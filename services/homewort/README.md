# homewort

Hosts the [`homewort`](https://git.immutable-byte.de/nixcon-ctf/homewort) CTF
challenge: a NixOS box where the player may only edit their own home-manager
configuration and has to escalate to root from there.

Each player needs their own machine — solving the challenge means rebuilding the
system as root — so this service runs a pool of independent QEMU VMs:

- `homewort-vm-1` … `homewort-vm-N` — one systemd service per VM
- VM `n` accepts SSH on `basePort + n - 1` (see Network for how it gets there)
- the guest logs in as `friend` with the generated `homewort-login/password`

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

## Login

Players log in as `friend` with the clan var `homewort-login/password`, a
three-word passphrase generated on first use. It is public on purpose: it goes
into the challenge description. Only its yescrypt hash reaches the machine,
baked into the system image.

```console
clan vars generate ctf-machine --generator homewort-login
clan vars get ctf-machine homewort-login/password
```

The guests keep `mutableUsers = true`, so the account is created with that hash
on first boot and later activations leave `/etc/shadow` alone: a player's own
`sudo rebuildHome` - the intended solve step - does not reset the password, even
though the challenge repo's own `mus.nix` declares `friend` for local runs.

Rotating it needs a regenerate plus a deploy, which rebuilds the image and
restarts every VM:

```console
clan vars generate ctf-machine --generator homewort-login --regenerate
```

## Network

The guests run with QEMU's `restrict=on`: the VMs have no outbound access - a
rooted challenge box cannot reach the internet or the rest of the host's
network. Because of that this service images the challenge flake's `mus-vm`,
which pins the guest's `/etc/nixos` flake inputs to Nix store paths and seeds the
store with what an offline rebuild has to build, so `sudo rebuildHome` works
without egress. Installing additional packages inside the VM does not work,
which is expected.

`restrict=on` also drops the guest's replies to any client address other than
slirp's own host alias, and slirp only rewrites loopback clients to that alias.
A player connecting from outside would complete the TCP handshake against slirp
and then wait forever for the SSH banner. So QEMU forwards the guest's SSH port
to `127.0.0.1:<internalBasePort + n - 1>`, and the public port is served by a
`systemd-socket-proxyd` unit (`homewort-vm-<n>-ssh.socket`) that reaches the
guest over loopback.

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
    # basePort = 2201;           # public SSH port of the first VM
    # internalBasePort = 42201;  # loopback port QEMU forwards to
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

  ssh friend@ctf.immutable-byte.de -p <2201-2206>   (password: <homewort-login/password>)

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
