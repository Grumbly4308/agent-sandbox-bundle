#!/usr/bin/env bash
# Where the model credential travels: from `login` into the keyring, from the
# keyring into the sidecar's stdin, and nowhere else. Includes the Codex
# subscription login, whose access token the host renews.  [logical B22]
#
# The keyring (`secret-tool`) and the renewal service (`curl`) are stand-ins
# written into the test's temporary directory. That the real renewal service
# accepts the request is not tested here and cannot be: see "UNPROVEN" in
# ./sandbox.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup
make_root
make_repo "$T/src"
log="$FAKE_PODMAN_LOG"
mkdir "$T/keyring"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP credentials.sh: jq is not installed (the Codex login needs it)"
  exit 0
fi
if [ "$(uname -s)" = Darwin ]; then
  echo "SKIP credentials.sh: the stand-in keyring imitates secret-tool, which macOS does not use"
  exit 0
fi

# A keyring: `store` keeps stdin in a file named after the attributes,
# `lookup` prints it. Every call's arguments are noted.
cat > "$T/bin/secret-tool" <<STANDIN
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/secret-tool.calls"
verb="\$1"; shift
if [ "\$verb" = store ]; then shift 2; fi          # --label <text>
file="$T/keyring/\$4-\$6"                           # service S agent A auth M
case "\$verb" in
  store)  cat > "\$file" ;;
  lookup) [ -f "\$file" ] && cat "\$file" ;;
esac
STANDIN
# The renewal service: notes its arguments and its stdin, answers with a file.
cat > "$T/bin/curl" <<STANDIN
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/curl.args"
cat > "$T/curl.stdin"
[ "\${FAKE_CURL_EXIT:-0}" -eq 0 ] || exit "\$FAKE_CURL_EXIT"
cat "$T/curl.reply"
STANDIN
chmod +x "$T/bin/secret-tool" "$T/bin/curl"

# A token shaped like the ones Codex holds: three parts, the middle one
# saying when it expires.
jwt() {
  printf 'hdr.%s.sig%s' "$(printf '{"exp":%s}' "$1" | base64 | tr '+/' '-_' | tr -d '=\n')" "$2"
}
nowhere() {   # <description> <secret>: in no podman call, no stdin but the sidecar's, no file of the session
  if grep -qF -- "$2" "$log" "$T/secret-tool.calls" 2>/dev/null; then fail "$1: on a command line"; return; fi
  if grep -rqF -- "$2" "$SANDBOX_STATE_DIR" "$SANDBOX_CONFIG_DIR" 2>/dev/null; then fail "$1: in a file"; return; fi
  if [ -f "$T/curl.args" ] && grep -qF -- "$2" "$T/curl.args"; then fail "$1: on curl's command line"; return; fi
  pass "$1"
}

# The most recent thing piped to a sidecar's loader (the fake numbers what it
# keeps in call order).
last_loaded() {
  local file number best=0 found=""
  for file in "$FAKE_PODMAN_STATE"/stdin/*.sidecar-load; do
    [ -f "$file" ] || continue
    number="${file##*/}"
    number="${number%%.*}"
    if [ "$number" -gt "$best" ]; then best="$number"; found="$file"; fi
  done
  printf '%s' "$found"
}

# --- login --------------------------------------------------------------------
CLAUDE_TOKEN="sk-ant-oat01-LOGIN-TOKEN-abcdef"
out="$(printf '%s\n' "$CLAUDE_TOKEN" | "$ROOT/sandbox" login --agent claude --auth oauth 2>&1)" || fail "login failed: $out"
check "login stores the token in the keyring" test "$(cat "$T/keyring/claude-oauth")" = "$CLAUDE_TOKEN"
check "it is filed under agent-sandbox, agent and mode" grep -q "service agent-sandbox agent claude auth oauth" "$T/secret-tool.calls"
nowhere "the token is on no command line and in no file" "$CLAUDE_TOKEN"
case "$out" in *"$CLAUDE_TOKEN"*) fail "login printed the token" ;; *) pass "login does not print the token" ;; esac
for text in "claude setup-token" "one year" "dedicated subscription account" "extra usage" "overage billing" "To revoke it" "secret-tool clear service agent-sandbox agent claude auth oauth"; do
  case "$out" in *"$text"*) pass "login says: $text" ;; *) fail "login does not say '$text'" ;; esac
done

printf 'sk-ant-api03-KEY\n' | "$ROOT/sandbox" login --agent claude --auth apikey >/dev/null 2>&1
check "an API key is stored under its own mode" test "$(cat "$T/keyring/claude-apikey")" = "sk-ant-api03-KEY"
refuse "something that is not a token is not stored" bash -c "printf 'two words\n' | '$ROOT/sandbox' login --agent claude --auth apikey"
refuse "login for an unknown agent is refused" bash -c "printf 'x\n' | '$ROOT/sandbox' login --agent nosuch"

# Codex: the whole auth.json, read from the path the operator gives.
ACCESS_1="$(jwt $(( $(date +%s) + 7200 )) A)"
mkdir -p "$T/home/.codex"
printf '{\n  "OPENAI_API_KEY": null,\n  "tokens": {\n    "id_token": "id.one.x",\n    "access_token": "%s",\n    "refresh_token": "rt_FIRST-refresh-token",\n    "account_id": "acct-42"\n  },\n  "last_refresh": "2026-10-01T00:00:00Z"\n}\n' "$ACCESS_1" > "$T/home/.codex/auth.json"
out="$(printf '\n' | "$ROOT/sandbox" login --agent codex --auth oauth 2>&1)" || fail "codex login failed: $out"
check "the Codex login is stored whole, on one line" test "$(wc -l < "$T/keyring/codex-oauth")" -eq 0
check "it keeps the refresh token" test "$(jq -r .tokens.refresh_token "$T/keyring/codex-oauth")" = "rt_FIRST-refresh-token"
nowhere "the refresh token is on no command line and in no file" "rt_FIRST-refresh-token"
printf '{"tokens":{}}\n' > "$T/empty.json"
refuse "an auth.json with no login in it is refused" bash -c "printf '%s\n' '$T/empty.json' | '$ROOT/sandbox' login --agent codex --auth oauth"

# --- run: keyring to sidecar ------------------------------------------------------
"$ROOT/sandbox" run "$T/src" --agent claude --auth oauth </dev/null >/dev/null 2>&1 || fail "run with a keyring credential failed"
s="$(only_session)"
loaded="$(find "$FAKE_PODMAN_STATE/stdin" -name "*.$s-credsidecar.sidecar-load")"
check "the stored token is what the sidecar receives" test "$(cat "$loaded")" = "{\"token\":\"$CLAUDE_TOKEN\"}"
nowhere "and it is nowhere else" "$CLAUDE_TOKEN"
"$ROOT/sandbox" destroy >/dev/null 2>&1

# --- Codex: only the access token and the account id enter a container -------------
"$ROOT/sandbox" run "$T/src" --agent codex --auth oauth </dev/null >/dev/null 2>&1 || fail "run with the Codex login failed"
s="$(only_session)"
dir="$SANDBOX_STATE_DIR/$s"
loaded="$(find "$FAKE_PODMAN_STATE/stdin" -name "*.$s-credsidecar.sidecar-load" | head -1)"
check "the sidecar receives the access token and the account id" test "$(cat "$loaded")" = "{\"token\":\"$ACCESS_1\",\"account_id\":\"acct-42\"}"
check "a token with time left is not renewed" test ! -e "$T/curl.args"
if grep -rqF "rt_FIRST" "$FAKE_PODMAN_STATE/stdin"; then fail "the refresh token was piped into a container"; else pass "the refresh token is piped into no container"; fi
nowhere "the refresh token is nowhere else either" "rt_FIRST-refresh-token"
nowhere "the access token is on no command line and in no file" "$ACCESS_1"
check "a watchdog was started for the session" test -s "$dir/watchdog.pid"
watchdog="$(cat "$dir/watchdog.pid")"
check "it is running" kill -0 "$watchdog"
# The watchdog's first look hands the sidecar the token once more. Wait for
# that, then hold the watchdog still so the looks below are the test's own.
tries=0
until [ "$(find "$FAKE_PODMAN_STATE/stdin" -name "*.sidecar-load" | wc -l)" -ge 2 ] && [ ! -e "$SANDBOX_STATE_DIR/codex-refresh.lock" ]; do
  tries=$((tries + 1))
  [ "$tries" -lt 100 ] || { fail "the watchdog never took its first look"; break; }
  sleep 0.1
done
kill -STOP "$watchdog"
check "the renewal lock is released" test ! -e "$SANDBOX_STATE_DIR/codex-refresh.lock"

# --- renewal: the token is about to expire ------------------------------------------
ACCESS_OLD="$(jwt $(( $(date +%s) + 60 )) B)"
ACCESS_NEW="$(jwt $(( $(date +%s) + 7200 )) C)"
jq -c --arg t "$ACCESS_OLD" '.tokens.access_token = $t' "$T/keyring/codex-oauth" > "$T/k" && cp "$T/k" "$T/keyring/codex-oauth"
printf '{"id_token":"id.two.x","access_token":"%s","refresh_token":"rt_SECOND-refresh-token"}\n' "$ACCESS_NEW" > "$T/curl.reply"
# A lock left by a process that no longer exists must not block the renewal.
mkdir "$SANDBOX_STATE_DIR/codex-refresh.lock"
echo 999999 > "$SANDBOX_STATE_DIR/codex-refresh.lock/pid"
: > "$log"
"$ROOT/sandbox" __watchdog "$s" --once || fail "the watchdog's look failed"
check "the renewal goes to the Codex token endpoint" grep -q "https://auth.openai.com/oauth/token" "$T/curl.args"
check "the request names the client, the grant and the scope" test "$(jq -r '.client_id + " " + .grant_type + " " + .scope' "$T/curl.stdin")" = "app_EMoamEEZ73f0CkXaXp7hrann refresh_token openid profile email"
check "the refresh token travels in the request body" test "$(jq -r .refresh_token "$T/curl.stdin")" = "rt_FIRST-refresh-token"
if grep -qF "rt_FIRST" "$T/curl.args"; then fail "the refresh token is on curl's command line"; else pass "the refresh token is not on curl's command line"; fi
check "the rotated refresh token is written back to the keyring" test "$(jq -r .tokens.refresh_token "$T/keyring/codex-oauth")" = "rt_SECOND-refresh-token"
check "so is the new access token" test "$(jq -r .tokens.access_token "$T/keyring/codex-oauth")" = "$ACCESS_NEW"
check "the account id is kept" test "$(jq -r .tokens.account_id "$T/keyring/codex-oauth")" = "acct-42"
loaded="$(last_loaded)"
check "the sidecar is given the new access token" test "$(cat "$loaded")" = "{\"token\":\"$ACCESS_NEW\",\"account_id\":\"acct-42\"}"
if grep -rqF "rt_" "$FAKE_PODMAN_STATE/stdin" "$log"; then fail "a refresh token reached Podman"; else pass "no refresh token ever reaches Podman"; fi
nowhere "the new refresh token is on no command line and in no file" "rt_SECOND-refresh-token"
check "a stale lock was taken over and released" test ! -e "$SANDBOX_STATE_DIR/codex-refresh.lock"

# --- renewal fails: the session carries on, the keyring is not damaged ---------------
jq -c --arg t "$ACCESS_OLD" '.tokens.access_token = $t' "$T/keyring/codex-oauth" > "$T/k" && cp "$T/k" "$T/keyring/codex-oauth"
before_failure="$(cat "$T/keyring/codex-oauth")"
FAKE_CURL_EXIT=22 "$ROOT/sandbox" __watchdog "$s" --once 2>/dev/null || fail "a failed renewal ended the watchdog"
check "a failed renewal leaves the stored login as it was" test "$(cat "$T/keyring/codex-oauth")" = "$before_failure"
check "and releases the lock" test ! -e "$SANDBOX_STATE_DIR/codex-refresh.lock"
printf 'this is not json\n' > "$T/curl.reply"
"$ROOT/sandbox" __watchdog "$s" --once 2>/dev/null || fail "a garbled reply ended the watchdog"
check "a garbled reply leaves the stored login as it was" test "$(cat "$T/keyring/codex-oauth")" = "$before_failure"

# --- destroy ends the watchdog ---------------------------------------------------------
kill -CONT "$watchdog"
"$ROOT/sandbox" destroy >/dev/null 2>&1 || fail "destroy failed"
sleep 1
refuse "destroy stops the watchdog" kill -0 "$watchdog"
left="$(find "$SANDBOX_STATE_DIR" -mindepth 1)"
if [ -z "$left" ]; then pass "destroy leaves nothing in the state directory"; else fail "left: $left"; fi
refuse "the watchdog refuses a name that is not a session" "$ROOT/sandbox" __watchdog "../../etc"

finish
