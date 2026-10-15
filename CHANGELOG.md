# Changelog

## Unreleased

- **`upgrade` moves the CLI pins.** It rebuilt the images from the version
  and hashes pinned in each `agents/<agent>/install.sh`, so a newer Claude
  Code or Codex never arrived until someone read three `npm view` outputs
  into that file by hand. `./sandbox upgrade` now runs `scripts/pin-clis.sh`
  first: for each agent whose image exists here it asks the registry which
  version is `latest`, reads the sha512 integrity of every package the
  install unpacks at that version, rewrites the pin, and then rebuilds. The
  build still verifies each tarball against what was written, and the script
  refuses (changing nothing) when the registry cannot be asked, answers
  something that is not a version or a sha512, or the wrapper package has
  gained ordinary dependencies that the install would never fetch.
  `--keep-clis` rebuilds from the pins as they are.
- **`export --commit` commits on the session branch or not at all.** It
  committed on whatever HEAD named, while export bundles the session branch
  only: an agent that had switched branches or detached HEAD would have had
  its work committed where export never looks, and `destroy` would then have
  removed the only copy. It now checks HEAD first and refuses, with the
  recovery steps, when it is not the session branch. Found by review.
- **`resume` says that the request budget starts over.** The sidecar counts
  requests in memory, so starting it again (after a time limit, a reboot, or
  the agent ending its container) resets the count to zero. That was so but
  unsaid; `resume` now says it, and [09](docs/09-sessions.md) and the threat
  model (B24) state the contract: a cap per start of the sidecar, with the
  account's spend limit as the cap that always holds.
- **Tests.** The launcher tests now run from outside the checkout, so a git
  identity set in this repository's own `.git/config` no longer overrides
  the test identity (two identity checks in `resume.sh` failed in such a
  checkout).

- **Sessions have no time limit unless you give them one.** `TTL` defaults to
  `none`, and `--ttl 4h` (or `TTL=4h` in the settings file) is what sets a
  limit. With none, every container is created with Podman's `--timeout 0`
  (its own "never"), the state records no deadline, and `verify` reports B26
  as not in force rather than failing it. The threat model says what that
  means: an agent left alone keeps its containers and its share of the host
  until `destroy`, and spends requests up to the budget.
- **`resume`: back into a session.** After the CLI exited, after a time
  limit, after the agent ended its own container, or after a reboot: `resume`
  starts whatever of the session is stopped, in the order `run` did, hands the
  sidecar the credential again (and a relay its token), and attaches. Nothing
  is created and no memory check is repeated, so it also answers "the session
  may use up to 6.6 GB and this host has less" when all you wanted was to get
  back in. `resume -- --continue` lets Claude Code pick up its conversation
  while its container lives. A workspace that was held in memory is refused
  after a reboot, since it is gone.
- **The session records outlive a reboot.** They move from `$XDG_RUNTIME_DIR`
  (emptied at boot) to `~/.local/state/agent-sandbox`. Nothing in them is a
  secret. A session on the disk store is therefore still a session after a
  reboot, not an orphaned directory. Sessions started by 2.0.0 are not found
  after a reboot; [07](docs/07-troubleshooting.md#getting-back-into-a-session)
  says how to read their workspaces.
- **The keyring is unlocked at the prompt.** After a reboot the keyring is
  locked, and `run` went straight to asking for the credential, with the
  unlock script named in a warning. At a terminal, `run`, `resume` and `login`
  now run `scripts/keyring-unlock.py` themselves, so you type the keyring's
  password and they go on (three tries at a wrong one). `login` also creates
  the keyring that way when there is none. Without a terminal nothing changes.
- **Uncommitted work is named, and `export --commit` brings it out.** The
  export helper says how many changes in the workspace are not in the bundle,
  so an agent that stopped before committing no longer looks like one that
  did nothing; `export --commit` commits them first, in the agent's container
  under your git identity. `export`'s closing lines say that nothing has
  reached the repository yet and that `push` is what sends the branch there.
- **Tests.** `make test` ran only one of the eleven launcher suites: the
  harness took `tests/launcher/run.sh` (the test of `run`) for a directory
  runner. It is now `start.sh`, and all of them run; one check in
  `session.sh` is skipped when a real `gh` is installed. New: `resume.sh`,
  the locked-keyring prompts at a pseudo-terminal in `credentials.sh`.

- **`run --git-token` from a path with an `https://` origin.** The check
  looked at the address given to `run`, so a path was always refused, though
  the token is never used for the clone: it is for `push`, `pr` and the
  relay, which go to the session's origin. It now looks at that origin (the
  address itself, or a path's `remote.origin.url`) and holds the token for
  its host. A session started from an earlier export, with the real
  repository added as its origin, can now push with a session token instead
  of a credential kept on the host. A path with no origin, or an `ssh`
  origin, is still refused, with a message saying why.
- **Docs: the quickstart starts from a brand-new VM.** Rewritten for
  someone who has never set up a Linux host: Debian 13, Ubuntu 24.04 or
  Fedora 41, every command written out with which machine and which account
  it is typed on, what each block should print, the account, cgroup
  delegation, the disk store (with SELinux labelling on Fedora), gitleaks
  with its checksum checked, Ubuntu's crash reporter, the keyring, both
  credentials, both ways to get the work back to GitHub, tmux, reboots and
  updates. The Ubuntu and Fedora commands have not been run by the authors,
  and the page says so.
- **Docs: sessions.** New [09 — Sessions](docs/09-sessions.md): one
  repository after another, several side by side (`SANDBOX_SESSION`, what
  they share), another agent on the same repository, and two ways to have it
  carry on from the first agent's work with `--branch`: through the remote,
  or straight from the export with nothing pushed. The README, the
  quickstart, [05](docs/05-agents-and-toolchains.md) and
  [07](docs/07-troubleshooting.md) point to it. The second way's import (an
  existing branch carried on, `origin` deciding where `push` goes) was
  checked against the real `import_repository`; a whole run with two agents
  has not been done.
- **Docs: fetching an export to a workstation.** The old quickstart's
  `git push origin agent/<session>` after a plain `git fetch` named a branch
  the fetch never made; it now pushes `FETCH_HEAD`.
- **`login` on a headless Linux host.** The account the quickstart recommends
  (no password, reached over SSH) has no keyring, and gnome-keyring can create
  or unlock one only through a graphical prompt, so `./sandbox login` ended in
  `secret-tool: Cannot create an item in a locked collection`.
  `gnome-keyring-daemon --unlock`, the usual advice, returns 0 and changes
  nothing against the systemd-managed daemon of gnome-keyring 48. New
  `scripts/keyring-unlock.py` creates or unlocks the keyring over D-Bus with a
  password you choose. `login` now checks the keyring before asking for the
  token and names that fix; `doctor` reports a missing or locked keyring; `run`
  says why it is asking for the credential. Tests use a stand-in `busctl`.
- **A git token for one session: `run --git-token`.** For a private
  repository the host needs a git credential, and a breakout lands in the host
  account; a personal SSH key there is a larger asset than the inference-only
  model token the design goes to such lengths to isolate. `--git-token` asks
  for a token scoped to the one repository and gives it to git's credential
  cache: held in memory, in the session directory, for the session's time
  limit; used by the clone, `push` and `pr` (and the relay, with
  `--git-relay`) instead of anything else on the host; forgotten at
  `destroy`. Never a file, never in a container.
- **Docs: what the host holds.** The README, the quickstart and
  [03 — Credentials](docs/03-credentials.md#git-credentials) now say what a
  breakout would find on the host, rank the ways to give it a git credential
  (none, a session token, a deploy key, never a personal key), show the
  zero-credential workflow over the SSH link you already have, and warn
  against SSH agent forwarding. The keyring section says plainly what the
  keyring does and does not protect against, and that typing the token at
  each `run` is a sound alternative on a headless host.

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
