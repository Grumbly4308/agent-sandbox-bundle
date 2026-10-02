# Phase B — what has not been run, and how to run it

Version 2 was written on a machine with **no container runtime**. Everything
that could be tested without one was (`make test`). Nothing that needs Podman
has been run: no image has been built, no container started, and **no `verify`
check has passed or failed**. This file is the list of what to run on a real
host and what is still unproven.

When a step fails, fix the cause and record it here. Do not weaken the check.

## Before you start

A Linux host (or a Mac with `podman machine`) and an ordinary account without
`sudo`:

- rootless Podman 4.4 or newer, `git`, `jq`, `curl`
- `gitleaks` (the export's secret scan; without it `push` refuses)
- `secret-tool` on Linux (the keyring), unless you will type credentials in
- an API key from a **dedicated workspace with a spend cap**, for the test run
- for subscription mode: a dedicated Claude account (and ChatGPT account, for
  Codex) with overage billing off

## The steps, in order

```bash
# 1. The static tests still pass on this host (bash, git and node versions differ).
make test

# 2. Pin the base images and the service images. Read the diff, then commit it.
scripts/pin-images.sh
git diff images/PINS services/

# 3. Regenerate the seccomp profile and confirm it is byte-identical to the
#    committed one (expected sha256 742274fe51492c308ee2b5f58bafab372699f07797a4643598e346ab41f991f2).
scripts/make-seccomp.sh
git diff --exit-code seccomp/agent-seccomp.json

# 4. The host checks.
./sandbox doctor

# 5. Every image builds, each CLI starts, and the quick checks pass on each
#    (Codex, OpenCode, and the python and full toolchains; no real credential).
tests/phase-b/images.sh

# 6. The full cycle with Claude Code in API-key mode: doctor, run, verify,
#    export, destroy; first on tests/fixtures/mini-node, then on
#    https://github.com/jonschlinkert/is-number. Also runs the deadline test.
SANDBOX_TEST_ANTHROPIC_KEY=sk-ant-... tests/phase-b/cycle.sh

# 7. Subscription mode, by hand (needs a browser and the dedicated account).
claude setup-token                       # on a machine signed in to that account
./sandbox login                          # paste the token
./sandbox run /path/to/a/repo --strict
./sandbox verify
./sandbox export && ./sandbox destroy

# 8. Codex with a ChatGPT login, by hand.
codex login
./sandbox login --agent codex
./sandbox run /path/to/a/repo --agent codex --strict

# 9. The disk-backed workspace, if you want it (doctor prints how to make a store).
./sandbox run /path/to/a/repo --workspace-driver local --workspace-size 2g --strict
scripts/verify.sh --store-test
```

Each `verify` run prints one line per check: `PASS`, `FAIL` with a `fix:` line,
or `SKIP` with a reason. A `SKIP` for anything but a stated, legitimate reason
counts as a failure.

## The verify checks — none has been run

Every row of the barrier register in
[docs/00-threat-model.md](docs/00-threat-model.md) has checks. **Status of all
of them: not run here.**

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
| B13 no gateway | `B13-gateway-ports`, `-etc-hosts`, `-network-no-gateway` | not run here |
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
- `policy/containers.conf` (`host_containers_internal_ip = "none"`) keeps the
  host's address out of `/etc/hosts`. If not, `B13-etc-hosts` fails.
- `--timeout` kills each container at the deadline with the launcher gone.
- `--http-proxy=false` and the proxy with both networks' name service off still
  resolves outside names through the host's resolvers.
- `--cpus` and `--device-write-bps` under rootless (controller delegation).
- Every `podman inspect --format` field name the launcher and `verify` read.
- `podman unshare chown` / `du` / `rm` on the disk store.
- macOS: everything, through `podman machine`.

### Images

- That each `Containerfile` builds at all (`COPY --chmod`, comment lines inside
  `RUN`, a tag-plus-digest `FROM`, Chromium without its setuid helper).
- Each CLI runs from the unpacked install (no `npm install` is used) and
  reports its version; Codex's platform package is installed under an alias,
  OpenCode's plain x64 build needs AVX2 (a baseline build is pinned as well).
- `catatonit -P` as the first process reaps children and stops on SIGTERM.
- The empty `/etc/resolv.conf` survives the build.
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
- Web-search queries are found in real reply streams (Codex in particular).
- The image's certificate store verifies the vendors' certificates through a
  real Squid `CONNECT`.

### Codex subscription login

- The host-side renewal: endpoint, request body, reply shape, and that the
  rotated refresh token is written back to the keyring. Not exercised at all.
- The dummy token the Codex CLI is given carries only an expiry and a dummy
  account id; the real CLI may want more claims.

### Export

- Real gitleaks: that the installed version accepts `--ignore-gitleaks-allow`
  and a bare repository, and that the extra rule in `policy/gitleaks.toml`
  loads.
- git 2.40 or newer: the attribute handling on a bare repository.
- BSD `awk`, `cut`, `tr` and bash 3.2 on macOS.

### Git relay

- GitHub or GitLab accepting the relay's push bodies and its Basic
  authentication header, through a real Squid.
- The agent's git reaching `http://gitrelay:8081/` through `/etc/hosts` and
  `NO_PROXY`.

### Agents

- Claude Code with `--auto`: whether the one-time "bypass permissions" dialog
  appears.
- Codex's interface in API-key mode, and its trusted-directory entry.
- OpenCode's interface with `--auto`.

### Extras

Nothing in `extras/` has been loaded or started: the auditd rules, the Falco
rules, the Tetragon policy, the Lima template and the Multipass file. Their
field names and package names are from memory.

## The sidecar spike (requirement 19)

Done in Phase A against a mock API and a proxy that refuses everything, with
dummy tokens. All three CLIs can be run with only a dummy credential and a base
URL pointing at a sidecar; `agents/<name>/compat.md` records the settings each
needs. What the spike could not show, and step 6 to 8 above will: that the
vendors accept the requests once the sidecar puts a real credential on them.
