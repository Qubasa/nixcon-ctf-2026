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
