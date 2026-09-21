{ inputs, ... }:
{
  _class = "clan.service";
  manifest.name = "ctfd";
  manifest.description = "Dockerized CTFd Capture The Flag platform with MariaDB and Redis, secrets managed through clan vars.";
  manifest.categories = [ "Web" ];
  manifest.readme = builtins.readFile ./README.md;

  roles.server = {
    description = "Runs the CTFd web app together with its MariaDB database and Redis cache as OCI containers on a single machine.";

    interface =
      { lib, ... }:
      {
        options = {
          folder = lib.mkOption {
            type = lib.types.str;
            default = "/var/lib/ctfd";
            description = "Directory holding uploads, logs, the MariaDB data and the Redis data.";
          };

          address = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            example = "0.0.0.0";
            description = ''
              Host address the CTFd container publishes to. Defaults to loopback,
              expecting a reverse proxy in front of it.
            '';
          };

          port = lib.mkOption {
            type = lib.types.port;
            default = 8000;
            description = "Host port CTFd is published on.";
          };

          workers = lib.mkOption {
            type = lib.types.ints.positive;
            default = 1;
            description = "Number of gunicorn workers CTFd runs.";
          };

          challManager = {
            apiUrl = lib.mkOption {
              type = lib.types.str;
              default = "http://10.89.0.1:8080";
              description = ''
                Base URL of the chall-manager HTTP gateway, as seen from inside
                the CTFd container. Defaults to the gateway address of the
                `challmgr` docker network, where the host-side chall-manager
                listens. The plugin refuses any scheme other than `http` and
                silently falls back to its own default, so do not put a proxy
                with TLS in front of it.
              '';
            };

            apiTimeout = lib.mkOption {
              type = lib.types.ints.positive;
              default = 600;
              description = ''
                Seconds the plugin waits for a chall-manager API call before
                giving up. Instance creation runs a full Pulumi deployment, so
                this needs to comfortably exceed a cold boot.
              '';
            };

            manaTotal = lib.mkOption {
              type = lib.types.ints.unsigned;
              default = 0;
              description = ''
                Mana budget each source may spend on instances. Zero disables the
                mana accounting entirely, which is what we want: capacity is
                bounded by the challenge's own slot count instead.
              '';
            };

            hideInstancesPanel = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Hide the "Instances" entry from the player menu bar. Unlike the
                other plugin settings this one is re-read from the environment on
                every CTFd start and has no admin-UI equivalent.
              '';
            };

            network = lib.mkOption {
              type = lib.types.str;
              default = "challmgr";
              description = ''
                Docker network the CTFd container is additionally attached to in
                order to reach chall-manager on the host. Created by the
                `chall-manager` service as `docker-network-<name>.service`.
              '';
            };
          };

          nginx = {
            enable = lib.mkEnableOption "an nginx reverse proxy with TLS (ACME) in front of CTFd";

            hostName = lib.mkOption {
              type = lib.types.str;
              example = "ctf.nixcon.org";
              description = ''
                Canonical public host name CTFd is served under. A Let's Encrypt
                certificate is obtained for it, so DNS must point at this machine
                and ports 80 and 443 must be reachable.
              '';
            };

            redirectHostNames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "ctf.immutable-byte.de" ];
              description = ''
                Further host names that resolve to this machine and answer with
                a permanent redirect to `hostName`. Each gets its own
                certificate, so every name must already point here. Keeps old
                links working while the scoreboard has a single origin for
                cookies, CSRF checks and the Anubis challenge.
              '';
            };

            acmeEmail = lib.mkOption {
              type = lib.types.str;
              example = "admin@immutable-byte.de";
              description = "Contact email for the Let's Encrypt account.";
            };

            anubis = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Put Anubis in front of CTFd as a proof-of-work anti-bot
                  challenge, using nginx subrequest authentication.
                '';
              };

              port = lib.mkOption {
                type = lib.types.port;
                default = 8923;
                description = "Loopback port the Anubis instance binds to.";
              };
            };
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
            secrets = config.clan.core.vars.generators.ctfd.files;
            backend = config.virtualisation.oci-containers.backend;
            backendBin = "${pkgs.${backend}}/bin/${backend}";
            proxy = settings.nginx;
            cm = settings.challManager;
            cmNetworkUnit = "docker-network-${cm.network}.service";
            # Upstream's `challenge_visible` decorator only looks at a
            # challenge's `state`, so a player can POST an instance of a
            # challenge that CTFd core hides behind unsolved prerequisites. The
            # patch teaches the decorator the same requirements check core
            # applies. Delete ./prerequisite-gate.patch and this binding once
            # ctfd-chall-manager enforces requirements itself: the patch stops
            # applying and the build fails loudly when that lands.
            challManagerSrc = pkgs.applyPatches {
              name = "ctfd-chall-manager-prereq-gate";
              src = inputs.ctfd-chall-manager;
              patches = [ ./prerequisite-gate.patch ];
            };
          in
          lib.mkMerge [
          {
            # Force docker: internal-network name resolution does not work with podman.
            virtualisation.oci-containers.backend = "docker";

            clan.core.vars.generators.ctfd = {
              files."db.env" = { };
              files."ctfd.env" = { };
              runtimeInputs = [
                pkgs.coreutils
                pkgs.openssl
              ];
              script = ''
                db_pass=$(openssl rand -hex 24)
                root_pass=$(openssl rand -hex 24)
                secret_key=$(openssl rand -hex 64)

                {
                  printf 'MARIADB_ROOT_PASSWORD=%s\n' "$root_pass"
                  printf 'MARIADB_PASSWORD=%s\n' "$db_pass"
                } > "$out/db.env"

                {
                  printf 'DATABASE_URL=mysql+pymysql://ctfd:%s@db/ctfd\n' "$db_pass"
                  printf 'SECRET_KEY=%s\n' "$secret_key"
                } > "$out/ctfd.env"
              '';
            };

            systemd.tmpfiles.rules = [
              "d ${settings.folder}/uploads 0755 1001 1001 - -"
              "d ${settings.folder}/logs 0755 1001 1001 - -"
              "d ${settings.folder}/mysql 0755 999 999 - -"
              "d ${settings.folder}/redis 0755 999 999 - -"
            ];

            # Create the internal network before the database container starts.
            # Because 'ctfd' depends on 'ctfd-db', this covers all three containers.
            systemd.services."${backend}-ctfd-db".preStart = ''
              ${backendBin} network inspect ctfd_internal ||
              ${backendBin} network create --internal ctfd_internal
            '';

            # The internal network has no outbound access, so attach ctfd to the
            # bridge network once it is up. It also has no gateway at all
            # (--internal), which is why the challmgr network is a second
            # attachment rather than a route: chall-manager runs on the host and
            # is only reachable through that network's gateway address.
            systemd.services."${backend}-ctfd" = {
              after = [ cmNetworkUnit ];
              wants = [ cmNetworkUnit ];
              postStart = ''
                for i in {1..15}; do
                  if ${backendBin} inspect ctfd >/dev/null 2>&1; then
                    ${backendBin} network connect bridge ctfd &&
                    ${backendBin} network connect ${cm.network} ctfd &&
                    exit 0
                  fi
                  sleep 1
                done
                echo "ctfd container not found..." >&2
                exit 1
              '';
            };

            virtualisation.oci-containers.containers = {
              ctfd-db = {
                # Digest-pinned like CTFd itself: `pull = "always"` on a
                # floating tag makes every container restart depend on Docker
                # Hub being reachable, which is the last thing that should be
                # able to take the scoreboard down mid-event.
                image = "mariadb:10.11@sha256:8020e05c4c498d06c87f0a1db010eb79bd6f8fb30e9b763d4690c34ce1e61008";
                pull = "missing";
                environment = {
                  MARIADB_USER = "ctfd";
                  MARIADB_DATABASE = "ctfd";
                  MARIADB_AUTO_UPGRADE = "1";
                };
                environmentFiles = [ secrets."db.env".path ];
                volumes = [ "${settings.folder}/mysql:/var/lib/mysql" ];
                cmd = [
                  "mysqld"
                  "--character-set-server=utf8mb4"
                  "--collation-server=utf8mb4_unicode_ci"
                  "--wait_timeout=28800"
                  "--log-warnings=0"
                ];
                extraOptions = [
                  "--network=ctfd_internal"
                  "--network-alias=db"
                ];
              };

              ctfd-cache = {
                image = "redis:4@sha256:2e03fdd159f4a08d2165ca1c92adde438ae4e3e6b0f74322ce013a78ee81c88d";
                pull = "missing";
                volumes = [ "${settings.folder}/redis:/data" ];
                extraOptions = [
                  "--network=ctfd_internal"
                  "--network-alias=cache"
                ];
              };

              ctfd = {
                # Pinned by digest: ctfd-chall-manager v0.10.1 is CI-tested
                # against exactly this build, and a floating tag could swap CTFd
                # out from under the plugin on any mid-event container restart.
                image = "ctfd/ctfd:3.8.7@sha256:284f1f06c5464108c4eaaea8a28934cb1e81d491e3f0fe60f3d686cf38593e41";
                pull = "missing";
                environment = {
                  REDIS_URL = "redis://cache:6379";
                  UPLOAD_FOLDER = "/var/uploads";
                  LOG_FOLDER = "/var/log/CTFd";
                  WORKERS = toString settings.workers;
                  REVERSE_PROXY = "true";
                  ACCESS_LOG = "-";
                  ERROR_LOG = "-";
                  # The plugin tree lives in the read-only nix store.
                  PYTHONDONTWRITEBYTECODE = "1";
                  # These three seed CTFd's config table on the very first plugin
                  # load only (guarded by the `chall-manager:setup` config key);
                  # afterwards they are ignored and the values are owned by the
                  # CTFd admin UI under Plugins > chall-manager.
                  PLUGIN_SETTINGS_CM_API_URL = cm.apiUrl;
                  PLUGIN_SETTINGS_CM_API_TIMEOUT = toString cm.apiTimeout;
                  PLUGIN_SETTINGS_CM_MANA_TOTAL = toString cm.manaTotal;
                  # Re-read on every start, unlike the three above.
                  PLUGIN_SETTINGS_CM_UI_HIDE_INSTANCES_PANEL = lib.boolToString cm.hideInstancesPanel;
                };
                environmentFiles = [ secrets."ctfd.env".path ];
                volumes = [
                  "${settings.folder}/uploads:/var/uploads"
                  "${settings.folder}/logs:/var/log/CTFd"
                  # Directory name is load-bearing: the plugin uses absolute
                  # `CTFd.plugins.ctfd_chall_manager.*` imports and derives both
                  # its asset endpoint and its migration path from the
                  # directory's basename, so it must be exactly this.
                  "${challManagerSrc}:/opt/CTFd/CTFd/plugins/ctfd_chall_manager:ro"
                ];
                ports = [ "${settings.address}:${toString settings.port}:8000" ];
                dependsOn = [
                  "ctfd-db"
                  "ctfd-cache"
                ];
                extraOptions = [
                  "--network=ctfd_internal"
                  "--network-alias=ctfd"
                ];
              };
            };
          }

          (lib.mkIf proxy.enable {
            networking.firewall.allowedTCPPorts = [
              80
              443
            ];

            security.acme.acceptTerms = true;
            security.acme.defaults.email = proxy.acmeEmail;

            services.nginx = {
              enable = true;
              recommendedProxySettings = true;
              recommendedTlsSettings = true;
              recommendedOptimisation = true;
              recommendedGzipSettings = true;

              virtualHosts =
                # Everything that is not the canonical name answers with a
                # permanent redirect, so cookies, CSRF origin checks and the
                # Anubis challenge only ever see one host.
                lib.genAttrs proxy.redirectHostNames (_: {
                  forceSSL = true;
                  enableACME = true;
                  globalRedirect = proxy.hostName;
                })
                // {
                  ${proxy.hostName} = {
                    forceSSL = true;
                    enableACME = true;

                    locations = {
                      "/" = {
                        proxyPass = "http://${settings.address}:${toString settings.port}";
                        proxyWebsockets = true;
                        # Gate every request on an Anubis proof-of-work challenge.
                        # https://anubis.techaro.lol/docs/admin/configuration/subrequest-auth
                        extraConfig = lib.optionalString proxy.anubis.enable ''
                          auth_request /.within.website/x/cmd/anubis/api/check;
                          error_page 401 = @redirectToAnubis;
                        '';
                      };
                    }
                    // lib.optionalAttrs proxy.anubis.enable {
                      "/.within.website/" = {
                        proxyPass = "http://127.0.0.1:${toString proxy.anubis.port}";
                        extraConfig = ''
                          auth_request off;
                          proxy_pass_request_body off;
                          proxy_set_header Content-Length "";
                        '';
                      };

                      "@redirectToAnubis".extraConfig = ''
                        return 307 /.within.website/?redir=$scheme://$host$request_uri;
                        auth_request off;
                      '';
                    };
                  };
                };
            };

            services.anubis.instances.ctfd = lib.mkIf proxy.anubis.enable {
              settings = {
                # Subrequest-auth mode: nginx proxies to CTFd, Anubis only
                # answers the auth_request check, so no upstream target here.
                TARGET = " ";
                BIND = "127.0.0.1:${toString proxy.anubis.port}";
                BIND_NETWORK = "tcp";
                OG_PASSTHROUGH = true;
                REDIRECT_DOMAINS = proxy.hostName;
              };
              policy.settings.status_codes = {
                CHALLENGE = 200;
                DENY = 403;
              };
            };
          })
          ];
      };
  };
}
