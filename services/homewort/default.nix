{ inputs }:
{
  _class = "clan.service";
  manifest.name = "homewort";
  manifest.description = "Hosts the `homewort` privilege-escalation challenge as an on-demand pool of ephemeral QEMU VMs, one forwarded SSH port and one freshly minted flag each, handed out by chall-manager through a small allocator CLI.";
  manifest.categories = [ "Utility" ];
  manifest.readme = builtins.readFile ./README.md;

  roles.server = {
    description = "Provides `maxSlots` challenge VM slots that chall-manager claims and releases per team through `homewort-instance`, each with its own public SSH port and its own random flag.";

    interface =
      { lib, ... }:
      {
        options = {
          maxSlots = lib.mkOption {
            type = lib.types.ints.positive;
            default = 8;
            description = ''
              Number of concurrent challenge instances the host offers. Slots
              are claimed on demand, but every claimed slot runs a full VM, so
              this is a hard RAM budget: `maxSlots` × `memorySize` (8 × 4 GiB
              on a 64 GiB machine) must still leave room for CTFd and
              chall-manager. Claiming beyond it fails the allocator with exit
              code 4, which surfaces as a failed deploy in the CTFd UI.
            '';
          };

          basePort = lib.mkOption {
            type = lib.types.port;
            default = 2201;
            description = ''
              TCP port of the first slot's forwarded SSH. Slot `n` (starting
              at 1) listens on `basePort + n - 1`.
            '';
          };

          internalBasePort = lib.mkOption {
            type = lib.types.port;
            default = 42201;
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

          flagFormat = lib.mkOption {
            type = lib.types.str;
            default = "nixcon{homewort_%s}";
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
              User allowed to run `homewort-instance` through `sudo` without a
              password. This is chall-manager, whose Pulumi scenario is the
              only thing that claims and releases slots. `null` installs no
              sudo rule, leaving the allocator to root only.
            '';
          };

          readyTimeout = lib.mkOption {
            type = lib.types.ints.positive;
            default = 180;
            description = ''
              Seconds `homewort-instance create` waits for the guest's SSH
              banner before giving up, releasing the slot again and failing
              with exit code 5. A cold boot of the challenge image takes well
              under a minute. The headroom is for a host under load from seven
              other VMs.
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
            login = config.clan.core.vars.generators.homewort-login.files;

            slots = lib.range 1 settings.maxSlots;

            # Where the allocator keeps its slot bookkeeping. `<n>/identity`
            # marks the slot as claimed, `<n>/flag` is what fw_cfg hands to
            # that slot's guest.
            slotDir = "/var/lib/homewort-slots";

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
              inherit publicHost;
              # A non-secret var, already materialised at eval time: it is part
              # of the challenge description, so it may sit in the store.
              password = login.password.value;
              stateDir = slotDir;
              systemctl = "${config.systemd.package}/bin/systemctl";
            };

            # The scenario package puts a loose `Pulumi.yaml` and a prebuilt
            # `main` at the derivation root, because chall-manager loads a
            # scenario as one OCI layer per file and stats those two names. A
            # tarball layer would not load.
            scenario = pkgs.callPackage ./scenario/package.nix { };
            scenarioRef = "127.0.0.1:5000/homewort:${scenario.version}";

            pushScenario = pkgs.writeShellApplication {
              name = "homewort-scenario-push";
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

                echo "homewort scenario available as ${scenarioRef}"
              '';
            };

            # `mus-vm` is the challenge's own bootable variant: same machine as
            # `mus`, plus the closure an offline `sudo rebuildHome` needs already
            # in the guest store. The bootloader lives in the image so a player's
            # `nixos-rebuild switch` succeeds. The host Nix store is not shared
            # into the guest, and the guest has no egress.
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
                  description = "homewort challenge VM in slot ${toString n} (ssh on port ${toString port})";
                  # Nothing pulls this in: `homewort-instance create` starts it
                  # when a team claims the slot and `destroy` stops it again.
                  wantedBy = [ ];
                  after = [ "network.target" ];

                  environment = {
                    NIX_DISK_IMAGE = "/var/lib/${stateDir}/disk.qcow2";
                    # Loopback only: slirp rewrites a loopback client to its own
                    # host alias, which `restrict=on` lets the guest answer.
                    # Public traffic arrives through the -ssh proxy unit.
                    QEMU_NET_OPTS = "hostfwd=tcp:127.0.0.1:${toString internalPort}-:22";
                    # A root-only sysfs blob inside the guest, which the ctf-flag
                    # service installs as /etc/flag. The allocator writes
                    # this file before it starts the unit, so each claim of the
                    # slot gets a different flag.
                    QEMU_OPTS = "-fw_cfg name=opt/ctf/flag,file=${slotDir}/${toString n}/flag";
                  };

                  serviceConfig = {
                    ExecStart = "${vm}/bin/run-mus-vm";
                    # Players get root in there, so every start must begin from
                    # the pristine backing image.
                    ExecStartPre = "${pkgs.coreutils}/bin/rm -f /var/lib/${stateDir}/disk.qcow2";
                    # Reclaims the disk the moment the slot is released, and
                    # covers a crash or a manual stop too. The allocator
                    # deliberately does not do this itself: it runs inside
                    # chall-manager's mount namespace, where /var/lib is
                    # read-only apart from the slot directory.
                    ExecStopPost = "${pkgs.coreutils}/bin/rm -f /var/lib/${stateDir}/disk.qcow2";
                    # A player who bricks or powers off their box gets it back,
                    # with the same flag: the slot is still theirs.
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
            # banner never arrives. The public port therefore belongs to a host
            # process that talks to the guest over loopback.
            sshProxySocket = n: {
              name = "homewort-vm-${toString n}-ssh";
              value = {
                description = "Public SSH port of homewort challenge slot ${toString n}";
                wantedBy = [ "sockets.target" ];
                listenStreams = [ "${settings.address}:${toString (settings.basePort + n - 1)}" ];
              };
            };

            sshProxyService = n: {
              name = "homewort-vm-${toString n}-ssh";
              value = {
                description = "Forwards the public SSH port of homewort challenge slot ${toString n} into the guest";
                requires = [ "homewort-vm-${toString n}-ssh.socket" ];
                after = [
                  "homewort-vm-${toString n}-ssh.socket"
                  "homewort-vm-${toString n}.service"
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
            users.users.homewort = {
              isSystemUser = true;
              group = "homewort";
              description = "Runs the homewort challenge VMs";
            };
            users.groups.homewort = { };

            # The login players are given. It is public on purpose: it goes into
            # the challenge description. Rotating it means regenerating this and
            # redeploying, which rebuilds the image.
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

            environment.systemPackages = [ allocator ];

            # The slot directory is world-traversable so the VM services, which
            # run as `homewort` under `ProtectSystem=strict`, can read their own
            # `<n>/flag`.
            systemd.tmpfiles.rules = [ "d ${slotDir} 0755 root root -" ];

            security.sudo.extraRules = lib.optionals (settings.allowUser != null) [
              {
                users = [ settings.allowUser ];
                commands = [
                  {
                    # The profile path, not the allocator's store path: the
                    # Pulumi scenario hardcodes this command line and the
                    # profile path is the only one that survives a rebuild
                    # changing the allocator's hash.
                    command = "/run/current-system/sw/bin/homewort-instance";
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
                # chall-manager pulls the scenario from the host's registry every
                # time it deploys an instance, so the artifact has to be there
                # before the first team clicks "deploy".
                homewort-scenario-push = {
                  description = "Push the homewort Pulumi scenario to the local chall-manager registry";
                  after = [ "chall-manager-registry.service" ];
                  wants = [ "chall-manager-registry.service" ];
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                    # Layer titles are paths relative to the working directory,
                    # and chall-manager stats `Pulumi.yaml` and `main` at the
                    # artifact root.
                    WorkingDirectory = "${scenario}";
                    ExecStart = "${pushScenario}/bin/homewort-scenario-push";
                    # oras looks for a docker config under $HOME. The store path
                    # it works in is read-only, so give it the private tmpdir.
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
