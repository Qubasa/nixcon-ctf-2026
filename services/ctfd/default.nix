{ ... }:
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

          nginx = {
            enable = lib.mkEnableOption "an nginx reverse proxy with TLS (ACME) in front of CTFd";

            hostName = lib.mkOption {
              type = lib.types.str;
              example = "ctf.immutable-byte.de";
              description = ''
                Public host name CTFd is served under. A Let's Encrypt
                certificate is obtained for it, so DNS must point at this machine
                and ports 80 and 443 must be reachable.
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
            # bridge network once it is up.
            systemd.services."${backend}-ctfd".postStart = ''
              for i in {1..15}; do
                if ${backendBin} inspect ctfd >/dev/null 2>&1; then
                  ${backendBin} network connect bridge ctfd && exit 0
                fi
                sleep 1
              done
              echo "ctfd container not found..." >&2
              exit 1
            '';

            virtualisation.oci-containers.containers = {
              ctfd-db = {
                image = "mariadb:10.11";
                pull = "always";
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
                image = "redis:4";
                pull = "always";
                volumes = [ "${settings.folder}/redis:/data" ];
                extraOptions = [
                  "--network=ctfd_internal"
                  "--network-alias=cache"
                ];
              };

              ctfd = {
                image = "ctfd/ctfd:latest";
                pull = "always";
                environment = {
                  REDIS_URL = "redis://cache:6379";
                  UPLOAD_FOLDER = "/var/uploads";
                  LOG_FOLDER = "/var/log/CTFd";
                  WORKERS = toString settings.workers;
                  REVERSE_PROXY = "true";
                  ACCESS_LOG = "-";
                  ERROR_LOG = "-";
                };
                environmentFiles = [ secrets."ctfd.env".path ];
                volumes = [
                  "${settings.folder}/uploads:/var/uploads"
                  "${settings.folder}/logs:/var/log/CTFd"
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

              virtualHosts.${proxy.hostName} = {
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
