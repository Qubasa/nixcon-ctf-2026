# xin

Hosts the [`xin`](https://git.immutable-byte.de/nixcon-ctf/xin) challenge: a
NixOS box where the player logs in as the unprivileged `friend` and has to find
the flag pieces that the system configuration dropped into `/nix/store`.

The plumbing is a fork of [`homewort-v2`](../homewort-v2) with its own names, so
read that README for the details of the allocator, the ephemeral overlays, the
loopback proxy, and the Pulumi scenario. This one lists what differs.

## Why a VM per player

The flag is static, so a pool is not needed to keep flags apart. It is needed
because every player shares the `friend` account: on one shared box the first
player to run `passwd` locks everybody else out, and any player can kill the
others' sessions. Each claim therefore gets its own VM, as with `homewort`:

- slot `n` runs `xin-vm-<n>` and accepts SSH on `basePort + n - 1`
  (default 2501-…, loopback 42501-…)
- the guest logs in as `friend` with the generated `xin-login/password`
- the allocator is `xin-instance`, with the same verbs and exit codes as
  `homewort-v2-instance`, and its state lives in `/var/lib/xin-slots`

## Flag

The flag is the one the challenge author wrote into `xin.nix`. It is not
minted per claim, so the allocator prints no `flag` field and the scenario
exports only `connection_info`. CTFd checks submissions against a static flag
on the challenge instead. The ctfd-chall-manager plugin still refuses a
submission while the player has no running instance.

The flag pieces are `writeTextFile` packages in `environment.systemPackages`
whose files sit outside every linked directory. `system-path` therefore does
not reference them, and a disk image built from the system closure would not
contain them. The service adds `environment.systemPackages` to
`system.extraDependencies` of the guest so the files are in its store.

## Guest

The image is the challenge flake's `nixosConfigurations.xin` as
`vmWithBootLoader`, with QEMU's `restrict=on` (no egress), 1 GiB and one vCPU
by default. The root filesystem is the image's own size and is not grown: the
solve only reads files.

## Usage

```nix
inventory.instances.xin = {
  module = {
    name = "xin";
    input = "self";
  };
  roles.server.machines.ctf-machine = { };
  roles.server.settings = {
    publicHost = "ctf.nixcon.org";
    maxSlots = 20;
    # basePort = 2501;
    # internalBasePort = 42501;
    # memorySize = 1024;
    # cores = 1;
    # allowUser = "chall-manager";
    # readyTimeout = 180;
  };
};
```

chall-manager's `scenarioWritePaths` must contain `/var/lib/xin-slots`.

The login password is a clan var:

```console
clan vars generate ctf-machine --generator xin-login
clan vars get ctf-machine xin-login/password
```

## Registering the challenge in CTFd

Create it in the admin UI (`https://ctf.nixcon.org/admin/challenges`):

- **Category**: `Forensics`
- **Name**: `xin`
- **Value**: dynamic, `initial = 200`, `decay = 20`, `minimum = 50`,
  `logarithmic`, the same entry value as the other easy challenges
- **Type**: `dynamic_iac`
- **Scenario**: `127.0.0.1:5000/xin:0.1.0`
- **Timeout**: `1800` (30 minutes)
- **Destroy on flag**: on
- **Mana cost**: `0`
- **Shared**: off
- **Flag**: static, case-sensitive, the string `xin.nix` spells out. The
  scenario reports no flag, so without this one nothing can be solved.
- **Description**:

  ```text
  Find the flag on your own X I N box. Deploy an instance and ssh in with the
  credentials shown.

  The box has no internet access and is yours alone for 30 minutes.
  ```

Before making it visible, deploy an instance from the admin UI, log in with
the printed port and password, check the flag files are there, and destroy it
again.
