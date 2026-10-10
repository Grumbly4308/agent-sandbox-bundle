#!/usr/bin/env bash
# Two things the agent can try on the person reading the export:
#   - terminal control sequences in commit messages, file names and file
#     contents (B32): they must not reach the terminal;
#   - rewriting history below the commit the session started from, so that a
#     change hides in what looks like old history: export must say so, show
#     everything, and not call the result clean.

# shellcheck source=tests/export/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fake_gitleaks 8.24.2 0

ESC=$(printf '\033')
BEL=$(printf '\007')
CR=$(printf '\r')
C1_CSI=$(printf '\302\233')   # U+009B, which a terminal reads like ESC [
NL='
'

# --- control characters -----------------------------------------------------
SRC=$WORK/src
new_repo "$SRC"
# A directory whose name clears the screen and then starts a line of its own
# that looks like a line of export's report.
EVIL_DIR="pkg${ESC}[2J${NL}secret scan:  passed"
mkdir "$SRC/$EVIL_DIR"
printf '{"name": "x"}\n' >"$SRC/$EVIL_DIR/package.json"
printf 'red %s[31m text, clipboard %s]52;c;ZXZpbA==%s, bare c1 \233 2J, over%swritten\n' "$ESC" "$ESC" "$BEL" "$CR" >"$SRC/src/notes.txt"
printf 'backspaces: visible\b\b\b\b\b\b\bHIDDEN \177 nul:\0:end\n' >>"$SRC/src/notes.txt"
git -C "$SRC" add -A
git -C "$SRC" commit -q -F - <<EOF
café ✓ ${ESC}[1;31mSUBJECT${ESC}[0m ${ESC}]52;c;ZXZpbA==${BEL} ${C1_CSI}2J tail${CR}overwritten
EOF
make_bundle "$SRC" "$WORK/control.bundle"

next_session
run_export "$WORK/control.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 0
for forbidden in "$ESC" "$BEL" "$CR" "$C1_CSI" "$(printf '\233')" "$(printf '\b')" "$(printf '\177')"; do
  assert_lacks "$forbidden"
done
# What is left is the text without its controls, and UTF-8 is untouched.
assert_has "café ✓ [1;31mSUBJECT[0m ]52;c;ZXZpbA== 2J tailoverwritten"
assert_has "+red [31m text, clipboard ]52;c;ZXZpbA==, bare c1 ? 2J, overwritten"
assert_has "nul::end"
# The file name stays on one line, in the listing and in the diff header.
assert_has "  A  pkg?[2J?secret scan:  passed/package.json"
assert_eq "$(printf '%s\n' "$OUTPUT" | grep -c '^secret scan:')" 1 "lines starting with 'secret scan:'"
assert_has "secret scan:  passed"
ok "ESC, OSC 52, CR, C1 and other control characters are stripped; UTF-8 text is kept"

# A very long line is cut, and said to be cut.
LONG=$WORK/long
new_repo "$LONG"
awk 'BEGIN { for (i = 0; i < 5000; i++) printf "x"; print "END-OF-LONG-LINE" }' >"$LONG/src/long.txt"
commit_all "$LONG" "A long line"
make_bundle "$LONG" "$WORK/long.bundle"
next_session
run_export "$WORK/long.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 0
assert_lacks "END-OF-LONG-LINE"
assert_has "[line cut at 2000 bytes]"
ok "an over-long line is cut and marked"

# --- history rewritten below the starting commit ---------------------------
# The agent amends the commit the session started from (its id changes) and
# adds a commit on top. The host still holds the old id.
REWRITE=$WORK/rewrite
new_repo "$REWRITE"
printf 'console.log("slipped into old history")\n' >"$REWRITE/src/index.js"
git -C "$REWRITE" add -A
git -C "$REWRITE" commit -q --amend -m "Start of the project"
printf 'harmless\n' >"$REWRITE/src/new.txt"
commit_all "$REWRITE" "A harmless-looking change"
TIP=$(git -C "$REWRITE" rev-parse HEAD)
make_bundle "$REWRITE" "$WORK/rewrite.bundle"

next_session
run_export "$WORK/rewrite.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 2
assert_has "HISTORY WAS REWRITTEN"
assert_status "$SESSION_DIR" HISTORY rewritten
assert_status "$SESSION_DIR" SCAN passed
assert_status "$SESSION_DIR" TIP "$TIP"
# Nothing is hidden: both commits are listed, and the diff is against an
# empty repository, so the amended file shows in full.
assert_has "==== Commits (2) ===="
assert_has "Start of the project"
assert_has '+console.log("slipped into old history")'
assert_has "+harmless"
assert_has "  A  package-lock.json"
assert_has "NEEDS A HUMAN"
# The scan covers the whole history too, not a range from a commit that is
# no longer there.
assert_gitleaks_arg "--log-opts=$TIP"
ok "a base that is not an ancestor gives status 2, HISTORY=rewritten and a diff against nothing"

# A base that exists in the bundle but on another line of history.
SIDE=$WORK/side
new_repo "$SIDE"
git -C "$SIDE" checkout -q -b elsewhere
echo "side" >"$SIDE/side.txt"
commit_all "$SIDE" "On a side branch"
SIDE_BASE=$(git -C "$SIDE" rev-parse HEAD)
git -C "$SIDE" checkout -q work
echo "main" >"$SIDE/main.txt"
commit_all "$SIDE" "On the session branch"
git -C "$SIDE" bundle create -q "$WORK/side.bundle" work elsewhere
next_session
run_export "$WORK/side.bundle" "$WORK/out" "$SESSION" "$SIDE_BASE" work
assert_rc 2
assert_status "$SESSION_DIR" HISTORY rewritten
assert_eq "$(clean_git "$SESSION_DIR/repo.git" for-each-ref --format='%(refname)')" refs/heads/work "refs in repo.git"
ok "a base on another branch is not accepted as the starting point either"

# No new commits at all is not an error.
EMPTY=$WORK/empty
new_repo "$EMPTY"
make_bundle "$EMPTY" "$WORK/empty.bundle"
next_session
run_export "$WORK/empty.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 0
assert_has "No new commits on this branch."
assert_has "no changed path matches a pattern"
ok "a branch with no new commits exports as clean"

echo "test-output-and-history: all passed"
