#!/usr/bin/env bash
# The launcher against the REAL scripts/allowlist.sh, scripts/export.sh,
# policy/ and agents/ of this repository (the other tests use stand-ins), to
# catch a mismatch between what ./sandbox calls and what those files offer.
# Podman is still the fake, and verify.sh is still a stand-in.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for needed in scripts/allowlist.sh scripts/export.sh policy/never-allow.txt policy/allowlist.base.txt \
              policy/presets/github-downloads.txt policy/gitleaks.toml agents/claude/env agents/claude/allowlist.txt; do
  if [ ! -e "$REPO/$needed" ]; then
    echo "SKIP integration.sh: $needed is not in the repository yet"
    exit 0
  fi
done

setup
make_root
rm -rf "$ROOT/agents" "$ROOT/scripts/allowlist.sh" "$ROOT/scripts/export.sh"
cp -R "$REPO/agents" "$REPO/policy" "$ROOT/"
cp "$REPO/scripts/allowlist.sh" "$REPO/scripts/export.sh" "$ROOT/scripts/"
make_repo "$T/src"
git init --quiet --bare "$T/remote.git"
git -C "$T/src" remote add origin "$T/remote.git"
log="$FAKE_PODMAN_LOG"
tab="$(printf '\t')"
export SANDBOX_TEST_ANTHROPIC_KEY="sk-ant-test-0123456789"

# --- every shipped agent's env file passes the launcher's check ---------------------
# shellcheck disable=SC2016  # $1 belongs to the inner shell
check "agents/*/env hold NAME=value lines only" \
  bash -c '. "$1/sandbox"; for file in "$1"/agents/*/env; do check_env_file "$file"; done' _ "$REPO"

# --- the plug-ins say which credential modes they take --------------------------------
says   "OpenCode with a subscription login is refused" "opencode does not take --auth oauth" "$ROOT/sandbox" run "$T/src" --agent opencode --auth oauth
says   "and so is storing one" "opencode does not take --auth oauth" "$ROOT/sandbox" login --agent opencode --auth oauth
check  "nothing was made" test -z "$(only_session)"

# --- run renders the real lists -------------------------------------------------------
out="$("$ROOT/sandbox" run "$T/src" --branch agent/test </dev/null 2>&1)" || fail "run failed: $out"
s="$(only_session)"
proxy="$SANDBOX_STATE_DIR/$s/proxy"
for file in agent.domains sidecar.domains relay.domains extra.conf; do
  check "the real allowlist_render wrote $file" test -f "$proxy/$file"
done
check "the vendor's host is on the sidecar's list" grep -q "anthropic.com" "$proxy/sidecar.domains"
if grep -q "anthropic.com" "$proxy/agent.domains"; then fail "the vendor's host is on the agent's list"; else pass "and not on the agent's  [B21]"; fi
check "the lists are world-readable for the proxy's user" test "$(stat -c %a "$proxy/agent.domains" 2>/dev/null || stat -f %Lp "$proxy/agent.domains")" = 644

# --- allow and deny through the real functions -------------------------------------------
"$ROOT/sandbox" allow docs.example.com --reason "API reference" >/dev/null 2>&1 || fail "allow failed"
check  "an allowed host reaches the session's list" grep -qx "docs.example.com" "$proxy/agent.domains"
refuse "a never-allow host is refused  [B20]" "$ROOT/sandbox" allow storage.googleapis.com --reason "bucket"
refuse "a pattern wide enough to cover one is refused" "$ROOT/sandbox" allow .googleapis.com --reason "all of it"
refuse "the model vendor's host is refused for the agent  [B21]" "$ROOT/sandbox" allow api.anthropic.com --reason "direct"
refuse "an IP address is refused" "$ROOT/sandbox" allow 10.0.0.1 --reason "internal"
refuse "an --until date in the past is refused" "$ROOT/sandbox" allow old.example.com --reason "x" --until 2001-01-01
"$ROOT/sandbox" allow --preset github-downloads --reason "release tarballs" >/dev/null 2>&1 || fail "allow --preset failed"
check  "the preset's hosts reach the session's list" grep -q "githubusercontent.com" "$proxy/agent.domains"
"$ROOT/sandbox" allow db.example.com:8443 --reason "staging" --until 2099-12-31 >/dev/null 2>&1 || fail "allow host:port failed"
check  "a host:port rule reaches extra.conf" grep -q "db.example.com" "$proxy/extra.conf"
says   "an https URL: only the host name is enforced" "only the host name is enforced" "$ROOT/sandbox" allow --url https://files.example.com/pkg/ --reason "tarballs"
"$ROOT/sandbox" allow --url http://mirror.example.com/debian/ --reason "plaintext mirror" >/dev/null 2>&1 || fail "allow --url http failed"
check  "a plaintext URL rule reaches extra.conf" grep -q "url_regex" "$proxy/extra.conf"
check  "the running session's proxy was told to re-read" grep -q "^exec${tab}$s-proxy${tab}squid${tab}-k${tab}reconfigure" "$log"
"$ROOT/sandbox" deny docs.example.com >/dev/null 2>&1 || fail "deny failed"
if grep -qx "docs.example.com" "$proxy/agent.domains"; then fail "deny left the host on the list"; else pass "deny takes the host off the session's list"; fi

# A session started now has a plaintext rule. Port 80 as a whole stays closed:
# the rule opens only its own path prefix.
: > "$log"
"$ROOT/sandbox" run "$T/src" </dev/null >/dev/null 2>&1 || fail "second run failed"
check "a plaintext rule does not open port 80 as a whole" grep -qE "^create${tab}--name${tab}asb-src-[0-9a-f]{6}-proxy${tab}.*SANDBOX_ALLOW_HTTP=0" "$log"
second="$(for d in "$SANDBOX_STATE_DIR"/asb-*; do [ "${d##*/}" = "$s" ] || printf '%s' "${d##*/}"; done)"
SANDBOX_SESSION="$second" "$ROOT/sandbox" destroy >/dev/null 2>&1

# --- export through the real export.sh, then push ----------------------------------------
git clone --quiet "$T/src" "$T/work"
git -C "$T/work" checkout --quiet -b agent/test
printf 'more\n' >> "$T/work/README.md"
git -C "$T/work" commit --quiet -am "a change made in the sandbox"
tip="$(git -C "$T/work" rev-parse HEAD)"
git -C "$T/work" bundle create --quiet "$T/agent.bundle" agent/test

status=0
out="$(FAKE_PODMAN_BUNDLE="$T/agent.bundle" "$ROOT/sandbox" export --out "$T/exported" 2>&1)" || status=$?
status_file="$T/exported/$s/export.status"
check "the real export.sh made the repository" test -d "$T/exported/$s/repo.git"
check "it holds the commit from the bundle" test "$(git --git-dir="$T/exported/$s/repo.git" rev-parse refs/heads/agent/test)" = "$tip"
for key in SCAN ATTRIBUTION TIP BRANCH ORIGIN_URL; do
  check "export.status has $key" grep -q "^$key=" "$status_file"
done
check "TIP is the exported commit" grep -qx "TIP=$tip" "$status_file"
if command -v gitleaks >/dev/null 2>&1; then
  check "with gitleaks installed a clean export exits 0" test "$status" -eq 0
  "$ROOT/sandbox" push >/dev/null 2>&1 || fail "push failed"
  check "push delivered the branch" test "$(git --git-dir="$T/remote.git" rev-parse refs/heads/agent/test)" = "$tip"
else
  check "without gitleaks the export exits 2 (needs a human)" test "$status" -eq 2
  check "and records that no scan ran" grep -qx "SCAN=not-run" "$status_file"
  says  "so push refuses" "secret scan did not pass" "$ROOT/sandbox" push
  check "and nothing was pushed" test -z "$(git --git-dir="$T/remote.git" branch --list)"
fi

"$ROOT/sandbox" destroy >/dev/null 2>&1 || fail "destroy failed"
finish
