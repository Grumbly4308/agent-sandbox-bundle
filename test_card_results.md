# Test card results: first run against Podman

Host: Debian 13 (kernel 6.12), Podman 5.4.2 rootless, 8 GB memory, a 20 GB
loop-device store. Run as `sandboxer` on 2026-10-09 and 2026-10-10 from the
[test card](test_card.md). Logs are in [phase-b-logs/](phase-b-logs/) (copied from `~/phase-b-logs/` on that host); a
`-N` suffix is a re-run after a fix.

Everything that failed was fixed on `build/phase-a` in the commits after
e553315 ("Pin the base and service images"), and the step was run again
until it passed. No check was weakened; three of the fixes are to how a
check reports, and the sidecar and the store were right all along.

## The table

| Step | Result | Notes |
|---|---|---|
| B1 packages | pass | Debian 13's `gitleaks` is 8.16, too old for `export`; 8.30.1 installed for the user at `~/.local/bin` (B1 in the card now says so) |
| B2 account | pass | |
| B3 disk store | pass | the store's file was sparse (see E9) |
| B4 log in as that account | pass | |
| B5 code | pass | |
| C2 static tests | pass | |
| C3 pin images | pass | |
| C4 system-call filter identical | pass | checksum matches |
| C5 settings | pass | |
| C6 doctor | pass | |
| D1 images | pass | after three fixes, below |
| D2 cycle and deadline test | not finished | every `verify` 0 failed, deadline test 10 of 10; the agent's task could not run: no real API key was available |
| E1 start a session | partial | start-up and 72 barrier checks as described; Claude Code starts with no login prompt; the task could not run (no key) |
| E2 inside the container | pass | no variable named like a key or token exists at all, which is stricter than the card asks |
| E3 allow and deny | pass | |
| E4 logs | pass | the key is in no log |
| E5 verify, export, destroy | pass | export holds only the fixture commit (no agent task) |
| E6 push and pull request | not run | needs a scratch repository |
| E7 services | pass | |
| E8 git relay | not run | needs a scratch repository and a token |
| E9 store limits; workspace in memory | pass | after the store-full check fix |
| E10 upgrade | pass | all seven images rebuilt, versions printed |
| F0 keyring | fail | no keyring on this host over SSH; see [test_card_subscriptions.md](test_card_subscriptions.md) |
| F1 Claude subscription | to do by hand | [test_card_subscriptions.md](test_card_subscriptions.md) |
| F2 Codex subscription | to do by hand | [test_card_subscriptions.md](test_card_subscriptions.md) |
| F3 OpenCode | not run | needs an API key |
| G optional | not run | |

## What failed, and the fix

**D1, every combination: the proxy never came up.** Squid 6.9 died at start
with `shm_open ... Read-only file system`: it keeps its collapsed-forwarding
tables in POSIX shared memory, and the proxy container had no writable
`/dev/shm`. Fix: a 16 MB tmpfs on `/dev/shm` for the proxy
(`topology.sh`), as the agent and Postgres already had. PHASE-B.md had
listed this as unproven.

**D1, the `full` toolchain: the image failed its own setuid check.**
`chromium` pulls in `dbus-daemon`, whose `dbus-daemon-launch-helper` is
setuid. Fix: the helper is removed after the install
(`images/agent/Containerfile`); there is no system bus in the image.

**D1, Codex: B22-credential-swap, B22-credential-replace and
B25-search-logged failed.** The in-container probe reports
`http <status> <first bytes of the body>` on one line, and the host reads
its last line. Codex's Responses dialect streams its reply, so the excerpt
had line breaks in it and the host read a `data:` line instead of the
status. The sidecar's own log showed the swap and the logged search were
right. Fix: the excerpt is kept to one line (`images/agent/verify-inside.sh`).

**D2 and E5: export's secret scan failed with a usage error.** Debian 13's
gitleaks 8.16 rejects `--ignore-gitleaks-allow` and
`--gitleaks-ignore-path`, the two flags that stop the tree from silencing
the scan. Fix: `export` checks the version (or the help text, since
Debian's build prints no number) and runs no scan with an older gitleaks,
saying what to install; `doctor` warns (`scripts/export.sh`,
`scripts/doctor.sh`). PHASE-B.md had listed this as unproven.

**E9: B33-store-full reported a FAIL although the store filled.** The check
showed the last three lines of a failed `dd`, and `dd` says why on the
first of its four. Fix: all four lines are kept (`scripts/verify.sh`).

**E9: filling the store took 19 GB from the root disk.** The store's
backing file on this host was sparse, so the store read as 20 GB but its
blocks were taken from the host's disk as they were written. The recipes in
the docs use `fallocate`, which does not do this; the host was set up some
other way. Fix: `doctor` warns when a loop device's backing file is mostly
unallocated and prints the `fallocate` that fixes it. The file is now
almost fully allocated after the test, so this host needs nothing.

**Static tests: "no credential in the keyring" failed whenever the test
key was in the environment.** The test now clears
`SANDBOX_TEST_ANTHROPIC_KEY` (`tests/verify/host-fake-podman.sh`).

## Noticed, not changed

- Every `./sandbox allow` and `deny` prints 14 lines of Squid's
  reconfigure warnings. Squid also warns that the session and egress `/24`
  entries in the `to_private` ACL are redundant inside `10.0.0.0/8`. Both
  are cosmetic.
- Inside the agent container, `env | grep -iE 'key|token'` prints only
  `SANDBOX_AUTH=apikey`: no credential variable exists, with or without
  `dummy` in it.
- The sidecar's log line for a model request lists the names of the CLI's
  tools.

## Still to prove

- D2's agent task and E1's, with a real API key from a capped workspace.
- E6 and E8, with a scratch repository and a narrow token.
- F1 and F2 by hand, and F2's renewal about ten days after `codex login`.
- Section G.
