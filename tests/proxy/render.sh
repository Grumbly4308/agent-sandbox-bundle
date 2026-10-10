#!/usr/bin/env bash
# The proxy's entrypoint, run here as a plain process: it must turn the
# template into a Squid configuration whose rules are in the order the
# threat model promises [logical B20, B21], and refuse to start on an
# environment it cannot trust.
#
# This proves what Squid would be TOLD. There is no squid program on the
# machine these tests run on, so whether Squid accepts the file (`squid -k
# parse`) and enforces it is for `./sandbox verify` on a real host.
# shellcheck disable=SC2016  # the ${...} looked for in other files is literal on purpose
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SANDBOX_ROOT="$root"
# shellcheck source-path=SCRIPTDIR source=../../scripts/allowlist.sh
source "$root/scripts/allowlist.sh"
entrypoint="$root/images/proxy/entrypoint.sh"
template="$root/images/proxy/squid.conf.template"
containerfile="$root/images/proxy/Containerfile"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

# The entrypoint is for busybox sh: it must at least parse as plain sh.
sh -n "$entrypoint" || fail "entrypoint.sh does not parse as sh"
case "$(head -n 1 "$entrypoint")" in
  '#!/bin/sh') ;;
  *) fail "entrypoint.sh does not start with #!/bin/sh" ;;
esac

# A stand-in for Squid: it records how it was started and exits.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/squid" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$SQUID_RUN_DIR/squid.args"
EOF
chmod +x "$tmp/bin/squid"

# The session's lists, made by the real renderer, with one host:port and one
# URL entry so that extra.conf has rules in it.
export SANDBOX_CONFIG_DIR="$tmp/config" ALLOWLIST_TODAY=2026-06-15
allowlist_add hostport db.example.com:8443 - 'test' || fail "could not add a host:port entry"
allowlist_add url http://mirror.example.org/pub/ - 'test' || fail "could not add a URL entry"
allowlist_render "$tmp/session" claude git.example.com || fail "could not render the session's lists"
session="$tmp/session/proxy"

# render <run dir> NAME=value...: runs the entrypoint with exactly that
# environment and returns its exit status.
render() {
  local run="$1"
  shift
  mkdir -p "$run"
  env -i PATH="$tmp/bin:$PATH" SQUID_RUN_DIR="$run" SQUID_TEMPLATE="$template" \
    SQUID_SESSION_DIR="$session" "$@" sh "$entrypoint"
}

# rules <config>: the lines Squid acts on, numbered as in the file, with
# comments and blank lines removed.
rules() {
  sed -e 's/[[:space:]]*#.*$//' "$1" | grep -n -v '^[[:space:]]*$' || true
}
# line_of <config> <exact line>: its line number, or nothing.
line_of() {
  rules "$1" | WANT="$2" awk '{
    i = index($0, ":")
    if (substr($0, i + 1) == ENVIRON["WANT"]) { print substr($0, 1, i - 1); exit }
  }'
}
has_rule() { [ -n "$(line_of "$1" "$2")" ]; }
# in_order <config> <line> <line>...: every line is there, in this order.
in_order() {
  local conf="$1" last=0 n rule
  shift
  for rule in "$@"; do
    n="$(line_of "$conf" "$rule")"
    if [ -z "$n" ]; then
      fail "${conf#"$tmp"/}: missing rule: $rule"
      return 0
    fi
    if [ "$n" -le "$last" ]; then
      fail "${conf#"$tmp"/}: out of order (line $n, expected after line $last): $rule"
    fi
    last="$n"
  done
}

AGENT=10.201.7.10 SIDECAR=10.201.7.3 RELAY=10.201.7.4

# ---------------------------------------------------------------------------
# 1. The default session: no relay, plaintext HTTP off
# ---------------------------------------------------------------------------
run="$tmp/run-default"
render "$run" SANDBOX_AGENT_IP=$AGENT SANDBOX_SIDECAR_IP=$SIDECAR SANDBOX_RELAY_IP= \
  SANDBOX_ALLOW_HTTP=0 SANDBOX_REQUEST_MAX_MB=25 SANDBOX_REPLY_MAX_MB=200 ||
  fail "the entrypoint failed on a good environment"
conf="$run/squid.conf"
[ -f "$conf" ] || { echo "FAIL no configuration was written; nothing more can be checked"; exit 1; }

# Squid is started in the foreground on the file just written, and on no other.
[ "$(tr '\n' ' ' < "$run/squid.args")" = "-N -f $conf " ] ||
  fail "squid was not started as 'squid -N -f $conf': $(tr '\n' ' ' < "$run/squid.args")"
if grep -q '@' "$conf"; then
  fail "a placeholder was left in the configuration: $(grep -n '@' "$conf" | head -n 3)"
fi
[ "$(find "$run" -type f | wc -l)" -eq 2 ] || fail "the entrypoint left something besides squid.conf: $(ls -A "$run")"

# The order of the rules is the policy: first match wins.
in_order "$conf" \
  'http_access deny to_ip_literal' \
  'http_access deny !known_source' \
  "include $session/extra.conf" \
  'http_access deny method_connect !port_443' \
  'http_access deny !method_connect' \
  'http_access deny from_agent agent_domains to_private' \
  'http_access allow from_agent agent_domains' \
  'http_access deny from_sidecar sidecar_domains to_private' \
  'http_access allow from_sidecar sidecar_domains' \
  'http_access deny all'
in_order "$conf" 'http_access deny !known_source' 'http_access deny manager' "include $session/extra.conf"

# Nothing comes before the first rule or after the last.
first="$(rules "$conf" | grep -E '^[0-9]+:(http_access|include) ' | head -n 1)"
last="$(rules "$conf" | grep -E '^[0-9]+:(http_access|include) ' | tail -n 1)"
[ "${first#*:}" = 'http_access deny to_ip_literal' ] || fail "the first rule is not the refusal of address literals: $first"
[ "${last#*:}" = 'http_access deny all' ] || fail "the last rule is not 'deny all': $last"

# The allow rules are exactly these two, each tied to one address and its own list.
allows="$(rules "$conf" | grep -E '^[0-9]+:http_access allow ' | cut -d: -f2-)"
expected='http_access allow from_agent agent_domains
http_access allow from_sidecar sidecar_domains'
[ "$allows" = "$expected" ] || fail "unexpected allow rules: $allows"

# [B21] The addresses are exact (/32) and are the ones in the environment.
has_rule "$conf" "acl from_agent src $AGENT/32" || fail "from_agent is not exactly the agent's address"
has_rule "$conf" "acl from_sidecar src $SIDECAR/32" || fail "from_sidecar is not exactly the sidecar's address"
has_rule "$conf" "acl known_source src $AGENT/32" || fail "known_source does not hold the agent's address"
has_rule "$conf" "acl known_source src $SIDECAR/32" || fail "known_source does not hold the sidecar's address"
while IFS= read -r line; do
  case "$line" in
    *" src $AGENT/32"|*" src $SIDECAR/32") ;;
    *) fail "a source rule that is not one exact known address: $line" ;;
  esac
done <<EOF
$(rules "$conf" | grep -E '^[0-9]+:acl [a-z_]+ src ' | cut -d: -f2-)
EOF
# A header the client writes must never decide who the client is.
if rules "$conf" | grep -q -e follow_x_forwarded_for -e acl_uses_indirect_client; then
  fail "the configuration trusts a forwarding header for access decisions"
fi

# No relay: nothing mentions one.
if rules "$conf" | grep -q relay; then
  fail "a relay rule is present without a relay address"
fi
# Plaintext off: port 80 is not even named.
if rules "$conf" | grep -q port_80; then
  fail "port 80 is mentioned although plaintext HTTP is off"
fi

# Every list of names is compared as text: `-n` means "never ask DNS".
while IFS= read -r line; do
  case "$line" in
    'acl '*' dstdomain -n '*|'acl '*' dstdom_regex -n '*) ;;
    *) fail "a name list without -n (it would make Squid do DNS lookups): $line" ;;
  esac
done <<EOF
$(rules "$conf" | grep -E '^[0-9]+:acl [a-z_0-9]+ (dstdomain|dstdom_regex)' | cut -d: -f2-)
EOF
has_rule "$conf" "acl agent_domains dstdomain -n \"$session/agent.domains\"" || fail "agent_domains does not read the session's agent.domains"
has_rule "$conf" "acl sidecar_domains dstdomain -n \"$session/sidecar.domains\"" || fail "sidecar_domains does not read the session's sidecar.domains"
# Address literals: dotted IPv4 and anything with a colon (bracketed IPv6).
has_rule "$conf" 'acl to_ip_literal dstdom_regex -n ^[0-9.]+$ :' || fail "to_ip_literal is not the expected pattern"

# The one check that resolves a name (type `dst`) is used only after a list
# of names has matched: never before the port rules, and on its own line
# always to the right of a dstdomain list. Checked over the rules as Squid
# will see them, with extra.conf read in where the include is.
effective="$tmp/effective.conf"
inc="$(grep -n "^include $session/extra.conf\$" "$conf" | cut -d: -f1)"
{
  head -n "$((inc - 1))" "$conf"
  cat "$session/extra.conf"
  tail -n "+$((inc + 1))" "$conf"
} > "$effective"
dst_acls=" $(rules "$effective" | sed -n -E 's/^[0-9]+:acl ([a-z_0-9]+) dst .*/\1/p' | sort -u | tr '\n' ' ')"
name_acls=" $(rules "$effective" | sed -n -E 's/^[0-9]+:acl ([a-z_0-9]+) dstdomain -n .*/\1/p' | sort -u | tr '\n' ' ')"
[ "$dst_acls" = ' to_private ' ] || fail "expected exactly one address list, to_private; found:$dst_acls"
source_line="$(line_of "$effective" 'http_access deny !known_source')"
literal_line="$(line_of "$effective" 'http_access deny to_ip_literal')"
defined=' all manager '
while IFS= read -r line; do
  n="${line%%:*}"
  line="${line#*:}"
  case "$line" in
    'acl '*)
      word="${line#acl }"
      defined="$defined${word%% *} "
      continue ;;
    'http_access '*) ;;
    *) continue ;;
  esac
  seen_name=0
  # shellcheck disable=SC2086  # split the rule into its words on purpose
  set -- ${line#http_access }
  verdict="$1"
  shift
  case "$verdict" in
    allow|deny) ;;
    *) fail "line $n: neither allow nor deny: $line" ;;
  esac
  for word in "$@"; do
    bare="${word#!}"
    case "$defined" in
      *" $bare "*) ;;
      *) fail "line $n uses '$bare' before it is defined: $line" ;;
    esac
    case "$name_acls" in
      *" $bare "*)
        if [ "$word" = "$bare" ]; then seen_name=1; fi ;;
    esac
    case "$dst_acls" in
      *" $bare "*)
        [ "$seen_name" -eq 1 ] || fail "line $n resolves a name before any list of names has matched: $line"
        if [ "$n" -lt "$source_line" ] || [ "$n" -lt "$literal_line" ]; then
          fail "line $n resolves a name before the address-literal and source rules: $line"
        fi
        [ "$verdict" = deny ] || fail "line $n: the address list is used in an allow rule: $line"
        ;;
    esac
  done
  # Every allow rule, extra.conf's included, has a refusal for private
  # addresses with the same conditions right above it.
  if [ "$verdict" = allow ]; then
    rules "$effective" | grep -q -F -x "$((n - 1)):http_access deny $* to_private" ||
      fail "line $n: no private-address refusal directly above: $line"
  fi
done <<EOF
$(rules "$effective")
EOF
# extra.conf's exceptions sit after the first two rules and before the port rules.
in_order "$effective" \
  'http_access deny !known_source' \
  'http_access allow method_connect from_agent extra_1_host extra_1_port' \
  'http_access allow !method_connect from_agent extra_2_host extra_2_url' \
  'http_access deny method_connect !port_443' \
  'http_access deny !method_connect'

# Addresses no allowed name may resolve to, with this session's own network.
for net in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 \
  ::1/128 fc00::/7 fe80::/10 10.201.7.0/24; do
  has_rule "$conf" "acl to_private dst $net" || fail "to_private does not cover $net"
done

# The rest of what the contract asks for.
for rule in 'http_port 3128' 'request_body_max_size 25 MB' 'reply_body_max_size 200 MB' \
  'cache deny all' 'forwarded_for delete' 'via off' 'httpd_suppress_version_string on' \
  'connect_timeout 15 seconds' 'access_log stdio:/dev/stdout logformat=sandbox' \
  "pid_filename $run/squid.pid"; do
  has_rule "$conf" "$rule" || fail "missing: $rule"
done
# The log line cuts what the client controls to a fixed length.
logformat="$(rules "$conf" | grep -E '^[0-9]+:logformat sandbox ' || true)"
case "$logformat" in
  *'%.512ru'*) ;;
  *) fail "the log format does not cut the request URL to a fixed length: $logformat" ;;
esac
case "$logformat" in
  *'%.16rm'*) ;;
  *) fail "the log format does not cut the request method to a fixed length: $logformat" ;;
esac
if printf '%s\n' "$logformat" | grep -q -E '%[<>]?(ru|rm|rp|rs|rd|>h|<h)'; then
  fail "the log format has a client-controlled field with no length limit: $logformat"
fi

# Only directives this file is known to use, so a typing mistake cannot hide.
known=' http_port visible_hostname hosts_file acl http_access include request_body_max_size reply_body_max_size connect_timeout max_filedescriptors shutdown_lifetime cache cache_mem forwarded_for via httpd_suppress_version_string logformat access_log cache_log logfile_rotate pid_filename coredump_dir '
while IFS= read -r line; do
  word="${line#*:}"
  word="${word%% *}"
  case "$known" in
    *" $word "*) ;;
    *) fail "unexpected directive '$word' on line ${line%%:*}" ;;
  esac
done <<EOF
$(rules "$conf")
EOF

# Every path Squid is pointed at is one of the two memory mounts, the
# read-only session directory, or the container's own output.
while IFS= read -r path; do
  case "$path" in
    "$run"/*|/var/cache/squid|"$session"/*|/dev/stdout|/dev/stderr) ;;
    *) fail "a path outside the writable mounts and the session directory: $path" ;;
  esac
done <<EOF
$(rules "$conf" | grep -v -E '^[0-9]+:(logformat|acl [a-z_]+ (dst|src|urlpath_regex|dstdom_regex)) ' | grep -o -E '(^|[ ":])/[A-Za-z0-9._/-]+' | sed -e 's/^[ ":]//')
EOF

# ---------------------------------------------------------------------------
# 2. With a git relay, plaintext HTTP on, other limits, the egress network
# ---------------------------------------------------------------------------
run="$tmp/run-full"
render "$run" SANDBOX_AGENT_IP=$AGENT SANDBOX_SIDECAR_IP=$SIDECAR SANDBOX_RELAY_IP=$RELAY \
  SANDBOX_ALLOW_HTTP=1 SANDBOX_REQUEST_MAX_MB=7 SANDBOX_REPLY_MAX_MB=1234 \
  SANDBOX_EGRESS_SUBNET=10.202.7.0/24 ||
  fail "the entrypoint failed on a good environment with a relay"
conf="$run/squid.conf"
if grep -q '@' "$conf"; then
  fail "a placeholder was left in the configuration (relay, HTTP on)"
fi
in_order "$conf" \
  'http_access deny to_ip_literal' \
  'http_access deny !known_source' \
  "include $session/extra.conf" \
  'http_access deny method_connect !port_443' \
  'http_access deny !method_connect !port_80' \
  'http_access deny from_agent agent_domains to_private' \
  'http_access allow from_agent agent_domains' \
  'http_access deny from_sidecar sidecar_domains to_private' \
  'http_access allow from_sidecar sidecar_domains' \
  'http_access deny from_relay relay_domains to_private' \
  'http_access allow from_relay relay_domains' \
  'http_access deny all'
if has_rule "$conf" 'http_access deny !method_connect'; then
  fail "the blanket refusal of plaintext is still there with plaintext HTTP on"
fi
for rule in "acl from_relay src $RELAY/32" "acl known_source src $RELAY/32" \
  "acl relay_domains dstdomain -n \"$session/relay.domains\"" 'acl port_80 port 80' \
  'request_body_max_size 7 MB' 'reply_body_max_size 1234 MB' \
  'acl to_private dst 10.202.7.0/24'; do
  has_rule "$conf" "$rule" || fail "missing with a relay and HTTP on: $rule"
done
[ "$(rules "$conf" | grep -c -E '^[0-9]+:http_access allow ')" -eq 3 ] || fail "expected exactly three allow rules with a relay"

# Defaults: plaintext off and the stock limits when the variables are absent.
run="$tmp/run-unset"
render "$run" SANDBOX_AGENT_IP=$AGENT SANDBOX_SIDECAR_IP=$SIDECAR || fail "the entrypoint needs variables that have defaults"
has_rule "$run/squid.conf" 'http_access deny !method_connect' || fail "plaintext HTTP is not off by default"
has_rule "$run/squid.conf" 'request_body_max_size 25 MB' || fail "no default request size cap"
has_rule "$run/squid.conf" 'reply_body_max_size 200 MB' || fail "no default reply size cap"

# ---------------------------------------------------------------------------
# 3. An environment that cannot be trusted is refused, and Squid is not started
# ---------------------------------------------------------------------------
n=0
# refused <description> NAME=value...
refused() {
  local what="$1" run
  shift
  n=$((n + 1))
  run="$tmp/run-bad-$n"
  if render "$run" "$@" 2>/dev/null; then
    fail "the entrypoint accepted $what"
  fi
  [ ! -e "$run/squid.args" ] || fail "squid was started with $what"
  [ ! -e "$run/squid.conf" ] || fail "a configuration was written with $what"
}
good_sidecar="SANDBOX_SIDECAR_IP=$SIDECAR"
good_agent="SANDBOX_AGENT_IP=$AGENT"
nl=$'\n'
for bad in '' 10.201.7 10.201.7.10.1 10.201.7.256 10.201.7.010 010.201.7.10 \
  10.201.7.10/24 10.201.7.0/24 '10.201.7.10 10.201.7.3' 10.201.7.-1 10.201..10 \
  .10.201.7.10 10.201.7.10. 0x0a.201.7.10 a.b.c.d all localhost ::1 '[::1]' \
  '2001:db8::10' '10.201.7.10#' '!10.201.7.10' '10.201.7.10|g' \
  "10.201.7.10${nl}acl from_agent src all" '10.201.7.10 acl' '"10.201.7.10"' 10.201.7.1０; do
  refused "the agent address '$bad'" "SANDBOX_AGENT_IP=$bad" "$good_sidecar"
  refused "the sidecar address '$bad'" "$good_agent" "SANDBOX_SIDECAR_IP=$bad"
  [ -z "$bad" ] || refused "the relay address '$bad'" "$good_agent" "$good_sidecar" "SANDBOX_RELAY_IP=$bad"
done
refused "no addresses at all"
# [B21] Two roles on one address would hand one's list to the other.
refused "the agent and the sidecar on one address" "$good_agent" "SANDBOX_SIDECAR_IP=$AGENT"
refused "the relay on the agent's address" "$good_agent" "$good_sidecar" "SANDBOX_RELAY_IP=$AGENT"
refused "the relay on the sidecar's address" "$good_agent" "$good_sidecar" "SANDBOX_RELAY_IP=$SIDECAR"
for bad in 2 yes true on -1 '1 ' "1${nl}http_access allow all"; do
  refused "SANDBOX_ALLOW_HTTP='$bad'" "$good_agent" "$good_sidecar" "SANDBOX_ALLOW_HTTP=$bad"
done
for bad in 0 -5 1.5 25MB '25 MB' 025 1234567 "25${nl}http_access allow all" '25 KB' abc; do
  refused "a request cap of '$bad'" "$good_agent" "$good_sidecar" "SANDBOX_REQUEST_MAX_MB=$bad"
  refused "a reply cap of '$bad'" "$good_agent" "$good_sidecar" "SANDBOX_REPLY_MAX_MB=$bad"
done
for bad in 10.202.7.0 10.202.7.0/ 10.202.7.0/33 10.202.7.0/0 10.202.7/24 0.0.0.0/0 all \
  '10.202.7.0/24 all' "10.202.7.0/24${nl}x" 'fd00::/8'; do
  refused "an egress network of '$bad'" "$good_agent" "$good_sidecar" "SANDBOX_EGRESS_SUBNET=$bad"
done

# Without the session's lists there is nothing to enforce.
mv "$session/sidecar.domains" "$session/sidecar.domains.away"
refused "a session directory without sidecar.domains" "$good_agent" "$good_sidecar"
mv "$session/sidecar.domains.away" "$session/sidecar.domains"

# The paths are /var/run/squid and /etc/squid/session unless a test says otherwise.
grep -q -F 'run_dir="${SQUID_RUN_DIR:-/var/run/squid}"' "$entrypoint" || fail "the output directory does not default to /var/run/squid"
grep -q -F 'session_dir="${SQUID_SESSION_DIR:-/etc/squid/session}"' "$entrypoint" || fail "the session directory does not default to /etc/squid/session"
grep -q -F 'template="${SQUID_TEMPLATE:-/etc/squid/squid.conf.template}"' "$entrypoint" || fail "the template does not default to /etc/squid/squid.conf.template"

# ---------------------------------------------------------------------------
# 4. The image: pinned base, one package, Squid's user from the start
# ---------------------------------------------------------------------------
steps="$(sed -e 's/^[[:space:]]*#.*$//' "$containerfile" | grep -v '^[[:space:]]*$')"
printf '%s\n' "$steps" | grep -q -x 'ARG ALPINE_BASE' || fail "Containerfile: ALPINE_BASE is not a build argument without a default"
printf '%s\n' "$steps" | grep -q -F -x 'FROM ${ALPINE_BASE}' || fail "Containerfile: the base image is not \${ALPINE_BASE}"
[ "$(printf '%s\n' "$steps" | grep -c '^FROM ')" -eq 1 ] || fail "Containerfile: more than one FROM"
[ "$(printf '%s\n' "$steps" | grep -o 'apk add[^&\\]*' | tr -s ' ' | sed -e 's/ $//')" = 'apk add --no-cache squid' ] ||
  fail "Containerfile: installs something other than squid"
user_line="$(printf '%s\n' "$steps" | grep -n '^USER ' | tail -n 1)"
entry_line="$(printf '%s\n' "$steps" | grep -n '^ENTRYPOINT ' | tail -n 1)"
[ "${user_line#*:}" = 'USER 31:31' ] || fail "Containerfile: the user is not 31:31"
if [ -z "$entry_line" ] || [ "${user_line%%:*}" -ge "${entry_line%%:*}" ]; then
  fail "Containerfile: USER does not come before ENTRYPOINT"
fi
if printf '%s\n' "$steps" | grep -q -E '^(CMD|HEALTHCHECK|VOLUME|ADD) '; then
  fail "Containerfile: has a step this image should not need"
fi

if [ "$fails" -gt 0 ]; then
  printf '%s proxy check(s) failed\n' "$fails"
  exit 1
fi
echo "proxy render: all static checks passed"
