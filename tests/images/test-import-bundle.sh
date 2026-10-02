#!/usr/bin/env bash
# sandbox-import and sandbox-bundle, run here against a temporary workspace:
# bundle in -> commit -> bundle out -> import again. Also: import refuses a
# non-empty target and a damaged bundle, and a hostile .git/config does not
# get a program run while the export bundle is written.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

import="$root/images/agent/sandbox-import"
bundle="$root/images/agent/sandbox-bundle"

# Keep the tester's own git configuration out of it.
export HOME="$scratch/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
id=(-c user.name=Host -c user.email=host@example.invalid)

branch="asb/work"

# --- A host-side repository, bundled the way ./sandbox does it --------------
git init --quiet --initial-branch=main "$scratch/src"
echo one >"$scratch/src/a.txt"
git -C "$scratch/src" add a.txt
git -C "$scratch/src" "${id[@]}" commit --quiet -m "first"
echo two >"$scratch/src/b.txt"
git -C "$scratch/src" add b.txt
git -C "$scratch/src" "${id[@]}" commit --quiet -m "second"
git -C "$scratch/src" branch "$branch"
base="$(git -C "$scratch/src" rev-parse HEAD)"
git -C "$scratch/src" bundle create --quiet "$scratch/in.bundle" HEAD "refs/heads/$branch"

leftovers() { find /tmp -maxdepth 1 -name 'sandbox-import.*' 2>/dev/null | wc -l; }
before="$(leftovers)"

# --- Import ------------------------------------------------------------------
ws="$scratch/ws1"
mkdir -p "$ws"
if SANDBOX_WORKSPACE_FOR_TESTS="$ws" GIT_AUTHOR_NAME="Ada Host" GIT_AUTHOR_EMAIL="ada@example.invalid" \
  "$import" "$branch" <"$scratch/in.bundle" >"$scratch/import.out" 2>"$scratch/import.err"; then
  pass "import: succeeds"
else
  fail "import: failed: $(cat "$scratch/import.err")"
fi
repo="$ws/repo"
if [ "$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$branch" ]; then
  pass "import: $branch is checked out"
else
  fail "import: wrong branch checked out"
fi
if [ "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" = "$base" ]; then
  pass "import: tip is the host's commit"
else
  fail "import: tip differs from the host's commit"
fi
if [ "$(cat "$repo/a.txt" 2>/dev/null)" = one ] && [ "$(cat "$repo/b.txt" 2>/dev/null)" = two ]; then
  pass "import: files are checked out"
else
  fail "import: files missing from the work tree"
fi
if [ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
  pass "import: work tree is clean"
else
  fail "import: work tree is not clean"
fi
if [ "$(git -C "$repo" config --local --get user.name)" = "Ada Host" ] \
  && [ "$(git -C "$repo" config --local --get user.email)" = "ada@example.invalid" ]; then
  pass "import: identity comes from the environment"
else
  fail "import: identity not set from the environment"
fi
if [ -z "$(git -C "$repo" remote)" ]; then
  pass "import: no remote left pointing at the temporary bundle"
else
  fail "import: a remote is left behind"
fi

# With a relay address, and only then, the clone has a remote: the relay.
mkdir -p "$scratch/ws-relay"
if SANDBOX_WORKSPACE_FOR_TESTS="$scratch/ws-relay" "$import" "$branch" http://gitrelay:8081/repo.git <"$scratch/in.bundle" >/dev/null 2>&1 &&
  [ "$(git -C "$scratch/ws-relay/repo" remote get-url origin 2>/dev/null)" = http://gitrelay:8081/repo.git ] &&
  [ "$(git -C "$scratch/ws-relay/repo" remote | wc -l)" -eq 1 ]; then
  pass "import: with a relay address, origin is the relay and nothing else"
else
  fail "import: the relay address did not become the one remote"
fi
if [ "$(mode_of "$repo")" = 700 ]; then
  pass "import: repo directory is 0700"
else
  fail "import: repo mode is $(mode_of "$repo")"
fi
if [ "$(leftovers)" = "$before" ]; then
  pass "import: temporary file deleted"
else
  fail "import: left a file in /tmp"
fi

# --- Import with no identity passed: nothing is made up -----------------------
ws2="$scratch/ws2"
mkdir -p "$ws2/repo"
if SANDBOX_WORKSPACE_FOR_TESTS="$ws2" "$import" "$branch" <"$scratch/in.bundle" >/dev/null 2>&1; then
  pass "import: works into an existing empty directory"
else
  fail "import: failed into an existing empty directory"
fi
if git -C "$ws2/repo" config --local --get user.name >/dev/null \
  || git -C "$ws2/repo" config --local --get user.email >/dev/null; then
  fail "import: invented an identity"
else
  pass "import: sets no identity when none is passed"
fi

# --- Import refuses a non-empty target ----------------------------------------
tip_before="$(git -C "$repo" rev-parse HEAD)"
if SANDBOX_WORKSPACE_FOR_TESTS="$ws" "$import" "$branch" <"$scratch/in.bundle" >/dev/null 2>"$scratch/again.err"; then
  fail "import: accepted a non-empty target"
else
  pass "import: refuses a non-empty target"
fi
check "import: says why" grep -q 'not empty' "$scratch/again.err"
if [ "$(git -C "$repo" rev-parse HEAD)" = "$tip_before" ]; then
  pass "import: refused target is untouched"
else
  fail "import: refused target changed"
fi

ws3="$scratch/ws3"
mkdir -p "$ws3/repo"
echo stray >"$ws3/repo/.hidden"
if SANDBOX_WORKSPACE_FOR_TESTS="$ws3" "$import" "$branch" <"$scratch/in.bundle" >/dev/null 2>&1; then
  fail "import: a hidden file did not count as non-empty"
else
  pass "import: a hidden file counts as non-empty"
fi

# --- Import refuses a damaged bundle and bad arguments --------------------------
ws4="$scratch/ws4"
mkdir -p "$ws4"
head -c 200 "$scratch/in.bundle" >"$scratch/cut.bundle"
if SANDBOX_WORKSPACE_FOR_TESTS="$ws4" "$import" "$branch" <"$scratch/cut.bundle" >/dev/null 2>&1; then
  fail "import: accepted a truncated bundle"
else
  pass "import: refuses a truncated bundle"
fi
if [ -z "$(ls -A "$ws4/repo" 2>/dev/null)" ]; then
  pass "import: nothing unpacked from a bad bundle"
else
  fail "import: bad bundle left files"
fi
if [ "$(leftovers)" = "$before" ]; then
  pass "import: temporary file deleted after a failure"
else
  fail "import: failure left a file in /tmp"
fi
if SANDBOX_WORKSPACE_FOR_TESTS="$scratch/ws5" "$import" "--upload-pack=x" <"$scratch/in.bundle" >/dev/null 2>&1; then
  fail "import: accepted a branch name starting with a dash"
else
  pass "import: refuses a branch name starting with a dash"
fi
if SANDBOX_WORKSPACE_FOR_TESTS="$scratch/ws5" "$import" <"$scratch/in.bundle" >/dev/null 2>&1; then
  fail "import: ran without a branch argument"
else
  pass "import: needs exactly one argument"
fi

# --- The agent commits; bundle out ---------------------------------------------
echo three >"$repo/c.txt"
git -C "$repo" add c.txt
git -C "$repo" commit --quiet -m "agent work"
tip="$(git -C "$repo" rev-parse HEAD)"
if [ "$(git -C "$repo" log -1 --format=%an)" = "Ada Host" ]; then
  pass "commit: uses the imported identity"
else
  fail "commit: wrong author"
fi

if SANDBOX_WORKSPACE_FOR_TESTS="$ws" "$bundle" "$branch" >"$scratch/out.bundle" 2>"$scratch/bundle.err"; then
  pass "bundle: succeeds"
else
  fail "bundle: failed: $(cat "$scratch/bundle.err")"
fi
if head -n 1 "$scratch/out.bundle" | grep -q '^# v[23] git bundle$'; then
  pass "bundle: standard output starts with the bundle header"
else
  fail "bundle: something else is on standard output"
fi
git init --quiet --bare "$scratch/host.git"
check "bundle: verifies on the host side" git -C "$scratch/host.git" bundle verify "$scratch/out.bundle"
heads="$(git bundle list-heads "$scratch/out.bundle")"
if [ "$heads" = "$tip refs/heads/$branch" ]; then
  pass "bundle: holds exactly the session branch at the agent's tip"
else
  fail "bundle: unexpected contents: $heads"
fi
git -C "$scratch/host.git" fetch --quiet "$scratch/out.bundle" "refs/heads/$branch:refs/heads/$branch"
if [ "$(git -C "$scratch/host.git" rev-list --count "$base..$tip")" = 1 ]; then
  pass "bundle: the agent's commit sits on the host's base commit"
else
  fail "bundle: history does not connect to the base"
fi

# --- Round trip: the exported bundle imports again ------------------------------
ws6="$scratch/ws6"
mkdir -p "$ws6"
if SANDBOX_WORKSPACE_FOR_TESTS="$ws6" "$import" "$branch" <"$scratch/out.bundle" >/dev/null 2>&1 \
  && [ "$(git -C "$ws6/repo" rev-parse HEAD)" = "$tip" ] && [ "$(cat "$ws6/repo/c.txt")" = three ]; then
  pass "round trip: bundle -> import -> commit -> bundle -> import"
else
  fail "round trip failed"
fi

# --- Bundle: errors ---------------------------------------------------------------
if SANDBOX_WORKSPACE_FOR_TESTS="$ws" "$bundle" no-such-branch >"$scratch/none.out" 2>/dev/null; then
  fail "bundle: succeeded for a branch that does not exist"
else
  pass "bundle: fails for a branch that does not exist"
fi
if [ ! -s "$scratch/none.out" ]; then
  pass "bundle: writes nothing to standard output on failure"
else
  fail "bundle: wrote to standard output on failure"
fi
if SANDBOX_WORKSPACE_FOR_TESTS="$ws" "$bundle" "--all" >/dev/null 2>&1; then
  fail "bundle: accepted a branch name starting with a dash"
else
  pass "bundle: refuses a branch name starting with a dash"
fi
if SANDBOX_WORKSPACE_FOR_TESTS="$ws" "$bundle" >/dev/null 2>&1; then
  fail "bundle: ran without a branch argument"
else
  pass "bundle: needs exactly one argument"
fi

# --- A hostile repository configuration -------------------------------------------
# The agent wrote .git/config. Give it a file-system monitor, a hooks
# directory full of hooks and a pager, each of which leaves a marker file
# when run.
marks="$scratch/marks"
mkdir -p "$marks" "$scratch/evil-hooks"
printf '#!/bin/sh\ntouch "%s/fsmonitor"\nexit 1\n' "$marks" >"$scratch/evil-fsmonitor"
printf '#!/bin/sh\ntouch "%s/pager"\ncat\n' "$marks" >"$scratch/evil-pager"
chmod +x "$scratch/evil-fsmonitor" "$scratch/evil-pager"
for hook in pre-commit post-commit post-checkout reference-transaction post-index-change pre-auto-gc; do
  printf '#!/bin/sh\ntouch "%s/hook"\nexit 0\n' "$marks" >"$scratch/evil-hooks/$hook"
  chmod +x "$scratch/evil-hooks/$hook"
  cp "$scratch/evil-hooks/$hook" "$repo/.git/hooks/$hook"
done
git -C "$repo" config core.fsmonitor "$scratch/evil-fsmonitor"
git -C "$repo" config core.hooksPath "$scratch/evil-hooks"
git -C "$repo" config core.pager "$scratch/evil-pager"
git -C "$repo" config pager.bundle true
git -C "$repo" config pager.rev-parse true

# Control: the traps are live. Ordinary git commands in this repository do
# run them, so their silence further down means something.
git -C "$repo" status >/dev/null 2>&1 || true
if [ -e "$marks/fsmonitor" ]; then
  pass "control: the hostile fsmonitor runs under plain git"
else
  fail "control: the fsmonitor trap never fires; the checks below prove nothing"
fi
git -C "$repo" commit --quiet --allow-empty -m "trap" >/dev/null 2>&1 || true
if [ -e "$marks/hook" ]; then
  pass "control: the hostile hooks run under plain git"
else
  fail "control: the hook trap never fires; the checks below prove nothing"
fi
rm -f "${marks:?}/hook" "${marks:?}/fsmonitor" "${marks:?}/pager"
tip="$(git -C "$repo" rev-parse HEAD)"

if SANDBOX_WORKSPACE_FOR_TESTS="$ws" "$bundle" "$branch" >"$scratch/hostile.bundle" 2>"$scratch/hostile.err"; then
  pass "hostile config: bundle still succeeds"
else
  fail "hostile config: bundle failed: $(cat "$scratch/hostile.err")"
fi
if [ ! -e "$marks/hook" ]; then pass "hostile config: no hook ran"; else fail "hostile config: a hook ran during sandbox-bundle"; fi
if [ ! -e "$marks/fsmonitor" ]; then pass "hostile config: fsmonitor did not run"; else fail "hostile config: fsmonitor ran during sandbox-bundle"; fi
if [ ! -e "$marks/pager" ]; then pass "hostile config: pager did not run"; else fail "hostile config: pager ran during sandbox-bundle"; fi
if [ "$(git bundle list-heads "$scratch/hostile.bundle")" = "$tip refs/heads/$branch" ]; then
  pass "hostile config: the bundle is intact"
else
  fail "hostile config: the bundle is not what was asked for"
fi

# The switches are on the command line of every git call in the script.
check "bundle: hooks are disabled on the command line" grep -q -- '-c core.hooksPath=/dev/null' "$bundle"
check "bundle: fsmonitor is disabled on the command line" grep -q -- '-c core.fsmonitor=false' "$bundle"
check "bundle: pager is disabled on the command line" grep -q -- '--no-pager' "$bundle"

finish
