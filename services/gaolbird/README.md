# gaolbird

Hosts the `gaolbird` challenge series: four increasingly restrictive nix repls
a player must escape to read `/etc/flag`. Stage 1 is the loosest sandbox and
stage 4 the tightest; the actual restrictions and escapes live in the
challenge's own flake, not here. This service only plumbs each stage onto the
CTF host the same way [`homewort`](../homewort) does: an on-demand pool of
ephemeral QEMU VMs, one forwarded SSH port and one freshly minted flag per
claim, handed out by chall-manager through a small allocator CLI.

Each stage is a separate instantiation of this module, distinguished by the
`challengeStage` setting (`1`-`4`). Instantiating it twice with the same
`challengeStage` on the same machine is not supported: the slot directory,
VM/proxy unit names, sudo rule, and allocator binary are all namespaced by
`challengeStage`, not by the inventory instance name.

Each team needs their own machine, because escaping the repl means altering
what the box will do next. Each team also needs their own flag, or the first
team to escape a stage could hand the string to everyone else. This service
therefore does not hand out a pool of identical boxes. It offers `maxSlots`
empty slots per stage and lets [chall-manager](../chall-manager) claim one per
team, on demand, through the `gaolbird-<challengeStage>-instance` allocator:

- slot `n` of stage `s` runs the systemd service `gaolbird-<s>-vm-<n>`,
  started when it is claimed and stopped when it is released
- slot `n` accepts SSH on `basePort + n - 1` (see Network for how it gets there)
- slot `n` gets its own random flag, minted at claim time, formatted with
  that stage's `flagFormat`
- the guest logs in as `gaolbird` with the generated
  `gaolbird-<challengeStage>-login/password`

Nobody operates this during the event. A team clicks "deploy" on a stage's
challenge in CTFd and the plugin asks chall-manager. chall-manager runs that
stage's Pulumi scenario, the scenario runs `gaolbird-<challengeStage>-instance
create`, and the team gets a port, a password, and however long the CTFd
challenge's timeout allows. Solving it, or the timeout running out, releases
the slot again.

## The allocator

`gaolbird-<challengeStage>-instance` is the entire seam between the VM host
and chall-manager for that stage. The Pulumi scenario knows nothing about
systemd or qcow2. It runs

```console
/run/wrappers/bin/sudo -n /run/current-system/sw/bin/gaolbird-<challengeStage>-instance create --identity <ID>
```

and parses the single line of JSON on stdout:

```json
{"identity":"abc123","slot":3,"port":2203,"flag":"nixcon{gaolbird-1_<32 hex>}","connection_info":"ssh gaolbird@ctf.immutable-byte.de -p 2203  (password: word-word-word)"}
```

`connection_info` and `flag` are what the scenario exports to chall-manager,
and from there into the team's challenge page.

| verb                      | behaviour                                                                   |
| ------------------------- | --------------------------------------------------------------------------- |
| `create --identity <ID>`  | Claims a slot, starts the VM, waits for its SSH banner, and prints the JSON |
| `destroy --identity <ID>` | Stops the VM, wipes the flag, frees the slot, and prints nothing            |
| `status --identity <ID>`  | Prints the same JSON for an already claimed identity                        |
| `list`                    | Prints a JSON array of every claimed slot                                   |

Every verb is idempotent: `create` run twice for the same identity reprints
the same JSON (same slot, same flag), and `destroy` succeeds for an identity
that never existed. chall-manager retries, so the idempotency is load bearing.

Exit codes are the contract with the scenario:

| code | meaning                                                                               |
| ---- | ------------------------------------------------------------------------------------- |
| `0`  | Success                                                                               |
| `2`  | Malformed identity (the charset is `[a-z0-9]{1,64}`) or a usage error                 |
| `3`  | `status` for an identity that holds no slot                                           |
| `4`  | No free slot: the pool is not overbooked, and the deploy fails in CTFd instead        |
| `5`  | The VM did not become reachable within `readyTimeout`, and the slot is released again |

The bookkeeping is a directory tree under `/var/lib/gaolbird-<challengeStage>-slots`,
not a database:

```text
/var/lib/gaolbird-<challengeStage>-slots/.lock          flock target that serialises the claim only
/var/lib/gaolbird-<challengeStage>-slots/<n>/identity   presence == slot claimed
/var/lib/gaolbird-<challengeStage>-slots/<n>/flag       0400 gaolbird:gaolbird, fed to the guest
```

The lock is held for the claim and for teardown, never while `create` waits
for a guest to boot, so teams can deploy concurrently. The flag is written
before the identity file, so a crash in between leaves a free slot rather than
a slot with a stale flag.

`gaolbird-<challengeStage>-instance` is root-only. `security.sudo.extraRules`
grants `allowUser` (default `chall-manager`) `NOPASSWD` on exactly
`/run/current-system/sw/bin/gaolbird-<challengeStage>-instance` and nothing
else. That path, not the allocator's store path, is what the scenario
hardcodes: it is the only one that survives a rebuild.

You can drive it by hand for a smoke test:

```console
sudo gaolbird-1-instance create --identity smoketest
sudo gaolbird-1-instance list
sudo gaolbird-1-instance destroy --identity smoketest
```

## Ephemerality

Every VM boots from a read-only system image with a throwaway qcow2 overlay
in `/var/lib/gaolbird-<challengeStage>-vm-<n>/`. The unit deletes it both in
`ExecStartPre` and in `ExecStopPost`, so a start always begins from the
pristine image and a released slot gives its disk back immediately, however it
was stopped. The allocator deliberately does not touch the overlay itself: it
runs inside chall-manager's mount namespace, where `/var/lib` is read-only
apart from the slot directories. `Restart = "always"` covers a player who
bricks or powers off their box: the slot is still theirs, so it comes back
with the same flag.

Instances are not recycled blindly: chall-manager destroys them on a correct
flag submission (`destroy_on_flag`) or, at the latest, when the challenge's
timeout expires. Its janitor sweeps expired instances by running
`gaolbird-<challengeStage>-instance destroy`, which frees the slot.

One consequence of on-demand slots: the VM units have no `wantedBy`, so
nothing starts them at boot. After a host reboot the state in `/var/lib` still
records who owns which slot, but the guests are gone. Bring a claimed slot
back with `systemctl start gaolbird-<challengeStage>-vm-<n>` (the flag is
unchanged) or let chall-manager's janitor time the instances out.

## Flag

Each claim mints its own flag: 32 hex characters from `openssl rand`, put
through that stage's `flagFormat` (default `nixcon{gaolbird-<challengeStage>_%s}`).
It never reaches a clan var and never reaches the Nix store. It lives in
`/var/lib/gaolbird-<challengeStage>-slots/<n>/flag`, mode `0400`, and in
chall-manager's database.

That file is passed to the VM through QEMU's `fw_cfg` device and installed by
the guest as `/etc/flag`, mode `0600`, owned by root. `fw_cfg` blobs are
root-only in the guest, and a flag put into a NixOS option like
`environment.etc` would end up world readable in `/nix/store`, which would
make the repl escape pointless.

## Login

Players log in as `gaolbird` with the clan var
`gaolbird-<challengeStage>-login/password`, a three-word passphrase generated
on first use per stage. It is public on purpose: the allocator bakes it into
`connection_info`, which CTFd shows to the team. Only its yescrypt hash
reaches the machine, baked into the system image. The challenge repo's own
`gaolbird` password (`gaol.nix` or similar) is a default for running it
locally, not for a public box; this service always overrides it with the
generated hash.

Rotating a stage's password needs a regenerate plus a deploy, which rebuilds
that stage's image:

```console
clan vars generate ctf-machine --generator gaolbird-1-login --regenerate
```

## Network

Unlike `homewort`, these guests keep normal outbound network access: some
stages' intended solves need it. This service still images the challenge
flake's `gaol-vm`, which pins the guest's flake inputs to Nix store paths and
seeds the store with what an offline `nixos-rebuild switch` needs, so a
player's rebuild works even without reaching the internet — but the guest is
free to reach it for whatever a stage's solve requires.

Because the guest is not slirp-restricted, QEMU's ordinary hostfwd would
normally let an external client reach it directly. This service still
forwards guest SSH only to loopback (`internalBasePort + n - 1`) and serves
the public port through a `systemd-socket-proxyd` unit
(`gaolbird-<challengeStage>-vm-<n>-ssh.socket`), for consistency with
`homewort`'s proxy setup rather than out of network necessity. That loopback
port is also how `create` decides a VM is ready: it reads the SSH banner off
it, because a completed connect proves nothing when QEMU binds the forwarded
port the moment the VM process starts.

The public ports `basePort … basePort + maxSlots - 1` are open in the firewall
for every slot of that stage, claimed or not. Because every stage reuses the
same option defaults, stages deployed on the same machine need distinct
`basePort`/`internalBasePort` ranges (see Usage) or their port ranges collide.

## Capacity

`maxSlots` is a hard cap on concurrent instances per stage, not a soft limit:
every claimed slot runs a real VM, at the same per-VM cost as `homewort`
(see its README for measured numbers, since the underlying VM plumbing is
identical). `maxSlots × memorySize` per stage must still leave room for CTFd,
chall-manager, and every other stage running on the same host.

Exhaustion is neither queued nor pooled. A team's deploy fails, visibly, in
the CTFd UI, once a stage's slots are all claimed. The host must have KVM
(`/dev/kvm`). The VM services run as the unprivileged `gaolbird` user in the
`kvm` group.

## The Pulumi scenario

chall-manager deploys an instance of stage `s` by running a Pulumi program it
pulls from the host's own OCI registry. That program is built by
`scenario-<s>/package.nix` and pushed by
`gaolbird-<s>-scenario-push.service`, a oneshot ordered after
`chall-manager-registry.service`:

```text
127.0.0.1:5000/gaolbird-<s>:0.1.0
```

The artifact is not a tarball. chall-manager's loader pulls it with an
oras-go file store and then stats `Pulumi.yaml` and `main` in the download
directory, so the push sends one layer per file, media type
`application/vnd.ctfer-io.file`, titled by its path relative to the scenario
root, under artifact type `application/vnd.ctfer-io.scenario`.

The tag is the scenario package's `version`, bumped by hand: the operator
pastes the reference into the CTFd challenge once, so it must not move when
an unrelated rebuild changes a store hash. After bumping it, redeploy (the
push unit runs on activation) and update that stage's challenge's scenario
field. The unit echoes the reference it pushed:

```console
journalctl -u gaolbird-1-scenario-push
```

## Usage

Each stage is its own inventory instance, with its own port range so the four
stages don't collide on the same machine:

```nix
inventory.instances.gaolbird-1 = {
  module = {
    name = "gaolbird";
    input = "self";
  };
  roles.server.machines.ctf-machine = { };
  roles.server.settings = {
    challengeStage = 1;
    maxSlots = 8;
    publicHost = "ctf.immutable-byte.de";
    basePort = 2301;
    internalBasePort = 42301;
    # memorySize = 4096;   # MiB per VM
    # cores = 2;
    # diskSize = 36864;    # MiB, sparse upper bound
    # flagFormat = "nixcon{gaolbird-1_%s}";
    # allowUser = "chall-manager";  # null installs no sudo rule
    # readyTimeout = 180;  # seconds `create` waits for the guest's SSH banner
  };
};

inventory.instances.gaolbird-2 = {
  module = {
    name = "gaolbird";
    input = "self";
  };
  roles.server.machines.ctf-machine = { };
  roles.server.settings = {
    challengeStage = 2;
    maxSlots = 8;
    publicHost = "ctf.immutable-byte.de";
    basePort = 2309;
    internalBasePort = 42309;
  };
};

# ...and likewise gaolbird-3 (basePort 2317) and gaolbird-4 (basePort 2325),
# each with its own non-overlapping basePort/internalBasePort range sized to
# maxSlots.
```

## Registering the challenge in CTFd

The scoreboard is a separate service (see `../ctfd`), and challenges are
created in its admin UI (`https://ctf.immutable-byte.de/admin/challenges`).
Each stage is its own `dynamic_iac` challenge:

- **Category**: `nix` (or `pwn`)
- **Name**: `gaolbird-<s>`
- **Type**: `dynamic_iac`
- **Scenario**: `127.0.0.1:5000/gaolbird-<s>:0.1.0`
- **Destroy on flag**: on, so a solved instance frees its slot immediately
- **Mana cost**: `0`, because mana is disabled on this deployment
- **Shared**: off, because every player needs an instance of their own
- **Flag**: none. The scenario reports the instance's own flag to
  chall-manager, which checks submissions against it.

Before making a stage visible, deploy an instance from the admin UI and
verify the box is reachable from outside with the port and password it
printed, then destroy it again so team one gets slot one.
