# shellcheck shell=bash
# Shared by the tests in this directory. Sourced by them; does nothing useful
# when run by itself.
#
# These are static tests: they run the scripts as ordinary processes, with
# fake stand-ins for podman, npm and the agent CLIs. They prove what the
# scripts do, not what a container runtime does with the result.
set -euo pipefail

# Used by the tests that source this file.
# shellcheck disable=SC2034
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
pass() { printf 'ok   %s\n' "$*"; }
# check <description> <command...>: passes when the command succeeds.
check() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
# check_not <description> <command...>: passes when the command fails.
check_not() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then fail "$what"; else pass "$what"; fi
}
# is <description> <actual> <expected>: passes when the two strings are equal.
is() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2', expected '$3'"; fi
}
finish() {
  if [ "$fails" -gt 0 ]; then
    printf '%s: %d failure(s)\n' "$(basename "$0")" "$fails"
    exit 1
  fi
  printf '%s: all passed\n' "$(basename "$0")"
}

# A scratch directory per test, removed on the way out.
scratch="$(mktemp -d)"
trap 'chmod -R u+rwx "${scratch:?}" 2>/dev/null; rm -rf "${scratch:?}"' EXIT

# sha256 of a file (Linux: sha256sum; macOS: shasum).
sha256_of() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Permission bits of a path, as octal digits (GNU stat, then BSD stat).
mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
