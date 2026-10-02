#!/usr/bin/env bash
# allowlist_valid_host: what may be written on a list, and what may not.
# Runs as a plain process; nothing here needs a container.
# shellcheck disable=SC2016  # the dollar sign in one of the names is literal on purpose
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SANDBOX_ROOT="$root"
# shellcheck source-path=SCRIPTDIR source=../../scripts/allowlist.sh
source "$root/scripts/allowlist.sh"

fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

accepts() {
  allowlist_valid_host "$1" 2>/dev/null || fail "refused a good host name: '$1'"
}
# refuses <host> <word expected in the explanation>
refuses() {
  local why
  if why="$(allowlist_valid_host "$1" 2>&1)"; then
    fail "accepted '$1'"
    return 0
  fi
  case "$why" in
    *"$2"*) ;;
    *) fail "'$1' was refused, but the explanation does not mention '$2': $why" ;;
  esac
}

label63="$(printf 'a%.0s' {1..63})"
label64="${label63}a"

accepts docs.example.com
accepts .example.com
accepts registry.npmjs.org
accepts a-b.example.co.uk
accepts xn--bcher-kva.example
accepts 0x0.st
accepts 123.example.com
accepts "${label63}.example.com"

refuses ''                          'empty'
refuses Example.com                 'uppercase'
refuses docs.EXAMPLE.com            'uppercase'
refuses https://example.com         'scheme'
refuses example.com/path            'path'
refuses example.com:8443            'port'
refuses 192.0.2.7                   'IP address'
refuses .192.0.2.7                  'IP address'
refuses 2130706433                  'IP address'
refuses '2001:db8::1'               'IP address'
refuses '[2001:db8::1]'             'IP address'
refuses '::1'                       'IP address'
refuses example..com                'empty label'
refuses example.com.                'empty label'
refuses ..example.com               'empty label'
refuses .                           'empty'
refuses "${label64}.example.com"    '63'
refuses localhost                   'not a host name'
refuses -a.example.com              'hyphen'
refuses a-.example.com              'hyphen'
refuses example.123                 'ends in a number'
refuses 0x7f.0.0.1                  'ends in a number'
refuses 'exa mple.com'              'character'
refuses 'example.com #x'            'character'
refuses '"example.com"'             'character'
refuses "example.com'"              'character'
refuses $'example.com\nacl x src all' 'character'
refuses $'example.com\t'            'character'
refuses 'exämple.com'               'character'
refuses 'example.com*'              'character'
refuses '$example.com'              'character'
refuses 'example_.com'              'character'

if [ "$fails" -gt 0 ]; then
  printf '%s valid-host check(s) failed\n' "$fails"
  exit 1
fi
echo "allowlist valid-host: all checks passed"
