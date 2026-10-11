# 08 — What has been verified

Version 2.0.0 was written on a machine with no container runtime, then run
on a real host on 2026-10-09 and 2026-10-10. This page is the current truth:
what that run proved, what was fixed to get there, what was closed without a
check, and what is still unproven. The plan, the tick-box cards, the filled-in
results and every log are kept as they were in
[docs/archive/phase-b/](archive/phase-b/README.md).

## The host

| | |
|---|---|
| OS | Debian 13 (trixie), kernel 6.12 |
| Podman | 5.4.2, rootless, netavark, cgroup v2 with cpu, memory and pids delegated |
| Memory and disk | 8 GB; a 20 GB loop-device store for workspaces |
| Account | `sandboxer`, no sudo, lingering enabled |
| Tools | git 2.47, Node 20 on the host (Node 22 in the images), gitleaks 8.30.1 (Debian's 8.16 is too old) |

Every other host is unproven: see the last section.

## Proven on that host

`make test` passes. Every `./sandbox verify` after the fixes below ended with
**0 failed**: 72 passed with 13 stated skips for a plain session, 75 with 10
for one with the git relay, 78 with 7 after the relay checks by hand. Every
skip has a stated reason: no SELinux on this host (B05), no gVisor (B06), no
git relay in that session (B30), or a check that needs a session of its own
(B26, B27, B31, B33) and was run there.

| Area | Proven by |
|---|---|
| Every barrier in the register, B01 to B33 | `verify` on live sessions; the deadline test (B26, B27, B31) 10 of 10; the store tests (B33) |
| Image builds and every CLI starting from the unpacked install | Codex, OpenCode, `python` and `full` toolchains (D1); `upgrade` rebuilt all seven images (E10) |
| The proxy: default deny, allow and deny without a restart, presets, DNS by the proxy only, the log | E2, E3, E4 |
| The credential sidecar against the real vendors | Claude Code with a subscription (F1, `B15-token-absent` PASS); Codex with a ChatGPT login (F2, over TLS, real account id) |
| Codex web search, logged | Four real searches and two page opens through the sidecar, every query in its log, each charged to the budget (F2 web search) |
| Export: bundle, attribution, secret scan, "runs later", hostile `.git` | E5, the deadline test with planted hostile content, and the static `tests/export/` |
| Push and the pull request link | E6, with a fine-grained token in the host's credential helper; the sandbox never saw it |
| The git relay: one branch accepted, other branches and tags refused | E8 (`B30-other-branch`, `B30-tag`, `B15-push` PASS; `B30-force-push` is a stated SKIP) |
| Sibling services | Postgres 16 and Redis 7 beside the agent, both reachable by address, read-only roots (E7) |
| The disk store's share watch and a full store; a workspace held in memory | E9 |
| The keyring through `secret-tool`, on a server with none running | F0, with a keyring started by hand |

## Fixed during the run

Each is written up in [results.md](archive/phase-b/results.md). None weakened
a check.

- The proxy needs a writable `/dev/shm`: Squid keeps shared tables there.
- The `full` toolchain pulled in a setuid dbus helper; it is removed.
- gitleaks before 8.18 cannot be told to ignore the tree's own exceptions; `export` runs no scan with one and `doctor` says so.
- The in-container probe's answer had to be kept to one line for Codex's streamed replies.
- Codex needs the real account id in its dummy login, and a sidecar that speaks TLS; `run` makes a certificate per session.
- `run` rebuilds an image whose build inputs changed, not only a missing one.
- `verify`'s own second sidecar stays on plain HTTP whatever the session speaks.
- `B33-store-full` showed too few lines of `dd`'s answer; `doctor` warns of a sparse store file.
- Codex 0.162.1 declares its tools in an `additional_tools` input item, which the sidecar did not inspect: B23's lists never saw a Codex tool. Fixed, with tests.
- Codex's ChatGPT models search through a request of the CLI's own, not the hosted tool; the provider is marked for it and the sidecar forwards and logs that path.

## Closed without a check

Decided on 2026-10-10. They are not failures; they were not run and will
not be, so nothing is claimed for them.

- The automated cycle with a real Anthropic API key (D2), the agent's task in a live session (E1) and OpenCode (F3): the API-key path has run against a mock only. The Claude API-key sidecar path did reach the vendor once, with a dummy key, and was refused as expected.
- A commit made by the agent itself and pushed (E6 was run with a commit made by hand inside the container, so the push path is proven and the agent's own commit is not).
- The renewal of the Codex login on the host, about ten days after `codex login`.

## Still unproven

- **Hosted web search in a reply.** The sidecar's scanner for the hosted `web_search` tool, whose query comes back in the model's reply: no ChatGPT model uses it, and Claude's streamed `server_tool_use` form has not been seen against the real API.
- **Whether `CODEX_CA_CERTIFICATE` adds to or replaces Codex's trusted roots.** What the agent can reach is decided by the proxy either way.
- **Claude Code with `--auto`:** whether its one-time "bypass permissions" dialog appears. Codex's interface in API-key mode. OpenCode's interface.
- **Other hosts.** Fedora with SELinux (B05 is a stated SKIP on Debian and Ubuntu); macOS with `podman machine`, where everything is unproven, the `security` keyring tool in particular; gVisor (`SANDBOX_RUNTIME_CLASS=runsc`); that Podman 4.4 is really the oldest that works (5.4.2 is the only version run).
- **`resume`, and sessions that outlive a reboot.** Both are covered by the launcher tests against the stand-in Podman (what is started, in which order, what is handed in again, what is refused), and `--ttl none` by the topology test. A real cycle (reboot, `resume`, work, `export`) has not been run on the host.
- **The extras.** Nothing under `extras/` has been loaded: the auditd rules, the Falco rules, the Tetragon policy, the Lima template, the Multipass file.
- **The CI Podman job** (`workflow_dispatch`, needs the key as a repository secret) has not been run.

## Running it again

The tick-box card in the archive is still the way to do it:
[test-card.md](archive/phase-b/test-card.md), with
[plan.md](archive/phase-b/plan.md) behind it and
[test-card-subscriptions.md](archive/phase-b/test-card-subscriptions.md) for
the subscription logins. `tests/phase-b/images.sh` builds and checks every
image; `tests/phase-b/cycle.sh` runs the full cycle with a real key. Record
what you see in a new results file beside the old one, and keep the logs.
