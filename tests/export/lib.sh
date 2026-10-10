#!/usr/bin/env bash
# lib.sh — shared by the export tests in this directory. Sourced, not run.
#
# Every fixture is built at test time: a small git repository in a temporary
# directory, committed to, and turned into a bundle the way the sandbox would
# hand one over. Nothing here needs a container.

# shellcheck disable=SC2034  # BASE, SESSION_DIR and HAVE_JQ are read by the tests that source this file

set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$TESTS_DIR/../.." && pwd)
EXPORT=$ROOT/scripts/export.sh

WORK=$(mktemp -d "${TMPDIR:-/tmp}/export-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# export.sh puts its scratch directory under TMPDIR; pointing that at a
# directory of ours lets a test check that nothing is left behind.
export TMPDIR=$WORK/tmp
mkdir "$TMPDIR"

# The fixture repositories are made with a git that reads no configuration of
# the person running the tests.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Test Human" GIT_AUTHOR_EMAIL=human@example.com
export GIT_COMMITTER_NAME="Test Human" GIT_COMMITTER_EMAIL=human@example.com
export GIT_AUTHOR_DATE="2026-01-02T03:04:05Z" GIT_COMMITTER_DATE="2026-01-02T03:04:05Z"

# export.sh is run with a PATH that holds exactly the tools it says it needs,
# so the tests fail if it starts depending on another one, and so that a
# gitleaks installed on this machine is not picked up by accident.
BIN=$WORK/bin
mkdir "$BIN"
for tool in bash env git awk sed grep tr cut sort comm wc cat ls mkdir mktemp mv rm dirname; do
  ln -s "$(command -v "$tool")" "$BIN/$tool"
done
HAVE_JQ=no
if command -v jq >/dev/null 2>&1; then
  ln -s "$(command -v jq)" "$BIN/jq"
  HAVE_JQ=yes
fi

OUTPUT=""
RC=0
CASE=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [ -n "$OUTPUT" ]; then
    printf '%s\n' "--- output of export.sh ---" "$OUTPUT" "---" >&2
  fi
  exit 1
}

ok() { printf 'ok - %s\n' "$*"; }

# A stand-in for gitleaks: answers `gitleaks version`, otherwise writes down
# its arguments, its environment and its working directory, and exits with
# the status the test asked for.
#   fake_gitleaks <version> <exit-status>
fake_gitleaks() {
  mkdir -p "$WORK/shim"
  cat >"$WORK/shim/gitleaks" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = version ]; then echo "$1"; exit 0; fi
printf '%s\n' "\$@" >"$WORK/gitleaks.args"
env >"$WORK/gitleaks.env"
pwd >"$WORK/gitleaks.cwd"
echo "fake gitleaks ran"
exit $2
SHIM
  chmod +x "$WORK/shim/gitleaks"
  EXPORT_PATH=$WORK/shim:$BIN
  rm -f "$WORK/gitleaks.args" "$WORK/gitleaks.env" "$WORK/gitleaks.cwd"
}

no_gitleaks() { EXPORT_PATH=$BIN; }

# run_export <args to export.sh...>   sets OUTPUT and RC
run_export() {
  RC=0
  OUTPUT=$(PATH="$EXPORT_PATH" "$EXPORT" "$@" 2>&1) || RC=$?
}

assert_rc() {
  if [ "$RC" -ne "$1" ]; then fail "expected exit status $1, got $RC"; fi
}

assert_has() {
  case $OUTPUT in
    *"$1"*) ;;
    *) fail "the output does not contain: $1" ;;
  esac
}

assert_lacks() {
  case $OUTPUT in
    *"$1"*) fail "the output contains: $1" ;;
  esac
}

assert_eq() {
  if [ "$1" != "$2" ]; then fail "$3: expected '$2', got '$1'"; fi
}

assert_missing() {
  if [ -e "$1" ] || [ -L "$1" ]; then fail "$1 exists and should not"; fi
}

# status_value <session-dir> <KEY>   reads export.status the way the launcher
# does: with `read`, never by sourcing it.
status_value() {
  local key value
  while IFS='=' read -r key value; do
    if [ "$key" = "$2" ]; then printf '%s' "$value"; fi
  done <"$1/export.status"
}

assert_status() {
  assert_eq "$(status_value "$1" "$2")" "$3" "export.status $2"
}

# gitleaks_arg_after <flag>   the argument that followed <flag>
gitleaks_arg_after() {
  awk -v flag="$1" 'found { print; exit } $0 == flag { found = 1 }' "$WORK/gitleaks.args"
}

assert_gitleaks_arg() {
  if ! grep -qxF -- "$1" "$WORK/gitleaks.args"; then
    fail "gitleaks was not given the argument: $1 (got: $(tr '\n' ' ' <"$WORK/gitleaks.args"))"
  fi
}

# new_repo <dir>   a repository on branch `work` with one commit, the state a
# session starts from. Prints nothing; BASE is set to that commit.
new_repo() {
  git init -q -b work "$1"
  mkdir -p "$1/src"
  printf 'console.log("hello")\n' >"$1/src/index.js"
  printf '{\n  "name": "demo",\n  "scripts": {"test": "node test.js"},\n  "dependencies": {"left-pad": "1.3.0"}\n}\n' >"$1/package.json"
  cat >"$1/package-lock.json" <<'LOCK'
{
  "name": "demo",
  "lockfileVersion": 3,
  "packages": {
    "": {"name": "demo", "dependencies": {"left-pad": "1.3.0"}},
    "node_modules/left-pad": {
      "version": "1.3.0",
      "resolved": "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz",
      "integrity": "sha512-BASEBASEBASE"
    }
  }
}
LOCK
  commit_all "$1" "Start of the project"
  BASE=$(git -C "$1" rev-parse HEAD)
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

# make_bundle <repo> <bundle-file> [ref]   what `sandbox-bundle` produces
make_bundle() {
  git -C "$1" bundle create -q "$2" "${3:-work}"
}

# git on an exported repository, again without anyone's configuration.
clean_git() {
  local repo=$1
  shift
  git --git-dir="$repo" "$@"
}

# names_in <dir>   the names directly inside a directory, sorted, on one line
names_in() {
  find "$1" -mindepth 1 -maxdepth 1 | sed 's|.*/||' | sort | tr '\n' ' '
}

next_session() {
  CASE=$((CASE + 1))
  SESSION=asb-test-$(printf '%06x' "$CASE")
  SESSION_DIR=$WORK/out/$SESSION
}
