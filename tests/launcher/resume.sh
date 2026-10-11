#!/usr/bin/env bash
# `./sandbox resume`: back into a session after the CLI exited, after its
# time limit, after a reboot; what is started again and in which order, what
# is handed in again, and what is refused. Also sessions with no time limit
# (the default) and `export --commit`.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup
make_root
make_repo "$T/src"
log="$FAKE_PODMAN_LOG"
tab="$(printf '\t')"
SECRET="sk-ant-test-RESUME-SECRET-0123456789"
export SANDBOX_TEST_ANTHROPIC_KEY="$SECRET"

called() { if grep -qE -- "$2" "$log"; then pass "$1"; else fail "$1: no call matching $2"; fi; }
not_called() { if grep -qE -- "$2" "$log"; then fail "$1: a call matched $2"; else pass "$1"; fi; }
state_of() { sed -n "s/^$2=//p" "$SANDBOX_STATE_DIR/$1/state"; }
# As after a reboot: every container of the fake is down.
reboot() {
  local file label
  for file in "$FAKE_PODMAN_STATE"/containers/*; do
    [ -f "$file" ] || continue
    label="$(sed -n 's/^label=//p' "$file")"
    printf 'label=%s\nstatus=exited\n' "$label" > "$file"
  done
}
loads_of() {   # <session>: how many times the sidecar was handed a credential
  find "$FAKE_PODMAN_STATE/stdin" -name "*.$1-credsidecar.sidecar-load" | wc -l | tr -d ' '
}

# --- a session with a time limit (the test settings say TTL=1h) -------------------
"$ROOT/sandbox" run "$T/src" --branch agent/test --service redis:7 </dev/null >/dev/null 2>&1 || fail "run failed"
s="$(only_session)"
dir="$SANDBOX_STATE_DIR/$s"
check "state records the time limit on its own" test "$(state_of "$s" TTL_SECONDS)" = 3600
check "state records the budget" test "$(state_of "$s" BUDGET)" = 50
check "state records this boot" test -n "$(state_of "$s" BOOT_ID)"
deadline="$(state_of "$s" DEADLINE_EPOCH)"

# --- the CLI exited; everything still runs ------------------------------------------
: > "$log"
out="$("$ROOT/sandbox" resume -- --continue 2>&1)" || fail "resume of a running session failed: $out"
case "$out" in *"is running; attaching"*) pass "resume of a running session only attaches" ;; *) fail "resume: $out" ;; esac
not_called "nothing is started" "^start${tab}"
not_called "nothing is stopped" "^stop${tab}"
called "the CLI is started again, with the arguments after --" "^exec${tab}.*$s-agent${tab}sandbox-launch${tab}--continue$"
called "the CLI gets your git identity again" "sandbox-launch.*GIT_AUTHOR_NAME=Test Operator|GIT_AUTHOR_NAME=Test Operator.*sandbox-launch"
check "the sidecar was not handed the credential again" test "$(loads_of "$s")" -eq 1
check "the deadline is unchanged" test "$(state_of "$s" DEADLINE_EPOCH)" = "$deadline"
case "$out" in *"runs until"*"at most 50 model requests"*) pass "resume says the time limit and the budget" ;; *) fail "no limit line: $out" ;; esac
case "$out" in *"SANDBOX_SESSION=$s ./sandbox resume"*) pass "when the CLI exits, run and resume say how to come back" ;; *) fail "no resume hint: $out" ;; esac
refuse "resume takes nothing but -- arguments" "$ROOT/sandbox" resume --continue

# --- after a reboot -------------------------------------------------------------------
reboot
: > "$log"
sleep 1
out="$("$ROOT/sandbox" resume 2>&1)" || fail "resume after a reboot failed: $out"
case "$out" in *"starting it again"*) pass "resume after a reboot says it is starting the session again" ;; *) fail "resume after reboot: $out" ;; esac
called "the keeper is started" "^start${tab}$s-keeper$"
before "the keeper starts first" "^start${tab}$s-keeper$" "^start${tab}$s-proxy$"
before "the proxy starts before the sidecar" "^start${tab}$s-proxy$" "^start${tab}$s-credsidecar$"
before "the service starts before the agent" "^start${tab}$s-svc-redis$" "^start${tab}$s-agent$"
before "the proxy is waited for before the credential goes in" "^exec${tab}$s-proxy${tab}squid${tab}-k${tab}check" "sidecar-load"
before "the sidecar is waited for before the credential goes in" "^exec${tab}$s-credsidecar${tab}sidecar-healthcheck" "sidecar-load"
before "the service is waited for" "^exec${tab}$s-svc-redis${tab}redis-cli" "sandbox-launch"
before "the credential goes in before the CLI starts" "sidecar-load" "sandbox-launch"
check "the sidecar is handed the credential again (its memory was emptied)" test "$(loads_of "$s")" -eq 2
case "$out" in *"request budget counts from zero: 50 requests again"*) pass "resume says the budget starts over with the sidecar" ;; *) fail "no budget notice: $out" ;; esac
loaded="$(find "$FAKE_PODMAN_STATE/stdin" -name "*.$s-credsidecar.sidecar-load" | sort -n | tail -1)"
check "... the same credential, as one JSON object" test "$(cat "$loaded")" = "{\"token\":\"$SECRET\"}"
if grep -qF "$SECRET" "$log"; then fail "the credential is on a podman command line"; else pass "the credential is on no podman command line"; fi
not_called "nothing is created: the containers are the ones run made" "^(create|network${tab}create|volume${tab}create)"
check "no barrier check is repeated (the containers did not change)" test "$(grep -c -- "^--quick" "$T/config/verify.calls")" -eq 1
check "the deadline moved: Podman's timers started again" test "$(state_of "$s" DEADLINE_EPOCH)" -gt "$deadline"
check "... by the session's own time limit" test "$(( $(state_of "$s" DEADLINE_EPOCH) - $(state_of "$s" CREATED_EPOCH) ))" -eq 3600
check "no watchdog for a session that needs none" test ! -e "$dir/watchdog.pid"

# --- after the time limit ---------------------------------------------------------------
sed "s/^DEADLINE_EPOCH=.*/DEADLINE_EPOCH=1/" "$dir/state" > "$T/state.edit" && cp "$T/state.edit" "$dir/state"
: > "$log"
out="$("$ROOT/sandbox" resume 2>&1)" || fail "resume after the time limit failed: $out"
case "$out" in *"reached its time limit"*"resume to carry on"*) pass "the sweep says the limit passed and names resume" ;; *) fail "no sweep notice: $out" ;; esac
called "what the limit stopped is started again" "^start${tab}$s-agent$"
check "with a fresh deadline" test "$(state_of "$s" DEADLINE_EPOCH)" -gt "$(date +%s)"
check "the sidecar is handed the credential once more" test "$(loads_of "$s")" -eq 3

# --- the agent killed its own container: the rest is restarted too --------------------
podman stop "$s-agent" >/dev/null
: > "$log"
"$ROOT/sandbox" resume </dev/null >/dev/null 2>&1 || fail "resume with the agent down failed"
called "what still ran is stopped" "^stop${tab}$s-proxy$"
not_called "but not the keeper" "^stop${tab}$s-keeper$"
called "and everything starts afresh" "^start${tab}$s-credsidecar$"

# --- stopped by the watch -------------------------------------------------------------
printf 'its workspace grew past --workspace-size (0.0 GB)\n' > "$dir/stopped"
podman stop "$s-agent" >/dev/null
out="$("$ROOT/sandbox" resume 2>&1)" || fail "resume of a session stopped by the watch failed: $out"
case "$out" in *"was stopped because its workspace grew past"*"started again as it is"*) pass "resume says why it was stopped and what happens now" ;; *) fail "no stop notice: $out" ;; esac
check "the stop marker is removed" test ! -e "$dir/stopped"

# --- a workspace held in memory does not survive a reboot ---------------------------------
sed "s/^BOOT_ID=.*/BOOT_ID=00000000-dead-beef-0000-000000000000/" "$dir/state" > "$T/state.edit" && cp "$T/state.edit" "$dir/state"
reboot
: > "$log"
says "resume refuses: the workspace in memory is gone" "held its workspace in memory, and this host has rebooted" "$ROOT/sandbox" resume
not_called "nothing is started" "^start${tab}"
sed "s/^BOOT_ID=.*/BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)/" "$dir/state" > "$T/state.edit" && cp "$T/state.edit" "$dir/state"

# --- a container of the session is gone -------------------------------------------------
rm -f "$FAKE_PODMAN_STATE/containers/$s-proxy"
says "resume refuses when a container is gone" "is gone; the session cannot be resumed" "$ROOT/sandbox" resume
"$ROOT/sandbox" destroy >/dev/null 2>&1 || fail "destroy failed"

# --- a session on the disk store survives a reboot, watchdog and all -------------------
if stat -c %d / >/dev/null 2>&1; then
  mkdir "$T/store"
  printf 'STORE=%s\n' "$T/store" >> "$T/config/settings"
  real_stat="$(command -v stat)"
  cat > "$T/bin/stat" <<STANDIN
#!/bin/sh
if [ "\$1" = -c ] && [ "\$2" = %d ] && [ "\$3" = "$T/store/.." ]; then echo 1; exit 0; fi
exec "$real_stat" "\$@"
STANDIN
  chmod +x "$T/bin/stat"
  "$ROOT/sandbox" run "$T/src" --workspace-driver local --workspace-size 16m </dev/null >/dev/null 2>&1 || fail "run on the store failed"
  s="$(only_session)"
  dir="$SANDBOX_STATE_DIR/$s"
  kill "$(cat "$dir/watchdog.pid")" 2>/dev/null || true
  reboot
  sed "s/^BOOT_ID=.*/BOOT_ID=00000000-dead-beef-0000-000000000000/" "$dir/state" > "$T/state.edit" && cp "$T/state.edit" "$dir/state"
  : > "$log"
  "$ROOT/sandbox" resume </dev/null >/dev/null 2>&1 || fail "resume on the store after a reboot failed"
  called "a workspace on disk is resumed across a reboot" "^start${tab}$s-agent$"
  check "a watchdog is started again for it" test -s "$dir/watchdog.pid"
  check "... and it is running" kill -0 "$(cat "$dir/watchdog.pid")"
  "$ROOT/sandbox" destroy >/dev/null 2>&1 || fail "destroy failed"
  grep -v '^STORE=' "$T/config/settings" > "$T/settings.edit" && cp "$T/settings.edit" "$T/config/settings"
  rm -f "$T/bin/stat"
fi

# --- no time limit  [logical B26 is then not in force] -----------------------------------
: > "$log"
out="$("$ROOT/sandbox" run "$T/src" --ttl none </dev/null 2>&1)" || fail "run --ttl none failed: $out"
s="$(only_session)"
dir="$SANDBOX_STATE_DIR/$s"
if grep -qE "^create${tab}--name${tab}$s-agent${tab}.*--timeout${tab}0${tab}" "$log"; then pass "--ttl none: Podman's timer is 0, its own 'never'"; else fail "--ttl none: $(grep -oE -- "--timeout${tab}[0-9]+" "$log" | sort -u | tr '\n' ' ')"; fi
check "--ttl none: no deadline in the state" test "$(state_of "$s" DEADLINE_EPOCH)" = 0
check "--ttl none: the limit is recorded as none" test "$(state_of "$s" TTL_SECONDS)" = 0
case "$out" in *"has no time limit (it runs until you destroy it)"*) pass "run says the session has no time limit" ;; *) fail "run's limit line: $out" ;; esac
out="$("$ROOT/sandbox" logs proxy 2>&1 || true)"
case "$out" in *"time limit"*) fail "a session with no limit is reported as past it: $out" ;; *) pass "the sweep leaves a session with no limit alone" ;; esac
reboot
"$ROOT/sandbox" resume </dev/null >/dev/null 2>&1 || fail "resume of a session with no limit failed"
check "resume keeps it unlimited" test "$(state_of "$s" DEADLINE_EPOCH)" = 0
"$ROOT/sandbox" destroy >/dev/null 2>&1 || fail "destroy failed"

# The default, with no TTL line in the settings file.
grep -v '^TTL=' "$T/config/settings" > "$T/settings.edit" && cp "$T/settings.edit" "$T/config/settings"
"$ROOT/sandbox" run "$T/src" </dev/null >/dev/null 2>&1 || fail "run with the default limit failed"
s="$(only_session)"
check "with nothing said, a session has no time limit" test "$(state_of "$s" DEADLINE_EPOCH)" = 0
says "--ttl still takes a duration" "is not a duration" "$ROOT/sandbox" run "$T/src" --ttl 4w
says "the settings file explains none" "or none: it runs until you destroy it" bash -c "rm '$T/config/settings'; '$ROOT/sandbox' doctor >/dev/null 2>&1; cat '$T/config/settings'"
check "a fresh settings file defaults TTL to none" grep -qx 'TTL=none' "$T/config/settings"

# --- export --commit  [logical B27] ------------------------------------------------------
git clone --quiet "$T/src" "$T/work"
git -C "$T/work" checkout --quiet -b "agent/$s"
printf 'more\n' >> "$T/work/README.md"
git -C "$T/work" commit --quiet -am "agent's change"
git -C "$T/work" bundle create --quiet "$T/agent.bundle" "agent/$s"

# The commit lands where HEAD is, and export takes the session branch only:
# any other branch, or none, is refused before anything is committed.
: > "$log"
out="$(FAKE_PODMAN_BUNDLE="$T/agent.bundle" FAKE_PODMAN_GIT_HEAD=experiment FAKE_PODMAN_GIT_STATUS='?? notes.md\n' "$ROOT/sandbox" export --out "$T/exported" --commit 2>&1)" && fail "export --commit on another branch succeeded"
case "$out" in *"has branch experiment checked out, not the session branch agent/$s"*"Nothing was committed"*"git switch agent/$s"*) pass "export --commit refuses another branch, and says how to recover" ;; *) fail "another branch: $out" ;; esac
not_called "... nothing is committed there" "git -c core.hooksPath=/dev/null add -A"
not_called "... and nothing is exported" "sandbox-bundle"
: > "$log"
out="$(FAKE_PODMAN_BUNDLE="$T/agent.bundle" FAKE_PODMAN_GIT_HEAD=detached FAKE_PODMAN_GIT_STATUS='?? notes.md\n' "$ROOT/sandbox" export --out "$T/exported" --commit 2>&1)" && fail "export --commit on a detached HEAD succeeded"
case "$out" in *"has a detached HEAD checked out, not the session branch"*) pass "export --commit refuses a detached HEAD" ;; *) fail "detached HEAD: $out" ;; esac
not_called "... and commits nothing" "git -c core.hooksPath=/dev/null add -A"
export FAKE_PODMAN_GIT_HEAD="agent/$s"

: > "$log"
out="$(FAKE_PODMAN_BUNDLE="$T/agent.bundle" "$ROOT/sandbox" export --out "$T/exported" --commit 2>&1)" || fail "export --commit on a clean tree failed: $out"
case "$out" in *"no uncommitted changes"*) pass "export --commit on a clean tree commits nothing" ;; *) fail "clean tree: $out" ;; esac
not_called "... and runs no commit" "git -c core.hooksPath=/dev/null commit"
case "$out" in *"Nothing has reached $T/src yet"*"./sandbox push"*) pass "export says where push would send the branch" ;; *) fail "no push destination: $out" ;; esac
: > "$log"
out="$(FAKE_PODMAN_BUNDLE="$T/agent.bundle" FAKE_PODMAN_GIT_STATUS=' M README.md\n?? notes.md\n' "$ROOT/sandbox" export --out "$T/exported" --commit 2>&1)" || fail "export --commit failed: $out"
case "$out" in *"committing 2 uncommitted change(s)"*) pass "export --commit counts the uncommitted changes" ;; *) fail "count: $out" ;; esac
called "the status is read with the agent's git, hooks off" "^exec${tab}.*$s-agent${tab}git${tab}-C${tab}/workspace/repo${tab}-c${tab}core.hooksPath=/dev/null${tab}status${tab}--porcelain"
called "they are committed in the agent's container, under your identity" "^exec${tab}.*GIT_AUTHOR_NAME=Test Operator.*$s-agent${tab}sh${tab}-c${tab}cd /workspace/repo && git -c core.hooksPath=/dev/null add -A && git -c core.hooksPath=/dev/null commit --quiet -m \"Uncommitted work at export\"$"
before "the commit comes before the bundle is written" "git -c core.hooksPath=/dev/null add -A" "sandbox-bundle"
podman stop "$s-agent" >/dev/null
says "export --commit needs the agent container" "resume starts the session again" "$ROOT/sandbox" export --out "$T/exported" --commit
says "shell on a stopped session names resume" "./sandbox resume starts the session again" "$ROOT/sandbox" shell

finish
