# The grading guest as a bootable QEMU image. Used by the clan module and
# exposed as `.#rtunreal-vm`, so the grader can be booted and poked at without
# deploying anything:
#
#   nix run .#rtunreal-vm
#   curl --data-binary @my.patch http://127.0.0.1:43002/verify
{
  pkgs,

  # The challenge source tree and the nixpkgs its flake.lock pins.
  src-rtunreal,
  challengeNixpkgs,

  port ? 3000,
  checkTimeout ? 600,
  totalTimeout ? 900,
  maxPatchBytes ? 512 * 1024,

  memorySize ? 6144,
  cores ? 4,
  diskSize ? 40960,

  # Loopback port the guest's runner is forwarded to. The clan module sets
  # this through `QEMU_NET_OPTS` on the unit instead, so it only applies to a
  # hand-started VM.
  hostPort ? 43002,

  # Extra NixOS modules for a hand-started guest: a probe unit, a debug
  # shell, a smaller disk. The clan module passes none.
  extraModules ? [ ],
}:
let
  # Evaluated from the caller's nixpkgs rather than a flake input: the guest is
  # part of this service, not of the challenge. `system` must be null, or
  # eval-config defaults it to `builtins.currentSystem` and the flake stops
  # evaluating purely.
  guest = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    system = null;
    inherit pkgs;
    modules = [
      (import ./guest.nix {
        inherit
          port
          src-rtunreal
          challengeNixpkgs
          checkTimeout
          totalTimeout
          maxPatchBytes
          ;
      })
      {
        virtualisation.vmVariantWithBootLoader.virtualisation = {
          graphics = false;
          # No egress. Submissions are arbitrary Nix, evaluated unsandboxed
          # and built with fixed-output derivations that run outside the build
          # sandbox's network namespace, so this is the only thing between a
          # player and the host's network, where chall-manager's
          # unauthenticated API listens.
          restrictNetwork = true;
          forwardPorts = [
            {
              from = "host";
              host.address = "127.0.0.1";
              host.port = hostPort;
              guest.port = port;
            }
          ];
          inherit memorySize cores diskSize;
        };
      }
    ]
    ++ extraModules;
  };
in
# `vmWithBootLoader`, not `vm`: it boots a disk image holding its own store,
# while the plain VM variant would 9p-mount the host's /nix/store into the
# guest, and a player's builder would then be free to read that store.
guest.config.system.build.vmWithBootLoader
