#!/usr/bin/env bash
# Static check of topology.sh: build every argument list with sample values
# and assert the hardening is there. This proves what ./sandbox would ASK
# Podman for; whether Podman does it is for `./sandbox verify` on a real host.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../../topology.sh
source "$root/topology.sh"

export SANDBOX_SESSION=asb-test-0a1b2c SANDBOX_ROOT="$root"
export SANDBOX_SUBNET=10.201.7.0/24 SANDBOX_EGRESS_SUBNET=10.202.7.0/24
export SANDBOX_AGENT_IP=10.201.7.10 SANDBOX_PROXY_IP=10.201.7.2
export SANDBOX_SIDECAR_IP=10.201.7.3 SANDBOX_RELAY_IP=10.201.7.4
export SANDBOX_WORKSPACE_DRIVER=memory SANDBOX_WORKSPACE_SIZE=4g
export SANDBOX_CPUS=2 SANDBOX_MEM_LIMIT=10804527104 SANDBOX_PIDS=512
export SANDBOX_NPROC=512 SANDBOX_FSIZE_BYTES=4294967296
export SANDBOX_TMP_SIZE=1g SANDBOX_HOME_SIZE=1g SANDBOX_TTL_SECONDS=14400
export SANDBOX_AGENT=claude SANDBOX_TOOLCHAIN=node SANDBOX_VERSION=test
export SANDBOX_AUTH=oauth SANDBOX_BUDGET=500
export SANDBOX_BRANCH=agent/asb-test-0a1b2c
export SANDBOX_RELAY_UPSTREAM=https://git.example/you/project.git
export SANDBOX_SESSION_DIR=/nonexistent/asb-test-0a1b2c

fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

# has <flag-or-word>: true when TOPO contains that exact element.
has() {
  local want="$1" item
  for item in "${TOPO[@]}"; do
    [ "$item" = "$want" ] && return 0
  done
  return 1
}
# has_pair <flag> <value>: true when the flag is followed by that value.
has_pair() {
  local i
  for ((i = 0; i < ${#TOPO[@]} - 1; i++)); do
    [ "${TOPO[i]}" = "$1" ] && [ "${TOPO[i + 1]}" = "$2" ] && return 0
  done
  return 1
}
# value_of <flag>: prints every value given to that flag, one per line.
value_of() {
  local i
  for ((i = 0; i < ${#TOPO[@]} - 1; i++)); do
    [ "${TOPO[i]}" = "$1" ] && printf '%s\n' "${TOPO[i + 1]}"
  done
  return 0
}

# Read by topo_service in topology.sh.
# shellcheck disable=SC2034
SVC_IMAGE='docker.io/library/postgres:16-alpine@sha256:0000' SVC_USER=70:70
# shellcheck disable=SC2034
SVC_TMPFS=('/var/lib/postgresql/data:size=512m,mode=1777,nosuid,nodev,noexec')
# shellcheck disable=SC2034
SVC_ENV=('POSTGRES_PASSWORD=sandbox') SVC_MEMORY=1g SVC_PIDS=128 SVC_COMMAND=()

containers='keeper agent export proxy sidecar gitrelay service'
for c in $containers; do
  case "$c" in
    service) topo_service postgres 10.201.7.20 ;;
    *) "topo_$c" ;;
  esac

  # Hardening every container must carry (B02, B03, B06, B07, B10, B11, B28).
  for flag in --read-only --read-only-tmpfs=false --cap-drop=ALL \
    --security-opt=no-new-privileges --ipc=private --pid=private \
    --cgroupns=private --restart=no --pull=never --http-proxy=false \
    --no-hosts --log-driver=k8s-file; do
    has "$flag" || fail "$c: missing $flag"
  done
  has_pair --ulimit core=0:0 || fail "$c: core dumps not switched off"
  [ -n "$(value_of --memory)" ] || fail "$c: no memory limit"
  [ "$(value_of --memory)" = "$(value_of --memory-swap)" ] ||
    fail "$c: memory-plus-swap limit differs from the memory limit"
  [ -n "$(value_of --pids-limit)" ] || fail "$c: no process limit"
  [ -n "$(value_of --cpus)" ] || fail "$c: no CPU limit"
  [ -n "$(value_of --user)" ] || fail "$c: no user"
  case "$(value_of --user)" in
    0 | 0:* | root | root:*) fail "$c: runs as root" ;;
  esac

  # Things no container may have (B06, B09).
  for bad in --privileged --cap-add --device --network=host --pid=host \
    --ipc=host --userns=host --add-host; do
    has "$bad" && fail "$c: has $bad"
  done
  for item in "${TOPO[@]}"; do
    case "$item" in
      *podman.sock* | *docker.sock*) fail "$c: mounts a runtime socket: $item" ;;
      --cap-add=* | --device=* | --privileged=*) fail "$c: has $item" ;;
    esac
  done

  # Every memory mount is capped and nosuid,nodev (B08).
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in *size=*) ;; *) fail "$c: tmpfs without a size cap: $t" ;; esac
    case "$t" in *nosuid*) ;; *) fail "$c: tmpfs without nosuid: $t" ;; esac
    case "$t" in *nodev*) ;; *) fail "$c: tmpfs without nodev: $t" ;; esac
  done < <(value_of --tmpfs)

  # The deadline: everything but the keeper (B26).
  if [ "$c" = keeper ]; then
    has --timeout && fail "keeper: must have no deadline, it holds the workspace"
  else
    has --timeout || fail "$c: no deadline"
  fi
done

# The agent specifically.
topo_agent
has_pair --user 61000:61000 || fail "agent: not uid 61000"
value_of --security-opt | grep -q '^seccomp=.*/seccomp/agent-seccomp.json$' ||
  fail "agent: custom seccomp profile not applied"
has --dns=none || fail "agent: resolver configuration not suppressed"
# Nothing is found by name (B13, B14): Podman writes no /etc/hosts, so every
# address the agent is given must be a number.
has_pair --hostname sandbox || fail "agent: its own name is not the one the image's /etc/hosts holds"
has_pair --env HTTPS_PROXY=http://10.201.7.2:3128 || fail "agent: the proxy is not given by address"
has_pair --env SANDBOX_SIDECAR_URL=http://10.201.7.3:8080 || fail "agent: the sidecar is not given by address"
has_pair --env NO_PROXY=localhost,127.0.0.1,10.201.7.3 || fail "agent: NO_PROXY is not the sidecar's address"
for item in "${TOPO[@]}"; do
  case "$item" in
    *//proxy* | *//sidecar* | *//gitrelay* | *,sidecar* | *,gitrelay*) fail "agent: a container is named, not addressed: $item" ;;
  esac
done
[ "$(value_of --network)" = "asb-test-0a1b2c-sandbox:ip=10.201.7.10" ] ||
  fail "agent: must be on the sandbox network only, got: $(value_of --network | tr '\n' ' ')"
has --volume && fail "agent: has a bind mount (--volume)"
value_of --mount | grep -qv '^type=volume,' && fail "agent: has a mount that is not the named volume"
for item in "${TOPO[@]}"; do
  case "$item" in
    *API_KEY=* | *OAUTH_TOKEN=* | *_TOKEN=*) fail "agent: a credential-looking variable is passed: ${item%%=*}" ;;
  esac
done
has_pair --ulimit nofile=65536:65536 || fail "agent: nofile ulimit"
has_pair --ulimit nproc=512:512 || fail "agent: nproc ulimit"
has_pair --ulimit fsize=4294967296:4294967296 || fail "agent: fsize ulimit"

# Only the proxy touches the egress network (B12).
for c in keeper agent export sidecar gitrelay; do
  "topo_$c"
  value_of --network | grep -q -- '-egress' && fail "$c: attached to the egress network"
done
topo_proxy
value_of --network | grep -q -- '-egress$' || fail "proxy: not on the egress network"
value_of --volume | grep -q ':ro,z$' || fail "proxy: allowlist mount is not read-only"

# Keeper and export helper have no network at all.
for c in keeper export; do
  "topo_$c"
  has_pair --network none || fail "$c: must have no network"
  value_of --mount | grep -q ',ro$' || fail "$c: workspace must be mounted read-only"
done

# A service image's own VOLUME lines must not become volumes on disk (B08, B09).
topo_service postgres 10.201.7.20
has --image-volume=ignore || fail "service: image-declared volumes are not ignored"

# Networks and volume.
topo_network_sandbox
has --internal || fail "sandbox network: not internal"
has --disable-dns || fail "sandbox network: name service not disabled"
topo_network_egress
has --internal && fail "egress network: must not be internal"
topo_volume_workspace
value_of --opt | grep -q '^o=size=4g,nosuid,nodev' || fail "workspace volume: not capped / nosuid / nodev"
SANDBOX_WORKSPACE_DRIVER=bogus
if topo_volume_workspace 2>/dev/null; then fail "workspace volume: unknown driver accepted"; fi
export SANDBOX_WORKSPACE_DRIVER=local SANDBOX_STORE=/srv/store
topo_volume_workspace
has_pair --opt 'o=bind,nosuid,nodev' || fail "disk workspace: not nosuid,nodev"

# Every object carries the session label, so destroy can find it.
for f in topo_network_sandbox topo_network_egress topo_volume_workspace topo_keeper topo_agent topo_proxy topo_sidecar topo_gitrelay topo_export; do
  "$f"
  has_pair --label agent-sandbox.session=asb-test-0a1b2c || fail "$f: no session label"
done

# A missing required variable must stop the build of the argument list.
if (unset SANDBOX_BUDGET; topo_sidecar) 2>/dev/null; then
  fail "topo_sidecar: built without SANDBOX_BUDGET"
fi

if [ "$fails" -gt 0 ]; then
  printf '%s topology check(s) failed\n' "$fails"
  exit 1
fi
echo "topology: all static checks passed"
