{ inputs }:
{
  _class = "clan.service";
  manifest.name = "nixbot";
  manifest.description = "nixbot Nix CI wired to the clan's Gitea: forge webhooks -> nix-eval-jobs on a repo's `.#checks` -> builds -> commit statuses and a web UI.";
  manifest.categories = [ "Development" ];
  manifest.readme = builtins.readFile ./README.md;

  roles.server = {
    description = "Runs nixbot behind nginx with TLS, on the clan PostgreSQL, integrated with Gitea.";

    interface =
      { lib, ... }:
      {
        options = {
          hostName = lib.mkOption {
            type = lib.types.str;
            example = "ci.immutable-byte.de";
            description = "Public host name nixbot's web UI is served under. Gets its own ACME certificate.";
          };

          giteaUrl = lib.mkOption {
            type = lib.types.str;
            example = "https://git.immutable-byte.de";
            description = "Base URL of the Gitea forge nixbot integrates with.";
          };

          acmeEmail = lib.mkOption {
            type = lib.types.str;
            example = "admin@immutable-byte.de";
            description = "Contact email for the Let's Encrypt account.";
          };

          oauthId = lib.mkOption {
            type = lib.types.str;
            description = ''
              Gitea OAuth2 application client id for the nixbot login button
              (non-secret). The matching secret is the operator-prompted
              `nixbot/gitea-oauth-secret` clan var. Create the app in Gitea under
              Site Administration -> Applications with redirect URI
              `https://<hostName>/auth/gitea/callback`.
            '';
          };

          admins = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "gitea:qubasa" ];
            description = ''
              Provider-qualified admin logins (`gitea:<login>`). Admins can reload
              the project list, enable/disable projects and restart or cancel any
              build.
            '';
          };

          topic = lib.mkOption {
            type = lib.types.str;
            default = "build-with-nixbot";
            description = ''
              Gitea repository topic. On first start against an empty database,
              repos carrying this topic are imported and enabled; afterwards
              manage projects in the web UI.
            '';
          };

          buildSystems = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "x86_64-linux" ];
            description = "Systems built locally; anything else needs nix remote builders.";
          };

          evalWorkerCount = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            example = 2;
            description = ''
              nix-eval-jobs workers. `null` keeps the upstream default (one per
              core), which reserves `cores * 2 GiB` and can OOM a small box.
            '';
          };
        };
      };

    perInstance =
      { settings, ... }:
      {
        nixosModule =
          { config, lib, ... }:
          {
            imports = [ inputs.nixbot.nixosModules.nixbot ];

            # Operator-prompted Gitea secrets: the bot user's access token
            # (write:repository + read:user) and the OAuth2 app client secret.
            # nixbot reads both through systemd LoadCredential as root at
            # unit start, so the raw clan-var paths need no owner juggling.
            clan.core.vars.generators.nixbot = {
              prompts.gitea-token = {
                description = "Gitea access token for the nixbot bot user (write:repository + read:user)";
                type = "hidden";
              };
              prompts.gitea-oauth-secret = {
                description = "Gitea OAuth2 application client secret for the nixbot login button";
                type = "hidden";
              };
              files.gitea-token.restartUnits = [ "nixbot.service" ];
              files.gitea-oauth-secret.restartUnits = [ "nixbot.service" ];
              script = ''
                cp "$prompts"/gitea-token        "$out"/gitea-token
                cp "$prompts"/gitea-oauth-secret "$out"/gitea-oauth-secret
              '';
            };

            clan.core.postgresql.enable = true;
            clan.core.postgresql.users.nixbot = { };
            clan.core.postgresql.databases.nixbot.create.options.OWNER = "nixbot";
            clan.core.postgresql.databases.nixbot.restore.stopOnRestore = [ "nixbot" ];

            # Private clones and build logs; the nix store itself is
            # rebuildable and deliberately not backed up.
            clan.core.state.nixbot.folders = [ "/var/lib/nixbot" ];

            networking.firewall.allowedTCPPorts = [
              80
              443
            ];

            security.acme.acceptTerms = true;
            security.acme.defaults.email = lib.mkDefault settings.acmeEmail;

            services.nixbot = {
              enable = true;
              domain = settings.hostName;
              admins = settings.admins;
              buildSystems = settings.buildSystems;
              evalWorkerCount = lib.mkIf (settings.evalWorkerCount != null) settings.evalWorkerCount;

              # Don't re-evaluate and re-build derivations already known to
              # fail until an explicit rerun.
              cacheFailedBuilds = true;

              database.createLocally = false;
              database.url = "postgresql://nixbot@/nixbot?host=/run/postgresql";

              gitea = {
                enable = true;
                instanceUrl = settings.giteaUrl;
                tokenFile = config.clan.core.vars.generators.nixbot.files.gitea-token.path;
                oauthId = settings.oauthId;
                oauthSecretFile = config.clan.core.vars.generators.nixbot.files.gitea-oauth-secret.path;
                topic = settings.topic;
              };

              nginx.enableACME = true; # HTTP-01
            };

            # nixbot only orders after postgresql.target when it provisions the
            # database itself; with the clan Postgres we wire the ordering here.
            systemd.services.nixbot = {
              after = [ "postgresql.target" ];
              requires = [ "postgresql.target" ];
            };
          };
      };
  };
}
