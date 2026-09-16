# homewort-v2

Hosts the [`homewort-v2`](https://git.immutable-byte.de/nixcon-ctf/homewort-v2)
CTF challenge: the same premise as [`homewort`](../homewort) - a NixOS box where
the player may only edit their own home-manager configuration and has to
escalate to root from there - on a machine whose home-manager is not the one
upstream ships. The author rates it at the harder end of medium, the easier end
of hard, so it is meant to be attempted after the first one falls.

Everything in here is a fork of `../homewort` with its own names: the two pools
run side by side on `ctf-machine`, and a challenge that shares a unit name, a
state directory, a system user or a password with another challenge is one
rebuild away from handing two challenges the same box.

Each player needs their own machine - solving the challenge means rebuilding the
system as root - and each player needs their own flag, or the first solver could
hand the string to everyone else. So this service offers `maxSlots` empty slots
and lets [chall-manager](../chall-manager) claim one per player, on demand,
through the `homewort-v2-instance` allocator:

- slot `n` runs the systemd service `homewort-v2-vm-<n>`, started when it is
  claimed and stopped when it is released
- slot `n` accepts SSH on `basePort + n - 1` (see Network for how it gets there)
- slot `n` gets its own random flag, minted at claim time
- the guest logs in as `friend` with the generated `homewort-v2-login/password`

Nobody operates this during the event. A player clicks "deploy" in CTFd, the
plugin asks chall-manager, chall-manager runs the Pulumi scenario, the scenario
runs `homewort-v2-instance create`, and the player gets a port, a password and
60 minutes. Solving it, or the timeout running out, releases the slot again.

## The allocator

`homewort-v2-instance` is the entire seam between the VM host and chall-manager.
The Pulumi scenario knows nothing about systemd or qcow2; it runs

```console
/run/wrappers/bin/sudo -n /run/current-system/sw/bin/homewort-v2-instance create --identity <ID>
```

and parses the single line of JSON on stdout:

```json
{"identity":"abc123","slot":3,"port":2303,"flag":"nixcon{homewort_v2_<32 hex>}","connection_info":"ssh friend@ctf.nixcon.org -p 2303  (password: word-word-word)"}
```

`connection_info` and `flag` are what the scenario exports to chall-manager, and
from there into the player's challenge page.

| verb                      | behaviour                                                               |
| ------------------------- | ----------------------------------------------------------------------- |
| `create --identity <ID>`  | claims a slot, starts the VM, waits for its SSH banner, prints the JSON  |
| `destroy --identity <ID>` | stops the VM, wipes the flag, frees the slot, silent                     |
| `status --identity <ID>`  | prints the same JSON for an already claimed identity                     |
| `list`                    | JSON array of every claimed slot                                        |

Every verb is idempotent: `create` run twice for the same identity reprints the
same JSON — same slot, same flag — and `destroy` succeeds for an identity that
never existed. chall-manager retries, so this is load bearing.

Exit codes are the contract with the scenario:

| code | meaning                                                                          |
| ---- | -------------------------------------------------------------------------------- |
| `0`  | success                                                                          |
| `2`  | malformed identity (the charset is `[a-z0-9]{1,64}`) or a usage error             |
| `3`  | `status` for an identity that holds no slot                                      |
| `4`  | no free slot; the pool is not overbooked, the deploy fails in CTFd instead        |
| `5`  | the VM did not become reachable within `readyTimeout`; the slot is released again |

The bookkeeping is a directory tree under `/var/lib/homewort-v2-slots`, not a
database:

```text
/var/lib/homewort-v2-slots/.lock          flock target; serialises the claim only
/var/lib/homewort-v2-slots/<n>/identity   presence == slot claimed
/var/lib/homewort-v2-slots/<n>/flag       0400 homewort-v2:homewort-v2, fed to the guest
```

The lock is held for the claim and for teardown, never while `create` waits for
a guest to boot, so several players can deploy at the same time. The flag is
written before the identity file, so a crash in between leaves a free slot
rather than a slot with a stale flag.

`homewort-v2-instance` is root-only; `security.sudo.extraRules` grants
`allowUser` (default `chall-manager`) `NOPASSWD` on exactly
`/run/current-system/sw/bin/homewort-v2-instance` and nothing else. That path,
not the allocator's store path, is what the scenario hardcodes: it is the only
one that survives a rebuild.

Which systemd unit a slot maps to is a template of the allocator's `unitPrefix`
argument, not a literal, so this pool's `stop` and `start` can never land on
`../homewort`'s `homewort-vm-<n>` units, and the next fork of this service
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
(`destroy_on_flag`) and at the latest when the 45-minute timeout expires; its
janitor runs `homewort-v2-instance destroy` and frees the slot.

One consequence of on-demand slots: the VM units have no `wantedBy`, so nothing
starts them at boot. After a host reboot the state in `/var/lib` still records
who owns which slot, but the guests are gone. Bring a claimed slot back with
`systemctl start homewort-v2-vm-<n>` — the flag is unchanged — or let
chall-manager's janitor time the instances out.

## Flag

Each claim mints its own flag: 32 hex characters from `openssl rand`, put
through `flagFormat` (default `nixcon{homewort_v2_%s}`, distinct from v1's so a
submission cannot be mistaken for the other challenge's). It never reaches a
clan var and never reaches the Nix store; it lives in
`/var/lib/homewort-v2-slots/<n>/flag`, mode `0400`, and in chall-manager's
database.

That file is passed to the VM through QEMU's `fw_cfg` device and installed by the
guest's `ctf-flag.service` as `/etc/flag`, mode `0600`, owned by root.

The indirection is the point: `fw_cfg` blobs are root-only in the guest, and a
flag put into a NixOS option like `environment.etc` would end up world readable
in `/nix/store`, making the privilege escalation pointless.

## Login

Players log in as `friend` with the clan var `homewort-v2-login/password`, a
three-word passphrase generated on first use. It is a generator of its own, not
shared with `homewort`: the two challenges hand out different boxes and must
hand out different passwords. The password is public on purpose - the allocator
bakes it into `connection_info`, which CTFd shows to the player - and only its
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

The guests run with QEMU's `restrict=on`: the VMs have no outbound access - a
rooted challenge box cannot reach the internet or the rest of the host's
network. Because of that this service images the challenge flake's `mus-vm`,
which pins the guest's `/etc/nixos` flake inputs to Nix store paths and seeds the
store with what an offline rebuild has to build, so the intended solve step works
without egress. Installing additional packages inside the VM does not work,
which is expected.

`restrict=on` also drops the guest's replies to any client address other than
slirp's own host alias, and slirp only rewrites loopback clients to that alias.
A player connecting from outside would complete the TCP handshake against slirp
and then wait forever for the SSH banner. So QEMU forwards the guest's SSH port
to `127.0.0.1:<internalBasePort + n - 1>`, and the public port is served by a
`systemd-socket-proxyd` unit (`homewort-v2-vm-<n>-ssh.socket`) that reaches the
guest over loopback.

That loopback port is also how `create` decides a VM is ready: it reads the SSH
banner off it. A completed connect proves nothing, because QEMU binds the
forwarded port the moment the VM process starts.

With `maxSlots = 4` this pool owns public TCP **2301-2304** and loopback
**42301-42304**, a hundred above `homewort`'s 2201-2212 and 42201-42212, which
leaves both ranges room to grow before they meet. The public
ports are open in the firewall for every slot, claimed or not. An unclaimed
slot's proxy socket accepts and then finds no guest, which is exactly what a
player sees when they guess a port that is not theirs.

## Capacity

`maxSlots` is a hard cap on concurrent instances, not a soft limit: every
claimed slot runs a real VM, and this pool is the second one on the host.

Four slots, not the module's own default, because the twelve-slot v1 pool has
first claim on the machine's RAM. The two pools together declare
12 x 4 GiB + 4 x 4 GiB = 64 GiB of `memorySize` against the host's 62 GiB of
usable RAM, so they are deliberately overcommitted. That is sound because
`memorySize` is a per-guest ceiling, not a reservation. Measured on this host
for a v2 guest: 2.38 GiB RSS after a full in-guest `nixos-rebuild switch`,
which took 55 s offline and left a 660 MiB overlay. Four of those add roughly
10 GiB to the 29 GiB the v1 pool measured with all twelve guests rebuilding,
so the realistic worst case sits near 39 GiB and leaves the host over 20 GiB.

Note that a v2 guest is no more expensive than a v1 one despite rebuilding the
whole system rather than one home: 2.38 GiB against v1's measured 2.4 GiB. The
smaller pool buys headroom, not a cheaper guest.

The case that would not fit is all 16 slots claimed *and* every guest touching
its full 4 GiB at the same instant. If that ever looks likely, lower `maxSlots`
here rather than on v1: this pool is the one fewer players hold.

CPU is the softer limit, as on v1: guests are idle almost all the time and
`readyTimeout` covers the guest's boot, not a player's rebuild.

Exhaustion is neither queued nor pooled. The fifth player's deploy fails,
visibly, in the CTFd UI; nothing silently hands two players the same box. CTFd
runs in `user_mode = users` on this deployment, so a slot is claimed per player,
not per team. Throughput over an event is the other half of the sum: a slot is
only freed by a flag submission or by the timeout, so shortening the timeout
buys more turns per hour than adding slots does.

The host must have KVM (`/dev/kvm`); the VM services run as the unprivileged
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
unrelated rebuild changes a store hash. After bumping it, redeploy — the push
unit runs on activation — and update the challenge's scenario field. The unit
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
    maxSlots = 4;                # shares the host with homewort's 12 slots
    # basePort = 2301;           # public SSH port of the first slot
    # internalBasePort = 42301;  # loopback port QEMU forwards to
    # memorySize = 4096;   # MiB per VM; a rebuild inside the VM needs a few GiB
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

The scoreboard is a separate service (see `../ctfd`); challenges are created in
its admin UI (`https://ctf.nixcon.org/admin/challenges`). Like `homewort`, this
one needs the `ctfd-chall-manager` plugin.

- **Category**: `pwn` (or `nix`)
- **Name**: `homewort-v2`
- **Value**: dynamic, `initial = 750`, `decay = 20`, `minimum = 150`,
  `logarithmic` — the author rates it at the harder end of medium, the easier
  end of hard, so it sits above `homewort`'s 500
- **Type**: `dynamic_iac`
- **Scenario**: `127.0.0.1:5000/homewort-v2:0.1.0`
- **Timeout**: `3600` — 60 minutes, after which the janitor destroys the
  instance. Longer than v1's 45, because a solve here starts from a full
  offline `nixos-rebuild`, which alone costs the player a minute per attempt
- **Destroy on flag**: on; a solved instance frees its slot immediately
- **Mana cost**: `0`, mana is disabled on this deployment
- **Shared**: off. One instance per player is the whole point.
- **Flag**: none. The scenario reports the instance's own flag to chall-manager,
  which checks submissions against it.
- **Prerequisite**: `homewort`. Deployed with that requirement, which also
  answers the challenge author's worry about the published `payload/`
  directory: only a player who already solved v1 sees v2 at all.
- **Description**:

  ```text
  MUS, the Multi-User System, is back. The operators read the incident report
  from last time, took the obvious measures, and still let users customise
  their own environment through home-manager.

  Click "deploy" to get your own machine. The connection details, including the
  password, show up here once it is up; give it a minute to boot.

  The box has no internet access, it is yours alone for 60 minutes, and the
  flag is /etc/flag, which only root can read.
  ```

Hints are the author's call and are not written down here: this service hosts
the challenge, it does not know the solve.

Before making the challenge visible, deploy an instance from the admin UI and
verify the box is reachable from outside with the port and password it printed:

```console
ssh friend@ctf.nixcon.org -p 2301
```

Then destroy it again, so the first player gets slot one.
