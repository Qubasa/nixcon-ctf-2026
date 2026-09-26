{ inputs, ... }:
{
  _class = "clan.service";
  manifest.name = "baas";
  manifest.description = "Hosts the `baas` challenge, an Express app that hands `nix-build` whatever expression a player posts, inside a QEMU VM of its own, and proxies it onto a public plain-HTTP port.";
  manifest.categories = [ "Web" ];
  manifest.readme = builtins.readFile ./README.md;

  roles.server = {
    description = "Runs the single shared baas VM, forwards its app port to loopback and serves it through an nginx vhost on `publicPort`.";

    interface =
      { lib, ... }:
      {
        options = {
          port = lib.mkOption {
            type = lib.types.port;
            default = 3000;
            description = ''
              Port the app listens on inside the guest. The port is
              guest-internal, so the app's own default is fine here, although
              on the host itself 3000 is gitea's.
            '';
          };

          internalPort = lib.mkOption {
            type = lib.types.port;
            default = 43000;
            description = ''
              Loopback port QEMU forwards the guest's app port to. Players never
              see it: the public port belongs to nginx, which reaches the guest
              over loopback and adds the rate limit and `X-Forwarded-For` the
              app keys its listings on.
            '';
          };

          publicPort = lib.mkOption {
            type = lib.types.port;
            default = 8081;
            description = ''
              Port the nginx vhost listens on. It cannot be 80 or 443, because
              those belong to CTFd and gitea, whose certificates cover their own
              names. It cannot be 8080 either, because chall-manager has no
              listen-address flag and already binds `0.0.0.0:8080`.
            '';
          };

          memorySize = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4096;
            description = ''
              RAM for the VM in MiB. Every `POST /build` evaluates the whole of
              nixpkgs in the app process, a few hundred MiB on its own, and the
              builds it kicks off run in the same guest.
            '';
          };

          cores = lib.mkOption {
            type = lib.types.ints.positive;
            default = 2;
            description = "Virtual CPUs for the VM.";
          };

          diskSize = lib.mkOption {
            type = lib.types.ints.positive;
            default = 40960;
            description = ''
              Size in MiB of the VM's writable overlay. It is a sparse qcow2
              backed by the read-only system image, so this is an upper bound,
              not an allocation. It has to hold every derivation every player
              builds for the length of the event: nothing collects the guest's
              store, because a garbage collection would break the store paths
              players are still holding links to.
            '';
          };

          flagFormat = lib.mkOption {
            type = lib.types.str;
            default = "nixcon{baas_%s}";
            description = ''
              `printf` template the `baas` generator fills with 32 hex
              characters to mint the flag. It must contain exactly one `%s`.
            '';
          };

          nginx = {
            enable = lib.mkEnableOption "an nginx reverse proxy in front of the challenge VM";

            hostName = lib.mkOption {
              type = lib.types.str;
              example = "ctf.nixcon.org";
              description = ''
                Host name the vhost is named after. It needs no certificate and
                no record of its own: the vhost is plain HTTP on `publicPort`
                and is the default server there, so it also answers a bare IP.
              '';
            };

            anubis = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Put Anubis in front of the app as a proof-of-work anti-bot
                  challenge. It is off by default, unlike CTFd's: this challenge
                  is driven by `curl` and scripts, and a browser interstitial
                  breaks every non-browser client.
                '';
              };

              port = lib.mkOption {
                type = lib.types.port;
                default = 8924;
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
            flag = config.clan.core.vars.generators.baas.files.flag;

            proxy = settings.nginx;

            stateDir = "/var/lib/baas-vm";

            upstream = "http://127.0.0.1:${toString settings.internalPort}";

            # QEMU's slirp opens the guest's outbound connections from its own
            # process, so matching the `baas` user catches exactly the guest.
            fromVm = "-m owner --uid-owner baas";
            newFromVm = "${fromVm} -m conntrack --ctstate NEW";

            # The guard rule rejects new guest connections while the chain is
            # rebuilt, so a firewall reload never opens a window.
            egressFilter =
              {
                cmd,
                allow,
                deny,
              }:
              ''
                ${cmd} -w -C OUTPUT ${newFromVm} -j REJECT 2>/dev/null \
                  || ${cmd} -w -I OUTPUT 1 ${newFromVm} -j REJECT
                ${cmd} -w -N baas-egress 2>/dev/null || ${cmd} -w -F baas-egress
                ${cmd} -w -A baas-egress -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
                ${lib.concatMapStrings (rule: "${cmd} -w -A baas-egress ${rule} -j ACCEPT\n") allow}
                ${cmd} -w -A baas-egress -m addrtype --dst-type LOCAL -j REJECT
                ${cmd} -w -A baas-egress -d ${lib.concatStringsSep "," deny} -j REJECT
                ${cmd} -w -C OUTPUT ${fromVm} -j baas-egress 2>/dev/null \
                  || ${cmd} -w -I OUTPUT 2 ${fromVm} -j baas-egress
                ${cmd} -w -D OUTPUT ${newFromVm} -j REJECT
              '';

            resolvedStub = lib.optionals config.services.resolved.enable [
              "-d 127.0.0.53 -p udp --dport 53"
              "-d 127.0.0.53 -p tcp --dport 53"
            ];

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

            proxyTimeouts = ''
              # A cold nix-build in the guest takes minutes and outruns nginx's
              # 60s default, which would hand the player a 504 while the build
              # keeps running.
              proxy_read_timeout 600s;
              proxy_send_timeout 600s;
            '';

            anubisGate = lib.optionalString proxy.anubis.enable ''
              auth_request /.within.website/x/cmd/anubis/api/check;
              error_page 401 = @redirectToAnubis;
            '';
          in
          lib.mkMerge [
            {
              assertions = [
                {
                  assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
                  message = ''
                    services/baas: the baas VM has internet access, and only the iptables
                    rules in networking.firewall.extraCommands keep it off this host's
                    loopback and private networks. Enable networking.firewall with the
                    iptables backend.
                  '';
                }
              ];

              networking.firewall.extraCommands =
                egressFilter {
                  cmd = "iptables";
                  allow = resolvedStub;
                  deny = [
                    "0.0.0.0/8"
                    "10.0.0.0/8"
                    "100.64.0.0/10"
                    "127.0.0.0/8"
                    "169.254.0.0/16"
                    "172.16.0.0/12"
                    "192.168.0.0/16"
                    "224.0.0.0/3"
                  ];
                }
                + lib.optionalString config.networking.enableIPv6 (egressFilter {
                  cmd = "ip6tables";
                  allow = [ ];
                  deny = [
                    "::/128"
                    "::1/128"
                    "::ffff:0:0/96"
                    "fc00::/7"
                    "fe80::/10"
                    "ff00::/8"
                  ];
                });

              users.users.baas = {
                isSystemUser = true;
                group = "baas";
                description = "Runs the baas challenge VM";
              };
              users.groups.baas = { };

              clan.core.vars.generators.baas = {
                files.flag = {
                  secret = true;
                  owner = "baas";
                  group = "baas";
                  mode = "0400";
                  restartUnits = [ "baas-vm.service" ];
                };
                runtimeInputs = [
                  pkgs.coreutils
                  pkgs.openssl
                ];
                script = ''
                  printf '${settings.flagFormat}' "$(openssl rand -hex 16)" > "$out/flag"
                '';
              };

              systemd.services.baas-vm = {
                description = "baas challenge VM";
                wantedBy = [ "multi-user.target" ];
                # Without the egress filter the guest could reach this host's
                # loopback, so the VM stops whenever the firewall does.
                requires = [ "firewall.service" ];
                after = [
                  "network.target"
                  "firewall.service"
                ];

                environment = {
                  NIX_DISK_IMAGE = "${stateDir}/disk-${builtins.substring 0 12 (baseNameOf vm)}.qcow2";
                  QEMU_NET_OPTS = "hostfwd=tcp:127.0.0.1:${toString settings.internalPort}-:${toString settings.port}";
                  QEMU_OPTS = "-fw_cfg name=opt/ctf/flag,file=${flag.path}";
                };

                serviceConfig = {
                  ExecStart = "${vm}/bin/run-baas-vm";
                  Restart = "always";
                  RestartSec = 5;

                  User = "baas";
                  Group = "baas";
                  SupplementaryGroups = [ "kvm" ];
                  StateDirectory = "baas-vm";
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
            }

            (lib.mkIf proxy.enable {
              networking.firewall.allowedTCPPorts = [ settings.publicPort ];

              services.nginx = {
                enable = true;
                recommendedProxySettings = true;
                recommendedTlsSettings = true;
                recommendedOptimisation = true;
                recommendedGzipSettings = true;

                appendHttpConfig = ''
                  limit_req_zone $binary_remote_addr zone=baas_build:4m rate=12r/m;
                '';

                virtualHosts.baas = {
                  serverName = proxy.hostName;
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
                      proxyPass = upstream;
                      extraConfig = proxyTimeouts + anubisGate;
                    };

                    "/build" = {
                      proxyPass = upstream;
                      extraConfig = ''
                        limit_req zone=baas_build burst=5 nodelay;
                        limit_req_status 429;
                      ''
                      + proxyTimeouts
                      + anubisGate;
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
                      return 307 /.within.website/?redir=$scheme://$http_host$request_uri;
                      auth_request off;
                    '';
                  };
                };
              };

              services.anubis.instances.baas = lib.mkIf proxy.anubis.enable {
                settings = {
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
