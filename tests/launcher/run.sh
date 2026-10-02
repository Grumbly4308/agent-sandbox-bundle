#!/usr/bin/env bash
# A whole `./sandbox run` against the fake Podman: what is created, in which
# order, with which arguments, and where the credential does and does not go.
# This proves what the launcher ASKS Podman for. Whether Podman then does it
# is for `./sandbox verify` on a real host.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup
make_root
make_repo "$T/src"

SECRET="sk-ant-test-THE-REAL-SECRET-0123456789"
export SANDBOX_TEST_ANTHROPIC_KEY="$SECRET"
# A key lying about in the operator's shell must never be picked up.
export ANTHROPIC_API_KEY="sk-ant-MUST-NEVER-BE-USED"
# Nor may the host's proxy settings travel into the containers.
export HTTPS_PROXY="http://operator:proxy-password@corp-proxy.example.test:8080"

status=0
out="$("$ROOT/sandbox" run "$T/src" --branch agent/test --service redis:7 --auto </dev/null 2>&1)" || status=$?
[ "$status" -eq 0 ] || fail "run exited $status: $out"
s="$(only_session)"
dir="$SANDBOX_STATE_DIR/$s"
log="$FAKE_PODMAN_LOG"
tab="$(printf '\t')"

# has <description> <file> <fixed text>
has() { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1: '$3' not found"; fi; }
# line_has <description> <line pattern> <fixed text>: the first recorded call
# matching the pattern contains the text.
line_has() {
  local line
  line="$(grep -E -- "$2" "$log" | head -1)"
  case "$line" in
    *"$3"*) pass "$1" ;;
    *) fail "$1: '$3' not in: ${line:-(no such call)}" ;;
  esac
}

if [[ "$s" =~ ^asb-src-[0-9a-f]{6}$ ]]; then pass "session is named asb-<slug>-<6 hex> ($s)"; else fail "session name: '$s'"; fi

# --- order ---------------------------------------------------------------------
before "preflight comes before anything is created"   "^info${tab}"                         "^network${tab}create"
before "networks are created before containers"       "^network${tab}create"                "^create${tab}"
before "the sandbox network comes first"              "^network${tab}create.*$s-sandbox$"   "^network${tab}create.*$s-egress$"
before "the volume is created before containers"      "^volume${tab}create"                 "^create${tab}"
before "the keeper is created before the agent"       "^create${tab}--name${tab}$s-keeper"  "^create${tab}--name${tab}$s-agent"
before "the proxy is created before the agent"        "^create${tab}--name${tab}$s-proxy"   "^create${tab}--name${tab}$s-agent"
before "the sidecar is created before the agent"      "^create${tab}--name${tab}$s-credsidecar" "^create${tab}--name${tab}$s-agent"
before "the service is created before the agent"      "^create${tab}--name${tab}$s-svc-redis" "^create${tab}--name${tab}$s-agent"
before "everything is created before anything starts" "^create${tab}--name${tab}$s-agent"   "^start${tab}"
before "the keeper starts first"                      "^start${tab}$s-keeper"               "^start${tab}$s-proxy"
before "the agent starts last"                        "^start${tab}$s-svc-redis"            "^start${tab}$s-agent"
before "the proxy is waited for before the credential goes in" "^exec${tab}$s-proxy${tab}squid${tab}-k${tab}check" "sidecar-load"
before "the sidecar is waited for before the credential goes in" "^exec${tab}$s-credsidecar${tab}sidecar-healthcheck" "sidecar-load"
before "the service is waited for"                    "^exec${tab}$s-svc-redis${tab}redis-cli${tab}-h${tab}127.0.0.1${tab}ping" "sandbox-launch"
before "the credential goes in before the code"       "sidecar-load"                        "sandbox-import"
before "the code goes in before the CLI starts"       "sandbox-import"                      "sandbox-launch"
has    "the barrier checks ran, quick, on this session" "$T/config/verify.calls" "--quick $s"

# --- networks and volume ---------------------------------------------------------
line_has "the agent's network is internal"            "^network${tab}create.*$s-sandbox$" "--internal"
line_has "the agent's network has no name service"    "^network${tab}create.*$s-sandbox$" "--disable-dns"
line_has "the agent's network is the first free /24"  "^network${tab}create.*$s-sandbox$" "--subnet${tab}10.201.0.0/24"
line_has "the egress network is in its own range"     "^network${tab}create.*$s-egress$"  "--subnet${tab}10.202.0.0/24"
if grep -E "^network${tab}create.*$s-egress$" "$log" | grep -q -- --internal; then fail "the egress network is internal"; else pass "only the agent's network is internal"; fi
line_has "the workspace is held in memory, capped"    "^volume${tab}create" "o=size=33554432,nosuid,nodev,mode=1777"
line_has "every object carries the session label"     "^volume${tab}create" "--label${tab}agent-sandbox.session=$s"

# --- the agent container: topology.sh's arguments arrive unchanged ----------------
agent="^create${tab}--name${tab}$s-agent"
# 64m processes + 16m /tmp + 16m home + 64m /dev/shm + 32m workspace
line_has "memory limit is processes plus every memory-backed mount" "$agent" "--memory${tab}201326592${tab}--memory-swap${tab}201326592"
line_has "no capabilities"                 "$agent" "--cap-drop=ALL"
line_has "no new privileges"               "$agent" "--security-opt=no-new-privileges"
line_has "read-only root"                  "$agent" "--read-only${tab}--read-only-tmpfs=false"
line_has "fixed non-root user"             "$agent" "--user${tab}61000:61000"
line_has "the seccomp profile of this copy" "$agent" "seccomp=$ROOT/seccomp/agent-seccomp.json"
line_has "process limit"                   "$agent" "--pids-limit${tab}128"
line_has "deadline from --ttl"             "$agent" "--timeout${tab}3600"
line_has "largest file is the workspace cap" "$agent" "fsize=33554432:33554432"
line_has "fixed address on the internal network" "$agent" "--network${tab}$s-sandbox:ip=10.201.0.10"
line_has "no resolver"                     "$agent" "--dns=none"
line_has "proxy and sidecar by /etc/hosts" "$agent" "--add-host${tab}proxy:10.201.0.2${tab}--add-host${tab}sidecar:10.201.0.3"
line_has "the service by /etc/hosts"       "$agent" "--add-host${tab}redis:10.201.0.20"
line_has "the service is reached directly" "$agent" "NO_PROXY=localhost,127.0.0.1,sidecar,10.201.0.3,redis,10.201.0.20"
line_has "the agent plug-in's env file"    "$agent" "--env-file${tab}$ROOT/agents/claude/env"
line_has "the image for this agent and toolchain" "$agent" "localhost/agent-sandbox/agent-claude:node-$(cat "$REPO/VERSION")${tab}sandbox-idle"
if grep -E "^create" "$log" | grep -qE -- "--privileged|--network${tab}host|--pid=host|podman.sock|--cap-add"; then
  fail "a container was given a privilege"
else
  pass "no container is privileged, on the host network, or given a capability"
fi
if grep -E "^create${tab}--name${tab}$s-keeper" "$log" | grep -q -- "--timeout"; then fail "the keeper has a deadline"; else pass "the keeper has no deadline"; fi

# --- the helpers -----------------------------------------------------------------
line_has "the proxy mounts this session's lists read-only" "^create${tab}--name${tab}$s-proxy" "--volume${tab}$dir/proxy:/etc/squid/session:ro,z"
line_has "the proxy knows the agent's exact address" "^create${tab}--name${tab}$s-proxy" "SANDBOX_AGENT_IP=10.201.0.10"
line_has "plaintext port 80 is off"         "^create${tab}--name${tab}$s-proxy" "SANDBOX_ALLOW_HTTP=0"
line_has "the proxy is on both networks"    "^create${tab}--name${tab}$s-proxy" "--network${tab}$s-egress"
line_has "the sidecar gets the budget"      "^create${tab}--name${tab}$s-credsidecar" "SANDBOX_BUDGET=50"
line_has "the sidecar gets the mode"        "^create${tab}--name${tab}$s-credsidecar" "SANDBOX_AUTH=apikey"
line_has "the service runs as its own user" "^create${tab}--name${tab}$s-svc-redis" "--user${tab}999:1000"
line_has "the service gets its address"     "^create${tab}--name${tab}$s-svc-redis" "--network${tab}$s-sandbox:ip=10.201.0.20"
line_has "the service's memory mounts"      "^create${tab}--name${tab}$s-svc-redis" "--tmpfs${tab}/data:size=8m,mode=1777,nosuid,nodev,noexec"
if grep -qE "^create${tab}--name${tab}$s-svc-redis.*sha256:3333${tab}redis-server${tab}--save${tab}$" "$log"; then
  pass "the service's command keeps its empty argument"
else
  fail "the service's command lost its empty argument"
fi
check "the proxy directory is world-readable (0755)" test "$(stat -c %a "$dir/proxy")" = 755
check "the session directory is private (0700)"      test "$(stat -c %a "$dir")" = 700
check "the proxy's lists were rendered"              test -s "$dir/proxy/agent.domains"

# --- the credential  [physical B15, logical B22] -----------------------------------
loaded="$(find "$FAKE_PODMAN_STATE/stdin" -name "*.$s-credsidecar.sidecar-load")"
if [ -n "$loaded" ] && [ "$(cat "$loaded")" = "{\"token\":\"$SECRET\"}" ]; then
  pass "the credential reached the sidecar on stdin, as one JSON object"
else
  fail "the sidecar's stdin was: $(cat "$loaded" 2>/dev/null)"
fi
line_has "it was piped with exec -i, to the sidecar only" "sidecar-load" "exec${tab}-i${tab}$s-credsidecar${tab}sidecar-load"
if grep -qF "$SECRET" "$log"; then fail "the credential is on a podman command line"; else pass "the credential is on no podman command line"; fi
if grep -rqF "$SECRET" "$SANDBOX_STATE_DIR" "$SANDBOX_CONFIG_DIR"; then fail "the credential is in a file"; else pass "the credential is in no file of the session or the configuration"; fi
if [[ "$out" == *"$SECRET"* ]]; then fail "the credential was printed"; else pass "the credential is not printed"; fi
if grep -rqF "$SECRET" "$FAKE_PODMAN_STATE/stdin" --exclude="*.sidecar-load"; then fail "the credential went to another container"; else pass "the credential went to no other container"; fi
if grep -qF "MUST-NEVER-BE-USED" "$log" "$loaded"; then fail "ANTHROPIC_API_KEY from the shell was used"; else pass "ANTHROPIC_API_KEY from the shell is ignored"; fi
if [ -e "$FAKE_PODMAN_STATE/created-with-host-proxy" ]; then
  fail "containers were created with the host's proxy variables: $(tr '\n' ' ' < "$FAKE_PODMAN_STATE/created-with-host-proxy")"
else
  pass "the host's proxy variables are removed before any container is created"
fi

# --- the code -------------------------------------------------------------------
bundle="$(find "$FAKE_PODMAN_STATE/stdin" -name "*.$s-agent.sandbox-import")"
heads="$(git bundle list-heads "$bundle" 2>/dev/null || true)"
base="$(git -C "$T/src" rev-parse HEAD)"
case "$heads" in
  *"$base refs/heads/agent/test"*) pass "the agent received a bundle of the session branch at the starting commit" ;;
  *) fail "the bundle holds: $heads" ;;
esac
line_has "the import names the branch" "sandbox-import" "$s-agent${tab}sandbox-import${tab}agent/test"
line_has "the import carries your git identity" "sandbox-import" "--env${tab}GIT_AUTHOR_NAME=Test Operator"
check "the source repository was not touched" test "$(git -C "$T/src" branch --list | wc -l)" -eq 1

# --- attach ---------------------------------------------------------------------
launch="sandbox-launch"
line_has "the CLI is started in the agent container, with --auto" "$launch" "$s-agent${tab}sandbox-launch${tab}--auto"
line_has "the CLI is told the credential mode"   "$launch" "--env${tab}SANDBOX_AUTH=apikey"
line_has "the CLI gets your git name"            "$launch" "--env${tab}GIT_COMMITTER_NAME=Test Operator"
line_has "the CLI gets your git email"           "$launch" "--env${tab}GIT_AUTHOR_EMAIL=operator@example.test"
line_has "the CLI gets the service's address"    "$launch" "--env${tab}REDIS_URL=redis://redis:6379/0"
case "$out" in *"0.7 GB of this host's memory"*) pass "run prints the memory total" ;; *) fail "no memory total in: $out" ;; esac
case "$out" in *"SANDBOX_SESSION=$s ./sandbox export"*"SANDBOX_SESSION=$s ./sandbox destroy"*) pass "run says how to export and destroy" ;; *) fail "no export/destroy hint" ;; esac
check "no watchdog is started when none is needed" test ! -e "$dir/watchdog.pid"

# --- the state file -------------------------------------------------------------
for key in SESSION AGENT AUTH TOOLCHAIN BRANCH BASE_COMMIT ORIGIN_URL DEADLINE_EPOCH SUBNET EGRESS_SUBNET WORKSPACE_DRIVER SERVICES GIT_RELAY CREATED_EPOCH; do
  grep -q "^$key=" "$dir/state" || fail "state has no $key"
done
has "state records the starting commit"   "$dir/state" "BASE_COMMIT=$base"
has "state records where push will go"    "$dir/state" "ORIGIN_URL=$T/src"
has "state records the branch"            "$dir/state" "BRANCH=agent/test"
has "state records the services"          "$dir/state" "SERVICES=redis:7"
created="$(sed -n 's/^CREATED_EPOCH=//p' "$dir/state")"
deadline="$(sed -n 's/^DEADLINE_EPOCH=//p' "$dir/state")"
check "the deadline is the start plus --ttl" test "$((deadline - created))" -eq 3600

# --- a second session, side by side -----------------------------------------------
: > "$log"
status=0
"$ROOT/sandbox" run "$T/src" --ttl 2h </dev/null >/dev/null 2>&1 || status=$?
check "a second session starts" test "$status" -eq 0
line_has "it gets the next free subnet"       "^network${tab}create.*-sandbox$" "--subnet${tab}10.201.1.0/24"
line_has "its branch is named after it"       "sandbox-import" "sandbox-import${tab}agent/asb-src-"
check "the barrier checks are not repeated for images that passed" test "$(wc -l < "$T/config/verify.calls")" -eq 1
if grep -q "sandbox-launch${tab}--auto" "$log"; then fail "--auto was passed without being asked for"; else pass "without --auto the CLI keeps its prompts"; fi
says "with two sessions a command asks which one" "more than one session" "$ROOT/sandbox" shell
SANDBOX_SESSION="$s" "$ROOT/sandbox" destroy >/dev/null 2>&1
check "destroy removes the session it was told to" test ! -e "$dir"
check "and leaves the other one" test -n "$(only_session)"

# --- --strict, and a CLI that exits non-zero ---------------------------------------
status=0
FAKE_PODMAN_LAUNCH_EXIT=3 "$ROOT/sandbox" run "$T/src" --strict </dev/null >/dev/null 2>&1 || status=$?
check "run returns the CLI's exit status" test "$status" -eq 3
check "--strict repeats the barrier checks" test "$(wc -l < "$T/config/verify.calls")" -eq 2
check "the session stays when the CLI exits" test "$(find "$SANDBOX_STATE_DIR" -type f -name state | wc -l)" -eq 2

# --- destroy --all leaves nothing  [logical B31, closes L1] ------------------------
# Plus one session Podman still holds whose directory is gone (as after a reboot).
podman create --name asb-lost-0a1b2c-agent --label agent-sandbox.session=asb-lost-0a1b2c image >/dev/null
podman network create --label agent-sandbox.session=asb-lost-0a1b2c --subnet 10.201.9.0/24 asb-lost-0a1b2c-sandbox >/dev/null
"$ROOT/sandbox" destroy --all >/dev/null 2>&1 || fail "destroy --all failed"
left="$(find "$SANDBOX_STATE_DIR" -mindepth 1; find "$FAKE_PODMAN_STATE/containers" "$FAKE_PODMAN_STATE/networks" "$FAKE_PODMAN_STATE/volumes" -type f)"
if [ -z "$left" ]; then pass "destroy --all leaves nothing in the state directory or in Podman"; else fail "left after destroy --all: $left"; fi
says "with no session a command says so" "there is no session" "$ROOT/sandbox" export

finish
