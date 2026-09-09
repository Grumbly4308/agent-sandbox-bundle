# 09 — Running more than one project

You have several repos across GitHub and GitLab. Two obvious shapes:

- **A: one bundle per project** — `agent-sandbox-app/`, `agent-sandbox-api/`, …
- **B: one bundle per Linux user** — a `agent-app` account, a `agent-api`
  account, each with its own copy.

**Recommendation: start with A. Move a project to B only when its credentials
must not be readable by your normal account.**

Either way, the account running the sandbox must have **no sudo** — see step 1
of the [quickstart](01-quickstart.md). Splitting projects across Linux users is
pointless if each of those users can become root.

Do *not* try to run several projects out of a single bundle directory. It has
one `project/`, one `workspace/`, one `.env`, one `secrets/` and one
allowlist; sharing them means the allowlist is the union of every project's
needs and any credential is reachable from every session. That is the opposite
of what this is for.

---

## Option A — one directory per project

```bash
cp -r agent-sandbox agent-sandbox-api
cd agent-sandbox-api
rm -rf project workspace logs/* auth secrets/deploy_key .env
./sandbox init ssh://git@gitlab.example.org:2222/group/api.git
```

`./sandbox init` writes `SANDBOX_NAME` from the directory name, which prefixes
every container, network and volume:

```yaml
name: ${SANDBOX_NAME:-agent-sandbox}
container_name: ${SANDBOX_NAME:-agent-sandbox}-egress-proxy
```

Without that, the second project's `docker compose up` adopts the first
project's containers — same compose project name, same fixed
`container_name` — and you get one proxy serving two allowlists, or a name
conflict. If you copied an older bundle, add `SANDBOX_NAME` to each `.env`.

What you get:

| | |
|---|---|
| Egress allowlist | Per project. The API repo's internal hosts are not reachable from the frontend's sandbox. |
| Coding agent | Per project. `SANDBOX_AGENT` in each `.env` — one bundle can run claude, another codex. |
| Credentials | Per project. Separate `.env`, separate `secrets/deploy_key`, separate token to revoke. |
| Agent policy | Per project. `profile/` is copied, so you can loosen `qa` or permissions for one repo only. |
| Concurrency | Full. Two agents on two repos at once, each with its own proxy. |
| Cost | Disk: one image layer cache shared, one clone per project. Drift: `profile/` copies diverge unless you keep them in sync. |

Keeping profiles in sync is the one real drawback. If it starts to matter,
make `profile/` a git submodule, or symlink the shared parts:

```bash
ln -s ../agent-sandbox/profile/claude/CLAUDE.md profile/claude/CLAUDE.md
```

Note that a symlink out of the bundle is followed by the *host* when compose
resolves the bind mount, so this works — but keep the target read-only in
spirit: it is shared policy now.

---

## Option B — a separate Linux user per project

Worth the extra setup when the projects have genuinely different trust levels —
a client repo whose deploy key your personal account should not be able to
read, for example.

```bash
sudo useradd -m -G docker agent-clientx
sudo -u agent-clientx -i
git clone <your-bundle> ~/agent-sandbox && cd ~/agent-sandbox
./sandbox init git@github.com:clientx/repo.git
```

What this adds over Option A: **the host's own file permissions now separate
the projects.** In Option A, everything runs as you, so any process running as
you — including an agent that escapes its container — can read every project's
`.env` and `secrets/`. In Option B, `agent-clientx` cannot read
`~agent-app/agent-sandbox/secrets/`.

What it costs:

- `docker` group membership is effectively root on the host. A user in the
  `docker` group can mount `/` into a container. If you use Option B for
  isolation, use **rootless Podman** per user, or a rootless Docker daemon —
  otherwise the boundary you just built is bypassable in one command.
- One image cache per user, so builds and disk multiply.
- `sudo -u … -i` for every session, and `./sandbox login` per user.

A middle path that keeps most of the benefit: stay as yourself, but keep each
bundle's secrets in a directory only readable by you (`chmod 700`), and use
per-repo deploy keys and per-repo tokens so a leak from one project cannot
touch another. That is Option A plus discipline, and for most people it is
where the effort/benefit curve peaks.

---

## Practical layout

```
~/agents/
├── shared-profile/          # optional: the policy you want everywhere
├── agent-sandbox-app/       # SANDBOX_NAME=agent-sandbox-app   (github)
├── agent-sandbox-api/       # SANDBOX_NAME=agent-sandbox-api   (self-hosted gitlab)
└── agent-sandbox-scratch/   # SANDBOX_NAME=agent-sandbox-scratch
```

Rules that keep this manageable:

1. One repo per bundle. Never two.
2. `SANDBOX_NAME` unique, always — it is what stops two projects sharing a proxy.
3. Allowlists stay per project. Resist the urge to make one union list.
4. One deploy key or token per repo, so revoking is per repo.
5. `./sandbox login` per bundle; `auth/` is not shared between them.
6. Commit the bundle (minus `.env`, `auth/`, `secrets/`) so a new project is
   `cp -r` plus `init`.
