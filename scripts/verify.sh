#!/usr/bin/env bash
# verify.sh — attempts every bypass in the barrier register.
#
#   scripts/verify.sh [--quick] <session>     check a running session
#   scripts/verify.sh --deadline-test         B26, B27, B31, B32: makes its own
#                                             short-lived session and lets its
#                                             time limit pass (about 5 minutes)
#   scripts/verify.sh --store-test            B33: makes its own sessions on the
#                                             disk store and fills them
#
# The specification is the "Verify attempts" column of the register in
# docs/00-threat-model.md. Every check has a stable name that starts with its
# barrier's number and prints one line:
#
#   PASS <name> — <what was tried and what happened>
#   FAIL <name> — <what was tried and what happened>
#     fix: <what to do>
#   SKIP <name> — (<reason>) <why it was not tried>
#
# The exit status is 1 if anything failed. A SKIP is never a pass: it counts
# as a FAILURE unless its reason is on the short list LEGITIMATE below.
# "Could not test" is not allowed to look like "tested and fine".
#
# No vacuous checks (closes reference finding M4: the old `cannot sudo` test
# passed because sudo was simply absent). Each check exercises the thing it
# names; where a refusal could come from the wrong cause, a control that must
# succeed runs beside it (an allowed host, a canary the search must find).
#
# Where the checks run
#   * In the agent container, as the agent's user: `podman exec <session>-agent
#     /usr/share/sandbox/verify-inside.sh ...` (images/agent/verify-inside.sh).
#   * In the proxy and the sidecar, where a check needs their point of view.
#   * On this host: `podman inspect`, `podman network inspect`, `podman volume
#     inspect`, `podman ps`, `podman logs`.
#   What the launcher asked Podman for (limits, sizes) is read from `podman
#   inspect` here and handed to the in-container checks, which compare it BY
#   VALUE with what the kernel reports.
#
# --quick leaves out what fills memory (B08-fill), forks to the limit
# (B10-fork-limit) and runs doctor again (B29-doctor); the rest takes about
# ten seconds.
#
# On a session where untrusted code has already run, the in-container
# answers are only as trustworthy as the container. `./sandbox run` calls
# this before the agent starts.
#
# Everything printed here that came out of a container is reduced to
# printable ASCII first, so it cannot steer your terminal. [logical B32]
#
# Host-side code: it must also run under macOS's bash 3.2, so there are no
# associative arrays, no mapfile and no ${var,,} here. It needs no jq:
# Podman's own --format templates do the reading.
#
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="agent-sandbox.session"
INSIDE=/usr/share/sandbox/verify-inside.sh     # where the agent image keeps images/agent/verify-inside.sh
SESSION_PATTERN='^asb-[a-z0-9]([a-z0-9-]*[a-z0-9])?-[0-9a-f]{6}$'

# The reasons for which a SKIP does not count as a failure. Each one means
# "this barrier, or this attempt, does not apply here", never "could not be
# bothered". Anything else in brackets after SKIP is a failure.
#   no-selinux        B05 on a host without SELinux (Debian, Ubuntu, macOS)
#   no-swap           B10: no swap limit in force, on a host with no swap
#   no-setuid-files   B03: the image has no setuid program to run
#   no-remote         B15: the repository came from a local path
#   no-git-relay      B30: the session has no git relay
#   branch-rule       B30: a force-push is the git host's to refuse, not the relay's
#   http-allowed      B20: you opened port 80 with `allow --url http://...`
#   memory-workspace  B33: the workspace is held in memory, not on the store
#   no-store          B33: no disk store is configured
#   no-runtime-class  SANDBOX_RUNTIME_CLASS is not set
#   quick             left out because you passed --quick
#   separate          has a command of its own (--deadline-test, --store-test)
LEGITIMATE="no-selinux no-swap no-setuid-files no-remote no-git-relay branch-rule http-allowed memory-workspace no-store no-runtime-class quick separate"

die() { printf 'verify: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
PASSED=0 FAILED=0 SKIPPED=0
GREEN="" RED="" YELLOW="" OFF=""
if [ -t 1 ]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
fi

# [logical B32] Printable ASCII on one line, and not too much of it.
clean() { LC_ALL=C tr '\n\r\t' '   ' | LC_ALL=C tr -cd '\40-\176' | cut -c1-700; }

pass() {   # <name> <detail>
  printf '%sPASS%s %s — %s\n' "$GREEN" "$OFF" "$1" "$(printf '%s' "$2" | clean)"
  PASSED=$((PASSED + 1))
}
fail() {   # <name> <detail> <fix>
  printf '%sFAIL%s %s — %s\n  fix: %s\n' "$RED" "$OFF" "$1" "$(printf '%s' "$2" | clean)" "$(printf '%s' "$3" | clean)"
  FAILED=$((FAILED + 1))
}
skip() {   # <name> <reason> <detail> [fix]
  case " $LEGITIMATE " in
    *" $2 "*)
      printf '%sSKIP%s %s — (%s) %s\n' "$YELLOW" "$OFF" "$1" "$2" "$(printf '%s' "$3" | clean)"
      SKIPPED=$((SKIPPED + 1)) ;;
    *)
      printf '%sSKIP%s %s — (%s) %s [counts as a failure: not tested is not passed]\n  fix: %s\n' "$RED" "$OFF" "$1" \
        "$(printf '%s' "$2" | clean)" "$(printf '%s' "$3" | clean)" \
        "$(printf '%s' "${4:-make this check able to run, then run verify again}" | clean)"
      FAILED=$((FAILED + 1)) ;;
  esac
}

finish() {
  printf '\n%s passed, %s failed, %s skipped for a stated reason.\n' "$PASSED" "$FAILED" "$SKIPPED"
  if [ "$FAILED" -gt 0 ]; then
    printf '%sA barrier is missing or could not be tested. Do not let an agent loose in this session.%s\n' "$RED" "$OFF"
    exit 1
  fi
  exit 0
}

rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

# kv <file> <KEY> — the value of the last KEY=value line. State and settings
# files are data: read with `read`, never sourced.
kv() {
  local line found=""
  [ -f "$1" ] || return 0
  # Split by hand at the first `=`, so a value ending in `=` is kept whole.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2"=*) found="${line#*=}" ;; esac
  done < "$1"
  printf '%s' "$found"
}

# Where the launcher keeps its sessions and your settings (same rules as
# ./sandbox).
state_dir() {
  if [ -n "${SANDBOX_STATE_DIR:-}" ]; then printf '%s' "$SANDBOX_STATE_DIR"
  elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then printf '%s' "$XDG_RUNTIME_DIR/agent-sandbox"
  else printf '%s' "${TMPDIR:-/tmp}/agent-sandbox-$(id -u)"; fi
}
config_dir() { printf '%s' "${SANDBOX_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-sandbox}"; }

WORK=""
TEST_SIDECAR=""
MOCK_PID=""
cleanup() {
  if [ -n "$MOCK_PID" ]; then kill "$MOCK_PID" 2>/dev/null || true; fi
  if [ -n "$TEST_SIDECAR" ]; then podman rm -f -t 0 "$TEST_SIDECAR" >/dev/null 2>&1 || true; fi
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}

# ---------------------------------------------------------------------------
# Reading what Podman was asked for: one `podman inspect` per container,
# printing key=value lines. If the whole template is refused (a field this
# Podman does not have), each line is asked for by itself, so one unknown
# field costs one check and names itself, instead of taking all of them down.
# ---------------------------------------------------------------------------
inspect_template() {
  cat <<'EOF'
state={{.State.Status}}
image={{.ImageName}}
user={{.Config.User}}
readonly={{.HostConfig.ReadonlyRootfs}}
privileged={{.HostConfig.Privileged}}
capadd={{.HostConfig.CapAdd}}
effcaps={{.EffectiveCaps}}
bndcaps={{.BoundingCaps}}
secopt={{.HostConfig.SecurityOpt}}
netmode={{.HostConfig.NetworkMode}}
pidmode={{.HostConfig.PidMode}}
ipcmode={{.HostConfig.IpcMode}}
cgroupmode={{.HostConfig.CgroupMode}}
devices={{.HostConfig.Devices}}
memory={{.HostConfig.Memory}}
memswap={{.HostConfig.MemorySwap}}
nanocpus={{.HostConfig.NanoCpus}}
pids={{.HostConfig.PidsLimit}}
ulimits={{range .HostConfig.Ulimits}}{{.Name}}:{{.Soft}}:{{.Hard}} {{end}}
tmpfs={{range $k, $v := .HostConfig.Tmpfs}}{{$k}}={{$v}};{{end}}
timeout={{.Config.Timeout}}
logdriver={{.HostConfig.LogConfig.Type}}
logpath={{.HostConfig.LogConfig.Path}}
runtime={{.OCIRuntime}}
networks={{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}
mounts={{range .Mounts}}{{.Type}}|{{.RW}}|{{.Destination}}|{{.Source}};{{end}}
label={{.ProcessLabel}}
EOF
}

inspect_load() {   # <role>
  local role="$1" file="$WORK/inspect.$1" line key err
  if podman inspect --format "$(inspect_template)" "$SESSION-$role" > "$file" 2>/dev/null; then
    return 0
  fi
  : > "$file"
  while IFS= read -r line; do
    key="${line%%=*}"
    if ! podman inspect --format "$line" "$SESSION-$role" >> "$file" 2>"$WORK/err"; then
      err="$(head -n 1 "$WORK/err" | tr -d '\n' | clean)"
      printf '%s=!unreadable (%s)\n' "$key" "$err" >> "$file"
    fi
  done <<EOF
$(inspect_template)
EOF
}

field() {   # <role> <key>
  local key value
  while IFS='=' read -r key value; do
    if [ "$key" = "$2" ]; then printf '%s' "$value"; return 0; fi
  done < "$WORK/inspect.$1"
  printf '!unreadable (podman inspect printed no such line)'
}

# What the kernel says inside a container: capability sets, no-new-privileges,
# the core-dump limit, and what happens on a write to /. Plain `sh`, so it
# runs in the Alpine images too.
# shellcheck disable=SC2016  # this text is run by the container's sh, not expanded here
CONTAINER_PROBE='LC_ALL=C; export LC_ALL
while read -r k v; do case "$k" in CapInh:|CapPrm:|CapEff:|CapBnd:|CapAmb:|NoNewPrivs:) echo "$k$v";; esac; done < /proc/self/status
while read -r a b c d e f g; do if [ "$a $b $c $d" = "Max core file size" ]; then echo "Core:$e $f"; fi; done < /proc/self/limits
if out=$( ( : > /.verify-probe ) 2>&1 ); then rm -f /.verify-probe; echo "Root:created a file"; else echo "Root:$out"; fi'

probe_load() {   # <role>
  podman exec "$SESSION-$1" sh -c "$CONTAINER_PROBE" > "$WORK/probe.$1" 2>"$WORK/probe-err.$1" || true
}
probed() {   # <role> <Key>
  local line
  while IFS= read -r line; do
    case "$line" in "$2:"*) printf '%s' "${line#"$2":}"; return 0 ;; esac
  done < "$WORK/probe.$1"
  printf '!no answer'
}

# to_bytes 1g|512m|64k|1048576 -> bytes, or nothing if it is not a size
to_bytes() {
  local number unit
  number="$(printf '%s' "$1" | sed -E 's/[kKmMgG]$//')"
  unit="$(printf '%s' "$1" | sed -E 's/^[0-9]+//')"
  case "$number" in ''|*[!0-9]*) return 0 ;; esac
  case "$unit" in
    '') printf '%s' "$number" ;;
    k|K) printf '%s' "$((number * 1024))" ;;
    m|M) printf '%s' "$((number * 1024 * 1024))" ;;
    g|G) printf '%s' "$((number * 1024 * 1024 * 1024))" ;;
  esac
}

tmpfs_size() {   # <path>: the size= asked for on the agent's memory mount at <path>, in bytes
  local entry size
  printf '%s' "$(field agent tmpfs)" | tr ';' '\n' | while IFS= read -r entry; do
    case "$entry" in
      "$1="*)
        size="$(printf '%s' "${entry#*=}" | tr ',' '\n' | sed -n 's/^size=//p' | head -n 1)"
        to_bytes "$size" ;;
    esac
  done
}

ulimit_asked() {   # nofile|nproc|fsize: the value asked for when soft and hard agree
  local entry name soft hard
  for entry in $(field agent ulimits); do
    IFS=: read -r name soft hard <<EOF
$entry
EOF
    name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    case "$name" in
      "$1"|"rlimit_$1") if [ "$soft" = "$hard" ]; then printf '%s' "$soft"; fi ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Running the in-container checks and relaying their lines.
# ---------------------------------------------------------------------------
PARAMS=()

# run_inside <check-name>...
# One `podman exec`. Every name asked for must come back with a result; a
# name that does not (the probe died, was killed, or the image is older than
# this script) is a failure.
run_inside() {
  local out status=0 line word rest name seen=" " pending="" p_status="" p_name="" p_detail="" p_fix=""
  out="$(podman exec "$SESSION-agent" "$INSIDE" ${PARAMS[@]+"${PARAMS[@]}"} "$@" 2>"$WORK/inside-err")" || status=$?
  flush() {
    [ -n "$pending" ] || return 0
    case "$p_status" in
      PASS) pass "$p_name" "$p_detail" ;;
      FAIL) fail "$p_name" "$p_detail" "${p_fix:-see the line above}" ;;
      SKIP)
        # "(reason) detail"
        rest="${p_detail#(}"
        skip "$p_name" "${rest%%)*}" "${rest#*) }" "$p_fix" ;;
    esac
    pending=""
  }
  while IFS= read -r line; do
    case "$line" in
      "PASS "*|"FAIL "*|"SKIP "*)
        flush
        word="${line%% *}"; rest="${line#* }"; name="${rest%% *}"
        # Only names that were asked for, and each one once.
        case " $* " in *" $name "*) ;; *) continue ;; esac
        case "$seen" in *" $name "*) continue ;; esac
        seen="$seen$name "
        pending=1; p_status="$word"; p_name="$name"; p_detail="${rest#* }"; p_fix="" ;;
      "  fix: "*)
        if [ -n "$pending" ]; then p_fix="${line#  fix: }"; fi ;;
    esac
  done <<EOF
$out
EOF
  flush
  for name in "$@"; do
    case "$seen" in
      *" $name "*) ;;
      *) fail "$name" "the check inside the agent container did not report (podman exec ended with status $status: $(head -n 2 "$WORK/inside-err" | clean))" \
           "status 137 means the kernel killed it. Otherwise the agent image may be older than this script: rebuild it (./sandbox upgrade)" ;;
    esac
  done
}

# inside_helper <helper-name> [name=value]...: a helper's bare output, for
# checks that are judged here.
inside_helper() {
  local helper="$1"
  shift
  podman exec "$SESSION-agent" "$INSIDE" ${PARAMS[@]+"${PARAMS[@]}"} "$@" "$helper" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Host-side checks over every container of the session.
# ---------------------------------------------------------------------------
check_B02_caps_all() {
  local role key value bad=""
  for role in $ROLES; do
    for key in capadd effcaps bndcaps; do
      value="$(field "$role" "$key")"
      [ "$value" = '[]' ] || bad="$bad $role: Podman reports $key=$value;"
    done
    for key in CapInh CapPrm CapEff CapBnd CapAmb; do
      value="$(probed "$role" "$key")"
      case "$value" in
        *[!0]*|'') bad="$bad $role: the kernel reports $key=$value;" ;;
      esac
    done
  done
  if [ -z "$bad" ]; then
    pass B02-caps-all "in each of [$ROLES]: Podman reports no capability added and empty effective and bounding sets, and a process started inside reads all five capability sets as empty from the kernel"
  else
    fail B02-caps-all "a container holds capabilities:$bad" \
      "every container is created with --cap-drop=ALL and nothing added back (topology.sh, _topo_hardening); remove the --cap-add"
  fi
}

check_B03_nnp_all() {
  local role value bad=""
  for role in $ROLES; do
    case "$(field "$role" secopt)" in
      *no-new-privileges*) ;;
      *) bad="$bad $role: Podman's security options are $(field "$role" secopt);" ;;
    esac
    value="$(probed "$role" NoNewPrivs)"
    [ "$value" = 1 ] || bad="$bad $role: the kernel reports NoNewPrivs=$value;"
  done
  if [ -z "$bad" ]; then
    pass B03-nnp-all "in each of [$ROLES]: created with no-new-privileges, and a process started inside reads NoNewPrivs: 1 from the kernel"
  else
    fail B03-nnp-all "no-new-privileges is not in force everywhere:$bad" \
      "every container is created with --security-opt=no-new-privileges (topology.sh, _topo_hardening)"
  fi
}

check_B06_private_modes() {
  local role key value bad=""
  for role in $ROLES; do
    [ "$(field "$role" privileged)" = false ] || bad="$bad $role: privileged=$(field "$role" privileged);"
    for key in pidmode ipcmode cgroupmode; do
      value="$(field "$role" "$key")"
      [ "$value" = private ] || bad="$bad $role: $key=$value, expected private;"
    done
    value="$(field "$role" netmode)"
    case "$value" in
      host|container:*|ns:*|'!'*) bad="$bad $role: network mode $value;" ;;
    esac
    [ "$(field "$role" devices)" = '[]' ] || bad="$bad $role: devices passed in: $(field "$role" devices);"
  done
  if [ -z "$bad" ]; then
    pass B06-private-modes "in each of [$ROLES]: Podman reports not privileged, private process, shared-memory and cgroup namespaces, not the host's network, and no device passed in"
  else
    fail B06-private-modes "a container shares something with the host:$bad" \
      "topology.sh (_topo_hardening) sets --pid=private --ipc=private --cgroupns=private and never --privileged, --network=host or --device; remove what was added"
  fi
}

check_B06_runtime_class() {
  local role want value bad=""
  want="${SANDBOX_RUNTIME_CLASS:-}"
  if [ -z "$want" ]; then
    skip B06-runtime-class no-runtime-class "SANDBOX_RUNTIME_CLASS is not set, so the containers run on Podman's default runtime ($(field agent runtime)), not gVisor"
    return 0
  fi
  for role in $ROLES; do
    value="$(field "$role" runtime)"
    [ "${value##*/}" = "${want##*/}" ] || bad="$bad $role runs on $value;"
  done
  if [ -z "$bad" ]; then
    pass B06-runtime-class "SANDBOX_RUNTIME_CLASS=$want was asked for, and Podman reports that runtime for each of [$ROLES]"
  else
    fail B06-runtime-class "SANDBOX_RUNTIME_CLASS=$want was asked for, but:$bad" \
      "the session was created without it. Export SANDBOX_RUNTIME_CLASS before ./sandbox run, and check 'podman info' lists that runtime"
  fi
}

check_B07_readonly_all() {
  local role value bad=""
  for role in $ROLES; do
    [ "$(field "$role" readonly)" = true ] || bad="$bad $role: Podman reports ReadonlyRootfs=$(field "$role" readonly);"
    value="$(probed "$role" Root)"
    case "$value" in
      *"Read-only file system"*) ;;
      *) bad="$bad $role: a write to / answered '$value', not 'Read-only file system';" ;;
    esac
  done
  if [ -z "$bad" ]; then
    pass B07-readonly-all "in each of [$ROLES]: created with a read-only root, and creating a file in / from inside answered 'Read-only file system'"
  else
    fail B07-readonly-all "a root filesystem is not read-only:$bad" \
      "every container is created with --read-only (topology.sh, _topo_hardening). 'Permission denied' is not enough: that only stops a non-root user"
  fi
}

check_B09_host_mounts() {
  local role entry type rw dest source bad="" seen=""
  for role in $ROLES; do
    case "$(field "$role" mounts)" in
      '!'*) bad="$bad $role: $(field "$role" mounts);"; continue ;;
    esac
    while IFS='|' read -r type rw dest source; do
      [ -n "$type" ] || continue
      [ "$type" != tmpfs ] || continue       # memory mounts are not host paths; B08 covers them
      seen="$seen $role:$dest($type,$([ "$rw" = true ] && printf 'writable' || printf 'read-only'))"
      if [ "$role" = agent ]; then
        # The agent gets the workspace volume and nothing else.
        if [ "$type" != volume ] || [ "$dest" != /workspace ]; then
          bad="$bad agent: $source is mounted at $dest ($type);"
        fi
      elif [ "$type" = bind ] && [ "$rw" = true ]; then
        bad="$bad $role: the host path $source is mounted WRITABLE at $dest;"
      elif [ "$type" = volume ] && [ "$rw" = true ]; then
        bad="$bad $role: a volume is mounted writable at $dest (only the agent writes to the workspace);"
      elif [ "$type" = bind ] && [ "$role" = proxy ]; then
        # The one host path in the whole session: the lists ./sandbox wrote.
        case "$source" in
          */"$SESSION"/proxy) ;;
          *) bad="$bad proxy: the host path $source is mounted at $dest (expected only its allowlists);" ;;
        esac
      elif [ "$type" = bind ]; then
        bad="$bad $role: the host path $source is mounted at $dest;"
      fi
    done <<EOF
$(field "$role" mounts | tr ';' '\n')
EOF
  done
  if [ -z "$bad" ]; then
    pass B09-host-mounts "listed every mount Podman reports for [$ROLES]: the agent has the workspace volume and nothing else, no host path is writable anywhere, and the only host path at all is the proxy's read-only allowlists ($seen )"
  else
    fail B09-host-mounts "a host path is mounted where it must not be:$bad" \
      "remove the --volume or --mount (topology.sh). Nothing of yours belongs in the agent container, and nothing writable in any"
  fi
}

check_B08_workspace_volume() {
  local line driver type device opts want bad=""
  line="$(podman volume inspect --format '{{.Driver}}|{{index .Options "type"}}|{{index .Options "device"}}|{{index .Options "o"}}' "$SESSION-workspace" 2>"$WORK/err")" || {
    skip B08-workspace-volume unreadable "podman volume inspect $SESSION-workspace failed: $(head -n 1 "$WORK/err")" "the session's volume is gone, or this Podman reports volumes differently"
    return 0
  }
  IFS='|' read -r driver type device opts <<EOF
$line
EOF
  [ "$driver" = local ] || bad="$bad driver is $driver;"
  case ",$opts," in *,nosuid,*) ;; *) bad="$bad options lack nosuid ($opts);" ;; esac
  case ",$opts," in *,nodev,*) ;; *) bad="$bad options lack nodev ($opts);" ;; esac
  if [ "$WORKSPACE_DRIVER" = local ]; then
    [ "$device" = "$STORE/$SESSION" ] || bad="$bad it is the directory '$device', expected $STORE/$SESSION on the disk store;"
  else
    [ "$type" = tmpfs ] || bad="$bad its type is '$type', expected tmpfs (held in memory);"
    want="$(to_bytes "$(printf '%s' "$opts" | tr ',' '\n' | sed -n 's/^size=//p' | head -n 1)")"
    [ -n "$want" ] && [ "$want" = "$WORKSPACE_BYTES" ] || bad="$bad its size cap is '${want:-none}', the session recorded $WORKSPACE_BYTES;"
  fi
  if [ -z "$bad" ]; then
    pass B08-workspace-volume "podman volume inspect: the workspace is $([ "$WORKSPACE_DRIVER" = local ] && printf 'the directory %s on the disk store' "$device" || printf 'held in memory, capped at %s bytes' "$WORKSPACE_BYTES"), nosuid and nodev, and is a volume made for this session, not a folder of yours"
  else
    fail B08-workspace-volume "the workspace volume is not what the session asked for:$bad" \
      "see topo_volume_workspace in topology.sh; destroy the session and run again"
  fi
}

check_B10_limits_all() {
  local role memory bad=""
  for role in $ROLES; do
    memory="$(field "$role" memory)"
    case "$memory" in ''|0|*[!0-9]*) bad="$bad $role: memory limit $memory;" ;; esac
    [ "$(field "$role" memswap)" = "$memory" ] || bad="$bad $role: memory+swap limit $(field "$role" memswap) is not equal to the memory limit $memory (swap allowance must be zero);"
    case "$(field "$role" pids)" in ''|0|-1|*[!0-9]*) bad="$bad $role: process limit $(field "$role" pids);" ;; esac
    case "$(field "$role" nanocpus)" in ''|0|*[!0-9]*) bad="$bad $role: CPU limit $(field "$role" nanocpus);" ;; esac
  done
  if [ -z "$bad" ]; then
    pass B10-limits-all "Podman reports, for each of [$ROLES]: a memory limit, a memory+swap limit equal to it, a process limit and a CPU limit (the agent's are compared with the kernel's own numbers in B10-*-max)"
  else
    fail B10-limits-all "a container has no ceiling:$bad" \
      "every container gets --cpus, --memory, --memory-swap and --pids-limit from _topo_limits in topology.sh"
  fi
}

check_B11_core_all() {
  local role value bad=""
  for role in $ROLES; do
    value="$(probed "$role" Core)"
    [ "$value" = "0 0" ] || bad="$bad $role: core file size limit is '$value';"
  done
  if [ -z "$bad" ]; then
    pass B11-core-all "in each of [$ROLES]: a process started inside reads a core-dump limit of 0 (soft and hard) from the kernel"
  else
    fail B11-core-all "core dumps are not switched off everywhere:$bad" \
      "every container is created with --ulimit core=0:0 (topology.sh, _topo_hardening): a crash must not copy a container's memory to disk"
  fi
}

check_B12_network_attach() {
  local role nets bad="" json
  nets="$(field agent networks)"; nets="${nets% }"
  [ "$nets" = "$SESSION-sandbox" ] || bad="$bad the agent is attached to [$nets], expected only $SESSION-sandbox;"
  for role in $ROLES; do
    case " $(field "$role" networks) " in
      *" $SESSION-egress "*) [ "$role" = proxy ] || bad="$bad $role is attached to the egress network (only the proxy may be);" ;;
    esac
  done
  json="$(podman network inspect "$SESSION-sandbox" 2>/dev/null)" || json=""
  if [ -z "$json" ]; then
    bad="$bad podman network inspect $SESSION-sandbox gave nothing;"
  elif ! printf '%s' "$json" | grep -Eq '"internal": *true'; then
    bad="$bad the network $SESSION-sandbox is not marked internal;"
  fi
  if [ -z "$bad" ]; then
    pass B12-network-attach "Podman reports the agent on one network, $SESSION-sandbox, which is marked internal; the proxy is the only container on $SESSION-egress"
  else
    fail B12-network-attach "the agent's network is not the closed one:$bad" \
      "see topo_network_sandbox (--internal) and the --network lines of topo_agent in topology.sh"
  fi
}

check_B13_network_no_gateway() {
  local json gateway bad=""
  json="$(podman network inspect "$SESSION-sandbox" 2>"$WORK/err")" || json=""
  if [ -z "$json" ]; then
    skip B13-network-no-gateway unreadable "podman network inspect $SESSION-sandbox failed: $(head -n 1 "$WORK/err")" "the session's network is gone: destroy the session and run again"
    return 0
  fi
  # A network with a gateway lists it beside its subnet: "gateway": "a.b.c.1".
  gateway="$(printf '%s' "$json" | sed -n 's/.*"gateway": *"\([^"]*\)".*/\1/p' | tr '\n' ' ')"
  [ -z "$gateway" ] || bad="$bad it has the gateway address $gateway;"
  printf '%s' "$json" | grep -Eq '"dns_enabled": *false' || bad="$bad its name service is not switched off;"
  printf '%s' "$json" | grep -Eq '"subnet": *"'"$PREFIX"'\.0/24"' || bad="$bad its subnet is not the session's $SUBNET;"
  if [ -z "$bad" ]; then
    pass B13-network-no-gateway "podman network inspect $SESSION-sandbox: subnet $SUBNET, no gateway address, name service off (B13-gateway-ports probes the address from inside)"
  else
    fail B13-network-no-gateway "the agent's network gives the host a foothold:$bad" \
      "the network must be created with --internal and --disable-dns (topology.sh, topo_network_sandbox). If this Podman gives such a network a gateway anyway, that is new behaviour: do not use it until it is understood"
  fi
}

check_B26_deadline_set() {
  local role value want bad=""
  want=$((DEADLINE_EPOCH - CREATED_EPOCH))
  for role in $ROLES; do
    value="$(field "$role" timeout)"
    if [ "$role" = keeper ]; then
      [ "$value" = 0 ] || bad="$bad the keeper has a deadline ($value s): the workspace would vanish with it;"
    else
      [ "$value" = "$want" ] || bad="$bad $role: Podman's own deadline is '$value' s, the session's time limit is $want s;"
    fi
  done
  if [ -z "$bad" ]; then
    pass B26-deadline-set "Podman reports its own kill timer of $want seconds (this session's time limit) on every container of [$ROLES] except the keeper, which has none. Letting it pass is a test of its own: scripts/verify.sh --deadline-test"
  else
    fail B26-deadline-set "the time limit is not set from outside on every container:$bad" \
      "every container but the keeper is created with --timeout (topology.sh, _topo_deadline)"
  fi
}

check_B26_keeper() {
  local bad=""
  case " $ROLES " in *" keeper "*) ;; *) bad="$bad there is no keeper container;" ;; esac
  if [ -z "$bad" ]; then
    [ "$(field keeper state)" = running ] || bad="$bad the keeper is $(field keeper state);"
    [ "$(field keeper netmode)" = none ] || bad="$bad the keeper's network mode is $(field keeper netmode), expected none;"
    [ "$(field keeper user)" = 61003:61003 ] || bad="$bad the keeper runs as $(field keeper user), expected 61003:61003 (not the agent's user);"
  fi
  if [ -z "$bad" ]; then
    pass B26-keeper "Podman reports the keeper running with no network and as its own user 61003, so the agent can neither reach nor signal what holds the workspace (the agent's process list is checked in B06-pid1)"
  else
    fail B26-keeper "the keeper is not out of the agent's reach:$bad" "see topo_keeper in topology.sh"
  fi
}

check_B28_log_driver() {
  local role other driver path entry source bad=""
  for role in $ROLES; do
    driver="$(field "$role" logdriver)"
    path="$(field "$role" logpath)"
    [ "$driver" = k8s-file ] || bad="$bad $role logs through '$driver', expected k8s-file;"
    case "$path" in ''|'!'*) bad="$bad $role: no log file reported ($path);"; continue ;; esac
    # No container may have the place a log is written to mounted into it.
    for other in $ROLES; do
      while IFS='|' read -r _ _ _ source; do
        [ -n "$source" ] || continue
        case "$path" in
          "$source"|"$source"/*) bad="$bad the log of $role ($path) lies inside $source, which is mounted into $other;" ;;
        esac
      done <<EOF
$(field "$other" mounts | tr ';' '\n')
EOF
    done
  done
  if [ -z "$bad" ]; then
    pass B28-log-driver "Podman reports, for each of [$ROLES]: the k8s-file log driver (a file that belongs to the container and is deleted with it), and no log file lies inside anything mounted into a container"
  else
    fail B28-log-driver "a log is not collected from outside:$bad" \
      "every container is created with --log-driver=k8s-file and no log path is mounted anywhere (topology.sh, _topo_hardening)"
  fi
}

check_B29_rootless() {
  local line rootless remote bad=""
  line="$(podman info --format '{{.Host.Security.Rootless}} {{.Host.ServiceIsRemote}}' 2>"$WORK/err")" || line=""
  read -r rootless remote <<EOF
$line
EOF
  [ "$(id -u)" -ne 0 ] || bad="$bad this is running as root;"
  [ "${rootless:-}" = true ] || bad="$bad Podman does not report rootless (it says '${rootless:-nothing}');"
  [ "${remote:-}" = false ] || bad="$bad Podman is a remote client (it says '${remote:-nothing}');"
  if [ -z "$bad" ]; then
    pass B29-rootless "this host: not root (uid $(id -u)), and Podman reports that it runs rootless and on this machine"
  else
    fail B29-rootless "an escape would not land in an ordinary account:$bad" \
      "run ./sandbox doctor. Use an ordinary account without sudo and a local, rootless Podman"
  fi
}

check_B29_doctor() {
  local out status=0
  if [ ! -x "$ROOT/scripts/doctor.sh" ]; then
    skip B29-doctor unreadable "scripts/doctor.sh is missing" "restore it from the repository"
    return 0
  fi
  out="$("$ROOT/scripts/doctor.sh" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    pass B29-doctor "ran scripts/doctor.sh, which checks each condition the launcher refuses on: it found nothing wrong"
  else
    fail B29-doctor "scripts/doctor.sh ended with status $status: $(printf '%s' "$out" | grep -i -E 'fix|✗|fail|error' | head -n 3 | clean)" \
      "run ./sandbox doctor and follow its fix lines"
  fi
}

# --- B20: the never-allow list cannot be argued with --------------------------
check_B20_never_allow() {
  local host config="$WORK/never-config" render="$WORK/never-render" added=0 rendered=0
  host="$(sed -n 's/^\([a-z0-9.-][a-z0-9.-]*\).*/\1/p' "$ROOT/policy/never-allow.txt" 2>/dev/null | head -n 1)"
  if [ -z "$host" ] || [ ! -f "$ROOT/scripts/allowlist.sh" ]; then
    skip B20-never-allow unreadable "policy/never-allow.txt has no entry, or scripts/allowlist.sh is missing" "restore both from the repository"
    return 0
  fi
  mkdir -p "$config" "$render/proxy"
  # In a copy of your settings directory, so your own allowlist is untouched.
  # First the front door: what `./sandbox allow` calls.
  # shellcheck disable=SC2016  # the child shell expands these
  if SANDBOX_ROOT="$ROOT" SANDBOX_CONFIG_DIR="$config" bash -c \
       '. "$1/scripts/allowlist.sh" && allowlist_add host "$2" - "verify probe"' _ "$ROOT" "$host" >/dev/null 2>&1; then added=1; fi
  if grep -qF "$host" "$config/allowlist.local" 2>/dev/null; then added=1; fi
  # Then the back door: the entry written into the file by hand.
  printf 'host\t%s\t-\tverify probe\n' "$host" > "$config/allowlist.local"
  # shellcheck disable=SC2016
  if SANDBOX_ROOT="$ROOT" SANDBOX_CONFIG_DIR="$config" bash -c \
       '. "$1/scripts/allowlist.sh" && allowlist_render "$2" "$3"' _ "$ROOT" "$render" "$AGENT" >/dev/null 2>&1; then rendered=1; fi
  if grep -qxF "$host" "$render/proxy/agent.domains" 2>/dev/null; then rendered=1; fi
  if [ "$added" -eq 0 ] && [ "$rendered" -eq 0 ]; then
    pass B20-never-allow "tried to allow $host, a host on the never-allow list, twice: through the function './sandbox allow' uses, and by writing the entry into a copy of allowlist.local by hand and rendering the proxy's lists. Both were refused"
  else
    fail B20-never-allow "a never-allow host ($host) got through:$([ "$added" -eq 1 ] && printf ' allowlist_add accepted it;')$([ "$rendered" -eq 1 ] && printf ' allowlist_render wrote lists with it;')" \
      "see allowlist_add and allowlist_render in scripts/allowlist.sh: both must refuse anything policy/never-allow.txt covers"
  fi
}

# --- B15: the real credential is not inside ------------------------------------
# The credential is read from your keyring HERE and compared HERE. It never
# goes into the agent container: not as an argument, not on stdin. What is
# inside is copied OUT (environment, /proc/*/environ, home, workspace, /tmp,
# /dev/shm) and searched on this side.
keyring_get() {   # <agent> <auth>; the same lookup ./sandbox uses
  if [ "$(uname -s)" = Darwin ]; then
    security find-generic-password -s agent-sandbox -a "$1-$2" -w 2>/dev/null
  else
    command -v secret-tool >/dev/null 2>&1 || return 1
    secret-tool lookup service agent-sandbox agent "$1" auth "$2" 2>/dev/null
  fi
}

# Reads a stream, prints which of the patterns (one per line in $2) occur.
# The stream is cut into runs of the characters a token is made of, so a
# binary stream of any size is handled a short line at a time. The patterns
# reach grep through a pipe, never through a command line.
scan_for() {
  LC_ALL=C tr -c 'A-Za-z0-9._~+/=-' '\n' | LC_ALL=C grep -o -F -f <(printf '%s\n' "$1") | sort -u || true
}

check_B15_token_absent() {
  local secret pieces canary_file canary_env found where="" searched="" missing=""
  secret="$(keyring_get "$AGENT" "$AUTH" || true)"
  if [ -z "$secret" ] && [ -n "$CREDENTIAL_FD" ]; then
    secret="$(cat <&"$CREDENTIAL_FD" 2>/dev/null || true)"
  fi
  # What is stored may be a bare token or a JSON document (Codex keeps its
  # whole login). Every long run of token characters in it that has a digit
  # and both cases of letter is searched for; host names and key names are not.
  pieces="$(printf '%s\n%s\n' "$secret" "${SANDBOX_TEST_ANTHROPIC_KEY:-}" | LC_ALL=C tr -c 'A-Za-z0-9._~+/=-' '\n' \
    | awk 'length($0) >= 20 && /[0-9]/ && /[a-z]/ && /[A-Z]/' | sort -u)"
  secret=""
  if [ -z "$pieces" ]; then
    skip B15-token-absent no-credential "there is no $AUTH credential for $AGENT in your keyring to search for, so the agent container could not be searched for it" \
      "store it with ./sandbox login --agent $AGENT --auth $AUTH (a session started by typing the credential in is checked at run, and cannot be checked again later)"
    return 0
  fi
  # Two canaries prove the search can find something: one planted in a file,
  # one in a process's environment. They are random strings, not credentials.
  canary_file="verifyCanaryF$(rand_hex 12)"
  canary_env="verifyCanaryE$(rand_hex 12)"
  printf '%s' "$canary_file" | podman exec -i "$SESSION-agent" sh -c 'cat > /tmp/.verify-canary' 2>/dev/null || true
  podman exec -d --env "SANDBOX_VERIFY_CANARY=$canary_env" "$SESSION-agent" sleep 20 >/dev/null 2>&1 || true

  # 1. The environment Podman starts every process of the container with.
  found="$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$SESSION-agent" 2>/dev/null | tee "$WORK/env-seen" | scan_for "$pieces" || true)"
  [ -z "$found" ] || where="$where the container's environment;"
  grep -q '^HOME=' "$WORK/env-seen" 2>/dev/null && searched="$searched environment," || missing="$missing the container's environment could not be read;"
  : > "$WORK/env-seen"

  # 2. The environment of every process running inside right now.
  found="$(podman exec "$SESSION-agent" sh -c 'cat /proc/[0-9]*/environ 2>/dev/null' 2>/dev/null | scan_for "$pieces
$canary_env" || true)"
  case "$found" in *"$canary_env"*) searched="$searched /proc/*/environ," ;; *) missing="$missing the canary was not found in /proc/*/environ;" ;; esac
  [ "$found" = "$canary_env" ] || [ -z "$found" ] || where="$where a running process's environment;"

  # 3. Every file in the writable places, as one tar stream.
  found="$(podman exec "$SESSION-agent" tar -cf - -C / home workspace tmp dev/shm 2>/dev/null | scan_for "$pieces
$canary_file" || true)"
  case "$found" in *"$canary_file"*) searched="$searched home, workspace, /tmp and /dev/shm" ;; *) missing="$missing the canary file was not found in the copy of the writable places;" ;; esac
  [ "$found" = "$canary_file" ] || [ -z "$found" ] || where="$where a file in the home directory, the workspace, /tmp or /dev/shm;"
  podman exec "$SESSION-agent" rm -f /tmp/.verify-canary >/dev/null 2>&1 || true
  found=""; pieces=""

  if [ -n "$where" ]; then
    fail B15-token-absent "YOUR REAL CREDENTIAL IS INSIDE THE AGENT CONTAINER, in:$where" \
      "destroy this session now, and revoke the credential if an agent has run in it. Then find what put it there: agents/$AGENT/env, agents/$AGENT/launch, or a variable of your own shell that Podman copied in"
  elif [ -n "$missing" ]; then
    skip B15-token-absent canary-not-found "the search could not see everything, so a clean result would prove nothing:$missing" \
      "the agent container must be running and have sh and tar: ./sandbox logs agent"
  else
    pass B15-token-absent "read the $AUTH credential from your keyring on this host, copied out and searched the agent's$searched for it: not there. Two canaries planted first were found, so the search works. The credential itself never entered the container"
  fi
}

# --- B21: the vendor's host IS allowed from the sidecar (the control) ----------
CONNECT_JS='
const net = require("net");
const [proxy, target] = process.argv.slice(2);
let buf = "", done = false;
const s = net.connect({ host: proxy, port: 3128 });
const fin = (r) => { if (!done) { done = true; s.destroy(); console.log(r); } };
s.setTimeout(20000, () => fin("timeout"));
s.on("connect", () => s.write("CONNECT " + target + " HTTP/1.1\r\nHost: " + target + "\r\n\r\n"));
s.on("data", (d) => { buf += d; const m = /^HTTP\/1\.[01] (\d{3})/.exec(buf); if (m) fin("http " + m[1]); });
s.on("end", () => fin("closed"));
s.on("error", (e) => fin("error " + e.code));
'
check_B21_sidecar_allowed() {
  local out
  if [ -z "$VENDOR_HOST" ]; then
    skip B21-sidecar-allowed unreadable "the session's sidecar.domains list is empty, so there is no vendor host to try" "see agents/$AGENT/allowlist.txt, section [sidecar]"
    return 0
  fi
  out="$(printf '%s' "$CONNECT_JS" | podman exec -i "$SESSION-credsidecar" node - "$PROXY_IP" "$VENDOR_HOST:443" 2>/dev/null | tail -n 1)" || out=""
  case "$out" in
    "http 200") pass B21-sidecar-allowed "from the sidecar's address, asked the proxy for a tunnel to $VENDOR_HOST:443: allowed (200). The same request from the agent is refused (B21-vendor-plain), so the rule really is about the address" ;;
    http\ *) fail B21-sidecar-allowed "from the sidecar's address, the proxy answered ${out#http } for $VENDOR_HOST:443, expected 200" \
               "the vendor's host must be in <session dir>/proxy/sidecar.domains and reachable from this host: ./sandbox logs proxy" ;;
    *) skip B21-sidecar-allowed no-answer "could not ask the proxy from inside the sidecar (${out:-no output})" "the sidecar container must be running: ./sandbox logs sidecar" ;;
  esac
}

# --- B22 to B25: the credential sidecar, against a mock vendor -------------------
# The session's own sidecar holds your real credential and talks to the real
# vendor, so none of these checks is run against it: one request too many
# would be a real request on your account. A second sidecar is started from
# the same image and the same topology.sh arguments, with a budget of 3, a
# made-up token, and a mock vendor on its own loopback. The agent talks to it
# exactly as it talks to the real one. It is removed when verify ends, and
# has Podman's own deadline of five minutes in case verify is killed.
# shellcheck disable=SC2016  # JavaScript, not shell
MOCK_JS='
const http = require("http");
const [dialect, marker] = process.argv.slice(2);
const seen = [];
http.createServer((req, res) => {
  if (req.url === "/__verify/log") { res.end(seen.map((l) => l + "\n").join("")); return; }
  let bytes = 0;
  req.on("data", (c) => { bytes += c.length; });
  req.on("end", () => {
    const headers = Object.entries(req.headers).map(([k, v]) => k + "=" + v).join(" ").replace(/[^\x20-\x7e]/g, "?");
    seen.push("REQ " + (seen.length + 1) + " " + req.method + " " + req.url + " bytes=" + bytes + " " + headers);
    if (dialect === "openai-responses") {
      const item = { type: "web_search_call", id: "ws_verify", status: "completed", action: { type: "search", query: marker } };
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write("event: response.output_item.done\ndata: " + JSON.stringify({ type: "response.output_item.done", output_index: 0, item }) + "\n\n");
      res.end("event: response.completed\ndata: " + JSON.stringify({ type: "response.completed", response: { id: "resp_verify", status: "completed", output: [item] } }) + "\n\n");
    } else if (dialect === "openai-chat") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ id: "chatcmpl-verify", object: "chat.completion", choices: [{ index: 0, message: { role: "assistant", content: "ok" }, finish_reason: "stop" }] }));
    } else {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ id: "msg_verify", type: "message", role: "assistant", model: "claude-verify", content: [{ type: "text", text: "ok" }], stop_reason: "end_turn", usage: { input_tokens: 1, output_tokens: 1 } }));
    }
  });
}).listen(9000, "127.0.0.1");
'
ROUTE_JS='
const fs = require("fs");
const dir = process.env.SANDBOX_AGENTS_DIR || "/usr/share/sandbox/agents";
const file = JSON.parse(fs.readFileSync(dir + "/" + process.env.SANDBOX_AGENT + "/sidecar.json", "utf8"));
const route = file.modes[process.env.SANDBOX_AUTH].routes.find((r) => r.model === true);
console.log(route.method + " " + route.path + " " + file.bodies[route.body].dialect);
'
MOCK_LOG_JS='require("http").get("http://127.0.0.1:9000/__verify/log", (r) => r.pipe(process.stdout)).on("error", () => process.exit(1));'

SIDECAR_NAMES="B22-credential-swap B22-credential-replace B23-mcp-servers B23-web-fetch B24-oversized B25-search-logged B24-budget"

answered() {   # <probe answer> <status>: did the sidecar answer with this HTTP status
  case "$1" in "http $2"|"http $2 "*) return 0 ;; esac
  return 1
}
mock_log() { podman exec "$TEST_SIDECAR" node -e "$MOCK_LOG_JS" 2>/dev/null || true; }
mock_count() { printf '%s' "$1" | grep -c '^REQ ' || true; }

# Starts the second sidecar. Returns 1 with the reason in SIDECAR_WHY.
SIDECAR_WHY=""
start_test_sidecar() {
  local item prev="" count image tries args=() name="$SESSION-verify-credsidecar"
  podman rm -f -t 0 "$name" >/dev/null 2>&1 || true     # left by an interrupted verify
  [ -f "$ROOT/topology.sh" ] || { SIDECAR_WHY="topology.sh is missing"; return 1; }
  IFS= read -r SANDBOX_VERSION < "$ROOT/VERSION" || true
  export SANDBOX_VERSION SANDBOX_ROOT="$ROOT" SANDBOX_SESSION="$SESSION" SANDBOX_AGENT="$AGENT" SANDBOX_AUTH="$AUTH"
  export SANDBOX_BUDGET=3 SANDBOX_TTL_SECONDS=300 SANDBOX_PROXY_IP="$PROXY_IP" SANDBOX_SIDECAR_IP="$TEST_SIDECAR_IP"
  SANDBOX_SELINUX_OPT=""
  if [ "$SELINUX" = true ]; then SANDBOX_SELINUX_OPT="label=type:container_t"; fi
  export SANDBOX_SELINUX_OPT
  # shellcheck source=../topology.sh
  . "$ROOT/topology.sh"
  topo_sidecar
  # The same arguments, with another name, and the mock as its vendor.
  for item in "${TOPO[@]}"; do
    if [ "$prev" = --name ]; then item="$name"; fi
    prev="$item"
    args+=("$item")
  done
  count="${#args[@]}"
  image="$(field credsidecar image)"
  case "$image" in ''|'!'*) image="${args[$((count - 1))]}" ;; esac
  unset "args[$((count - 1))]"
  args+=(--env "SANDBOX_UPSTREAM_OVERRIDE=http://127.0.0.1:9000" "$image")
  # Podman copies your proxy variables into containers; they have no business there.
  if ! env -u http_proxy -u https_proxy -u ftp_proxy -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u FTP_PROXY -u NO_PROXY \
       podman create "${args[@]}" >/dev/null 2>"$WORK/err"; then
    SIDECAR_WHY="podman create failed: $(head -n 1 "$WORK/err")"; return 1
  fi
  TEST_SIDECAR="$name"
  if ! podman start "$name" >/dev/null 2>"$WORK/err"; then
    SIDECAR_WHY="podman start failed: $(head -n 1 "$WORK/err")"; return 1
  fi
  tries=0
  until podman exec "$name" sidecar-healthcheck >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 40 ]; then SIDECAR_WHY="the second sidecar did not come up: $(podman logs "$name" 2>&1 | tail -n 1)"; return 1; fi
    sleep 0.5
  done
  printf '%s' "$MOCK_JS" | podman exec -i "$name" node - "$DIALECT" "$MARKER" >/dev/null 2>&1 &
  MOCK_PID=$!
  tries=0
  until podman exec "$name" node -e "$MOCK_LOG_JS" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 40 ]; then SIDECAR_WHY="the mock vendor did not start inside the second sidecar"; return 1; fi
    sleep 0.5
  done
}

load_token() {   # <token>: piped in on stdin, as ./sandbox does with the real one
  printf '{"token":"%s","account_id":"verify-account"}' "$1" | podman exec -i "$TEST_SIDECAR" sidecar-load >/dev/null 2>&1
}

ask() {   # <kind>: one request from the agent to the second sidecar; prints "http <status> ..." or "error ..."
  inside_helper sidecar-probe "target=$TEST_SIDECAR_IP" "route_method=$ROUTE_METHOD" "route_path=$ROUTE_PATH" \
    "dialect=$DIALECT" "dummy=$DUMMY" "marker=$MARKER" "kind=$1" | tail -n 1
}

check_sidecar() {
  local route name token1 token2 answer log last before after
  local fix="see images/credsidecar/sidecar.mjs and agents/$AGENT/sidecar.json; the second sidecar's own log was: "
  DUMMY="verify-dummy-$(rand_hex 12)"
  MARKER="verifysearch$(rand_hex 8)"
  token1="verify-real-one-$(rand_hex 12)"
  token2="verify-real-two-$(rand_hex 12)"

  # Which request the CLI makes for a model call: read from the sidecar's own
  # copy of agents/<agent>/sidecar.json, so a new agent needs no change here.
  route="$(podman exec "$SESSION-credsidecar" node -e "$ROUTE_JS" 2>"$WORK/err" | tail -n 1)" || route=""
  read -r ROUTE_METHOD ROUTE_PATH DIALECT <<EOF
$route
EOF
  if [ -z "${DIALECT:-}" ]; then
    SIDECAR_WHY="could not read the model route from the sidecar's sidecar.json: $(head -n 1 "$WORK/err")"
  elif start_test_sidecar && load_token "$token1"; then
    SIDECAR_WHY=""
  else
    SIDECAR_WHY="${SIDECAR_WHY:-the second sidecar did not accept a token}"
  fi
  if [ -n "$SIDECAR_WHY" ]; then
    for name in $SIDECAR_NAMES; do
      skip "$name" no-test-sidecar "$SIDECAR_WHY" "the session's credsidecar container must be running, and topology.sh must be able to describe a second one (podman ps -a; ./sandbox logs sidecar)"
    done
    return 0
  fi

  # B22: the dummy goes in, the real token comes out the other side.
  answer="$(ask model)"; log="$(mock_log)"; last="$(printf '%s\n' "$log" | grep '^REQ ' | tail -n 1 || true)"
  if ! answered "$answer" 200; then
    fail B22-credential-swap "sent a model request ($ROUTE_METHOD $ROUTE_PATH) from the agent with a dummy credential: the sidecar answered '$answer', expected the mock vendor's 200" "$fix$(podman logs "$TEST_SIDECAR" 2>&1 | tail -n 1)"
  elif [[ "$log" == *"$DUMMY"* ]]; then
    fail B22-credential-swap "the agent's dummy credential reached the vendor: the sidecar forwarded it" "$fix$(podman logs "$TEST_SIDECAR" 2>&1 | tail -n 1)"
  elif [[ "$last" != *"$token1"* ]]; then
    fail B22-credential-swap "the request reached the mock vendor without the sidecar's token in any header" "$fix$(podman logs "$TEST_SIDECAR" 2>&1 | tail -n 1)"
  else
    pass B22-credential-swap "sent a model request ($ROUTE_METHOD $ROUTE_PATH) from the agent with a dummy credential to a second sidecar: the mock vendor received the sidecar's token and never saw the dummy"
  fi

  # B22: a token piped in mid-session is used by the very next request.
  load_token "$token2" || true
  answer="$(ask model)"; log="$(mock_log)"; last="$(printf '%s\n' "$log" | grep '^REQ ' | tail -n 1 || true)"
  if answered "$answer" 200 && [[ "$last" == *"$token2"* ]] && [[ "$last" != *"$token1"* ]] && [[ "$log" != *"$DUMMY"* ]]; then
    pass B22-credential-replace "piped a new token into the running sidecar and sent another request: the mock vendor received the new token, not the old one, with no restart"
  else
    fail B22-credential-replace "after a new token was piped in, the next request (answer '$answer') did not carry it to the mock vendor" "$fix$(podman logs "$TEST_SIDECAR" 2>&1 | tail -n 1)"
  fi

  # B23: features that make the vendor's servers contact other hosts.
  before="$(mock_count "$log")"
  answer="$(ask mcp)"; log="$(mock_log)"; after="$(mock_count "$log")"
  if answered "$answer" 400 && [ "$after" = "$before" ]; then
    pass B23-mcp-servers "sent a model request naming a remote MCP server: refused with 400, and the mock vendor never received it"
  else
    fail B23-mcp-servers "a model request naming a remote MCP server was answered '$answer' and the mock vendor saw $((after - before)) new request(s); expected 400 and none" "$fix$(podman logs "$TEST_SIDECAR" 2>&1 | tail -n 1)"
  fi
  before="$after"
  answer="$(ask webfetch)"; log="$(mock_log)"; after="$(mock_count "$log")"
  if answered "$answer" 400 && [ "$after" = "$before" ]; then
    pass B23-web-fetch "sent a model request asking the vendor's servers to fetch a URL: refused with 400, and the mock vendor never received it"
  else
    fail B23-web-fetch "a model request asking for a server-side URL fetch was answered '$answer' and the mock vendor saw $((after - before)) new request(s); expected 400 and none" "$fix$(podman logs "$TEST_SIDECAR" 2>&1 | tail -n 1)"
  fi

  # B24: a body over the size cap (33 MB against a cap of 32).
  before="$after"
  answer="$(ask big)"; log="$(mock_log)"; after="$(mock_count "$log")"
  case "$answer" in
    "http 413"*|error*)
      if [ "$after" = "$before" ]; then
        pass B24-oversized "sent a 33 MB model request: refused ($(printf '%s' "$answer" | cut -c1-8)), and the mock vendor never received it"
      else
        fail B24-oversized "a 33 MB request was answered '$answer' but the mock vendor received it all the same" "$fix$(podman logs "$TEST_SIDECAR" 2>&1 | tail -n 1)"
      fi ;;
    *) fail B24-oversized "a 33 MB model request was answered '$answer'; expected 413" "$fix$(podman logs "$TEST_SIDECAR" 2>&1 | tail -n 1)" ;;
  esac

  # B25: a web search, and its query in the sidecar's log. The third and
  # last request the budget allows.
  answer="$(ask search)"; log="$(mock_log)"
  if [ "$DIALECT" = openai-chat ]; then
    skip B25-search-logged no-search-in-dialect "this agent's model route speaks a format with no web search the sidecar can see" "nothing to log: say so in agents/$AGENT/compat.md"
  elif ! answered "$answer" 200; then
    fail B25-search-logged "a model request with the vendor's web search tool was answered '$answer'; web search is meant to be let through" "$fix$(podman logs "$TEST_SIDECAR" 2>&1 | tail -n 1)"
  elif podman logs "$TEST_SIDECAR" 2>&1 | grep -qF "$MARKER"; then
    pass B25-search-logged "ran one web search through the second sidecar with the query '$MARKER' and found that query in the sidecar's log, as Podman collected it$([ "$DIALECT" = openai-responses ] && printf ' (read from the mock reply; not yet proven against the real vendor)')"
  else
    fail B25-search-logged "ran one web search with the query '$MARKER' and the sidecar's log does not contain it" "$fix$(podman logs "$TEST_SIDECAR" 2>&1 | tail -n 1)"
  fi

  # B24: one request past the budget of 3.
  before="$(mock_count "$log")"
  answer="$(ask model)"; log="$(mock_log)"; after="$(mock_count "$log")"
  if [ "$before" = 3 ] && answered "$answer" 403 && [ "$after" = 3 ]; then
    pass B24-budget "with a budget of 3, the fourth model request was refused with 403 and the mock vendor received exactly 3 (the refused requests above cost nothing)"
  else
    fail B24-budget "with a budget of 3, the mock vendor had received $before requests before the last one and $after after it, and that one was answered '$answer'; expected 3, 3 and 403" "$fix$(podman logs "$TEST_SIDECAR" 2>&1 | tail -n 1)"
  fi
}

# --- B25: the proxy logs every request line ----------------------------------------
check_B25_proxy_log() {
  local line
  line="$(podman logs "$SESSION-proxy" 2>&1 | grep -F "$DENIED_HOST" | head -n 1)" || line=""
  if [ -n "$line" ]; then
    pass B25-proxy-log "the request B20-denied-host made is in the proxy's log, as Podman collected it: $line"
  else
    fail B25-proxy-log "asked the proxy for $DENIED_HOST from the agent, and the proxy's log has no line naming it" \
      "the proxy must log to its standard output (access_log stdio:/dev/stdout in images/proxy/squid.conf.template) and B20-denied-host must have run"
  fi
}

# --- B32: what the launcher prints is filtered ---------------------------------------
controls_in() {   # how many control characters (other than newline and tab) are on stdin
  LC_ALL=C tr -cd '\000-\010\013-\037\177' | wc -c | tr -d ' '
}
check_B32_logs_filter() {
  local marker planted raw shown
  marker="verifyescape$(rand_hex 8)"
  planted="$(inside_helper plant-escapes "marker=$marker")"
  raw="$(podman logs "$SESSION-agent" 2>&1 | grep -aF "$marker" | controls_in || true)"
  if [ "${raw:-0}" -eq 0 ]; then
    skip B32-logs-filter not-planted "could not put an escape sequence into the agent container's log (the helper said: $planted), so the filter was not exercised" \
      "the agent's first process must write to the container's log: ./sandbox logs agent"
    return 0
  fi
  if [ ! -x "$ROOT/sandbox" ]; then
    skip B32-logs-filter unreadable "the launcher $ROOT/sandbox is missing" "restore it from the repository"
    return 0
  fi
  shown="$( { SANDBOX_SESSION="$SESSION" "$ROOT/sandbox" logs agent; SANDBOX_SESSION="$SESSION" "$ROOT/sandbox" logs proxy; } 2>&1 || true)"
  if [[ "$shown" != *"$marker"* ]]; then
    fail B32-logs-filter "'./sandbox logs agent' did not show the line that was planted, so its filter was not exercised" "run SANDBOX_SESSION=$SESSION ./sandbox logs agent by hand"
  elif [ "$(printf '%s' "$shown" | controls_in)" -ne 0 ]; then
    fail B32-logs-filter "wrote escape sequences into the agent's log ($raw control characters are in Podman's raw copy) and into a request line: './sandbox logs' printed $(printf '%s' "$shown" | controls_in) control characters to the terminal" \
      "everything ./sandbox prints from a container must pass through filter_control (./sandbox, cmd_logs)"
  else
    pass B32-logs-filter "wrote escape sequences (set-title, clear-screen, colour) into the agent's log and into a request line to the proxy. Podman's raw log holds them ($raw control characters); './sandbox logs agent' and 'logs proxy' printed the same lines with none"
  fi
}

# ---------------------------------------------------------------------------
# Checking a running session
# ---------------------------------------------------------------------------
verify_session() {
  local role names name state_file
  [[ "$SESSION" =~ $SESSION_PATTERN ]] || die "'$SESSION' is not a session name"
  SESSION_DIR="$(state_dir)/$SESSION"
  state_file="$SESSION_DIR/state"
  [ -f "$state_file" ] || die "there is no session named $SESSION (looked for $state_file)"
  command -v podman >/dev/null 2>&1 || die "podman is not installed"

  AGENT="$(kv "$state_file" AGENT)"; AUTH="$(kv "$state_file" AUTH)"
  SUBNET="$(kv "$state_file" SUBNET)"
  ORIGIN_URL="$(kv "$state_file" ORIGIN_URL)"
  DEADLINE_EPOCH="$(kv "$state_file" DEADLINE_EPOCH)"; CREATED_EPOCH="$(kv "$state_file" CREATED_EPOCH)"
  WORKSPACE_DRIVER="$(kv "$state_file" WORKSPACE_DRIVER)"; WORKSPACE_BYTES="$(kv "$state_file" WORKSPACE_BYTES)"
  STORE="$(kv "$state_file" STORE)"; GIT_RELAY="$(kv "$state_file" GIT_RELAY)"
  PREFIX="${SUBNET%.0/24}"
  [[ "$PREFIX" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the session's state names no usable subnet ('$SUBNET')"
  case "$DEADLINE_EPOCH$CREATED_EPOCH" in ''|*[!0-9]*) die "the session's state has no usable CREATED_EPOCH and DEADLINE_EPOCH" ;; esac
  # Fixed by position in the session's /24 (see ./sandbox, session_addresses).
  GATEWAY="$PREFIX.1"; PROXY_IP="$PREFIX.2"; SIDECAR_IP="$PREFIX.3"; RELAY_IP="$PREFIX.4"
  TEST_SIDECAR_IP="$PREFIX.250"      # for the second sidecar of B22-B25; services start at .20

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-verify.XXXXXX")"
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  # The session's containers, by label. The export helper and our own second
  # sidecar come and go and are not part of the session's standing shape.
  names="$(podman ps -a --filter "label=$LABEL=$SESSION" --format '{{.Names}}' 2>"$WORK/err")" \
    || die "podman ps failed: $(head -n 1 "$WORK/err")"
  ROLES=""
  for name in $names; do
    role="${name#"$SESSION"-}"
    case "$role" in export|verify-*) continue ;; esac
    ROLES="$ROLES${ROLES:+ }$role"
  done
  for role in keeper agent proxy credsidecar; do
    case " $ROLES " in *" $role "*) ;; *) die "session $SESSION has no $role container (podman ps -a shows: ${ROLES:-nothing})" ;; esac
  done
  for role in $ROLES; do
    inspect_load "$role"
  done
  for role in $ROLES; do
    [ "$(field "$role" state)" = running ] \
      || die "the $role container of $SESSION is '$(field "$role" state)', not running. verify needs a live session (has its time limit passed?)"
    probe_load "$role"
  done

  SELINUX="$(podman info --format '{{.Host.Security.SELinuxEnabled}}' 2>/dev/null || true)"
  # One host from each of the proxy's lists, to try from both sides.
  # A line starting with a dot is a whole domain, and its bare name may not
  # answer; a line without one is a host that does.
  ALLOWED_HOST="$(grep -v -m 1 '^\.' "$SESSION_DIR/proxy/agent.domains" 2>/dev/null || true)"
  VENDOR_HOST="$(grep -v -m 1 '^\.' "$SESSION_DIR/proxy/sidecar.domains" 2>/dev/null || true)"
  DENIED_HOST="v$(rand_hex 8).example.com"
  ALLOW_HTTP=0
  if grep -q 'url_regex' "$SESSION_DIR/proxy/extra.conf" 2>/dev/null; then ALLOW_HTTP=1; fi

  # What was asked for, as Podman recorded it, for the in-container checks.
  PARAMS=(
    "uid=61000"
    "pids=$(field agent pids | tr -cd '0-9')"
    "mem=$(field agent memory | tr -cd '0-9')"
    "nofile=$(ulimit_asked nofile)" "nproc=$(ulimit_asked nproc)" "fsize=$(ulimit_asked fsize)"
    "tmp_size=$(tmpfs_size /tmp)" "home_size=$(tmpfs_size /home)" "shm_size=$(tmpfs_size /dev/shm)"
    "ws_size=$WORKSPACE_BYTES" "ws_driver=$WORKSPACE_DRIVER"
    "subnet=$PREFIX" "gateway=$GATEWAY" "proxy=$PROXY_IP" "sidecar=$SIDECAR_IP" "relay=$RELAY_IP" "git_relay=$GIT_RELAY"
    "allowed_host=$ALLOWED_HOST" "vendor_host=$VENDOR_HOST" "denied_host=$DENIED_HOST" "allow_http=$ALLOW_HTTP"
    "selinux=$SELINUX" "label=$(field agent label | grep -v '^!' || true)"
    "origin_url=$ORIGIN_URL"
  )
  case "$(field agent nanocpus)" in
    ''|*[!0-9]*) ;;
    *) PARAMS+=("cpu_milli=$(( $(field agent nanocpus) / 1000000 ))") ;;
  esac

  # --- physical barriers ------------------------------------------------------
  run_inside B01-user B02-caps B02-raw-socket
  check_B02_caps_all
  run_inside B03-nnp-flag B03-setuid-inert
  check_B03_nnp_all
  run_inside B04-seccomp-mode B04-ptrace B04-mount B04-unshare-user B04-clone-newuser B04-clone3 B04-setns B04-process-vm-readv B04-bpf \
             B05-lsm-label B06-runtime-sockets B06-runtime-binaries B06-pid1 B06-cgroupns
  check_B06_private_modes
  check_B06_runtime_class
  run_inside B07-readonly-root
  check_B07_readonly_all
  run_inside B08-writable-set B08-mount-flags
  check_B08_workspace_volume
  if [ "$QUICK" -eq 1 ]; then
    skip B08-fill quick "filling every memory-backed place to the brim is left out of --quick"
  else
    run_inside B08-fill
    # If the check was killed half-way, its files are still there.
    podman exec "$SESSION-agent" sh -c 'rm -f /tmp/.verify-fill.* /home/.verify-fill.* /dev/shm/.verify-fill.* /workspace/.verify-fill.*' >/dev/null 2>&1 || true
  fi
  run_inside B09-mounts
  check_B09_host_mounts
  run_inside B10-pids-max B10-memory-max B10-swap-max B10-cpu-max
  check_B10_limits_all
  if [ "$QUICK" -eq 1 ]; then
    skip B10-fork-limit quick "forking up to the process limit is left out of --quick"
  else
    run_inside B10-fork-limit
  fi
  run_inside B11-ulimits B11-fsize
  check_B11_core_all
  run_inside B12-no-route
  check_B12_network_attach
  check_B13_network_no_gateway
  run_inside B13-gateway-ports B13-etc-hosts B14-no-resolver B14-dns-by-hand
  check_B15_token_absent
  run_inside B15-key-files B15-push B16-add-address B16-packet-socket

  # --- logical barriers -------------------------------------------------------
  run_inside B20-allowed-host B20-denied-host B20-port-80 B20-connect-port B20-ip-literal-v4 B20-ip-literal-v6
  check_B20_never_allow
  run_inside B21-vendor-plain B21-vendor-forged
  check_B21_sidecar_allowed
  check_sidecar
  run_inside B23-unknown-path
  check_B25_proxy_log
  check_B26_deadline_set
  check_B26_keeper
  skip B26-deadline separate "letting a time limit pass, with the launcher gone and the agent forking, needs a session of its own: scripts/verify.sh --deadline-test"
  skip B27-export separate "the export attempts (hostile .git/config and hooks, attribution, a fake secret, a hidden lockfile change, a symlink, an endless stream) run in: scripts/verify.sh --deadline-test"
  check_B28_log_driver
  check_B29_rootless
  if [ "$QUICK" -eq 1 ]; then
    skip B29-doctor quick "running doctor again is left out of --quick (./sandbox run has just run its checks)"
  else
    check_B29_doctor
  fi
  run_inside B30-other-branch B30-tag
  if [ "$GIT_RELAY" = 1 ]; then
    # The register does not claim this one: the relay never unpacks what is
    # pushed, so it cannot tell a rewrite of history from an ordinary push,
    # and trying it for real would rewrite your branch. Said on every run so
    # nobody takes the relay for more than it is.
    skip B30-force-push branch-rule "not attempted: the relay cannot refuse a force-push (images/gitrelay/relay.mjs says why). Protect the session branch on the git host with a no-force-push rule"
  else
    skip B30-force-push no-git-relay "this session has no git relay (it is off unless you pass --git-relay)"
  fi
  skip B31-destroy separate "checking that destroy leaves nothing would destroy this session; it runs in: scripts/verify.sh --deadline-test"
  check_B32_logs_filter
  if [ "$WORKSPACE_DRIVER" = local ]; then
    skip B33-store separate "writing past this session's share of the disk store would stop it; it runs in: scripts/verify.sh --store-test"
  else
    skip B33-store memory-workspace "this session's workspace is held in memory; the disk store watch only exists with --workspace-driver local"
  fi
  finish
}

# ---------------------------------------------------------------------------
# Sessions of verify's own, for the checks that would wreck a real one.
# ---------------------------------------------------------------------------
T=""            # scratch directory
OWN=""          # the session made here
RUN_PID=""
own_cleanup() {
  if [ -n "$RUN_PID" ]; then kill "$RUN_PID" 2>/dev/null || true; fi
  if [ -n "$OWN" ] && [ -d "$SANDBOX_STATE_DIR/$OWN" ]; then
    SANDBOX_SESSION="$OWN" "$ROOT/sandbox" destroy >/dev/null 2>&1 || true
  fi
  if [ -n "$T" ]; then rm -rf "$T"; fi
}

own_setup() {
  command -v podman >/dev/null 2>&1 || die "podman is not installed"
  command -v git >/dev/null 2>&1 || die "git is not installed"
  [ -x "$ROOT/sandbox" ] || die "the launcher $ROOT/sandbox is missing"
  T="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-verify.XXXXXX")"
  # A state directory of its own, so the session made here is the only one
  # the launcher sees and yours are left alone.
  export SANDBOX_STATE_DIR="$T/state"
  mkdir -m 700 "$SANDBOX_STATE_DIR"
  trap own_cleanup EXIT
  trap 'exit 130' INT TERM
  git init -q "$T/repo"
  printf 'a throwaway repository made by scripts/verify.sh\n' > "$T/repo/README"
  git -C "$T/repo" add README
  git -C "$T/repo" -c user.name=verify -c user.email=verify@example.invalid commit -q -m "verify: first commit"
}

# own_session <run arguments>: starts ./sandbox run with no terminal, waits
# until the agent container runs, then makes sure the launcher is gone, as if
# its terminal had been closed. Sets OWN and STARTED. Returns 1 if no session
# came up.
STARTED=0
own_session() {
  local waited=0 dir
  OWN=""
  # With the test key set, these sessions use it and need nothing in the
  # keyring (./sandbox reads it for claude with --auth apikey only).
  [ -z "${SANDBOX_TEST_ANTHROPIC_KEY:-}" ] || set -- --agent claude --auth apikey "$@"
  ( cd "$ROOT" && exec nohup ./sandbox run "$T/repo" "$@" </dev/null >"$T/run.log" 2>&1 ) &
  RUN_PID=$!
  # Images may have to be built on the first run: up to twenty minutes.
  while [ "$waited" -lt 1200 ]; do
    for dir in "$SANDBOX_STATE_DIR"/asb-*; do
      if [ -f "$dir/state" ]; then OWN="${dir##*/}"; fi
    done
    if [ -n "$OWN" ] && [ "$(podman inspect --format '{{.State.Running}}' "$OWN-agent" 2>/dev/null || true)" = true ] \
       && grep -q 'runs until' "$T/run.log" 2>/dev/null; then
      break
    fi
    if ! kill -0 "$RUN_PID" 2>/dev/null; then break; fi
    sleep 1
    waited=$((waited + 1))
  done
  STARTED="$(date +%s)"
  # The terminal is closed: the launcher is gone, and so is its watchdog when
  # asked for. What happens next is up to Podman alone.
  kill "$RUN_PID" 2>/dev/null || true
  wait "$RUN_PID" 2>/dev/null || true
  RUN_PID=""
  [ -n "$OWN" ] && [ "$(podman inspect --format '{{.State.Running}}' "$OWN-agent" 2>/dev/null || true)" = true ]
}

kill_watchdog() {
  local pid=""
  [ -f "$SANDBOX_STATE_DIR/$OWN/watchdog.pid" ] || return 0
  IFS= read -r pid < "$SANDBOX_STATE_DIR/$OWN/watchdog.pid" || true
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill "$pid" 2>/dev/null || true
}

# bounded <seconds> <command...>: runs it, kills it if it takes longer.
# Returns the command's status, or 124 when it had to be killed.
bounded() {
  local limit="$1" waited=0 pid status=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" || status=$?
  return "$status"
}

# What the agent would do to attack the export: run inside the agent
# container, as the agent's user, in its repository. [B27, B32]
# shellcheck disable=SC2016  # run by the container's bash, not expanded here
PLANT='set -eu
marker="$1"; canary="$2"; secret="$3"
cd /workspace/repo
export GIT_AUTHOR_NAME=verify GIT_AUTHOR_EMAIL=verify@example.invalid GIT_COMMITTER_NAME=verify GIT_COMMITTER_EMAIL=verify@example.invalid
# A lockfile change, hidden from diff tools the usual way.
printf "{\"lockfileVersion\":3,\"verify\":\"%s\"}\n" "$marker" > package-lock.json
printf "package-lock.json -diff binary linguist-generated\n" > .gitattributes
git add -A; git commit -q -m "verify: a lockfile change hidden with .gitattributes"
# A symlink to a path on the host.
ln -s /etc/passwd "host-link-$marker"
git add -A; git commit -q -m "verify: a symlink to a host path"
# A fake secret, with both of the ways a tree can tell gitleaks to look away.
printf "token = \"%s\"  # gitleaks:allow\n" "$secret" > verify-secret.txt
git add -A; git commit -q -m "verify: a fake secret"
printf "%s:verify-secret.txt:github-pat:1\n" "$(git rev-parse HEAD)" > .gitleaksignore
git add -A; git commit -q -m "verify: a .gitleaksignore entry for it"
# AI attribution.
git commit -q --allow-empty -m "$(printf "verify: attribution\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n")"
# Escape sequences in a commit message.
git commit -q --allow-empty -m "$(printf "verify-esc-%s \033]0;owned\007\033[2J\033[31m" "$marker")"
# Last, so the commits above still work: a config and hooks that run a
# command whenever git is used in this tree.
git config core.fsmonitor "touch $canary"
git config core.sshCommand "touch $canary"
git config core.pager "touch $canary"
mkdir -p .git/hooks
for hook in post-checkout post-merge pre-commit reference-transaction; do
  printf "#!/bin/sh\ntouch %s 2>/dev/null\nexit 0\n" "$canary" > ".git/hooks/$hook"
  chmod +x ".git/hooks/$hook"
done
echo planted'

deadline_test() {
  local ttl marker secret canary branch state status=0 names name left bad="" shown real out exported=0
  own_setup
  marker="$(rand_hex 6)"
  secret="ghp_$(rand_hex 18)"          # shaped like a GitHub token; random, opens nothing
  canary="$T/host-command-ran"

  if ! own_session --ttl 3m --mem 1g --workspace-size 256m; then
    for name in B26-deadline B26-export-after-deadline B27-git-config-hook B27-attribution B27-secret-scan B27-dependency-diff B27-symlink B27-endless-stream B31-destroy B32-export-filter; do
      skip "$name" no-session "./sandbox run did not bring a session up: $(tail -n 3 "$T/run.log" 2>/dev/null)" \
        "run ./sandbox doctor, and ./sandbox login if there is no credential in the keyring; then try again"
    done
    finish
  fi
  state="$SANDBOX_STATE_DIR/$OWN/state"
  branch="$(kv "$state" BRANCH)"
  # The time limit as the session itself recorded it (3 minutes was asked for).
  ttl=$(( $(kv "$state" DEADLINE_EPOCH) - $(kv "$state" CREATED_EPOCH) ))

  out="$(printf '%s' "$PLANT" | podman exec -i "$OWN-agent" bash -s -- "$marker" "$canary" "$secret" 2>&1 | tail -n 1)" || out="failed"
  # An agent that forks as fast as it can must not outlive the deadline either.
  podman exec -d "$OWN-agent" bash -c 'while :; do sleep 30 & done' >/dev/null 2>&1 || true
  kill_watchdog

  printf 'Session %s is up; waiting about %s seconds for its time limit to pass with no launcher running...\n' "$OWN" "$ttl"
  while [ "$(date +%s)" -lt $((STARTED + ttl + 20)) ]; do sleep 1; done

  # --- B26 ----------------------------------------------------------------------
  names="$(podman ps -a --filter "label=$LABEL=$OWN" --format '{{.Names}} {{.State}}' 2>/dev/null)" || names=""
  shown="$(printf '%s' "$names" | tr '\n' ',')"
  while read -r name status; do
    [ -n "$name" ] || continue
    case "$name" in
      *-keeper) [ "$status" = running ] || bad="$bad the keeper is '$status' (the workspace is gone);" ;;
      *) [ "$status" != running ] || bad="$bad $name is still running;" ;;
    esac
  done <<EOF
$names
EOF
  case "$names" in *-agent*) ;; *) bad="$bad podman ps shows no agent container at all;" ;; esac
  if [ -z "$bad" ]; then
    pass B26-deadline "ran a session with a time limit of $ttl seconds, ended the launcher, and set the agent forking without pause. Twenty seconds after the limit, with nothing of the sandbox running on the host: every container but the keeper is dead ($shown)"
  else
    fail B26-deadline "after the time limit, with the launcher gone:$bad ($shown)" \
      "every container but the keeper must be created with --timeout (topology.sh, _topo_deadline): Podman's own monitor does the killing"
  fi

  # --- B26, B27, B32: export after the deadline -----------------------------------
  status=0
  ( cd "$ROOT" && SANDBOX_SESSION="$OWN" ./sandbox export --out "$T/out" ) > "$T/export.log" 2>&1 || status=$?
  if { [ "$status" -eq 0 ] || [ "$status" -eq 2 ]; } && [ -d "$T/out/$OWN/repo.git" ] && [ -f "$T/out/$OWN/export.status" ]; then
    exported=1
    pass B26-export-after-deadline "after the deadline had killed the agent, './sandbox export' still brought the work out (status $status, $T/out/$OWN/repo.git): the keeper held the workspace"
  else
    fail B26-export-after-deadline "after the deadline, './sandbox export' ended with status $status and no repository: $(tail -n 2 "$T/export.log")" \
      "the keeper must hold the workspace volume and have no deadline (topology.sh, topo_keeper); the plant step said: $out"
  fi

  if [ "$exported" -eq 0 ] || [ "$out" != planted ]; then
    for name in B27-git-config-hook B27-attribution B27-secret-scan B27-dependency-diff B27-symlink B32-export-filter; do
      skip "$name" no-export "there is no export to examine (planting said '$out', export ended with status $status)" "fix B26-export-after-deadline first"
    done
  else
    if [ -e "$canary" ]; then
      fail B27-git-config-hook "planted a .git/config and hooks that run a command; after export that command HAD RUN ON THIS HOST ($canary exists)" \
        "nothing on the host may run git inside a tree the agent wrote: export must fetch from the bundle only (scripts/export.sh)"
    elif grep -Eq 'fsmonitor|sshCommand|pager' "$T/out/$OWN/repo.git/config" 2>/dev/null; then
      fail B27-git-config-hook "the agent's git configuration was carried into the exported repository's config" "export must create its own repository and fetch one branch into it (scripts/export.sh)"
    else
      pass B27-git-config-hook "planted core.fsmonitor, core.sshCommand, core.pager and four hooks that each run a command in the agent's repository, then exported: the command never ran on this host, and the exported repository has none of them"
    fi

    case "$(kv "$T/out/$OWN/export.status" ATTRIBUTION)" in
      stripped)
        if git --git-dir="$T/out/$OWN/repo.git" log --format=%B "refs/heads/$branch" 2>/dev/null | grep -qi 'co-authored-by'; then
          fail B27-attribution "export says it stripped the attribution trailer, but a commit message in the exported branch still has one" "see the attribution step of scripts/export.sh"
        else
          pass B27-attribution "committed with a 'Co-Authored-By: Claude' trailer; export stripped it, and no commit message of the exported branch has one"
        fi ;;
      refused) pass B27-attribution "committed with a 'Co-Authored-By: Claude' trailer; export found it, could not strip it and refused to mark the export clean" ;;
      *) fail B27-attribution "committed with a 'Co-Authored-By: Claude' trailer; export.status says ATTRIBUTION=$(kv "$T/out/$OWN/export.status" ATTRIBUTION): it was not noticed" "see the attribution step of scripts/export.sh" ;;
    esac

    case "$(kv "$T/out/$OWN/export.status" SCAN)" in
      failed) pass B27-secret-scan "committed a fake token with a 'gitleaks:allow' comment and a .gitleaksignore entry naming it: the scan found it all the same (SCAN=failed), so push and pr refuse" ;;
      not-run) skip B27-secret-scan no-gitleaks "gitleaks is not installed on this host, so the scan did not run (export says SCAN=not-run and refuses push and pr)" "install gitleaks, then run this again" ;;
      *) fail B27-secret-scan "committed a fake token with a 'gitleaks:allow' comment and a .gitleaksignore entry: export.status says SCAN=$(kv "$T/out/$OWN/export.status" SCAN)" \
           "gitleaks must run with the configuration shipped in policy/gitleaks.toml and ignore every allow-list in the tree (scripts/export.sh)" ;;
    esac

    # Hidden the usual way: '-diff binary' makes diff tools say "binary files
    # differ" and move on. Caught = the report lists the lockfile as changed
    # among the files that run later, lists the .gitattributes file that did
    # the hiding, and does not call the lockfile binary.
    if grep -Eq '^[[:space:]]+[AM][[:space:]]+package-lock\.json$' "$T/export.log" \
       && grep -Eq '^[[:space:]]+[AM][[:space:]]+\.gitattributes$' "$T/export.log" \
       && ! grep -Eq 'Binary files.*package-lock\.json|package-lock\.json.*\| *Bin' "$T/export.log"; then
      pass B27-dependency-diff "changed package-lock.json and marked it '-diff binary' in .gitattributes: export listed the lockfile as changed among the files that run later, and listed the .gitattributes that tried to hide it"
    else
      fail B27-dependency-diff "changed package-lock.json and hid it with '-diff binary' in .gitattributes: export's report does not list both as changed" \
        "export must read git objects with attributes switched off and report lockfiles and .gitattributes in its 'runs later' section (scripts/export.sh, policy/runs-later.txt)"
    fi

    if ! grep -qF "host-link-$marker" "$T/export.log"; then
      fail B27-symlink "committed a symlink to /etc/passwd: export did not mention it" "symlinks belong in the 'runs later' section of the export report (scripts/export.sh, policy/runs-later.txt)"
    elif [ -n "$(find "$T/out/$OWN" -name "host-link-*" -not -path '*/repo.git/*' 2>/dev/null)" ]; then
      fail B27-symlink "committed a symlink to /etc/passwd: export CHECKED IT OUT on this host" "export must never check files out (scripts/export.sh)"
    else
      pass B27-symlink "committed a symlink to /etc/passwd: export reported it and checked nothing out on this host"
    fi

    if ! grep -qF "verify-esc-$marker" "$T/export.log"; then
      fail B32-export-filter "committed with escape sequences in the message: export did not print that commit at all, so its filter was not exercised" "see what ./sandbox export printed: $T/export.log is removed when this ends, so run it by hand"
    elif [ "$(controls_in < "$T/export.log")" -ne 0 ]; then
      fail B32-export-filter "committed with escape sequences in the message: './sandbox export' printed $(controls_in < "$T/export.log") control characters to the terminal" \
        "everything ./sandbox export prints must pass through filter_control (./sandbox, cmd_export)"
    else
      pass B32-export-filter "committed with set-title, clear-screen and colour escape sequences in the message: './sandbox export' printed that commit with no control character left"
    fi
  fi

  # --- B27: an endless stream in place of the bundle --------------------------------
  # The helper container cannot be made to do this (its program is on a
  # read-only image), so the stream is swapped here: for this one export a
  # stand-in `podman` answers the helper's call with an endless stream and
  # passes every other call to the real one.
  real="$(command -v podman)"
  mkdir "$T/shim"
  cat > "$T/shim/podman" <<EOF
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = sandbox-bundle ]; then exec yes endless-stream-from-verify; fi
done
exec "$real" "\$@"
EOF
  chmod +x "$T/shim/podman"
  status=0
  ( cd "$ROOT" && PATH="$T/shim:$PATH" SANDBOX_SESSION="$OWN" bounded 300 ./sandbox export --out "$T/out-endless" ) > "$T/endless.log" 2>&1 || status=$?
  # export writes what it reads beside its destination and removes it when
  # it refuses; a bundle still there is the stream, kept.
  left="$(find "$T/out-endless" -maxdepth 1 -name '.*.bundle' 2>/dev/null | head -n 1 || true)"
  if [ "$status" -eq 124 ]; then
    fail B27-endless-stream "fed export a stream that never ends in place of the bundle: after five minutes it was still reading" "export must stop reading at the workspace size cap (./sandbox, cmd_export)"
  elif [ "$status" -eq 0 ] || [ "$status" -eq 2 ] || [ -d "$T/out-endless/$OWN/repo.git" ] || [ -n "$left" ]; then
    fail B27-endless-stream "fed export a stream that never ends in place of the bundle: it ended with status $status$([ -n "$left" ] && printf ' and left %s behind' "$left")" "export must stop at the workspace size cap and refuse what it read (./sandbox, cmd_export)"
  else
    pass B27-endless-stream "fed export a stream that never ends in place of the bundle: it stopped reading at the workspace cap, refused, exported nothing and kept nothing ($(tail -n 1 "$T/endless.log"))"
  fi

  # --- B31 ----------------------------------------------------------------------------
  status=0
  ( cd "$ROOT" && SANDBOX_SESSION="$OWN" ./sandbox destroy ) > "$T/destroy.log" 2>&1 || status=$?
  left="$( { podman ps -a --filter "label=$LABEL=$OWN" --format 'container:{{.Names}}'
             podman network ls --filter "label=$LABEL=$OWN" --format 'network:{{.Name}}'
             podman volume ls --filter "label=$LABEL=$OWN" --format 'volume:{{.Name}}'
             podman ps -a --format 'container:{{.Names}}' | grep -F "$OWN" || true
             podman network ls --format 'network:{{.Name}}' | grep -F "$OWN" || true
             podman volume ls --format 'volume:{{.Name}}' | grep -F "$OWN" || true
           } 2>/dev/null | sort -u | tr '\n' ' ' || true)"
  if [ -e "$SANDBOX_STATE_DIR/$OWN" ]; then left="$left directory:$SANDBOX_STATE_DIR/$OWN"; fi
  if [ "$status" -eq 0 ] && [ -z "${left// /}" ]; then
    pass B31-destroy "ran './sandbox destroy', then listed containers, networks and volumes by the session's label and by its name, and looked for its directory: nothing is left (the container logs went with the containers)"
  else
    fail B31-destroy "after './sandbox destroy' (status $status) this is left of the session: $left" "see destroy_session in ./sandbox; remove what is left with podman rm, podman network rm, podman volume rm"
  fi
  OWN=""
  finish
}

store_test() {
  local store free_kb size out status=0 waited=0
  store="$(kv "$(config_dir)/settings" STORE)"
  if [ -z "$store" ]; then
    skip B33-share-watch no-store "no disk store is configured (STORE is empty in $(config_dir)/settings), so --workspace-driver local cannot be used and this barrier does not exist here"
    skip B33-store-full no-store "no disk store is configured"
    finish
  fi
  own_setup

  # --- writing past the session's share stops the session ------------------------
  if ! own_session --workspace-driver local --workspace-size 64m --ttl 15m --mem 1g; then
    skip B33-share-watch no-session "./sandbox run --workspace-driver local did not bring a session up: $(tail -n 3 "$T/run.log" 2>/dev/null)" "run ./sandbox doctor; it explains how to make the store"
  else
    podman exec "$OWN-agent" dd if=/dev/zero of=/workspace/.verify-over bs=1048576 count=96 >/dev/null 2>&1 || true
    while [ "$waited" -lt 120 ] && [ "$(podman inspect --format '{{.State.Running}}' "$OWN-agent" 2>/dev/null || true)" = true ]; do
      sleep 5; waited=$((waited + 5))
    done
    if [ "$(podman inspect --format '{{.State.Running}}' "$OWN-agent" 2>/dev/null || true)" != true ] && [ -f "$SANDBOX_STATE_DIR/$OWN/stopped" ]; then
      pass B33-share-watch "gave a session 64 MB of the disk store and wrote 96 MB: the host's watch stopped the session after about $waited seconds and recorded why"
    else
      fail B33-share-watch "gave a session 64 MB of the disk store and wrote 96 MB: two minutes later the agent is $(podman inspect --format '{{.State.Status}}' "$OWN-agent" 2>/dev/null || printf 'gone')" \
        "the watchdog must be running for a local-driver session (./sandbox, start_watchdog and watchdog_tick); look at <session dir>/watchdog.log"
    fi
    ( cd "$ROOT" && SANDBOX_SESSION="$OWN" ./sandbox destroy ) >/dev/null 2>&1 || true
  fi
  OWN=""

  # --- the hard wall: the store itself fills up -----------------------------------
  # A share larger than the store, and no watch: only the filesystem's own
  # size can stop the writing now.
  free_kb="$(df -Pk "$store" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  case "$free_kb" in ''|*[!0-9]*) free_kb=0 ;; esac
  size="$(( free_kb / 1048576 + 2 ))g"
  if ! own_session --workspace-driver local --workspace-size "$size" --ttl 30m --mem 1g; then
    skip B33-store-full no-session "./sandbox run --workspace-driver local --workspace-size $size did not bring a session up: $(tail -n 3 "$T/run.log" 2>/dev/null)" "run ./sandbox doctor"
    finish
  fi
  kill_watchdog
  printf 'Filling the disk store (%s MB free); other sessions on it will see it full until this ends...\n' "$((free_kb / 1024))"
  # One gigabyte per file, until the first write that fails.
  # shellcheck disable=SC2016  # run by the container's sh
  out="$(podman exec "$OWN-agent" sh -c 'n=0; while :; do if ! out=$(LC_ALL=C dd if=/dev/zero of=/workspace/.verify-full.$n bs=1048576 count=1024 2>&1); then echo "$out" | tail -n 3; break; fi; n=$((n+1)); [ "$n" -lt 4096 ] || { echo never-filled; break; }; done; rm -f /workspace/.verify-full.*' 2>&1)" || status=$?
  case "$out" in
    *"No space left on device"*) pass B33-store-full "took the watch away and wrote to the workspace until it stopped: the store answered 'No space left on device', and the files were removed" ;;
    *) fail B33-store-full "wrote to the disk-backed workspace without a watch and it did not end with 'No space left on device' (status $status): $out" \
         "the store must be a filesystem of fixed size of its own, not a directory on your disk (./sandbox doctor explains how to make one)" ;;
  esac
  ( cd "$ROOT" && SANDBOX_SESSION="$OWN" ./sandbox destroy ) >/dev/null 2>&1 || true
  OWN=""
  finish
}

# ---------------------------------------------------------------------------
main() {
  local mode=session
  QUICK=0; SESSION=""; CREDENTIAL_FD=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --quick) QUICK=1 ;;
      # ./sandbox run hands the credential it has just loaded over on an open
      # file descriptor, so a session started by typing the credential in can
      # be checked too. A descriptor, not an argument: arguments are visible
      # to every process on the host.
      --credential-fd)
        [ $# -ge 2 ] || die "--credential-fd needs a number"
        CREDENTIAL_FD="$2"; shift ;;
      --deadline-test) mode=deadline ;;
      --store-test) mode=store ;;
      -*) die "unknown option $1. Usage: verify.sh [--quick] <session> | --deadline-test | --store-test" ;;
      *) [ -z "$SESSION" ] || die "one session at a time"; SESSION="$1" ;;
    esac
    shift
  done
  case "$mode" in
    deadline) deadline_test ;;
    store) store_test ;;
    session)
      [ -n "$SESSION" ] || die "usage: verify.sh [--quick] <session> | --deadline-test | --store-test"
      verify_session ;;
  esac
}

main "$@"
