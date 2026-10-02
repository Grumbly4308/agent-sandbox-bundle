#!/usr/bin/env bash
# `run --git-relay`: the optional container that lets the agent push the
# session branch by itself. What the launcher creates for it, and where its
# git token goes.  [logical B30]
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup
make_root
log="$FAKE_PODMAN_LOG"
tab="$(printf '\t')"
export SANDBOX_TEST_ANTHROPIC_KEY="sk-ant-test-0123456789"
RELAY_TOKEN="github_pat_RELAY-TOKEN_0123456789"

make_repo "$T/src"
says   "a repository with no https address cannot use the relay" "needs an https:// repository address" \
  bash -c "printf '%s\n' '$RELAY_TOKEN' | '$ROOT/sandbox' run '$T/src' --git-relay"
check  "nothing was made" test -z "$(only_session)"

git -C "$T/src" remote add origin https://github.com/example/project.git
says   "without a token the relay is refused" "needs a git token" "$ROOT/sandbox" run "$T/src" --git-relay </dev/null
says   "something that is not a token is refused" "does not look like a token" \
  bash -c "printf 'not a token\n' | '$ROOT/sandbox' run '$T/src' --git-relay"
check  "still nothing was made" test -z "$(only_session)"

: > "$log"
out="$(printf '%s\n' "$RELAY_TOKEN" | "$ROOT/sandbox" run "$T/src" --git-relay --branch agent/test 2>&1)" || fail "run --git-relay failed: $out"
s="$(only_session)"
relay="$(grep "^create${tab}.*--name${tab}$s-gitrelay" "$log" || true)"

case "$out" in *"does NOT go through export"*) pass "run says that relay pushes skip export" ;; *) fail "no warning about export: $out" ;; esac
check  "the relay container is created" test -n "$relay"
before "the relay is created before the agent" "--name${tab}$s-gitrelay" "^create${tab}--name${tab}$s-agent"
case "$relay" in *"--env${tab}RELAY_UPSTREAM=https://github.com/example/project.git${tab}--env${tab}RELAY_BRANCH=agent/test"*) pass "it is told its one repository and one branch" ;; *) fail "relay create: $relay" ;; esac
case "$relay" in *"--network${tab}$s-sandbox:ip=10.201.0.4"*) pass "it gets the relay's fixed address" ;; *) fail "relay address: $relay" ;; esac
case "$relay" in *"--user${tab}61002:61002"*"--cap-drop=ALL"*|*"--cap-drop=ALL"*"--user${tab}61002:61002"*) pass "it runs as its own user with no capabilities" ;; *) fail "relay hardening: $relay" ;; esac
check  "the proxy is told the relay's address" grep -qE "^create${tab}--name${tab}$s-proxy${tab}.*SANDBOX_RELAY_IP=10.201.0.4" "$log"
check  "the agent finds the relay by /etc/hosts" grep -qE "^create${tab}--name${tab}$s-agent${tab}.*--add-host${tab}gitrelay:10.201.0.4" "$log"
check  "the agent reaches the relay directly, not through the proxy" grep -qE "^create${tab}--name${tab}$s-agent${tab}.*NO_PROXY=[^${tab}]*,gitrelay,10.201.0.4" "$log"
check  "the proxy's relay list holds the one git host" grep -qx "github.com" "$SANDBOX_STATE_DIR/$s/proxy/relay.domains"
check  "state records that the relay is on" grep -qx "GIT_RELAY=1" "$SANDBOX_STATE_DIR/$s/state"
check  "the agent's clone is given the relay as its remote" grep -qE "^exec${tab}.*$s-agent${tab}sandbox-import${tab}agent/test${tab}http://gitrelay:8081/repo.git$" "$log"
before "the relay is waited for before its token goes in" "^exec${tab}$s-gitrelay${tab}gitrelay-healthcheck" "relay-load"

loaded="$(find "$FAKE_PODMAN_STATE/stdin" -name "*.$s-gitrelay.relay-load")"
check  "the token reaches the relay on stdin, as one JSON object" test "$(cat "$loaded")" = "{\"token\":\"$RELAY_TOKEN\",\"username\":\"x-access-token\"}"
if grep -qF "$RELAY_TOKEN" "$log"; then fail "the git token is on a podman command line"; else pass "the git token is on no podman command line"; fi
if grep -rqF "$RELAY_TOKEN" "$SANDBOX_STATE_DIR" "$SANDBOX_CONFIG_DIR"; then fail "the git token is in a file"; else pass "the git token is in no file"; fi
if grep -rqF "$RELAY_TOKEN" "$FAKE_PODMAN_STATE/stdin" --exclude="*.relay-load"; then fail "the git token went to another container"; else pass "the git token went to no other container"; fi
case "$out" in *"$RELAY_TOKEN"*) fail "the git token was printed" ;; *) pass "the git token is not printed" ;; esac
"$ROOT/sandbox" logs relay >/dev/null 2>&1
check  "logs relay reads the relay's log" grep -qE "^logs${tab}$s-gitrelay$" "$log"

# Without --git-relay there is no relay and no address for one.
"$ROOT/sandbox" destroy >/dev/null 2>&1
: > "$log"
"$ROOT/sandbox" run "$T/src" </dev/null >/dev/null 2>&1 || fail "plain run failed"
if grep -q "gitrelay" "$log"; then fail "a relay appeared without --git-relay"; else pass "no relay unless asked for"; fi
check  "and the clone is given no remote" grep -qE "sandbox-import${tab}[^${tab}]+$" "$log"
says  "logs relay without a relay says so" "has no git relay" "$ROOT/sandbox" logs relay
check "the proxy then has no relay address" grep -qE "^create${tab}--name${tab}asb-src-[0-9a-f]{6}-proxy${tab}.*SANDBOX_RELAY_IP=${tab}" "$log"
"$ROOT/sandbox" destroy >/dev/null 2>&1

finish
