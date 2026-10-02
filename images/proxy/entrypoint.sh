#!/bin/sh
# The proxy container's first process.  [logical B20, B21]
#
# It writes this session's Squid configuration from the template and then
# becomes Squid. The values come from the container's environment, which
# ./sandbox set when it created the container (see topo_proxy in
# topology.sh):
#   SANDBOX_AGENT_IP        the agent's address: may reach the general lists
#   SANDBOX_SIDECAR_IP      the credential sidecar's address: the only one
#                           that may reach the model vendor
#   SANDBOX_RELAY_IP        the git relay's address; empty when there is none
#   SANDBOX_ALLOW_HTTP      1 = plaintext HTTP on port 80 allowed; default 0
#   SANDBOX_REQUEST_MAX_MB  largest plaintext request body, in megabytes
#   SANDBOX_REPLY_MAX_MB    largest plaintext reply body, in megabytes
#   SANDBOX_EGRESS_SUBNET   optional: the session's outbound network, added
#                           to the addresses no allowed name may resolve to
#
# Every value is checked before it is written into the configuration. An
# address must be four plain numbers with dots: anything else could be read
# by Squid as something other than one address, and these addresses are what
# keeps the agent away from the model vendor.
#
# Written for busybox sh, the only shell in the image. The container's root
# filesystem is read-only; the one place this script writes is the
# memory-backed mount at /var/run/squid.
#
# In the template, @NAME@ is replaced by a value, and a line that starts
# with a marker (the relay, plaintext HTTP on or off, the egress network) is
# kept without the marker when it applies and deleted when it does not.
set -eu

# The three paths are variables so that the tests can run this script
# outside a container. Nothing sets them in the image.
run_dir="${SQUID_RUN_DIR:-/var/run/squid}"
template="${SQUID_TEMPLATE:-/etc/squid/squid.conf.template}"
session_dir="${SQUID_SESSION_DIR:-/etc/squid/session}"

die() {
  printf 'proxy: %s\n' "$*" >&2
  exit 1
}

# True for a dotted IPv4 address: four numbers from 0 to 255, no leading
# zeros, nothing else.
is_ipv4() {
  case "$1" in
    ''|*[!0123456789.]*|.*|*.|*..*) return 1 ;;
  esac
  old_ifs="$IFS"
  IFS=.
  # shellcheck disable=SC2086  # split on dots on purpose; only digits and dots are left
  set -- $1
  IFS="$old_ifs"
  [ "$#" -eq 4 ] || return 1
  for octet in "$@"; do
    case "$octet" in
      [0123456789]|[123456789][0123456789]|1[0123456789][0123456789]) ;;
      2[01234][0123456789]|25[012345]) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# True for a whole number from 1 to 999999 with no leading zero.
is_megabytes() {
  case "$1" in
    ''|0*|*[!0123456789]*|???????*) return 1 ;;
  esac
  return 0
}

# True for an IPv4 network such as 10.89.4.0/24.
is_ipv4_net() {
  case "$1" in
    */*) ;;
    *) return 1 ;;
  esac
  is_ipv4 "${1%/*}" || return 1
  case "${1##*/}" in
    [89]|[12][0123456789]|3[012]) return 0 ;;
  esac
  return 1
}

# True for an absolute path made of characters that mean nothing to sed or
# to Squid.
is_plain_path() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_.-]*) return 1 ;;
  esac
  return 0
}

# Squid must start as its own user. Started as root it would switch user
# later and then be unable to open the standard output it logs to.
[ "$(id -u)" != 0 ] || die "refusing to run as root: start this container as Squid's user (uid 31)"

agent_ip="${SANDBOX_AGENT_IP:-}"
sidecar_ip="${SANDBOX_SIDECAR_IP:-}"
relay_ip="${SANDBOX_RELAY_IP:-}"
allow_http="${SANDBOX_ALLOW_HTTP:-0}"
request_max="${SANDBOX_REQUEST_MAX_MB:-25}"
reply_max="${SANDBOX_REPLY_MAX_MB:-200}"
egress_net="${SANDBOX_EGRESS_SUBNET:-}"

is_ipv4 "$agent_ip" || die "SANDBOX_AGENT_IP must be a plain IPv4 address such as 10.89.4.10"
is_ipv4 "$sidecar_ip" || die "SANDBOX_SIDECAR_IP must be a plain IPv4 address such as 10.89.4.3"
if [ -n "$relay_ip" ]; then
  is_ipv4 "$relay_ip" || die "SANDBOX_RELAY_IP must be a plain IPv4 address or empty"
fi
# [logical B21] The rules tell the three apart by address. Two of them
# sharing one would hand one's list to the other.
[ "$agent_ip" != "$sidecar_ip" ] || die "the agent and the sidecar have the same address"
[ "$relay_ip" != "$agent_ip" ] || die "the agent and the git relay have the same address"
[ "$relay_ip" != "$sidecar_ip" ] || die "the sidecar and the git relay have the same address"

case "$allow_http" in
  0|1) ;;
  *) die "SANDBOX_ALLOW_HTTP must be 0 or 1" ;;
esac
is_megabytes "$request_max" || die "SANDBOX_REQUEST_MAX_MB must be a whole number of megabytes"
is_megabytes "$reply_max" || die "SANDBOX_REPLY_MAX_MB must be a whole number of megabytes"
if [ -n "$egress_net" ]; then
  is_ipv4_net "$egress_net" || die "SANDBOX_EGRESS_SUBNET must be an IPv4 network such as 10.90.4.0/24"
fi

is_plain_path "$run_dir" || die "unusable directory for the configuration: $run_dir"
is_plain_path "$session_dir" || die "unusable directory for the session's lists: $session_dir"
[ -r "$template" ] || die "the template $template is missing"
if [ ! -d "$run_dir" ] || [ ! -w "$run_dir" ]; then
  die "$run_dir is not a writable directory"
fi
# The lists ./sandbox wrote for this session. Squid would refuse to start
# without them; saying which one is missing is kinder.
for list in agent.domains sidecar.domains relay.domains extra.conf; do
  [ -r "$session_dir/$list" ] || die "$session_dir/$list is missing: the session's allowlist was not rendered"
done

# The session's network is the /24 the agent's address is in.
session_net="${agent_ip%.*}.0/24"

# Lines that depend on a setting: drop the marker to keep the line, or
# delete the whole line.
if [ -n "$relay_ip" ]; then relay_lines='s|^@IF_RELAY@||'; else relay_lines='/^@IF_RELAY@/d'; fi
if [ -n "$egress_net" ]; then egress_lines='s|^@IF_EGRESS@||'; else egress_lines='/^@IF_EGRESS@/d'; fi
if [ "$allow_http" = 1 ]; then
  http_lines='s|^@IF_HTTP@||'
  no_http_lines='/^@IF_NO_HTTP@/d'
else
  http_lines='/^@IF_HTTP@/d'
  no_http_lines='s|^@IF_NO_HTTP@||'
fi

# Written under another name and renamed, so Squid never reads half a file.
umask 022
sed \
  -e "$relay_lines" \
  -e "$egress_lines" \
  -e "$http_lines" \
  -e "$no_http_lines" \
  -e "s|@AGENT_IP@|$agent_ip|g" \
  -e "s|@SIDECAR_IP@|$sidecar_ip|g" \
  -e "s|@RELAY_IP@|$relay_ip|g" \
  -e "s|@SESSION_NET@|$session_net|g" \
  -e "s|@EGRESS_NET@|$egress_net|g" \
  -e "s|@REQUEST_MAX_MB@|$request_max|g" \
  -e "s|@REPLY_MAX_MB@|$reply_max|g" \
  -e "s|@RUN_DIR@|$run_dir|g" \
  -e "s|@SESSION_DIR@|$session_dir|g" \
  "$template" > "$run_dir/squid.conf.tmp"

# A marker nobody filled in means the template and this script disagree.
if grep -q '@[A-Z_]*@' "$run_dir/squid.conf.tmp"; then
  die "the rendered configuration still has a placeholder in it; refusing to start"
fi
mv -f "$run_dir/squid.conf.tmp" "$run_dir/squid.conf"

# -N: stay in the foreground as this one process, so Podman sees Squid start
# and stop. -f: the configuration just written, and no other.
exec squid -N -f "$run_dir/squid.conf"
