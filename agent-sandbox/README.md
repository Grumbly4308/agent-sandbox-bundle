# agent-sandbox

A disposable, network-restricted container to run an AI coding agent in.

**New here? Read [`../README.md`](../README.md) instead** — it is a step-by-step
setup guide starting from a fresh VM. This file is the reference for what each
piece in this directory is.

```bash
./sandbox init git@github.com:you/project.git
./sandbox login                   # log in once — or put a key in .env
./sandbox new fix-login           # fresh clone on branch agent/fix-login
./sandbox verify                  # confirm the walls are actually there
./sandbox go                      # start the agent
./sandbox review                  # diff + attribution check + secret scan, on the host
./sandbox push                    # push from YOUR environment
./sandbox pr                      # ...or push and open the PR / MR
./sandbox destroy                 # burn it down
```

Self-hosted git on a non-standard SSH port needs the `ssh://` form —
`ssh://git@host:2222/group/repo.git`. `init` rewrites the scp-style version and
tells you it did.

If the account running the sandbox should hold no git credentials at all, no
SSH key and no stored token, clone over HTTPS with a read-only token that is
asked for on every fetch and never written to disk:

```bash
SANDBOX_PULL_AUTH=prompt ./sandbox init https://github.com/you/project.git
```

See `../docs/06-credentials.md`, "Pulling without stored credentials".

Full explanation: `../sandboxing-ai-coding-agent.md`.
Something broken: `./sandbox doctor`, then `../docs/08-troubleshooting.md`.

## What's here

| Path | What it is |
| --- | --- |
| `sandbox` | The CLI. Every command you need. |
| `docker-compose.yml` | Two services: the locked-down agent, and the egress proxy. |
| `docker-compose.podman.yml` | Applied on top when `SANDBOX_RUNTIME=podman`. |
| `agent/` | The agent image and the entrypoint that rebuilds `$HOME` from `profile/`. |
| `proxy/` | A stock Squid configured as a default-deny allowlist. No third-party image. |
| `proxy/agents/` | Per-vendor allowlist blocks; the active one is compiled into `allowlist.txt`. |
| `profile/` | **Your defaults, version-controlled.** Survives every sandbox regeneration. |
| `scripts/verify.sh` | Self-test: read-only rootfs, dropped caps, blocked egress, mounts. |
| `scripts/make-seccomp.sh` | Optional Layer 4 — a tightened seccomp profile. |
| `project/` | The canonical clone. Never mounted into the container. |
| `workspace/` | A clone of `project/` that **is** mounted. The only host dir the agent sees. |
| `auth/` | A saved agent login, if you use one. `chmod 700`, gitignored. |
| `secrets/` | A deploy key, if you use one. Mounted read-only. |

## The profile

`profile/` is the answer to "I don't want to re-configure this every time."
It is mounted **read-only** at `/opt/profile`, and the entrypoint copies it
into the container's ephemeral `$HOME` at every start:

| Profile file | Becomes | Purpose |
| --- | --- | --- |
| `claude/settings.json` | `~/.claude/settings.json` | Permission allow/ask/deny lists, attribution, hooks |
| `claude/CLAUDE.md` | `~/.claude/CLAUDE.md` | Standing instructions for the agent |
| `codex/AGENTS.md` | `~/.codex/AGENTS.md` | The same standing instructions, for codex |
| `bin/*` | `~/.local/bin/*` | Custom commands on `PATH` (e.g. `qa`) |
| `shellrc.sh` | `~/.bashrc` | Aliases, prompt, env |
| `setup.sh` | runs at start | Per-session bootstrap (`npm ci`, venv, …) |

Read-only is the point: the agent uses its own permission rules but cannot
rewrite them. Commit `profile/` to git and changes to it become reviewable
policy changes rather than undocumented local drift.

Shipped defaults worth knowing about: `attribution.commit` and `attribution.pr`
are empty strings, and `CLAUDE.md` forbids `Co-Authored-By` and every other AI
trailer — the tool is a tool, you are the author. `./sandbox verify` checks both
are in place and `./sandbox review` greps outgoing commits for them.

## Choosing the agent

Claude Code is the default. Each bundle (one per project) can run codex
instead:

```bash
./sandbox agent codex     # rewrites .env, swaps the allowlist, reloads the proxy
./sandbox upgrade         # rebuild so the image carries the codex CLI
./sandbox login           # sign in with ChatGPT — or put OPENAI_API_KEY in .env
```

`SANDBOX_AGENT` in `.env` records the choice; `OPENAI_API_KEY` is the codex
equivalent of `ANTHROPIC_API_KEY`. The egress allowlist is generated from
`proxy/allowlist.base.txt` plus `proxy/agents/<agent>.txt`, so exactly one
vendor's endpoints are reachable at a time — `./sandbox verify` checks that
the inactive vendor's API is actually refused. Your own entries
(`./sandbox allow`) live in the base file and survive the swap.

One agent per bundle, deliberately: one image, one credential set, one vendor
on the allowlist. Run the same repo under both agents by copying the bundle,
as with any two projects (below).

One caveat the swap cannot fix for you: `auth/` is mounted read-write into
every session, so a *saved login* for the other vendor stays readable from
inside the container until you `./sandbox logout`. The entrypoint drops the
inactive vendor's API keys from the environment and does not materialise its
saved session, and `./sandbox agent` warns when leftovers exist — but the file
in `auth/` is only gone when you remove it. If you switch vendors for good,
log out first.

## Several projects

One repo per bundle. Copy the directory per project and let `init` set a
distinct `SANDBOX_NAME` in each `.env` — that is what keeps two projects from
sharing one egress proxy. See `../docs/09-multiple-projects.md`.

## Podman

Set `SANDBOX_RUNTIME=podman` in `.env` and everything else stays the same.
Rootless Podman has no root daemon, so a container escape lands in your own
unprivileged account rather than on the host as root. See
`../docs/11-podman.md` for the two things that differ (user namespaces and
SELinux labels), both of which the overlay handles.

## Requirements

Docker, or Podman with `podman-compose`, and git. Optionally `gitleaks` on the host for
`./sandbox review`, `gh`/`glab` for `./sandbox pr`, and `jq` for
`make-seccomp.sh`.
