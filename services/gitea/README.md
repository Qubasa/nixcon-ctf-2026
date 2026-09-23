# Gitea

Runs [Gitea](https://about.gitea.com/) as a native NixOS service:

- PostgreSQL as the database, created through `clan.core.postgresql` (user
  `gitea`, database `gitea`, `C` collation)
- `/var/lib/gitea` and a `pg_dump` of the database registered as clan backup
  state, with Gitea stopped for the duration of the backup
- nginx terminating TLS with a Let's Encrypt certificate
- [Anubis](https://anubis.techaro.lol/) gating every request behind a
  proof-of-work anti-bot challenge (nginx subrequest authentication), including
  the upstream bot policy for Gitea RSS feeds

Gitea itself binds to loopback only, so all external traffic goes through nginx.

## Usage

```nix
inventory.instances.gitea = {
  module = {
    name = "gitea";
    input = "self";
  };
  roles.server.machines.ctf-machine = { };
  roles.server.settings = {
    hostName = "git.immutable-byte.de";
    nginx.acmeEmail = "admin@immutable-byte.de";
    # port = 3000;                 # loopback port Gitea binds to
    # disableRegistration = true;  # on by default
    # nginx.anubis.enable = true;  # on by default
    # nginx.anubis.port = 3001;    # loopback port Anubis binds to
  };
};
```

DNS for `hostName` must resolve to this machine and ports 80/443 must be
reachable from the internet for the ACME HTTP-01 challenge to succeed.

## First login

Gitea has no admin account out of the box and registration is disabled, so the
first admin has to be created on the machine with the command below. Gitea must
be running first, because it writes `app.ini` and migrates the database on its
first start.

```
sudo -u gitea GITEA_WORK_DIR=/var/lib/gitea GITEA_CUSTOM=/var/lib/gitea/custom \
  gitea admin user create --admin --username <name> --email <mail> --random-password
```

The generated password is printed once. Afterwards log in at
`https://<hostName>/user/login` and add further users under
*Site Administration → Identity & Access → User Accounts*.

## Notes

- No mailer is configured, so Gitea cannot send registration or notification
  mail. Add `services.gitea.settings.mailer` plus a `mailerPasswordFile` from a
  clan vars generator if that is needed.
- SSH access to repositories uses the machine's existing sshd on port 22.
