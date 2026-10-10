# 04 — Monitoring

The agent cannot write its own audit trail. Nothing is logged from inside to a
place the agent can reach: no log directory is mounted into any container
(barrier B28 in the [threat model](00-threat-model.md)). Every container writes
to its standard output, and Podman collects that from outside.

## What is recorded

| Container | What its log holds |
|---|---|
| **proxy** | One line per request the agent or the sidecar made, allowed or denied, with the host name asked for. |
| **credsidecar** | One JSON line per model request: time, path, model, the tools offered, any web search query, the answer's status, the budget left. Never a credential. |
| **gitrelay** (if used) | One JSON line per git request: which branch a push named and whether it was let through. |
| **agent** | Whatever the agent's first process printed. Treat this one as written by the agent. Commands started later with `podman exec` are not in it. |

Only the proxy's and the sidecar's logs are evidence of what happened.

```bash
./sandbox logs proxy
./sandbox logs sidecar
./sandbox logs relay          # with --git-relay
./sandbox logs agent
./sandbox logs service        # sibling services
```

What `./sandbox logs` prints has control characters removed first, so nothing
the agent caused to be logged can redraw your terminal (barrier B32).

## Limits you should know

- **Size cap.** Each container's log is capped at 10 MB. When it reaches the
  cap, Podman empties it. An agent can therefore push earlier entries out by
  making the proxy or sidecar log a great deal. The sidecar limits how fast
  refused requests are logged, which slows this down but does not prevent it.
- **Deleted with the session.** The log is a file that belongs to the
  container; `./sandbox destroy` removes it.

If you need a record that survives both, forward the logs as they are written.

## Forwarding logs

The log driver is set in one place, `_topo_hardening` in `topology.sh`:

```bash
--log-driver=k8s-file
--log-opt max-size=10m
```

To send logs to the system journal instead, change those two lines to:

```bash
--log-driver=journald
--log-opt tag={{.Name}}
```

and read them with `journalctl --user CONTAINER_NAME=<session>-proxy`. Journal
entries are **not** removed by `destroy`; that is the point, and it is also why
this is not the default: the default promise is that nothing of a session
remains.

For syslog or a collector such as Fluentd, forward from the journal
(`systemd-journal-remote`, `fluent-bit` with its systemd input). Podman has no
log driver that ships to a remote collector directly.

## Host-side auditing (optional)

`extras/host-audit/` has an auditd rule file, a Falco rules file and a Tetragon
policy that watch the session's containers from the host. They need root to
load, they are not part of what the sandbox guarantees, and they have not been
tested by this project. Their README says what each one gives you.

Next: [05 — Agents and toolchains](05-agents-and-toolchains.md).
