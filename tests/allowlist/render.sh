#!/usr/bin/env bash
# allowlist_add, allowlist_remove and allowlist_render, end to end, against
# a temporary configuration directory and a temporary session directory.
# Runs as a plain process; nothing here needs a container.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SANDBOX_ROOT="$root"
# shellcheck source-path=SCRIPTDIR source=../../scripts/allowlist.sh
source "$root/scripts/allowlist.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SANDBOX_CONFIG_DIR="$tmp/config"
# A fixed "today", so the expiry checks do not depend on the day they run.
export ALLOWLIST_TODAY=2026-06-15
session="$tmp/session"
proxy="$session/proxy"
local_file="$SANDBOX_CONFIG_DIR/allowlist.local"

fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

# in_list <file> <line>: true when the file has exactly that line.
in_list() { grep -qxF -- "$2" "$1"; }

# --- A render with no entries of your own -----------------------------------
allowlist_render "$session" claude || fail "render with no allowlist.local failed"
for f in agent.domains sidecar.domains relay.domains extra.conf; do
  [ -f "$proxy/$f" ] || fail "render did not write $f"
done
[ ! -s "$proxy/relay.domains" ] || fail "relay.domains is not empty without a relay host"
[ ! -s "$proxy/extra.conf" ] || fail "extra.conf is not empty without host:port or URL entries"
base_before="$(cat "$proxy/agent.domains")"

# --- Add, render, remove, render --------------------------------------------
allowlist_add host docs.example.com - 'the API docs the tests quote' || fail "add host failed"
allowlist_add host .cdn.example.net 2026-12-31 'assets for the build' || fail "add pattern failed"
[ -f "$local_file" ] || fail "allowlist.local was not created"
grep -q "$(printf 'host\tdocs.example.com\t-\tthe API docs the tests quote')" "$local_file" ||
  fail "the entry is not stored as kind<TAB>value<TAB>until<TAB>reason"

allowlist_render "$session" claude || fail "render after add failed"
in_list "$proxy/agent.domains" docs.example.com || fail "docs.example.com is not in agent.domains after add"
in_list "$proxy/agent.domains" .cdn.example.net || fail ".cdn.example.net is not in agent.domains after add"
if grep -q '[#[:space:]]' "$proxy/agent.domains"; then
  fail "agent.domains holds something other than one bare entry per line"
fi
if grep -q 'the API docs' "$proxy"/*; then
  fail "a reason was written into a file Squid reads"
fi

# Adding the same entry again changes nothing.
before="$(cat "$local_file")"
allowlist_add host docs.example.com - 'again' 2>/dev/null || fail "adding an entry twice is an error"
[ "$(cat "$local_file")" = "$before" ] || fail "adding an entry twice changed allowlist.local"

allowlist_remove docs.example.com || fail "remove failed"
allowlist_remove .cdn.example.net || fail "remove of a pattern failed"
if allowlist_remove docs.example.com 2>/dev/null; then
  fail "removing an entry that is not there succeeded"
fi
if allowlist_remove registry.npmjs.org 2>/dev/null; then
  fail "removing a shipped entry succeeded; only allowlist.local is yours to change"
fi
allowlist_render "$session" claude || fail "render after remove failed"
[ "$(cat "$proxy/agent.domains")" = "$base_before" ] || fail "add then remove did not restore agent.domains"

# --- Expiry -----------------------------------------------------------------
# An entry is good through its `until` day and dropped from the day after.
allowlist_add host future.example.com 2026-06-16 'still needed' || fail "add with a future date failed"
allowlist_add host lastday.example.com 2026-06-15 'ends today' || fail "add with today's date failed"
if allowlist_add host past.example.com 2026-06-14 'too late' 2>/dev/null; then
  fail "add accepted a date that has already passed"
fi
# One that was fine when it was added and has run out since.
printf 'host\texpired.example.com\t2026-06-14\tran out yesterday\n' >> "$local_file"
msg="$(allowlist_render "$session" claude 2>&1)" || fail "render with an expired entry failed: $msg"
case "$msg" in
  *expired.example.com*2026-06-14*) ;;
  *) fail "render did not say it dropped the expired entry: $msg" ;;
esac
in_list "$proxy/agent.domains" future.example.com || fail "an entry with a future date was dropped"
in_list "$proxy/agent.domains" lastday.example.com || fail "an entry was dropped on its last day"
if in_list "$proxy/agent.domains" expired.example.com; then
  fail "an expired entry was rendered"
fi
grep -q expired.example.com "$local_file" || fail "render edited allowlist.local"
# The day after, the entry that ended "today" is gone too.
ALLOWLIST_TODAY=2026-06-16 allowlist_render "$session" claude 2>/dev/null || fail "render on the next day failed"
if in_list "$proxy/agent.domains" lastday.example.com; then
  fail "an entry outlived its last day"
fi
in_list "$proxy/agent.domains" future.example.com || fail "an entry was dropped on its last day (next day run)"
# A date that is not one stops the render rather than becoming "no end date".
for bad in 2026-13-01 2026-00-10 2026-06-32 2026-6-1 tomorrow 20260615 ''; do
  if allowlist_add host bad-date.example.com "$bad" 'test' 2>/dev/null; then
    fail "add accepted the date '$bad'"
  fi
done
printf 'host\ttypo.example.com\t2026-6-1\thand edit\n' >> "$local_file"
if allowlist_render "$session" claude 2>/dev/null; then
  fail "render accepted a malformed until date"
fi
rm -f "$local_file"

# --- host:port and URL entries become extra.conf, and nothing else does ------
allowlist_add host plain.example.com - 'a plain host' || fail "add host failed"
allowlist_add hostport db.example.com:8443 - 'the staging API' || fail "add hostport failed"
allowlist_add url http://mirror.example.org/pub/tools+extras/v1.2/ - 'a plaintext mirror' ||
  fail "add url failed"
allowlist_render "$session" claude || fail "render with extra entries failed"
expected='acl extra_1_host dstdomain -n db.example.com
acl extra_1_port port 8443
http_access deny method_connect from_agent extra_1_host extra_1_port to_private
http_access allow method_connect from_agent extra_1_host extra_1_port
acl extra_2_host dstdomain -n mirror.example.org
acl extra_2_url url_regex ^http://mirror\.example\.org/pub/tools\+extras/v1\.2/
http_access deny !method_connect from_agent extra_2_host extra_2_url path_dotdot
http_access deny !method_connect from_agent extra_2_host extra_2_url to_private
http_access allow !method_connect from_agent extra_2_host extra_2_url'
if [ "$(cat "$proxy/extra.conf")" != "$expected" ]; then
  fail "extra.conf is not what was expected:"
  diff <(printf '%s\n' "$expected") "$proxy/extra.conf" || true
fi
# Neither of them widens the list of names.
in_list "$proxy/agent.domains" plain.example.com || fail "the plain host is missing from agent.domains"
if grep -q -e db.example.com -e mirror.example.org "$proxy/agent.domains"; then
  fail "a host:port or URL entry also landed in agent.domains"
fi
# Every rule in extra.conf is for the agent's address only, and every address
# check comes after a name has matched on the same line.
while IFS= read -r line; do
  case "$line" in
    http_access*)
      case "$line" in
        *" from_agent "*) ;;
        *) fail "extra.conf rule is not limited to the agent: $line" ;;
      esac
      case "$line" in
        *to_private*_host*) fail "extra.conf looks an address up before the name matched: $line" ;;
      esac ;;
  esac
done < "$proxy/extra.conf"

# An https:// URL cannot be enforced as a URL: it becomes its host, and both
# add and render say so.
msg="$(allowlist_add url https://api.example.io/v2/things - 'an API' 2>&1)" || fail "add https url failed"
case "$msg" in
  *"whole host api.example.io"*) ;;
  *) fail "add did not say an https URL allows the whole host: $msg" ;;
esac
msg="$(allowlist_render "$session" claude 2>&1)" || fail "render with an https url failed"
case "$msg" in
  *"whole host api.example.io"*) ;;
  *) fail "render did not say an https URL allows the whole host: $msg" ;;
esac
in_list "$proxy/agent.domains" api.example.io || fail "the https URL's host is not in agent.domains"
[ "$(cat "$proxy/extra.conf")" = "$expected" ] || fail "an https URL added something to extra.conf"

# Removing by value works for every kind.
allowlist_remove db.example.com:8443 || fail "remove hostport failed"
allowlist_remove http://mirror.example.org/pub/tools+extras/v1.2/ || fail "remove url failed"
allowlist_remove https://api.example.io/v2/things || fail "remove https url failed"
allowlist_render "$session" claude || fail "render after removing extras failed"
[ ! -s "$proxy/extra.conf" ] || fail "extra.conf is not empty after the entries were removed"
rm -f "$local_file"

# --- Squid refuses a list with a pattern and a name beneath it ---------------
allowlist_add host www.example.com - 'one host' || fail "add failed"
allowlist_add host example.com - 'the bare domain' || fail "add failed"
allowlist_add host .example.com - 'the whole domain' || fail "add failed"
allowlist_add host .deep.example.com - 'a narrower pattern' || fail "add failed"
allowlist_add host notexample.com - 'a different domain' || fail "add failed"
allowlist_render "$session" claude || fail "render with overlapping entries failed"
in_list "$proxy/agent.domains" .example.com || fail "the pattern was dropped"
in_list "$proxy/agent.domains" notexample.com || fail "an unrelated host was dropped"
for covered in www.example.com example.com .deep.example.com; do
  if in_list "$proxy/agent.domains" "$covered"; then
    fail "$covered is still listed next to the pattern that covers it"
  fi
done
[ "$(sort -u "$proxy/agent.domains" | wc -l)" -eq "$(wc -l < "$proxy/agent.domains")" ] ||
  fail "agent.domains has duplicate lines"
rm -f "$local_file"

# --- The git relay's host ----------------------------------------------------
allowlist_render "$session" claude git.example.com || fail "render with a relay host failed"
[ "$(cat "$proxy/relay.domains")" = git.example.com ] || fail "relay.domains is not the relay host"
if in_list "$proxy/agent.domains" git.example.com; then
  fail "the relay's host leaked into agent.domains"
fi
if allowlist_render "$session" claude .example.com 2>/dev/null; then
  fail "render accepted a pattern as the relay host"
fi

# --- Files Squid can read, written whole, nothing left behind ----------------
for f in agent.domains sidecar.domains relay.domains extra.conf; do
  case "$(ls -l "$proxy/$f")" in
    -rw-r--r--*) ;;
    *) fail "$f is not mode 0644" ;;
  esac
done
case "$(ls -ld "$proxy")" in
  drwxr-xr-x*) ;;
  *) fail "the proxy directory is not mode 0755" ;;
esac
[ "$(find "$proxy" -mindepth 1 | wc -l)" -eq 4 ] || fail "render left something besides its four files: $(ls -A "$proxy")"
[ "$(find "$SANDBOX_CONFIG_DIR" -name '*.tmp.*' | wc -l)" -eq 0 ] || fail "a temporary file was left in the config directory"

# --- An agent that does not exist --------------------------------------------
if allowlist_render "$session" nosuchagent 2>/dev/null; then
  fail "render accepted an unknown agent"
fi
if allowlist_render "$session" ../policy 2>/dev/null; then
  fail "render accepted an agent name with a path in it"
fi

if [ "$fails" -gt 0 ]; then
  printf '%s render check(s) failed\n' "$fails"
  exit 1
fi
echo "allowlist render: all checks passed"
