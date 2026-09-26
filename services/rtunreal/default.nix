{ inputs, ... }:
{
  _class = "clan.service";
  manifest.name = "rtunreal";
  manifest.description = "Hosts the `rtunreal` (Pimp my PHP) build challenge: a submission desk that takes a player's patch, grades it against the challenge flake's own checks inside a throwaway QEMU VM, and prints the flag when every check builds.";
  manifest.categories = [ "Web" ];
  manifest.readme = builtins.readFile ./README.md;

  roles.server = {
    description = "Runs the grading VM, the submission desk in front of it, and one nginx vhost on `publicPort`.";

    interface =
      { lib, ... }:
      {
        options = {
          port = lib.mkOption {
            type = lib.types.port;
            default = 3000;
            description = ''
              Port the check runner listens on *inside* the guest. Nothing on
              the host reaches it except through `internalPort`.
            '';
          };

          internalPort = lib.mkOption {
            type = lib.types.port;
            default = 43002;
            description = ''
              Loopback port QEMU forwards `port` to. It is loopback only because
              slirp's `restrict=on` drops replies to any client that is not the
              host alias, so the public side has to be a host process (here the
              submission desk).
            '';
          };

          gatewayPort = lib.mkOption {
            type = lib.types.port;
            default = 43003;
            description = ''
              Loopback port the submission desk listens on. nginx proxies
              `publicPort` to it.
            '';
          };

          publicPort = lib.mkOption {
            type = lib.types.port;
            default = 8082;
            description = ''
              Public plain-HTTP port of the vhost. 80 and 443 belong to CTFd
              and gitea, 8080 to chall-manager.
            '';
          };

          memorySize = lib.mkOption {
            type = lib.types.ints.positive;
            default = 6144;
            description = ''
              Guest RAM in MiB. It has to hold one nixpkgs evaluation per check
              and up to two parallel builders.
            '';
          };

          cores = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4;
            description = "Guest vCPUs.";
          };

          diskSize = lib.mkOption {
            type = lib.types.ints.positive;
            default = 40960;
            description = ''
              Overlay disk in MiB, a sparse upper bound. It holds the seeded
              closure plus whatever submissions build until the guest's hourly
              garbage collection frees it again.
            '';
          };

          checkTimeout = lib.mkOption {
            type = lib.types.ints.positive;
            default = 600;
            description = "Seconds one check may build before it is failed.";
          };

          totalTimeout = lib.mkOption {
            type = lib.types.ints.positive;
            default = 900;
            description = ''
              Seconds one submission may take in total. Checks that no longer
              fit are reported as skipped rather than silently passing.
            '';
          };

          maxPatchBytes = lib.mkOption {
            type = lib.types.ints.positive;
            default = 512 * 1024;
            description = "Largest submission accepted, in bytes.";
          };

          flagFormat = lib.mkOption {
            type = lib.types.str;
            default = "nixcon{rtunreal_%s}";
            description = ''
              `printf` format of the flag, one `%s` for the random part. The
              host holds it and the submission desk hands it out. It never
              reaches the guest.
            '';
          };

          nginx = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Serve the submission desk through an nginx vhost.";
            };

            hostName = lib.mkOption {
              type = lib.types.str;
              example = "ctf.nixcon.org";
              description = ''
                `server_name` of the vhost. The vhost is `default` on its
                port, so a request with a bare IP in `Host` is served too.
              '';
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
            flag = config.clan.core.vars.generators.rtunreal.files.flag;

            stateDir = "/var/lib/rtunreal-vm";

            gateway = (pkgs.callPackage ./package.nix { }).gateway;

            published = pkgs.callPackage ./source.nix { src = inputs.rtunreal; };

            tarball = pkgs.runCommand "rtunreal-challenge.tar.gz" { } ''
              cp -r ${published} rtunreal-challenge
              chmod -R u+w rtunreal-challenge
              tar --sort=name --owner=0 --group=0 --numeric-owner \
                  --mtime=@1 -czf $out rtunreal-challenge
            '';

            vm = import ./vm.nix {
              inherit pkgs;
              inherit (settings)
                port
                checkTimeout
                totalTimeout
                maxPatchBytes
                memorySize
                cores
                diskSize
                ;
              hostPort = settings.internalPort;
              src-rtunreal = inputs.rtunreal;
              challengeNixpkgs = inputs.rtunreal-nixpkgs;
            };
          in
          lib.mkMerge [
            {
              users.users.rtunreal = {
                isSystemUser = true;
                group = "rtunreal";
                description = "Runs the rtunreal submission desk, holds the flag";
              };
              users.groups.rtunreal = { };

              users.users.rtunreal-vm = {
                isSystemUser = true;
                group = "rtunreal-vm";
                description = "Runs the rtunreal grading VM, never sees the flag";
              };
              users.groups.rtunreal-vm = { };

              clan.core.vars.generators.rtunreal = {
                files.flag = {
                  secret = true;
                  owner = "rtunreal";
                  group = "rtunreal";
                  mode = "0400";
                  restartUnits = [ "rtunreal-gateway.service" ];
                };
                runtimeInputs = [
                  pkgs.coreutils
                  pkgs.openssl
                ];
                script = ''
                  printf '${settings.flagFormat}' "$(openssl rand -hex 16)" > "$out/flag"
                '';
              };

              systemd.services.rtunreal-vm = {
                description = "rtunreal challenge grading VM";
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];

                environment = {
                  NIX_DISK_IMAGE = "${stateDir}/disk-${builtins.substring 0 12 (baseNameOf vm)}.qcow2";
                };

                serviceConfig = {
                  ExecStart = "${vm}/bin/run-rtunreal-vm";
                  Restart = "always";
                  RestartSec = 5;

                  User = "rtunreal-vm";
                  Group = "rtunreal-vm";
                  SupplementaryGroups = [ "kvm" ];
                  StateDirectory = "rtunreal-vm";
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

              systemd.services.rtunreal-gateway = {
                description = "rtunreal submission desk";
                wantedBy = [ "multi-user.target" ];
                after = [
                  "network.target"
                  "rtunreal-vm.service"
                ];
                wants = [ "rtunreal-vm.service" ];

                environment = {
                  RTUNREAL_PORT = toString settings.gatewayPort;
                  RTUNREAL_BUILDER = "http://127.0.0.1:${toString settings.internalPort}";
                  RTUNREAL_FLAG_FILE = flag.path;
                  RTUNREAL_TARBALL = "${tarball}";
                  RTUNREAL_MAX_PATCH = toString settings.maxPatchBytes;
                  RTUNREAL_PUBLIC_URL = lib.optionalString settings.nginx.enable "http://${settings.nginx.hostName}:${toString settings.publicPort}";
                  RTUNREAL_TIMEOUT = toString (settings.totalTimeout + 120);
                };

                serviceConfig = {
                  ExecStart = lib.getExe gateway;
                  Restart = "always";
                  RestartSec = 5;

                  User = "rtunreal";
                  Group = "rtunreal";

                  NoNewPrivileges = true;
                  ProtectSystem = "strict";
                  ProtectHome = true;
                  PrivateTmp = true;
                  PrivateDevices = true;
                  ProtectKernelTunables = true;
                  ProtectKernelModules = true;
                  ProtectControlGroups = true;
                  RestrictAddressFamilies = [
                    "AF_UNIX"
                    "AF_INET"
                    "AF_INET6"
                  ];
                  RestrictSUIDSGID = true;
                  LockPersonality = true;
                  SystemCallFilter = [ "@system-service" ];
                  MemoryDenyWriteExecute = true;
                };
              };
            }

            (lib.mkIf settings.nginx.enable {
              networking.firewall.allowedTCPPorts = [ settings.publicPort ];

              services.nginx = {
                enable = true;
                recommendedProxySettings = true;
                recommendedTlsSettings = true;
                recommendedOptimisation = true;
                recommendedGzipSettings = true;

                appendHttpConfig = ''
                  limit_req_zone $binary_remote_addr zone=rtunreal_submit:4m rate=6r/m;
                '';

                virtualHosts.rtunreal = {
                  serverName = settings.nginx.hostName;
                  default = true;
                  listen = [
                    {
                      addr = "0.0.0.0";
                      port = settings.publicPort;
                    }
                    {
                      addr = "[::]";
                      port = settings.publicPort;
                    }
                  ];

                  locations = {
                    "/" = {
                      proxyPass = "http://127.0.0.1:${toString settings.gatewayPort}";
                    };

                    "/submit" = {
                      proxyPass = "http://127.0.0.1:${toString settings.gatewayPort}";
                      extraConfig = ''
                        limit_req zone=rtunreal_submit burst=3 nodelay;
                        limit_req_status 429;
                        client_max_body_size ${toString settings.maxPatchBytes};
                        # Grading takes minutes and outruns nginx's 60s
                        # default, which would hand the player a 504 while the
                        # build keeps running.
                        proxy_read_timeout ${toString (settings.totalTimeout + 180)}s;
                        proxy_send_timeout ${toString (settings.totalTimeout + 180)}s;
                      '';
                    };
                  };
                };
              };
            })
          ];
      };
  };
}
