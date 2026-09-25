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

            networkName = "challmgr";
            bridgeName = "challmgr0";
            subnet = "10.89.0.0/24";
            gateway = "10.89.0.1";

            registryStateDir = "/var/lib/chall-manager-registry";

            registryConfig = (pkgs.formats.yaml { }).generate "chall-manager-registry.yml" {
              version = "0.1";
              log.level = "info";
              storage = {
                filesystem.rootdirectory = registryStateDir;
                delete.enabled = true;
              };
              http.addr = "127.0.0.1:${toString settings.registryPort}";
              health.storagedriver.enabled = false;
            };

            servicePath = [
              pkgs.pulumi
              pkgs.pulumiPackages.pulumi-go
              pkgs.pulumiPackages.pulumi-command
              pkgs.go
              "/run/wrappers"
              "/run/current-system/sw"
            ];

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

            systemd.services.docker-network-challmgr = {
              description = "Create the ${networkName} docker network for chall-manager";
              after = [ "${backend}.service" ];
              requires = [ "${backend}.service" ];
              wantedBy = [ "multi-user.target" ];
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
                PULUMI_BACKEND_URL = "file://${settings.stateDir}/pulumi-state";
                PULUMI_HOME = "${settings.stateDir}/pulumi-home";
                PULUMI_SKIP_UPDATE_CHECK = "true";
                HOME = settings.stateDir;

                GOPROXY = "off";
                GOTOOLCHAIN = "local";
                GOCACHE = "${settings.stateDir}/go-cache";
                GOPATH = "${settings.stateDir}/go";
              };

              serviceConfig = {
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
                ReadWritePaths = [ settings.stateDir ] ++ settings.scenarioWritePaths;
                PrivateTmp = true;

                ProtectSystem = "strict";
                ProtectHome = true;
                ProtectKernelTunables = true;
                ProtectControlGroups = true;
                RestrictAddressFamilies = [
                  "AF_UNIX"
                  "AF_INET"
                  "AF_INET6"
                  "AF_NETLINK"
                ];
                RestrictSUIDSGID = true;
                LockPersonality = true;
              };
            };

            systemd.services.chall-manager-janitor = {
              description = "Delete expired chall-manager instances";
              after = [ "chall-manager.service" ];
              requires = [ "chall-manager.service" ];

              environment = otelEnv;

              serviceConfig = {
                Type = "oneshot";
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

            networking.firewall.interfaces.${bridgeName}.allowedTCPPorts = [ settings.port ];
          };
      };
  };
}
