# 05 — Agents and toolchains

## Agents are plug-ins

Each agent is a directory under `agents/`. The launcher knows nothing about
any particular agent; a fourth one is a fourth directory.

| File | What it is |
|---|---|
| `install.sh` | Runs when the image is built. Installs one pinned version of the CLI, checks the sha512 of every package it unpacks, and runs no install scripts. |
| `allowlist.txt` | Two lists: hosts the agent may reach, and hosts the sidecar may reach for it (the model API). |
| `env` | `NAME=value` lines the CLI needs in its environment to find the sidecar. |
| `launch` | Starts the CLI inside the container. Writes the few settings the CLI needs to start, sets the **dummy** credential, handles `--auto`. |
| `compat.md` | Every one of those settings, why it is there, and whether it was proven necessary. |
| `auth.md` | Which credentials this agent may use, and how `./sandbox login` gets them. |
| `sidecar.json` | What the credential sidecar forwards for this agent: upstream, paths, which request features are allowed. |

Shipped: `claude` (Claude Code 2.1.296), `codex` (Codex CLI 0.162.1),
`opencode` (OpenCode 1.18.34).

## Switching agents on one repository

A session's agent is fixed when it starts. To use another agent on the same
repository, start another session with `--agent`, after storing that agent's
credential once with `./sandbox login --agent <name>`.

- **A fresh start:** `./sandbox run <repo> --agent codex`. It starts from the
  repository as it is now and knows nothing of other sessions. A Claude
  session and a Codex session can run on the same repository at once.
- **Carrying on from the other agent's work**, with
  `--branch agent/<first session>`, which continues that branch from its
  last commit. The first agent's work has to come out first, one of two
  ways:
  - **A, through the remote:** `export`, `push`, `destroy`, then
    `run <repo-url> --agent codex --branch agent/<first session>`.
  - **B, straight from the export, nothing pushed:** `export`, `destroy`,
    then `run ~/agent-sandbox-out/<first session>/repo.git --agent codex
    --branch agent/<first session>`.

Read each export, RUNS LATER above all, before the next agent builds on it.
[09 — Sessions](09-sessions.md#another-agent-on-the-same-repository) has both
ways in full, with how to push the result of B.

## Agent configuration is the vendor's default

We ship no `CLAUDE.md`, no `AGENTS.md`, no hooks and no permission rules. Rules
like that are read and applied by the agent itself, so the agent can ignore
them; this project does not rely on them and does not call them controls. See
"vapor" in the [threat model](00-threat-model.md).

What `launch` and `env` do set is the minimum for the CLI to start in a
container with no way out except the proxy and the sidecar. Each agent's
`compat.md` lists every setting. The ones that matter:

- **Claude Code**: the base URL of the sidecar; a marker that first-run setup
  is done (the home directory is new every session); a switch so WebFetch does
  not ask a vendor host for permission first.
- **Codex**: a custom model provider pointing at the sidecar, and
  `sandbox_mode = "danger-full-access"`. Codex's own sandbox cannot work inside
  this container, which does not let anything create namespaces; the container
  is the sandbox.
- **OpenCode**: the base URL pinned in a way a repository's own configuration
  file cannot override. Even so, a repository can ask OpenCode to use its
  built-in provider at `opencode.ai`; only the proxy stops that, and that host
  is not on the list.

"Attribution off" is set as a courtesy. `./sandbox export` is what removes AI
attribution from commits, on the host.

None of these settings is a deny rule. Delete them all and the sandbox is
exactly as safe; the CLI just will not start.

## `--auto`

```bash
./sandbox run <repo> --auto
```

runs the agent with its permission-bypass flag
(`--dangerously-skip-permissions` for Claude Code, the equivalent for Codex and
OpenCode). Permission prompts are for a person who is watching. With or without
them, what the agent can reach is decided by the container, the proxy and the
sidecar.

## Web tools

- **Web search** (Claude Code's WebSearch, Codex's web search) runs on the
  vendor's servers. For Claude it is part of a model request; for Codex's
  ChatGPT models it is a request of the CLI's own to the vendor's search
  endpoint, which the sidecar forwards and counts against the budget like a
  model request. It is allowed; the sidecar logs each query and each page
  address. It is one of the stated non-goals of the threat model: a query is
  a string that leaves.
- **WebFetch** in Claude Code runs inside the container. It goes through the
  proxy and reaches only hosts on the allowlist.

## MCP servers

An MCP server that a repository declares as a command runs inside the agent's
container, under the same limits. One that is a remote address needs that host
on the allowlist (`./sandbox allow`). The sidecar refuses model requests that
ask the vendor to connect to an MCP server on the agent's behalf.

## Toolchains

`--toolchain` chooses what is installed in the agent image. Every program is
something a hostile agent can use, so the lists are short, and
`images/agent/Containerfile` gives a reason for each.

| Toolchain | Adds |
|---|---|
| `node` (default) | Node and npm, git, ripgrep, curl, jq, less, patch, process tools |
| `python` | the above, plus Python 3, pip and venv |
| `full` | the above, plus a C/C++ compiler, Python headers and headless Chromium |

In every toolchain there is no container runtime, no `sudo` and no SSH client.

**Chromium** has its own sandbox, which needs to create namespaces and so
cannot work here. Run it with `--no-sandbox`. The container is the boundary.

What does not work inside, by design: building container images, and test
suites that start their own containers. Use `--service` for a database or a
cache ([06](06-services.md)).

## Versions and upgrades

Base images are pinned by digest in `images/PINS`; CLI versions and package
hashes are pinned in each `install.sh`. Each image carries a list of
everything installed in it at `/usr/share/sandbox/sbom.json`.

```bash
./sandbox upgrade
```

moves each CLI's pin to the version npm calls `latest` (`scripts/pin-clis.sh`
reads the new version and the integrity of each package from the registry and
rewrites `install.sh`; `git diff agents` shows what changed), rebuilds every
image from scratch, and prints old → new versions. `--keep-clis` rebuilds
from the pins as they are. To pin a version that is not `latest`, change the
version and hashes in `install.sh` by hand (the top of the file says how) and
run `./sandbox upgrade --keep-clis`.

Debian packages inside the image are not pinned to a version: the base image
digest fixes most of them, and the rest are whatever Debian served on the build
day. The SBOM records what you got.

## Adding an agent

1. Copy an existing directory under `agents/`.
2. In `install.sh`, pin the version and the sha512 of the package and its
   Linux packages (`npm view <pkg>@<version> dist.integrity`).
3. In `sidecar.json`, name the vendor's host, the API paths the CLI uses, and
   how the credential is put on a request.
4. In `launch`, point the CLI at `$SANDBOX_SIDECAR_URL` (the sidecar's
   address in this session; there are no names to use) and give it a dummy
   credential. Settings that are the same in every session can go in an `env`
   file of `NAME=value` lines; it is optional.
5. In `allowlist.txt`, list the model API host under `[sidecar]`.
6. Write `compat.md` and `auth.md`.
7. `./sandbox upgrade`. The sidecar's image holds a copy of every agent's
   `sidecar.json`, and is only rebuilt when asked.
8. `./sandbox run <repo> --agent <name> --strict`.

Next: [06 — Services](06-services.md).
