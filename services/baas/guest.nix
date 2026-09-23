# The challenge guest runs nothing but the baas app and the Nix daemon whose
# store players build into. It is the containment boundary, so it holds no
# secret beyond the flag it is handed and has no way out (see ./README.md).
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
    # The app shells out to bare `nix-build`, so the client on its PATH is the
    # guest's own daemon package rather than whatever `pkgs.nix` happens to be.
    nix = config.nix.package;
  };

  stateDir = "/var/lib/baas";

  # A root-only sysfs blob that the hypervisor's fw_cfg device hands over. The
  # flag never goes through a NixOS option: `environment.etc` and friends would
  # put it in /nix/store, which this app serves over HTTP by design.
  flagBlob = "/sys/firmware/qemu_fw_cfg/by_name/opt/ctf/flag/raw";

  bootstrap = pkgs.writeShellApplication {
    name = "baas-flag-bootstrap";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      config.nix.package
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
      # 200 means the listener is really up.
      for _ in $(seq 1 60); do
        if curl -sf -o /dev/null http://127.0.0.1:${toString port}/build; then
          break
        fi
        sleep 1
      done

      # `builtPaths` is in-process memory, so the flag has to be re-registered
      # on every start, not just on first boot.
      #
      # The app trusts every proxy hop and therefore keys the build on the
      # left-most `X-Forwarded-For` entry. A fixed value there would be a value
      # a player could send too, so this parks the flag under a random one: the
      # only listing it shows up in is one nobody can ask for. Player requests
      # still get their own bucket, the address the host's nginx appends.
      bucket="bootstrap-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
      curl -4 -sS --fail-with-body \
        -H "X-Forwarded-For: $bucket" \
        --data-urlencode "code=$code" \
        http://127.0.0.1:${toString port}/build

      # The app ran `nix-build` in its working directory, so `./result` now
      # points at the flag. Delete it: until a player's own build overwrites
      # it, `/path//var/lib/baas/result` would serve the flag to anyone who
      # asks, and the app restarts on failure.
      rm -f ${stateDir}/result ${stateDir}/flag-result
    '';
  };

  # Players build real derivations in here with no substituters and no egress,
  # so a build can only use what the image already ships. `stdenv` and
  # `stdenvNoCC` make every `mkDerivation`, `runCommand` and `writeText`
  # buildable, which includes the flag itself. The `inputDerivation`s further
  # down add those packages' sources and build-time closures, so a derivation
  # that really compiles something works too. The tool list is an ordinary
  # `buildInputs` line, kept generic on purpose: it is not tailored to any
  # particular solution.
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

  # slirp forwards exactly one port into this guest and the guest's own
  # firewall would drop it.
  networking.firewall.allowedTCPPorts = [ port ];

  nix.settings = {
    # No egress: fail fast on a path that is not in the image instead of
    # hanging on an unreachable cache.
    substituters = [ ];
    # Player builds are the challenge, and the sandbox is the only thing
    # keeping them inside the store.
    sandbox = true;
  };

  # Disabling GC is load bearing, not a default worth inheriting: the flag's
  # store path is deliberately unrooted, because every symlink to it is a
  # one-request solve through `/path/:path`. A collection would take the flag
  # with it.
  nix.gc.automatic = false;
  nix.optimise.automatic = false;

  # The flag arrives through fw_cfg, whose sysfs interface needs the module.
  boot.kernelModules = [ "qemu_fw_cfg" ];

  # These are the same values the VM variant sets on its own, spelled out so
  # this module also evaluates as a plain system. The backing image is sized to
  # the closure and nothing more, so the writable overlay is where player
  # builds have to fit.
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
    # Express resolves its view directory relative to the working directory,
    # and the working directory has to be writable because `nix-build` drops a
    # `./result` symlink into it on every request.
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
      # index.js evaluates `import <nixpkgs> {}` with `restrict-eval` on, so
      # the search path has to be set here: NixOS exports its own default
      # through `environment.sessionVariables`, which no system unit inherits.
      # A store path also keeps evaluation offline, unlike the `flake:nixpkgs`
      # indirection that default uses.
      NIX_PATH = "nixpkgs=${pkgs.path}";
      # The evaluator writes ~/.cache/nix.
      HOME = stateDir;
    };

    serviceConfig = {
      ExecStart = "${app}/bin/baas";
      # The `+` prefix runs it as root, because the fw_cfg blob the flag
      # arrives in is readable by root only.
      ExecStartPost = "+${lib.getExe bootstrap}";
      Restart = "on-failure";
      RestartSec = 5;

      User = "baas";
      Group = "baas";
      StateDirectory = "baas";
      StateDirectoryMode = "0750";
      # `nix-build` writes its out-link into the working directory.
      WorkingDirectory = stateDir;
      # PrivateTmp is load bearing, not hygiene: `ProtectSystem=strict` leaves
      # /tmp read-only, and nix-build fails to create its temporary build
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
      # The unit needs no `ReadWritePaths` for /nix/var/nix/daemon-socket.
      # Measured with this exact set on a transient unit, connect(2) to the
      # daemon socket and a full `nix-build --out-link` both succeed under the
      # read-only /nix that `ProtectSystem=strict` leaves behind.
    };
  };

  system.extraDependencies = buildSeeds;

  # Nobody logs in here and the image is copied to the server on every deploy,
  # so the man pages and the options.json build are pure weight.
  documentation.enable = false;

  system.stateVersion = "26.05";
}
