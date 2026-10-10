#!/usr/bin/env bash
# tests/verify/static.sh — what can be said about verify by reading it.
#
#   1. shellcheck -x on both scripts and on these tests.
#   2. scripts/verify.sh is host-side code and must run under macOS's bash
#      3.2: no associative arrays, no mapfile, no ${var,,} and friends.
#   3. The two halves agree: every check verify.sh asks the agent container
#      for exists in verify-inside.sh, and every check in verify-inside.sh is
#      asked for.
#   4. Every barrier in the register of docs/00-threat-model.md has at least
#      one check named after it.
#   5. Every reason verify-inside.sh can give for a SKIP is either on
#      verify.sh's list of legitimate reasons or is meant to count as a
#      failure; the list itself has not grown unnoticed.
#
# Exit 0 = all of it holds.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
host="$repo/scripts/verify.sh"
inside="$repo/images/agent/verify-inside.sh"

failures=0
not_ok() { failures=$((failures + 1)); printf 'not ok - %s\n' "$1"; }
ok() { printf 'ok   - %s\n' "$1"; }

# 1 ---------------------------------------------------------------------------
command -v shellcheck >/dev/null 2>&1 || { echo "tests/verify: shellcheck is needed and is not installed" >&2; exit 1; }
if shellcheck -x "$host" "$inside" "$here"/*.sh; then ok "shellcheck -x: clean"; else not_ok "shellcheck found something"; fi
if bash -n "$host" && bash -n "$inside"; then ok "bash -n: both scripts parse"; else not_ok "a script does not parse"; fi

# 2 ---------------------------------------------------------------------------
# Comment lines are left out: the header names these constructs to forbid them.
banned='declare -A|local -A|typeset -A|mapfile|readarray|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^|,|\^)\}|\$\{[A-Za-z_][A-Za-z0-9_]*@[A-Za-z]\}|&>>|\|&|coproc|local -n|declare -n|\[-1\]|printf .%\(|\$\{!.*@\}|wait -n|read -t 0\.|;;&|;&$'
if grep -v '^[[:space:]]*#' "$host" | grep -nE -- "$banned"; then
  not_ok "scripts/verify.sh uses something bash 3.2 does not have (lines above)"
else
  ok "scripts/verify.sh: none of the constructs bash 3.2 lacks"
fi
if grep -nE '(^|[^a-z-])(jq|python3?|timeout|setsid|realpath|readlink -f|sed -i|date -d|stat -c) ' "$host" | grep -v '^[0-9]*:[[:space:]]*#'; then
  not_ok "scripts/verify.sh calls a tool the host is not required to have, or a GNU-only form (lines above)"
else
  ok "scripts/verify.sh: no jq, python, timeout, setsid or GNU-only options on the host side"
fi

# 3 ---------------------------------------------------------------------------
defined="$(sed -n 's/^    \(B[0-9][0-9]-[a-z0-9-]*\)) .*/\1/p' "$inside" | sort -u)"
# The arguments of every run_inside call, continuation lines included.
asked="$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$host" | sed -n 's/^ *run_inside \(B.*\)$/\1/p' | tr ' ' '\n' | grep '^B[0-9][0-9]-' | sort -u)"
[ "$(printf '%s\n' "$defined" | grep -c .)" -ge 45 ] || not_ok "could not read the check names from verify-inside.sh"
missing="$(comm -13 <(printf '%s\n' "$defined") <(printf '%s\n' "$asked") | tr '\n' ' ')"
unasked="$(comm -23 <(printf '%s\n' "$defined") <(printf '%s\n' "$asked") | tr '\n' ' ')"
if [ -z "$missing" ]; then ok "every check verify.sh asks for exists in verify-inside.sh"; else not_ok "verify.sh asks for checks verify-inside.sh does not have: $missing"; fi
if [ -z "$unasked" ]; then ok "every check in verify-inside.sh is asked for by verify.sh ($(printf '%s\n' "$defined" | grep -c .) of them)"; else not_ok "verify-inside.sh has checks verify.sh never runs: $unasked"; fi
documented="$(sed -n 's/^#   \(B[0-9][0-9]-[a-z0-9-]*\)  .*/\1/p' "$inside" | sort -u)"
if [ "$documented" = "$defined" ]; then ok "the list of names at the end of verify-inside.sh matches its checks"; else not_ok "the list of names at the end of verify-inside.sh is out of date"; fi

# 4 ---------------------------------------------------------------------------
register="$(sed -n 's/^| \(B[0-9][0-9]\) | .*/\1/p' "$repo/docs/00-threat-model.md" | sort -u)"
[ "$(printf '%s\n' "$register" | grep -c .)" -eq 30 ] || not_ok "expected 30 barriers in the register, found $(printf '%s\n' "$register" | grep -c .)"
uncovered=""
for barrier in $register; do
  grep -qE "(pass|fail|skip|run_inside|for name in)[^#]* $barrier-[a-z]" "$host" || grep -q "^    $barrier-" "$inside" || uncovered="$uncovered $barrier"
done
if [ -z "$uncovered" ]; then ok "every barrier of the register (B01-B16, B20-B33) has a check named after it"; else not_ok "barriers with no check:$uncovered"; fi

# 5 ---------------------------------------------------------------------------
legitimate="$(sed -n 's/^LEGITIMATE="\(.*\)"$/\1/p' "$host")"
expected="no-selinux no-swap no-setuid-files no-remote no-git-relay branch-rule http-allowed memory-workspace no-store no-runtime-class quick separate"
if [ "$legitimate" = "$expected" ]; then ok "the list of legitimate skip reasons is the reviewed one"; else not_ok "the list of legitimate skip reasons changed: review it, then update this test ('$legitimate')"; fi
# Reasons the in-container script uses, and which side of the line each is on.
counted=""
while read -r reason; do
  case " $legitimate " in *" $reason "*) ;; *) counted="$counted $reason" ;; esac
done <<LIST
$(grep -oE 'skip "?[A-Za-z0-9$-]+"? [a-z-]+ ' "$inside" | awk '{ print $3 }' | sort -u)
LIST
if [ "$counted" = " no-probe unknown" ]; then
  ok "in-container skips that count as failures: no-probe (the probe could not run) and unknown (a value was not handed in)"
else
  not_ok "in-container skip reasons that count as failures are [$counted], expected [ no-probe unknown]"
fi

printf '\n%s assertion(s) failed\n' "$failures"
[ "$failures" -eq 0 ]
