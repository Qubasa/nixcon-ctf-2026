# chall-manager

Runs [chall-manager](https://github.com/ctfer-io/chall-manager) as a plain
systemd service. It is the engine behind the on-demand challenges: CTFd asks it
for a private instance of a challenge, it runs that challenge's Pulumi program
to build one, and its janitor tears the instance down once it expires.

Four units and a timer:

- `docker-network-challmgr.service` — creates the `challmgr` docker network
- `chall-manager-registry.service` — the local OCI registry holding scenarios
- `chall-manager.service` — the API
- `chall-manager-janitor.service` + `.timer` — reclaims expired instances

## Architecture

```
player                                                   ctf host
  |                                                          |
  |  solves / clicks "deploy"                                |
  v                                                          |
CTFd container ---- ctfd_chall_manager plugin                |
  |                     |                                    |
  |                     |  HTTP/JSON, no auth                |
  |                     |  http://10.89.0.1:8080             |
  |                     v                                    |
  |            chall-manager.service                          |
  |                     |                                     |
  |                     |  pulls the scenario as an OCI artifact
  |                     |  from 127.0.0.1:5000                |
  |                     |  runs it with the Pulumi automation API
  |                     v                                     |
  |            homewort-scenario (a Go Pulumi program)         |
  |                     |                                     |
  |                     |  sudo -n homewort-instance create --identity <id>
  |                     v                                     |
  |            slot 3, port 2203, a freshly minted flag        |
  |                     |                                     |
  |  <------------------+  connection_info + flag back through CTFd
  v
ssh friend@ctf.nixcon.org -p 2203
```

Every arrow above is local to this machine. Nothing in the chain reaches the
internet, and nothing in the chain needs an operator during the event.

## Why native, and not Kubernetes or the docker socket

Upstream deploys chall-manager into Kubernetes and its scenarios normally
create Kubernetes objects. That is one machine's worth of work for zero benefit
here: the challenge this runs is a full QEMU VM with its own bootloader, so
there is nothing to containerise, and a single-node k3s underneath would only
add a control plane to keep alive during a CTF.

`KUBERNETES_TARGET_NAMESPACE` is deliberately left unset. It is the only thing
that makes a scenario instantiate the Kubernetes provider — the scenario SDK
switches on `os.LookupEnv` of that variable — so leaving it out is what keeps
this deployment out of Kubernetes entirely.

The other obvious shortcut, handing chall-manager the docker socket so scenarios
can start containers, is worse than it looks: the docker socket is root on the
host, and chall-manager authenticates nobody (see below). Instead the scenario
gets exactly one privileged verb, through a sudo rule that `services/homewort`
owns:

```
/run/wrappers/bin/sudo -n /run/current-system/sw/bin/homewort-instance <verb> --identity <ID>
```

`homewort-instance` validates the identity, hands out one slot from a fixed pool
and prints JSON. That is the whole privileged surface.

## Trust boundary

chall-manager has no authentication and no authorization, at all. Upstream calls
it RCE-as-a-Service without irony: anything that can reach its port can make it
run an arbitrary Pulumi program as a service that holds a sudo rule. Reaching
the port is owning the host.

So the port is never public:

```nix
networking.firewall.interfaces.challmgr0.allowedTCPPorts = [ 8080 ];
```

and nothing global. `challmgr0` is the bridge of the `challmgr` docker network
(`10.89.0.0/24`, gateway `10.89.0.1`) that `docker-network-challmgr.service`
creates. The fixed bridge name is the entire reason that unit exists: left to
itself docker would pick a `br-<hash>` name and the firewall rule would have
nothing stable to match on.

The CTFd container is attached to that network by `services/ctfd`, which is why
it can reach `http://10.89.0.1:8080` — the gateway address is the host. A
process anywhere else on the machine, or on `docker0`, cannot: its packets
arrive on the wrong interface and the firewall drops them.

chall-manager itself has no listen-address flag and always binds `0.0.0.0`. The
firewall is the only thing keeping it private, so do not add a global port
opening or a reverse proxy in front of it.

One port serves everything. Upstream cmux-multiplexes gRPC and the HTTP/JSON
gateway on a single listener, so `8080` is both the plugin's REST endpoint and
the janitor's gRPC target.

## The registry, and how a scenario gets in

A *scenario* is a Pulumi program distributed as an OCI artifact.
chall-manager only ever loads scenarios from a registry, so there is one on
`127.0.0.1:5000`, plain HTTP, backed by the nixpkgs `distribution` package with
a generated config file and filesystem storage under
`/var/lib/chall-manager-registry`.

Challenge services push their own scenario into it at boot;
`services/homewort` does this in `homewort-scenario-push.service`. The push must
match what chall-manager's loader expects, which is not obvious: it is **not** a
tarball. Upstream packs one layer per file, media type
`application/vnd.ctfer-io.file`, with the layer title set to the file's path
relative to the scenario root, under artifact type
`application/vnd.ctfer-io.scenario`:

```
cd <scenario dir>
oras push --plain-http \
  --artifact-type application/vnd.ctfer-io.scenario \
  127.0.0.1:5000/homewort:0.1.0 \
  Pulumi.yaml:application/vnd.ctfer-io.file \
  main:application/vnd.ctfer-io.file
```

On the way back in, chall-manager copies each layer to
`<stateDir>/cache/oci/<digest>/<layer title>`, so those two names have to land at
the artifact root. A `scenario.tar.gz` layer would be written out as a literal
file called `scenario.tar.gz` and validation would fail with `no Pulumi project
file found`.

`Pulumi.yaml` must declare the prebuilt binary:

```yaml
runtime:
  name: go
  options:
    binary: ./main
```

Without `options.binary` chall-manager runs `go build` in its own unit at
challenge-creation time, which is not something to discover during an event.
Permissions do not survive an OCI round trip, but that is handled upstream: the
loader chmods the binary itself after pulling it.

`--oci.insecure` is a global switch, not a per-registry one — upstream has no
per-host setting. That is acceptable here only because `127.0.0.1:5000` is the
only registry configured.

## The offline Pulumi recipe

chall-manager drives Pulumi through the automation API, i.e. it shells out to
the real `pulumi` CLI. The CLI's instinct on a cache miss is to download a
plugin, and this host has no egress worth relying on during a CTF, so
everything it could want is on the unit's `PATH` as an ambient plugin instead:

| on `PATH` | why |
| --- | --- |
| `pulumi` | the CLI itself |
| `pulumiPackages.pulumi-go` | the Go language host (`pulumi-language-go`) |
| `pulumiPackages.pulumi-command` | the `command` provider the scenario uses |
| `go` | see below |
| `/run/wrappers/bin` | `sudo` |
| `/run/current-system/sw/bin` | `homewort-instance` |

plus `PULUMI_BACKEND_URL=file://<stateDir>/pulumi-state`,
`PULUMI_HOME=<stateDir>/pulumi-home` and `PULUMI_SKIP_UPDATE_CHECK=true`. There
is no `pulumi login` and no plugin seeding step.

Two traps in there.

**The `go` binary is not optional.** Even with `options.binary` pointing at a
prebuilt `main`, `pulumi-language-go` 3.192 runs a "discover package
requirements" pass over the program directory on every preview and up, and
aborts the deployment with `couldn't find go binary` if `go` is missing. This
fires when the challenge is *created*, not when an instance is deployed, so
without it the first admin save in the CTFd UI fails. `GOPROXY=off` and
`GOTOOLCHAIN=local` make sure that pass can never turn into a download attempt,
and `GOCACHE`/`GOPATH` are redirected under `stateDir` because
`ProtectSystem=strict` will not let the toolchain create `$HOME/.cache`.

**`pulumi-command` in nixpkgs is 0.9.0, upstream is 1.2.x.** A scenario whose
`go.mod` asks for the 1.x SDK makes Pulumi go looking for a matching 1.x
provider at instance-creation time, and fail offline. Scenarios built in this
repo pin `github.com/pulumi/pulumi-command/sdk v0.9.0` to match.

## Hardening

`NoNewPrivileges` is impossible for `chall-manager.service`: the whole point of
the scenario is to call `sudo homewort-instance`, and `sudo` is setuid. The unit
compensates with `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
`RestrictAddressFamilies`, `RestrictSUIDSGID`, `LockPersonality`,
`ProtectKernelTunables` and `ProtectControlGroups`, with `stateDir` as the only
writable path. `AF_NETLINK` is in the allowed address families because `sudo`
wants an audit socket.

The registry and the janitor have no such constraint and run with
`NoNewPrivileges` and `DynamicUser`.

The service user is called `chall-manager` on purpose: that name is what
`services/homewort`'s sudo rule grants, so renaming it silently breaks
instance creation.

## The janitor

Instances carry an expiry, and nothing removes them until something asks. The
janitor is that something: every run it fetches the instances whose deadline has
passed and deletes them, which is what releases the underlying VM slot back into
the pool. It is what makes the deployment hands-off, and it is the reason a
player who walks away does not hold a slot for the rest of the event.

Upstream can loop internally with `--ticker`, but this deploys it as a oneshot
plus a timer (`janitorInterval`, 5 min by default) so retries, failures and logs
stay in systemd. Run it by hand with:

```
systemctl start chall-manager-janitor.service
```

The per-instance lifetime itself is **not** configured here. chall-manager has
no global timeout knob: `timeout` and `destroy_on_flag` are per-challenge fields
that arrive over the API when an admin saves a `dynamic_iac` challenge in CTFd.
For this event they are `2h` and enabled; see `services/ctfd/README.md`.

## State layout

Everything lives under `stateDir` (`/var/lib/chall-manager`), owned by the
`chall-manager` user, mode `0700`:

| path | contents |
| --- | --- |
| `store/` | challenge and instance records, and the filesystem locks (`--dir`) |
| `cache/oci/<digest>/` | scenarios unpacked from the registry, one directory per manifest digest; Pulumi runs the program from here |
| `pulumi-state/` | the Pulumi file backend: one stack per instance |
| `pulumi-home/` | `PULUMI_HOME` |
| `go-cache/`, `go/` | the Go toolchain's caches, kept out of `$HOME` |

Losing `store/` and `pulumi-state/` orphans every running instance: the VMs keep
running with slots claimed and nothing left that knows how to release them. The
registry has its own directory, `/var/lib/chall-manager-registry`, which is
disposable — every scenario in it is re-pushed from the Nix store on the next
deploy.

Scenario directories are keyed by manifest digest, so a rebuilt scenario pushed
under the same tag is picked up as a new directory rather than a stale cache
hit.

## Inspecting an instance by hand

From the host, `curl` the gateway over loopback (the firewall only restricts
`challmgr0`, and loopback is not it):

```bash
# every challenge chall-manager knows about
curl -s http://127.0.0.1:8080/api/v1/challenge | jq

# one challenge, including its scenario reference and timeout
curl -s http://127.0.0.1:8080/api/v1/challenge/homewort | jq

# the instance a given CTFd team holds
curl -s http://127.0.0.1:8080/api/v1/instance/homewort/<source_id> | jq

# nuke one instance; the slot is released and the flag wiped
curl -s -X DELETE http://127.0.0.1:8080/api/v1/instance/homewort/<source_id>
```

`source_id` is the CTFd team (or user) id the plugin used. The `connection_info`
and `flags` in the response come straight out of the Pulumi stack's outputs,
which come straight out of `homewort-instance create`, so they are the same
strings the player sees.

What the registry is holding:

```bash
curl -s http://127.0.0.1:5000/v2/_catalog | jq
curl -s http://127.0.0.1:5000/v2/homewort/tags/list | jq
```

When a deploy fails, the error CTFd shows is the gRPC status message, which is
usually truncated. The full Pulumi output — including the program's own
diagnostics — is in the journal:

```bash
journalctl -u chall-manager.service -n 200
```

Capacity exhaustion looks like a failed deploy in the CTFd UI: with all eight
slots taken, `homewort-instance create` exits 4, the scenario fails, and Pulumi
reports it back up the chain. That is intentional — there is no queue and no
warm pool.

## Usage

```nix
inventory.instances.chall-manager = {
  roles.server.machines.ctf-machine = { };
  # optionally:
  # roles.server.settings.janitorInterval = "1min";
  # roles.server.settings.stateDir = "/srv/chall-manager";
};
```

All settings are defaulted; an empty `settings` block is the normal case. The
addresses are not settings on purpose — the subnet, the gateway and the bridge
name are a contract between this service, the firewall rule and
`services/ctfd`'s plugin configuration, and changing one of them without the
others produces a deployment that looks fine and cannot deploy a challenge.
