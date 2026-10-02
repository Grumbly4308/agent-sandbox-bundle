#!/usr/bin/env bash
# The agent wrote the repository the bundle comes from. Its .git/config, its
# hooks, its ref names, its .gitmodules and malformed objects must do nothing
# on the host (reference finding C1).

# shellcheck source=tests/export/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MARK=$WORK/hostile-code-ran
fake_gitleaks 8.24.2 0

# Every file under the given hooks directory becomes a script that leaves a
# marker file behind.
plant_hooks() {
  local hook
  mkdir -p "$1"
  for hook in pre-commit post-commit post-checkout post-merge post-rewrite post-index-change \
    reference-transaction pre-auto-gc update pre-receive post-receive post-update fsmonitor-watchman; do
    printf '#!/bin/sh\ntouch "%s"\n' "$MARK" >"$1/$hook"
    chmod +x "$1/$hook"
  done
}

# --- a hostile .git/config and hooks in the source repository --------------
SRC=$WORK/src
new_repo "$SRC"
echo "more" >>"$SRC/src/index.js"
commit_all "$SRC" "A change"
TIP=$(git -C "$SRC" rev-parse HEAD)
plant_hooks "$SRC/.git/hooks"
plant_hooks "$SRC/evil-hooks"
git -C "$SRC" config core.fsmonitor "touch $MARK; false"
git -C "$SRC" config core.pager "touch $MARK; cat"
git -C "$SRC" config core.hooksPath "$SRC/evil-hooks"
git -C "$SRC" config core.sshCommand "touch $MARK"
git -C "$SRC" config diff.external "touch $MARK"
git -C "$SRC" config credential.helper "!touch $MARK"
make_bundle "$SRC" "$WORK/hostile.bundle"
rm -f "$MARK" # making the fixture runs those hooks; only what export does counts

next_session
# The caller's environment is hostile too: it points git at the agent's
# repository and injects settings. None of it may be inherited.
GIT_DIR=$SRC/.git GIT_WORK_TREE=$SRC \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0="touch $MARK; false" \
  GIT_EXTERNAL_DIFF="touch $MARK" GIT_PAGER="touch $MARK" GIT_SSH_COMMAND="touch $MARK" \
  run_export "$WORK/hostile.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 0
assert_missing "$MARK"
assert_status "$SESSION_DIR" TIP "$TIP"
REPO=$SESSION_DIR/repo.git
for key in core.fsmonitor core.pager core.hooksPath core.sshCommand diff.external credential.helper; do
  if clean_git "$REPO" config --local --get "$key" >/dev/null; then
    fail "$key from the agent's repository reached the clean repository"
  fi
done
assert_missing "$REPO/hooks"
if grep -q '^GIT_DIR=\|^GIT_WORK_TREE=\|^GIT_EXTERNAL_DIFF=\|^GIT_SSH_COMMAND=\|^GIT_PAGER=' "$WORK/gitleaks.env"; then
  fail "the caller's GIT_* variables reached gitleaks"
fi
assert_eq "$(grep -c '^GIT_CONFIG_KEY_0=core.fsmonitor$' "$WORK/gitleaks.env")" 0 "injected GIT_CONFIG_KEY_0 reaching gitleaks"
ok "a hostile .git/config, hooks and GIT_* environment do nothing, and none reaches the clean repository"

# --- a .gitmodules with an ext:: URL, which would run a command if followed -
SUB=$WORK/submodule
new_repo "$SUB"
printf '[submodule "lib"]\n\tpath = vendor/lib\n\turl = ext::sh -c "touch %s"\n' "$MARK" >"$SUB/.gitmodules"
git -C "$SUB" add .gitmodules
git -C "$SUB" update-index --add --cacheinfo "160000,$BASE,vendor/lib"
git -C "$SUB" commit -q -m "Add a submodule"
BASE_SUB=$(git -C "$SUB" rev-parse HEAD~1)
make_bundle "$SUB" "$WORK/submodule.bundle"
next_session
run_export "$WORK/submodule.bundle" "$WORK/out" "$SESSION" "$BASE_SUB" work
assert_rc 0
assert_missing "$MARK"
assert_has "Symlinks and submodules: 1 added or changed"
assert_has "submodule  vendor/lib at commit $BASE, from ext::sh -c"
assert_has "Git plumbing in the tree: 1 changed"
assert_missing "$SESSION_DIR/repo.git/modules"
ok "a .gitmodules with an ext:: URL is listed and nothing is fetched or run"

# --- a bundle without the branch the host asked for ------------------------
# (A fresh fixture: any git command in $SRC runs the hooks planted above.)
REFS=$WORK/refs
new_repo "$REFS"
echo "more" >>"$REFS/src/index.js"
commit_all "$REFS" "A change"
TIP=$(git -C "$REFS" rev-parse HEAD)
git -C "$REFS" branch other
make_bundle "$REFS" "$WORK/other.bundle" other
next_session
run_export "$WORK/other.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 1
assert_has "does not contain the branch work"
assert_missing "$SESSION_DIR/repo.git"
assert_missing "$SESSION_DIR/export.status"
ok "a bundle that lacks the branch is refused"

# --- ref names shaped like options -----------------------------------------
# Git itself lets a ref be called this. Nothing may ever pass it to a command.
printf '#!/bin/sh\ntouch "%s"\n' "$MARK" >"$WORK/evil.sh"
chmod +x "$WORK/evil.sh"
EVIL_REF="refs/heads/--upload-pack=$WORK/evil.sh"
git -C "$REFS" update-ref "$EVIL_REF" "$TIP"
git -C "$REFS" bundle create -q "$WORK/evil-only.bundle" "$EVIL_REF"
next_session
run_export "$WORK/evil-only.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 1
assert_has "does not contain the branch work"
assert_missing "$MARK"

# The same name next to the real branch: the branch is exported, the other
# ref is never created.
git -C "$REFS" bundle create -q "$WORK/evil-both.bundle" work "$EVIL_REF"
next_session
run_export "$WORK/evil-both.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 0
assert_missing "$MARK"
assert_eq "$(clean_git "$SESSION_DIR/repo.git" for-each-ref --format='%(refname)')" refs/heads/work "refs in repo.git"

# A hand-written bundle header whose ref name is nothing but an option. git
# may refuse the file or ignore the name; either way nothing runs and no ref
# other than the host's is written.
header_bytes=0
while IFS= read -r line; do
  header_bytes=$((header_bytes + ${#line} + 1))
  if [ -z "$line" ]; then break; fi
done < <(LC_ALL=C sed -n '1,/^$/p' "$WORK/evil-both.bundle")
{
  printf '# v2 git bundle\n%s --upload-pack=%s\n%s refs/heads/work\n\n' "$TIP" "$WORK/evil.sh" "$TIP"
  tail -c "+$((header_bytes + 1))" "$WORK/evil-both.bundle"
} >"$WORK/evil-header.bundle"
next_session
run_export "$WORK/evil-header.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_missing "$MARK"
case $RC in
  0) assert_eq "$(clean_git "$SESSION_DIR/repo.git" for-each-ref --format='%(refname)')" refs/heads/work "refs in repo.git" ;;
  1) assert_missing "$SESSION_DIR/repo.git" ;;
  *) fail "unexpected exit status $RC for a bundle with an option as a ref name" ;;
esac
ok "ref names that look like options are never used: only the host's branch name is"

# --- objects git considers malformed ---------------------------------------
# git 2.39 does not check objects that arrive in a bundle, even with
# fetch.fsckObjects=true. Export must.
BAD=$WORK/bad
new_repo "$BAD"
tree=$(git -C "$BAD" rev-parse "HEAD^{tree}")
bad_commit=$(printf 'tree %s\nparent %s\nauthor Nobody nobody@example.com 1700000000 +0000\ncommitter Test Human <human@example.com> 1700000000 +0000\n\nNo angle brackets around the address\n' \
  "$tree" "$BASE" | git -C "$BAD" hash-object -t commit -w --literally --stdin)
git -C "$BAD" update-ref refs/heads/work "$bad_commit"
make_bundle "$BAD" "$WORK/bad.bundle"
next_session
run_export "$WORK/bad.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 1
assert_has "git fsck --strict"
assert_missing "$SESSION_DIR/repo.git"
assert_missing "$SESSION_DIR/export.status"

# A NUL byte in a commit message hides whatever follows it from most tools.
nul_commit=$(printf 'tree %s\nparent %s\nauthor Test Human <human@example.com> 1700000000 +0000\ncommitter Test Human <human@example.com> 1700000000 +0000\n\nSubject\0\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' \
  "$tree" "$BASE" | git -C "$BAD" hash-object -t commit -w --literally --stdin)
git -C "$BAD" update-ref refs/heads/work "$nul_commit"
make_bundle "$BAD" "$WORK/nul.bundle"
next_session
run_export "$WORK/nul.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 1
assert_has "nulInCommit"
assert_missing "$SESSION_DIR/repo.git"

# A file that is not a bundle at all.
printf 'this is not a bundle\n' >"$WORK/garbage.bundle"
next_session
run_export "$WORK/garbage.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 1
assert_missing "$SESSION_DIR/repo.git"
assert_eq "$(ls -A "$TMPDIR")" "" "scratch left behind in TMPDIR"
ok "malformed objects and files that are not bundles are refused, and no repository is left"

echo "test-hostile-git: all passed"
