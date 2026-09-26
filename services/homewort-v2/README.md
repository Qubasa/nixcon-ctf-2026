# homewort-v2

Hosts the [`homewort-v2`](https://git.immutable-byte.de/nixcon-ctf/homewort-v2)
CTF challenge. It shares the premise of [`homewort`](../homewort) (a NixOS box
where the player may only edit their own home-manager configuration and has to
escalate to root from there) but runs on a machine whose home-manager is not the
one upstream ships. The author rates it at the harder end of medium, the easier
end of hard, so it is meant to be attempted after the first one falls.

Everything in here is a fork of `../homewort` with its own names, because the
two pools run side by side on `ctf-machine`. A challenge that shares a unit
name, a state directory, a system user, or a password with another challenge is
one rebuild away from handing two challenges the same box.

Each player needs their own machine, because solving the challenge means
rebuilding the system as root. Each player also needs their own flag, or the
first solver could hand the string to everyone else. This service therefore
offers `maxSlots` empty slots and lets [chall-manager](../chall-manager) claim
one per player, on demand, through the `homewort-v2-instance` allocator:

- slot `n` runs the systemd service `homewort-v2-vm-<n>`, started when it is
  claimed and stopped when it is released
- slot `n` accepts SSH on `basePort + n - 1` (see Network for how it gets there)
- slot `n` gets its own random flag, minted at claim time
- the guest logs in as `friend` with the generated `homewort-v2-login/password`

Nobody operates this during the event. A player clicks "deploy" in CTFd and the
plugin asks chall-manager. chall-manager runs the Pulumi scenario, the scenario
runs `homewort-v2-instance create`, and the player gets a port, a password, and
60 minutes. Solving it, or the timeout running out, releases the slot again.

## The allocator

`homewort-v2-instance` is the entire seam between the VM host and chall-manager.
The Pulumi scenario knows nothing about systemd or qcow2. It runs

```console
/run/wrappers/bin/sudo -n /run/current-system/sw/bin/homewort-v2-instance create --identity <ID>
```

and parses the single line of JSON on stdout:

```json
{"identity":"abc123","slot":3,"port":2303,"flag":"nixcon{homewort_v2_<32 hex>}","connection_info":"ssh friend@ctf.nixcon.org -p 2303  (password: word-word-word)"}
```

`connection_info` and `flag` are what the scenario exports to chall-manager, and
from there into the player's challenge page.

| verb                      | behaviour                                                                   |
| ------------------------- | --------------------------------------------------------------------------- |
| `create --identity <ID>`  | Claims a slot, starts the VM, waits for its SSH banner, and prints the JSON |
| `destroy --identity <ID>` | Stops the VM, wipes the flag, frees the slot, and prints nothing            |
| `status --identity <ID>`  | Prints the same JSON for an already claimed identity                        |
| `list`                    | Prints a JSON array of every claimed slot                                   |

Every verb is idempotent: `create` run twice for the same identity reprints the
same JSON (same slot, same flag), and `destroy` succeeds for an identity that
never existed. chall-manager retries, so the idempotency is load bearing.

Exit codes are the contract with the scenario:

| code | meaning                                                                               |
| ---- | ------------------------------------------------------------------------------------- |
| `0`  | Success                                                                               |
| `2`  | Malformed identity (the charset is `[a-z0-9]{1,64}`) or a usage error                 |
| `3`  | `status` for an identity that holds no slot                                           |
| `4`  | No free slot: the pool is not overbooked, and the deploy fails in CTFd instead        |
| `5`  | The VM did not become reachable within `readyTimeout`, and the slot is released again |

The bookkeeping is a directory tree under `/var/lib/homewort-v2-slots`, not a
database:

```text
/var/lib/homewort-v2-slots/.lock          flock target that serialises the claim only
/var/lib/homewort-v2-slots/<n>/identity   presence == slot claimed
/var/lib/homewort-v2-slots/<n>/flag       0400 homewort-v2:homewort-v2, fed to the guest
```

The lock is held for the claim and for teardown, never while `create` waits for
a guest to boot, so players can deploy concurrently. The flag is written before
the identity file, so a crash in between leaves a free slot rather than a slot
with a stale flag.

`homewort-v2-instance` is root-only. `security.sudo.extraRules` grants
`allowUser` (default `chall-manager`) `NOPASSWD` on exactly
`/run/current-system/sw/bin/homewort-v2-instance` and nothing else. That path,
not the allocator's store path, is what the scenario hardcodes: it is the only
one that survives a rebuild.

Which systemd unit a slot maps to is a template of the allocator's `unitPrefix`
argument, not a literal. This pool's `stop` and `start` therefore can never land
on `../homewort`'s `homewort-vm-<n>` units, and the next fork of this service
changes one string.

You can drive it by hand for a smoke test:

```console
sudo homewort-v2-instance create --identity smoketest
sudo homewort-v2-instance list
sudo homewort-v2-instance destroy --identity smoketest
```

The CLI's contract is covered by `checks.homewort-v2-allocator`
(`allocator-test.nix`), which runs it against a stub `systemctl` and a stub
readiness probe, so it needs neither KVM nor root. It exercises two allocator
instantiations with different `unitPrefix` values, which is how the unit-name
template stays honest.

## Ephemerality

Every VM boots from a read-only system image with a throwaway qcow2 overlay in
`/var/lib/homewort-v2-vm-<n>/`. The unit deletes it both in `ExecStartPre` and in
`ExecStopPost`, so a start always begins from the pristine image and a released
slot gives its disk back immediately, however it was stopped. The allocator
deliberately does not touch the overlay itself: it runs inside chall-manager's
mount namespace, where `/var/lib` is read-only apart from
`/var/lib/homewort-v2-slots`. `Restart=always` covers a player who bricks or
powers off their box: the slot is still theirs, so it comes back with the same
flag.

chall-manager destroys instances on a correct flag submission
(`destroy_on_flag`) or, at the latest, when the 60-minute timeout expires. Its
janitor runs `homewort-v2-instance destroy` and frees the slot.

One consequence of on-demand slots: the VM units have no `wantedBy`, so nothing
starts them at boot. After a host reboot the state in `/var/lib` still records
who owns which slot, but the guests are gone. Bring a claimed slot back with
`systemctl start homewort-v2-vm-<n>` (the flag is unchanged) or let
chall-manager's janitor time the instances out.

## Flag

Each claim mints its own flag: 32 hex characters from `openssl rand`, put
through `flagFormat` (default `nixcon{homewort_v2_%s}`, distinct from v1's so a
submission cannot be mistaken for the other challenge's). It never reaches a
clan var and never reaches the Nix store. It lives in
`/var/lib/homewort-v2-slots/<n>/flag`, mode `0400`, and in chall-manager's
database.

That file is passed to the VM through QEMU's `fw_cfg` device and installed by the
guest's `ctf-flag.service` as `/etc/flag`, mode `0600`, owned by root.

The indirection is the point: `fw_cfg` blobs are root-only in the guest, and a
flag put into a NixOS option like `environment.etc` would end up world readable
in `/nix/store`, which would make the privilege escalation pointless.

## Login

Players log in as `friend` with the clan var `homewort-v2-login/password`, a
three-word passphrase generated on first use. It is a generator of its own, not
shared with `homewort`: the two challenges hand out different boxes and must
hand out different passwords. The password is public on purpose: the allocator
bakes it into `connection_info`, which CTFd shows to the player. Only its
yescrypt hash reaches the machine, baked into the system image.

```console
clan vars generate ctf-machine --generator homewort-v2-login
clan vars get ctf-machine homewort-v2-login/password
```

The guests keep `mutableUsers = true`, so the account is created with that hash
on first boot and later activations leave `/etc/shadow` alone: a player's own
in-guest rebuild does not reset the password, even though the challenge repo
declares `friend` for local runs.

Rotating it needs a regenerate plus a deploy, which rebuilds the image:

```console
clan vars generate ctf-machine --generator homewort-v2-login --regenerate
```

## Network

The guests run with QEMU's `restrict=on`, so the VMs have no outbound access: a
rooted challenge box cannot reach the internet or the rest of the host's
network. Because of that, this service images the challenge flake's `mus-vm`. It
pins the guest's `/etc/nixos` flake inputs to Nix store paths and seeds the
store with what an offline rebuild has to build, so the intended solve step
works without egress. Installing additional packages inside the VM does not
work, which is expected.

`restrict=on` also drops the guest's replies to any client address other than
slirp's own host alias, and slirp only rewrites loopback clients to that alias.
A player connecting from outside would complete the TCP handshake against slirp
and then wait forever for the SSH banner. QEMU therefore forwards the guest's
SSH port to `127.0.0.1:<internalBasePort + n - 1>`, and the public port is
served by a `systemd-socket-proxyd` unit (`homewort-v2-vm-<n>-ssh.socket`) that
reaches the guest over loopback.

That loopback port is also how `create` decides a VM is ready: it reads the SSH
banner off it. A completed connect proves nothing, because QEMU binds the
forwarded port the moment the VM process starts.

With `maxSlots = 14` this pool owns public TCP **2301-2314** and loopback
**42301-42314**, a hundred above `homewort`'s 2201-2240 and 42201-42240, which
leaves both ranges room to grow before they meet. The public ports are open in
the firewall for every slot, claimed or not. An unclaimed slot's proxy socket
accepts and then finds no guest, which is exactly what a player sees when they
guess a port that is not theirs.

## Capacity

`maxSlots` is a hard cap on concurrent instances, not a soft limit: every
claimed slot runs a real VM, and this pool is the second one on the host.

The pool runs fourteen slots against v1's forty, because the v1 pool is the one
most players reach. The host is an AMD EPYC 7502P (32 cores / 64 threads,
251 GiB). Both pools together declare 40 x 4 GiB + 14 x 4 GiB = 216 GiB of
`memorySize`, plus 10 GiB for the `baas` and `rtunreal` VMs, which leaves
~25 GiB for the host even if every guest touches its full ceiling. Nothing is
overcommitted. Measured on this host with all 54 guests of both pools claimed
and rebuilding at once: every rebuild succeeded, `rebuildHome-friend` took
59 s alone and ~120 s in the storm, and the pools peaked at 130 GiB RSS with
118 GiB still available, so the realistic peak sits far below the ceiling.

A v2 guest is no more expensive than a v1 one despite rebuilding the whole
system rather than one home: 2.38 GiB against v1's measured 2.4 GiB. The
smaller pool reflects demand, not a more expensive guest.

If host RAM ever gets tight, lower `maxSlots` here rather than on v1: this pool
is the one fewer players hold.

CPU is the softer limit, as on v1: 54 guests at 2 vCPUs are 108 vCPUs on 64
threads, idle guests cause no measurable CPU pressure, and the 54-way rebuild
storm peaked at 27 % CPU pressure (avg10). `readyTimeout` covers the guest's
boot, not a player's rebuild.

Exhaustion is neither queued nor pooled. The fifteenth player's deploy fails,
visibly, in the CTFd UI. Nothing silently hands two players the same box. CTFd
runs in `user_mode = users` on this deployment, so a slot is claimed per player,
not per team. Throughput over an event is the other half of the sum: a slot is
only freed by a flag submission or by the timeout, so shortening the timeout
buys more turns per hour than adding slots does.

The host must have KVM (`/dev/kvm`). The VM services run as the unprivileged
`homewort-v2` user in the `kvm` group.

## The Pulumi scenario

chall-manager deploys an instance by running a Pulumi program it pulls from the
host's own OCI registry. That program is built by `packages.homewort-v2-scenario`
and pushed by `homewort-v2-scenario-push.service`, a oneshot ordered after
`chall-manager-registry.service`:

```text
127.0.0.1:5000/homewort-v2:0.1.0
```

Its Pulumi project is named `homewort-v2` and it reads its identity from the
stack config key `homewort-v2:identity`, which is why the project name in
`Pulumi.yaml` and the `config.New` namespace in `main.go` have to agree:
chall-manager namespaces that key by project.

The Go module path is shared with `../homewort/scenario`, and `go.mod`/`go.sum`
are byte-identical copies, so both scenarios keep the same `vendorHash`. The
built binary therefore still lands at `$out/bin/homewort-scenario` before
`postInstall` renames it to `main`.

The artifact is not a tarball. chall-manager's loader pulls it with an oras-go
file store and then stats `Pulumi.yaml` and `main` in the download directory, so
the push sends one layer per file, media type `application/vnd.ctfer-io.file`,
titled by its path relative to the scenario root, under artifact type
`application/vnd.ctfer-io.scenario`.

The tag is the scenario package's `version`, bumped by hand: the operator pastes
the reference into the CTFd challenge once, so it must not move when an
unrelated rebuild changes a store hash. After bumping it, redeploy (the push
unit runs on activation) and update the challenge's scenario field. The unit
echoes the reference it pushed:

```console
journalctl -u homewort-v2-scenario-push
```

## Usage

```nix
inventory.instances.homewort-v2 = {
  module = {
    name = "homewort-v2";
    input = "self";
  };
  roles.server.machines.ctf-machine = { };
  roles.server.settings = {
    publicHost = "ctf.nixcon.org";
    maxSlots = 14;               # shares the host with homewort's 40 slots
    # basePort = 2301;           # public SSH port of the first slot
    # internalBasePort = 42301;  # loopback port QEMU forwards to
    # memorySize = 4096;   # MiB per VM, a rebuild inside the VM needs a few GiB
    # cores = 2;
    # diskSize = 36864;    # MiB, sparse upper bound
    # flagFormat = "nixcon{homewort_v2_%s}";
    # allowUser = "chall-manager";  # null installs no sudo rule
    # readyTimeout = 180;  # seconds `create` waits for the guest's SSH banner
  };
};
```

chall-manager's own instance needs this pool's state directory in its
`scenarioWritePaths`, next to v1's, or the allocator hits EROFS inside its mount
namespace:

```nix
scenarioWritePaths = [
  "/var/lib/homewort-slots"
  "/var/lib/homewort-v2-slots"
];
```

## Registering the challenge in CTFd

The scoreboard is a separate service (see `../ctfd`), and challenges are created
in its admin UI (`https://ctf.nixcon.org/admin/challenges`). Like `homewort`,
this one needs the `ctfd-chall-manager` plugin.

- **Category**: `pwn` (or `nix`)
- **Name**: `homewort-v2`
- **Value**: dynamic, `initial = 750`, `decay = 20`, `minimum = 150`,
  `logarithmic`. The author rates it at the harder end of medium, the easier
  end of hard, so it sits above `homewort`'s 500
- **Type**: `dynamic_iac`
- **Scenario**: `127.0.0.1:5000/homewort-v2:0.1.0`
- **Timeout**: `3600` (60 minutes), after which the janitor destroys the
  instance. The timeout is longer than v1's 45 minutes because a solve here
  starts from a full offline `nixos-rebuild`, which alone costs the player a
  minute per attempt
- **Destroy on flag**: on, so a solved instance frees its slot immediately
- **Mana cost**: `0`, because mana is disabled on this deployment
- **Shared**: off, because every player needs an instance of their own
- **Flag**: none. The scenario reports the instance's own flag to chall-manager,
  which checks submissions against it.
- **Prerequisite**: `homewort`. The challenge is deployed with that
  requirement, which also answers the challenge author's worry about the
  published `payload/` directory: only a player who already solved v1 sees v2
  at all.
- **Description**:

  ```text
  MUS shipped the home-manager feature again. This time they patched the hole
  you walked through in `homewort`.

  Click "deploy" to get your own machine. The connection details, including the
  password, show up here once it is up. Give it a minute to boot.

  The box has no internet access and is yours alone for 60 minutes. The flag is
  `/etc/flag`, which only root can read.

  `sudo rebuildHome-friend` rebuilds the system from the config in your home
  directory, and `sudo systemctl start home-manager-friend.service` runs your
  activation. Adding new packages will not work: there is nothing to fetch them
  from.
  ```

Hints are the author's call and are not written down here: this service hosts
the challenge but does not know the solve.

Before making the challenge visible, deploy an instance from the admin UI and
verify the box is reachable from outside with the port and password it printed:

```console
ssh friend@ctf.nixcon.org -p 2301
```

Then destroy it again, so the first player gets slot one.
