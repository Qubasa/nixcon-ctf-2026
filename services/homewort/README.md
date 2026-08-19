# homewort

Hosts the [`homewort`](https://git.immutable-byte.de/nixcon-ctf/homewort) CTF
challenge: a NixOS box where the player may only edit their own home-manager
configuration and has to escalate to root from there.

Each player needs their own machine — solving the challenge means rebuilding the
system as root — so this service runs a pool of independent QEMU VMs:

- `homewort-vm-1` … `homewort-vm-N` — one systemd service per VM
- VM `n` forwards host port `basePort + n - 1` to the guest's SSH port
- the guest logs in as `friend` with password `friend`

## Ephemerality

Every VM boots from a read-only system image with a throwaway qcow2 overlay in
`/var/lib/homewort-vm-<n>/`. The overlay is deleted in `ExecStartPre`, so any
restart returns the VM to a pristine state. `Restart=always` covers players who
brick or power off their box, and `resetInterval` (default `30min`) restarts
every VM on a timer so abandoned or broken instances return to the pool.

## Flag

The flag is the operator-prompted clan var `homewort/flag` (machine
`ctf-machine`). It is passed to each VM through QEMU's `fw_cfg` device and
installed by the guest's `ctf-flag.service` as `/etc/flag`, mode `0600`, owned by
root.

This indirection is the point: `fw_cfg` blobs are root-only in the guest, and a
flag put into a NixOS option like `environment.etc` would end up world readable
in `/nix/store`, making the privilege escalation pointless.

Set it before the first deploy:

```console
clan vars generate ctf-machine --generator homewort
```

Rotating the flag (`clan vars set ctf-machine homewort/flag`) restarts all VMs.

## Network

The guests run with QEMU's `restrict=on`: the forwarded SSH port works, but the
VMs have no outbound access — a rooted challenge box cannot reach the internet or
the rest of the host's network. Because of that the guest's `/etc/nixos` flake
pins its inputs to Nix store paths, so `sudo rebuildHome` works offline.
Installing additional packages inside the VM does not work, which is expected.

## Usage

```nix
inventory.instances.homewort = {
  module = {
    name = "homewort";
    input = "self";
  };
  roles.server.machines.ctf-machine = { };
  roles.server.settings = {
    instances = 6;
    # basePort = 2201;
    # memorySize = 4096;   # MiB per VM; a rebuild inside the VM needs a few GiB
    # cores = 2;
    # diskSize = 12288;    # MiB, sparse upper bound
    # resetInterval = "30min";   # null disables the reset timer
  };
};
```

Budget roughly `memorySize` × `instances` of RAM plus the growth of the overlays
in `/var/lib`. The host must have KVM (`/dev/kvm`); the VM services run as the
unprivileged `homewort` user in the `kvm` group.

## Registering the challenge in CTFd

The scoreboard is a separate service (see `../ctfd`); challenges are created in
its admin UI (`https://ctf.immutable-byte.de/admin/challenges`). For this
challenge:

- **Category**: `pwn` (or `nix`)
- **Name**: `homewort`
- **Value**: ~200 (author rates it "easier end of medium")
- **Type**: standard, flag type static, case sensitive
- **Flag**: the same string as the `homewort/flag` clan var
- **Description**:

  ```text
  MUS, the Multi-User System, just shipped a new feature: users may customise
  their own environment through home-manager. Log in and see for yourself.

  ssh friend@ctf.immutable-byte.de -p <2201-2206>   (password: friend)

  Pick any port from the range; each one is your own machine. The box has no
  internet access, resets every 30 minutes, and the flag is /etc/flag, which
  only root can read.
  ```

- **Hints** (optional, cost some points): "`sudo rebuildHome` runs
  home-manager's activation for the user named in the config it is given."

Verify a VM is reachable from outside before making the challenge visible:

```console
ssh friend@ctf.immutable-byte.de -p 2201
```
