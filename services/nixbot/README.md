# nixbot

Nix CI for the clan's Gitea. Forge webhooks trigger `nix-eval-jobs` on a repo's
`.#checks`, builds run through the local nix daemon, and results come back as
commit statuses plus a web UI at `hostName`.

The service is the standalone successor of buildbot-nix
([Mic92/nixbot](https://github.com/Mic92/nixbot)) and complements the
[gitea](../gitea) service, which has no CI of its own.

## What the module sets up

- `services.nixbot` with the Gitea integration, an nginx vhost, and an HTTP-01
  certificate for `hostName`.
- A database on the clan PostgreSQL (`database.createLocally = false`, socket
  peer authentication) so it rides the clan pg-dump backup and restore.
- `/var/lib/nixbot` (private clones, build logs) in `clan.core.state`. The nix
  store itself is rebuildable and is not backed up.
- A single operator-prompted `nixbot` clan var holding both Gitea secrets.

Builds run on the machine itself (`buildSystems`, default `x86_64-linux`).
Anything else needs nix remote builders.

## Manual setup

None of this can live in the flake, and all of it happens in Gitea.

1. **DNS.** Point `hostName` at the machine before deploying, otherwise the
   HTTP-01 challenge fails.
2. **Bot user.** Gitea registration is closed, so create the user on the
   machine:
   ```
   gitea admin user create --username nixbot --email nixbot@<domain> --random-password
   ```
   Add it as an admin collaborator on every repository it should build.
   Gitea only lets repo admins manage webhooks. Without admin rights the repo is
   still discovered, but its webhook has to be added by hand.
3. **Access token.** As `nixbot`, generate a token under Settings → Applications
   with `write:repository` and `read:user`, or mint it with
   `gitea admin user generate-access-token`.
4. **OAuth2 app.** Under Site Administration → Applications, create an
   application named `nixbot` with redirect URI
   `https://<hostName>/auth/gitea/callback`. Put the generated client id into
   `clan.nix` as `oauthId` (non-secret).
5. **Secrets.** Both the access token and the OAuth client secret are prompts of
   one generator:
   ```
   clan vars generate ctf-machine --generator nixbot
   ```
   Use `clan vars set` only to rotate one of them later.
6. **Opt repositories in.** Tag them with the `topic` (default
   `build-with-nixbot`) for the one-shot import, or enable them in the web UI
   afterwards. The import only runs against an empty database. Webhooks
   (`push`, `pull_request`, `pull_request_sync`) are created on each discovery
   cycle.

## Access control

Login goes through Gitea's OAuth, so forge write access maps to build controls:
repository writers can restart their repo's builds, pull request authors their
own. The `admins` list (`gitea:<login>`) can do anything, including reloading
and enabling or disabling projects.

## Notes

- The Gitea vhost is fronted by Anubis, but its default policy only challenges
  browser user agents, so nixbot's API calls and git clones pass through.
- `evalWorkerCount` caps the `nix-eval-jobs` workers. The upstream default is
  one per core and each reserves 2 GiB, which can exhaust a small machine. Set
  it to 2 on an 8 GB box.
- `cacheFailedBuilds` is on: derivations known to fail are not rebuilt until an
  explicit rerun.
