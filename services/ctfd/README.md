# CTFd

Runs [CTFd](https://github.com/CTFd/CTFd), a Capture The Flag platform, as a set
of OCI containers on a single machine:

- `ctfd` — the CTFd web application (published on `<address>:<port>`)
- `ctfd-db` — a MariaDB database
- `ctfd-cache` — a Redis cache

The database, cache and CTFd containers talk to each other over an internal
docker network. CTFd itself is additionally attached to the bridge network so it
retains outbound access.

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

## Notes

- Docker is forced as the backend because internal-network name resolution does
  not work reliably with podman.
- Container names are fixed (`ctfd`, `ctfd-db`, `ctfd-cache`), so only a single
  instance of this service is supported per machine.
