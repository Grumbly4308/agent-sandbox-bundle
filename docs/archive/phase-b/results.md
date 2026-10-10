# Test card results: first run against Podman

> **Archived.** The record of the first run on a real host. The current
> summary is [docs/08-verification.md](../../08-verification.md).

Host: Debian 13 (kernel 6.12), Podman 5.4.2 rootless, 8 GB memory, a 20 GB
loop-device store. Run as `sandboxer` on 2026-10-09 and 2026-10-10 from the
[test card](test-card.md). Logs are in [logs/](logs/) (copied from `~/phase-b-logs/` on that host); a
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
| D2 cycle and deadline test | never tested, closed | every `verify` 0 failed, deadline test 10 of 10; the agent's task never ran: no real API key was available, and this step will not be run (decided 2026-10-10) |
| E1 start a session | complete, not checked | start-up and 72 barrier checks as described; Claude Code starts with no login prompt; the agent's task never ran (no key) and will not be checked (decided 2026-10-10) |
| E2 inside the container | pass | no variable named like a key or token exists at all, which is stricter than the card asks |
| E3 allow and deny | pass | |
| E4 logs | pass | the key is in no log |
| E5 verify, export, destroy | pass | export holds only the fixture commit (no agent task) |
| E6 push and pull request | pass, with one variant | run on 2026-10-10 against a private scratch repository with a fine-grained token; the commit was made by hand inside the container (no model key), not by the agent; export clean (attribution clean, secret scan passed with gitleaks 8.30.1), `push` put `agent/<session>` on the remote, `pr` printed the compare link (no `gh` on the host); logs `E6-run`, `E6-inside`, `E6` |
| E7 services | pass | |
| E8 git relay | pass | run on 2026-10-10; the session branch push was accepted, another branch and a tag were refused by the relay; `verify` 78 passed, 0 failed, 7 skipped, with `B30-other-branch`, `B30-tag` and `B15-push` PASS and `B30-force-push` the stated SKIP; logs `E8-run-2`, `E8-inside`, `E8` |
| E9 store limits; workspace in memory | pass | after the store-full check fix |
| E10 upgrade | pass | all seven images rebuilt, versions printed |
| F0 keyring | pass | after starting a keyring by hand; see [test-card-subscriptions.md](test-card-subscriptions.md) |
| F1 Claude subscription | pass | Claude Code 2.1.283 started with no login prompt and answered; `B15-token-absent` PASS |
| F2 Codex subscription | pass | after four fixes; Codex 0.162.1, a Plus account; 72 passed, 0 failed, 13 skipped; the renewal after ten days is closed as not checked: it will not be run (decided 2026-10-10). Web search run on 2026-10-10: pass after two fixes, below (logs `F2-search-live`, `F2-search-live-sidecar`, `F2-search-verify`) |
| F3 OpenCode | complete, not checked | needs an API key; will not be checked (decided 2026-10-10) |
| G optional | not run | |

## What failed, and the fix

**D1, every combination: the proxy never came up.** Squid 6.9 died at start
with `shm_open ... Read-only file system`: it keeps its collapsed-forwarding
tables in POSIX shared memory, and the proxy container had no writable
`/dev/shm`. Fix: a 16 MB tmpfs on `/dev/shm` for the proxy
(`topology.sh`), as the agent and Postgres already had. plan.md had
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
`scripts/doctor.sh`). plan.md had listed this as unproven.

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

**F2: Codex stopped at start with "selected workspace missing from
routing discovery".** At start the interactive interface looks the account
in its login up in the list `/wham/accounts/check` returns for the real
login, and the dummy `acct-sandbox-dummy` was never in it. `run` now reads
the account id from the stored login and hands it to the agent as
`SANDBOX_CODEX_ACCOUNT_ID`; `launch` writes it into the dummy login. The
id names the account; the tokens stay dummies (`agents/codex/launch`,
`sandbox`). While there, both CLIs were moved to npm's latest (Codex
0.159.3 → 0.162.1, Claude Code 2.1.283 → 2.1.296); the account check turned
out to be in every version from 0.159.3 on.

**F2, second start: "workspace backend must use an HTTPS origin without
credentials".** With the real account id, Codex goes on to "workspace
routing" and refuses a `chatgpt_base_url` in plain HTTP, even for a Plus
account whose routing is `NO_CONSTRAINT`, and no setting turns the routing
off. For a Codex subscription the sidecar now speaks TLS: `run` makes a key
and a certificate for the sidecar's address with `openssl` and pipes them
in (`sidecar-load --tls`), the key never on disk; the sidecar listens only
once it has them and never falls back to plain HTTP; the agent is handed
the certificate alone (`CODEX_CA_CERTIFICATE`). Other agents stay on plain
HTTP. `B23-unknown-path` speaks TLS to such a sidecar and checks the
certificate names its address (`images/credsidecar/`, `sandbox`,
`topology.sh`, `scripts/verify.sh`, `images/agent/verify-inside.sh`).

**F2, third start: the sidecar refused `--tls`.** `run` had reused the
old sidecar image: an image's tag does not change when the files it is
built from do, and only a missing image was built. Every image is now
labelled with a checksum of its build inputs and `run` rebuilds the one
that differs; `run` and the build also warn when a pinned CLI is behind
npm's latest, and never stop on it (`sandbox`).

**F2, fourth start: B22 to B25 skipped, "the second sidecar did not come
up".** `run` exports the TLS switch for the session and `verify.sh`
inherits it, so its own second sidecar, in front of the mock vendor, was
created in TLS mode too and waited for a key nobody pipes it. That sidecar
now stays plain HTTP whatever the session speaks (`scripts/verify.sh`),
and the fake-Podman test has a scenario for it.

**F2 web search, first run: no search was made, and the sidecar logged no
tools.** Codex answered from its shell instead (it tried Google, which the
proxy refused, then the npm registry), and every model request was logged
with `tools_total` 0 although Codex plainly used its shell tool. Codex
0.162.1 declares its tools in an `input` item of type `additional_tools`,
not in the top-level `tools` key the sidecar inspects, so the allow and
deny lists of B23 never saw a Codex tool. Fix: the sidecar checks those
items like the top-level list (`images/credsidecar/sidecar.mjs`), with
tests for a hidden `mcp` and `file_search` tool there (`tests/sidecar/`).
After it, every request lists Codex's 14 tools.

**F2 web search, second run: Codex said it had no web search tool,
whatever `--search` said.** Read from the pinned source: for a model the
vendor's catalogue marks `use_responses_lite` (every ChatGPT model, fetched
through the sidecar on 2026-10-10) Codex never offers the hosted
`web_search` tool. Its web search is a tool of its own, `web.run`, that
POSTs the queries to `<provider>/alpha/search`, and the CLI registers that
tool only for a provider marked `supports_standalone_web_search`, which the
built-in provider is and the sidecar provider was not. Fix: the launcher
marks the provider (`agents/codex/launch`); the sidecar forwards
`/backend-api/codex/alpha/search` (and `/v1/alpha/search` for an API key)
as a model request, counted against the budget, with a dialect that logs
every query, image query, page and find pattern from the request
(`agents/codex/sidecar.json`, `images/credsidecar/sidecar.mjs`,
`tests/sidecar/`). Third run: Codex ran four searches and opened two pages,
answered correctly, and every one of them is in the sidecar's log as
`web_search` entries on that route; `verify` 75 passed, 0 failed.

## Noticed, not changed

- `run --git-relay` reads the relay token with `read -r`, which reports
  failure at end of file when the piped token has no trailing newline, and
  `run` then stops with "needs a git token" although the token was read
  (log `E8-run`). Typed in, or piped with a newline, it works.
- A fine-grained GitHub token with only the Metadata permission is enough for
  the API to show the repository, but git over HTTPS answers 403 "Write
  access to repository not granted" even for a read. Contents read and write
  is what the relay and `push` need.
- `./sandbox pr` runs `push` again before printing the link, so the branch is
  pushed twice; the second push is a no-op.

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

- A commit made by the agent itself through the API-key path. E6 on
  2026-10-10 made the commit by hand inside the container, so the push path is
  proven and the agent's own commit is not. E1's task, D2 and F3 are closed as
  not checked: they will not be run.
- Codex web search through the hosted `web_search` tool, where the query
  comes back in the reply: no ChatGPT model uses it (they all search through
  the CLI's own request, which is proven), so the reply scanner is still
  unproven against the vendor.
- Whether `CODEX_CA_CERTIFICATE` replaces or adds to Codex's trusted roots.
- Section G.
