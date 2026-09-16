# baas

Hosts the `baas` challenge (`../../challenges/baas`): an Express app that takes
a Nix expression from an HTTP form, hands it to `nix-build`, and serves anything
under `/nix/store` back over `GET /path/:path`. One shared instance, one flag,
no per-team deployment: everybody plays against the same app.

The whole service is one long-lived QEMU VM plus an nginx vhost in front of it.
There is no allocator and nothing to claim, unlike the [homewort](../homewort)
pool.

## Why a VM

The app is a remote build service with no authentication. Two things it does are
harmless in a throwaway guest and unacceptable on the host:

1. **`GET /path/:path` serves any store path.** It resolves the path, checks
   that the realpath starts with `/nix/store/`, and then sends the file or lists
   the directory. Pointed at the host's daemon, that is ctf-machine's entire
   `/nix/store` published over HTTP, unauthenticated: every service's closure,
   every configuration file NixOS assembles in the store, every future
   challenge's build inputs. Nix's build sandbox also bind-mounts the whole
   store read-only into every builder, so a player's derivation could walk it
   too.
2. **Fixed-output derivations build in the host's network namespace.** That is
   Nix's documented behaviour and the mechanism this challenge is about. On the
   host it would put players on the loopback interface of ctf-machine, where
   chall-manager's unauthenticated API listens on `10.89.0.1:8080` - its own
   README calls it RCE-as-a-Service, and the service holds `NOPASSWD` sudo on
   `homewort-instance` - and where its OCI registry on `127.0.0.1:5000` accepts
   plain-HTTP pushes with `delete.enabled = true`, i.e. replacing the scenario
   that chall-manager executes. Neither is reachable from inside the guest.

Systemd hardening on the app unit cannot fix either of those: the builds do not
run in the app's namespace, they run in `nix-daemon`'s. Containment has to be at
the store and network level, which means a machine boundary.

So `guest.nix` is a NixOS system with its own store, its own daemon and its own
`nixbld` users, imaged as `system.build.vmWithBootLoader` and started by
`baas-vm.service`. `vmWithBootLoader` rather than the plain `vm` variant because
the plain one 9p-mounts the host's `/nix/store` into the guest, which is the
exact exposure this VM exists to prevent. A sandbox escape inside lands in a VM
that holds one secret, the flag, which the players are supposed to get anyway.

## Network

The guest runs with QEMU's `restrict=on`: no egress at all. `restrict=on` also
drops the guest's replies to any client address other than slirp's own host
alias, and only a loopback client is rewritten to that alias, so the guest's app
port is forwarded to `127.0.0.1:<internalPort>` and the public port belongs to a
host process that reaches the guest over loopback - here nginx, where homewort
uses `systemd-socket-proxyd`.

Loopback *inside* the guest still works, which is what the challenge needs.

What no egress costs: a player's build can only use what the image already
ships, and `nix.settings.substituters` is empty in the guest so a build that
needs an absent path fails immediately instead of hanging on an unreachable
cache. `system.extraDependencies` seeds `stdenv`, `stdenvNoCC`, the usual
`buildInputs` tools and a few `inputDerivation`s, so `mkDerivation`,
`runCommand`, `writeText` and a derivation that really compiles something all
work offline. Anything else - `pkgs.fetchurl` from the internet, a package whose
source is not in the image - is a build failure, and that is expected.

The vhost is plain HTTP on `publicPort` (default `8081`), no ACME:

- 80 and 443 belong to CTFd and gitea, whose certificates cover their own names
- 8080 is not available: chall-manager has no listen-address flag and always
  binds `0.0.0.0:8080`, so nginx would fail to bind it
- HTTP-01 only ever answers on 80, so a certificate for a vhost on a
  non-standard port is not obtainable this way

The vhost is `default` on its port, so it answers whatever `Host` a player's
`curl` sends, a bare IP included. No new DNS record: `ctf.nixcon.org` already
points here.

`recommendedProxySettings = true` is load bearing, see below, and both proxy
timeouts are raised to `600s` because a cold `nix-build` outruns nginx's 60
second default and the player would get a 504 while the build keeps running.

`POST /build` gets a `limit_req` zone of `12r/m` per address with a burst of 5.
Every request evaluates the whole of nixpkgs inside the guest - seconds of one
of its two cores - so without a limit one client with a loop starves everybody
else. One build every five seconds is far faster than anyone writes Nix by hand.
`GET /build` shares the zone; it only renders a form, so it costs nothing either
way.

Anubis is available (`nginx.anubis.enable`) but **off** by default, unlike
CTFd's: this challenge is solved with `curl` and scripts, and a
proof-of-work interstitial breaks every non-browser client.

## The two patches to `index.js`

The challenge source is published to players as it is; the deployment needs
exactly two changes, both `substituteInPlace` in `package.nix`:

1. `const port = 3000` becomes `process.env.PORT`. The port is a deployment
   decision, and on the host 3000 is gitea's.
2. `app.set('trust proxy', true)` right after `const app = express()`.

The second one decides whether the challenge is solvable at all. `builtPaths` is
keyed on `req.ip`, and Express 5 defaults `trust proxy` to `false`: behind the
vhost every request would report `127.0.0.1`, one shared bucket for all players,
and it is the bucket the startup flag build would land in. `GET /` would then
hand the flag's store path to everybody who asked.

Trusting the proxy has its own edge: with every hop trusted, `req.ip` is the
left-most `X-Forwarded-For` entry, which is whatever the client sent, because
nginx appends rather than replaces. A player can therefore claim any bucket they
like. That is why the flag is not parked on a fixed address: the bootstrap POST
sends a random `X-Forwarded-For` token, so the only listing the flag appears in
is one nobody can ask for, while players still get their own bucket from the
address nginx appends.

## Flag

`clan vars` mints it once, `openssl rand -hex 16` through `flagFormat`
(default `nixcon{baas_%s}`), secret, `0400` and owned by `baas` because QEMU
opens the file itself:

```console
clan vars generate ctf-machine --generator baas
clan vars get ctf-machine baas/flag
```

From there:

1. `baas-vm.service` passes the file to QEMU as
   `-fw_cfg name=opt/ctf/flag,file=<var path>`
2. inside the guest it appears as
   `/sys/firmware/qemu_fw_cfg/by_name/opt/ctf/flag/raw`, readable by root only
3. the app unit's `ExecStartPost` - prefixed `+`, so it runs as root while the
   app itself runs as the unprivileged `baas` user - reads that blob and posts
   `{}: pkgs.writeText "flag" "<flag>"` to the app, character for character the
   expression `index.js` wraps player input in

So the flag does end up in the guest's store, deliberately: finding that store
path is the challenge. It never reaches this machine's store, and it never goes
through a NixOS option in the guest either - `environment.etc` and friends would
put it in the store *world-readable and predictable*, and the whole store is
served over HTTP here.

The bootstrap re-runs on every start of the app, because `builtPaths` is
in-process memory and a restart loses it. It also takes a second GC root with
`nix-build --out-link /var/lib/baas/flag-result`, because every player build
overwrites the `./result` link in the working directory and the flag derivation
would be left unrooted.

`ExecStartPost` waits for the listener with a retry loop on `GET /build` rather
than sleeping: the unit counts as started when the process is forked, a second
or two before express binds.

Rotating the flag means regenerating the var and restarting the VM (the
generator lists `baas-vm.service` in `restartUnits`, so a deploy does it):

```console
clan vars generate ctf-machine --generator baas --regenerate
```

## Guest internals worth knowing

- The app runs as the system user `baas` with the same hardening set as
  `chall-manager`: `ProtectSystem=strict`, `ProtectHome`, `NoNewPrivileges`,
  `RestrictAddressFamilies`, and so on. It needs no group membership to use the
  Nix daemon: the socket is world-connectable and untrusted users cannot change
  daemon-side settings, which is exactly what we want.
- `PrivateTmp = true` is load bearing, not hygiene. Under
  `ProtectSystem=strict` `/tmp` is read-only and `nix-build` cannot create its
  temporary build directory. Measured with the full set on a transient unit:
  with `PrivateTmp`, `connect(2)` to `/nix/var/nix/daemon-socket` and a whole
  `nix-build --out-link` both succeed, so the daemon socket needs no
  `ReadWritePaths` entry of its own.
- `NIX_PATH = "nixpkgs=${pkgs.path}"` is set in the unit because `index.js`
  evaluates `import <nixpkgs> {}` with `restrict-eval` on. NixOS exports its own
  default through `environment.sessionVariables`, which no system unit inherits,
  and a store path keeps evaluation offline where the default
  `flake:nixpkgs` indirection would not. It is the same nixpkgs the host is
  built from.
- `WorkingDirectory` is the state directory because `nix-build` drops a
  `./result` symlink into the working directory on every request. Express
  resolves its view directory relative to the same place, so `/var/lib/baas/views`
  is a tmpfiles symlink into the package.
- The overlay disk is *not* wiped on restart, the other difference to the
  homewort pool: players keep working against store paths they built earlier, so
  a crash-restart has to find them again. `diskSize` therefore has to hold every
  derivation built for the length of the event - nothing collects the guest's
  store, because a garbage collection would break the paths players still hold
  links to.
- No `openssh` in the guest. Nobody is supposed to log in; debug it from the
  host with `journalctl -u baas-vm` and the QEMU console.

## Usage

```nix
inventory.instances.baas = {
  module = {
    name = "baas";
    input = "self";
  };
  roles.server.machines.ctf-machine = { };
  roles.server.settings = {
    nginx = {
      enable = true;
      hostName = "ctf.nixcon.org";
      # anubis.enable = false;  # breaks curl-driven clients, off on purpose
    };
    # port = 3000;          # app port inside the guest
    # internalPort = 43000; # loopback port QEMU forwards to
    # publicPort = 8081;    # 8080 is chall-manager's
    # memorySize = 4096;    # MiB; one nixpkgs evaluation per build request
    # cores = 2;
    # diskSize = 40960;     # MiB, sparse upper bound, holds every player build
    # flagFormat = "nixcon{baas_%s}";
  };
};
```

The VM host needs KVM (`/dev/kvm`); `baas-vm.service` runs as the unprivileged
`baas` user in the `kvm` group. Budget one extra long-lived 4 GiB guest next to
the homewort pool.

Smoke test after a deploy:

```console
systemctl status baas-vm
curl -sf http://127.0.0.1:43000/build >/dev/null && echo guest up
curl -s http://ctf.nixcon.org:8081/ | head
journalctl -u baas-vm | grep -i 'Built /nix/store'
```

## Registering the challenge in CTFd

Challenges are created in CTFd's admin UI
(`https://ctf.nixcon.org/admin/challenges`). This one is a plain static-flag
challenge: one shared instance, so there is nothing for chall-manager to deploy
and no `dynamic_iac` form.

- **Category**: `nix` (or `web`)
- **Name**: `baas`
- **Value**: ~200, the author rates it "easier end of medium"
- **Type**: `standard`
- **Flag**: the value of `clan vars get ctf-machine baas/flag`, static,
  case-sensitive
- **Description**: must carry the URL, `http://ctf.nixcon.org:8081/` - plain
  HTTP on a non-standard port, so it will not be guessed. Worth saying that the
  box has no internet access, so that nobody burns time on a build that wants to
  download a source tarball.
