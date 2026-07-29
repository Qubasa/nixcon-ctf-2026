{ inputs }:
{
  # Ensure this is unique among all clans you want to use.
  meta.name = "nixcon-ctf";
  meta.domain = "immutable-byte.de";

  # Local clan services.
  modules.ctfd = ./services/ctfd;
  modules.gitea = ./services/gitea;
  # Takes `inputs` to reach the nixbot flake's module.
  modules.nixbot = import ./services/nixbot { inherit inputs; };

  inventory.machines = {
    # Define machines here.
    ctf-machine = { };
  };

  inventory.instances = {

    # Docs: https://clan.lol/docs/services/official/sshd
    # SSH service for secure remote access to machines.
    # Generates persistent host keys and configures authorized keys.
    sshd = {
      roles.server.tags.all = { };
      roles.server.settings.authorizedKeys = {
        # Insert the public key that you want to use for SSH access.
        # All keys will have ssh access to all machines ("tags.all" means 'all machines').
        # Alternatively set 'users.users.root.openssh.authorizedKeys.keys' in each machine
        "admin-machine-1" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGXfyed2m6hEB5gXTclAYSdi8tDQJF5HQe+rop7Pj8ik lhebendanz@wintux";
      };
    };

    # Docs: https://clan.lol/docs/unstable/services/official/users
    # Root password management for all machines.
    user-root = {
      module = {
        name = "users";
      };
      roles.default.tags.all = { };
      roles.default.settings = {
        user = "root";
        prompt = true;
      };
    };

    # Docs: https://clan.lol/docs/unstable/services/official/p2p-ssh-iroh
    # Status experimental
    # Firewall-traversing SSH access via encrypted QUIC streams
    p2p-ssh-iroh = {
      roles.server.tags = [ "nixos" ];
    };

    # Local module (see ./services/ctfd). Runs the CTFd platform with its
    # MariaDB and Redis containers. Secrets are managed through clan vars.
    ctfd = {
      module = {
        name = "ctfd";
        input = "self";
      };
      roles.server.machines.ctf-machine = { };
    };

    # Local module (see ./services/gitea). Gitea on PostgreSQL behind nginx
    # with TLS and an Anubis proof-of-work challenge.
    gitea = {
      module = {
        name = "gitea";
        input = "self";
      };
      roles.server.machines.ctf-machine = { };
      roles.server.settings = {
        hostName = "git.immutable-byte.de";
        nginx.acmeEmail = "admin@immutable-byte.de";
      };
    };

    # Local module (see ./services/nixbot). Nix CI for the Gitea instance
    # above: webhooks -> `.#checks` -> commit statuses. Needs the manual Gitea
    # setup described in services/nixbot/README.md (bot user, access token,
    # OAuth2 app) before the first deploy.
    nixbot = {
      module = {
        name = "nixbot";
        input = "self";
      };
      roles.server.machines.ctf-machine = { };
      roles.server.settings = {
        hostName = "ci.immutable-byte.de";
        giteaUrl = "https://git.immutable-byte.de";
        acmeEmail = "admin@immutable-byte.de";
        # Client id of the Gitea OAuth2 application (non-secret).
        oauthId = "REPLACE_WITH_GITEA_OAUTH_CLIENT_ID";
        admins = [ "gitea:qubasa" ];
      };
    };
  };

  # Additional NixOS configuration can be added here.
  # machines/server/configuration.nix will be automatically imported.
  # See: https://clan.lol/docs/unstable/guides/inventory/autoincludes
  machines = {
    ctf-machine = { config, pkgs, ... }: {
      environment.systemPackages = [ pkgs.helix ];
    };
  };
}
