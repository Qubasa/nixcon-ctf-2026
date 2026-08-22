{ inputs }:
{
  _class = "clan.service";
  manifest.name = "homewort";
  manifest.description = "Hosts the `homewort` privilege-escalation challenge as a pool of ephemeral QEMU VMs, one forwarded SSH port each, with the flag handed to each VM through fw_cfg.";
  manifest.categories = [ "Utility" ];
  manifest.readme = builtins.readFile ./README.md;

  roles.server = {
    description = "Runs `instances` independent challenge VMs, each reachable on its own TCP port and reset to a pristine state on every (re)start.";

    interface =
      { lib, ... }:
      {
        options = {
          instances = lib.mkOption {
            type = lib.types.ints.positive;
            default = 6;
            description = ''
              Number of challenge VMs to run. Players solve the challenge by
              rebuilding the system as root, so every player needs their own
              VM; size this to the expected number of concurrent solvers.
            '';
          };

          basePort = lib.mkOption {
            type = lib.types.port;
            default = 2201;
            description = ''
              TCP port of the first VM's forwarded SSH. Instance `n` (starting
              at 1) listens on `basePort + n - 1`.
            '';
          };

          internalBasePort = lib.mkOption {
            type = lib.types.port;
            default = 42201;
            description = ''
              Loopback port QEMU forwards instance `n`'s guest SSH to
              (`internalBasePort + n - 1`). Players never see these: QEMU's
              slirp `restrict=on` drops guest replies to any client address
              other than its own host alias, so the public port is served by a
              host-side proxy that reaches the guest over loopback.
            '';
          };

          address = lib.mkOption {
            type = lib.types.str;
            default = "0.0.0.0";
            description = "Address the public SSH ports are bound to.";
          };

          memorySize = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4096;
            description = ''
              RAM per VM in MiB. `sudo rebuildHome` evaluates a full NixOS
              configuration inside the VM, which needs a few GiB.
            '';
          };

          cores = lib.mkOption {
            type = lib.types.ints.positive;
            default = 2;
            description = "Virtual CPUs per VM.";
          };

          diskSize = lib.mkOption {
            type = lib.types.ints.positive;
            default = 36864;
            description = ''
              Size in MiB of each VM's writable overlay. It is a sparse qcow2
              backed by the read-only system image, so this is an upper bound,
              not an allocation.
            '';
          };

          resetInterval = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = "30min";
            example = null;
            description = ''
              systemd time span after which every VM is restarted, wiping the
              player's changes. This is the only way a VM that a player broke
              (or left logged in) returns to the pool. `null` disables the
              timer; VMs then only reset when they crash or are restarted by
              hand.
            '';
          };
        };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule =
          {
            config,
            pkgs,
            lib,
            ...
          }:
          let
            flag = config.clan.core.vars.generators.homewort.files.flag.path;
            login = config.clan.core.vars.generators.homewort-login.files;

            vmNames = map (n: "homewort-vm-${toString n}") (lib.range 1 settings.instances);

            # `mus-vm` is the challenge's own bootable variant: same machine as
            # `mus`, plus the closure an offline `sudo rebuildHome` needs already
            # in the guest store. The bootloader lives in the image so a player's
            # `nixos-rebuild switch` succeeds; the host Nix store is not shared
            # into the guest and the guest has no egress.
            vm =
              (inputs.homewort.nixosConfigurations.mus-vm.extendModules {
                modules = [
                  (
                    { lib, ... }:
                    {
                      virtualisation.vmVariantWithBootLoader.virtualisation = {
                        graphics = false;
                        restrictNetwork = true;
                        inherit (settings) memorySize cores diskSize;
                      };

                      # The login handed to players of this deployment. The
                      # challenge repo's own `friend` password is a default for
                      # running it locally, not for a public box.
                      users.users.friend.password = lib.mkForce null;
                      users.users.friend.hashedPassword = lib.mkForce login.password-hash.value;
                    }
                  )
                ];
              }).config.system.build.vmWithBootLoader;

            vmService = n: {
              name = "homewort-vm-${toString n}";
              value =
                let
                  stateDir = "homewort-vm-${toString n}";
                  port = settings.basePort + n - 1;
                  internalPort = settings.internalBasePort + n - 1;
                in
                {
                  description = "homewort challenge VM ${toString n} (ssh on port ${toString port})";
                  wantedBy = [ "multi-user.target" ];
                  after = [ "network.target" ];

                  environment = {
                    NIX_DISK_IMAGE = "/var/lib/${stateDir}/disk.qcow2";
                    # Loopback only: slirp rewrites a loopback client to its own
                    # host alias, which `restrict=on` lets the guest answer.
                    # Public traffic arrives through the -ssh proxy unit.
                    QEMU_NET_OPTS = "hostfwd=tcp:127.0.0.1:${toString internalPort}-:22";
                    # Root-only sysfs blob inside the guest; the ctf-flag
                    # service installs it as /etc/flag.
                    QEMU_OPTS = "-fw_cfg name=opt/ctf/flag,file=${flag}";
                  };

                  serviceConfig = {
                    ExecStart = "${vm}/bin/run-mus-vm";
                    # Players get root in there, so every start must begin from
                    # the pristine backing image.
                    ExecStartPre = "${pkgs.coreutils}/bin/rm -f /var/lib/${stateDir}/disk.qcow2";
                    Restart = "always";
                    RestartSec = 5;

                    User = "homewort";
                    Group = "homewort";
                    SupplementaryGroups = [ "kvm" ];
                    StateDirectory = stateDir;
                    StateDirectoryMode = "0700";
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
            };

            # QEMU's slirp keeps a non-loopback client's address inside the
            # guest network, and `restrict=on` then drops the guest's replies to
            # it: the player's TCP handshake completes against slirp and the SSH
            # banner never arrives. So the public port belongs to a host process
            # that talks to the guest over loopback.
            sshProxySocket = n: {
              name = "homewort-vm-${toString n}-ssh";
              value = {
                description = "Public SSH port of homewort challenge VM ${toString n}";
                wantedBy = [ "sockets.target" ];
                listenStreams = [ "${settings.address}:${toString (settings.basePort + n - 1)}" ];
              };
            };

            sshProxyService = n: {
              name = "homewort-vm-${toString n}-ssh";
              value = {
                description = "Forwards the public SSH port of homewort challenge VM ${toString n} into the guest";
                requires = [ "homewort-vm-${toString n}-ssh.socket" ];
                after = [
                  "homewort-vm-${toString n}-ssh.socket"
                  "homewort-vm-${toString n}.service"
                ];

                serviceConfig = {
                  ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString (settings.internalBasePort + n - 1)}";
                  DynamicUser = true;
                  CapabilityBoundingSet = "";
                  NoNewPrivileges = true;
                  ProtectSystem = "strict";
                  ProtectHome = true;
                  RestrictAddressFamilies = [
                    "AF_UNIX"
                    "AF_INET"
                  ];
                  RestrictSUIDSGID = true;
                  LockPersonality = true;
                };
              };
            };
          in
          {
            users.users.homewort = {
              isSystemUser = true;
              group = "homewort";
              description = "Runs the homewort challenge VMs";
            };
            users.groups.homewort = { };

            clan.core.vars.generators.homewort = {
              prompts.flag = {
                description = "Flag handed to the homewort challenge VMs, e.g. nixcon{...}";
                type = "line";
              };
              files.flag = {
                owner = "homewort";
                group = "homewort";
                mode = "0400";
                restartUnits = vmNames;
              };
              runtimeInputs = [ pkgs.coreutils ];
              # Strip the trailing newline the prompt may carry, add exactly one
              # back: the guest installs this file verbatim as /etc/flag.
              script = ''
                {
                  tr -d '\r\n' < "$prompts/flag"
                  printf '\n'
                } > "$out/flag"
              '';
            };

            # The login players are given. Public on purpose: it goes into the
            # challenge description. Rotating it means regenerating this and
            # redeploying, which restarts every VM.
            clan.core.vars.generators.homewort-login = {
              files.password.secret = false;
              files.password-hash.secret = false;
              runtimeInputs = [
                pkgs.xkcdpass
                pkgs.mkpasswd
                pkgs.coreutils
              ];
              script = ''
                xkcdpass --numwords 3 --min 4 --max 6 --delimiter - \
                  | tr -d '\n' > "$out/password"
                mkpasswd --method=yescrypt --stdin < "$out/password" \
                  | tr -d '\n' > "$out/password-hash"
              '';
            };

            systemd.sockets = lib.listToAttrs (map sshProxySocket (lib.range 1 settings.instances));

            systemd.services =
              lib.listToAttrs (map vmService (lib.range 1 settings.instances))
              // lib.listToAttrs (map sshProxyService (lib.range 1 settings.instances))
              // lib.optionalAttrs (settings.resetInterval != null) (
                lib.listToAttrs (
                  map (name: {
                    name = "${name}-reset";
                    value = {
                      description = "Reset ${name} to a pristine state";
                      serviceConfig = {
                        Type = "oneshot";
                        ExecStart = "${config.systemd.package}/bin/systemctl restart ${name}.service";
                      };
                    };
                  }) vmNames
                )
              );

            systemd.timers = lib.optionalAttrs (settings.resetInterval != null) (
              lib.listToAttrs (
                map (name: {
                  inherit name;
                  value = {
                    description = "Periodic reset of ${name}";
                    wantedBy = [ "timers.target" ];
                    timerConfig = {
                      OnActiveSec = settings.resetInterval;
                      OnUnitActiveSec = settings.resetInterval;
                      Unit = "${name}-reset.service";
                    };
                  };
                }) vmNames
              )
            );

            networking.firewall.allowedTCPPorts = map (
              n: settings.basePort + n - 1
            ) (lib.range 1 settings.instances);
          };
      };
  };
}
