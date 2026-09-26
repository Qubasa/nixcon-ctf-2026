{ config, lib, ... }:
let
  cfg = config.ctf.vmEgress;

  owners = map (user: "-m owner --uid-owner ${user}") cfg.users;
  isNew = "-m conntrack --ctstate NEW";
  forEachOwner = f: lib.concatMapStrings (owner: f owner + "\n") owners;

  # The guard rules reject new guest connections while the chain is rebuilt,
  # so a firewall reload never opens a window.
  egressFilter =
    {
      cmd,
      allow,
      deny,
    }:
    ''
      ${forEachOwner (owner: ''
        ${cmd} -w -C OUTPUT ${owner} ${isNew} -j REJECT 2>/dev/null \
          || ${cmd} -w -I OUTPUT 1 ${owner} ${isNew} -j REJECT'')}
      ${cmd} -w -N vm-egress 2>/dev/null || ${cmd} -w -F vm-egress
      ${cmd} -w -A vm-egress -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      ${lib.concatMapStrings (rule: "${cmd} -w -A vm-egress ${rule} -j ACCEPT\n") allow}
      ${cmd} -w -A vm-egress -m addrtype --dst-type LOCAL -j REJECT
      ${cmd} -w -A vm-egress -d ${lib.concatStringsSep "," deny} -j REJECT
      ${forEachOwner (owner: ''
        ${cmd} -w -C OUTPUT ${owner} -j vm-egress 2>/dev/null \
          || ${cmd} -w -I OUTPUT ${toString (lib.length owners + 1)} ${owner} -j vm-egress'')}
      ${forEachOwner (owner: "${cmd} -w -D OUTPUT ${owner} ${isNew} -j REJECT")}
    '';

  resolvedStub = lib.optionals config.services.resolved.enable [
    "-d 127.0.0.53 -p udp --dport 53"
    "-d 127.0.0.53 -p tcp --dport 53"
  ];
in
{
  options.ctf.vmEgress.users = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Users that run QEMU guests with slirp networking and internet access.
      slirp opens a guest's connections from the QEMU process and maps
      `10.0.2.2` to this host's loopback, so every new connection these users
      open to an address of this host or to a private, link-local, multicast
      or reserved range is rejected. DNS to systemd-resolved's stub stays
      allowed, because slirp forwards the guest's DNS there.
    '';
  };

  config = lib.mkIf (cfg.users != [ ]) {
    assertions = [
      {
        assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
        message = ''
          modules/vm-egress.nix: the VMs of ${lib.concatStringsSep ", " cfg.users} have
          internet access, and only the iptables rules in
          networking.firewall.extraCommands keep them off this host's loopback
          and private networks. Enable networking.firewall with the iptables
          backend.
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
  };
}
