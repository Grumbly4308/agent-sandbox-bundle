# 01 — Quickstart

Run an AI coding agent on your repository inside a disposable container that
has no route to the internet except an allowlist, cannot see your SSH keys, and
is deleted when you exit.

Start to finish on a fresh VM: about 15 minutes, most of it waiting for `apt`
and the first image build.

**Assumes:** a vanilla Ubuntu 24.04 (or Debian 12) VM, and a GitHub or GitLab
repository you can already clone.

**You will use two accounts.** An admin account with `sudo`, used only for the
installs in step 2 — and a separate account with **no sudo at all**, which is
the one that actually runs the agent. Step 1 explains why that matters more
than it sounds.

---

## 1. Make an account that cannot become root

Skip this and the sandbox is mostly decoration.

The container is the wall. But if something ever gets past it — a container
escape, or just you pasting a command the agent suggested — it lands in
whatever account launched the sandbox. If that account can become root, the
attacker is one `sudo` away from owning the machine, and everything the
container was protecting is moot.

**On a cloud VM this is the default and it is the worst case.** AWS, Azure and
GCE images all ship their default user (`ubuntu`, `ec2-user`, `azureuser`) with
a `NOPASSWD:ALL` rule in `/etc/sudoers.d/`. That account can become root with
no password, no prompt, no friction. It is exactly the account you are handed
when the VM boots, and exactly the one not to run an agent as.

Check what you currently have:

```bash
sudo -n true 2>/dev/null && echo "PASSWORDLESS SUDO — do not run the sandbox here"
groups            # 'sudo', 'wheel', 'admin' or 'docker' all mean root is reachable
```

So, as your admin user, create a dedicated one:

```bash
sudo adduser --disabled-password --gecos "" sandboxer
```

`adduser` on Debian/Ubuntu does **not** add a new user to `sudo`, so this
account starts unprivileged. Confirm rather than assume:

```bash
sudo -l -U sandboxer          # want: "not allowed to run sudo"
groups sandboxer              # want: just "sandboxer"
sudo grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/ 2>/dev/null
```

That last one is the important check, and the one people skip. A blanket rule
in `/etc/sudoers.d/90-cloud-init-users` can grant passwordless sudo to a group
your new user happens to be in. If `sandboxer` appears in that output, fix it
before going further.

Also make sure it is **not** in the `docker` group. Membership of `docker` is
equivalent to root on the host — `docker run -v /:/host` mounts your whole
filesystem — which is most of why this guide uses rootless Podman instead.

Give it a way in. Either set a password (`sudo passwd sandboxer`), or better,
copy your SSH key so you can log in directly:

```bash
sudo install -d -m 700 -o sandboxer -g sandboxer /home/sandboxer/.ssh
sudo cp ~/.ssh/authorized_keys /home/sandboxer/.ssh/
sudo chown sandboxer:sandboxer /home/sandboxer/.ssh/authorized_keys
sudo chmod 600 /home/sandboxer/.ssh/authorized_keys
```

**SSH in as `sandboxer` for the rest of this guide** — `ssh sandboxer@your-vm`.
A real login session is worth having: `su`/`sudo -i` does not always set up
`XDG_RUNTIME_DIR` and the user D-Bus session, and rootless Podman needs both.
If you must switch users locally, use `sudo -iu sandboxer` and then check
`echo $XDG_RUNTIME_DIR` is set; if it is empty, `export XDG_RUNTIME_DIR=/run/user/$(id -u)`.

`./sandbox` checks this for you and warns loudly if the account running it can
reach root. That warning is not pedantry — it is the difference between a
sandbox and a speed bump.

---

## 2. Install the dependencies

**As your admin user** (the one with sudo), not as `sandboxer`:

```bash
sudo apt update
sudo apt install -y \
  podman podman-compose \
  uidmap slirp4netns fuse-overlayfs dbus-user-session \
  git curl ca-certificates
```

Podman runs **rootless**: there is no root daemon, so if something ever broke
out of the container it would land in your unprivileged account rather than on
the host as root. `uidmap`, `slirp4netns` and `fuse-overlayfs` are what make
rootless work; without them Podman falls back or fails in confusing ways.

Now set up the **sandboxer** account for rootless containers — still as the
admin user, because these need sudo:

```bash
sudo loginctl enable-linger sandboxer
grep "^sandboxer:" /etc/subuid /etc/subgid
```

Both greps should print a line. If they print nothing, Podman has no UID range
to map into and nothing will work:

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 sandboxer
```

Optional, still as the admin user:

```bash
sudo apt install -y jq          # nicer command logging
sudo apt install -y gh          # GitHub CLI, for `./sandbox pr` and merging
```

Without `gh` (or `glab` for GitLab), `./sandbox pr` still works — it prints the
URL that opens the pull-request form instead of opening it for you.

Finally, put the bundle somewhere `sandboxer` can read it:

```bash
sudo cp agent-sandbox-bundle.tar.gz /home/sandboxer/
sudo chown sandboxer:sandboxer /home/sandboxer/agent-sandbox-bundle.tar.gz
```

**That is the last command needing sudo.** Log in as `sandboxer` now —
`ssh sandboxer@your-vm` — and stay there for everything below. If Podman
complains about storage on first use, `podman system migrate` clears it.

---

## 3. Unpack, and make a copy for this project

As `sandboxer`, in that account's home directory:

```bash
cd ~
tar -xzf agent-sandbox-bundle.tar.gz
cd agent-sandbox-bundle

cp -r agent-sandbox agent-sandbox-myproject
cd agent-sandbox-myproject
```

**One repository per copy.** Never point two projects at one directory — it has
a single `.env`, a single set of credentials, and a single egress allowlist, and
sharing them means every project can reach every other project's hosts. For a
second repo, come back and `cp -r agent-sandbox agent-sandbox-otherproject`.

---

## 4. Write your `.env`

```bash
cp .env.example .env
chmod 600 .env
```

`.env.example` is heavily commented and lists every option. You do not need
most of them. Open `.env` and **replace the entire contents** with this:

```bash
SANDBOX_RUNTIME=podman

# ↓↓↓ THESE TWO YOU MUST CHANGE ↓↓↓
GIT_AUTHOR_NAME=Your Name
GIT_AUTHOR_EMAIL=you@example.com
```

That is genuinely all. Everything else is either optional or filled in for you:

| Left out | Why that's fine |
|---|---|
| `HOST_UID` / `HOST_GID` | Read live from `id -u` / `id -g` on every run and written back here automatically. |
| `SANDBOX_NAME` | Taken from this directory's name, so each project copy gets its own containers. |
| `ANTHROPIC_API_KEY` | Not needed if you log in in step 5. Add one later for unattended runs, with a spend limit. (Running codex instead? `OPENAI_API_KEY` is its equivalent.) |
| `GIT_TOKEN` | Not needed. You push from your own shell, so the container never holds repo credentials. |
| `AGENT_MEMORY`, `AGENT_CPUS`, everything else | Sensible defaults (4 GB, 2 CPUs) are built in. |

`GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` matter because they are the name on
every commit the agent makes. Put **your** name there. The sandbox is configured
so nothing marks these commits as AI-written — no `Co-Authored-By` trailer, no
"Generated with" line — because the tool is a tool and you are the author.

`chmod 600` because this file will hold secrets if you ever add any.

---

## 5. Get the agent running

```bash
./sandbox init git@github.com:you/myproject.git
./sandbox login
./sandbox new fix-login
./sandbox go
```

**`init`** clones your repo into `project/` (which is never mounted into the
container), adds its host to the egress allowlist, and writes the rest of `.env`.

> Using a self-hosted server on a non-standard SSH port? Use the `ssh://` form —
> `ssh://git@gitlab.example.org:2222/group/repo.git`. The short
> `git@host:2222/group/repo.git` form **cannot carry a port**; git reads `2222/`
> as part of the path and you get a misleading "could not be found or you don't
> have permission".

**`login`** starts the agent once so you can authenticate. Type `/login` at the
prompt (codex offers its sign-in on first run), finish in the browser, then
exit. The session is saved to `auth/` and reused by every later run — without
this you would log in again every session, because the container's home
directory is wiped each time.

> Headless VM with no browser? The flow prints a URL. Open it on your laptop and
> paste the code back into the terminal.

**`new fix-login`** makes a fresh clone at `workspace/` on a branch called
`agent/fix-login`. That directory is the only part of your machine the agent can
see. Use a new one per task.

**`go`** starts the agent and attaches it to your terminal. Work with it as
normal. When you exit, the container is deleted.

Optional, worth doing once so you believe it:

```bash
./sandbox verify     # proves the walls: no internet, no keys, read-only root
```

---

## 6. Ship the work — from your own shell, outside the sandbox

The agent commits. **You** review and push, using your normal git credentials.
Nothing in the container can push on its own.

```bash
./sandbox review
```

Shows the diff, the commits, any files the agent left behind that git isn't
tracking, and a scan for accidentally committed secrets. Read the full diff
before you push:

```bash
git -C workspace diff origin/main...HEAD
```

Then push, and open a pull request:

```bash
./sandbox push
./sandbox pr "Fix the login redirect"
```

`pr` pushes and opens the PR (GitHub) or MR (GitLab). With `gh`/`glab`
installed it opens it directly; otherwise it prints the URL to click.

Merge it — deliberately, after a human has read it:

```bash
gh pr merge --squash --delete-branch        # GitHub
glab mr merge --yes --remove-source-branch  # GitLab
```

Or just click **Merge** in the web UI.

---

## 7. Clean up

```bash
./sandbox destroy    # stops containers, deletes workspace/, lists what to revoke
./sandbox logout     # deletes the saved login from auth/
```

`destroy` leaves `project/`, `.env` and your logs alone, so the next
`./sandbox new <task>` is fast. Run `logout` when you're done on this machine —
the saved session is a live login to your Claude account.

---

## The whole thing, once more

```bash
# once per machine — as the ADMIN user
sudo adduser --disabled-password --gecos "" sandboxer
sudo -l -U sandboxer          # must say: not allowed to run sudo
sudo apt install -y podman podman-compose uidmap slirp4netns fuse-overlayfs \
                    dbus-user-session git curl ca-certificates
sudo loginctl enable-linger sandboxer
grep "^sandboxer:" /etc/subuid /etc/subgid    # must print two lines

sudo cp agent-sandbox-bundle.tar.gz /home/sandboxer/ && sudo chown sandboxer: /home/sandboxer/agent-sandbox-bundle.tar.gz

# everything below as SANDBOXER:  ssh sandboxer@your-vm
# once per project
cd ~ && tar -xzf agent-sandbox-bundle.tar.gz && cd agent-sandbox-bundle
cp -r agent-sandbox agent-sandbox-myproject && cd agent-sandbox-myproject
cp .env.example .env && chmod 600 .env && nano .env
./sandbox init git@github.com:you/myproject.git
./sandbox login

# once per task
./sandbox new fix-login
./sandbox go
./sandbox review
./sandbox push
./sandbox pr "Fix the login redirect"
./sandbox destroy
```

---

## Commands you'll actually use

| Command | What it does |
|---|---|
| `./sandbox new <task>` | Fresh clone on branch `agent/<task>` |
| `./sandbox go` | Start the agent |
| `./sandbox shell` | A bash prompt inside the sandbox, to look around |
| `./sandbox review` | Diff, leftovers, secret scan — on your machine |
| `./sandbox push` | Push the branch with your own credentials |
| `./sandbox pr [title]` | Push and open a PR / MR |
| `./sandbox allow <host>` | Let the agent reach one more hostname |
| `./sandbox logs proxy` | Watch every request the agent makes, allowed or blocked |
| `./sandbox status` | What's running, which branch, which credentials are set |
| `./sandbox doctor` | Diagnose and repair a broken setup |
| `./sandbox upgrade [ver]` | Rebuild the image with a newer agent CLI; pin or unpin a version |
| `./sandbox agent <name>` | Switch the coding agent (claude / codex) and swap the allowlist |
| `./sandbox destroy` | Tear it all down |

---

## When something goes wrong

```bash
./sandbox doctor
```

It checks the runtime, your user IDs, the workspace state and your credentials,
and repairs most problems on the spot. If that isn't enough,
[08-troubleshooting.md](08-troubleshooting.md) lists every
failure this setup actually produces, with its real cause — which is almost
never the obvious one.

**"this account can run sudo without a password"** — the check from step 1,
firing. You are running the sandbox from an account that can become root, which
defeats most of the point. Move to a dedicated account, or set
`SANDBOX_ALLOW_PRIVILEGED=1` in `.env` if you have decided the risk is
acceptable on this machine.

Two you may hit on an older distro:

- **Ubuntu 22.04**'s `podman-compose` is too old for `--in-pod=false`. The
  script tells you; add `SANDBOX_USERNS=off` to `.env` and afterwards run
  `podman unshare chown -R 0:0 workspace` to fix file ownership. Ubuntu 24.04
  has no such problem.
- **`mem_limit` silently ignored** on cgroups v1. Check with
  `[ -f /sys/fs/cgroup/cgroup.controllers ] && echo v2 || echo v1`. Anything
  current is v2.

---

## Going deeper

This quickstart is the short version. The full guide explains what each layer
defends against and how to change it.

| # | Document | Covers |
|---|---|---|
| 02 | [Why, and the threat model](02-threat-model.md) | What you are actually defending against |
| 03 | [Prerequisites and layout](03-prerequisites-and-layout.md) | How the directory is arranged, and why |
| 04 | [The container](04-container.md) | Image, runtime flags, how to verify them |
| 05 | [Egress control](05-egress-proxy.md) | The allowlist proxy you build yourself |
| 06 | [Credentials](06-credentials.md) | Deploy keys, scoped tokens, staying logged in |
| 07 | [The profile](07-profile.md) | Settings and standing instructions that survive every rebuild |
| 08 | [Troubleshooting](08-troubleshooting.md) | Every real failure, with its real cause |
| 09 | [More than one project](09-multiple-projects.md) | Directories vs Linux users |
| 10 | [Push and pull requests](10-push-and-pr.md) | Getting the work back out |
| 11 | [Podman notes](11-podman.md) | Rootless details, and Docker if you prefer it |

Single-file version of everything: [`sandboxing-ai-coding-agent.md`](../sandboxing-ai-coding-agent.md).
