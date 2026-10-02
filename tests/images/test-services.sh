#!/usr/bin/env bash
# services/*/service.conf: parsed the way ./sandbox parses them (`read`,
# split at the first `=`, never sourced), every required key present, every
# line explained, and the values the two shipped services are meant to have.
#
# Looks for literal text such as $( in the files, hence:
# shellcheck disable=SC2016
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

required="IMAGE VERSIONS USER MEMORY PIDS PORT URL_VAR URL_TEMPLATE HEALTH"

# to_bytes <size>: 512m, 1g, 64k or a plain number.
to_bytes() {
  case "$1" in
    *g) echo $((${1%g} * 1024 * 1024 * 1024)) ;;
    *m) echo $((${1%m} * 1024 * 1024)) ;;
    *k) echo $((${1%k} * 1024)) ;;
    *) echo "$1" ;;
  esac
}

# load <file>: fills the variables below. Same loop as load_service in
# ./sandbox.
load() {
  local key value
  IMAGE="" VERSIONS="" USER_="" MEMORY="" PIDS="" PORT="" URL_VAR="" URL_TEMPLATE="" HEALTH=""
  TMPFS=() ENV=() COMMAND=() UNKNOWN="" SEEN=""
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      '' | '#'*) continue ;;
      IMAGE) IMAGE="$value" ;;
      VERSIONS) VERSIONS="$value" ;;
      USER) USER_="$value" ;;
      MEMORY) MEMORY="$value" ;;
      PIDS) PIDS="$value" ;;
      PORT) PORT="$value" ;;
      URL_VAR) URL_VAR="$value" ;;
      URL_TEMPLATE) URL_TEMPLATE="$value" ;;
      HEALTH) HEALTH="$value" ;;
      TMPFS) TMPFS+=("$value") ;;
      ENV) ENV+=("$value") ;;
      COMMAND_ARG) COMMAND+=("$value") ;;
      *) UNKNOWN="$UNKNOWN $key" ;;
    esac
    SEEN="$SEEN $key"
  done <"$1"
}

for file in "$root"/services/*/service.conf; do
  name="$(basename "$(dirname "$file")")"
  load "$file"

  if [ -z "$UNKNOWN" ]; then pass "$name: only known keys"; else fail "$name: unknown keys:$UNKNOWN"; fi
  for key in $required; do
    case " $SEEN " in
      *" $key "*) ;;
      *) fail "$name: required key $key is missing" ;;
    esac
    if [ "$(printf '%s\n' "$SEEN" | tr ' ' '\n' | grep -cx "$key")" -gt 1 ]; then fail "$name: $key appears more than once"; fi
  done
  if [ -n "$IMAGE" ] && [ -n "$VERSIONS" ] && [ -n "$USER_" ] && [ -n "$MEMORY" ] && [ -n "$PIDS" ] && [ -n "$PORT" ] \
    && [ -n "$URL_VAR" ] && [ -n "$URL_TEMPLATE" ] && [ -n "$HEALTH" ]; then
    pass "$name: every required key has a value"
  else
    fail "$name: a required key is empty"
  fi

  if [[ "$IMAGE" =~ ^(UNPINNED|[a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64})$ ]]; then
    pass "$name: IMAGE is UNPINNED or pinned by digest"
  else
    fail "$name: IMAGE is neither UNPINNED nor digest-pinned: $IMAGE"
  fi
  # The tag pin-images.sh will pull, directly above IMAGE.
  if grep -B 1 '^IMAGE=' "$file" | head -n 1 | grep -qE '^# tag: docker\.io/library/[a-z]+:[0-9][A-Za-z0-9.-]*$'; then
    pass "$name: '# tag:' line directly above IMAGE"
  else
    fail "$name: no '# tag: <reference>' line directly above IMAGE"
  fi
  check_not "$name: the tag is not 'latest'" grep -qE '^# tag: .*:latest$' "$file"

  if [[ "$USER_" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]]; then pass "$name: USER is a non-root uid:gid"; else fail "$name: USER is '$USER_'"; fi
  if [[ "$PIDS" =~ ^[1-9][0-9]*$ ]] && [[ "$PORT" =~ ^[1-9][0-9]*$ ]]; then pass "$name: PIDS and PORT are numbers"; else fail "$name: PIDS or PORT is not a number"; fi
  if [[ "$MEMORY" =~ ^[1-9][0-9]*[mg]$ ]]; then pass "$name: MEMORY is a size"; else fail "$name: MEMORY is '$MEMORY'"; fi
  if [[ "$URL_VAR" =~ ^[A-Z][A-Z0-9_]*$ ]]; then pass "$name: URL_VAR is a variable name"; else fail "$name: URL_VAR is '$URL_VAR'"; fi
  case "$URL_TEMPLATE" in
    *"@{host}:$PORT"* | *"//{host}:$PORT"*) pass "$name: URL_TEMPLATE points at {host}:PORT" ;;
    *) fail "$name: URL_TEMPLATE does not contain {host}:$PORT" ;;
  esac
  case "$HEALTH" in
    *"127.0.0.1"*"$PORT"*) pass "$name: HEALTH checks the TCP port" ;;
    *) fail "$name: HEALTH does not use 127.0.0.1 and the port" ;;
  esac
  case "$HEALTH" in
    *[\"\'\$\`\;\|\&]*) fail "$name: HEALTH needs a shell; it must be plain words" ;;
    *) pass "$name: HEALTH is plain words" ;;
  esac

  # Memory mounts: capped, no setuid, no devices; and MEMORY covers them
  # plus the 64 MB of shared memory topology.sh adds.
  total=$((64 * 1024 * 1024))
  for t in ${TMPFS[@]+"${TMPFS[@]}"}; do
    case "$t" in
      /*:*size=*) ;;
      *) fail "$name: TMPFS without a path or a size: $t" ;;
    esac
    case "$t" in *nosuid*) ;; *) fail "$name: TMPFS without nosuid: $t" ;; esac
    case "$t" in *nodev*) ;; *) fail "$name: TMPFS without nodev: $t" ;; esac
    size="${t#*size=}"
    total=$((total + $(to_bytes "${size%%,*}")))
  done
  if [ "$(to_bytes "$MEMORY")" -gt "$total" ]; then
    pass "$name: MEMORY exceeds its memory mounts plus shared memory"
  else
    fail "$name: MEMORY ($MEMORY) does not cover its memory mounts ($total bytes)"
  fi

  # Every setting has a comment above it: walking up from a KEY=value line,
  # a comment must come before a blank line or the top of the file.
  unexplained="" explained=0 n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
      '') explained=0 ;;
      '#'*) explained=1 ;;
      *) if [ "$explained" -eq 0 ]; then unexplained="$unexplained $n"; fi ;;
    esac
  done <"$file"
  if [ -z "$unexplained" ]; then pass "$name: every line has its reason above it"; else fail "$name: no comment above line(s)$unexplained"; fi

  # Not a shell script: nothing in it would do anything if it were sourced.
  if grep -vE '^#' "$file" | grep -qE '\$\(|`|\$\{'; then
    fail "$name: a value contains shell syntax"
  else
    pass "$name: no shell syntax in values"
  fi
done

# --- The two shipped services --------------------------------------------------
load "$root/services/postgres/service.conf"
check "postgres: tag is 16-alpine" grep -qx '# tag: docker.io/library/postgres:16-alpine' "$root/services/postgres/service.conf"
is "postgres: VERSIONS" "$VERSIONS" 16
is "postgres: USER" "$USER_" 70:70
is "postgres: MEMORY" "$MEMORY" 1g
is "postgres: URL_VAR" "$URL_VAR" DATABASE_URL
is "postgres: URL_TEMPLATE" "$URL_TEMPLATE" 'postgres://postgres:sandbox@{host}:5432/postgres'
data_mount=""
for t in "${TMPFS[@]}"; do
  case "$t" in /var/lib/postgresql/data:*size=512m*mode=1777*) data_mount="${t%%:*}" ;; esac
done
is "postgres: data directory is a 512m memory mount, mode 1777" "$data_mount" /var/lib/postgresql/data
pgdata=""
for e in "${ENV[@]}"; do
  case "$e" in PGDATA=*) pgdata="${e#PGDATA=}" ;; esac
done
case "$pgdata" in
  "$data_mount"/?*) pass "postgres: PGDATA is a sub-directory of the mount" ;;
  *) fail "postgres: PGDATA ($pgdata) is not inside the mount" ;;
esac
case " ${ENV[*]} " in *" POSTGRES_PASSWORD=sandbox "*) pass "postgres: password matches the URL" ;; *) fail "postgres: POSTGRES_PASSWORD is not 'sandbox'" ;; esac
case "$HEALTH" in "pg_isready -h 127.0.0.1 "*) pass "postgres: health check is over TCP" ;; *) fail "postgres: health check is not pg_isready over TCP" ;; esac
is "postgres: uses the image's own command (COMMAND_ARG lines)" "${#COMMAND[@]}" 0

load "$root/services/redis/service.conf"
check "redis: tag is 7-alpine" grep -qx '# tag: docker.io/library/redis:7-alpine' "$root/services/redis/service.conf"
is "redis: VERSIONS" "$VERSIONS" 7
is "redis: USER" "$USER_" 999:1000
is "redis: MEMORY" "$MEMORY" 512m
is "redis: URL_VAR" "$URL_VAR" REDIS_URL
# The command, argument by argument, including the empty one after --save.
want=(redis-server --save "" --appendonly no --maxmemory 384mb)
same=1
[ "${#COMMAND[@]}" -eq "${#want[@]}" ] || same=0
if [ "$same" -eq 1 ]; then
  for i in "${!want[@]}"; do
    [ "${COMMAND[i]}" = "${want[i]}" ] || same=0
  done
fi
if [ "$same" -eq 1 ]; then
  pass "redis: command is redis-server --save \"\" --appendonly no --maxmemory 384mb"
else
  fail "redis: command is [$(printf '<%s> ' ${COMMAND[@]+"${COMMAND[@]}"})]"
fi
is "redis: needs no writable path (TMPFS lines)" "${#TMPFS[@]}" 0

# --- README --------------------------------------------------------------------
readme="$root/services/README.md"
check "README: how to add a service" grep -q '^## Adding a service' "$readme"
check "README: the agent cannot start services" grep -q 'The agent cannot' "$readme"
check "README: a service is part of the agent's reach" grep -q "part of the agent's reach" "$readme"
check "README: image builds and testcontainers are out of scope" grep -qi 'testcontainers' "$readme"
for key in $required TMPFS ENV COMMAND_ARG; do
  check "README: documents $key" grep -q "^| \`$key\` |" "$readme"
done

finish
