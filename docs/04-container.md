# 04 — Layer 1: the container

> **Defends:** destructive filesystem operations (threat 1), persistence
> (threat 6), resource exhaustion (threat 5).

The container is the walls: its own filesystem, a non-root user, no view of your
host, and hard ceilings on what it can consume.

## The image

Everything the agent will ever run is installed at **build** time, because the
root filesystem is read-only at **run** time.

`agent/Dockerfile`:

```dockerfile
FROM ubuntu:24.04

ARG HOST_UID=1000
ARG HOST_GID=1000
ARG AGENT_CLI="@anthropic-ai/claude-code"

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl file git jq less make nano netcat-openbsd nodejs \
      npm openssh-client patch procps python-is-python3 python3 python3-pip \
      python3-venv ripgrep shellcheck tini tree unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

# `ext::` remotes let git run an arbitrary command as the transport.
RUN git config --system protocol.ext.allow never

# Ubuntu 24.04 ships a stock `ubuntu` user on uid 1000. Remove it so the agent
# user can take YOUR uid — otherwise every file the agent writes into the
# mounted worktree comes back owned by the wrong user.
RUN userdel -r ubuntu 2>/dev/null || true; \
    groupadd -g "${HOST_GID}" agent 2>/dev/null || true; \
    useradd -m -u "${HOST_UID}" -g "${HOST_GID}" -s /bin/bash agent

RUN npm install -g ${AGENT_CLI}

COPY entrypoint.sh /usr/local/bin/agent-entrypoint
RUN chmod 0755 /usr/local/bin/agent-entrypoint

WORKDIR /workspace/repo
USER agent
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agent-entrypoint"]
CMD ["claude"]
```

Four details that are easy to get wrong:

**The uid dance.** If the container user's uid doesn't match yours, every file
the agent creates in the bind-mounted worktree comes back owned by someone else,
and you hit permission errors the moment you try to review or commit.
`./sandbox` reads your real uid and gid from `id(1)` on **every run**, exports
them for compose interpolation, and rewrites `.env` when the stored values
disagree — so a bundle copied to another machine or account just works. Freezing
them at `init` time is what produced the "deploy key exists but is unreadable"
and "files owned by nobody" failures in
[08 — Troubleshooting](08-troubleshooting.md). Because the agent user is created
from those build args, the uid is part of the image tag
(`localhost/agent-sandbox-agent:claude-1000`): a changed uid names an image that
does not exist yet, and the next run builds it. Ubuntu 24.04's stock `ubuntu`
account already occupies uid 1000, hence the `userdel`.

**One image, shared.** The tag is per agent and uid, not per project, so every
bundle copy on the account runs the same image and `./sandbox upgrade` in any
of them moves them all ([09](09-multiple-projects.md)). A start does not
rebuild: it builds only when the image is missing, or when that copy's `agent/`
changed since it last built.

**`tini` as PID 1.** Agents spawn a lot of subprocesses. Without an init to reap
them, a long session accumulates zombies until it hits `pids_limit` and
mysteriously stops being able to run anything.

**Install only what the project needs.** Every extra binary is attack surface.
`netcat-openbsd` is here because SSH-over-443 through the proxy needs it
([06](06-credentials.md)); `jq` because the command-logging hook uses it
([07](07-profile.md)); `make` because `qa` runs `make test`, `nano` because
the shell profile sets `EDITOR=nano`. The remaining build and inspection tools
(`patch`, `unzip`, `xz-utils`, `file`, `tree`, `procps`, `shellcheck`) talk to
no network and open no new hosts. If your project doesn't need Python, drop it.
The image also sets `protocol.ext.allow=never` in the system gitconfig, so git
cannot run a command as a remote transport (`ext::`) no matter what URL a
submodule or a pasted `git fetch` carries.

**The CLI is installed as root into `/usr/local`.** The agent runs as `agent` and
the filesystem is read-only, so it cannot modify or replace its own binary —
which matters, because an agent that can rewrite its own harness can rewrite its
own permission checks.

To use a different agent: `./sandbox agent codex` (or `claude`) handles the
built-in pair — it sets `AGENT_CLI`/`AGENT_BIN` in `.env`, swaps the vendor
block of the egress allowlist ([05](05-egress-proxy.md)) and asks for the
rebuild. For anything else, set `AGENT_CLI` in `.env` yourself for npm-based
CLIs (and `AGENT_BIN` to its launcher name), or swap the `npm install -g` line
for `pip install aider-chat` and adjust `CMD` — and give it an allowlist block
under `proxy/agents/` while you are at it.

## The runtime flags

From `docker-compose.yml`:

```yaml
  agent:
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    read_only: true
    tmpfs:
      - /tmp:mode=1777,size=1g
      - /home/agent:mode=0777,size=1g          # no uid=/gid=: Podman rejects them
    volumes:
      - ./workspace:/workspace/repo        # the ONE folder of yours it sees
      - ./profile:/opt/profile:ro          # defaults it can read, never edit
      - ./logs:/logs                       # audit trail, written outside
      - ./secrets:/run/secrets:ro          # deploy key, if you use one
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    pids_limit: 512
    mem_limit: ${AGENT_MEMORY:-4g}
    cpus: ${AGENT_CPUS:-2}
    networks: [egress]                     # internal — no route to the internet
```

| Setting | What it buys you |
|---|---|
| `user: <your uid>` | Non-root. An exploit inherits an unprivileged account, and file ownership stays sane. |
| `read_only: true` | `/`, `/usr`, `/etc` immutable. No installed backdoor, no edited rc file, no modified agent binary. |
| `tmpfs` for `/tmp` and `$HOME` | RAM-backed scratch that vanishes on exit — and the reason [the profile](07-profile.md) has to be re-materialised each start. |
| `cap_drop: [ALL]` | No raw sockets, no mounting, no `ptrace` of other processes. |
| `no-new-privileges` | A setuid binary cannot escalate, even if one sneaks into the image. |
| `pids_limit` / `mem_limit` / `cpus` | Fork bombs and runaway builds hit a ceiling instead of your laptop. |
| One bind mount | Everything not mounted is not merely forbidden — it does not exist in that mount namespace. |
| `networks: [egress]` | Declared `internal: true`. No default route at all — see [05](05-egress-proxy.md). |

### The mount rule

**Never mount `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.kube`, or your home
directory.** Not read-only, not "just this once."

Unmounted is a strictly stronger guarantee than any permission rule, because it
is enforced by the kernel rather than by a config file the agent can read. A
deny rule says "don't look here"; an absent mount means there is no *here*.

## Resource and time limits

The cgroup limits above are tunable via `.env` (`AGENT_MEMORY`, `AGENT_CPUS`).
Two additions worth having:

**A wall-clock kill switch**, from a second terminal:

```bash
sleep 3600 && docker compose -f agent-sandbox/docker-compose.yml kill agent &
```

Hard stop after an hour, regardless of what the agent believes it is doing.

**Disk quota.** The tmpfs mounts are capped at 1 GB each, so `/tmp` and `$HOME`
cannot fill your disk. The worktree is the remaining exposure — keep
`agent-sandbox/` on a quota-limited filesystem, or add `--storage-opt size=10G`
(overlay2 on xfs with pquota enabled).

**Budget ceilings belong at the API key**, not in the container. See
[06](06-credentials.md).

## Prove it, don't assume it

```bash
./sandbox verify
```

This runs `scripts/verify.sh` inside the real container and checks each claim
on this page:

```
── identity ──
  ✓ running as non-root (uid 1000)
  ✓ cannot sudo
  ✓ all capabilities dropped
── filesystem ──
  ✓ / is read-only
  ✓ /tmp is writable
  ✓ /workspace/repo is a git worktree
  ✓ profile mount is read-only
── credentials ──
  ✓ no host ssh keys reachable
  ✓ host root filesystem not mounted
── egress (allowlist) ──
  ✓ no direct route to the internet
  ✓ allowed host reachable (api.anthropic.com)
  ✓ blocked host refused (example.com)
── profile ──
  ✓ settings.json materialised
  ✓ qa is on PATH
── limits ──
  ✓ pid limit set
  ✓ memory limit set
```

Run it after any change to the compose file. A sandbox you haven't tested is a
sandbox you're assuming.

Next: [05 — Layer 2, egress control](05-egress-proxy.md).
