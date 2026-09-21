"""Host-side submission desk for the `rtunreal` challenge.

Hands out the challenge tarball, takes a unified diff, forwards it to the
builder inside the challenge VM and prints the flag when every check the
builder ran came back green.

The split is the whole point of this process: the flag is here, the evaluation
of player-supplied Nix is over there. Nix evaluates expressions unsandboxed, so
a `builtins.readFile` in a submission must not run anywhere near this file.
"""

from __future__ import annotations

import html
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

TARBALL_ROUTE = "/rtunreal-challenge.tar.gz"


@dataclass(frozen=True)
class Config:
    """Everything the desk needs, all of it baked in by the NixOS module."""

    port: int
    builder: str
    flag_file: Path
    tarball: Path
    max_patch: int
    timeout: int
    # Where players reach this desk. nginx forwards `Host` without the port,
    # and this vhost does not live on a default one, so the URL in the copy
    # and paste instructions has to be told rather than guessed.
    public_url: str


def config_from_env() -> Config:
    def required(name: str) -> str:
        value = os.environ.get(name)
        if not value:
            raise SystemExit(f"rtunreal-gateway: {name} is not set")
        return value

    return Config(
        port=int(os.environ.get("RTUNREAL_PORT", "3001")),
        builder=required("RTUNREAL_BUILDER"),
        flag_file=Path(required("RTUNREAL_FLAG_FILE")),
        tarball=Path(required("RTUNREAL_TARBALL")),
        max_patch=int(os.environ.get("RTUNREAL_MAX_PATCH", str(512 * 1024))),
        timeout=int(os.environ.get("RTUNREAL_TIMEOUT", "1200")),
        public_url=os.environ.get("RTUNREAL_PUBLIC_URL", "").rstrip("/"),
    )


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pimp my PHP - submission desk</title>
<style>
 body {{ background: #11151c; color: #d8dee9; font-family: monospace;
        margin: 0 auto; max-width: 60rem; padding: 2rem 1rem; line-height: 1.5; }}
 a {{ color: #88c0d0; }}
 h1 {{ color: #ebcb8b; }}
 textarea {{ width: 100%; height: 18rem; background: #0b0e13; color: #d8dee9;
             border: 1px solid #3b4252; padding: .5rem; font-family: monospace; }}
 button, input[type=file] {{ font-family: monospace; font-size: 1rem; }}
 button {{ background: #5e81ac; color: #eceff4; border: 0; padding: .6rem 1.4rem;
           cursor: pointer; }}
 pre {{ background: #0b0e13; border: 1px solid #3b4252; padding: .5rem;
        overflow-x: auto; white-space: pre-wrap; }}
 .pass {{ color: #a3be8c; }}
 .fail {{ color: #bf616a; }}
 .flag {{ background: #2e3440; border: 1px solid #a3be8c; padding: 1rem;
          font-size: 1.2rem; word-break: break-all; }}
</style>
</head>
<body>
<h1>Pimp my PHP</h1>
<p>Package the PHP script so the flake's checks pass, then submit the diff that
gets you there. Every check has to build; the flag is printed when they all do.</p>
<ol>
 <li>Get the source: <a href="{tarball}">{tarball}</a>
     (or <code>git clone</code> it from the URL in the task description).</li>
 <li>Write <code>input-derivation.nix</code>, add whatever else you need, and make
     <code>nix flake check</code> pass locally.</li>
 <li>Produce the diff: <code>git add -A &amp;&amp; git diff HEAD</code>
     (<code>diff -ruN</code> against a pristine copy works too).</li>
 <li>Paste it below, or
     <code>curl --data-binary @my.patch {origin}/submit</code>.</li>
</ol>
<p>The builder runs <b>offline</b> in a throwaway VM: no substituters, no network,
no fetchers. It ships the challenge's own nixpkgs plus the build closure a
working solution needs. <code>flake.nix</code> and <code>flake.lock</code> are
restored from the pristine tree after your patch applies, so the checks you are
graded against are the ones you were given. One submission builds at a time.</p>
<form method="post" action="/submit">
 <p><input type="file" id="file" accept=".patch,.diff,text/*"></p>
 <textarea name="patch" id="patch" placeholder="diff --git a/input-derivation.nix ..."
           required>{patch}</textarea>
 <p><button type="submit">Submit patch</button></p>
</form>
{result}
<script>
document.getElementById('file').addEventListener('change', async (event) => {{
  const file = event.target.files[0];
  if (file) document.getElementById('patch').value = await file.text();
}});
</script>
</body>
</html>
"""


def render_result(verdict: dict[str, Any], flag: str | None) -> str:
    """Turn the builder's JSON into the part of the page below the form."""
    parts = ["<h2>Result</h2>"]

    # Anything that never reached the checks - a patch that does not apply, a
    # submission the runner refused, a builder that did not answer - carries
    # its own message.
    if verdict.get("stage") != "checks":
        message = str(verdict.get("message") or "The submission was not graded.")
        parts.append(f'<p class="fail">{html.escape(message)}</p>')
        parts.append(f"<pre>{html.escape(str(verdict.get('patchLog', '')))}</pre>")
        return "\n".join(parts)

    for check in verdict.get("checks", []):
        state = "pass" if check["passed"] else "fail"
        mark = "PASS" if check["passed"] else "FAIL"
        parts.append(
            f'<h3 class="{state}">{mark} {html.escape(str(check["name"]))}</h3>'
        )
        if not check["passed"]:
            parts.append(f"<pre>{html.escape(str(check['log']))}</pre>")

    if flag is not None:
        parts.append("<h2 class='pass'>All checks passed</h2>")
        parts.append(f'<p class="flag">{html.escape(flag)}</p>')
    else:
        parts.append('<p class="fail">Not all checks passed, no flag.</p>')

    parts.append(f"<p>built in {html.escape(str(verdict.get('seconds', '?')))}s</p>")
    return "\n".join(parts)


def page(origin: str, result: str = "", patch: str = "") -> bytes:
    return PAGE.format(
        tarball=TARBALL_ROUTE,
        origin=html.escape(origin),
        result=result,
        patch=html.escape(patch),
    ).encode()


def submit(cfg: Config, patch: bytes) -> dict[str, Any]:
    """Forward one submission to the builder in the VM."""
    request = urllib.request.Request(
        f"{cfg.builder}/verify",
        data=patch,
        headers={"Content-Type": "text/plain"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=cfg.timeout) as response:
            verdict: dict[str, Any] = json.loads(response.read())
            return verdict
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        return {
            "ok": False,
            "stage": "builder",
            "message": f"The grader refused the submission ({error.code}).",
            "patchLog": detail,
            "checks": [],
        }
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        return {
            "ok": False,
            "stage": "builder",
            "message": "The grading VM did not answer. It may still be "
            "booting, or your submission ran past the time budget.",
            "patchLog": str(error),
            "checks": [],
        }


def extract_patch(content_type: str, body: bytes) -> bytes:
    """Take the diff from a browser form field, or as the whole body.

    Content-Type cannot decide this: `curl --data-binary @my.patch`, the
    command every player is handed, labels a raw diff as form data. A diff
    posted that way has no `patch` field, so the field is what tells the two
    apart.
    """
    if content_type.startswith("application/x-www-form-urlencoded"):
        fields = urllib.parse.parse_qs(
            body.decode(errors="replace"), keep_blank_values=True
        )
        if "patch" in fields:
            return fields["patch"][0].encode()
    return body


class Handler(BaseHTTPRequestHandler):
    cfg: Config

    protocol_version = "HTTP/1.1"
    server_version = "rtunreal-gateway"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"{self.address_string()} {fmt % args}", flush=True)

    def origin(self) -> str:
        if self.cfg.public_url:
            return self.cfg.public_url
        host = self.headers.get("Host", "localhost")
        proto = self.headers.get("X-Forwarded-Proto", "http")
        return f"{proto}://{host}"

    def wants_json(self) -> bool:
        query = urllib.parse.urlparse(self.path).query
        if "json" in urllib.parse.parse_qs(query).get("format", []):
            return True
        return "application/json" in (self.headers.get("Accept") or "")

    def send_bytes(self, status: int, mime: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        self.send_bytes(status, "application/json", json.dumps(payload).encode())

    def do_GET(self) -> None:
        route = urllib.parse.urlparse(self.path).path
        if route == "/":
            self.send_bytes(200, "text/html; charset=utf-8", page(self.origin()))
        elif route == TARBALL_ROUTE:
            self.send_bytes(200, "application/gzip", self.cfg.tarball.read_bytes())
        elif route == "/health":
            self.send_json(200, {"ok": True})
        else:
            self.send_bytes(404, "text/plain; charset=utf-8", b"not found\n")

    def do_POST(self) -> None:
        route = urllib.parse.urlparse(self.path).path
        if route != "/submit":
            self.send_bytes(404, "text/plain; charset=utf-8", b"not found\n")
            return

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > self.cfg.max_patch:
            self.send_json(400, {"ok": False, "error": "empty or oversized patch"})
            return

        patch = extract_patch(
            self.headers.get("Content-Type", ""), self.rfile.read(length)
        )
        if not patch.strip():
            self.send_json(400, {"ok": False, "error": "empty patch"})
            return

        verdict = submit(self.cfg, patch)
        flag = self.cfg.flag_file.read_text().strip() if verdict.get("ok") else None

        if self.wants_json():
            self.send_json(200, {**verdict, "flag": flag})
            return
        body = page(
            self.origin(), render_result(verdict, flag), patch.decode(errors="replace")
        )
        self.send_bytes(200, "text/html; charset=utf-8", body)


def main() -> None:
    cfg = config_from_env()
    Handler.cfg = cfg
    # Fail at start rather than on the one request that matters: an unreadable
    # flag file means the deploy is wrong, not that the player is.
    cfg.flag_file.read_text()
    server = ThreadingHTTPServer(("127.0.0.1", cfg.port), Handler)
    print(f"rtunreal-gateway: listening on 127.0.0.1:{cfg.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
