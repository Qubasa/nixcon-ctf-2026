{ port, src-baas }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  app = pkgs.callPackage ./package.nix {
    inherit src-baas;
    nix = config.nix.package;
  };

  stateDir = "/var/lib/baas";

  flagBlob = "/sys/firmware/qemu_fw_cfg/by_name/opt/ctf/flag/raw";

  bootstrap = pkgs.writeShellApplication {
    name = "baas-flag-bootstrap";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      config.nix.package
      config.networking.firewall.package
    ];
    text = ''
      if [ -r ${flagBlob} ]; then
        flag=$(cat ${flagBlob})
      else
        echo "no flag handed over via fw_cfg, using a placeholder" >&2
        flag='fakectf{no_flag_was_handed_to_this_vm}'
      fi

      # The expression matches what index.js wraps `code` in character for
      # character, so the path built here and the path the app hands out are
      # the same one. A 45 character flag leaves `code` at 73, far below the
      # app's limit of 1024.
      code="{}: pkgs.writeText \"flag\" \"$flag\""
      expr="let pkgs = import <nixpkgs> {}; in pkgs.callPackage ($code) {}"

      # The build takes no out-link. `/path/:path` resolves any path the caller
      # names and serves it as long as the *resolved* path is under /nix/store,
      # so any symlink to the flag's output is a one-request solve: a root at
      # `${stateDir}/flag-result` is guessable, and so is the `./result` the
      # app's own nix-build drops in its working directory. Nothing in this
      # guest ever garbage collects (`nix.gc.automatic` is off below), so the
      # path survives unrooted, which is the only way it survives unreachable.
      nix-build --option restrict-eval true --no-out-link --expr "$expr"

      # The unit counts as started once the process is forked, which is a
      # second or two before express binds. GET /build is a static page, so a
      # 200 means the listener is really up. Loopback is always open in the
      # guest firewall.
      for _ in $(seq 1 60); do
        if curl -sf -o /dev/null http://127.0.0.1:${toString port}/build; then
          break
        fi
        sleep 1
      done

      # Registered from 127.0.0.1, exactly as the challenge's own init.sh
      # does: the intended solve is a fixed-output derivation that asks
      # `localhost:${toString port}/` for its listing. `builtPaths` is
      # in-process memory, so this re-runs on every start of the app.
      curl -4 -sS --fail-with-body \
        --data-urlencode "code=$code" \
        http://127.0.0.1:${toString port}/build

      # The app ran `nix-build` in its working directory, so `./result` now
      # points at the flag. Delete it: until a player's own build overwrites
      # it, `/path//var/lib/baas/result` would serve the flag to anyone who
      # asks.
      rm -f ${stateDir}/result

      # Only now does the host's slirp forward reach the app. The host's
      # allocator reports the slot ready on the first HTTP answer, so a team
      # never gets an instance whose flag is not registered yet.
      iptables -w -C nixos-fw -p tcp --dport ${toString port} -j nixos-fw-accept 2>/dev/null \
        || iptables -w -I nixos-fw -p tcp --dport ${toString port} -j nixos-fw-accept
    '';
  };

  buildSeeds =
    with pkgs;
    [
      stdenv
      stdenvNoCC
      bashInteractive
      cmake
      coreutils
      curl
      diffutils
      file
      findutils
      gawk
      gcc
      git
      gnugrep
      gnumake
      gnused
      gnutar
      gzip
      jq
      openssl
      patch
      pkg-config
      python3
      which
      xz
      zlib
    ]
    ++ map (drv: drv.inputDerivation) [
      cowsay
      hello
      jq
      zlib
    ];
in
{
  networking.hostName = "baas";

  nix.settings = {
    substituters = [ ];
    sandbox = true;
  };

  nix.gc.automatic = false;
  nix.optimise.automatic = false;

  boot.kernelModules = [ "qemu_fw_cfg" ];

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
    before = [ "baas.service" ];
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

  users.users.baas = {
    isSystemUser = true;
    group = "baas";
    description = "Runs the baas challenge app";
  };
  users.groups.baas = { };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 baas baas -"
    "L+ ${stateDir}/views - - - - ${app}/libexec/baas/views"
  ];

  systemd.services.baas = {
    description = "baas: build as a service, the challenge web app";
    wantedBy = [ "multi-user.target" ];
    wants = [ "nix-daemon.socket" ];
    after = [
      "network.target"
      "nix-daemon.socket"
    ];

    environment = {
      PORT = toString port;
      NIX_PATH = "nixpkgs=${pkgs.path}";
      HOME = stateDir;
    };

    serviceConfig = {
      ExecStart = "${app}/bin/baas";
      ExecStartPost = "+${lib.getExe bootstrap}";
      Restart = "on-failure";
      RestartSec = 5;

      User = "baas";
      Group = "baas";
      StateDirectory = "baas";
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
