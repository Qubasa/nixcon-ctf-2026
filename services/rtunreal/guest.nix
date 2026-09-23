# The grading guest: the check runner, a Nix daemon with no way out, and the
# pristine challenge tree it grades against. It is the containment boundary, so
# it holds no secret at all. The flag stays on the host, which only sees this
# guest's verdict. See ./README.md.
{
  port,
  src-rtunreal,
  challengeNixpkgs,
  checkTimeout,
  totalTimeout,
  maxPatchBytes,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  stateDir = "/var/lib/rtunreal";

  app = (pkgs.callPackage ./package.nix { }).builder;

  # The tree every submission starts from, and the tree `flake.nix` and
  # `flake.lock` are restored from once a patch applied. It is the same
  # derivation the host serves as a tarball.
  pristine = pkgs.callPackage ./source.nix { src = src-rtunreal; };

  # The challenge pins nixpkgs by tarball URL. This image ships that exact tree
  # and the runner overrides the input with it, because the guest has no egress
  # to fetch it with. Drift between the two is the one way this service can
  # break silently (every build would then fail on a missing path), so it
  # fails loudly at eval instead.
  lockedNixpkgs =
    (builtins.fromJSON (builtins.readFile "${src-rtunreal}/flake.lock")).nodes.nixpkgs.locked;

  guardedNixpkgs = lib.throwIf (lockedNixpkgs.narHash != challengeNixpkgs.narHash) ''
    rtunreal: the challenge's flake.lock pins nixpkgs
      ${lockedNixpkgs.narHash} (${lockedNixpkgs.url})
    but this flake's `rtunreal-nixpkgs` input is
      ${challengeNixpkgs.narHash}.
    The guest builds offline against the seeded copy, so a mismatch means every
    submission fails on paths that are not in the image. Point
    inputs.rtunreal-nixpkgs.url in flake.nix at the URL above and update
    flake.lock.
  '' challengeNixpkgs;

  cpkgs = guardedNixpkgs.legacyPackages.${system};

  # The pristine tree plus the answer key, evaluated exactly the way Nix would
  # evaluate the challenge flake: `outputs` is an ordinary function of its
  # inputs, and `self` is its own fixpoint. Deriving the seeds from the real
  # `checks` rather than a copy of them means a new check in the challenge
  # repo seeds its own build inputs on the next deploy.
  seedTree = pkgs.runCommand "rtunreal-seed-src" { } ''
    cp -r ${pristine} $out
    chmod -R u+w $out
    cp ${./solution/input-derivation.nix} $out/input-derivation.nix
  '';

  seedOutputs = (import "${seedTree}/flake.nix").outputs {
    self = seedOutputs;
    nixpkgs = guardedNixpkgs;
  };

  referenceChecks = builtins.attrValues seedOutputs.checks.${system};

  # Submissions build with no substituters and no egress, so a build can only
  # use what this image ships.
  #
  #  - the reference solution's checks, realised at image build time: proof
  #    that the challenge is solvable offline, and the exact closure a solution
  #    needs
  #  - their `inputDerivation`s, which add the build-time closure (stdenv, php,
  #    patch, the sources) so a *different* solution rebuilds fine
  #  - a generic tool list on top, deliberately not tailored to one solution
  buildSeeds =
    referenceChecks
    ++ map (drv: drv.inputDerivation) referenceChecks
    ++ (with cpkgs; [
      stdenv
      stdenvNoCC
      bash
      coreutils
      diffutils
      findutils
      gawk
      gnugrep
      gnupatch
      gnused
      gnutar
      gzip
      makeWrapper
      php85
      php85.packages.composer
      xz
    ])
    # The flake input the runner overrides `nixpkgs` with. Without the source
    # tree in the guest store there is nothing to evaluate the challenge
    # against.
    ++ [ guardedNixpkgs.outPath ];
in
{
  networking.hostName = "rtunreal";

  # slirp forwards exactly one port into this guest and the guest's own
  # firewall would drop it.
  networking.firewall.allowedTCPPorts = [ port ];

  # The guest boots through its own bootloader, so nothing puts the kernel on
  # the serial line by default and `journalctl -u rtunreal-vm` on the host
  # would show an empty screen after GRUB. The serial console is the only view
  # into a guest that fails to come up.
  boot.kernelParams = [ "console=ttyS0" ];

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # No egress: fail fast on a path that is not in the image instead of
      # hanging on an unreachable cache.
      substituters = [ ];
      # Player builds are the challenge's payload, and the sandbox is the only
      # thing keeping them inside the store.
      sandbox = true;
      # One submission builds at a time (see the semaphore in builder.py) and
      # gets two cores.
      max-jobs = 2;
      cores = 2;
    };

    # Every submission leaves an unrooted closure behind and nothing here is
    # worth keeping: the seeds are part of the system closure, which the
    # collector roots. Without this the overlay fills up over an event.
    gc = {
      automatic = true;
      dates = "hourly";
      options = "--max-freed 10G";
    };
  };

  # Same values the VM variant sets on its own, spelled out so this module also
  # evaluates as a plain system. The backing image is sized to the closure and
  # nothing more, so the writable overlay is where submissions have to fit.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  boot.growPartition = true;
  boot.loader.grub.device = "/dev/vda";

  # growpart enlarges the partition only after the root filesystem is mounted,
  # so the stage-1 resize from `autoResize` misses it on the first boot. Extend
  # the mounted filesystem online instead. Later boots are covered by
  # `autoResize` alone.
  systemd.services.grow-rootfs = {
    description = "Grow the root filesystem to the overlay disk size";
    wantedBy = [ "multi-user.target" ];
    before = [ "rtunreal-builder.service" ];
    after = [
      "growpart.service"
      "-.mount"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.e2fsprogs
      pkgs.util-linux
    ];
    script = ''
      # resize2fs operates on the block device, not the mount point.
      resize2fs "$(findmnt -n -o SOURCE /)"
    '';
  };

  users.users.rtunreal = {
    isSystemUser = true;
    group = "rtunreal";
    description = "Runs the rtunreal check runner";
  };
  users.groups.rtunreal = { };

  systemd.services.rtunreal-builder = {
    description = "rtunreal: grades a submitted patch against the challenge checks";
    wantedBy = [ "multi-user.target" ];
    wants = [ "nix-daemon.socket" ];
    after = [
      "network.target"
      "nix-daemon.socket"
    ];

    # `nix` is the guest's own daemon package, so client and daemon are the
    # same version. `git` and `patch` are the two ways a submission can be
    # applied.
    path = [
      config.nix.package
      pkgs.git
      pkgs.gnupatch
    ];

    environment = {
      RTUNREAL_PORT = toString port;
      RTUNREAL_SOURCE = "${pristine}";
      RTUNREAL_NIXPKGS = "${guardedNixpkgs}";
      RTUNREAL_SYSTEM = system;
      RTUNREAL_STATE = stateDir;
      RTUNREAL_NIX = lib.getExe config.nix.package;
      RTUNREAL_CHECK_TIMEOUT = toString checkTimeout;
      RTUNREAL_TOTAL_TIMEOUT = toString totalTimeout;
      RTUNREAL_MAX_PATCH = toString maxPatchBytes;
      # A player who submits while another submission builds waits in line
      # rather than getting a 503, for as long as one full submission takes.
      RTUNREAL_QUEUE_TIMEOUT = toString totalTimeout;
      # The evaluator writes ~/.cache/nix, and the second submission is much
      # faster for it.
      HOME = stateDir;
    };

    serviceConfig = {
      ExecStart = lib.getExe app;
      Restart = "on-failure";
      RestartSec = 5;

      User = "rtunreal";
      Group = "rtunreal";
      StateDirectory = "rtunreal";
      StateDirectoryMode = "0750";
      WorkingDirectory = stateDir;
      # PrivateTmp is load bearing, not hygiene: `ProtectSystem=strict` leaves
      # /tmp read-only, and `nix build` fails to create its temporary build
      # directory without a private one.
      PrivateTmp = true;

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      RestrictSUIDSGID = true;
      LockPersonality = true;
    };
  };

  system.extraDependencies = buildSeeds;

  # Nobody logs in here and the image is copied to the server on every deploy,
  # so the man pages and the options.json build are pure weight.
  documentation.enable = false;

  system.stateVersion = "26.05";
}
