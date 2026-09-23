# homewort

Hosts the [`homewort`](https://git.immutable-byte.de/nixcon-ctf/homewort) CTF
challenge: a NixOS box where the player may only edit their own home-manager
configuration and has to escalate to root from there.

Each team needs their own machine, because solving the challenge means
rebuilding the system as root. Each team also needs their own flag, or the first
team to solve it could hand the string to everyone else. This service therefore
does not hand out a pool of identical boxes. It offers `maxSlots` empty slots
and lets [chall-manager](../chall-manager) claim one per team, on demand,
through the `homewort-instance` allocator:

- slot `n` runs the systemd service `homewort-vm-<n>`, started when it is
  claimed and stopped when it is released
- slot `n` accepts SSH on `basePort + n - 1` (see Network for how it gets there)
- slot `n` gets its own random flag, minted at claim time
- the guest logs in as `friend` with the generated `homewort-login/password`

Nobody operates this during the event. A team clicks "deploy" in CTFd and the
plugin asks chall-manager. chall-manager runs the Pulumi scenario, the scenario
runs `homewort-instance create`, and the team gets a port, a password, and 45
minutes. Solving it, or the timeout running out, releases the slot again.

## The allocator

`homewort-instance` is the entire seam between the VM host and chall-manager.
The Pulumi scenario knows nothing about systemd or qcow2. It runs

```console
/run/wrappers/bin/sudo -n /run/current-system/sw/bin/homewort-instance create --identity <ID>
```

and parses the single line of JSON on stdout:

```json
{"identity":"abc123","slot":3,"port":2203,"flag":"nixcon{homewort_<32 hex>}","connection_info":"ssh friend@ctf.nixcon.org -p 2203  (password: word-word-word)"}
```

`connection_info` and `flag` are what the scenario exports to chall-manager, and
from there into the team's challenge page.

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

The bookkeeping is a directory tree under `/var/lib/homewort-slots`, not a
database:

```text
/var/lib/homewort-slots/.lock          flock target that serialises the claim only
/var/lib/homewort-slots/<n>/identity   presence == slot claimed
/var/lib/homewort-slots/<n>/flag       0400 homewort:homewort, fed to the guest
```

The lock is held for the claim and for teardown, never while `create` waits for
a guest to boot, so teams can deploy concurrently. The flag is written before
the identity file, so a crash in between leaves a free slot rather than a slot
with a stale flag.

`homewort-instance` is root-only. `security.sudo.extraRules` grants `allowUser`
(default `chall-manager`) `NOPASSWD` on exactly
`/run/current-system/sw/bin/homewort-instance` and nothing else. That path, not
the allocator's store path, is what the scenario hardcodes: it is the only one
that survives a rebuild.

You can drive it by hand for a smoke test:

```console
sudo homewort-instance create --identity smoketest
sudo homewort-instance list
sudo homewort-instance destroy --identity smoketest
```

The CLI's contract is covered by `checks.homewort-allocator`
(`allocator-test.nix`), which runs it against a stub `systemctl` and a stub
readiness probe, so it needs neither KVM nor root.

## Ephemerality

Every VM boots from a read-only system image with a throwaway qcow2 overlay in
`/var/lib/homewort-vm-<n>/`. The unit deletes it both in `ExecStartPre` and in
`ExecStopPost`, so a start always begins from the pristine image and a released
slot gives its disk back immediately, however it was stopped. The allocator
deliberately does not touch the overlay itself: it runs inside chall-manager's
mount namespace, where `/var/lib` is read-only apart from
`/var/lib/homewort-slots`. `Restart=always` covers a player who bricks or
powers off their box: the slot is still theirs, so it comes back with the same
flag.

The service has no reset timer any more. Instances do not have to be recycled
blindly, because chall-manager destroys them on a correct flag submission
(`destroy_on_flag`) or, at the latest, when the 45-minute timeout expires. Its
janitor sweeps expired instances by running `homewort-instance destroy`, which
frees the slot.

One consequence of on-demand slots: the VM units have no `wantedBy`, so nothing
starts them at boot. After a host reboot the state in `/var/lib` still records
who owns which slot, but the guests are gone. Bring a claimed slot back with
`systemctl start homewort-vm-<n>` (the flag is unchanged) or let
chall-manager's janitor time the instances out.

## Flag

Each claim mints its own flag: 32 hex characters from `openssl rand`, put
through `flagFormat` (default `nixcon{homewort_%s}`). It never reaches a clan
var and never reaches the Nix store. It lives in
`/var/lib/homewort-slots/<n>/flag`, mode `0400`, and in chall-manager's
database.

That file is passed to the VM through QEMU's `fw_cfg` device and installed by the
guest's `ctf-flag.service` as `/etc/flag`, mode `0600`, owned by root.

The indirection is still the point, even now that the flag is per instance:
`fw_cfg` blobs are root-only in the guest, and a flag put into a NixOS option
like `environment.etc` would end up world readable in `/nix/store`, which would
make the privilege escalation pointless.

## Login

Players log in as `friend` with the clan var `homewort-login/password`, a
three-word passphrase generated on first use. It is public on purpose: the
allocator bakes it into `connection_info`, which CTFd shows to the team. Only
its yescrypt hash reaches the machine, baked into the system image.

```console
clan vars generate ctf-machine --generator homewort-login
clan vars get ctf-machine homewort-login/password
```

The guests keep `mutableUsers = true`, so the account is created with that hash
on first boot and later activations leave `/etc/shadow` alone: a player's own
`sudo rebuildHome`, the intended solve step, does not reset the password, even
though the challenge repo's own `mus.nix` declares `friend` for local runs.

Rotating it needs a regenerate plus a deploy, which rebuilds the image:

```console
clan vars generate ctf-machine --generator homewort-login --regenerate
```

## Network

The guests run with QEMU's `restrict=on`, so the VMs have no outbound access: a
rooted challenge box cannot reach the internet or the rest of the host's
network. Because of that, this service images the challenge flake's `mus-vm`. It
pins the guest's `/etc/nixos` flake inputs to Nix store paths and seeds the
store with what an offline rebuild has to build, so `sudo rebuildHome` works
without egress. Installing additional packages inside the VM does not work,
which is expected.

`restrict=on` also drops the guest's replies to any client address other than
slirp's own host alias, and slirp only rewrites loopback clients to that alias.
A player connecting from outside would complete the TCP handshake against slirp
and then wait forever for the SSH banner. QEMU therefore forwards the guest's
SSH port to `127.0.0.1:<internalBasePort + n - 1>`, and the public port is
served by a `systemd-socket-proxyd` unit (`homewort-vm-<n>-ssh.socket`) that
reaches the guest over loopback.

That loopback port is also how `create` decides a VM is ready: it reads the SSH
banner off it. A completed connect proves nothing, because QEMU binds the
forwarded port the moment the VM process starts.

The public ports `basePort … basePort + maxSlots - 1` are open in the firewall
for every slot, claimed or not. An unclaimed slot's proxy socket accepts and
then finds no guest, which is exactly what a player sees when they guess a port
that is not theirs.

## Capacity

`maxSlots` is a hard cap on concurrent instances, not a soft limit: every
claimed slot runs a real VM. Measured on this host (i7-7700, 4 cores / 8
threads, 64 GiB, KVM):

| Per claimed slot                 | Cost                                     |
| -------------------------------- | ---------------------------------------- |
| Idle, player just logged in      | 750 MiB RSS, ~0.16 of a hardware thread  |
| After one in-guest `rebuildHome` | 2.4 GiB RSS                              |
| qcow2 overlay after a session    | ~0.7 GiB (`diskSize` is a sparse bound)  |
| Cold claim to SSH banner         | ~31 s, even with all 12 booting at once  |
| `rebuildHome` wall time          | 46 s alone, 146 s with all 12 rebuilding |

RAM is the binding resource only in the worst case, where every guest touches
its full `memorySize`: 12 x 4 GiB leaves ~14 GiB for CTFd, chall-manager, and
page cache. Measured with 12 slots claimed and every guest rebuilding, the pool
sits at 29 GiB and the host keeps 33 GiB available. CPU is the softer limit: 12
idle guests already burn ~1.5 threads of 8, and a 12-way rebuild storm runs at
70 % CPU pressure without a single failure, because `readyTimeout` covers the
guest's boot, not a player's rebuild.

Exhaustion is neither queued nor pooled. The thirteenth team's deploy fails,
visibly, in the CTFd UI. Nothing silently hands two teams the same box. Since
CTFd runs in `user_mode = users` on this deployment, a slot is claimed per
player, not per team, so `maxSlots` is the number of players who can hold a box
at the same instant. Throughput over an event is the other half of the sum: a
slot is only freed by a flag submission or by the timeout, so shortening the
timeout buys more turns per hour than adding slots does.

The host must have KVM (`/dev/kvm`). The VM services run as the unprivileged
`homewort` user in the `kvm` group.

## The Pulumi scenario

chall-manager deploys an instance by running a Pulumi program it pulls from the
host's own OCI registry. That program is built by `packages.homewort-scenario`
and pushed by `homewort-scenario-push.service`, a oneshot ordered after
`chall-manager-registry.service`:

```text
127.0.0.1:5000/homewort:0.1.0
```

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
journalctl -u homewort-scenario-push
```

## Usage

```nix
inventory.instances.homewort = {
  module = {
    name = "homewort";
    input = "self";
  };
  roles.server.machines.ctf-machine = { };
  roles.server.settings = {
    maxSlots = 12;
    publicHost = "ctf.nixcon.org";
    # basePort = 2201;           # public SSH port of the first slot
    # internalBasePort = 42201;  # loopback port QEMU forwards to
    # memorySize = 4096;   # MiB per VM, a rebuild inside the VM needs a few GiB
    # cores = 2;
    # diskSize = 36864;    # MiB, sparse upper bound
    # flagFormat = "nixcon{homewort_%s}";
    # allowUser = "chall-manager";  # null installs no sudo rule
    # readyTimeout = 180;  # seconds `create` waits for the guest's SSH banner
  };
};
```

## Registering the challenge in CTFd

The scoreboard is a separate service (see `../ctfd`), and challenges are created
in its admin UI (`https://ctf.nixcon.org/admin/challenges`). This one is no
longer a static-flag challenge: it needs the `ctfd-chall-manager` plugin.

- **Category**: `pwn` (or `nix`)
- **Name**: `homewort`
- **Value**: `500` (the author rates it "easier end of medium")
- **Type**: `dynamic_iac`
- **Scenario**: `127.0.0.1:5000/homewort:0.1.0`
- **Timeout**: `2700` (45 minutes), after which the janitor destroys the
  instance
- **Destroy on flag**: on, so a solved instance frees its slot immediately
- **Mana cost**: `0`, because mana is disabled on this deployment
- **Shared**: off, because every player needs an instance of their own
- **Flag**: none. The scenario reports the instance's own flag to chall-manager,
  which checks submissions against it.
- **Description**:

  ```text
  Escalate to root in your own NixOS box. Deploy an instance, ssh in with the
  credentials shown, and read `/etc/flag`.
  ```

- **Hints** (optional, cost some points): "`sudo rebuildHome` runs
  home-manager's activation for the user named in the config it is given."

Before making the challenge visible, deploy an instance from the admin UI and
verify the box is reachable from outside with the port and password it printed:

```console
ssh friend@ctf.nixcon.org -p 2201
```

Then destroy it again, so team one gets slot one.
