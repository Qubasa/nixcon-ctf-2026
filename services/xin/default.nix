{ inputs }:
{
  _class = "clan.service";
  manifest.name = "xin";
  manifest.description = "Hosts the `xin` challenge as an on-demand pool of ephemeral QEMU VMs, one forwarded SSH port each, handed out by chall-manager through a small allocator CLI.";
  manifest.categories = [ "Utility" ];
  manifest.readme = builtins.readFile ./README.md;

  roles.server = {
    description = "Provides `maxSlots` xin VM slots that chall-manager claims and releases per player through `xin-instance`, each with its own public SSH port.";

    interface =
      { lib, ... }:
      {
        options = {
          maxSlots = lib.mkOption {
            type = lib.types.ints.positive;
            default = 10;
            description = ''
              Number of concurrent challenge instances the host offers. Every
              claimed slot runs a VM, so this is a hard RAM budget. Claiming
              beyond it fails the allocator with exit code 4, which surfaces as
              a failed deploy in the CTFd UI.
            '';
          };

          basePort = lib.mkOption {
            type = lib.types.port;
            default = 2501;
            description = ''
              TCP port of the first slot's forwarded SSH. Slot `n` (starting
              at 1) listens on `basePort + n - 1`.
            '';
          };

          internalBasePort = lib.mkOption {
            type = lib.types.port;
            default = 42501;
            description = ''
              Loopback port QEMU forwards slot `n`'s guest SSH to
              (`internalBasePort + n - 1`). QEMU's slirp `restrict=on` only
              answers loopback clients, so the public port is served by a
              host-side proxy.
            '';
          };

          address = lib.mkOption {
            type = lib.types.str;
            default = "0.0.0.0";
            description = "Address the public SSH ports are bound to.";
          };

          publicHost = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "ctf.nixcon.org";
            description = ''
              Host name players are told to connect to in the allocator's
              `connection_info`. `null` uses the machine's
              `networking.fqdnOrHostName`.
            '';
          };

          memorySize = lib.mkOption {
            type = lib.types.ints.positive;
            default = 1024;
            description = ''
              RAM per VM in MiB. The guest only has to run sshd and a shell,
              the solve is reading files.
            '';
          };

          cores = lib.mkOption {
            type = lib.types.ints.positive;
            default = 1;
            description = "Virtual CPUs per VM.";
          };

          allowUser = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = "chall-manager";
            example = null;
            description = ''
              User allowed to run `xin-instance` through `sudo` without a
              password. `null` installs no sudo rule.
            '';
          };

          readyTimeout = lib.mkOption {
            type = lib.types.ints.positive;
            default = 180;
            description = ''
              Seconds `xin-instance create` waits for the guest's SSH banner
              before releasing the slot again and failing with exit code 5.
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
            login = config.clan.core.vars.generators.xin-login.files;

            slots = lib.range 1 settings.maxSlots;

            name = "xin";
            unitPrefix = "${name}-vm";

            slotDir = "/var/lib/${name}-slots";

            publicHost =
              if settings.publicHost != null then settings.publicHost else config.networking.fqdnOrHostName;

            allocator = import ./allocator.nix {
              inherit pkgs lib;
              inherit (settings)
                maxSlots
                basePort
                internalBasePort
                readyTimeout
                ;
              inherit publicHost unitPrefix;
              password = login.password.value;
              stateDir = slotDir;
              systemctl = "${config.systemd.package}/bin/systemctl";
            };

            scenario = pkgs.callPackage ./scenario/package.nix { };
            scenarioRef = "127.0.0.1:5000/${name}:${scenario.version}";

            pushScenario = pkgs.writeShellApplication {
              name = "${name}-scenario-push";
              runtimeInputs = [
                pkgs.oras
                pkgs.curl
                pkgs.coreutils
              ];
              text = ''
                set -euo pipefail

                # The registry has no readiness notification.
                for _ in $(seq 1 60); do
                  if curl -sf -o /dev/null http://127.0.0.1:5000/v2/; then
                    break
                  fi
                  sleep 1
                done

                # oras dies on an unreadable auth file even for an
                # unauthenticated registry.
                oras push --plain-http \
                  --registry-config "$HOME/oras-auth.json" \
                  --artifact-type application/vnd.ctfer-io.scenario \
                  ${scenarioRef} \
                  Pulumi.yaml:application/vnd.ctfer-io.file \
                  main:application/vnd.ctfer-io.file

                echo "${name} scenario available as ${scenarioRef}"
              '';
            };

            vm =
              (inputs.xin.nixosConfigurations.xin.extendModules {
                modules = [
                  (
                    { config, lib, ... }:
                    {
                      virtualisation.vmVariantWithBootLoader.virtualisation = {
                        graphics = false;
                        restrictNetwork = true;
                        inherit (settings) memorySize cores;
                      };

                      # The flag pieces are packages that link nothing into
                      # system-path, so they are not in the system closure. The
                      # challenge is finding them in the guest's store.
                      system.extraDependencies = config.environment.systemPackages;

                      users.users.friend.password = lib.mkForce null;
                      users.users.friend.hashedPassword = lib.mkForce login.password-hash.value;
                    }
                  )
                ];
              }).config.system.build.vmWithBootLoader;

            vmService = n: {
              name = "${unitPrefix}-${toString n}";
              value =
                let
                  stateDir = "${unitPrefix}-${toString n}";
                  port = settings.basePort + n - 1;
                  internalPort = settings.internalBasePort + n - 1;
                in
                {
                  description = "xin challenge VM in slot ${toString n} (ssh on port ${toString port})";
                  wantedBy = [ ];
                  after = [ "network.target" ];

                  environment = {
                    NIX_DISK_IMAGE = "/var/lib/${stateDir}/disk.qcow2";
                    QEMU_NET_OPTS = "hostfwd=tcp:127.0.0.1:${toString internalPort}-:22";
                  };

                  serviceConfig = {
                    ExecStart = "${vm}/bin/run-xin-vm";
                    ExecStartPre = "${pkgs.coreutils}/bin/rm -f /var/lib/${stateDir}/disk.qcow2";
                    ExecStopPost = "${pkgs.coreutils}/bin/rm -f /var/lib/${stateDir}/disk.qcow2";
                    Restart = "always";
                    RestartSec = 5;

                    User = name;
                    Group = name;
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

            sshProxySocket = n: {
              name = "${unitPrefix}-${toString n}-ssh";
              value = {
                description = "Public SSH port of xin challenge slot ${toString n}";
                wantedBy = [ "sockets.target" ];
                listenStreams = [ "${settings.address}:${toString (settings.basePort + n - 1)}" ];
              };
            };

            sshProxyService = n: {
              name = "${unitPrefix}-${toString n}-ssh";
              value = {
                description = "Forwards the public SSH port of xin challenge slot ${toString n} into the guest";
                requires = [ "${unitPrefix}-${toString n}-ssh.socket" ];
                after = [
                  "${unitPrefix}-${toString n}-ssh.socket"
                  "${unitPrefix}-${toString n}.service"
                ];

                serviceConfig = {
                  ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${
                    toString (settings.internalBasePort + n - 1)
                  }";
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
            users.users.${name} = {
              isSystemUser = true;
              group = name;
              description = "Runs the xin challenge VMs";
            };
            users.groups.${name} = { };

            clan.core.vars.generators.xin-login = {
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

            environment.systemPackages = [ allocator ];

            systemd.tmpfiles.rules = [ "d ${slotDir} 0755 root root -" ];

            security.sudo.extraRules = lib.optionals (settings.allowUser != null) [
              {
                users = [ settings.allowUser ];
                commands = [
                  {
                    command = "/run/current-system/sw/bin/${name}-instance";
                    options = [ "NOPASSWD" ];
                  }
                ];
              }
            ];

            systemd.sockets = lib.listToAttrs (map sshProxySocket slots);

            systemd.services =
              lib.listToAttrs (map vmService slots)
              // lib.listToAttrs (map sshProxyService slots)
              // {
                xin-scenario-push = {
                  description = "Push the xin Pulumi scenario to the local chall-manager registry";
                  after = [ "chall-manager-registry.service" ];
                  wants = [ "chall-manager-registry.service" ];
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                    WorkingDirectory = "${scenario}";
                    ExecStart = "${pushScenario}/bin/${name}-scenario-push";
                    Environment = [ "HOME=%T" ];
                    PrivateTmp = true;
                    DynamicUser = true;
                    ProtectSystem = "strict";
                    ProtectHome = true;
                    NoNewPrivileges = true;
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

            networking.firewall.allowedTCPPorts = map (n: settings.basePort + n - 1) slots;
          };
      };
  };
}
