{ ... }:
{
  _class = "clan.service";
  manifest.name = "chall-manager";
  manifest.description = "Runs ctfer-io/chall-manager natively, so CTFd can deploy a private Pulumi-built instance of a challenge per team and reclaim it when it expires.";
  manifest.categories = [ "Utility" ];
  manifest.readme = builtins.readFile ./README.md;

  roles.server = {
    description = "Runs the chall-manager API, its janitor, and the local OCI registry that holds the deployment scenarios, all reachable only from the `challmgr` docker network.";

    interface =
      { lib, ... }:
      {
        options = {
          port = lib.mkOption {
            type = lib.types.port;
            default = 8080;
            description = ''
              Single TCP port serving both the gRPC API and the HTTP/JSON
              gateway: upstream cmux-multiplexes them on one listener, so the
              CTFd plugin (REST, over the `challmgr` bridge at `10.89.0.1`) and
              the janitor (gRPC, over loopback) share it.

              chall-manager has no listen-address flag and always binds
              `0.0.0.0`. It also has no authentication at all, so this port is
              only ever opened on the `challmgr0` bridge.
            '';
          };

          registryPort = lib.mkOption {
            type = lib.types.port;
            default = 5000;
            description = ''
              Port of the local OCI registry on `127.0.0.1`, plain HTTP. It
              holds the deployment scenarios. Challenge services push theirs
              into it at boot and chall-manager pulls them from there.
            '';
          };

          janitorInterval = lib.mkOption {
            type = lib.types.str;
            default = "5min";
            description = ''
              systemd time span between janitor runs. The janitor is what makes
              the deployment unattended: every run asks chall-manager for the
              instances whose `until` has passed and deletes them, which is
              what releases the underlying challenge slot.

              Upstream can also loop internally (`--ticker`), but a oneshot
              plus a timer keeps the retry and logging semantics in systemd.
            '';
          };

          stateDir = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/chall-manager";
            description = ''
              Root of chall-manager's persistent state. It holds the challenge
              and instance records, the unpacked scenarios, and the Pulumi
              stack states (see `services/chall-manager/README.md` for the
              layout). Losing it orphans every running instance.
            '';
          };

          scenarioWritePaths = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "/var/lib/homewort-slots" ];
            description = ''
              Extra paths a deployment scenario has to be able to write to.

              A scenario runs as a child of this service and therefore inside
              its mount namespace, where `ProtectSystem = "strict"` leaves the
              whole file system read-only. The restriction applies to a `sudo`
              child too: namespaces are inherited, and being root inside one
              changes nothing. A scenario whose allocator keeps state outside
              `stateDir` therefore fails with EROFS until its directory is
              listed here.

              Prefix an entry with `-` to make it optional if it may not exist
              yet when this service starts.
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
            chall-manager = pkgs.callPackage ../../pkgs/chall-manager.nix { };

            backend = config.virtualisation.oci-containers.backend;
            backendBin = "${pkgs.${backend}}/bin/${backend}";

            # Fixed on purpose, not options. The firewall rule below keys on the
            # bridge name and the CTFd plugin is configured with the literal
            # gateway address, so these three values are a contract between
            # services/chall-manager and services/ctfd, not a knob.
            networkName = "challmgr";
            bridgeName = "challmgr0";
            subnet = "10.89.0.0/24";
            gateway = "10.89.0.1";

            registryStateDir = "/var/lib/chall-manager-registry";

            # A hand-written unit rather than `services.dockerRegistry`: that
            # module names its unit `docker-registry.service`, which challenge
            # services would then have to order against, and it brings its own
            # storage path and garbage-collection timer. Overriding all of that
            # is more code than the fifteen lines below.
            registryConfig = (pkgs.formats.yaml { }).generate "chall-manager-registry.yml" {
              version = "0.1";
              log.level = "info";
              storage = {
                filesystem.rootdirectory = registryStateDir;
                # Scenarios are re-pushed under the same tag on every deploy;
                # without delete the old manifests are unreachable garbage.
                delete.enabled = true;
              };
              http.addr = "127.0.0.1:${toString settings.registryPort}";
              health.storagedriver.enabled = false;
            };

            # chall-manager shells out to the Pulumi CLI through the automation
            # API, with an empty plugin cache and no egress: `pulumi` must find
            # its language host and every provider it needs as ambient plugins
            # on PATH, or it tries to download them and fails.
            #
            # `go` is not optional even though the scenario ships a prebuilt
            # binary: pulumi-language-go 3.192 runs a "discover package
            # requirements" pass over the program directory on every preview and
            # up, and without a `go` on PATH it aborts the whole deployment with
            # `couldn't find go binary`. We verified this against chall-manager
            # 0.6.6: CreateChallenge fails validation without `go` and succeeds with it.
            #
            # The two profile directories are plain strings rather than
            # packages: the scenario reaches the challenge host through
            # `sudo homewort-instance`, neither of which is a store path we can
            # refer to. `path` takes both forms and appends `/bin` itself, and
            # it leaves the minimal default service PATH in place, which setting
            # `environment.PATH` by hand would collide with.
            servicePath = [
              pkgs.pulumi
              pkgs.pulumiPackages.pulumi-go
              pkgs.pulumiPackages.pulumi-command
              pkgs.go
              "/run/wrappers"
              "/run/current-system/sw"
            ];

            # Upstream wires traces and logs through OTel autoexport, which
            # defaults to OTLP at localhost:4318 and would fail on every batch.
            # Metrics bypass autoexport and are hardcoded to an OTLP gRPC
            # exporter that cannot be turned off, so the export interval is
            # stretched to a day to keep it out of the journal.
            otelEnv = {
              OTEL_TRACES_EXPORTER = "none";
              OTEL_LOGS_EXPORTER = "none";
              OTEL_METRIC_EXPORT_INTERVAL = "86400000";
            };
          in
          {
            users.users.chall-manager = {
              isSystemUser = true;
              group = "chall-manager";
              description = "Runs the chall-manager API and its Pulumi scenarios";
            };
            users.groups.chall-manager = { };

            systemd.tmpfiles.rules = [
              "d ${settings.stateDir} 0700 chall-manager chall-manager - -"
              "d ${settings.stateDir}/store 0700 chall-manager chall-manager - -"
              "d ${settings.stateDir}/cache 0700 chall-manager chall-manager - -"
              "d ${settings.stateDir}/pulumi-state 0700 chall-manager chall-manager - -"
              "d ${settings.stateDir}/pulumi-home 0700 chall-manager chall-manager - -"
              "d ${settings.stateDir}/go-cache 0700 chall-manager chall-manager - -"
              "d ${settings.stateDir}/go 0700 chall-manager chall-manager - -"
            ];

            # The bridge name is the point of creating the network by hand: the
            # firewall rule below matches on `challmgr0`, so docker must not be
            # allowed to pick its usual `br-<hash>` name.
            systemd.services.docker-network-challmgr = {
              description = "Create the ${networkName} docker network for chall-manager";
              after = [ "${backend}.service" ];
              requires = [ "${backend}.service" ];
              wantedBy = [ "multi-user.target" ];
              # Ordering only: a container that joins the network at start-up
              # needs it to exist, but this service must not drag CTFd in.
              before = [
                "${backend}-ctfd-db.service"
                "${backend}-ctfd.service"
              ];

              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };

              script = ''
                ${backendBin} network inspect ${networkName} >/dev/null 2>&1 ||
                  ${backendBin} network create \
                    --subnet ${subnet} \
                    --gateway ${gateway} \
                    -o com.docker.network.bridge.name=${bridgeName} \
                    ${networkName}
              '';
            };

            systemd.services.chall-manager-registry = {
              description = "Local OCI registry holding chall-manager deployment scenarios";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];

              serviceConfig = {
                ExecStart = "${pkgs.distribution}/bin/registry serve ${registryConfig}";
                Restart = "on-failure";
                RestartSec = 5;

                DynamicUser = true;
                StateDirectory = "chall-manager-registry";
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

            systemd.services.chall-manager = {
              description = "chall-manager: challenge instances on demand";
              wantedBy = [ "multi-user.target" ];
              after = [
                "network.target"
                "chall-manager-registry.service"
              ];
              wants = [ "chall-manager-registry.service" ];

              path = servicePath;

              environment = otelEnv // {
                # Pulumi keeps the per-instance stack state in a local file
                # backend and must never reach out to the Pulumi service.
                PULUMI_BACKEND_URL = "file://${settings.stateDir}/pulumi-state";
                PULUMI_HOME = "${settings.stateDir}/pulumi-home";
                PULUMI_SKIP_UPDATE_CHECK = "true";
                # Belt and braces: nothing should fall back to $HOME, but if it
                # does it must land inside the state directory.
                HOME = settings.stateDir;

                # The Go toolchain above is only ever asked to inspect the
                # program directory, never to fetch anything: `off` turns a
                # module lookup into an immediate error instead of a hang, and
                # `local` stops it from trying to download another toolchain.
                # Both caches are redirected out of $HOME/.cache, which
                # ProtectSystem=strict would not let it create.
                GOPROXY = "off";
                GOTOOLCHAIN = "local";
                GOCACHE = "${settings.stateDir}/go-cache";
                GOPATH = "${settings.stateDir}/go";
              };

              serviceConfig = {
                # `--dir` is the challenge/instance record store, and `--cache`
                # is where scenarios are unpacked and where Pulumi runs them
                # from. Both must be writable. Left at its default, the cache
                # would land in $HOME/.cache.
                #
                # `--oci.insecure` is global, not per-registry: upstream has no
                # per-host setting. The switch is acceptable because the only
                # registry configured is 127.0.0.1, and it is plain HTTP.
                #
                # No `--swagger`: it serves files relative to the working
                # directory, which do not exist in the store path.
                ExecStart = lib.concatStringsSep " " [
                  "${chall-manager}/bin/chall-manager"
                  "--port ${toString settings.port}"
                  "--dir ${settings.stateDir}/store"
                  "--cache ${settings.stateDir}/cache"
                  "--oci.insecure"
                ];
                Restart = "on-failure";
                RestartSec = 5;

                User = "chall-manager";
                Group = "chall-manager";
                # The scenario's own state lives outside `stateDir`: it runs in
                # this namespace, and so does the `sudo` allocator it calls.
                ReadWritePaths = [ settings.stateDir ] ++ settings.scenarioWritePaths;
                PrivateTmp = true;

                # `NoNewPrivileges` is impossible here: the deployment scenario
                # allocates a challenge slot by calling `sudo homewort-instance`,
                # and sudo is setuid. Everything below is the compensation.
                ProtectSystem = "strict";
                ProtectHome = true;
                ProtectKernelTunables = true;
                ProtectControlGroups = true;
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_INET"
                  "AF_INET6"
                  # sudo's audit socket and NSS lookups.
                  "AF_NETLINK"
                ];
                RestrictSUIDSGID = true;
                LockPersonality = true;
              };
            };

            # The janitor makes the deployment unattended: instances carry an
            # expiry, and nothing removes them until the janitor asks for the
            # expired ones.
            systemd.services.chall-manager-janitor = {
              description = "Delete expired chall-manager instances";
              after = [ "chall-manager.service" ];
              requires = [ "chall-manager.service" ];

              environment = otelEnv;

              serviceConfig = {
                Type = "oneshot";
                # A bare gRPC target: the janitor dials with insecure
                # credentials and rejects a URL carrying a scheme.
                ExecStart = "${chall-manager}/bin/chall-manager-janitor --url 127.0.0.1:${toString settings.port}";

                DynamicUser = true;
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

            systemd.timers.chall-manager-janitor = {
              description = "Periodic reclaim of expired chall-manager instances";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnActiveSec = settings.janitorInterval;
                OnUnitActiveSec = settings.janitorInterval;
                Unit = "chall-manager-janitor.service";
              };
            };

            # chall-manager runs arbitrary Pulumi programs as a service with
            # sudo rights and authenticates nobody, and upstream calls it
            # RCE-as-a-Service. Reaching this port is owning the host, so it is
            # bound to the bridge CTFd sits on and never to a public interface.
            networking.firewall.interfaces.${bridgeName}.allowedTCPPorts = [ settings.port ];
          };
      };
  };
}
