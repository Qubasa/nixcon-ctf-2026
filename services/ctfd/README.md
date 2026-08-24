# CTFd

Runs [CTFd](https://github.com/CTFd/CTFd), a Capture The Flag platform, as a set
of OCI containers on a single machine:

- `ctfd` — the CTFd web application (published on `<address>:<port>`)
- `ctfd-db` — a MariaDB database
- `ctfd-cache` — a Redis cache

The database, cache and CTFd containers talk to each other over an internal
docker network. CTFd itself is additionally attached to the bridge network so it
retains outbound access, and to the `challmgr` network so it can reach
chall-manager on the host (see below).

## Secrets

The `SECRET_KEY`, MariaDB root password and CTFd database password are generated
and stored through clan vars (generator `ctfd`). They are never written to the
Nix store. To rotate them, remove the generator's vars and redeploy.

## Usage

```nix
inventory.instances.ctfd = {
  roles.server.machines.ctf-machine = { };
  # optionally:
  # roles.server.settings.port = 8000;
  # roles.server.settings.address = "127.0.0.1";
};
```

CTFd listens on loopback by default and expects a reverse proxy (it runs with
`REVERSE_PROXY=true`). Point your proxy at `http://127.0.0.1:8000`.

## Dynamic challenges (chall-manager)

The [ctfd-chall-manager](https://github.com/ctfer-io/ctfd-chall-manager) plugin
adds the `dynamic_iac` challenge type, which asks
[chall-manager](https://github.com/ctfer-io/chall-manager) to deploy a private
instance of a challenge per team. The plugin source comes from the
`ctfd-chall-manager` flake input and is bind-mounted read-only into the CTFd
container at:

```
/opt/CTFd/CTFd/plugins/ctfd_chall_manager
```

That directory name is not a preference. The plugin imports itself absolutely
(`from CTFd.plugins.ctfd_chall_manager.utils... import ...`) and derives both its
asset endpoint and its Alembic migration directory from the basename of its own
directory, so anything else — a hyphen, a version suffix — breaks it at import
time. `PYTHONDONTWRITEBYTECODE=1` is set on the container because the mount
points into the read-only nix store.

All three images are pinned by digest with `pull = "missing"`: CTFd to
`ctfd/ctfd:3.8.7` (the build the plugin's own CI runs against), plus
`mariadb:10.11` and `redis:4`. A floating tag with `pull = "always"` means any
mid-event container restart both depends on Docker Hub being reachable and can
pull a CTFd the plugin has never been tested against. Bumping one is a
deliberate edit: resolve the new digest, redeploy, check the site.

### Settings

The plugin reads its configuration from the environment exactly once, on its
first load, and writes the values into CTFd's own config table (guarded by a
`chall-manager:setup` key). From then on the environment is ignored and the
values are owned by the admin UI under *Plugins → chall-manager*. Changing a Nix
option after the first boot therefore has no effect — change it in the UI, or
drop the CTFd database.

| Option | Environment variable | Default |
| --- | --- | --- |
| `challManager.apiUrl` | `PLUGIN_SETTINGS_CM_API_URL` | `http://10.89.0.1:8080` |
| `challManager.apiTimeout` | `PLUGIN_SETTINGS_CM_API_TIMEOUT` | `600` |
| `challManager.manaTotal` | `PLUGIN_SETTINGS_CM_MANA_TOTAL` | `0` (mana disabled) |
| `challManager.hideInstancesPanel` | `PLUGIN_SETTINGS_CM_UI_HIDE_INSTANCES_PANEL` | `false` |

`hideInstancesPanel` is the exception: it is re-read from the environment on
every CTFd start and has no admin-UI equivalent.

Per-challenge knobs — the scenario reference, the instance `timeout`, and
`destroy_on_flag` — are fields on the `dynamic_iac` challenge form in CTFd, not
Nix options. chall-manager has no global equivalents.

### Reaching chall-manager

chall-manager runs as a native service on the host, not as a container.
`ctfd_internal` is created with `--internal`, which means it has no gateway at
all, so a container attached only to it cannot talk to the host. CTFd is
therefore also connected to the `challmgr` docker network (`10.89.0.0/24`,
gateway `10.89.0.1`, bridge `challmgr0`), which the `chall-manager` service
creates through a oneshot `docker-network-challmgr.service`. Docker only accepts
one `--network` when a container is created, so the second and third
attachments happen in the container unit's `postStart`.

`10.89.0.1` is the host as seen from that network, and chall-manager's firewall
rule only opens port 8080 on `challmgr0`. This matters: chall-manager has no
authentication or authorisation whatsoever, and deploying a scenario to it is by
design arbitrary code execution. It is never published to players, never proxied
by nginx, and never bound to a public interface — the plugin is its only client.

## Reverse proxy (nginx + TLS + Anubis)

Setting `nginx.enable = true` puts nginx in front of CTFd, terminates TLS with a
Let's Encrypt certificate, and gates every request behind an
[Anubis](https://anubis.techaro.lol/) proof-of-work anti-bot challenge (nginx
subrequest authentication). Ports 80 and 443 are opened.

```nix
inventory.instances.ctfd = {
  roles.server.machines.ctf-machine = { };
  roles.server.settings.nginx = {
    enable = true;
    hostName = "ctf.immutable-byte.de";
    acmeEmail = "admin@immutable-byte.de";
    # anubis.enable = true;   # on by default
    # anubis.port = 8923;     # loopback port Anubis binds to
  };
};
```

DNS for `hostName` must resolve to this machine and ports 80/443 must be
reachable from the internet for the ACME HTTP-01 challenge to succeed.

## Notes

- Docker is forced as the backend because internal-network name resolution does
  not work reliably with podman.
- Container names are fixed (`ctfd`, `ctfd-db`, `ctfd-cache`), so only a single
  instance of this service is supported per machine.
- All three container images are digest-pinned, so a restart never contacts
  Docker Hub. The flip side is that security updates only arrive when someone
  bumps a digest.
