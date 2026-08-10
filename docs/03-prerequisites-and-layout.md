# 03 — Prerequisites and layout

## What to install

**git** — verify with `git --version`. On a fresh machine, set your identity:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

**A container runtime — rootless Podman by default.** No root daemon, so a
container escape lands in your unprivileged account rather than on the host as
root.

```bash
sudo apt install -y podman podman-compose uidmap slirp4netns \
                    fuse-overlayfs dbus-user-session
sudo loginctl enable-linger "$USER"
podman run --rm hello-world      # verify
```

See [11 — Podman](11-podman.md) for the details.

**Docker** works too — `SANDBOX_RUNTIME=docker` in `.env`. Use the packaged
apt/dnf instructions at docs.docker.com rather than piping a script into a root
shell, and note that `docker` group membership is equivalent to root on the
host, which is most of why Podman is the default.

**Optional:** `gitleaks` on the host (secret scanning in `./sandbox review`), and
`jq` (used by the seccomp generator and by the command-logging hook).

## Layout

```
agent-sandbox/
├── sandbox                  # the CLI: init, new, go, verify, review, push, destroy
├── docker-compose.yml       # two services: agent (locked down), egress-proxy (the gate)
├── docker-compose.podman.yml # rootless-Podman overlay, applied automatically
├── .env                     # your short-lived secrets — chmod 600, never committed
│
├── agent/
│   ├── Dockerfile           # the agent's world
│   └── entrypoint.sh        # rebuilds $HOME from profile/ on every start
│
├── proxy/
│   ├── Dockerfile           # stock Alpine + Squid, no third-party image
│   ├── squid.conf           # default-deny allowlist
│   └── allowlist.txt        # the hosts the agent may reach — this is your policy
│
├── profile/                 # ★ your defaults, version-controlled, mounted read-only
│   ├── claude/settings.json #   permission rules + hooks
│   ├── claude/CLAUDE.md     #   standing instructions
│   ├── bin/qa               #   custom commands on PATH
│   ├── shellrc.sh           #   aliases, prompt
│   └── setup.sh             #   per-session bootstrap
│
├── scripts/
│   ├── verify.sh            # self-test: are the walls actually there?
│   └── make-seccomp.sh      # optional syscall hardening
│
├── project/                 # the canonical clone — NEVER mounted
├── workspace/               # a clone of project/ — the ONE host dir the agent sees
├── logs/                    # audit trail, written from inside, readable outside
├── auth/                    # saved agent login, if you use one — chmod 700
└── secrets/                 # deploy key, if you use one — mounted read-only
```

## Why `project/` and `workspace/` are separate

This split is load-bearing, not organisational tidiness.

`project/` is an ordinary clone that lives only on your host. `workspace/` is a
**clone of `project/`** on its own branch, and is the **only** thing
bind-mounted into the container.

```bash
git clone --no-hardlinks project workspace
git -C workspace remote set-url origin <the real upstream>
git -C workspace checkout -B agent/fix-login origin/main
```

Consequences:

- A `git reset --hard`, a deleted file, or a botched merge in `workspace/`
  cannot touch `project/` or your real working tree.
- The agent's output arrives as a clean branch you can diff, rather than as
  edits scattered through a checkout you were also using.
- Throwing the session away is `rm -rf workspace` — no cleanup, no stashing,
  no "wait, what did it change?"
- Two sessions on two tasks are two directories, fully independent.

### Why a clone and not a `git worktree`

The obvious choice here is `git worktree add`, and this bundle used to do
exactly that. It does not work across a container boundary.

A linked worktree's `.git` is not a directory but a *file* containing an
absolute host path:

```
gitdir: /home/you/agent-sandbox/project/.git/worktrees/workspace
```

The objects, the refs and that worktree's admin directory all live under
`project/.git`, which is deliberately never mounted into the container. So
every git command the agent ran failed with:

```
fatal: not a git repository: .../project/.git/worktrees/workspace
```

Mounting `project/` would fix the error and delete the isolation: the container
would have write access to the canonical clone's object store and refs. A
worktree is simply the wrong shape for this boundary.

The split state also breaks on the host. Delete `workspace/` by hand and git
still has it registered (`missing but already registered worktree`); re-clone
`project/` and the registration is gone while the checkout remains (`not a git
repository`); a half-failed `worktree add -b` leaves the branch behind so the
retry dies with `a branch named 'agent/x' already exists`. `git worktree prune`
clears exactly one of those three. See [08 — Troubleshooting](08-troubleshooting.md).

A clone is self-contained: it works inside the container, `rm -rf` is a
complete uninstall, and `--no-hardlinks` keeps the object stores physically
separate. The cost is disk — a second copy of the objects, on top of the one
`project/` already holds.

`./sandbox new <task>` does all of this for you, including fetching `origin`
first so the branch starts from current upstream rather than from whatever you
last pulled, and repointing `workspace`'s `origin` at the real remote so
`./sandbox push` reaches the server rather than a folder on your disk.

## What gets committed

`agent-sandbox/` is meant to live in version control. The `.gitignore` excludes
the parts that are per-session or secret:

| Committed | Ignored |
|---|---|
| `sandbox`, `docker-compose.yml` | `.env`, `secrets/*`, `auth/` |
| `agent/`, `proxy/`, `scripts/` | `project/`, `workspace/` |
| **`profile/`** — your agent policy | `logs/*`, `agent-seccomp.json` |
| `proxy/allowlist.txt` — your egress policy | |

Committing `profile/` and `allowlist.txt` is the point: changes to what your
agent is allowed to do become reviewable pull requests with authorship and
history, instead of undocumented local drift. On a team it is the difference
between "everyone's agent is configured somehow" and "here is our agent policy".

One bundle holds one repository. For several projects, copy the bundle per
project and give each a distinct `SANDBOX_NAME` — see
[09 — Running more than one project](09-multiple-projects.md).

Next: [04 — Layer 1, the container](04-container.md).
