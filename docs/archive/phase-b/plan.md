# Phase B — the test plan for a real host

> **Archived.** This is the plan as it stood before the run on 2026-10-09
> and 2026-10-10; the status columns below still say "not run here". What
> the run proved is in [results.md](results.md) and, in short, in
> [docs/08-verification.md](../../08-verification.md).

Version 2 was written on a machine with **no container runtime**. Everything
that could be tested without one was (`make test`). Nothing that needs Podman
has been run: no image has been built, no container started, and **no `verify`
check has passed or failed**.

[test-card.md](test-card.md) is the same plan as a tick-box card, with the
install and onboarding steps spelled out. This file is the reference behind
it: what to set up, what to run in which order, what a good result looks
like, and where to look when a step fails. After the plan come the full list
of `verify` checks and the list of things still unproven, by component.

Two rules:

- When a step fails, fix the cause and write down what it was. **Do not weaken
  the check.**
- Stop at the first failed step in Part 1. Later steps build on earlier ones.

## What you need

- A Linux machine or VM you can throw away. Ubuntu 24.04 is the reference;
  Debian 13 and current Fedora should work the same. (A Mac with
  `podman machine` is an optional extra, step 19.)
- 8 GB of memory and 50 GB of free disk: 20 GB for the disk store, where
  sessions keep their workspaces, and the rest for the system and the images.
  With the default settings one session may take up to about 6.6 GB of memory
  (10.6 GB if its workspace is held in memory), and `doctor` refuses to start
  one the host cannot hold; the test scripts use smaller sizes.
- An **API key from a dedicated Anthropic workspace with a spend cap**, for
  the automated cycle and Part 2.
- For Part 3: a dedicated Claude subscription account, a dedicated ChatGPT
  account (for Codex), both with overage billing off, and a browser.
- For steps 12 and 14: a scratch repository on GitHub or GitLab that you own,
  and for step 14 a token that can push to that one repository and nothing
  else.

## Part 0 — set the host up (once)

As an admin user:

```bash
# Ubuntu 24.04. On Fedora: dnf install podman git jq make ShellCheck nodejs gitleaks
sudo apt update
sudo apt install -y podman uidmap slirp4netns passt catatonit dbus-user-session \
  git jq curl make shellcheck nodejs gitleaks libsecret-tools

# The account the sandbox runs from: no sudo, and its containers may outlive a login.
sudo adduser --disabled-password --gecos "" sandboxer
sudo loginctl enable-linger sandboxer

# The disk store: a filesystem of fixed size where sessions keep their workspaces.
sudo fallocate -l 20G /var/lib/agent-sandbox-store.img
sudo mkfs.ext4 -q -m 0 /var/lib/agent-sandbox-store.img
sudo mkdir -p /var/lib/agent-sandbox-store
echo '/var/lib/agent-sandbox-store.img /var/lib/agent-sandbox-store ext4 loop,nosuid,nodev,nofail 0 0' | sudo tee -a /etc/fstab
sudo mount /var/lib/agent-sandbox-store
sudo chown sandboxer: /var/lib/agent-sandbox-store
```

Then log in **as `sandboxer`** over SSH or on a console, not with `su` (Podman
needs a real login session). Put the repository there, on branch
`build/phase-a`, and work from its top directory.

```bash
# Commits the agent makes carry your name; without one, its commits fail.
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"

# Record the host once.
mkdir -p ~/phase-b-logs
{ cat /etc/os-release; uname -r; podman version; podman info; } > ~/phase-b-logs/00-host.log 2>&1
```

Keep a log of everything. Every command below is meant to be run like this:

```bash
<command> 2>&1 | tee ~/phase-b-logs/<step>.log
```

In Parts 1 and 2 the test key is given as `SANDBOX_TEST_ANTHROPIC_KEY`. Set it
once in the terminal you work in (`read -rs SANDBOX_TEST_ANTHROPIC_KEY; export
SANDBOX_TEST_ANTHROPIC_KEY`, then paste), so it is in no log and no shell
history. `ANTHROPIC_API_KEY` is never read.

## Part 1 — the automated run

Run these in order. Each has one clear pass condition.

### 1. The static tests pass on this host

```bash
make test
```

**Good:** it prints `All static tests passed.` **If not:** the failing group
is named. This is the first place a portability problem shows: the tests were
written with Node 22, git 2.39 and bash 5.2, and Ubuntu 24.04 packages
Node 18. If only the `sidecar` or `gitrelay` groups fail, install Node 22 and
run it again before looking further. (Inside the containers Node comes from
the pinned image, not from the host.)

### 2. Pin the images

```bash
scripts/pin-images.sh
git diff images/PINS services/
git commit -am "Pin the base and service images"
```

**Good:** `images/PINS` and both `services/*/service.conf` now hold
`...@sha256:...` in place of `UNPINNED`. Needs to reach `docker.io`.

### 3. Regenerate the system-call filter

```bash
scripts/make-seccomp.sh
git diff --exit-code seccomp/agent-seccomp.json
sha256sum seccomp/agent-seccomp.json
```

**Good:** no diff, and the checksum is
`742274fe51492c308ee2b5f58bafab372699f07797a4643598e346ab41f991f2`.
Needs to reach `raw.githubusercontent.com`.

### 4. The host checks

```bash
./sandbox doctor
```

**Good:** ends with `This host is ready.` The usual first red line is that
your user may not set CPU limits; the fix is printed (one command as admin,
then log in again). Every red line has a fix under it.

### 5. Every image builds and every CLI starts

```bash
tests/phase-b/images.sh
```

Builds the Codex and OpenCode images and the `python` and `full` toolchains,
runs the barrier checks `run --strict` makes on each, and asks each CLI for
its version. No real credential is used. The first build takes a while.

**Good:** `Every image built, passed the barrier checks at run, and started
its CLI.` **If not:** a `PROBLEM:` line names the combination. A build error
is in the output above it; a barrier failure prints `FAIL <check>` with a
`fix:` line.

### 6. The full cycle with a real key

```bash
tests/phase-b/cycle.sh
```

Twice over (first `tests/fixtures/mini-node` as a local repository with its
workspace on the disk store, then `https://github.com/jonschlinkert/is-number`
cloned on the host with its workspace held in memory), it runs:
`doctor`, `run --strict --auto` with a small task, the **full** `verify`,
`export`, `destroy`, and a check that nothing of the session is left. Then it
runs the deadline test, which makes a three-minute session of its own, lets
the time limit pass with the launcher gone, exports afterwards with hostile
content planted in the repository, and destroys it.

**Good:** no `PROBLEM:` lines and exit status 0. This one command covers most
of the table of checks below. **If not:** each `PROBLEM:` names the step.
`verify` prints one line per check: `PASS`, `FAIL` with a `fix:` line, or
`SKIP` with a reason. A `SKIP` for anything but a stated, legitimate reason
counts as a failure.

This is also the first time a vendor sees a request the sidecar forwarded. If
the agent's task fails with a 4xx from the model API, look at
`./sandbox logs sidecar` before anything else.

## Part 2 — by hand, on a live session

Scripts cannot judge an interactive session. Make a small repository and
start one:

```bash
cp -R tests/fixtures/mini-node ~/mini-node
git -C ~/mini-node init -q && git -C ~/mini-node add -A && git -C ~/mini-node commit -qm fixture

./sandbox run ~/mini-node --auth apikey --strict
```

### 7. The CLI is usable

**Good:** you land in Claude Code with no login prompt and no "use this API
key?" question. Ask it to add a small function and commit. It answers, edits
and commits. Leave it running and open a second terminal for steps 8 to 10.

### 8. What the agent can see and reach

```bash
./sandbox shell
```

Inside:

| Type this | Good result |
|---|---|
| `id` | uid 61000 and gid 61000, nothing else |
| `cat /etc/hosts` | two loopback lines; nothing naming your host |
| `cat /etc/resolv.conf` | empty |
| `getent hosts localhost` | answers |
| `getent hosts example.com` | nothing |
| `env \| grep -iE 'key\|token'` | only values containing `dummy` |
| `curl -sS -o /dev/null https://example.com` | fails; curl says the proxy answered 403 |
| `npm view is-number version` | a version number (the npm registry is on the default list) |
| `touch /probe` | `Read-only file system` |
| `ls /var/run/docker.sock /run/podman` | no such file, twice |

### 9. The allowlist changes without a restart

On the host, with the shell from step 8 still open:

```bash
./sandbox allow example.com --reason "phase B test"
# inside: the curl line from step 8 now succeeds, with no output
./sandbox deny example.com
# inside: it fails with 403 again
./sandbox allow --preset github-downloads --reason "phase B test"
# inside: curl -sSI https://raw.githubusercontent.com/jonschlinkert/is-number/master/README.md
#         -> an answer from GitHub (HTTP 200, or 404 if the file has moved), not a proxy 403
# inside: curl -sSI https://github.com/
#         -> the proxy's 403: the preset allows downloads, not github.com itself
```

### 10. The logs say what happened

```bash
./sandbox logs proxy | tail -n 20
./sandbox logs sidecar | tail -n 5
./sandbox logs sidecar | grep -c "$SANDBOX_TEST_ANTHROPIC_KEY"     # must print 0
```

**Good:** the proxy log has one line for each request from steps 8 and 9,
allowed and denied, with the host name. The sidecar log has one JSON line per
model request, with the budget left, and the key appears nowhere in it.

### 11. Verify, export, destroy

```bash
./sandbox verify
./sandbox export
./sandbox destroy
podman ps -a; podman volume ls; podman network ls
```

**Good:** `verify` exits 0. `export` prints the commits, the diff and a
`RUNS LATER` section, and leaves a repository under
`~/agent-sandbox-out/<session>/repo.git` holding the agent's commit. After
`destroy` the three Podman listings show nothing whose name starts `asb-`.

### 12. Push and pull request (needs a repository of yours)

```bash
./sandbox run https://github.com/<you>/<scratch>.git --auth apikey --auto -- -p "Add a line to the README and commit."
./sandbox export
./sandbox push
./sandbox pr          # optional; needs gh or glab
./sandbox destroy
```

**Good:** the branch `agent/<session>` appears on the remote with the agent's
commit and no `Co-Authored-By` or "Generated with" line in its message.

### 13. Sibling services

```bash
./sandbox run ~/mini-node --auth apikey --strict --service postgres:16 --service redis:7
```

In a second terminal:

```bash
./sandbox shell
# inside:
node -e 'for (const v of ["DATABASE_URL","REDIS_URL"]) { const u = new URL(process.env[v]); const s = require("net").connect(u.port, u.hostname); s.on("connect", () => { console.log(v, "open"); s.end(); }).on("error", (e) => console.log(v, e.message)); }'
exit
./sandbox verify
./sandbox logs service | tail -n 5
./sandbox destroy
```

**Good:** both print `open`; `verify` exits 0. It covers the two service
containers too.

### 14. The git relay

```bash
./sandbox run https://github.com/<you>/<scratch>.git --auth apikey --git-relay --strict
# paste the narrow git token when asked
```

In a second terminal:

```bash
./sandbox shell
# inside:
git commit --allow-empty -m "relay test" && git push origin HEAD        # accepted
git push origin HEAD:refs/heads/some-other-branch                         # refused
git tag relay-test && git push origin relay-test                          # refused
exit
./sandbox verify            # runs B30-other-branch and B30-tag
./sandbox logs relay | tail -n 5
./sandbox destroy
```

**Good:** only the session branch reaches the remote. `B30-force-push` is a
stated `SKIP` (the relay cannot refuse a force push; protect the branch on
the git host).

### 15. The disk store's limits

```bash
scripts/verify.sh --store-test
```

Makes two short sessions of its own on the store: one writes past its share,
the other fills the store.

**Good:** `B33-share-watch` and `B33-store-full` pass: the first session is
stopped by the watch, and the second gets "no space left" while the rest of
the host's disk is untouched.

### 16. Upgrade

```bash
./sandbox upgrade
```

**Good:** every image is rebuilt from scratch and the old and new versions of
what is in them are printed.

## Part 3 — subscription logins

These need a browser and the dedicated accounts. Open a new terminal in which
`SANDBOX_TEST_ANTHROPIC_KEY` is **not** set.

### 17. Claude Code with a Pro or Max subscription

```bash
claude setup-token                 # on any machine signed in to the dedicated account
./sandbox login                    # paste the token; it goes into the OS keyring
./sandbox run ~/mini-node --strict
./sandbox verify
./sandbox export && ./sandbox destroy
```

**Good:** as step 7, with no login prompt. In `verify`, `B15-token-absent`
is a `PASS`: the real token was searched for in the agent container and not
found.

### 18. Codex with a ChatGPT login, and OpenCode with a key

```bash
codex login                                        # the Codex CLI on this host; writes ~/.codex/auth.json
./sandbox login --agent codex
./sandbox run ~/mini-node --agent codex --strict
./sandbox verify && ./sandbox destroy

./sandbox login --agent opencode --auth apikey     # the Anthropic key from the dedicated workspace
./sandbox run ~/mini-node --agent opencode --auth apikey --strict
./sandbox verify && ./sandbox destroy
```

**Good:** each CLI answers a prompt.

One thing a single sitting cannot show: the launcher renews the Codex login on
the host only when its access token has under ten minutes left, about ten days
after `codex login`. Start a Codex session then. It must start without asking
you to sign in again, and a second one after it must too (the renewed login
was written back to the keyring). Until then, record the renewal as not run.

## Part 4 — optional

### 19. Other hosts

- **Fedora** (SELinux on): repeat steps 1 to 6. `B05-lsm-label` runs there
  and is a stated `SKIP` on Ubuntu.
- **macOS** with `podman machine`: repeat steps 1 to 6. Everything on macOS
  is unproven, the keyring handling in particular.
- **gVisor:** install `runsc`, then `export SANDBOX_RUNTIME_CLASS=runsc` and
  repeat step 6. Untested by design until a host has it.

## When you are done

Bring back `~/phase-b-logs/` and, for every step, one of: passed, failed (with
what you saw), or not run. A failed step plus its log is enough to fix from.

| Step | Result | Notes |
|---|---|---|
| 1 static tests | | |
| 2 pin images | | |
| 3 seccomp identical | | |
| 4 doctor | | |
| 5 images | | |
| 6 cycle and deadline test | | |
| 7 CLI usable | | |
| 8 inside the container | | |
| 9 allow and deny | | |
| 10 logs | | |
| 11 verify, export, destroy | | |
| 12 push and pull request | | |
| 13 services | | |
| 14 git relay | | |
| 15 disk store | | |
| 16 upgrade | | |
| 17 Claude subscription | | |
| 18 Codex and OpenCode | | |
| 19 other hosts | | |

## The verify checks — none has been run

Every row of the barrier register in
[docs/00-threat-model.md](../../00-threat-model.md) has checks. **Status of all
of them: not run here.** Steps 6, 11, 13, 14 and 15 above are where they run.

| Barrier | Checks | Status |
|---|---|---|
| B01 non-root user | `B01-user` | not run here |
| B02 no capabilities | `B02-caps`, `B02-raw-socket`, `B02-caps-all` | not run here |
| B03 no new privileges | `B03-nnp-flag`, `B03-setuid-inert`, `B03-nnp-all` | not run here |
| B04 system-call filter | `B04-seccomp-mode`, `-ptrace`, `-mount`, `-unshare-user`, `-clone-newuser`, `-clone3`, `-setns`, `-process-vm-readv`, `-bpf` | not run here |
| B05 SELinux | `B05-lsm-label` | not run here |
| B06 namespaces, no runtime | `B06-runtime-sockets`, `-runtime-binaries`, `-pid1`, `-cgroupns`, `-private-modes`, `-runtime-class` | not run here |
| B07 read-only root | `B07-readonly-root`, `B07-readonly-all` | not run here |
| B08 writable places | `B08-writable-set`, `-mount-flags`, `-fill`, `-workspace-volume` | not run here |
| B09 no host mounts | `B09-mounts`, `B09-host-mounts` | not run here |
| B10 cgroup limits | `B10-pids-max`, `-memory-max`, `-swap-max`, `-cpu-max`, `-fork-limit`, `-limits-all` | not run here |
| B11 ulimits | `B11-ulimits`, `-fsize`, `-core-all` | not run here |
| B12 no route out | `B12-no-route`, `B12-network-attach` | not run here |
| B13 no gateway, no host address | `B13-gateway-ports`, `-etc-hosts`, `-hosts-all`, `-network-no-gateway` | not run here |
| B14 no resolver | `B14-no-resolver`, `B14-dns-by-hand` | not run here |
| B15 no credential inside | `B15-key-files`, `-push`, `-token-absent` | not run here |
| B16 cannot forge an address | `B16-add-address`, `B16-packet-socket` | not run here |
| B20 proxy default-deny | `B20-denied-host`, `-allowed-host`, `-port-80`, `-connect-port`, `-ip-literal-v4`, `-ip-literal-v6`, `-never-allow` | not run here |
| B21 vendor from sidecar only | `B21-vendor-plain`, `-vendor-forged`, `-sidecar-allowed` | not run here |
| B22 credential sidecar | `B22-credential-swap`, `-credential-replace` | not run here in a container; the same assertions pass against a mock as plain processes (`tests/sidecar/`) |
| B23 sidecar forwards only what is needed | `B23-unknown-path`, `-mcp-servers`, `-web-fetch` | as B22 |
| B24 request budget | `B24-budget`, `B24-oversized` | as B22 |
| B25 request log | `B25-search-logged`, `B25-proxy-log` | as B22 |
| B26 time limit | `B26-deadline-set`, `-keeper`, `-deadline`, `-export-after-deadline` | not run here |
| B27 export | `B27-git-config-hook`, `-attribution`, `-secret-scan`, `-dependency-diff`, `-symlink`, `-endless-stream` | not run here through Podman; `scripts/export.sh` passes the same cases on built fixtures (`tests/export/`), with a stand-in for gitleaks |
| B28 logs | `B28-log-driver` | not run here |
| B29 launcher refusals | `B29-rootless`, `B29-doctor` | refusals tested against a fake Podman (`tests/launcher/`); not run on a real one |
| B30 git relay | `B30-other-branch`, `B30-tag` (`B30-force-push` is a stated SKIP) | not run here in a container; passes with the real git client against a local mock (`tests/gitrelay/`) |
| B31 destroy | `B31-destroy` | not run here |
| B32 output filter | `B32-logs-filter`, `B32-export-filter` | filter tested (`tests/launcher/`, `tests/export/`); not run on real output |
| B33 disk store watch | `B33-share-watch`, `B33-store-full` | not run here |

## Unproven, by component

These are the things only a real Podman, a real Squid, a real gitleaks or a
real vendor can settle. Each is the first place to look when a step above
fails.

### Podman itself

- A rootless user can create the memory-backed named volume
  (`--opt type=tmpfs`). The manual says the option needs root; a maintainer
  says it has worked since 4.0. **If this fails, nothing starts.** The fallback
  is a `--tmpfs /workspace` mount on the keeper and a shared mount, which needs
  a design change.
- The keeper keeps that volume mounted after the agent container is killed, so
  the workspace survives the deadline.
- `/workspace` (mode 1777) lets the agent's user create `repo` after the keeper
  mounted it first.
- An explicit `--tmpfs /dev/shm` is writable with `--read-only-tmpfs=false`.
- `--memory-swap` equal to `--memory` is accepted and gives a swap allowance of
  zero. Fallback: `--cgroup-conf=memory.swap.max=0`.
- An internal network with `--disable-dns` has no gateway address (filed
  upstream as a bug; may change), and static `ip=` addresses work on it.
- `--dns=none` leaves the image's empty `/etc/resolv.conf` in place.
- `--no-hosts` leaves the image's `/etc/hosts` in place and mounts nothing
  over it, in every container. `B13-etc-hosts` and `B13-hosts-all` fail if
  not.
- `--hostname sandbox` is accepted together with `--no-hosts`.
- `--image-volume=ignore` stops a service image's declared data directory
  becoming an uncapped volume on disk, and Redis starts with `/data` read-only.
- `--timeout` kills each container at the deadline with the launcher gone.
- `--http-proxy=false` and the proxy with both networks' name service off still
  resolves outside names through the host's resolvers.
- `--cpus` and `--device-write-bps` under rootless (controller delegation).
- Every `podman inspect --format` field name the launcher and `verify` read.
- A named volume that is a bind of a directory on the disk store
  (`--opt type=none --opt o=bind,nosuid,nodev`), created by a rootless user,
  and `podman unshare chown` / `du` / `rm` on that directory.
- The store is mounted again after a reboot by its `/etc/fstab` line (`loop`,
  `nofail`), and `destroy --all` then removes what earlier sessions left.
- On a host with SELinux, whether containers may write to the store as it is,
  or its files need the container label first.
- That 4.4 really is the oldest Podman all of the above works on. Ubuntu
  24.04's 4.9 is the oldest one this plan exercises.
- macOS: everything, through `podman machine`. In particular, storing a
  Codex login (about 8 KB once encoded) through the `security` tool may be cut
  short by its line limit.

### Images

- That each `Containerfile` builds at all (`COPY --chmod`, comment lines inside
  `RUN`, a tag-plus-digest `FROM`, Chromium without its setuid helper).
- Each CLI runs from the unpacked install (no `npm install` is used) and
  reports its version; Codex's platform package is installed under an alias,
  OpenCode's plain x64 build needs AVX2 (a baseline build is pinned as well).
- `catatonit -P` as the first process reaps children and stops on SIGTERM.
- The empty `/etc/resolv.conf` and the two-line `/etc/hosts` survive the
  build as written (builders manage both files themselves while building).
- The service images' own `/etc/hosts` holds loopback addresses only.
- Postgres and Redis start as non-root on a read-only root.
- `scripts/pin-images.sh` records the multi-architecture digest.

### Proxy

- `squid -k parse` accepts the rendered configuration on Alpine 3.20's Squid
  (most at risk: `dstdom_regex -n`, `hosts_file none`, the log format, an empty
  `extra.conf`).
- Squid starts as uid 31 with no capabilities on a read-only root and can write
  to standard output under Podman's log driver.
- `squid -k reconfigure` picks up a replaced list through the read-only mount.
- No DNS query leaves for a name that is not on a list, or for an IP literal.

### Credential sidecar

- **The vendors accept the forwarded requests**: Anthropic with a
  `setup-token`, and `chatgpt.com` with a Codex access token sent from Node,
  not from the Codex binary.
- The real CLIs tolerate the sidecar's 503 and 403 answers as intended, and
  send no tool type, path or encoding outside the lists in `sidecar.json` (a
  refusal shows up as a logged 400 or 404).
- Web-search queries are found in real reply streams. (Codex's ChatGPT models
  turned out to search through a request of the CLI's own instead, which the
  sidecar now forwards and logs; proven 2026-10-10. The reply path is still
  unproven for any model that uses the hosted tool.)
- The image's certificate store verifies the vendors' certificates through a
  real Squid `CONNECT`.

### Agents

- Each CLI reaches the sidecar when its base URL and `NO_PROXY` hold an
  address (`http://10.201.x.3:8080`), not a name. The spike did not use this
  form.
- Claude Code with `--auto`: whether the one-time "bypass permissions" dialog
  appears.
- Codex's interface in API-key mode, and its trusted-directory entry.
- OpenCode's interface with `--auto`.

### Codex subscription login

- The host-side renewal: endpoint, request body, reply shape, and that the
  rotated refresh token is written back to the keyring. Not exercised at all.
- The dummy token the Codex CLI is given carries only an expiry and a dummy
  account id; the real CLI may want more claims.

### Export

- Real gitleaks: that the installed version accepts `--ignore-gitleaks-allow`
  and a bare repository, and that the extra rule in `policy/gitleaks.toml`
  loads. If the packaged gitleaks is too old for the flag, install a current
  release.
- git 2.40 or newer: the attribute handling on a bare repository.
- BSD `awk`, `cut`, `tr` and bash 3.2 on macOS.

### Git relay

- GitHub or GitLab accepting the relay's push bodies and its Basic
  authentication header, through a real Squid.
- The agent's git reaching the relay by address with `NO_PROXY` set, so that a
  plain `git push` to the `origin` the import sets works.

### Extras

Nothing in `extras/` has been loaded or started: the auditd rules, the Falco
rules, the Tetragon policy, the Lima template and the Multipass file. Their
field names and package names are from memory.

## The sidecar spike (requirement 19)

Done in Phase A against a mock API and a proxy that refuses everything, with
dummy tokens. All three CLIs can be run with only a dummy credential and a base
URL pointing at a sidecar; `agents/<name>/compat.md` records the settings each
needs. What the spike could not show, and steps 6, 17 and 18 above will: that
the vendors accept the requests once the sidecar puts a real credential on
them.
