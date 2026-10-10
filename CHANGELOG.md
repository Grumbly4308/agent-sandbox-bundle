# Changelog

## 2.0.0 — 2026-10-10

A rewrite. The architecture of version 1 is kept: an agent container, a Squid
egress proxy on a network with no route out, no capabilities, no new
privileges, a tightened seccomp profile from a pinned upstream, a read-only
root filesystem, a memory-backed home, a never-allow list, per-vendor
allowlists. Almost everything around it changed.

> **Verified on one real host** (Debian 13, rootless Podman 5.4.2) on
> 2026-10-09 and 2026-10-10: every barrier in the register held, and the
> sidecar was accepted by the real vendors for Claude Code and Codex with
> subscriptions. Ten defects found by that run are fixed in this version.
> [docs/08-verification.md](docs/08-verification.md) has the full account;
> the plan, cards, results and logs are in
> [docs/archive/phase-b/](docs/archive/phase-b/README.md).

### Findings from the review of version 1, and how each is closed

Barrier numbers refer to the register in
[docs/00-threat-model.md](docs/00-threat-model.md).

| Finding | In version 1 | Closed by |
|---|---|---|
| **C1** | Host-side `push` and `pr` ran git inside the workspace the agent wrote; an agent-written `.git/config` could run commands as you. | The host never runs git or any other tool in a tree the agent wrote. Code leaves as a git bundle, unpacked into a repository the host created; one branch, named by the host; no checkout (B27, `scripts/export.sh`). `push` and `pr` act on that repository and push to the address recorded at `run`. |
| **C2** | The workspace and the log directory were host folders mounted writable; the audit log was written by a hook inside the agent. | No host folder is mounted into the agent (B09). The workspace is a per-session volume. Logs are each container's standard output, collected by Podman (B28); the in-agent logging hook is gone. |
| **H1** | A whole-account OAuth session and a deploy key were mounted into every run. | No credential is inside (B15). The model token lives in a separate sidecar container and is piped in on standard input (B22). For Claude it is a one-year inference-only token; for Codex only short-lived access tokens enter a container. Deploy keys are gone; the optional git relay holds a token outside the agent (B30). |
| **H2** | The agent's permission rules sat in its writable home. | Moot. No rules are shipped and none are relied on; see "vapor" in the threat model. |
| **H3** | DNS queries leaked to upstream resolvers; untested. | The agent's network has no name service and the agent has no resolver configuration (B14). The proxy looks up a name only after it has matched the allowlist, and refuses bare IP addresses (B20). `verify` attempts lookups. |
| **H4** | The host was reachable through the network's gateway address; untested. | Rootless Podman keeps the network apart from the host's own, and an internal network with its name service off gets no gateway address (B13). `verify` probes the address a gateway would have. |
| **H5** | No swap cap, no ulimits, the legacy `cpus:` key. | Memory-plus-swap equals the memory limit; ulimits on open files, processes, file size and core dumps; limits passed straight to Podman (B10, B11). The memory limit includes the memory-backed mounts. |
| **H6** | The workspace was a shared host directory. | A volume per session on a dedicated disk store of fixed size, with the session's share watched; held in memory and capped when the host has no store (B08, B33). |
| **M1** | The proxy was not read-only, port 80 was open, there were no body caps, and it restarted itself. | Read-only root, memory mounts for its scratch space, port 80 closed, size caps for plaintext, `--restart=no`, CPU, memory and process limits (`topology.sh`, `images/proxy/`). |
| **M2** | Images and the CLI were not pinned. | Base images by digest in `images/PINS` (a build refuses a placeholder); CLI versions and package hashes in each `agents/<name>/install.sh`; a list of every package and its version in the agent image, where the toolchains and the CLI are. |
| **M3** | The privilege preflight only warned. | `run` refuses as root, against a rootful or remote Podman, and without enforceable limits. No override (B29). |
| **M4** | The `cannot sudo` test passed vacuously; no tests for DNS, swap, symlinks, the gateway or user namespaces. | `verify` attempts each bypass and treats "could not test" as a failure (`scripts/verify.sh`). Symlinks are handled at export, which never checks files out. |
| **M5** | The memory-backed home was mode 0777. | The home directory is created 0700 inside the mount (B08). |
| **M6** | Logs could not be shipped anywhere. | Logs go through Podman's log driver; [docs/04-monitoring.md](docs/04-monitoring.md) shows how to forward them. |
| **L1** | `destroy` left state behind. | Every object carries the session's label and all session files live in one directory; `destroy` removes both (B31). |
| **L2** | No OpenCode. | `agents/opencode/`, API-key mode only. |
| **L4** | gitleaks honoured a configuration written by the agent. | The scan uses the configuration shipped here and ignores allow-lists and ignore files in the tree (B27). |

### Changed from version 1

- **Podman only, driven directly.** Docker, the compose files, the five
  overlays and the podman-compose workarounds are gone. `topology.sh` is the
  one file that decides how each network, volume and container is created.
- **One command set**: `doctor`, `verify`, `run`, `shell`, `allow`, `deny`,
  `export`, `push`, `pr`, `login`, `logs`, `destroy`, `upgrade`. `init`, `new`,
  `go`, `review`, `agent`, `reload`, `status`, `logout`, `up` and `down` are
  gone.
- **No project directory, no `.env`.** `run` takes a repository address or a
  path. Session state lives in a per-session directory that `destroy` removes.
- **Agents are plug-ins** under `agents/<name>/`.
- **No shipped agent configuration**: no `CLAUDE.md`, `AGENTS.md`,
  `settings.json`, `config.toml` rules or hooks. The few compatibility settings
  are listed, with reasons, in each `agents/<name>/compat.md`.
- **`github.com` is off the default allowlist.** Its download-only hosts are a
  one-command preset.
- **A time limit on every session**, enforced by Podman from outside each
  container. The workspace survives it until `destroy`.
- **Sibling services** (`--service postgres:16`) started by the operator.

### Fixed by the first run on a real host

Found on 2026-10-09 and 2026-10-10 and fixed before release; each is written
up in [docs/archive/phase-b/results.md](docs/archive/phase-b/results.md).

- The proxy gets a writable `/dev/shm` (Squid keeps shared tables there).
- The `full` toolchain's setuid dbus helper is removed from the image.
- `export` runs no secret scan with a gitleaks older than 8.18, which cannot
  be told to ignore the tree's own exceptions, and `doctor` says which to install.
- The in-container probe keeps its answer to one line (Codex streams).
- Codex gets the real account id in its dummy login, and a sidecar over TLS
  with a certificate made per session; `verify`'s own second sidecar stays on
  plain HTTP.
- `run` rebuilds an image whose build inputs changed, and says when a pinned
  CLI is behind npm's latest.
- `B33-store-full` keeps all of `dd`'s answer; `doctor` warns of a sparse
  store file.
- The sidecar inspects the tools Codex 0.162 declares in an `additional_tools`
  input item; before, B23's allow and deny lists never saw a Codex tool.
- Codex's ChatGPT models search through a request of the CLI's own
  (`alpha/search`); the provider is marked for it, and the sidecar forwards
  that path, counts it against the budget and logs every query (B25).

### Different from the original brief for version 2

Decided during design review:

- Pure Podman; the launcher calls it directly. There is no `compose.yaml`.
- The kernel memory limit is `--mem` plus the memory-backed mounts.
- The sidecar does not refresh logins. Claude uses a `setup-token`; Codex is
  renewed on the host.
- At the time limit the workspace is kept until `destroy`. `--keep` is gone.
- `/dev/shm` is a fourth writable place (64 MB).
- The dependency diff covers anything that runs later, not only lockfiles and
  manifests.
- The workspace is on disk by default, on a dedicated store whose size is the
  hard cap; each session's share of it is watched, not walled. Held in
  memory, a workspace had to fit in what the host could spare, and real
  repositories often did not. Memory is the fallback when there is no store.
- The git relay cannot refuse a force-push.
- The sidecar is a small Node program, not Caddy or nginx: it has to read
  request bodies to refuse some of them.
- No container is found by name. Podman writes no `/etc/hosts` (its own names
  the host and gives one of its addresses, and only recent versions can be
  told not to), so the proxy, the sidecar, the git relay and sibling services
  are reached by address. This keeps Podman 4.4 and so Ubuntu 24.04 as hosts.
