# baas

Hosts the `baas` challenge (`../../challenges/baas`): an Express app that takes
a Nix expression from an HTTP form, hands it to `nix-build`, and serves anything
under `/nix/store` back over `GET /path/:path`.

Every team gets its own app in its own QEMU VM with its own flag, claimed on
demand through chall-manager like the [gaolbird](../gaolbird) pool:

- slot `n` runs `baas-vm-<n>` and serves the app on public port
  `basePort + n - 1` (default 2601-…, loopback 42601-…)
- the allocator is `baas-instance`, built from the shared
  [`pkgs/pool-allocator.nix`](../../pkgs/pool-allocator.nix) that gaolbird uses
  too, with the same verbs and exit codes, and its state lives in
  `/var/lib/baas-slots`
- `connection_info` is the slot's URL, `http://<publicHost>:<port>/`

## Why a VM

The app is a remote build service with no authentication. Two things it does are
harmless in a throwaway guest and unacceptable on the host:

1. **`GET /path/:path` serves any store path.** It resolves the path, checks
   that the realpath starts with `/nix/store/`, and then sends the file or lists
   the directory. Pointed at the host's daemon, the endpoint would publish
   ctf-machine's entire `/nix/store` over HTTP without authentication. Nix's
   build sandbox also bind-mounts the whole store read-only into every builder,
   so a player's derivation could walk it too.
2. **Fixed-output derivations build in the daemon's network namespace.** That
   is Nix's documented behaviour and the mechanism this challenge is about. On
   the host it would put players on the loopback interface of ctf-machine, where
   chall-manager's unauthenticated API listens on `10.89.0.1:8080` and its OCI
   registry on `127.0.0.1:5000` accepts plain-HTTP pushes. The egress filter
   (see Network) keeps both out of reach of the guests.

`guest.nix` is therefore a NixOS system with its own store, its own daemon, and
its own `nixbld` users, imaged as `system.build.vmWithBootLoader`. It uses
`vmWithBootLoader` rather than the plain `vm` variant because the plain one
9p-mounts the host's `/nix/store` into the guest.

## Why a VM per team

The app keys its listing of built paths on `req.ip`, and the intended solve (the
author's `payload.nix`) is a fixed-output derivation that asks
`http://localhost:3000/` for the listing of `127.0.0.1`, where `init.sh` put the
flag, and sends it out. On one shared app that listing is the same for every
team, so the first team to solve it could hand the flag's path to everybody, and
one team filling the disk broke the challenge for all. With a VM per team:

- the flag is registered from `127.0.0.1`, exactly as `init.sh` does, and the
  app runs unpatched apart from its port
- a team's builds only ever fill its own disk, which is wiped when the slot is
  released
- every claim mints a new flag, so a flag copied from another team is wrong

## Network

The guest has internet access, because the solve sends the listing out of a
fixed-output derivation. QEMU's slirp opens those connections from the QEMU
process on the host, and slirp maps its host alias `10.0.2.2` to the host's
`127.0.0.1`. Left alone, a guest could reach every service on this machine.

QEMU runs as the `baas` user, which this service lists in
`ctf.vmEgress.users`. `../../modules/vm-egress.nix` then sends every packet
that user sends through the iptables `OUTPUT` chain `vm-egress`, which the
`gaolbird` VMs share:

1. packets of an already established connection pass. This keeps the proxies'
   connections *to* the guests' forwarded ports working.
2. DNS to systemd-resolved's stub on `127.0.0.53:53` passes, because slirp
   forwards the guest's DNS to the host's resolver.
3. a new connection to any address of this host (`--dst-type LOCAL`, which
   covers `127.0.0.0/8`, the public IP, docker and `challmgr0`) is rejected.
4. so is a new connection to any private, link-local, CGNAT, multicast, or
   reserved range, for IPv4 and IPv6.
5. everything else, that is the public internet, passes.

The rules fail closed. A guard rule rejects the guests' new connections while
the chain is rebuilt on a firewall reload, stopping the firewall leaves the
chain in place, and an assertion refuses a host without the iptables firewall.

To check the filter from the host, run as the `baas` user:

```console
sudo -u baas curl -m 3 http://127.0.0.1:5000/v2/  # must fail: loopback
sudo -u baas curl -m 3 http://10.89.0.1:8080/     # must fail: local address
sudo -u baas curl -m 3 -sI https://example.com    # must succeed: internet
```

The public port of slot `n` is a `systemd-socket-proxyd` unit,
`baas-vm-<n>-http.socket`, that reaches the guest over loopback. Loopback
*inside* the guest works, which is what the challenge needs.

`nix.settings.substituters` stays empty in the guest, so a build cannot pull a
multi-gigabyte closure from a binary cache. Builds download their sources
instead and compile against what the image seeds: `system.extraDependencies`
holds `stdenv`, `stdenvNoCC`, the usual `buildInputs` tools, and four
`inputDerivation`s.

## Flag

`baas-instance create` mints `flagFormat` (default `nixcon{baas_%s}`) with 32
random hex characters into `/var/lib/baas-slots/<n>/flag`, owned by `baas` and
mode `0400`, and reports it to chall-manager, which hands it to CTFd as the
instance's flag. From there:

1. `baas-vm-<n>.service` passes the file to QEMU as
   `-fw_cfg name=opt/ctf/flag,file=/var/lib/baas-slots/<n>/flag`
2. inside the guest it appears as
   `/sys/firmware/qemu_fw_cfg/by_name/opt/ctf/flag/raw`, readable by root only
3. the app unit's `ExecStartPost` reads that blob and posts
   `{}: pkgs.writeText "flag" "<flag>"` to the app from `127.0.0.1`, the same
   request `init.sh` makes. It is prefixed `+`, so it runs as root while the app
   itself runs as the unprivileged `baas` user.

The flag therefore does end up in the guest's store, deliberately: finding that
store path is the challenge. It never reaches this machine's store.

The bootstrap re-runs on every start of the app, because `builtPaths` is
in-process memory. It builds the flag with `nix-build --no-out-link` and deletes
the app's `./result` link afterwards, because `/path/` follows symlinks: a link
to the flag's output would be a one-request solve.

The guest firewall keeps the app port closed to the outside until the bootstrap
has registered the flag, and only then opens it. The allocator reports a slot
ready on the first HTTP answer through the forwarded port, so a team never gets
an instance whose flag is not registered yet.

## Guest internals worth knowing

- The app runs as the system user `baas` with `ProtectSystem=strict`,
  `ProtectHome`, `NoNewPrivileges`, `RestrictAddressFamilies`, and so on. It
  needs no group membership to use the Nix daemon: the socket is
  world-connectable and untrusted users cannot change daemon-side settings.
- `PrivateTmp = true` is load bearing, not hygiene. Under
  `ProtectSystem=strict` `/tmp` is read-only and `nix-build` cannot create its
  temporary build directory.
- `NIX_PATH = "nixpkgs=${pkgs.path}"` is set in the unit because `index.js`
  evaluates `import <nixpkgs> {}` with `restrict-eval` on. No system unit
  inherits NixOS's default, and a store path keeps evaluation offline. It is the
  same nixpkgs the host is built from.
- `WorkingDirectory` is the state directory because `nix-build` drops a
  `./result` symlink into the working directory on every request. Express
  resolves its view directory relative to the same place, so
  `/var/lib/baas/views` is a tmpfiles symlink into the package.
- The overlay disk is wiped whenever the slot's VM starts or stops, so a crash
  or a reboot of the guest loses the team's builds but keeps its flag, and a
  released slot gives its disk back at once. `restartIfChanged = false` keeps a
  deploy from wiping a running team's box. A changed image takes effect on the
  slot's next claim.
- The guest has no `openssh`. Debug it from the host with
  `journalctl -u baas-vm-<n>` and the QEMU console.

## The patch to `index.js`

The challenge source is served as it is, apart from one `substituteInPlace` in
`package.nix`: `const port = 3000` becomes `process.env.PORT`, because the port
is a deployment decision.

## Usage

```nix
inventory.instances.baas = {
  module = {
    name = "baas";
    input = "self";
  };
  roles.server.machines.ctf-machine = { };
  roles.server.settings = {
    publicHost = "ctf.nixcon.org";
    maxSlots = 20;
    # basePort = 2601;
    # internalBasePort = 42601;
    # memorySize = 4096;    # MiB, one nixpkgs evaluation per build request
    # cores = 2;
    # diskSize = 20480;     # MiB, sparse, wiped per claim
    # flagFormat = "nixcon{baas_%s}";
    # allowUser = "chall-manager";
    # readyTimeout = 180;
  };
};
```

chall-manager's `scenarioWritePaths` must contain `/var/lib/baas-slots`, and
`internalBasePort … internalBasePort + maxSlots - 1` must be in
`net.ipv4.ip_local_reserved_ports`.

Budget `maxSlots` × `memorySize`. A guest idles at about 2 GiB and peaks while
it evaluates nixpkgs.

Smoke test after a deploy, as root on the host:

```console
baas-instance create --identity smoke    # prints the slot's JSON, flag included
curl -s http://ctf.nixcon.org:2601/ | head
baas-instance destroy --identity smoke
```

## Registering the challenge in CTFd

Create it in the admin UI (`https://ctf.nixcon.org/admin/challenges`):

- **Category**: `nix` (or `web`)
- **Name**: `baas`
- **Value**: ~200 (the author rates it "easier end of medium")
- **Type**: `dynamic_iac`
- **Scenario**: `127.0.0.1:5000/baas:0.1.0`
- **Timeout**: `2700` (45 minutes)
- **Destroy on flag**: on
- **Mana cost**: `0`
- **Shared**: off
- **Flag**: none. The scenario reports each instance's flag.
- **Description**:

  ```text
  Build as a Service. Deploy an instance and open the URL shown.

  The box is yours alone for 45 minutes. It reaches the internet but has no
  binary cache, so building a large package from source takes a while.
  ```

Before making it visible, deploy an instance from the admin UI, open its URL,
build `{ writeText }: writeText "x" "y"`, and destroy it again.
