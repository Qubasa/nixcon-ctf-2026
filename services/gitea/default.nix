{ ... }:
{
  _class = "clan.service";
  manifest.name = "gitea";
  manifest.description = "Gitea git forge backed by PostgreSQL, fronted by nginx with TLS and an Anubis anti-bot challenge.";
  manifest.categories = [ "Web" ];
  manifest.readme = builtins.readFile ./README.md;

  roles.server = {
    description = "Runs Gitea with a PostgreSQL database managed through clan.core.postgresql.";

    interface =
      { lib, ... }:
      {
        options = {
          hostName = lib.mkOption {
            type = lib.types.str;
            example = "git.immutable-byte.de";
            description = ''
              Public host name Gitea is served under. It is used for the root
              URL, the ACME certificate, and the Anubis redirect domain.
            '';
          };

          port = lib.mkOption {
            type = lib.types.port;
            default = 3000;
            description = "Loopback port Gitea's HTTP server binds to.";
          };

          disableRegistration = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Only let administrators create accounts.";
          };

          nginx = {
            enable = lib.mkEnableOption "an nginx reverse proxy with TLS (ACME) in front of Gitea" // {
              default = true;
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
                  Put Anubis in front of Gitea as a proof-of-work anti-bot
                  challenge, using nginx subrequest authentication.
                '';
              };

              port = lib.mkOption {
                type = lib.types.port;
                default = 3001;
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
            lib,
            ...
          }:
          let
            proxy = settings.nginx;
          in
          lib.mkMerge [
            {
              clan.core.postgresql.enable = true;
              clan.core.postgresql.users.gitea = { };
              clan.core.postgresql.databases.gitea.create.options = {
                TEMPLATE = "template0";
                LC_COLLATE = "C";
                LC_CTYPE = "C";
                ENCODING = "UTF8";
                OWNER = "gitea";
              };
              clan.core.postgresql.databases.gitea.restore.stopOnRestore = [ "gitea" ];

              clan.core.state.gitea = {
                folders = [ "/var/lib/gitea" ];
                preBackupScript = ''
                  export PATH=${lib.makeBinPath [ config.systemd.package ]}
                  systemctl stop gitea.service
                '';
                postBackupScript = ''
                  export PATH=${lib.makeBinPath [ config.systemd.package ]}
                  systemctl start gitea.service
                '';
              };

              # Registration is off, so the first admin has to be created with
              # the CLI on the machine.
              environment.systemPackages = [ config.services.gitea.package ];

              services.gitea = {
                enable = true;
                database.type = "postgres";
                settings = {
                  session.COOKIE_SECURE = true;
                  service.DISABLE_REGISTRATION = settings.disableRegistration;
                  server = {
                    ROOT_URL = "https://${settings.hostName}";
                    HTTP_ADDR = "localhost";
                    HTTP_PORT = settings.port;
                    DOMAIN = settings.hostName;
                    LEVEL = "Warn";
                  };
                  other = {
                    SHOW_FOOTER_VERSION = false;
                  };
                };
              };
            }

            (lib.mkIf proxy.enable {
              networking.firewall.allowedTCPPorts = [
                80
                443
              ];

              security.acme.acceptTerms = true;
              security.acme.defaults.email = lib.mkDefault proxy.acmeEmail;

              services.nginx = {
                enable = true;
                recommendedProxySettings = true;
                recommendedTlsSettings = true;
                recommendedOptimisation = true;
                recommendedGzipSettings = true;

                virtualHosts.${settings.hostName} = {
                  forceSSL = true;
                  enableACME = true;

                  locations = {
                    "/" = {
                      proxyPass = "http://localhost:${toString settings.port}";
                      proxyWebsockets = true;
                      # Gate every request on an Anubis proof-of-work challenge.
                      # https://anubis.techaro.lol/docs/admin/configuration/subrequest-auth
                      extraConfig = lib.optionalString proxy.anubis.enable ''
                        auth_request /.within.website/x/cmd/anubis/api/check;
                        error_page 401 = @redirectToAnubis;
                      '';
                    };

                    "= /robots.txt".alias = ./robots.txt;
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

              services.anubis.instances.gitea = lib.mkIf proxy.anubis.enable {
                settings = {
                  # Subrequest-auth mode: nginx proxies to Gitea and Anubis only
                  # answers the auth_request check, so it needs no upstream target.
                  TARGET = " ";
                  BIND = "127.0.0.1:${toString proxy.anubis.port}";
                  BIND_NETWORK = "tcp";
                  OG_PASSTHROUGH = true;
                  # https://anubis.techaro.lol/docs/admin/configuration/redirect-domains
                  REDIRECT_DOMAINS = settings.hostName;
                };
                policy = {
                  settings.status_codes = {
                    CHALLENGE = 200;
                    DENY = 403;
                  };
                  # https://github.com/TecharoHQ/anubis/blob/main/data/apps/gitea-rss-feeds.yaml
                  extraBots = [
                    { import = "(data)/apps/gitea-rss-feeds.yaml"; }
                  ];
                };
              };
            })
          ];
      };
  };
}
