#!/usr/bin/env bash
# `run --git-token`: a git token for one session, held by git's credential
# cache in memory, used by this host's clone, push and pr, and gone at
# destroy. Where it goes and where it never goes.  [logical B15]
#
# The repository is "on GitHub" by address only: git's url.insteadOf sends
# that address to a bare repository here, so the clone and the push are real
# while no network is touched. The cache is git's own, so the daemon it
# starts is real too; the test tells it to exit when done.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup
make_root
export SANDBOX_TEST_ANTHROPIC_KEY="sk-ant-test-0123456789"

URL=https://github.com/example/private.git
TOKEN="github_pat_SESSION-TOKEN-0123456789abcdef"
make_repo "$T/src"
git clone --quiet --bare "$T/src" "$T/remote.git"
git config --global url."$T/remote.git".insteadOf "$URL"
log="$FAKE_PODMAN_LOG"

# --- refusals, before anything is made --------------------------------------------
says "a path needs no token" "needs no token" bash -c "printf '%s\n' '$TOKEN' | '$ROOT/sandbox' run '$T/src' --git-token"
says "an ssh address needs no token" "needs no token" bash -c "printf '%s\n' '$TOKEN' | '$ROOT/sandbox' run git@github.com:example/private.git --git-token"
says "without a token the run is refused" "needs a git token" "$ROOT/sandbox" run "$URL" --git-token </dev/null
says "something that is not a token is refused" "does not look like a token" \
  bash -c "printf 'not a token\n' | '$ROOT/sandbox' run '$URL' --git-token"
check "a refused run leaves no session behind" test -z "$(only_session)"
if grep -qE $'^(create|run)\t' "$log"; then fail "a refused run created something"; else pass "a refused run created nothing"; fi

# --- a session with a token ------------------------------------------------------
: > "$log"
out="$(printf '%s\n' "$TOKEN" | "$ROOT/sandbox" run "$URL" --git-token --branch agent/test 2>&1)" || fail "run --git-token failed: $out"
s="$(only_session)"
dir="$SANDBOX_STATE_DIR/$s"
socket="$dir/git-credential"
check "state records that the session has a token" grep -qx "GIT_TOKEN=1" "$dir/state"
check "the cache's socket is in the session directory" test -S "$socket"
held="$(printf 'protocol=https\nhost=github.com\n' | git credential-cache --socket="$socket" get | sed -n 's/^password=//p')"
check "git's credential cache holds the token" test "$held" = "$TOKEN"
check "... for the user name GitHub takes" test "$(printf 'protocol=https\nhost=github.com\n' | git credential-cache --socket="$socket" get | sed -n 's/^username=//p')" = x-access-token
check "the clone happened" grep -qx "ORIGIN_URL=$URL" "$dir/state"
if grep -rqF "$TOKEN" "$SANDBOX_STATE_DIR" "$SANDBOX_CONFIG_DIR" "$T/home" 2>/dev/null; then fail "the token is in a file"; else pass "the token is in no file"; fi
if grep -qF "$TOKEN" "$log"; then fail "the token is on a podman command line"; else pass "the token is on no podman command line"; fi
if grep -rqF "$TOKEN" "$FAKE_PODMAN_STATE/stdin" 2>/dev/null; then fail "the token went into a container"; else pass "the token went into no container"; fi
case "$out" in *"$TOKEN"*) fail "the token was printed" ;; *) pass "the token is not printed" ;; esac
case "$out" in *"held in memory"*"never put in a container"*) pass "run says where the token is held" ;; *) fail "no word on the token: $out" ;; esac

# --- push with it ---------------------------------------------------------------------
git clone --quiet "$T/src" "$T/work"
git -C "$T/work" checkout --quiet -b agent/test
printf 'more\n' >> "$T/work/README.md"
git -C "$T/work" commit --quiet -am "agent's change"
tip="$(git -C "$T/work" rev-parse HEAD)"
git -C "$T/work" bundle create --quiet "$T/agent.bundle" agent/test
FAKE_PODMAN_BUNDLE="$T/agent.bundle" "$ROOT/sandbox" export --out "$T/exported" >/dev/null 2>&1 || fail "export failed"
out="$("$ROOT/sandbox" push 2>&1)" || fail "push failed: $out"
case "$out" in *"with the session's token"*) pass "push says it uses the session's token" ;; *) fail "push: $out" ;; esac
check "push sends the branch to the recorded address" test "$(git --git-dir="$T/remote.git" rev-parse refs/heads/agent/test)" = "$tip"

# pr hands the token to gh, and to nothing else.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<STANDIN
#!/usr/bin/env bash
printf '%s\n' "\${GH_TOKEN:-unset}" > "$T/gh.token"
STANDIN
chmod +x "$T/bin/gh"
"$ROOT/sandbox" pr >/dev/null 2>&1 || fail "pr failed"
check "pr gives gh the session's token in its environment" test "$(cat "$T/gh.token")" = "$TOKEN"
rm -f "$T/bin/gh"

# --- destroy forgets it ---------------------------------------------------------------
"$ROOT/sandbox" destroy >/dev/null 2>&1 || fail "destroy failed"
check "the socket is gone with the session" test ! -e "$socket"
if printf 'protocol=https\nhost=github.com\n' | git credential-cache --socket="$socket" get 2>/dev/null | grep -q .; then
  fail "the cache still answers after destroy"
else
  pass "the cache no longer answers after destroy"
fi

# --- without the option, nothing of this exists ---------------------------------------
: > "$log"
"$ROOT/sandbox" run "$T/src" </dev/null >/dev/null 2>&1 || fail "plain run failed"
s="$(only_session)"
check "a plain session records no token" grep -qx "GIT_TOKEN=0" "$SANDBOX_STATE_DIR/$s/state"
check "a plain session has no cache socket" test ! -e "$SANDBOX_STATE_DIR/$s/git-credential"

finish
