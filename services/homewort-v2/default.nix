{ inputs }:
{
  _class = "clan.service";
  manifest.name = "homewort-v2";
  manifest.description = "Hosts the `homewort-v2` privilege-escalation challenge as an on-demand pool of ephemeral QEMU VMs, one forwarded SSH port and one freshly minted flag each, handed out by chall-manager through a small allocator CLI.";
  manifest.categories = [ "Utility" ];
  manifest.readme = builtins.readFile ./README.md;

  roles.server = {
    description = "Provides `maxSlots` challenge VM slots that chall-manager claims and releases per team through `homewort-v2-instance`, each with its own public SSH port and its own random flag.";

    interface =
      { lib, ... }:
      {
        options = {
          maxSlots = lib.mkOption {
            type = lib.types.ints.positive;
            default = 6;
            description = ''
              Number of concurrent challenge instances the host offers. Slots
              are claimed on demand, but every claimed slot runs a full VM, so
              this is a hard RAM budget. This pool also shares the host with
              the 12-slot `homewort` pool, hence the smaller default: this is
              the harder variant, and fewer players reach it at once. Claiming
              beyond it fails the allocator with exit code 4, which surfaces as
              a failed deploy in the CTFd UI.
            '';
          };

          basePort = lib.mkOption {
            type = lib.types.port;
            default = 2301;
            description = ''
              TCP port of the first slot's forwarded SSH. Slot `n` (starting
              at 1) listens on `basePort + n - 1`. The default starts a hundred
              above `homewort`'s 2201, because that pool owns 2201-2212.
            '';
          };

          internalBasePort = lib.mkOption {
            type = lib.types.port;
            default = 42301;
            description = ''
              Loopback port QEMU forwards slot `n`'s guest SSH to
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

          publicHost = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "ctf.nixcon.org";
            description = ''
              Host name players are told to connect to in the allocator's
              `connection_info`. `null` uses the machine's
              `networking.fqdnOrHostName`, which is only right when that name
              resolves publicly.
            '';
          };

          memorySize = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4096;
            description = ''
              RAM per VM in MiB. `sudo rebuildHome-friend` evaluates a full NixOS
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

          flagFormat = lib.mkOption {
            type = lib.types.str;
            default = "nixcon{homewort_v2_%s}";
            description = ''
              `printf` template the allocator fills with 32 hex characters to
              mint an instance's flag. Must contain exactly one `%s`.
            '';
          };

          allowUser = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = "chall-manager";
            example = null;
            description = ''
              User allowed to run `homewort-v2-instance` through `sudo` without
              a password. This is chall-manager, whose Pulumi scenario is the
              only thing that claims and releases slots. `null` installs no
              sudo rule, leaving the allocator to root only.
            '';
          };

          readyTimeout = lib.mkOption {
            type = lib.types.ints.positive;
            default = 180;
            description = ''
              Seconds `homewort-v2-instance create` waits for the guest's SSH
              banner before giving up, releasing the slot again and failing
              with exit code 5. A cold boot of the challenge image takes well
              under a minute. The headroom is for a host that may also be
              running a full `homewort` pool.
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
            login = config.clan.core.vars.generators.homewort-v2-login.files;

            slots = lib.range 1 settings.maxSlots;

            name = "homewort-v2";
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
                flagFormat
                readyTimeout
                ;
              inherit publicHost unitPrefix;
              password = login.password.value;
              stateDir = slotDir;
              flagOwner = "${name}:${name}";
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

                # The registry is a plain long-running process with no
                # readiness notification, so ordering after its unit only
                # means "was started".
                for _ in $(seq 1 60); do
                  if curl -sf -o /dev/null http://127.0.0.1:5000/v2/; then
                    break
                  fi
                  sleep 1
                done

                # The registry is unauthenticated, but oras still opens its
                # auth file and dies on EACCES rather than skipping it, so
                # point it at the unit's private tmpdir instead of a $HOME it
                # may not be allowed to read.
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
              (inputs.homewort-v2.nixosConfigurations.mus-vm.extendModules {
                modules = [
                  (
                    { lib, ... }:
                    {
                      virtualisation.vmVariantWithBootLoader.virtualisation = {
                        graphics = false;
                        restrictNetwork = true;
                        inherit (settings) memorySize cores diskSize;
                      };

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
                  description = "homewort-v2 challenge VM in slot ${toString n} (ssh on port ${toString port})";
                  wantedBy = [ ];
                  after = [ "network.target" ];

                  environment = {
                    NIX_DISK_IMAGE = "/var/lib/${stateDir}/disk.qcow2";
                    QEMU_NET_OPTS = "hostfwd=tcp:127.0.0.1:${toString internalPort}-:22";
                    QEMU_OPTS = "-fw_cfg name=opt/ctf/flag,file=${slotDir}/${toString n}/flag";
                  };

                  serviceConfig = {
                    ExecStart = "${vm}/bin/run-mus-vm";
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
                description = "Public SSH port of homewort-v2 challenge slot ${toString n}";
                wantedBy = [ "sockets.target" ];
                listenStreams = [ "${settings.address}:${toString (settings.basePort + n - 1)}" ];
              };
            };

            sshProxyService = n: {
              name = "${unitPrefix}-${toString n}-ssh";
              value = {
                description = "Forwards the public SSH port of homewort-v2 challenge slot ${toString n} into the guest";
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
              description = "Runs the homewort-v2 challenge VMs";
            };
            users.groups.${name} = { };

            clan.core.vars.generators.homewort-v2-login = {
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
                homewort-v2-scenario-push = {
                  description = "Push the homewort-v2 Pulumi scenario to the local chall-manager registry";
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
