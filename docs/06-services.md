# 06 — Services: a database beside the agent

Tests often need a database or a cache. The agent cannot start one: there is no
container runtime inside the sandbox and no way to get one. You start it:

```bash
./sandbox run <repo> --service postgres:16 --service redis:7
```

Each service is its own container on the session's network, with the shared
hardening: read-only root, no capabilities, memory and process limits, a
deadline, no route out. The agent is given the connection string in its
environment:

| Service | Variable | Value |
|---|---|---|
| `postgres:16` | `DATABASE_URL` | `postgres://postgres:sandbox@postgres:5432/postgres` |
| `redis:7` | `REDIS_URL` | `redis://redis:6379/0` |

## What to know

- **A service is part of the agent's reach.** The agent holds its password, and
  a Postgres superuser can run programs inside the Postgres container. Treat
  that container as agent territory. It is contained the same way the agent is.
- **Nothing a service stores is kept.** Its data is in memory and is gone with
  the session. There is no way to attach your own data.
- **A service can reach nothing.** The proxy answers only the agent's, the
  sidecar's and the relay's addresses.
- **It adds to the session's memory.** `run` prints the total.

## The catalogue

One directory per service under `services/`, holding one file,
`service.conf`. Every line in it has a reason. `services/README.md` describes
the format and how to add a service.

A service's image is pinned by digest, like the base images. It ships as a
placeholder until you have run `scripts/pin-images.sh`, and `run` refuses the
service until then.

## Out of scope inside the sandbox

- **Building container images.**
- **Test suites that start their own containers** (testcontainers and similar).

Both need a container runtime, and giving the agent one would give it a way to
ask the runtime for anything on your host. If a project needs them, run those
tests in your own CI after `export`.

Next: [07 — Troubleshooting](07-troubleshooting.md).
