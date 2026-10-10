# Test card — agent-sandbox v2

> **Archived.** This card was followed on 2026-10-09 and 2026-10-10; the
> filled-in table is [results.md](results.md). Its header below still
> describes the state before that run.

Install it, set it up, and test it on a real machine, one tick box at a time.

**Where things stand.** The code was written and tested on a machine with no
container runtime. `make test` passes there. **Nothing has been run against
Podman yet**: no image built, no container started, no barrier check passed
or failed. This card is the first real run. Expect some steps to fail; that
is what it is for.

**How to use it.**

- Work top to bottom. In sections C and D, stop at the first failure: later
  steps build on earlier ones.
- Tick `pass` or `fail` on every step and fill in the table in section H.
- When a step fails, write down what you saw and keep the log. **Do not
  change a check to make it pass.**
- [plan.md](plan.md) is the reference behind this card: every `verify`
  check by name, and everything still unproven, by component. Start there
  when a step fails.

---

## A. What you need

| | |
|---|---|
| ☐ | A Linux machine or VM you can throw away. **Ubuntu 24.04** is the reference. Debian 13 and current Fedora should behave the same. |
| ☐ | **8 GB of memory, 50 GB of free disk.** 20 GB of the disk becomes the store where sessions keep their workspaces; the rest is for the system and the images. This card runs sessions with small memory sizes, about 3.6 GB each (step C5); with the defaults a session may take about 6.6 GB, and `doctor` refuses a session the host cannot hold. |
| ☐ | Admin (`sudo`) access for the setup in section B only. |
| ☐ | An **Anthropic API key from a dedicated workspace with a spend cap**. Used for sections D and E. |
| ☐ | A scratch repository on GitHub or GitLab that you own (steps E6 and E8). |
| ☐ | A git token that can push to that one repository and nothing else (step E8). |
| ☐ | For section F: a dedicated Claude subscription account and a dedicated ChatGPT account, both with overage billing off, and a machine with a browser. |

---

## B. Install

### B1. Packages (as an admin user)

```bash
sudo apt update
sudo apt install -y podman uidmap slirp4netns passt catatonit dbus-user-session \
  git jq curl make shellcheck nodejs gitleaks libsecret-tools
```

What each is for:

- `podman uidmap slirp4netns passt catatonit dbus-user-session`: Podman run by
  an ordinary user, its networking, the small first process it puts in one
  container, and the piece that lets it apply memory and CPU limits.
- `git jq curl`: the launcher uses them.
- `make shellcheck nodejs`: only for the static tests in step C2.
- `gitleaks`: the secret scan when work is exported. Without it `push`
  refuses. **8.18 or newer is needed**; Debian 13 packages 8.16, which
  `export` refuses to use (`doctor` says so). On such a host install the
  release binary for your user instead, with its checksum checked:

  ```bash
  cd "$(mktemp -d)"
  curl -sSLO https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz \
       -O https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_checksums.txt
  grep linux_x64.tar.gz gitleaks_8.30.1_checksums.txt | sha256sum -c
  tar -xzf gitleaks_8.30.1_linux_x64.tar.gz gitleaks && install -Dm755 gitleaks ~/.local/bin/gitleaks
  ```
- `libsecret-tools`: the keyring, for section F.

On Fedora: `sudo dnf install -y podman git jq make ShellCheck nodejs gitleaks libsecret`.

☐ pass ☐ fail — every package installed.

### B2. A dedicated account with no sudo

If a kernel bug ever lets an agent out of its container, it lands in the
account that started it. That account must not be able to become root.

```bash
sudo adduser --disabled-password --gecos "" sandboxer
sudo loginctl enable-linger sandboxer        # its containers may outlive a login

# Let yourself in as that user over SSH, with the key you already use.
sudo install -d -m 700 -o sandboxer -g sandboxer /home/sandboxer/.ssh
sudo install -m 600 -o sandboxer -g sandboxer ~/.ssh/authorized_keys /home/sandboxer/.ssh/authorized_keys
```

☐ done

### B3. The disk store (still as the admin user)

Sessions keep their workspaces on a filesystem of fixed size made for the
purpose. A session that fills it gets "no space left"; the rest of the
machine's disk is not touched. 20 GB here.

```bash
sudo fallocate -l 20G /var/lib/agent-sandbox-store.img
sudo mkfs.ext4 -q -m 0 /var/lib/agent-sandbox-store.img
sudo mkdir -p /var/lib/agent-sandbox-store
echo '/var/lib/agent-sandbox-store.img /var/lib/agent-sandbox-store ext4 loop,nosuid,nodev,nofail 0 0' | sudo tee -a /etc/fstab
sudo mount /var/lib/agent-sandbox-store
sudo chown sandboxer: /var/lib/agent-sandbox-store
df -h /var/lib/agent-sandbox-store        # about 20G, on a /dev/loop device
```

If you used a recipe from `extras/vm-wrapper/` to make the VM, this is already
done.

☐ pass ☐ fail — `df` shows a filesystem of its own, about 20 GB.

### B4. Log in as that account

Log in **as `sandboxer`** with `ssh sandboxer@<host>`. Do not use `su` or
`sudo -u`: Podman needs a real login session. Everything from here on is done
as `sandboxer`.

Check:

```bash
id                                                   # sandboxer, and no sudo, wheel or admin group
sudo -n true                                         # must fail
podman info --format '{{.Host.Security.Rootless}}'   # must print: true
```

☐ pass ☐ fail — logged in as `sandboxer`; no sudo; Podman reports rootless.

### B5. Get the code

Where the repository is now:

```bash
git bundle create agent-sandbox.bundle build/phase-a
```

Copy `agent-sandbox.bundle` to the test host, then as `sandboxer`:

```bash
git clone -b build/phase-a agent-sandbox.bundle ~/agent-sandbox
cd ~/agent-sandbox
git log --oneline | head -n 3
```

All commands below are run from `~/agent-sandbox`.

☐ pass ☐ fail — the top commit is the one you expect.

### B6. Git identity and a place for logs

```bash
# Commits the agent makes carry your name. Without one, its commits fail.
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"

mkdir -p ~/phase-b-logs
{ cat /etc/os-release; uname -r; podman version; podman info; } > ~/phase-b-logs/00-host.log 2>&1
```

From now on, run every command with a log:

```bash
<command> 2>&1 | tee ~/phase-b-logs/<step>.log
```

Steps with several commands are written out that way already:

```bash
( set -ex
  <command>
  <command>
) 2>&1 | tee ~/phase-b-logs/<step>.log
echo "exit: ${PIPESTATUS[0]}"
```

`set -x` writes each command into the log ahead of its output, and `set -e`
stops at the first one that fails. `exit:` is the status of the commands, not
of `tee`; read it before running anything else. Commands that open a session
or a shell are left outside, since they need the terminal to themselves. To
run a step again, write to `<step>-2.log` rather than over the first log.

☐ done

---

## C. Onboard

### C1. Look at the commands

```bash
./sandbox help
```

☐ pass ☐ fail — a list of commands: `doctor`, `login`, `run`, `shell`,
`verify`, `allow`, `deny`, `export`, `push`, `pr`, `logs`, `destroy`,
`upgrade`.

### C2. The static tests pass on this host

```bash
make test
```

**Good:** it prints `All static tests passed.`

**If not:** the failing group is named. The tests were written with Node 22,
git 2.39 and bash 5.2; Ubuntu 24.04 packages Node 18. If only the `sidecar`
or `gitrelay` groups fail, install Node 22 and run it again before looking
further.

☐ pass ☐ fail

### C3. Pin the images

The repository ships with placeholders where the exact image versions go, and
a build refuses until they are filled in.

```bash
( set -ex
  scripts/pin-images.sh
  git diff images/PINS services/
  git commit -am "Pin the base and service images"
) 2>&1 | tee ~/phase-b-logs/C3.log
echo "exit: ${PIPESTATUS[0]}"
```

**Good:** `images/PINS` and both `services/*/service.conf` now hold
`...@sha256:...` where they said `UNPINNED`. Needs to reach `docker.io`.

☐ pass ☐ fail

### C4. Regenerate the system-call filter

```bash
( set -ex
  scripts/make-seccomp.sh
  git diff --exit-code seccomp/agent-seccomp.json
  sha256sum seccomp/agent-seccomp.json
) 2>&1 | tee ~/phase-b-logs/C4.log
echo "exit: ${PIPESTATUS[0]}"
```

**Good:** no diff, and the checksum is
`742274fe51492c308ee2b5f58bafab372699f07797a4643598e346ab41f991f2`.
Needs to reach `raw.githubusercontent.com`.

☐ pass ☐ fail

### C5. Your settings

Defaults live in `~/.config/agent-sandbox/settings`: one `NAME=value` line
per setting, each with a comment. A flag on the command line wins over a line
there, and a later line wins over an earlier one. The first `./sandbox doctor`
writes the file.

```bash
( set -ex
  ./sandbox doctor > /dev/null 2>&1 || true        # writes the file; its verdict comes in C6
  cat ~/.config/agent-sandbox/settings
) 2>&1 | tee ~/phase-b-logs/C5.log
echo "exit: ${PIPESTATUS[0]}"
```

The file must name the store from step B3, which `./sandbox` found by itself:

```bash
grep '^STORE=' ~/.config/agent-sandbox/settings        # STORE=/var/lib/agent-sandbox-store
```

If that line is empty, the store was not there when the file was written:
go back to B3, then `echo STORE=/var/lib/agent-sandbox-store >> ~/.config/agent-sandbox/settings`.

For this card, make sessions small enough to leave room on an 8 GB machine:

```bash
printf '%s\n' MEM=2g TMP_SIZE=512m HOME_SIZE=512m >> ~/.config/agent-sandbox/settings
```

The workspace is on disk. `/tmp` and the home directory are held in memory,
so a session's memory ceiling is the sum of these:

| Setting | Default | For this card | What it is |
|---|---|---|---|
| `MEM` | `4g` | `2g` | memory for the agent's processes |
| `TMP_SIZE` | `1g` | `512m` | `/tmp` |
| `HOME_SIZE` | `1g` | `512m` | the agent's home directory |
| | | | plus about 0.6 GB for shared memory, the proxy, the sidecar and the keeper |
| **A session may take up to** | **about 6.6 GB** | **about 3.6 GB** | of memory |
| `WORKSPACE_SIZE` | `4g` | `4g` | this session's share of the disk store: the repository, its dependencies and package caches |

Others you may want later: `PIDS` and `NPROC` (default 512; raise both when a
build cannot start more processes), `TTL` (default 4 hours) and `BUDGET`
(default 500 model requests).

☐ pass ☐ fail — the file exists, names the store, and ends with the three
lines you added.

### C6. Check the host

```bash
./sandbox doctor
```

**Good:** a list of `ok` lines, among them `disk store
/var/lib/agent-sandbox-store is a separate filesystem that you own`, ending
with `This host is ready.` Every `FAIL` has a `fix:` line under it. The ones
to expect on a fresh machine:

| `FAIL` line | What to do |
|---|---|
| `cgroup v2, but your user may not set limits for: cpu` | Run the printed command as an admin (it writes one small systemd file), then log out and back in as `sandboxer`. |
| `your subordinate UID range does not reach 61003` | Run the printed `usermod` command as an admin. |
| `the session may use up to ... of memory and this host has ... available` | Step C5 was skipped, or other programs on the host are using the memory. |
| `the disk store ... is an ordinary directory, not a filesystem of its own` | The store is not mounted (step B3, or after a reboot: `sudo mount /var/lib/agent-sandbox-store`). |

A `warn` line saying `no disk store is set up` means the settings file does
not name the store: see step C5.
| `images/PINS still has UNPINNED base images` | Step C3 was skipped. |
| `Podman ... is too old` | Podman 4.4 or newer is needed. |

A `warn` line saying the account can use sudo means step B2 was not followed.

☐ pass ☐ fail — `This host is ready.`

### C7. The test key

Sections D and E use the API key from the dedicated workspace. Put it in the
terminal's environment without it landing in a log or your shell history:

```bash
read -rs SANDBOX_TEST_ANTHROPIC_KEY && export SANDBOX_TEST_ANTHROPIC_KEY      # then paste, Enter
```

Do this in every terminal you open for sections D and E.
`ANTHROPIC_API_KEY` is never read, on purpose.

☐ done

---

## D. Test: automated

### D1. Every image builds and every CLI starts

```bash
tests/phase-b/images.sh
```

Builds the images for Codex, OpenCode and the `python` and `full` toolchains,
runs the barrier checks on each, and asks each CLI for its version. No real
credential is used. The first build takes a while.

**Good:** `Every image built, passed the barrier checks at run, and started
its CLI.`

**If not:** a `PROBLEM:` line names the combination. A build error is in the
output above it. A barrier failure prints `FAIL <check>` with a `fix:` line.

☐ pass ☐ fail

### D2. The full cycle with a real key

```bash
tests/phase-b/cycle.sh
```

Twice (first the small fixture as a local repository, with its workspace on
the disk store; then `https://github.com/jonschlinkert/is-number` cloned on
the host, with its workspace held in memory) it runs:
`doctor`, `run` with a small task for the agent, the **full** `verify`,
`export`, `destroy`, and a check that nothing of the session is left. Then it
runs the deadline test: a three-minute session of its own whose time limit is
allowed to pass with the launcher gone, an export afterwards with hostile
content planted in the repository, and a destroy.

**Good:** no `PROBLEM:` lines; exit status 0. Each `verify` ends with a line
of the form `<n> passed, 0 failed, <n> skipped for a stated reason.`

**If not:** each `PROBLEM:` names the step. `verify` prints one line per
check: `PASS`, `FAIL` with a `fix:` line, or `SKIP` with a reason. A `SKIP`
marked `counts as a failure` is one.

This is the first time a vendor sees a request the sidecar forwarded. If the
agent's task fails with an error from the model API, look at
`./sandbox logs sidecar` first.

☐ pass ☐ fail

---

## E. Test: by hand, on a live session

Scripts cannot judge an interactive session. Make a small repository:

```bash
( set -ex
  cp -R tests/fixtures/mini-node ~/mini-node
  git -C ~/mini-node init -q && git -C ~/mini-node add -A && git -C ~/mini-node commit -qm fixture
) 2>&1 | tee ~/phase-b-logs/E0.log
echo "exit: ${PIPESTATUS[0]}"
```

### E1. Start a session

```bash
./sandbox run ~/mini-node --auth apikey --strict
```

**Good**, in order: how much memory the session may use, and `Its workspace
is on disk: up to 4g of the store at /var/lib/agent-sandbox-store.`;
`creating session asb-mini-node-xxxxxx`; the barrier checks, all `PASS`; `Session ... runs until
...`; then Claude Code, with no login prompt and no "use this API key?"
question. Ask it to add a small function and commit. It answers, edits and
commits.

Leave it running. Open a **second terminal** as `sandboxer` (step C7 again)
for E2 to E4.

☐ pass ☐ fail

### E2. What the agent can see and reach

```bash
./sandbox shell
```

Type each line inside:

| ☐ | Type this | Good result |
|---|---|---|
| ☐ | `id` | uid 61000 and gid 61000, nothing else |
| ☐ | `cat /etc/hosts` | two loopback lines; nothing naming your host |
| ☐ | `cat /etc/resolv.conf` | empty |
| ☐ | `getent hosts localhost` | answers |
| ☐ | `getent hosts example.com` | nothing |
| ☐ | `env \| grep -iE 'key\|token'` | only values containing `dummy` |
| ☐ | `curl -sS -o /dev/null https://example.com` | fails; curl says the proxy answered 403 |
| ☐ | `npm view is-number version` | a version number (the npm registry is on the default list) |
| ☐ | `touch /probe` | `Read-only file system` |
| ☐ | `df -h /workspace /tmp` | `/workspace`: about 20G, the store. `/tmp`: 512M, held in memory |
| ☐ | `ls /var/run/docker.sock /run/podman` | no such file, twice |
| ☐ | `ls ~ /workspace` | an almost empty home; the repository under `/workspace/repo`; nothing of yours |

Stay in this shell for E3.

☐ pass ☐ fail

### E3. The allowlist changes without a restart

In a third terminal on the host, or after leaving the shell and coming back:

| ☐ | On the host | Then, inside the shell | Good result |
|---|---|---|---|
| ☐ | `./sandbox allow example.com --reason "test card"` | `curl -sS -o /dev/null https://example.com` | succeeds, no output |
| ☐ | `./sandbox deny example.com` | the same | fails with 403 again |
| ☐ | `./sandbox allow --preset github-downloads --reason "test card"` | `curl -sSI https://raw.githubusercontent.com/jonschlinkert/is-number/master/README.md` | an answer from GitHub (200, or 404 if the file has moved), not a proxy 403 |
| ☐ | | `curl -sSI https://github.com/` | the proxy's 403: the preset allows downloads, not `github.com` itself |

☐ pass ☐ fail

### E4. The logs say what happened

```bash
( set -ex
  ./sandbox logs proxy | tail -n 20
  ./sandbox logs sidecar | tail -n 5
  set +x                                                             # keeps the key out of the log
  ./sandbox logs sidecar | grep -c "$SANDBOX_TEST_ANTHROPIC_KEY"     # must print 0
) 2>&1 | tee ~/phase-b-logs/E4.log
echo "exit: ${PIPESTATUS[0]}"         # 1 here is right: grep -c exits 1 when it counts nothing
```

**Good:** the proxy log has one line for each request from E2 and E3, allowed
and denied, with the host name. The sidecar log has one JSON line per model
request with the budget left. The key appears nowhere.

☐ pass ☐ fail

### E5. Verify, export, destroy

Leave Claude Code (`/exit`). The session stays.

```bash
( set -ex
  ./sandbox verify
  ./sandbox export
  ./sandbox destroy
  podman ps -a; podman volume ls; podman network ls
) 2>&1 | tee ~/phase-b-logs/E5.log
echo "exit: ${PIPESTATUS[0]}"
```

**Good:**

- ☐ `verify` ends with `0 failed` and exits 0.
- ☐ `export` prints the commits, the diff, and a section called `RUNS LATER`,
  and leaves `~/agent-sandbox-out/<session>/repo.git` holding the agent's
  commit (`git --git-dir ~/agent-sandbox-out/<session>/repo.git log --oneline --all`).
- ☐ After `destroy`, the three Podman listings show nothing whose name
  starts `asb-`, and neither `ls "$XDG_RUNTIME_DIR/agent-sandbox"` nor
  `ls /var/lib/agent-sandbox-store` shows an `asb-` directory.

☐ pass ☐ fail

### E6. Push and pull request

```bash
( set -ex
  ./sandbox run https://github.com/<you>/<scratch>.git --auth apikey --auto -- -p "Add a line to the README and commit."
  ./sandbox export
  ./sandbox push
  ./sandbox pr || true          # optional; needs gh or glab on the host
  ./sandbox destroy
) 2>&1 | tee ~/phase-b-logs/E6.log
echo "exit: ${PIPESTATUS[0]}"
```

**Good:** the branch `agent/<session>` appears on the remote with the agent's
commit, and its message has no `Co-Authored-By` or "Generated with" line.
The repository was cloned and pushed with **your** git credentials on the
host; the sandbox never saw them.

☐ pass ☐ fail

### E7. A database beside the agent

```bash
./sandbox run ~/mini-node --auth apikey --strict --service postgres:16 --service redis:7
```

In the second terminal:

```bash
./sandbox shell
# inside:
node -e 'for (const v of ["DATABASE_URL","REDIS_URL"]) { const u = new URL(process.env[v]); const s = require("net").connect(u.port, u.hostname); s.on("connect", () => { console.log(v, "open"); s.end(); }).on("error", (e) => console.log(v, e.message)); }'
exit
```

Back on the host:

```bash
( set -ex
  ./sandbox verify
  ./sandbox logs service | tail -n 5
  ./sandbox destroy
) 2>&1 | tee ~/phase-b-logs/E7.log
echo "exit: ${PIPESTATUS[0]}"
```

**Good:** `DATABASE_URL open` and `REDIS_URL open`; `verify` ends with
`0 failed` (it covers the two service containers too).

☐ pass ☐ fail

### E8. The git relay

Only for workflows where the agent has to push by itself. What it pushes
skips `export`.

```bash
./sandbox run https://github.com/<you>/<scratch>.git --auth apikey --git-relay --strict
# paste the narrow git token when asked
```

In the second terminal:

```bash
./sandbox shell
```

| ☐ | Inside | Good result |
|---|---|---|
| ☐ | `git commit --allow-empty -m "relay test" && git push origin HEAD` | accepted; the session branch is on the remote |
| ☐ | `git push origin HEAD:refs/heads/some-other-branch` | refused |
| ☐ | `git tag relay-test && git push origin relay-test` | refused |

```bash
( set -ex
  ./sandbox verify            # B30-other-branch and B30-tag are PASS
  ./sandbox logs relay | tail -n 5
  ./sandbox destroy
) 2>&1 | tee ~/phase-b-logs/E8.log
echo "exit: ${PIPESTATUS[0]}"
```

`B30-force-push` is a stated `SKIP`: the relay cannot refuse a force push.
Protect the branch on the git host if that matters.

☐ pass ☐ fail

### E9. The store's limits, and a workspace in memory

```bash
scripts/verify.sh --store-test
```

It makes two short sessions of its own on the store: one writes past its
share, the other fills the store.

**Good:** `B33-share-watch` and `B33-store-full` are `PASS`: the first session
is stopped by the watch, the second gets "no space left", and
`df -h /` shows the machine's own disk no fuller than before.

Then the other kind of workspace, for hosts with no store:

```bash
./sandbox run ~/mini-node --auth apikey --workspace-driver memory --workspace-size 1g --strict
```

In the second terminal: `./sandbox shell`, then `df -h /workspace` shows a
`tmpfs` of 1.0G. Then `./sandbox verify` and `./sandbox destroy`.

☐ pass ☐ fail

### E10. Upgrade

```bash
./sandbox upgrade
```

**Good:** every image is rebuilt from scratch, and the old and new versions
of what is in them are printed.

☐ pass ☐ fail

---

## F. Test: subscription logins

Open a **new terminal** in which `SANDBOX_TEST_ANTHROPIC_KEY` is not set.

### F0. A working keyring

`./sandbox login` stores the credential in the OS keyring through
`secret-tool`. On a desktop Linux session or a Mac that works as it is. On a
server reached over SSH there is usually no keyring running.

```bash
( set -ex
  printf 'probe' | secret-tool store --label "probe" service agent-sandbox-probe agent probe
  secret-tool lookup service agent-sandbox-probe agent probe      # must print: probe
  secret-tool clear  service agent-sandbox-probe agent probe
) 2>&1 | tee ~/phase-b-logs/F0.log
echo "exit: ${PIPESTATUS[0]}"
```

If that fails, one way to start a keyring by hand (not tried by the authors):

```bash
sudo apt install -y gnome-keyring          # as an admin
# as sandboxer, in the terminal you will use:
printf '%s' 'a passphrase of your choice' | gnome-keyring-daemon --unlock --components=secrets
```

Without a keyring you can still do F1: `./sandbox run` asks for the token and
uses it for that session only. A later `./sandbox verify` then reports
`B15-token-absent` as a `SKIP` that counts as a failure, because it has
nothing to search for; the same check ran with the token at `run --strict`.
F2 (Codex) needs the keyring.

☐ pass ☐ fail ☐ no keyring on this host

### F1. Claude Code with a Pro or Max subscription

```bash
claude setup-token                 # on any machine signed in to the dedicated account
./sandbox login                    # paste the token; it goes into the keyring
./sandbox run ~/mini-node --strict
```

After `/exit`:

```bash
( set -ex
  ./sandbox verify
  ./sandbox export && ./sandbox destroy
) 2>&1 | tee ~/phase-b-logs/F1.log
echo "exit: ${PIPESTATUS[0]}"
```

`login` also prints three things worth reading: use a dedicated account,
switch overage billing off, and how to revoke the token.

**Good:** Claude Code starts with no login prompt and answers. In `verify`,
`B15-token-absent` is a `PASS`: the real token was searched for in the agent
container and not found.

☐ pass ☐ fail

### F2. Codex with a ChatGPT login

```bash
codex login                        # the Codex CLI, on a machine with a browser; writes ~/.codex/auth.json
./sandbox login --agent codex      # asks for the path to that file
./sandbox run ~/mini-node --agent codex --strict
```

After leaving Codex:

```bash
( set -ex
  ./sandbox verify && ./sandbox destroy
) 2>&1 | tee ~/phase-b-logs/F2.log
echo "exit: ${PIPESTATUS[0]}"
```

**Good:** Codex starts with no login prompt and answers.

One thing a single sitting cannot show: the launcher renews the Codex login
on the host only when its access token has under ten minutes left, about ten
days after `codex login`. Start a Codex session then; it must start without
asking you to sign in again, and so must the one after it. Until then,
record the renewal as not run.

☐ pass ☐ fail ☐ renewal not run

### F3. OpenCode with an API key

```bash
./sandbox login --agent opencode --auth apikey     # the Anthropic key from the dedicated workspace
./sandbox run ~/mini-node --agent opencode --auth apikey --strict
```

After leaving OpenCode:

```bash
( set -ex
  ./sandbox verify && ./sandbox destroy
) 2>&1 | tee ~/phase-b-logs/F3.log
echo "exit: ${PIPESTATUS[0]}"
```

**Good:** OpenCode starts and answers.

☐ pass ☐ fail

---

## G. Optional

| ☐ | What | How |
|---|---|---|
| ☐ | Fedora, with SELinux on | Sections B to D again. `B05-lsm-label` runs there; on Ubuntu it is a stated `SKIP`. |
| ☐ | macOS with `podman machine` | Sections B to D again. Everything on macOS is unproven. |
| ☐ | gVisor | Install `runsc`, `export SANDBOX_RUNTIME_CLASS=runsc`, repeat D2. |
| ☐ | The time limit, by eye | `./sandbox run ~/mini-node --auth apikey --ttl 5m`, wait six minutes: the agent is cut off; `./sandbox export` still works; `./sandbox destroy`. |

---

## H. When you are done

Clean up:

```bash
( set -ex
  ./sandbox destroy --all
  podman ps -a; podman volume ls; podman network ls        # nothing starting asb-
) 2>&1 | tee ~/phase-b-logs/H.log
echo "exit: ${PIPESTATUS[0]}"
```

Then revoke the test API key in the console, revoke the subscription tokens
(`login` printed how), and delete the VM.

Bring back `~/phase-b-logs/` and this table. A failed step and its log are
enough to fix from.

| Step | Result | Notes |
|---|---|---|
| B1 packages | | |
| B2 account | | |
| B3 disk store | | |
| B4 log in as that account | | |
| B5 code | | |
| C2 static tests | | |
| C3 pin images | | |
| C4 system-call filter identical | | |
| C5 settings | | |
| C6 doctor | | |
| D1 images | | |
| D2 cycle and deadline test | | |
| E1 start a session | | |
| E2 inside the container | | |
| E3 allow and deny | | |
| E4 logs | | |
| E5 verify, export, destroy | | |
| E6 push and pull request | | |
| E7 services | | |
| E8 git relay | | |
| E9 store limits; workspace in memory | | |
| E10 upgrade | | |
| F0 keyring | | |
| F1 Claude subscription | | |
| F2 Codex subscription | | |
| F3 OpenCode | | |
| G optional | | |

---

## Where to look when something fails

| What you see | Look at |
|---|---|
| A `FAIL` or `refused:` line | The `fix:` line right under it. |
| `a barrier check failed, so the session was not started` | The `FAIL` lines above it. Find the check's name in the table in [plan.md](plan.md). |
| `... did not come up within 30 seconds` | `podman ps -a`, then `podman logs <session>-proxy` or `<session>-credsidecar`. |
| An image fails to build | The build output. "Images" under "Unproven" in plan.md lists the likely causes. |
| The CLI starts but every model request fails | `./sandbox logs sidecar`: the status and path of each request. |
| An allowed host is refused | `./sandbox logs proxy`. |
| The session stopped by itself; the next command says `its workspace grew past --workspace-size` | It used more than its share of the store. The work is still there: `./sandbox export`. Start again with a larger `--workspace-size`. |
| A session is left over and in the way | `./sandbox destroy --all` |
| Anything else that refuses | [docs/07-troubleshooting.md](../../07-troubleshooting.md) |

Which session a command acts on: the only one there is, or the one named in
`SANDBOX_SESSION` when there are several.
