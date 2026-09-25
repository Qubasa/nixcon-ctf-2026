"""Guest-side check runner for the `rtunreal` challenge.

Takes a unified diff over HTTP, applies it to a pristine copy of the challenge
source, rebuilds the flake's checks offline, and answers with one verdict per
check.

It holds no secret. The flag lives on the host, which only ever sees the
verdict this returns. A player's Nix expression is evaluated here with no
sandbox around the evaluator, as Nix always does, but it has nothing to read.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

LOG_TAIL = 8192

PRISTINE_FILES = ("flake.nix", "flake.lock")

REQUIRED_FILE = "input-derivation.nix"


@dataclass(frozen=True)
class Config:
    """Holds everything the runner needs, all of it baked in by the NixOS module."""

    port: int
    source: Path
    nixpkgs: Path
    system: str
    state: Path
    nix: str
    max_patch: int
    check_timeout: int
    total_timeout: int
    queue_timeout: int


def config_from_env() -> Config:
    """Read the configuration the unit exports, failing loudly on a gap."""

    def required(name: str) -> str:
        value = os.environ.get(name)
        if not value:
            raise SystemExit(f"rtunreal-builder: {name} is not set")
        return value

    return Config(
        port=int(os.environ.get("RTUNREAL_PORT", "3000")),
        source=Path(required("RTUNREAL_SOURCE")),
        nixpkgs=Path(required("RTUNREAL_NIXPKGS")),
        system=required("RTUNREAL_SYSTEM"),
        state=Path(required("RTUNREAL_STATE")),
        nix=os.environ.get("RTUNREAL_NIX", "nix"),
        max_patch=int(os.environ.get("RTUNREAL_MAX_PATCH", str(512 * 1024))),
        check_timeout=int(os.environ.get("RTUNREAL_CHECK_TIMEOUT", "600")),
        total_timeout=int(os.environ.get("RTUNREAL_TOTAL_TIMEOUT", "900")),
        queue_timeout=int(os.environ.get("RTUNREAL_QUEUE_TIMEOUT", "300")),
    )


def tail(text: str) -> str:
    """Keep the end of `text`, where a build failure puts its reason."""
    if len(text) <= LOG_TAIL:
        return text
    return "[...]\n" + text[-LOG_TAIL:]


def nix_argv(cfg: Config, *args: str) -> list[str]:
    """A `nix` command line that cannot reach the network or the lock file.

    `--override-input` replaces the challenge's tarball input with the copy
    baked into this image. Nix takes the original entry's metadata from
    flake.lock and never fetches it, which is what makes `--offline` work for a
    tree whose lock points at releases.nixos.org.
    """
    return [
        cfg.nix,
        *args,
        "--offline",
        "--no-write-lock-file",
        "--override-input",
        "nixpkgs",
        f"path:{cfg.nixpkgs}",
    ]


def run(argv: list[str], cwd: Path | None = None, timeout: int = 60) -> tuple[int, str]:
    """Run `argv`, merge its streams and never let it outlive `timeout`."""
    try:
        done = subprocess.run(
            argv,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as expired:
        partial = expired.output or ""
        if isinstance(partial, bytes):
            partial = partial.decode(errors="replace")
        return 124, f"{partial}\ntimed out after {timeout}s"
    return done.returncode, done.stdout


def discover_checks(cfg: Config) -> tuple[str, ...]:
    """Ask the pristine flake which checks a submission has to pass."""
    code, out = run(
        nix_argv(
            cfg,
            "eval",
            "--json",
            f"path:{cfg.source}#checks.{cfg.system}",
            "--apply",
            "builtins.attrNames",
        ),
        timeout=300,
    )
    if code != 0:
        raise SystemExit(f"rtunreal-builder: cannot evaluate the checks:\n{out}")
    return tuple(sorted(json.loads(out.splitlines()[-1])))


def copy_writable(source: Path, target: Path) -> None:
    """Copy a store tree to a place a patch can be applied in."""
    shutil.copytree(source, target)
    for path in [target, *target.rglob("*")]:
        path.chmod(path.stat().st_mode | 0o200)


def apply_patch(cfg: Config, work: Path, patch: bytes) -> tuple[bool, str]:
    """Apply the submitted diff, accepting both `git diff` and `diff -ruN`."""
    patch_file = work.parent / "submission.patch"
    patch_file.write_bytes(patch)

    attempts = [
        ["git", "apply", "--verbose", "-p1", "--whitespace=nowarn", str(patch_file)],
        ["patch", "-p1", "--batch", "--forward", "--input", str(patch_file)],
    ]
    log = ""
    for argv in attempts:
        code, out = run(argv, cwd=work, timeout=60)
        log += f"$ {' '.join(argv[:3])}\n{out}\n"
        if code == 0:
            return True, log
        shutil.rmtree(work)
        copy_writable(cfg.source, work)
    return False, log


def restore_pristine(cfg: Config, work: Path) -> None:
    """Undo any change to the files a submission is not allowed to decide."""
    for name in PRISTINE_FILES:
        target = work / name
        target.unlink(missing_ok=True)
        shutil.copyfile(cfg.source / name, target)
        target.chmod(0o644)


def run_check(cfg: Config, work: Path, name: str, deadline: float) -> dict[str, Any]:
    """Build one check derivation and turn its exit status into a verdict."""
    left = int(deadline - time.monotonic())
    if left <= 0:
        return {"name": name, "passed": False, "log": "skipped: out of time budget"}

    timeout = min(cfg.check_timeout, left)
    code, out = run(
        nix_argv(
            cfg,
            "build",
            "--no-link",
            "--print-build-logs",
            "--keep-going",
            "--max-jobs",
            "2",
            "--cores",
            "2",
            "--timeout",
            str(timeout),
            f"path:{work}#checks.{cfg.system}.{name}",
        ),
        timeout=timeout + 30,
    )
    return {"name": name, "passed": code == 0, "log": tail(out)}


def verify(cfg: Config, checks: tuple[str, ...], patch: bytes) -> dict[str, Any]:
    """Grade one submission: apply, restore, build, report."""
    started = time.monotonic()

    def refused(message: str, log: str) -> dict[str, Any]:
        return {
            "ok": False,
            "stage": "rejected",
            "message": message,
            "patchLog": tail(log),
            "checks": [],
            "seconds": round(time.monotonic() - started, 1),
        }

    with tempfile.TemporaryDirectory(dir=cfg.state) as tmp:
        work = Path(tmp) / "src"
        copy_writable(cfg.source, work)

        applied, apply_log = apply_patch(cfg, work, patch)
        if not applied:
            return refused("The patch does not apply to the challenge tree.", apply_log)

        restore_pristine(cfg, work)
        if not (work / REQUIRED_FILE).is_file():
            return refused(
                f"The patch applied, but it leaves no {REQUIRED_FILE}, which "
                "flake.nix needs to build anything. If you wrote it and git "
                f"dropped it from the diff, add it with `git add -f "
                f"{REQUIRED_FILE}`.",
                apply_log,
            )

        deadline = started + cfg.total_timeout
        results = [run_check(cfg, work, name, deadline) for name in checks]

    return {
        "ok": all(result["passed"] for result in results),
        "stage": "checks",
        "patchLog": tail(apply_log),
        "checks": results,
        "seconds": round(time.monotonic() - started, 1),
    }


class Handler(BaseHTTPRequestHandler):
    """The whole API: `POST /verify` and `GET /health`."""

    cfg: Config
    checks: tuple[str, ...]
    gate = threading.BoundedSemaphore(1)

    protocol_version = "HTTP/1.1"
    server_version = "rtunreal-builder"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"{self.address_string()} {fmt % args}", flush=True)

    def reply(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path != "/health":
            self.reply(404, {"error": "not found"})
            return
        self.reply(200, {"ok": True, "checks": list(self.checks)})

    def do_POST(self) -> None:
        if self.path != "/verify":
            self.reply(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            self.reply(400, {"error": "empty submission"})
            return
        if length > self.cfg.max_patch:
            self.reply(413, {"error": f"patch larger than {self.cfg.max_patch} bytes"})
            return

        patch = self.rfile.read(length)
        if not self.gate.acquire(timeout=self.cfg.queue_timeout):
            self.reply(503, {"error": "another submission is building, try again"})
            return
        try:
            self.reply(200, verify(self.cfg, self.checks, patch))
        finally:
            self.gate.release()


def main() -> None:
    cfg = config_from_env()
    cfg.state.mkdir(parents=True, exist_ok=True)

    Handler.cfg = cfg
    Handler.checks = discover_checks(cfg)
    print(f"rtunreal-builder: checks {', '.join(Handler.checks)}", flush=True)

    server = ThreadingHTTPServer(("0.0.0.0", cfg.port), Handler)
    print(f"rtunreal-builder: listening on 0.0.0.0:{cfg.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
