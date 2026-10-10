#!/usr/bin/env bash
# An ordinary change exports cleanly, gitleaks is called the way B27 says, the
# three outcomes of the scan are told apart, and bad arguments, oversized
# bundles and directories that are not ours are refused.

# shellcheck source=tests/export/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC=$WORK/src
new_repo "$SRC"
printf 'console.log("hello, world")\n' >"$SRC/src/index.js"
commit_all "$SRC" "Greet the world"
TIP=$(git -C "$SRC" rev-parse HEAD)
make_bundle "$SRC" "$WORK/change.bundle"

# --- a normal change, current gitleaks ------------------------------------
next_session
fake_gitleaks 8.24.2 0
run_export "$WORK/change.bundle" "$WORK/out" "$SESSION" "$BASE" work https://example.com/demo.git
assert_rc 0
assert_status "$SESSION_DIR" SCAN passed
assert_status "$SESSION_DIR" ATTRIBUTION clean
assert_status "$SESSION_DIR" TIP "$TIP"
assert_status "$SESSION_DIR" BRANCH work
assert_status "$SESSION_DIR" ORIGIN_URL https://example.com/demo.git
assert_status "$SESSION_DIR" HISTORY intact
assert_has "Greet the world"
assert_has '+console.log("hello, world")'
assert_has "RUNS LATER — read this first"
assert_has "any source file can run later too"
ok "a normal change exports with status 0"

# The result is a bare repository with one branch and nothing checked out.
REPO=$SESSION_DIR/repo.git
assert_eq "$(clean_git "$REPO" rev-parse --is-bare-repository)" true "repo.git is bare"
assert_eq "$(clean_git "$REPO" for-each-ref --format='%(refname) %(objectname)')" "refs/heads/work $TIP" "refs in repo.git"
assert_eq "$(clean_git "$REPO" symbolic-ref HEAD)" refs/heads/work "HEAD of repo.git"
assert_missing "$REPO/hooks"
assert_missing "$SESSION_DIR/src"
assert_eq "$(names_in "$SESSION_DIR")" ".agent-sandbox-export export.status repo.git " "content of the session directory"
assert_eq "$(ls -A "$TMPDIR")" "" "scratch left behind in TMPDIR"
ok "repo.git is bare, has one branch, and no scratch is left behind"

# gitleaks: newer command form, shipped configuration, every in-tree
# suppression off, only the exported commits.
assert_eq "$(awk 'NR == 1' "$WORK/gitleaks.args")" git "gitleaks subcommand"
assert_eq "$(awk 'END { print }' "$WORK/gitleaks.args")" "$REPO" "gitleaks source"
assert_eq "$(cd "$(dirname "$(gitleaks_arg_after --config)")" && pwd)/gitleaks.toml" "$ROOT/policy/gitleaks.toml" "gitleaks --config"
assert_gitleaks_arg --ignore-gitleaks-allow
assert_gitleaks_arg --no-banner
assert_gitleaks_arg --redact
assert_gitleaks_arg "--log-opts=$BASE..$TIP"
IGNORE=$(gitleaks_arg_after --gitleaks-ignore-path)
case $IGNORE in
  "$TMPDIR"/*) ;;
  *) fail "--gitleaks-ignore-path is not a file of export's own: $IGNORE" ;;
esac
case $(cat "$WORK/gitleaks.cwd") in
  "$TMPDIR"/*) ;;
  *) fail "gitleaks was not run from a scratch directory" ;;
esac
grep -qx 'GIT_CONFIG_GLOBAL=/dev/null' "$WORK/gitleaks.env" || fail "gitleaks' git would read the user's configuration"
grep -qx 'GIT_CONFIG_NOSYSTEM=1' "$WORK/gitleaks.env" || fail "gitleaks' git would read the system configuration"
grep -q '^GIT_CONFIG_VALUE_[0-9]*=/dev/null$' "$WORK/gitleaks.env" || fail "gitleaks' git did not get the safe settings"
if grep -q '^GIT_DIR=' "$WORK/gitleaks.env"; then fail "GIT_DIR reached gitleaks"; fi
ok "gitleaks gets the shipped configuration, no in-tree suppressions, and the commit range"

# --- older gitleaks: `detect --source` -------------------------------------
next_session
fake_gitleaks v8.18.4 0
run_export "$WORK/change.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 0
assert_eq "$(awk 'NR <= 3' "$WORK/gitleaks.args" | tr '\n' ' ')" "detect --source $SESSION_DIR/repo.git " "older gitleaks command form"
assert_gitleaks_arg --ignore-gitleaks-allow
assert_gitleaks_arg "--log-opts=$BASE..$TIP"
assert_status "$SESSION_DIR" ORIGIN_URL ""
ok "gitleaks older than 8.19 is called as detect --source"

# --- gitleaks reports a finding --------------------------------------------
next_session
fake_gitleaks 8.24.2 1
run_export "$WORK/change.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 2
assert_status "$SESSION_DIR" SCAN failed
assert_has "push and pr will refuse"
ok "gitleaks exiting 1 gives SCAN=failed and status 2"

# --- gitleaks is not installed ---------------------------------------------
next_session
no_gitleaks
run_export "$WORK/change.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 2
assert_status "$SESSION_DIR" SCAN not-run
assert_has "NO secret scan was run"
assert_has "push and pr will refuse"
ok "no gitleaks gives SCAN=not-run and status 2, with no substitute scan"

# --- exporting again into our own directory replaces the result ------------
fake_gitleaks 8.24.2 0
run_export "$WORK/change.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 0
assert_status "$SESSION_DIR" SCAN passed
ok "a second export into the same session directory replaces the first"

# --- a directory that is not ours is refused and left alone ----------------
next_session
mkdir -p "$SESSION_DIR/repo.git"
echo "mine" >"$SESSION_DIR/notes.txt"
run_export "$WORK/change.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 1
assert_has "was not made by export"
assert_eq "$(cat "$SESSION_DIR/notes.txt")" mine "the foreign file"
assert_missing "$SESSION_DIR/export.status"
assert_missing "$SESSION_DIR/repo.git/HEAD"
ok "an existing foreign directory at the output path is refused"

# --- the size limit ---------------------------------------------------------
next_session
SANDBOX_EXPORT_MAX_BYTES=100 run_export "$WORK/change.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 1
assert_has "more than the limit"
assert_missing "$SESSION_DIR"
ok "a bundle over SANDBOX_EXPORT_MAX_BYTES is refused"

# --- arguments --------------------------------------------------------------
next_session
for bad_branch in "--upload-pack=touch" "-x" "a..b" "a b" 'a;b' "refs/heads/x.lock" ".hidden" "x/"; do
  run_export "$WORK/change.bundle" "$WORK/out" "$SESSION" "$BASE" "$bad_branch"
  assert_rc 1
  assert_has "branch name is not valid"
done
for bad_session in "../escape" "a/b" "-rf" ".." ""; do
  run_export "$WORK/change.bundle" "$WORK/out" "$bad_session" "$BASE" work
  assert_rc 1
  assert_has "session name is not valid"
done
for bad_base in HEAD "work~1" "${BASE%?}" "${BASE}0" "--all" "$(printf '%s' "$BASE" | tr 'a-f' 'A-F')X"; do
  run_export "$WORK/change.bundle" "$WORK/out" "$SESSION" "$bad_base" work
  assert_rc 1
  assert_has "base commit must be"
done
run_export "$WORK/change.bundle" "$WORK/out" "$SESSION" "$BASE"
assert_rc 1
assert_has "usage:"
run_export "$WORK/nothing.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 1
assert_missing "$WORK/out/escape"
assert_missing "$SESSION_DIR"
assert_eq "$(ls -A "$TMPDIR")" "" "scratch left behind in TMPDIR"
ok "branch, session and base-commit arguments are validated before use"

echo "test-clean-export: all passed"
