{ inputs, ... }:
{
  _class = "clan.service";
  manifest.name = "baas";
  manifest.description = "Hosts the `baas` challenge, an Express app that hands `nix-build` whatever expression a player posts, as an on-demand pool of QEMU VMs with one public HTTP port and one freshly minted flag per team, handed out by chall-manager through the shared pool allocator.";
  manifest.categories = [ "Web" ];
  manifest.readme = builtins.readFile ./README.md;

  roles.server = {
    description = "Provides `maxSlots` baas VM slots that chall-manager claims and releases per team through `baas-instance`, each with its own public HTTP port and its own random flag.";

    interface =
      { lib, ... }:
      {
        options = {
          port = lib.mkOption {
            type = lib.types.port;
            default = 3000;
            description = "Port the app listens on inside each guest.";
          };

          maxSlots = lib.mkOption {
            type = lib.types.ints.positive;
            default = 8;
            description = ''
              Number of concurrent baas instances the host offers. Every claimed
              slot runs a full VM, so `maxSlots` × `memorySize` is a hard RAM
              budget. Claiming beyond it fails the allocator with exit code 4,
              which surfaces as a failed deploy in the CTFd UI.
            '';
          };

          basePort = lib.mkOption {
            type = lib.types.port;
            default = 2601;
            description = ''
              Public TCP port of the first slot's app. Slot `n` (starting at 1)
              listens on `basePort + n - 1`.
            '';
          };

          internalBasePort = lib.mkOption {
            type = lib.types.port;
            default = 42601;
            description = ''
              Loopback port QEMU forwards slot `n`'s app port to
              (`internalBasePort + n - 1`). Players never see it: the public
              port belongs to a `systemd-socket-proxyd` unit that reaches the
              guest over loopback.
            '';
          };

          address = lib.mkOption {
            type = lib.types.str;
            default = "0.0.0.0";
            description = "Address the public HTTP ports are bound to.";
          };

          publicHost = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "ctf.nixcon.org";
            description = ''
              Host name in the URL the allocator hands the player. `null` uses
              the machine's `networking.fqdnOrHostName`, which is only right
              when that name resolves publicly.
            '';
          };

          memorySize = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4096;
            description = ''
              RAM per VM in MiB. Every `POST /build` evaluates the whole of
              nixpkgs in the guest, a few hundred MiB on its own, and the builds
              it kicks off run in the same guest.
            '';
          };

          cores = lib.mkOption {
            type = lib.types.ints.positive;
            default = 2;
            description = "Virtual CPUs per VM.";
          };

          diskSize = lib.mkOption {
            type = lib.types.ints.positive;
            default = 20480;
            description = ''
              Size in MiB of each VM's writable overlay. It is a sparse qcow2
              backed by the read-only system image, so this is an upper bound,
              not an allocation, and it is wiped whenever the slot's VM starts
              or stops.
            '';
          };

          flagFormat = lib.mkOption {
            type = lib.types.str;
            default = "nixcon{baas_%s}";
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
              User allowed to run `baas-instance` through `sudo` without a
              password. This is chall-manager, whose Pulumi scenario is the only
              thing that claims and releases slots. `null` installs no sudo
              rule, leaving the allocator to root only.
            '';
          };

          readyTimeout = lib.mkOption {
            type = lib.types.ints.positive;
            default = 180;
            description = ''
              Seconds `baas-instance create` waits for the guest's app to answer
              HTTP before giving up, releasing the slot again and failing with
              exit code 5.
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
            slots = lib.range 1 settings.maxSlots;

            # `<n>/identity` marks slot `n` as claimed, `<n>/flag` is what
            # fw_cfg hands to that slot's guest.
            slotDir = "/var/lib/baas-slots";

            publicHost =
              if settings.publicHost != null then settings.publicHost else config.networking.fqdnOrHostName;

            allocator = import ../../pkgs/pool-allocator.nix {
              inherit pkgs lib;
              inherit (settings)
                maxSlots
                basePort
                internalBasePort
                flagFormat
                readyTimeout
                ;
              inherit publicHost;
              stateDir = slotDir;
              systemctl = "${config.systemd.package}/bin/systemctl";
              name = "baas-instance";
              unitPrefix = "baas-vm";
              flagOwner = "baas:baas";
            };

            # Loose `Pulumi.yaml` and a prebuilt `main` at the derivation root:
            # chall-manager loads a scenario as one OCI layer per file and
            # stats those two names.
            scenario = pkgs.callPackage ./scenario/package.nix { };
            scenarioRef = "127.0.0.1:5000/baas:${scenario.version}";

            pushScenario = pkgs.writeShellApplication {
              name = "baas-scenario-push";
              runtimeInputs = [
                pkgs.oras
                pkgs.curl
                pkgs.coreutils
              ];
              text = ''
                # The registry has no readiness notification, so ordering after
                # its unit only means "was started".
                for _ in $(seq 1 60); do
                  if curl -sf -o /dev/null http://127.0.0.1:5000/v2/; then
                    break
                  fi
                  sleep 1
                done

                oras push --plain-http \
                  --registry-config "$HOME/oras-auth.json" \
                  --artifact-type application/vnd.ctfer-io.scenario \
                  ${scenarioRef} \
                  Pulumi.yaml:application/vnd.ctfer-io.file \
                  main:application/vnd.ctfer-io.file

                echo "baas scenario available as ${scenarioRef}"
              '';
            };

            guest = import "${pkgs.path}/nixos/lib/eval-config.nix" {
              system = null;
              inherit pkgs;
              modules = [
                (import ./guest.nix {
                  inherit (settings) port;
                  src-baas = inputs.baas;
                })
                {
                  virtualisation.vmVariantWithBootLoader.virtualisation = {
                    graphics = false;
                    inherit (settings) memorySize cores diskSize;
                  };
                }
              ];
            };

            vm = guest.config.system.build.vmWithBootLoader;

            vmService = n: {
              name = "baas-vm-${toString n}";
              value =
                let
                  stateDir = "baas-vm-${toString n}";
                  port = settings.basePort + n - 1;
                  internalPort = settings.internalBasePort + n - 1;
                in
                {
                  description = "baas challenge VM in slot ${toString n} (http on port ${toString port})";
                  # Nothing pulls this in: `baas-instance create` starts it when
                  # a team claims the slot and `destroy` stops it again.
                  wantedBy = [ ];
                  after = [ "network.target" ];
                  # A deploy must not wipe a team's running box. A changed image
                  # takes effect on the slot's next claim.
                  restartIfChanged = false;

                  environment = {
                    NIX_DISK_IMAGE = "/var/lib/${stateDir}/disk.qcow2";
                    QEMU_NET_OPTS = "hostfwd=tcp:127.0.0.1:${toString internalPort}-:${toString settings.port}";
                    # The allocator writes this file before it starts the unit,
                    # so each claim of the slot gets a different flag.
                    QEMU_OPTS = "-fw_cfg name=opt/ctf/flag,file=${slotDir}/${toString n}/flag";
                  };

                  serviceConfig = {
                    ExecStart = "${vm}/bin/run-baas-vm";
                    # Every claim starts from the pristine image, and a released
                    # slot gives its disk back at once. The allocator cannot do
                    # this itself: it runs in chall-manager's mount namespace,
                    # where /var/lib is read-only apart from the slot directory.
                    ExecStartPre = "${pkgs.coreutils}/bin/rm -f /var/lib/${stateDir}/disk.qcow2";
                    ExecStopPost = "${pkgs.coreutils}/bin/rm -f /var/lib/${stateDir}/disk.qcow2";
                    Restart = "always";
                    RestartSec = 5;

                    User = "baas";
                    Group = "baas";
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

            proxySocket = n: {
              name = "baas-vm-${toString n}-http";
              value = {
                description = "Public HTTP port of baas challenge slot ${toString n}";
                wantedBy = [ "sockets.target" ];
                listenStreams = [ "${settings.address}:${toString (settings.basePort + n - 1)}" ];
              };
            };

            proxyService = n: {
              name = "baas-vm-${toString n}-http";
              value = {
                description = "Forwards the public HTTP port of baas challenge slot ${toString n} into the guest";
                requires = [ "baas-vm-${toString n}-http.socket" ];
                after = [
                  "baas-vm-${toString n}-http.socket"
                  "baas-vm-${toString n}.service"
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
            imports = [ ../../modules/vm-egress.nix ];

            ctf.vmEgress.users = [ "baas" ];

            users.users.baas = {
              isSystemUser = true;
              group = "baas";
              description = "Runs the baas challenge VMs";
            };
            users.groups.baas = { };

            environment.systemPackages = [ allocator ];

            # World-traversable so the VM services, which run as `baas` under
            # `ProtectSystem=strict`, can read their own `<n>/flag`.
            systemd.tmpfiles.rules = [ "d ${slotDir} 0755 root root -" ];

            security.sudo.extraRules = lib.optionals (settings.allowUser != null) [
              {
                users = [ settings.allowUser ];
                commands = [
                  {
                    # The profile path, not the allocator's store path: the
                    # scenario hardcodes this command line, and only the
                    # profile path survives a rebuild of the allocator.
                    command = "/run/current-system/sw/bin/baas-instance";
                    options = [ "NOPASSWD" ];
                  }
                ];
              }
            ];

            systemd.sockets = lib.listToAttrs (map proxySocket slots);

            systemd.services =
              lib.listToAttrs (map vmService slots)
              // lib.listToAttrs (map proxyService slots)
              // {
                # chall-manager pulls the scenario from the host's registry on
                # every deploy, so it has to be there before the first team
                # clicks "deploy".
                baas-scenario-push = {
                  description = "Push the baas Pulumi scenario to the local chall-manager registry";
                  after = [ "chall-manager-registry.service" ];
                  wants = [ "chall-manager-registry.service" ];
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                    # Layer titles are paths relative to the working directory.
                    WorkingDirectory = "${scenario}";
                    ExecStart = lib.getExe pushScenario;
                    # oras reads a docker config under $HOME, and the store path
                    # it works in is read-only.
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
