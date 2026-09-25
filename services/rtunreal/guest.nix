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

  pristine = pkgs.callPackage ./source.nix { src = src-rtunreal; };

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
    ++ [ guardedNixpkgs.outPath ];
in
{
  networking.hostName = "rtunreal";

  networking.firewall.allowedTCPPorts = [ port ];

  boot.kernelParams = [ "console=ttyS0" ];

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      substituters = [ ];
      sandbox = true;
      max-jobs = 2;
      cores = 2;
    };

    gc = {
      automatic = true;
      dates = "hourly";
      options = "--max-freed 10G";
    };
  };

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  boot.growPartition = true;
  boot.loader.grub.device = "/dev/vda";

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
      RTUNREAL_QUEUE_TIMEOUT = toString totalTimeout;
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

  documentation.enable = false;

  system.stateVersion = "26.05";
}
