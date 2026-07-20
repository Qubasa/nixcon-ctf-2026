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
        };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule =
          {
            config,
            pkgs,
            ...
          }:
          let
            secrets = config.clan.core.vars.generators.ctfd.files;
            backend = config.virtualisation.oci-containers.backend;
            backendBin = "${pkgs.${backend}}/bin/${backend}";
          in
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
          };
      };
  };
}
