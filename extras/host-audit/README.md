# Host-side audit (optional)

Three ways to watch a sandbox from the host, with tools that run as root
outside every container. Pick one or none.

**This is not part of the sandbox's guarantees.** Nothing here is a barrier
and nothing here is in the register in
[docs/00-threat-model.md](../../docs/00-threat-model.md). These tools record;
they stop nothing. They need **root on the host**, which the sandbox itself
never asks for, and you install and load them yourself.

**None of these files has been loaded or run by the authors.** They were
written from each tool's documentation on a machine with no auditd, Falco,
Tetragon or Podman. Validate each one before you rely on it, and expect to
fix details.

The primary record of a session stays what it was: the **proxy's log** (every
request the agent made to the outside) and the **sidecar's log** (every model
request and web search), read with `./sandbox logs proxy` and
`./sandbox logs sidecar`. Those come from processes the agent cannot touch.
What the tools below add is a second view from underneath: which programs
ran, and which connections were attempted, including ones that never got as
far as the proxy.

## What each one gives you

| File | Tool | Records | Tied to |
|---|---|---|---|
| `agent-sandbox.rules` | Linux audit (auditd) | Every program start and every `connect` by the agent's user; every write under the sandbox's state directory | The agent's user id as the host sees it: all sessions of your host user, not one. auditd has no notion of a container |
| `falco-rules.yaml` | Falco | Program starts and connections in the session's containers; a warning when anything but its own program starts in the proxy, sidecar or relay | Container name `<session>-<role>` (or the label `agent-sandbox.session=<session>`). Needs Falco to be able to ask Podman for names; see the note in the file |
| `tetragon-policy.yaml` | Tetragon | TCP connection attempts and UDP sends from one container. Tetragon reports program starts by itself | The container's process-namespace number, which you look up and substitute for each session |

All three are noisy during a build. Send them to a file or a collector, not
to a terminal.

## auditd

Load, as the user who runs the sandbox (this fills in the two placeholders;
the state directory must already exist, which it does once you have started
a session):

```sh
start="$(awk -F: -v u="$USER" '$1 == u { print $2; exit }' /etc/subuid)"
# The same rule ./sandbox uses to find its state directory.
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then state="$XDG_RUNTIME_DIR/agent-sandbox"
else state="${TMPDIR:-/tmp}/agent-sandbox-$(id -u)"; fi
sed -e "s|@AGENT_HOST_UID@|$((start + 61000 - 1))|g" -e "s|@STATE_DIR@|$state|g" \
    agent-sandbox.rules | sudo tee /etc/audit/agent-sandbox.rules >/dev/null
sudo auditctl -R /etc/audit/agent-sandbox.rules
```

Read: `sudo ausearch -i -k agent-sandbox-exec` (also `-connect`, `-state`).

Remove:

```sh
for key in agent-sandbox-exec agent-sandbox-connect agent-sandbox-state; do sudo auditctl -D -k "$key"; done
sudo rm /etc/audit/agent-sandbox.rules
```

Rules loaded with `auditctl` are gone after a reboot. That is deliberate
here: the state directory usually lives under `/run/user/<uid>`, which does
not exist at boot, so the rules cannot be loaded from `/etc/audit/rules.d/`.

## Falco

Edit `SESSION` in the file, then:

```sh
falco --validate falco-rules.yaml
sudo cp falco-rules.yaml /etc/falco/rules.d/agent-sandbox.yaml
sudo systemctl restart falco        # the unit's name depends on how Falco was installed
```

Read: wherever your Falco writes alerts (`journalctl -u falco` by default);
filter on the tag `agent-sandbox`.

Remove: `sudo rm /etc/falco/rules.d/agent-sandbox.yaml` and restart Falco.

## Tetragon

Substitute `SESSION` and `PIDNS` as the file's header describes (the number
changes with every session), then:

```sh
sudo tetra tracingpolicy add tetragon-policy.yaml
sudo tetra getevents -o compact
```

Remove: `sudo tetra tracingpolicy delete agent-sandbox-SESSION`. A policy
left behind after `./sandbox destroy` matches nothing, but delete it anyway.

## What was not tested

Everything. In particular:

- whether the user-id arithmetic for auditd matches your Podman's mapping
  (check with `podman top <session>-agent huser`);
- whether Falco resolves container names for rootless Podman on your host
  without the Podman API socket (the file offers a user-id fallback);
- the exact field and flag names, which differ between versions of Falco and
  Tetragon;
- the volume of events, and what it does to a build's speed.
