#!/usr/bin/env bash
# The commands that act on a running session: shell, logs, verify, allow,
# deny, export, push, pr and destroy, against the fake Podman.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup
make_root
log="$FAKE_PODMAN_LOG"
tab="$(printf '\t')"
esc="$(printf '\033')"
bel="$(printf '\007')"
export SANDBOX_TEST_ANTHROPIC_KEY="sk-ant-test-0123456789"

# The repository the session starts from says its origin is on github.com.
# git is told (in the test's own configuration) to read and write a local
# bare repository instead, so `push` can really push.
git init --quiet --bare "$T/remote.git"
make_repo "$T/src"
git -C "$T/src" remote add origin https://github.com/example/project.git
git config --global url."$T/remote.git".insteadOf https://github.com/example/project.git

"$ROOT/sandbox" run "$T/src" --branch agent/test </dev/null >/dev/null 2>&1 || fail "run failed"
s="$(only_session)"
dir="$SANDBOX_STATE_DIR/$s"
base="$(git -C "$T/src" rev-parse HEAD)"
check "state records the origin of a local repository" grep -qx "ORIGIN_URL=https://github.com/example/project.git" "$dir/state"

# called <description> <pattern>: a podman call matching the pattern was made.
called() { if grep -qE -- "$2" "$log"; then pass "$1"; else fail "$1: no call matching $2"; fi; }
# clean <description> <text>: no escape or bell character survived.
clean() {
  case "$2" in
    *"$esc"*|*"$bel"*) fail "$1: a control character reached the terminal" ;;
    *) pass "$1" ;;
  esac
}

# --- shell, logs, verify ---------------------------------------------------------
: > "$log"
"$ROOT/sandbox" shell </dev/null >/dev/null 2>&1 || fail "shell failed"
called "shell enters the agent container" "^exec${tab}-i${tab}.*$s-agent${tab}bash$"
out="$("$ROOT/sandbox" logs proxy 2>&1)"
called "logs proxy reads the proxy's log" "^logs${tab}$s-proxy$"
clean  "logs are filtered  [B32]" "$out"
case "$out" in *"first line"*"red"*"clipboard"*) pass "the text of the log is kept" ;; *) fail "log text lost: $out" ;; esac
"$ROOT/sandbox" logs sidecar >/dev/null 2>&1
called "logs sidecar reads the credential sidecar's log" "^logs${tab}$s-credsidecar$"
says   "logs rejects an unknown name" "usage: ./sandbox logs" "$ROOT/sandbox" logs keeper
says   "logs service without a service says so" "has no sibling service" "$ROOT/sandbox" logs service
out="$("$ROOT/sandbox" verify --quick 2>&1)"
clean  "verify output is filtered  [B32]" "$out"
check  "verify --quick is passed on with the session" grep -qx -- "--quick $s" "$T/config/verify.calls"
"$ROOT/sandbox" verify >/dev/null 2>&1
check  "verify without --quick runs the full set" grep -qx -- "$s" "$T/config/verify.calls"
FAKE_VERIFY_EXIT=1 refuse "verify fails when a check fails" "$ROOT/sandbox" verify

# --- allow and deny  [logical B20] --------------------------------------------------
: > "$log"
out="$("$ROOT/sandbox" allow docs.example.com --reason "API reference" 2>&1)" || fail "allow failed: $out"
check  "allow records the host and the reason" grep -qx "host${tab}docs.example.com${tab}-${tab}API reference" "$T/config/allowlist.local"
check  "allow re-renders the session's lists" grep -qx docs.example.com "$dir/proxy/agent.domains"
called "allow tells Squid to re-read its lists" "^exec${tab}$s-proxy${tab}squid${tab}-k${tab}reconfigure${tab}-f${tab}/var/run/squid/squid.conf$"
if grep -qE "^(create|start|stop|build|rm|kill)${tab}" "$log"; then fail "allow rebuilt or restarted something"; else pass "allow rebuilds and restarts nothing"; fi

refuse "allow without a reason is refused" "$ROOT/sandbox" allow more.example.com
says   "allow without a reason says what is missing" "a reason is required" "$ROOT/sandbox" allow more.example.com
refuse "a never-allow host is refused" "$ROOT/sandbox" allow pastebin.com --reason "quick paste"
refuse "a URL given as a host is refused" "$ROOT/sandbox" allow https://x.example.com/ --reason "x"
check  "a refused entry is not recorded" test "$(wc -l < "$T/config/allowlist.local")" -eq 1

says "an upload-capable host gets a warning" "accepts uploads" "$ROOT/sandbox" allow github.com --reason "clone a dependency"
says "an https URL: only the host name is enforced" "only the host name is enforced" "$ROOT/sandbox" allow --url https://files.example.com/pkg/ --reason "tarballs"
says "an https URL: path rules are for plaintext only" "plaintext http:// URLs only" "$ROOT/sandbox" allow --url https://files2.example.com/pkg/ --reason "tarballs"
check "an https URL is recorded as a url entry" grep -q "^url${tab}https://files.example.com/pkg/${tab}" "$T/config/allowlist.local"
"$ROOT/sandbox" allow db.example.com:5432 --reason "staging database" --until 2099-12-31 >/dev/null 2>&1
check "host:port is recorded with its end date" grep -qx "hostport${tab}db.example.com:5432${tab}2099-12-31${tab}staging database" "$T/config/allowlist.local"
"$ROOT/sandbox" allow --preset github-downloads --reason "release tarballs" >/dev/null 2>&1
check "a preset is recorded" grep -q "^preset${tab}github-downloads${tab}" "$T/config/allowlist.local"

: > "$log"
"$ROOT/sandbox" deny docs.example.com >/dev/null 2>&1 || fail "deny failed"
if grep -q "docs.example.com" "$T/config/allowlist.local" "$dir/proxy/agent.domains"; then fail "deny left the entry"; else pass "deny removes the entry and re-renders"; fi
called "deny tells Squid to re-read its lists" "^exec${tab}$s-proxy${tab}squid${tab}-k${tab}reconfigure"
refuse "deny of something never allowed fails" "$ROOT/sandbox" deny never.example.com

# --- export  [logical B27] ---------------------------------------------------------
# What the agent "did": one commit on the session branch, as a bundle.
git clone --quiet "$T/src" "$T/work"
git -C "$T/work" checkout --quiet -b agent/test
printf 'more\n' >> "$T/work/README.md"
git -C "$T/work" commit --quiet -am "agent's change"
tip="$(git -C "$T/work" rev-parse HEAD)"
git -C "$T/work" bundle create --quiet "$T/agent.bundle" agent/test

says "push before any export is refused" "nothing has been exported" "$ROOT/sandbox" push

: > "$log"
refuse "export fails when the helper writes nothing" "$ROOT/sandbox" export --out "$T/exported"
check  "a failed export leaves no bundle" test -z "$(find "$T" -name ".$s.bundle")"

# An endless stream: the launcher must stop reading at the workspace cap.
: > "$log"
out="$(FAKE_PODMAN_BUNDLE_BYTES=$((64 * 1024 * 1024)) "$ROOT/sandbox" export --out "$T/exported" 2>&1)" && fail "an oversized stream was exported"
case "$out" in *"larger than the workspace"*) pass "a stream past the workspace cap is refused" ;; *) fail "oversize: $out" ;; esac
check  "reading stopped at the cap, before the stream ended" test ! -e "$FAKE_PODMAN_STATE/bundle-read-to-the-end"
check  "nothing of the oversized stream is kept" test -z "$(find "$T" -name ".$s.bundle")"
check  "export.sh is not run on a refused stream" test ! -e "$T/config/export.calls"

: > "$log"
status=0
out="$(FAKE_PODMAN_BUNDLE="$T/agent.bundle" "$ROOT/sandbox" export --out "$T/exported" 2>&1)" || status=$?
check  "export succeeds" test "$status" -eq 0
called "the bundle is written by a fresh container with no network" "^run${tab}--name${tab}$s-export${tab}.*--network${tab}none.*sandbox-bundle${tab}agent/test$"
called "the helper is removed when it exits" "^run${tab}.*--rm${tab}"
called "the helper sees the workspace read-only" "^run${tab}.*source=$s-workspace,destination=/workspace,ro"
check  "the bundle is removed once export.sh has read it" test ! -e "$T/exported/.$s.bundle"
check  "no bundle is held in the memory-backed session directory" test -z "$(find "$dir" -name '*.bundle')"
check  "export.sh gets bundle, out dir, session, starting commit, branch and origin" \
  grep -qx "$T/exported/.$s.bundle $T/exported $s $base agent/test https://github.com/example/project.git" "$T/config/export.calls"
check  "the exported repository holds the agent's commit" test "$(git --git-dir="$T/exported/$s/repo.git" rev-parse refs/heads/agent/test)" = "$tip"
clean  "export output is filtered  [B32]" "$out"
case "$out" in *"Read the dependency diff first"*) pass "export says what to read first" ;; *) fail "no reading hint: $out" ;; esac

status=0
FAKE_PODMAN_BUNDLE="$T/agent.bundle" FAKE_EXPORT_EXIT=2 FAKE_EXPORT_SCAN=failed "$ROOT/sandbox" export --out "$T/exported" >/dev/null 2>&1 || status=$?
check  "export returns 2 when export.sh needs a human" test "$status" -eq 2
check  "no bundle is kept after an export that needs a human" test -z "$(find "$T" -name ".$s.bundle")"

# --- push and pr  [closes C1] ---------------------------------------------------------
says   "push refuses when the secret scan did not pass" "secret scan did not pass" "$ROOT/sandbox" push
check  "nothing was pushed" test -z "$(git --git-dir="$T/remote.git" branch --list agent/test)"
FAKE_PODMAN_BUNDLE="$T/agent.bundle" FAKE_EXPORT_EXIT=2 FAKE_EXPORT_HISTORY=rewritten "$ROOT/sandbox" export --out "$T/exported" >/dev/null 2>&1 || true
says   "push refuses when history below the starting commit was rewritten" "rewrote history" "$ROOT/sandbox" push
check  "nothing was pushed then either" test -z "$(git --git-dir="$T/remote.git" branch --list agent/test)"
FAKE_PODMAN_BUNDLE="$T/agent.bundle" "$ROOT/sandbox" export --out "$T/exported" >/dev/null 2>&1

# The exported repository's own config names another remote; push must not
# follow it.
git init --quiet --bare "$T/decoy.git"
git --git-dir="$T/exported/$s/repo.git" config remote.origin.url "$T/decoy.git"
git --git-dir="$T/exported/$s/repo.git" config remote.origin.pushurl "$T/decoy.git"
"$ROOT/sandbox" push >/dev/null 2>&1 || fail "push failed"
check  "push sends the branch to the address recorded at run" test "$(git --git-dir="$T/remote.git" rev-parse refs/heads/agent/test)" = "$tip"
check  "push ignores remotes named in the exported repository" test -z "$(git --git-dir="$T/decoy.git" branch --list)"

git --git-dir="$T/exported/$s/repo.git" update-ref refs/heads/agent/test "$base"
says   "push refuses a repository that is not at the reviewed commit" "not at the commit export reviewed" "$ROOT/sandbox" push
git --git-dir="$T/exported/$s/repo.git" update-ref refs/heads/agent/test "$tip"

# pr with a stand-in `gh` that notes how it was called and where.
printf '#!/bin/sh\n{ pwd; printf "%%s\\n" "$@"; } > "%s/gh.call"\n' "$T" > "$T/bin/gh"
chmod +x "$T/bin/gh"
"$ROOT/sandbox" pr >/dev/null 2>&1 || fail "pr failed"
check  "pr names the repository explicitly" grep -qx "github.com/example/project" "$T/gh.call"
check  "pr names the branch explicitly" grep -qx "agent/test" "$T/gh.call"
check  "pr runs outside any repository" test "$(head -1 "$T/gh.call")" = "$T/exported/$s"
check  "pr takes its title from the exported commit" grep -qx "agent's change" "$T/gh.call"
rm -f "$T/bin/gh"
says   "without gh, pr prints the address to open" "https://github.com/example/project/compare/agent/test?expand=1" "$ROOT/sandbox" pr

# --- a session past its deadline  [logical B26] --------------------------------------
sed "s/^DEADLINE_EPOCH=.*/DEADLINE_EPOCH=1/" "$dir/state" > "$T/state.edit" && cp "$T/state.edit" "$dir/state"
: > "$log"
out="$("$ROOT/sandbox" logs proxy 2>&1 || true)"
case "$out" in *"reached its time limit"*"still holds its workspace"*) pass "every command names sessions past their deadline" ;; *) fail "no deadline notice: $out" ;; esac
called "the expired session's agent is stopped" "^stop${tab}$s-agent$"
called "and its proxy" "^stop${tab}$s-proxy$"
if grep -q "^stop${tab}$s-keeper" "$log"; then fail "the keeper was stopped"; else pass "the keeper is left holding the workspace"; fi
says   "shell on an ended session points at export" "The work is still there" "$ROOT/sandbox" shell
FAKE_PODMAN_BUNDLE="$T/agent.bundle" check "an ended session can still be exported" "$ROOT/sandbox" export --out "$T/exported"

# --- destroy  [logical B31, closes L1] ------------------------------------------------
: > "$log"
"$ROOT/sandbox" destroy >/dev/null 2>&1 || fail "destroy failed"
before "containers are removed before networks" "^rm${tab}" "^network${tab}rm"
before "networks are removed before the volume" "^network${tab}rm" "^volume${tab}rm"
called "objects are found by the session label" "^ps${tab}-aq${tab}--filter${tab}label=agent-sandbox.session=$s$"
left="$(find "$SANDBOX_STATE_DIR" -mindepth 1; find "$FAKE_PODMAN_STATE/containers" "$FAKE_PODMAN_STATE/networks" "$FAKE_PODMAN_STATE/volumes" -type f)"
if [ -z "$left" ]; then pass "destroy leaves nothing in the state directory or in Podman"; else fail "left after destroy: $left"; fi
check  "the exported repository is yours and stays" test -d "$T/exported/$s/repo.git"
says   "after destroy there is no session" "there is no session" "$ROOT/sandbox" destroy

finish
