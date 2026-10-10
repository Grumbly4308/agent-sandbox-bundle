# Sibling services

A sibling service is a database or cache that runs next to the agent for one
session, so the project's tests have something to talk to:

```
./sandbox run <repo> --service postgres:16 --service redis:7
```

Each one is its own container on the session's internal network. It gets the
same hardening as everything else (no capabilities, read-only root
filesystem, memory and process limits, a deadline) and, like the agent, it
has no route out: the proxy answers only the agent's, the sidecar's and the
relay's exact addresses, so a service can reach nothing `[logical B21]`.

## What to know before you add `--service`

- **You start services. The agent cannot.** There is no container runtime
  and no runtime socket inside the sandbox, and the system-call filter
  refuses the calls a runtime needs `[physical B04, B06]`. The set of
  services is fixed when you type `run`.
- **A service is part of the agent's reach.** The agent is handed the
  connection string, password included, so it can do anything the database
  lets a superuser do, which for Postgres includes running programs inside
  the service's container. Treat that container as agent territory. It is
  contained the same way the agent is, and it is thrown away with the
  session. Never point a service at data you care about; there is no way to
  mount any.
- **Everything a service stores is in memory** and counts against your
  host's memory until `./sandbox destroy`. The limits are in each
  `service.conf`.
- **Out of scope inside the sandbox:** building container images, and test
  suites that start their own containers (Testcontainers and the like, or
  anything that runs `docker compose up`). Both need a container runtime,
  which is exactly what the sandbox withholds. Run those in CI or on your
  host, after you have read the exported diff. If a suite only needs a
  database, add it here as a service and point the suite at the URL
  variable.

## How a service is described

One directory per service, one file in it: `services/<name>/service.conf`.
`./sandbox` reads the file with `read`, line by line. It is never executed
as a shell script, so nothing in it can run a command on your host.

- A line starting with `#` is a comment. Blank lines are ignored.
- Every other line is `KEY=value`, split at the first `=`. The value is
  taken literally: no quotes, no variables, no escapes. Spaces are part of
  the value.
- `COMMAND_ARG=` with nothing after the `=` is an **empty argument** and is
  kept (Redis needs one: `--save ""`).

| Key | Required | Meaning |
|---|---|---|
| `IMAGE` | yes | The image, pinned by digest: `registry/repo:tag@sha256:...`. Ships as `UNPINNED` with a `# tag: <reference>` comment above it; `scripts/pin-images.sh` fills it in. A service whose image is `UNPINNED` is refused. |
| `VERSIONS` | yes | The versions `--service <name>:<version>` accepts, separated by spaces. One image is pinned per file, so normally one version. |
| `USER` | yes | `uid:gid` the container runs as. Must be the image's own non-root user: with no capabilities, an image that starts as root and then switches user cannot work. |
| `MEMORY` | yes | Memory limit (`512m`, `1g`). At least the sum of the `TMPFS` sizes plus 64 MB of shared memory plus working room, because files held in memory are memory. |
| `PIDS` | yes | Limit on processes and threads. |
| `PORT` | yes | The TCP port the service listens on. |
| `URL_VAR` | yes | Name of the environment variable the agent's CLI is started with, e.g. `DATABASE_URL`. |
| `URL_TEMPLATE` | yes | Its value. `{host}` is replaced by the service's address on the session network (no container is found by name). |
| `HEALTH` | yes | A command run inside the service container with `podman exec`; exit status 0 means ready. `./sandbox` waits for it before starting the agent's CLI. Plain words separated by spaces. |
| `TMPFS` | repeatable, may be absent | A writable path, held in memory and capped: `path:size=...,mode=1777,nosuid,nodev,noexec`. The root filesystem is read-only, so every path the service writes to needs one. |
| `ENV` | repeatable, may be absent | `NAME=value` for the service's environment. |
| `COMMAND_ARG` | repeatable, may be absent | One argument of the command, in order. Leave out to use the image's default command. |

`topology.sh` (`topo_service`) turns these into the `podman create`
arguments; read it to see every flag a service runs with.

## Adding a service

1. Pick an official image that can run as a non-root user with a read-only
   root filesystem. Find out which paths it writes to.
2. Create `services/<name>/service.conf` with every required key, a
   `# tag:` comment above `IMAGE=UNPINNED`, and a comment above each line
   saying why it is there.
3. Give every writable path a `TMPFS` line with a size, and set `MEMORY`
   above their sum. Pass whatever switches off writing to disk as
   `COMMAND_ARG` lines.
4. Run `scripts/pin-images.sh` on a host with Podman, and commit the digest.
5. Run `tests/images/test-services.sh`, then `./sandbox run --service
   <name>:<version>` and `./sandbox verify`.

No change to `./sandbox` or `topology.sh` is needed.

## What has and has not been tested

The two service files here were written without a container runtime at hand.
That each service starts as the user given, with a read-only root filesystem
and these memory mounts, and that the health checks behave as described, is
still to be confirmed on a real Podman.
