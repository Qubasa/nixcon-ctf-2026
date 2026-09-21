# rtunreal

Hosts the `rtunreal` challenge (`../../challenges/rtunreal-challenge`, "Pimp my
PHP"): the player is given a flake whose `checks` test a PHP program that
nobody packaged, and has to write the `input-derivation.nix` - plus the missing
piece of the program itself - that makes `nix flake check` pass.

Unlike every other challenge here, the player never gets the flag out of a
machine they broke into. They get it by handing in a patch that builds. So the
service is a grader:

```
player ──patch──▶ nginx :8082 ──▶ rtunreal-gateway ──patch──▶ rtunreal-vm
  ◀──── flag ──── (holds the flag)  ◀── verdict ──── (holds no secret)
```

Three moving parts:

- **`rtunreal-vm.service`** - one long-lived QEMU guest with no egress, running
  `rtunreal-builder` ([`builder.py`](builder.py)). It applies the patch to a
  pristine copy of the challenge, rebuilds the flake's checks offline and
  answers `POST /verify` with one verdict per check.
- **`rtunreal-gateway.service`** - the submission desk on the host
  ([`gateway.py`](gateway.py)). It serves the page and the challenge tarball,
  forwards submissions to the guest, and prints the flag when the verdict comes
  back green. It never evaluates anything.
- an nginx vhost on `publicPort` (plain HTTP, `8082`) in front of the desk.

## Why the grading is in a VM and the flag is not

Grading means evaluating Nix that a player wrote, and that is strictly worse
than building it:

1. **Nix evaluation is not sandboxed.** `builtins.readFile "/run/secrets/..."`
   in a submitted `input-derivation.nix` is evaluated with the privileges of
   whatever runs `nix build`. Any process that can read the flag must therefore
   never evaluate a submission - hence the split: the flag lives in the
   gateway, which only ever sees a JSON verdict.
2. **Fixed-output derivations build in the host's network namespace.** On
   ctf-machine that is loopback, where chall-manager's unauthenticated API
   listens on `10.89.0.1:8080` and its registry on `127.0.0.1:5000`. The same
   reasoning as [baas](../baas/README.md), and the same answer: the builds
   happen in a guest with `restrict=on`, no egress at all.
3. **The build sandbox bind-mounts the whole store read-only into builders.**
   On the host that is every service's closure; in the guest it is the
   challenge plus its build inputs.

A sandbox escape inside the guest lands in a machine that holds no secret
whatsoever. Not even the flag - which is the difference to baas, where the
flag is the point of the guest.

## What a submission may and may not change

The patch is applied to a pristine copy of the challenge tree, then
`flake.nix` and `flake.lock` are **restored from that pristine tree**
(`PRISTINE_FILES` in `builder.py`). Otherwise the first solve would be a patch
that replaces the checks with `true`, and the lock is what the guest's offline
closure was seeded for.

Everything else is fair game: `input-derivation.nix`, `main.php`, `pmp.patch`,
new files. The checks are behavioural - lint the installed program with `php
-l`, run it against a generated config, compare its output - so any package
that satisfies them is a solve.

Submissions are applied with `git apply -p1` and, if that fails, with
`patch -p1` from the pristine tree again, so both `git diff` and `diff -ruN`
output work. The runner builds one submission at a time behind a semaphore;
further submissions queue for up to `totalTimeout` before being turned away
with a 503.

A submission that applies but leaves no `input-derivation.nix` is rejected
before any build, with the `git add -f` hint: the challenge repo's own
`.gitignore` used to list that file, and a `git diff` says nothing about a
file git was told to ignore. That is the one way a player can hand in an
empty answer while believing they did not.

## What players are given

[`source.nix`](source.nix) builds the published tree, and *both* the tarball
the desk serves and the tree the guest grades against come from it - they
cannot drift. It drops two things from the challenge repo:

- `.git`
- `solution/`, a scratch copy of the whole challenge that lives in the
  challenge repo and whose own `.gitignore` has `#input-derivation.nix`
  commented out. Nothing leaks today, but the day the author commits their
  answer there it would ship with the tarball. Stripped rather than trusted.

## Offline, and what the image ships

The guest has no network, so `nix.settings.substituters` is empty and every
build either finds what it needs in the image or fails immediately.

The challenge pins nixpkgs by tarball URL. That tarball is an input of this
flake (`rtunreal-nixpkgs`), it is baked into the image, and the runner passes
`--override-input nixpkgs path:<that tree> --offline` on every build. Nix takes
the original input's metadata from the challenge's `flake.lock` and never
fetches it, so evaluation is offline too.

`guest.nix` throws at eval time if the challenge's lock and the flake input
ever drift apart, because the failure mode otherwise is silent: every
submission would fail on paths that are not in the image.

Seeded into the image (`system.extraDependencies`):

- the **reference solution's checks, realised at image build time**. That is
  `solution/input-derivation.nix` evaluated through the challenge's real
  `flake.nix` - `outputs` is an ordinary function and `self` is its own
  fixpoint, so there is no second copy of the check definitions to keep in
  sync. A build of this service therefore *proves the challenge is solvable
  offline*.
- their `inputDerivation`s, so a different solution has stdenv, php, patch and
  the sources available to rebuild from
- a generic tool list on top, deliberately not tailored to one solution

Note that `solution/input-derivation.nix` is the answer key. It is in this
repository, which is not the one players are given.

The guest garbage-collects hourly (`--max-freed 10G`): every submission leaves
an unrooted closure behind and none of it is worth keeping. The seeds survive
because they are part of the system closure, which is a GC root.

## Flag

`clan vars` mints it once, `openssl rand -hex 16` through `flagFormat`
(default `nixcon{rtunreal_%s}`), secret, `0400`, owned by `rtunreal`:

```console
clan vars generate prod-ctf-machine --generator rtunreal
clan vars get prod-ctf-machine rtunreal/flag
```

It is read by the gateway at request time and printed only when every check in
the verdict passed. Rotating it:

```console
clan vars generate prod-ctf-machine --generator rtunreal --regenerate
```

The generator lists `rtunreal-gateway.service` in `restartUnits`, so a deploy
picks the new value up. The guest is not restarted, because it never had it.

## Endpoints

| route | what it does |
|---|---|
| `GET /` | the submission page, with the instructions and a paste area |
| `GET /rtunreal-challenge.tar.gz` | the challenge tree, the same bytes the grader applies patches to |
| `POST /submit` | grade a patch; `?format=json` for a machine-readable verdict including `flag` |
| `GET /health` | liveness of the desk |

```console
curl --data-binary @my.patch 'http://ctf.nixcon.org:8082/submit?format=json'
```

The guest's own API (`POST /verify`, `GET /health`) is only reachable on
`127.0.0.1:<internalPort>` of the host.

## Usage

```nix
inventory.instances.rtunreal = {
  module = {
    name = "rtunreal";
    input = "self";
  };
  roles.server.machines.prod-ctf-machine = { };
  roles.server.settings = {
    nginx.hostName = "ctf.nixcon.org";
    # port = 3000;            # runner port inside the guest
    # internalPort = 43002;   # loopback port QEMU forwards to
    # gatewayPort = 43003;    # loopback port of the submission desk
    # publicPort = 8082;      # 8080 is chall-manager's, 8081 is baas'
    # memorySize = 6144;      # MiB; one nixpkgs evaluation per check
    # cores = 4;
    # diskSize = 40960;       # MiB, sparse; hourly GC keeps it flat
    # checkTimeout = 600;     # seconds per check
    # totalTimeout = 900;     # seconds per submission
    # maxPatchBytes = 524288;
    # flagFormat = "nixcon{rtunreal_%s}";
  };
};
```

The VM host needs KVM (`/dev/kvm`); `rtunreal-vm.service` runs as the
unprivileged `rtunreal` user in the `kvm` group. Budget one more long-lived
6 GiB guest next to baas and the homewort pools.

## Testing it without deploying

`nix run .#rtunreal-vm` boots the grader alone, forwarded to
`127.0.0.1:43002`, with no gateway and no flag:

```console
nix run .#rtunreal-vm &
curl -s 127.0.0.1:43002/health
cp services/rtunreal/solution/input-derivation.nix challenges/rtunreal-challenge/
git -C challenges/rtunreal-challenge add -A
git -C challenges/rtunreal-challenge diff HEAD > /tmp/solution.patch
curl -s --data-binary @/tmp/solution.patch 127.0.0.1:43002/verify | jq '.ok, .checks[].name'
```

Smoke test after a deploy:

```console
systemctl status rtunreal-vm rtunreal-gateway
curl -sf http://127.0.0.1:43002/health   # the guest answers
curl -s http://ctf.nixcon.org:8082/ | head
```

## Registering the challenge in CTFd

A plain static-flag challenge: one shared grader, nothing for chall-manager to
deploy and no `dynamic_iac` form.

- **Category**: `nix`
- **Name**: `Pimp my PHP`
- **Type**: `standard`
- **Flag**: the value of `clan vars get prod-ctf-machine rtunreal/flag`,
  static, case-sensitive
- **Description**: must carry both URLs - the repository to clone and
  `http://ctf.nixcon.org:8082/`, plain HTTP on a non-standard port, which
  nobody will guess. Worth saying that the grader builds offline, so nobody
  burns time on a solution that wants to fetch something.
