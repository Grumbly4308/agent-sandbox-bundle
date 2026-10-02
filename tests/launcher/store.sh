#!/usr/bin/env bash
# The disk-backed workspace (`--workspace-driver local`): the store it needs,
# how the session's directory is made and removed, and the host watch that
# stops a session past its share.  [physical B08, logical B33]
#
# A real store is a filesystem of its own. Making one needs root, so here a
# stand-in `stat` tells doctor.sh that the test's directory sits on a
# different device from its parent. Everything else is the real code.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup
make_root
make_repo "$T/src"
log="$FAKE_PODMAN_LOG"
tab="$(printf '\t')"
export SANDBOX_TEST_ANTHROPIC_KEY="sk-ant-test-0123456789"

if ! stat -c %d / >/dev/null 2>&1; then
  echo "SKIP store.sh: needs GNU stat (the disk store is a Linux feature)"
  exit 0
fi

mkdir "$T/store"
printf 'STORE=%s\n' "$T/store" >> "$T/config/settings"
run_local() { "$ROOT/sandbox" run "$T/src" --workspace-driver local "$@" </dev/null; }

# --- the store must be a filesystem of its own, and yours ---------------------------
says   "an ordinary directory is refused as a store" "not a filesystem of its own" run_local
says   "the refusal shows how to make one" "mkfs.ext4" run_local
check  "nothing was made" test -z "$(only_session)"

real_stat="$(command -v stat)"
cat > "$T/bin/stat" <<STANDIN
#!/bin/sh
# Report the store's parent as being on another device; otherwise the real stat.
if [ "\$1" = -c ] && [ "\$2" = %d ] && [ "\$3" = "$T/store/.." ]; then echo 1; exit 0; fi
if [ "\$1" = -c ] && [ "\$2" = %u ] && [ "\$3" = "$T/store" ] && [ -n "\${FAKE_STORE_OWNER:-}" ]; then echo "\$FAKE_STORE_OWNER"; exit 0; fi
exec "$real_stat" "\$@"
STANDIN
chmod +x "$T/bin/stat"
FAKE_STORE_OWNER=0 says "a store owned by someone else is refused" "belongs to uid 0, not to you" run_local
says   "--io-limit needs the store's block device" "is not one" run_local --io-limit 10m
FAKE_PODMAN_CONTROLLERS="cpu memory pids" says "--io-limit needs the io controller" "may not set limits for: io" run_local --io-limit 10m
check  "still nothing was made" test -z "$(only_session)"

# --- a session on the store -----------------------------------------------------------
: > "$log"
out="$(run_local --workspace-size 16m 2>&1)" || fail "run on the store failed: $out"
s="$(only_session)"
dir="$SANDBOX_STATE_DIR/$s"
check  "the session gets its own directory on the store" test -d "$T/store/$s"
before "it is handed to the container's user before the volume is made" \
  "^unshare${tab}chown${tab}61000:61000${tab}$T/store/$s$" "^volume${tab}create"
if grep -qE "^volume${tab}create.*--opt${tab}type=none${tab}--opt${tab}device=$T/store/$s${tab}--opt${tab}o=bind,nosuid,nodev${tab}$s-workspace$" "$log"; then
  pass "the volume is that directory, nosuid and nodev"
else
  fail "volume create was: $(grep "^volume${tab}create" "$log")"
fi
# 64m processes + 16m /tmp + 16m home + 64m /dev/shm; the workspace is on disk.
if grep -qE "^create${tab}--name${tab}$s-agent${tab}.*--memory${tab}167772160${tab}" "$log"; then
  pass "the memory limit leaves out a workspace that is on disk"
else
  fail "agent memory limit is wrong: $(grep -oE -- "--memory${tab}[0-9]+" "$log" | tr '\n' ' ')"
fi
check  "state records the driver" grep -qx "WORKSPACE_DRIVER=local" "$dir/state"
check  "state records the store" grep -qx "STORE=$T/store" "$dir/state"
check  "state records the session's share" grep -qx "WORKSPACE_BYTES=16777216" "$dir/state"
check  "a watchdog was started" test -s "$dir/watchdog.pid"
watchdog="$(cat "$dir/watchdog.pid")"
kill -STOP "$watchdog"      # hold it still: the looks below are the test's own

# --- the watch  [logical B33] ----------------------------------------------------------
: > "$log"
FAKE_PODMAN_DU=1000000 "$ROOT/sandbox" __watchdog "$s" --once || fail "a look within the share failed"
check  "the share is measured from inside Podman's user namespace" grep -qx "unshare${tab}du${tab}-sb${tab}$T/store/$s" "$log"
if grep -q "^stop${tab}" "$log"; then fail "a session within its share was stopped"; else pass "a session within its share keeps running"; fi

: > "$log"
status=0
FAKE_PODMAN_DU=17000000 "$ROOT/sandbox" __watchdog "$s" --once || status=$?
check  "past the share, the watch ends" test "$status" -ne 0
check  "the agent is stopped" grep -qx "stop${tab}$s-agent" "$log"
check  "the proxy and the sidecar are stopped" test "$(grep -cE "^stop${tab}$s-(proxy|credsidecar)$" "$log")" -eq 2
if grep -q "^stop${tab}$s-keeper" "$log"; then fail "the keeper was stopped"; else pass "the keeper keeps the work for export"; fi
says   "the next command says why the session stopped" "its workspace grew past --workspace-size" "$ROOT/sandbox" logs proxy

# --- destroy removes the session's directory on the store ---------------------------------
kill -CONT "$watchdog"
: > "$log"
"$ROOT/sandbox" destroy >/dev/null 2>&1 || fail "destroy failed"
check  "the directory on the store is removed as the container's user" grep -qx "unshare${tab}rm${tab}-rf${tab}$T/store/$s" "$log"
check  "it is gone" test ! -e "$T/store/$s"
check  "the store itself stays" test -d "$T/store"
left="$(find "$SANDBOX_STATE_DIR" -mindepth 1)"
if [ -z "$left" ]; then pass "destroy leaves nothing in the state directory"; else fail "left: $left"; fi
sleep 1
refuse "destroy stops the watchdog" kill -0 "$watchdog"

finish
