#!/usr/bin/env bash
# Nothing an operator types (or pastes) may add a line or a word to a file
# Squid reads.  [logical B20]
# Every attempt below must be refused by allowlist_add and, when it is
# written into allowlist.local by hand, by allowlist_render.
# Runs as a plain process; nothing here needs a container.
# shellcheck disable=SC2016,SC1003  # the dollar signs and backslashes in the attempts are literal on purpose
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SANDBOX_ROOT="$root"
# shellcheck source-path=SCRIPTDIR source=../../scripts/allowlist.sh
source "$root/scripts/allowlist.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SANDBOX_CONFIG_DIR="$tmp/config"
export ALLOWLIST_TODAY=2026-06-15
session="$tmp/session"
local_file="$SANDBOX_CONFIG_DIR/allowlist.local"
mkdir -p "$SANDBOX_CONFIG_DIR"

fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

# A good render first, so there is something a bad one could overwrite.
allowlist_render "$session" claude || fail "the first render failed"
good="$(cat "$session"/proxy/*)"

nl=$'\n'
tab=$'\t'

# refused <kind> <value>: add must refuse it and write nothing; the same
# entry written by hand must stop the render and leave the files alone.
refused() {
  local kind="$1" value="$2"
  if allowlist_add "$kind" "$value" - 'injection test' 2>/dev/null; then
    fail "add accepted $kind '$value'"
  fi
  [ ! -e "$local_file" ] || fail "add wrote allowlist.local for the refused $kind '$value'"
  rm -f "$local_file"
  printf '%s\t%s\t-\thand edit\n' "$kind" "$value" > "$local_file"
  if allowlist_render "$session" claude 2>/dev/null; then
    fail "render accepted $kind '$value' from allowlist.local"
  fi
  [ "$(cat "$session"/proxy/*)" = "$good" ] || fail "a refused render changed the proxy's files ($kind '$value')"
  rm -f "$local_file"
}

# --- host ---------------------------------------------------------------------
refused host "example.com${nl}http_access allow all"
refused host 'example.com http_access allow all'
refused host 'example.com #'
refused host '#example.com'
refused host '"example.com"'
refused host "'example.com'"
refused host '"/etc/passwd"'
refused host 'example.com;'
refused host 'example.com\'
refused host '${process_number}.example.com'
refused host '-n'
refused host 'all'

# --- host:port ----------------------------------------------------------------
refused hostport "db.example.com:8443${nl}http_access allow all"
refused hostport 'db.example.com:8443 http_access allow all'
refused hostport 'db.example.com:8443 #'
refused hostport 'db.example.com:"8443"'
refused hostport "db.example.com:'8443'"
refused hostport 'db example.com:8443'
refused hostport '"db.example.com":8443'
refused hostport 'db.example.com:0'
refused hostport 'db.example.com:65536'
refused hostport 'db.example.com:99999'
refused hostport 'db.example.com:123456'
refused hostport 'db.example.com:08443'
refused hostport 'db.example.com:-1'
refused hostport 'db.example.com:80-90'
refused hostport 'db.example.com:https'
refused hostport 'db.example.com:'
refused hostport 'db.example.com'
refused hostport '.example.com:8443'
refused hostport '192.0.2.7:8443'
refused hostport '[2001:db8::1]:8443'

# --- url ------------------------------------------------------------------------
refused url "http://mirror.example.org/pub/${nl}http_access allow all"
refused url 'http://mirror.example.org/pub/ http_access allow all'
refused url 'http://mirror.example.org/pub/#x'
refused url 'http://mirror.example.org/"pub"/'
refused url "http://mirror.example.org/'pub'/"
refused url 'http://mirror.example.org/pub/?q=1'
refused url 'http://mirror.example.org/pub/.*'
refused url 'http://mirror.example.org/pub/(a|b)'
refused url 'http://mirror.example.org/pub/[a]'
refused url 'http://mirror.example.org/pub\d/'
refused url 'http://mirror.example.org/${pid}/'
refused url 'http://mirror.example.org/pub/$'
refused url 'http://user:pw@mirror.example.org/pub/'
refused url 'http://mirror.example.org:8080/pub/'
refused url 'http://.example.org/pub/'
refused url 'http://192.0.2.7/pub/'
refused url 'http://Mirror.example.org/pub/'
refused url 'ftp://mirror.example.org/pub/'
refused url 'mirror.example.org/pub/'
refused url 'http://'
refused url "https://api.example.io/v2${nl}evil.example.com"
refused url 'https://api.example.io evil.example.com/'

# --- kind and preset ------------------------------------------------------------
refused acl 'x src all'
refused '' 'example.com'
refused preset '../never-allow'
refused preset 'github-downloads/../../never-allow'
refused preset 'no-such-preset'
refused preset "github-downloads${nl}host"

# --- until and reason: the two fields that only go into allowlist.local ---------
# A tab or a line break in either would start a new field or a new entry.
if allowlist_add host docs.example.com "2026-12-31${nl}host${tab}evil.example.com${tab}-${tab}x" 'test' 2>/dev/null; then
  fail "add accepted a line break in the until field"
fi
if allowlist_add host docs.example.com - "fine${nl}host${tab}evil.example.com${tab}-${tab}x" 2>/dev/null; then
  fail "add accepted a line break in the reason"
fi
if allowlist_add host docs.example.com - "fine${tab}more" 2>/dev/null; then
  fail "add accepted a tab in the reason"
fi
if allowlist_add host docs.example.com - $'fine\033[2Jmore' 2>/dev/null; then
  fail "add accepted an escape character in the reason"
fi
if allowlist_add host docs.example.com - $'fine\rmore' 2>/dev/null; then
  fail "add accepted a carriage return in the reason"
fi
if allowlist_add host docs.example.com - '' 2>/dev/null; then
  fail "add accepted an empty reason"
fi
if allowlist_add host docs.example.com - '   ' 2>/dev/null; then
  fail "add accepted a blank reason"
fi
[ ! -e "$local_file" ] || fail "a refused until or reason was written to allowlist.local"
rm -f "$local_file"

# A reason is ordinary prose. Spaces, `#` and quotes in it are fine, because
# a reason never goes into a file Squid reads.
reason='needed for "make docs" # see ticket 12; it'"'"'s temporary'
allowlist_add host docs.example.com - "$reason" || fail "add refused an ordinary reason"
allowlist_add hostport db.example.com:8443 - "$reason" || fail "add refused an ordinary reason (hostport)"
allowlist_add url http://mirror.example.org/pub/ - "$reason" || fail "add refused an ordinary reason (url)"
[ "$(grep -c . "$local_file")" -eq 7 ] || fail "allowlist.local does not hold exactly its header and three entries"
allowlist_render "$session" claude || fail "render with an ordinary reason failed"
if grep -q -e 'make docs' -e 'ticket' -e '"' -e "'" -e '#' "$session"/proxy/*; then
  fail "part of a reason reached a file Squid reads"
fi
# What did reach extra.conf: only lines that start with one of two words,
# and only words made of safe characters.
while IFS= read -r line; do
  case "$line" in
    'acl extra_'*|'http_access deny '*|'http_access allow '*) ;;
    *) fail "unexpected line in extra.conf: $line" ;;
  esac
done < "$session/proxy/extra.conf"
if LC_ALL=C grep -q '[^A-Za-z0-9 ._/:!^\\+~@%-]' "$session/proxy/extra.conf"; then
  fail "extra.conf holds a character outside the safe set"
fi
if LC_ALL=C grep -q '[^a-z0-9.-]' "$session/proxy/agent.domains" "$session/proxy/sidecar.domains"; then
  fail "a list of names holds a character that is not part of a host name"
fi
rm -f "$local_file"

# --- A line in allowlist.local with the wrong number of fields -------------------
for line in 'host docs.example.com - spaces instead of tabs' \
  "host${tab}docs.example.com" \
  "host${tab}docs.example.com${tab}-" \
  'docs.example.com'; do
  printf '%s\n' "$line" > "$local_file"
  if allowlist_render "$session" claude 2>/dev/null; then
    fail "render accepted the malformed line '$line'"
  fi
done
rm -f "$local_file"

if [ "$fails" -gt 0 ]; then
  printf '%s injection check(s) failed\n' "$fails"
  exit 1
fi
echo "allowlist injection: all checks passed"
