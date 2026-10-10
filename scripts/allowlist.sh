# shellcheck shell=bash
# allowlist.sh — which hosts the egress proxy lets through.  [logical B20, B21]
#
# ./sandbox sources this file. Nothing here talks to Podman or to the
# network: these functions read and write text files on your host.
#
# Where the lists come from
#   policy/allowlist.base.txt      hosts every agent may reach
#   policy/presets/<name>.txt      named groups you can switch on
#   policy/never-allow.txt         hosts that can never be added
#   agents/<agent>/allowlist.txt   that agent's hosts, in two sections:
#                                  [agent] and [sidecar]
#   <config dir>/allowlist.local   your own entries, one per line:
#                                  kind<TAB>value<TAB>until<TAB>reason
#
# What comes out (allowlist_render), in <session dir>/proxy/, which the
# proxy container mounts read-only:
#   agent.domains    names the agent's address may reach
#   sidecar.domains  names the credential sidecar's address may reach: the
#                    model vendor, and nobody else gets those [logical B21]
#   relay.domains    the one git host of the optional git relay
#   extra.conf       Squid rules for host:port and URL-prefix entries
#
# Everything that ends up in a file Squid reads is checked character by
# character first, so nothing you type (or paste) can add a Squid directive.
#
# Functions return 1 and explain themselves on stderr; they never exit, so
# the caller decides what happens next. allowlist_never_allow_hit prints its
# answer on stdout.
#
# Written for bash 3.2 (macOS): no associative arrays, no mapfile.

# The repository root, unless ./sandbox has set SANDBOX_ROOT.
_ALLOWLIST_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Character sets, spelled out. A range such as [a-z] means different things
# in different locales; a list of characters means the same everywhere.
_AL_LOWER='abcdefghijklmnopqrstuvwxyz'
_AL_UPPER='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
_AL_DIGIT='0123456789'
# Kept in variables so that no $'...' has to sit inside a "${var%...}",
# where old and new versions of bash disagree about how to read it.
_AL_TAB=$'\t'
_AL_NL=$'\n'
_AL_CR=$'\r'

# Results of _allowlist_split and _allowlist_parse (bash 3.2 has no better
# way to hand back several values).
_AL_KIND="" _AL_VALUE="" _AL_UNTIL="" _AL_REASON=""
_AL_SCHEME="" _AL_HOST="" _AL_PORT="" _AL_PATH=""

_allowlist_say() { printf 'allowlist: %s\n' "$*" >&2; }

_allowlist_root() { printf '%s' "${SANDBOX_ROOT:-$_ALLOWLIST_SELF}"; }

# Your own entries. The directory is the one ./sandbox keeps its settings in.
_allowlist_local() {
  printf '%s' "${SANDBOX_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-sandbox}/allowlist.local"
}

# True when every character of $1 is one of the characters in $2.
_allowlist_only() {
  case "$1" in
    *[!"$2"]*) return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Host names
# ---------------------------------------------------------------------------

# allowlist_valid_host <host>
# What may go on a list: lowercase labels of letters, digits and hyphens, at
# least one dot, optionally a leading dot meaning "this domain and everything
# beneath it". A URL, a port or an address pasted in by mistake would either
# be ignored by Squid or match something other than what was meant, so each
# is refused with a hint about what to type instead.
allowlist_valid_host() {
  local h="${1-}" bare rest label last=""
  bare="${h#.}"
  case "$h" in
    ''|.)
      _allowlist_say "empty host name"
      return 1 ;;
    *://*)
      _allowlist_say "'$h' has a scheme: give the bare host name"
      return 1 ;;
    */*)
      _allowlist_say "'$h' has a path: the proxy matches host names, not URLs"
      return 1 ;;
    *:*:*|*'['*|*']'*)
      _allowlist_say "'$h' is an IP address: the proxy matches the name the agent asks for, so allow that name"
      return 1 ;;
    *:*)
      _allowlist_say "'$h' has a port: give the bare host name here, or add it as a host:port entry"
      return 1 ;;
  esac
  if ! _allowlist_only "$bare" "${_AL_LOWER}${_AL_UPPER}${_AL_DIGIT}.-"; then
    _allowlist_say "'$h' has a character that cannot be in a host name: use letters, digits, hyphens and dots only"
    return 1
  fi
  if ! _allowlist_only "$bare" "${_AL_LOWER}${_AL_DIGIT}.-"; then
    _allowlist_say "'$h' has uppercase letters: host names go in lowercase"
    return 1
  fi
  if _allowlist_only "$bare" "${_AL_DIGIT}."; then
    _allowlist_say "'$h' is an IP address: the proxy matches the name the agent asks for, so allow that name"
    return 1
  fi
  if [ "${#bare}" -gt 253 ]; then
    _allowlist_say "'$h' is longer than a host name can be (253 characters)"
    return 1
  fi
  case "$bare" in
    *.*) ;;
    *)
      _allowlist_say "'$h' is not a host name: expected something like docs.example.com or .example.com"
      return 1 ;;
  esac
  # Label by label: none empty, none longer than 63, none starting or ending
  # with a hyphen.
  rest="$bare"
  while :; do
    label="${rest%%.*}"
    if [ -z "$label" ]; then
      _allowlist_say "'$h' has an empty label (two dots together, or a dot at the end)"
      return 1
    fi
    if [ "${#label}" -gt 63 ]; then
      _allowlist_say "'$h' has a label longer than 63 characters"
      return 1
    fi
    case "$label" in
      -*|*-)
        _allowlist_say "'$h' has a label that starts or ends with a hyphen"
        return 1 ;;
    esac
    last="$label"
    case "$rest" in
      *.*) rest="${rest#*.}" ;;
      *) break ;;
    esac
  done
  # No real top-level domain is a number. A name that ends in one is an
  # address written in an unusual way.
  if _allowlist_only "$last" "$_AL_DIGIT"; then
    _allowlist_say "'$h' ends in a number, which makes it an address, not a name"
    return 1
  fi
  return 0
}

# True when allowlist entry $1 would let through the host that entry $2
# names: they name the same host, or $1 is a pattern (leading dot) with $2
# beneath it, or $2 is a pattern with $1 beneath it.
_allowlist_covers() {
  local host="$1" entry="$2" bare="${1#.}" nbare="${2#.}"
  if [ "$bare" = "$nbare" ]; then
    return 0
  fi
  case "$host" in
    .*) case "$nbare" in *".$bare") return 0 ;; esac ;;
  esac
  case "$entry" in
    .*) case "$bare" in *".$nbare") return 0 ;; esac ;;
  esac
  return 1
}

# allowlist_never_allow_hit <host>
# Prints the entry of policy/never-allow.txt that covers <host>, with its
# reason, and returns 0; returns 1 when there is none. An entry without a
# leading dot names one host; with it, the domain and everything beneath. An
# allowlist pattern wide enough to cover an entry is a hit too, so
# `.googleapis.com` does not bring storage.googleapis.com back in.
# A missing never-allow file counts as a hit: no list, no additions.
allowlist_never_allow_hit() {
  local host="${1-}" file entry reason
  file="$(_allowlist_root)/policy/never-allow.txt"
  if [ ! -f "$file" ]; then
    printf '%s\n' "policy/never-allow.txt is missing, so nothing can be checked against it"
    return 0
  fi
  while read -r entry reason || [ -n "$entry" ]; do
    entry="${entry%"$_AL_CR"}"
    case "$entry" in ''|'#'*) continue ;; esac
    if _allowlist_covers "$host" "$entry"; then
      reason="${reason%"$_AL_CR"}"
      reason="${reason#\#}"
      reason="${reason#"${reason%%[![:space:]]*}"}"
      printf '%s%s\n' "$entry" "${reason:+ — $reason}"
      return 0
    fi
  done < "$file"
  return 1
}

# allowlist_upload_capable <host>
# True for hosts known to accept uploads from anyone who brings an account
# of their own. Allowing one is allowing the whole workspace to leave, so
# ./sandbox prints a warning. A pattern that covers one of them counts.
allowlist_upload_capable() {
  local host="${1-}" known
  for known in \
    github.com \
    api.github.com \
    uploads.github.com \
    gitlab.com \
    registry.npmjs.org \
    upload.pypi.org
  do
    # github.com: git push. api.github.com: gists, file contents, issues.
    # uploads.github.com: release files. gitlab.com: git push and its API.
    # registry.npmjs.org: npm publish. upload.pypi.org: package uploads.
    if _allowlist_covers "$host" "$known"; then
      return 0
    fi
  done
  return 1
}

# Reads a list file and prints its host names, one per line. Format: one
# host per line, `#` starts a comment, blank lines are fine. With a second
# argument (`agent` or `sidecar`) the file must be divided into `[agent]` and
# `[sidecar]` sections and only that section is printed. Every host in the
# file is checked, whichever section was asked for.
_allowlist_read_hosts() {
  local file="$1" want="${2-}" line current="" n=0
  if [ ! -f "$file" ]; then
    _allowlist_say "$file is missing"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '['*']')
        current="${line#[}"
        current="${current%]}"
        case "$current" in
          agent|sidecar) ;;
          *)
            _allowlist_say "$file line $n: unknown section [$current]; the sections are [agent] and [sidecar]"
            return 1 ;;
        esac
        if [ -z "$want" ]; then
          _allowlist_say "$file line $n: this file has no sections; only an agent's allowlist.txt does"
          return 1
        fi
        continue ;;
    esac
    if [ -n "$want" ] && [ -z "$current" ]; then
      _allowlist_say "$file line $n: '$line' comes before the first section; put it under [agent] or [sidecar]"
      return 1
    fi
    if ! allowlist_valid_host "$line"; then
      _allowlist_say "$file line $n is not usable"
      return 1
    fi
    if [ -z "$want" ] || [ "$current" = "$want" ]; then
      printf '%s\n' "$line"
    fi
  done < "$file"
  return 0
}

# Prints the model vendor's host that allowlist entry $1 would cover, and
# returns 0; returns 1 when it covers none. The vendors' hosts are the
# `[sidecar]` sections of every shipped agent, not only the one in use:
# reaching any model vendor from the agent's address is the same way out.
# [logical B21]
_allowlist_vendor_hit() {
  local host="$1" file hosts vendor
  for file in "$(_allowlist_root)"/agents/*/allowlist.txt; do
    [ -f "$file" ] || continue
    if ! hosts="$(_allowlist_read_hosts "$file" sidecar)"; then
      printf '%s\n' "an unreadable list ($file)"
      return 0
    fi
    while IFS= read -r vendor; do
      [ -n "$vendor" ] || continue
      if _allowlist_covers "$host" "$vendor"; then
        printf '%s\n' "$vendor"
        return 0
      fi
    done <<EOF
$hosts
EOF
  done
  return 1
}

# The two reasons a well-formed host name is still turned away from the
# agent's list. Returns 0 (and says why) when it is refused.
_allowlist_refused() {
  local host="$1" hit
  if hit="$(allowlist_never_allow_hit "$host")"; then
    _allowlist_say "$host is on policy/never-allow.txt ($hit): allow the specific host you need, not this one"
    return 0
  fi
  if hit="$(_allowlist_vendor_hit "$host")"; then
    _allowlist_say "$host covers $hit, a model vendor's host: those are reachable from the credential sidecar only"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Dates
# ---------------------------------------------------------------------------

# True for YYYY-MM-DD with a month of 01-12 and a day of 01-31.
_allowlist_valid_date() {
  local d="${1-}" digits day
  digits="${d//-/}"
  if [ "${#d}" -ne 10 ] || [ "${#digits}" -ne 8 ] \
     || [ "${d:4:1}" != - ] || [ "${d:7:1}" != - ] \
     || ! _allowlist_only "$digits" "$_AL_DIGIT"; then
    return 1
  fi
  case "${d:5:2}" in
    01|02|03|04|05|06|07|08|09|10|11|12) ;;
    *) return 1 ;;
  esac
  day="${d:8:2}"
  day="${day#0}"
  if [ "$day" -lt 1 ] || [ "$day" -gt 31 ]; then
    return 1
  fi
  return 0
}

# Today's date. Tests set ALLOWLIST_TODAY so that expiry does not depend on
# the day they are run.
_allowlist_today() {
  local today="${ALLOWLIST_TODAY:-}"
  if [ -z "$today" ]; then
    today="$(date +%Y-%m-%d)"
  fi
  if ! _allowlist_valid_date "$today"; then
    _allowlist_say "cannot tell today's date: '$today' is not YYYY-MM-DD"
    return 1
  fi
  printf '%s' "$today"
}

# True when date $1 is earlier than date $2. An entry is good through its
# `until` day and dropped from the day after.
_allowlist_before() {
  [ "${1//-/}" -lt "${2//-/}" ]
}

# ---------------------------------------------------------------------------
# Entries of allowlist.local
# ---------------------------------------------------------------------------

# Splits one line into _AL_KIND, _AL_VALUE, _AL_UNTIL and _AL_REASON.
# Returns 1 when the line does not have four tab-separated fields.
_allowlist_split() {
  local line="$1" tab="$_AL_TAB"
  case "$line" in
    *"$tab"*"$tab"*"$tab"*) ;;
    *) return 1 ;;
  esac
  _AL_KIND="${line%%"$tab"*}"
  line="${line#*"$tab"}"
  _AL_VALUE="${line%%"$tab"*}"
  line="${line#*"$tab"}"
  _AL_UNTIL="${line%%"$tab"*}"
  _AL_REASON="${line#*"$tab"}"
  return 0
}

# Checks one entry and takes it apart into _AL_HOST, _AL_PORT, _AL_SCHEME
# and _AL_PATH. This is the gate for everything that later goes into a file
# Squid reads; it returns 1, having said why, for anything it does not
# recognise completely.
#   host      docs.example.com  or  .example.com
#   hostport  db.example.com:8443      one exact host, one port
#   url       http://host/path         a plaintext URL prefix
#             https://host/path        accepted, but see allowlist_render
#   preset    the name of a file in policy/presets/
_allowlist_parse() {
  local kind="${1-}" value="${2-}" rest
  _AL_SCHEME="" _AL_HOST="" _AL_PORT="" _AL_PATH=""
  case "$kind" in
    host)
      allowlist_valid_host "$value" || return 1
      _AL_HOST="$value"
      ;;
    hostport)
      case "$value" in
        *:*) ;;
        *)
          _allowlist_say "'$value' is not host:port"
          return 1 ;;
      esac
      _AL_HOST="${value%:*}"
      _AL_PORT="${value##*:}"
      allowlist_valid_host "$_AL_HOST" || return 1
      case "$_AL_HOST" in
        .*)
          _allowlist_say "'$value': a host:port entry names one exact host, without a leading dot"
          return 1 ;;
      esac
      # 1-65535, digits only, no leading zero.
      if [ -z "$_AL_PORT" ] || [ "${#_AL_PORT}" -gt 5 ] \
         || ! _allowlist_only "$_AL_PORT" "$_AL_DIGIT" \
         || [ "${_AL_PORT:0:1}" = 0 ] || [ "$_AL_PORT" -gt 65535 ]; then
        _allowlist_say "'$value': the port must be a number from 1 to 65535"
        return 1
      fi
      ;;
    url)
      case "$value" in
        http://*)  _AL_SCHEME=http;  rest="${value#http://}" ;;
        https://*) _AL_SCHEME=https; rest="${value#https://}" ;;
        *)
          _allowlist_say "'$value' is not a URL: expected http://host/path"
          return 1 ;;
      esac
      case "$rest" in
        */*) _AL_HOST="${rest%%/*}"; _AL_PATH="/${rest#*/}" ;;
        *)   _AL_HOST="$rest";       _AL_PATH="/" ;;
      esac
      allowlist_valid_host "$_AL_HOST" || return 1
      case "$_AL_HOST" in
        .*)
          _allowlist_say "'$value': a URL names one exact host, without a leading dot"
          return 1 ;;
      esac
      # The path goes into a Squid pattern. Only characters that mean
      # nothing to Squid's configuration reader are let through: no spaces,
      # quotes, `#`, `$`, backslashes, brackets or query strings.
      if ! _allowlist_only "$_AL_PATH" "${_AL_LOWER}${_AL_UPPER}${_AL_DIGIT}/._~@%+-"; then
        _allowlist_say "'$value': the path may contain only letters, digits and / . _ ~ @ % + -"
        return 1
      fi
      ;;
    preset)
      if [ -z "$value" ] || ! _allowlist_only "$value" "${_AL_LOWER}${_AL_DIGIT}-"; then
        _allowlist_say "'$value' is not a preset name"
        return 1
      fi
      if [ ! -f "$(_allowlist_root)/policy/presets/$value.txt" ]; then
        _allowlist_say "there is no preset '$value' in policy/presets/"
        return 1
      fi
      ;;
    *)
      _allowlist_say "unknown kind '$kind': expected host, hostport, url or preset"
      return 1
      ;;
  esac
  return 0
}

# allowlist_add <kind> <value> <until> <reason>
# Adds one entry to your allowlist.local. <until> is YYYY-MM-DD (the last day
# the entry counts) or `-` for no end date. The reason is required: it is
# what tells you, months later, why the entry is there. Nothing takes effect
# until the next allowlist_render.
allowlist_add() {
  local kind="${1-}" value="${2-}" until="${3-}" reason="${4-}"
  local file line today tmp
  if [ "$#" -ne 4 ]; then
    _allowlist_say "usage: allowlist_add <host|hostport|url|preset> <value> <YYYY-MM-DD|-> <reason>"
    return 1
  fi
  _allowlist_parse "$kind" "$value" || return 1
  if [ "$kind" != preset ] && _allowlist_refused "$_AL_HOST"; then
    return 1
  fi
  if [ "$until" != - ]; then
    if ! _allowlist_valid_date "$until"; then
      _allowlist_say "'$until' is not a date: expected YYYY-MM-DD, or - for no end date"
      return 1
    fi
    today="$(_allowlist_today)" || return 1
    if _allowlist_before "$until" "$today"; then
      _allowlist_say "$until has already passed"
      return 1
    fi
  fi
  # One line of plain text. A tab or a line break in it would start a new
  # field or a new entry in allowlist.local.
  reason="${reason#"${reason%%[![:space:]]*}"}"
  reason="${reason%"${reason##*[![:space:]]}"}"
  case "$reason" in
    '')
      _allowlist_say "a reason is required: say why this entry is needed"
      return 1 ;;
    *[[:cntrl:]]*)
      _allowlist_say "the reason must be one line of plain text: no tabs, no line breaks, no control characters"
      return 1 ;;
  esac
  if [ "$_AL_SCHEME" = https ]; then
    _allowlist_say "note: the proxy cannot see paths inside HTTPS, so '$value' allows the whole host $_AL_HOST"
  fi

  file="$(_allowlist_local)"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      if _allowlist_split "$line" && [ "$_AL_KIND" = "$kind" ] && [ "$_AL_VALUE" = "$value" ]; then
        _allowlist_say "$value is already in $file"
        return 0
      fi
    done < "$file"
  fi
  mkdir -p "${file%/*}" || return 1
  # Written under another name and renamed, so a reader never sees half a
  # file.
  tmp="$file.tmp.$$"
  {
    if [ -f "$file" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line"
      done < "$file"
    else
      printf '%s\n' \
        "# Your own egress allowlist entries. Written by ./sandbox allow and deny." \
        "# kind<TAB>value<TAB>until<TAB>reason" \
        "#   kind:  host, hostport, url or preset" \
        "#   until: YYYY-MM-DD (the last day the entry counts) or - for no end date"
    fi
    printf '%s\t%s\t%s\t%s\n' "$kind" "$value" "$until" "$reason"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file"
}

# allowlist_remove <value>
# Removes every entry of your allowlist.local with exactly this value.
# Entries that ship with agent-sandbox (policy/, agents/) are not yours to
# remove from here: edit those files.
allowlist_remove() {
  local value="${1-}" file line tmp found=0
  file="$(_allowlist_local)"
  if [ -z "$value" ]; then
    _allowlist_say "usage: allowlist_remove <value>"
    return 1
  fi
  if [ ! -f "$file" ]; then
    _allowlist_say "$value is not in $file (the file does not exist)"
    return 1
  fi
  tmp="$file.tmp.$$"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) ;;
      *)
        if _allowlist_split "$line" && [ "$_AL_VALUE" = "$value" ]; then
          found=1
          continue
        fi ;;
    esac
    printf '%s\n' "$line"
  done < "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ "$found" -eq 0 ]; then
    rm -f "$tmp"
    _allowlist_say "$value is not in $file"
    return 1
  fi
  mv -f "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Rendering the session's lists
# ---------------------------------------------------------------------------

# Prints a list of hosts sorted, without duplicates, and without entries
# that a pattern in the same list already covers. Squid refuses to start
# when a list holds both `.example.com` and `www.example.com`.
_allowlist_minimise() {
  local list a b drop out=""
  list="$(printf '%s\n' "$1" | LC_ALL=C sort -u)"
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    drop=0
    while IFS= read -r b; do
      case "$b" in
        .*)
          if [ "$a" != "$b" ]; then
            case "${a#.}" in
              "${b#.}"|*"$b") drop=1 ;;
            esac
          fi ;;
      esac
    done <<EOF
$list
EOF
    if [ "$drop" -eq 0 ]; then
      out="$out$a$_AL_NL"
    fi
  done <<EOF
$list
EOF
  printf '%s' "$out"
}

# Writes $2 to file $1 under a temporary name in the same directory and
# renames it into place, so Squid never reads half a list. Mode 0644: Squid
# reads these as "anyone", and they hold host names, not secrets.
_allowlist_write() {
  local file="$1" content="$2" tmp
  tmp="${file%/*}/.${file##*/}.tmp.$$"
  if [ -n "$content" ]; then
    printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    : > "$tmp" || return 1
  fi
  chmod 0644 "$tmp" && mv -f "$tmp" "$file"
}

# allowlist_render <session_dir> <agent> [relay_host]
# Builds the four files the proxy reads, in <session_dir>/proxy/.
#   * Entries whose `until` day has passed are left out, with a line on
#     stderr for each.
#   * Any entry that policy/never-allow.txt covers, or that would let the
#     agent reach a model vendor's host, stops the render: it returns 1 and
#     leaves the files that are there untouched.
#   * An https:// URL entry cannot be enforced as a URL (the proxy does not
#     see paths inside HTTPS), so it becomes its host name, and this says so.
allowlist_render() {
  local session_dir="${1-}" agent="${2-}" relay="${3-}"
  local root dir today file line host hosts hit n=0 i=0 bs="\\" pattern
  local agent_list sidecar_list relay_list="" extra=""
  if [ -z "$session_dir" ] || [ -z "$agent" ]; then
    _allowlist_say "usage: allowlist_render <session_dir> <agent> [relay_host]"
    return 1
  fi
  root="$(_allowlist_root)"
  dir="$session_dir/proxy"
  if ! _allowlist_only "$agent" "${_AL_LOWER}${_AL_DIGIT}-" \
     || [ ! -f "$root/agents/$agent/allowlist.txt" ]; then
    _allowlist_say "unknown agent '$agent': there is no agents/$agent/allowlist.txt"
    return 1
  fi
  today="$(_allowlist_today)" || return 1

  # The agent's list: the base list plus the agent plug-in's own.
  agent_list="$(_allowlist_read_hosts "$root/policy/allowlist.base.txt")" || return 1
  hosts="$(_allowlist_read_hosts "$root/agents/$agent/allowlist.txt" agent)" || return 1
  agent_list="$agent_list$_AL_NL$hosts"
  # [logical B21] The vendor's hosts go to the sidecar's list and no other.
  sidecar_list="$(_allowlist_read_hosts "$root/agents/$agent/allowlist.txt" sidecar)" || return 1
  if [ -n "$relay" ]; then
    allowlist_valid_host "$relay" || return 1
    case "$relay" in
      .*)
        _allowlist_say "'$relay': the git relay's host is one exact host, without a leading dot"
        return 1 ;;
    esac
    relay_list="$relay"
  fi

  # Your own entries.
  file="$(_allowlist_local)"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      line="${line%"$_AL_CR"}"
      case "$line" in ''|'#'*) continue ;; esac
      if ! _allowlist_split "$line"; then
        _allowlist_say "$file line $n: expected kind<TAB>value<TAB>until<TAB>reason"
        return 1
      fi
      if ! _allowlist_parse "$_AL_KIND" "$_AL_VALUE"; then
        _allowlist_say "$file line $n is not usable: fix it or remove it"
        return 1
      fi
      if [ "$_AL_UNTIL" != - ]; then
        if ! _allowlist_valid_date "$_AL_UNTIL"; then
          _allowlist_say "$file line $n: '$_AL_UNTIL' is not a date: expected YYYY-MM-DD, or - for no end date"
          return 1
        fi
        if _allowlist_before "$_AL_UNTIL" "$today"; then
          _allowlist_say "dropped $_AL_VALUE: it was allowed until $_AL_UNTIL, which has passed"
          continue
        fi
      fi
      case "$_AL_KIND" in
        host)
          agent_list="$agent_list$_AL_NL$_AL_HOST"
          ;;
        preset)
          hosts="$(_allowlist_read_hosts "$root/policy/presets/$_AL_VALUE.txt")" || return 1
          agent_list="$agent_list$_AL_NL$hosts"
          ;;
        hostport)
          if _allowlist_refused "$_AL_HOST"; then
            return 1
          fi
          # An exception to "tunnels go to port 443 only": this host, this
          # port, from the agent. The first rule refuses the name if it
          # resolves to a private address; it is looked up only here, after
          # it has matched.
          i=$((i + 1))
          extra="${extra}acl extra_${i}_host dstdomain -n ${_AL_HOST}
acl extra_${i}_port port ${_AL_PORT}
http_access deny method_connect from_agent extra_${i}_host extra_${i}_port to_private
http_access allow method_connect from_agent extra_${i}_host extra_${i}_port
"
          ;;
        url)
          if [ "$_AL_SCHEME" = https ]; then
            _allowlist_say "note: the proxy cannot see paths inside HTTPS, so '$_AL_VALUE' allows the whole host $_AL_HOST"
            agent_list="$agent_list$_AL_NL$_AL_HOST"
            continue
          fi
          if _allowlist_refused "$_AL_HOST"; then
            return 1
          fi
          # A plaintext URL prefix. The pattern is anchored at the start and
          # every character with a meaning in a pattern (`.` and `+` are the
          # only ones _allowlist_parse lets through) is escaped. A port
          # other than 80 would appear in the URL and so does not match.
          pattern="^http://${_AL_HOST}${_AL_PATH}"
          pattern="${pattern//./$bs.}"
          pattern="${pattern//+/$bs+}"
          i=$((i + 1))
          extra="${extra}acl extra_${i}_host dstdomain -n ${_AL_HOST}
acl extra_${i}_url url_regex ${pattern}
http_access deny !method_connect from_agent extra_${i}_host extra_${i}_url path_dotdot
http_access deny !method_connect from_agent extra_${i}_host extra_${i}_url to_private
http_access allow !method_connect from_agent extra_${i}_host extra_${i}_url
"
          ;;
      esac
    done < "$file"
  fi

  # Nothing on never-allow gets onto any list, and no model vendor's host
  # gets onto the agent's.
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    if _allowlist_refused "$host"; then
      return 1
    fi
  done <<EOF
$agent_list
EOF
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    if hit="$(allowlist_never_allow_hit "$host")"; then
      _allowlist_say "$host is on policy/never-allow.txt ($hit)"
      return 1
    fi
  done <<EOF
$sidecar_list
$relay_list
EOF

  agent_list="$(_allowlist_minimise "$agent_list")"
  sidecar_list="$(_allowlist_minimise "$sidecar_list")"

  mkdir -p "$dir" || return 1
  chmod 0755 "$dir" || return 1
  _allowlist_write "$dir/agent.domains" "$agent_list" || return 1
  _allowlist_write "$dir/sidecar.domains" "$sidecar_list" || return 1
  _allowlist_write "$dir/relay.domains" "$relay_list" || return 1
  _allowlist_write "$dir/extra.conf" "${extra%"$_AL_NL"}" || return 1
  return 0
}
