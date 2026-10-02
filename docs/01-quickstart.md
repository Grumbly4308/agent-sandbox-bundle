# 01 — Quickstart

From nothing to an agent working on your repository, inside a container it
cannot get out of with your credentials, in about fifteen minutes. Most of that
is the first image build.

Read [00 — Threat model](00-threat-model.md) first if you want to know what
this does and does not protect. The short version: the agent gets one copy of
one repository, a short list of hosts, and a number of model requests. It does
not get your files, your keys or your login.

> **Status.** The code has been written and tested without a container
> runtime. It has not yet been run against Podman. [PHASE-B.md](../PHASE-B.md)
> lists what is still unproven. Until that list is worked through, treat every
> barrier as designed, not verified.

## 1. An ordinary account

Run the sandbox from an account that cannot become root. If a kernel bug ever
lets an agent out of its container, it lands in the account that started it.

On a cloud VM the default user (`ubuntu`, `ec2-user`, `azureuser`) has
passwordless `sudo`. Make another one:

```bash
sudo adduser --disabled-password --gecos "" sandboxer
sudo loginctl enable-linger sandboxer     # lets its containers outlive your login
```

Then log in as that user (`ssh sandboxer@host`), not with `su`.

`./sandbox` refuses to run as root. There is no flag to change that.

## 2. Install Podman

Podman is the only container runtime this uses, and it runs as your ordinary
user: there is no background service running as root and no special group to
join.

```bash
# Debian / Ubuntu 24.04 or newer (as an admin user)
sudo apt install -y podman uidmap passt git

# Fedora
sudo dnf install -y podman git

# macOS
brew install podman git && podman machine init && podman machine start
```

Optional but worth having on the host:

- `gitleaks` — the secret scan at export. Without it `export` still works but
  `push` refuses.
- `secret-tool` (package `libsecret-tools`) on Linux — stores the model
  credential in your OS keyring. macOS has its own.
- `gh` or `glab` — lets `./sandbox pr` open the pull request for you.

## 3. Check the host

```bash
./sandbox doctor
```

Green and red lines, and a one-line fix under each red. The usual first-time
red is that your user is not allowed to set CPU limits; the fix is printed and
takes one command and a re-login.

The first time, also pin the base images. Their exact versions cannot be
looked up ahead of time, so the repository ships with placeholders and a build
refuses until you have run:

```bash
scripts/pin-images.sh
```

## 4. Store the model credential, once

```bash
./sandbox login                      # Claude Code with a Pro or Max subscription
./sandbox login --agent codex        # Codex with a ChatGPT plan
./sandbox login --agent opencode --auth apikey
```

It tells you what to paste and puts it in your OS keyring. It also tells you
three things that matter more than the command: use a **dedicated account** for
sandboxes, switch **overage billing off** on it, and how to **revoke** the
credential. See [03 — Credentials](03-credentials.md).

## 5. Run

```bash
./sandbox run https://github.com/you/project.git
# or a repository already on this machine
./sandbox run ~/code/project
```

What happens, in order:

1. The host checks are repeated; anything red stops the run.
2. Your repository is cloned **on the host**, with your own credentials if it
   needs them, and handed to the sandbox as a single file. The sandbox never
   sees a git credential.
3. The containers start: the agent, the proxy, the credential sidecar and a
   small keeper that holds the workspace.
4. The barrier checks run: the first time for a given set of images, Podman
   version, kernel and shape of session, and every time with `--strict`. Any
   failure stops the run.
5. You are attached to the agent.

Useful options:

| Option | What it does |
|---|---|
| `--agent claude\|codex\|opencode` | Which agent. Default `claude`. |
| `--auto` | The agent acts without asking you. The container is the boundary either way. |
| `--toolchain node\|python\|full` | What is installed in the image. Default `node`. |
| `--service postgres:16` | Start a database beside the agent. See [06](06-services.md). |
| `--ttl 2h` | The time limit. Default four hours. |
| `--budget 200` | How many model requests the session may make. |
| `--mem 4g --cpus 2 --pids 512` | Resource ceilings. |

When the agent exits, the session is still there. Nothing is lost until you
destroy it.

## 6. Get the work out

```bash
./sandbox export
```

This brings the session's branch out as a clean repository under
`~/agent-sandbox-out/<session>/` and prints, in this order, what you should
read: the commits, the code diff, and then a section called **RUNS LATER** —
lockfiles, dependency files, CI workflows, build files, anything that will
execute on your machine or in CI after you merge. Read that section first. It
is the one attack the sandbox cannot stop.

Then:

```bash
./sandbox push      # pushes that branch with YOUR credentials, from the clean copy
./sandbox pr        # push, then open the pull request
```

`push` refuses if the secret scan did not pass, if an AI attribution line could
not be removed, or if the agent rewrote history below where it started.

## 7. Clean up

```bash
./sandbox destroy
```

Containers, networks, the workspace and the session's files are removed.
Nothing of the session is left except the image cache.

A session you forget keeps holding the memory its files occupy, even after its
time limit has cut it off from the network. Every `./sandbox` command reminds
you which sessions are still there.

## The whole thing, once more

```bash
./sandbox doctor
scripts/pin-images.sh                 # first time only
./sandbox login                       # first time only
./sandbox run https://github.com/you/project.git
./sandbox export
./sandbox push
./sandbox destroy
```

## Commands

| Command | What it does |
|---|---|
| `./sandbox doctor` | Is this host safe to run on? |
| `./sandbox login` | Store the model credential in your keyring |
| `./sandbox run <repo>` | Start a session and attach |
| `./sandbox shell` | A shell inside the agent container |
| `./sandbox verify` | Attempt every bypass in the barrier register |
| `./sandbox allow <host> --reason "<why>"` | Let the agent reach one more host. See [02](02-egress.md) |
| `./sandbox deny <host>` | Take it off again |
| `./sandbox logs [agent\|proxy\|sidecar\|service]` | What each container printed |
| `./sandbox export` | Bring the branch out and review it |
| `./sandbox push` / `./sandbox pr` | Send the reviewed branch to the repository |
| `./sandbox destroy [--all]` | Remove the session, or every session |
| `./sandbox upgrade` | Rebuild the images from scratch and show old → new versions |

Next: [02 — Egress](02-egress.md).
