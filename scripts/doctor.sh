#!/usr/bin/env bash
# doctor.sh — is this host safe to run a sandbox on?  [logical B29]
#
# Every barrier in docs/00-threat-model.md assumes an ordinary account driving
# rootless Podman on a kernel that can enforce the limits. This script checks
# that, and ./sandbox refuses to go on when it fails. It prints one line per
# check — ok, warn or FAIL — with a one-line fix under every FAIL, and exits 1
# if anything failed.
#
#   scripts/doctor.sh                  every check
#   scripts/doctor.sh --runtime-only   what any command that calls Podman needs:
#                                      not root, Podman present, local, rootless
#   scripts/doctor.sh --preflight      what `./sandbox run` cannot go on without
#
# The last two print only the failures. ./sandbox passes these as needed:
#   --memory BYTES       what the session being started may take from the host
#   --store DIR          the disk store, when workspaces are kept on it
#   --store-device DEV   that store's block device, for `--io-limit`
#   --io                 the session uses `--io-limit`
#
# Host-side code: it must also run under macOS's bash 3.2.
set -euo pipefail

SANDBOX_ROOT="${SANDBOX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -z "${SANDBOX_STATE_DIR:-}" ]; then
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    SANDBOX_STATE_DIR="$XDG_RUNTIME_DIR/agent-sandbox"
  else
    SANDBOX_STATE_DIR="${TMPDIR:-/tmp}/agent-sandbox-$(id -u)"
  fi
fi

MODE=full          # full | runtime | preflight
NEED_MEMORY=""
NEED_IO=""
STORE=""
STORE_DEVICE=""
FAILED=0
PODMAN_USABLE=0    # set once Podman has answered; later checks ask it questions

GREEN="" YELLOW="" RED="" RESET=""
if [ -t 1 ]; then
  GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' RESET=$'\033[0m'
fi

ok() {
  [ "$MODE" = full ] || return 0
  printf '  %sok%s    %s\n' "$GREEN" "$RESET" "$1"
}

warn() {
  [ "$MODE" = full ] || return 0
  printf '  %swarn%s  %s\n' "$YELLOW" "$RESET" "$1"
}

# bad <what is wrong> <the fix>
bad() {
  FAILED=1
  if [ "$MODE" = full ]; then
    printf '  %sFAIL%s  %s\n        fix: %s\n' "$RED" "$RESET" "$1" "$2"
  else
    printf 'refused: %s\n    fix: %s\n' "$1" "$2" >&2
  fi
}

human_bytes() {
  local tenths=$(( $1 * 10 / 1073741824 ))
  printf '%s.%s GB' "$(( tenths / 10 ))" "$(( tenths % 10 ))"
}

# ---------------------------------------------------------------------------
# The account.  [closes M3: this used to be a warning]
# If a kernel bug lets the agent out of its container, it lands in the account
# that started it. Root is refused, with no override.
# ---------------------------------------------------------------------------
check_account() {
  if [ "$(id -u)" -eq 0 ]; then
    bad "running as root" \
        "use an ordinary account without sudo; there is no override, because an escape would land as root"
    return 0
  fi
  ok "not root ($(id -un))"
  [ "$MODE" = full ] || return 0
  # Not a refusal, but worth knowing: cloud images give their default user
  # (ubuntu, ec2-user, azureuser) sudo without a password.
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    warn "this account can run sudo without a password: an escape would be one command from root. Use a dedicated account with no sudo"
  elif id -nG 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin'; then
    warn "this account is in a sudo group, so it can become root. A dedicated account with no sudo is safer"
  else
    ok "this account cannot become root with sudo"
  fi
}

# version_at_least <version> <major> <minor>
version_at_least() {
  local major minor _
  IFS=. read -r major minor _ <<<"$1"
  major="${major%%[!0-9]*}"
  minor="${minor%%[!0-9]*}"
  [ -n "$major" ] || return 1
  [ "$major" -gt "$2" ] || { [ "$major" -eq "$2" ] && [ "${minor:-0}" -ge "$3" ]; }
}

# ---------------------------------------------------------------------------
# Podman: present, on this machine, and not run by root.
# ---------------------------------------------------------------------------
check_podman() {
  local facts rootless remote version backend uri
  if ! command -v podman >/dev/null 2>&1; then
    bad "podman is not installed" \
        "install Podman 4.4 or newer from your distribution (apt install podman, dnf install podman)"
    return 0
  fi
  # These variables send every podman command to another machine's Podman.
  if [ -n "${CONTAINER_HOST:-}" ] || [ -n "${CONTAINER_CONNECTION:-}" ]; then
    bad "Podman is pointed at another machine (CONTAINER_HOST or CONTAINER_CONNECTION is set)" \
        "unset CONTAINER_HOST CONTAINER_CONNECTION"
    return 0
  fi
  if ! facts="$(podman info --format '{{.Host.Security.Rootless}} {{.Host.ServiceIsRemote}} {{.Version.Version}} {{.Host.NetworkBackend}}' 2>/dev/null)"; then
    bad "podman info failed" "run 'podman info' and fix what it reports"
    return 0
  fi
  read -r rootless remote version backend <<<"$facts"

  if [ "$rootless" != true ]; then
    bad "Podman is running as root (rootful)" \
        "run ./sandbox as an ordinary user, without sudo; rootless Podman needs no root service"
    return 0
  fi
  if [ "$remote" != false ]; then
    # On macOS Podman always runs in a small Linux VM on the same machine and
    # is driven over a local connection. That one case is let through; any
    # other remote Podman is refused. UNPROVEN until Phase B.
    uri=""
    if [ "$(uname -s)" = Darwin ]; then
      uri="$(podman system connection list --format '{{if .Default}}{{.URI}}{{end}}' 2>/dev/null || true)"
    fi
    case "$uri" in
      ssh://*@127.0.0.1:*|ssh://*@localhost:*|unix://*) ;;
      *)
        bad "Podman is a remote client: the containers would run on another machine" \
            "use the Podman installed on this machine (remove 'remote = true' from containers.conf and any default connection)"
        return 0
        ;;
    esac
  fi
  ok "Podman $version, rootless, on this machine"
  PODMAN_USABLE=1

  [ "$MODE" != runtime ] || return 0
  if version_at_least "$version" 4 4; then
    ok "Podman is 4.4 or newer"
  else
    bad "Podman $version is too old (4.4 or newer is needed)" "upgrade Podman from your distribution"
  fi
  # netavark is the network backend that gives an internal network with its
  # name service off no gateway address at all [physical B13].
  if [ "$backend" = netavark ]; then
    ok "network backend is netavark"
  else
    bad "Podman uses the '$backend' network backend, not netavark" \
        "install netavark and run 'podman system reset' (this deletes existing containers and images), or upgrade Podman"
  fi
}

# ---------------------------------------------------------------------------
# cgroup v2 with cpu, memory and pids handed to your user.  [physical B10]
# Without them the limits in topology.sh are ignored or the containers do not
# start. Podman's own report is used: it reads the controllers of the cgroup
# this very process is in.
# ---------------------------------------------------------------------------
check_cgroups() {
  local version controllers name missing=""
  version="$(podman info --format '{{.Host.CgroupsVersion}}' 2>/dev/null || true)"
  if [ "$version" != v2 ]; then
    bad "this host uses cgroup ${version:-v1}: memory, CPU and process limits would not be enforced" \
        "boot with cgroup v2 (kernel parameter systemd.unified_cgroup_hierarchy=1), or use a current distribution"
    return 0
  fi
  controllers=" $(podman info --format '{{.Host.CgroupControllers}}' 2>/dev/null | tr -d '[]') "
  for name in cpu memory pids ${NEED_IO:+io}; do
    case "$controllers" in
      *" $name "*) ;;
      *) missing="$missing $name" ;;
    esac
  done
  if [ -n "$missing" ]; then
    bad "cgroup v2, but your user may not set limits for:$missing" \
        "sudo mkdir -p /etc/systemd/system/user@.service.d && printf '[Service]\\nDelegate=cpu cpuset io memory pids\\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf && sudo systemctl daemon-reload; then log out and back in"
  else
    ok "cgroup v2 with cpu, memory and pids${NEED_IO:+ and io} delegated"
  fi
}

# ---------------------------------------------------------------------------
# Subordinate ids. The containers run as users 61000 to 61003; your account
# needs a range of spare ids (/etc/subuid, /etc/subgid) wide enough to give
# each of them one.  [physical B01]
# ---------------------------------------------------------------------------
check_id_range() {
  local kind map entry start size covered user
  user="$(id -un)"
  for kind in UID GID; do
    map="$(podman info --format "{{range .Host.IDMappings.${kind}Map}}{{.ContainerID}}:{{.Size}} {{end}}" 2>/dev/null || true)"
    covered=0
    for entry in $map; do
      start="${entry%%:*}"
      size="${entry##*:}"
      case "$start$size" in ''|*[!0-9]*) continue ;; esac
      if [ "$start" -le 61003 ] && [ $(( start + size )) -gt 61003 ]; then covered=1; fi
    done
    if [ "$covered" -eq 1 ]; then
      ok "subordinate ${kind}s cover the container users (61000-61003)"
    else
      bad "your subordinate ${kind} range does not reach 61003" \
          "sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $user && podman system migrate"
    fi
  done
}

# ---------------------------------------------------------------------------
# Files and tools the launcher needs on the host.
# ---------------------------------------------------------------------------
check_files_and_tools() {
  # The agent's system-call filter [physical B04]. topology.sh names it for
  # every agent container; without the file nothing starts.
  if [ -s "$SANDBOX_ROOT/seccomp/agent-seccomp.json" ]; then
    ok "seccomp/agent-seccomp.json is present"
  else
    bad "seccomp/agent-seccomp.json is missing" "run scripts/make-seccomp.sh (or restore the file from git)"
  fi
  if command -v git >/dev/null 2>&1; then
    ok "git is installed"
  else
    bad "git is not installed" "install git from your distribution"
  fi
  [ "$MODE" = full ] || return 0

  # Base images are pinned by digest [closes M2]. The digests are filled in on
  # a real host; an image build refuses until they are.
  if [ ! -f "$SANDBOX_ROOT/images/PINS" ]; then
    bad "images/PINS is missing" "restore it from git"
  elif grep -Eq '^[A-Z0-9_]+=UNPINNED' "$SANDBOX_ROOT/images/PINS"; then
    bad "images/PINS still has UNPINNED base images" "run scripts/pin-images.sh once, read the digests it wrote, then build"
  else
    ok "base images are pinned by digest"
  fi
  # export scans the agent's commits for secrets with gitleaks.
  if command -v gitleaks >/dev/null 2>&1; then
    # export tells it to ignore gitleaks:allow comments and .gitleaksignore
    # files, which it can only do from 8.18; an older one is not run at all.
    gitleaks_version=$(gitleaks version 2>/dev/null | awk 'NR == 1 { print $NF }') || gitleaks_version=""
    gitleaks_version=${gitleaks_version#v}
    case "$gitleaks_version" in *[!0-9.]*) gitleaks_version="" ;; esac   # Debian's build prints a sentence, not a number
    gitleaks_major=${gitleaks_version%%.*}
    gitleaks_rest=${gitleaks_version#*.}
    gitleaks_minor=${gitleaks_rest%%.*}
    case "$gitleaks_major.$gitleaks_minor" in
      *[!0-9.]* | .* | *.)
        gitleaks_help=$(gitleaks detect --help 2>&1) || true
        if [[ "$gitleaks_help" == *--ignore-gitleaks-allow* && "$gitleaks_help" == *--gitleaks-ignore-path* ]]; then gitleaks_ok=1; else gitleaks_ok=0; fi
        ;;
      *)
        if [ "$gitleaks_major" -gt 8 ] || { [ "$gitleaks_major" -eq 8 ] && [ "$gitleaks_minor" -ge 18 ]; }; then gitleaks_ok=1; else gitleaks_ok=0; fi
        ;;
    esac
    if [ "$gitleaks_ok" -eq 1 ]; then
      ok "gitleaks is installed${gitleaks_version:+ ($gitleaks_version)}"
    else
      warn "gitleaks ${gitleaks_version:-(unknown version)} is too old: export needs 8.18 or newer to keep the tree from silencing the scan, so it will run no scan and push and pr will refuse. Install a newer one from github.com/gitleaks/gitleaks/releases"
    fi
  else
    warn "gitleaks is not installed: export cannot scan for secrets, so push and pr will refuse. Install it from your distribution or github.com/gitleaks/gitleaks"
  fi
  # The model credential rests in the OS keyring between sessions.
  if [ "$(uname -s)" = Darwin ]; then
    if command -v security >/dev/null 2>&1; then ok "keyring tool (security) is present"
    else warn "the 'security' tool is missing: ./sandbox will ask for the credential at every run"; fi
  elif command -v secret-tool >/dev/null 2>&1; then
    ok "keyring tool (secret-tool) is present"
  else
    warn "secret-tool is not installed: ./sandbox will ask for the credential at every run (apt install libsecret-tools, dnf install libsecret)"
  fi
  # Only a Codex subscription login needs it: that credential is a JSON file.
  command -v jq >/dev/null 2>&1 \
    || warn "jq is not installed: needed only for 'login --agent codex --auth oauth'"
}

# ---------------------------------------------------------------------------
# Crash handlers. Core dumps are off in every container, so no core file is
# written. But when the host pipes crashes to a handler, the kernel still
# starts that handler, as root, on the host, for every crash in a container.
# ---------------------------------------------------------------------------
check_core_pattern() {
  local pattern handler
  [ -r /proc/sys/kernel/core_pattern ] || return 0
  IFS= read -r pattern < /proc/sys/kernel/core_pattern || true
  case "$pattern" in
    '|'*)
      handler="${pattern#|}"
      handler="${handler%% *}"
      case "$handler" in
        *systemd-coredump*)
          ok "crashes go to systemd-coredump, which stops at once when core dumps are off" ;;
        *)
          warn "crashes are piped to $handler, which runs as root on this host for every crash in a container; it has not been checked. To switch it off: sudo sysctl kernel.core_pattern=core" ;;
      esac
      ;;
    *) ok "no crash handler is started on the host (core_pattern is a file name)" ;;
  esac
}

# ---------------------------------------------------------------------------
# What confines a container process besides the kernel's namespaces.
# [physical B05]
# ---------------------------------------------------------------------------
check_confinement() {
  if [ "$(podman info --format '{{.Host.Security.SELinuxEnabled}}' 2>/dev/null || true)" = true ]; then
    ok "SELinux is on: containers are confined as container_t"
  else
    warn "no SELinux on this host, and rootless Podman applies no AppArmor profile: barrier B05 is absent here"
  fi
}

# ---------------------------------------------------------------------------
# The disk store, where workspaces are kept.  [physical B08, logical B33]
# It must be a filesystem of its own, so that its size is the hard wall a
# session cannot write past, and yours, so that rootless Podman can use it.
# ---------------------------------------------------------------------------

# The commands that make a store at <path>: a file of fixed size with a
# filesystem in it, mounted at every boot, handed to you. They need an admin,
# once. 20G is the most all sessions together can then put on disk.
store_recipe() {   # <path>
  printf '%s' "sudo fallocate -l 20G /var/lib/agent-sandbox-store.img && sudo mkfs.ext4 -q -m 0 /var/lib/agent-sandbox-store.img && sudo mkdir -p '$1' && echo '/var/lib/agent-sandbox-store.img $1 ext4 loop,nosuid,nodev,nofail 0 0' | sudo tee -a /etc/fstab && sudo mount '$1' && sudo chown $(id -u):$(id -g) '$1'"
}

# No store: not a refusal, but the workspace is then held in memory and has
# to fit in what this host can spare.
note_no_store() {
  local path="${SANDBOX_STANDARD_STORE:-/var/lib/agent-sandbox-store}"
  if [ "$(uname -s)" = Darwin ]; then
    # On a Mac the containers run in Podman's own VM, and a store would have
    # to be made inside it. Not worked out yet.
    warn "on macOS each session's workspace is held in memory and counts against the memory of Podman's VM (podman machine)"
    return 0
  fi
  warn "no disk store is set up: each session's workspace is held in memory and counts against this host's memory"
  [ "$MODE" = full ] || return 0
  printf '        to keep workspaces on disk, as an admin: %s\n' "$(store_recipe "$path")"
  printf '        then: echo STORE=%s >> %s\n' "$path" "${SANDBOX_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-sandbox}/settings"
}

check_store() {
  local owner device parent_device make
  make="$(store_recipe "$STORE")"
  if [ "$(uname -s)" = Darwin ]; then
    bad "a disk store is set (STORE=$STORE), and on macOS there is no support for one yet" \
        "remove the STORE line from your settings file; workspaces are then held in memory"
    return 0
  fi
  if [ -L "$STORE" ]; then
    # A link would be judged by the place it sits in, not the place it leads to.
    bad "the disk store $STORE is a symbolic link" "set STORE to the real path of the store's mount point"
    return 0
  fi
  if [ ! -d "$STORE" ]; then
    bad "the disk store $STORE does not exist" "$make"
    return 0
  fi
  device="$(stat -c %d "$STORE" 2>/dev/null || stat -f %d "$STORE")"
  parent_device="$(stat -c %d "$STORE/.." 2>/dev/null || stat -f %d "$STORE/..")"
  owner="$(stat -c %u "$STORE" 2>/dev/null || stat -f %u "$STORE")"
  if [ "$device" = "$parent_device" ]; then
    bad "the disk store $STORE is an ordinary directory, not a filesystem of its own: a session could fill your disk" "$make"
  elif [ "$owner" != "$(id -u)" ]; then
    bad "the disk store $STORE belongs to uid $owner, not to you" "sudo chown $(id -u):$(id -g) '$STORE'"
  else
    ok "disk store $STORE is a separate filesystem that you own"
  fi
  if [ -n "$NEED_IO" ]; then
    if [ -b "$STORE_DEVICE" ]; then
      ok "store device $STORE_DEVICE is a block device"
    else
      bad "--io-limit needs the store's block device, and STORE_DEVICE='$STORE_DEVICE' is not one" \
          "set STORE_DEVICE in your settings file to the device shown by: findmnt -no SOURCE '$STORE'"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Memory. A session's limit covers its processes and its memory-backed files,
# so it can really take that much from the host.  [physical B10]
# ---------------------------------------------------------------------------
host_available_bytes() {
  local key value _
  if [ -r /proc/meminfo ]; then
    while read -r key value _; do
      if [ "$key" = MemAvailable: ]; then
        printf '%s' "$(( value * 1024 ))"
        return 0
      fi
    done < /proc/meminfo
  fi
  # No /proc (macOS): ask Podman about the machine it runs the containers on.
  podman info --format '{{.Host.MemFree}}' 2>/dev/null || printf '0'
}

check_memory() {
  local available
  available="$(host_available_bytes)"
  case "$available" in ''|*[!0-9]*) available=0 ;; esac
  if [ "$NEED_MEMORY" -gt "$available" ]; then
    bad "the session may use up to $(human_bytes "$NEED_MEMORY") of memory and this host has $(human_bytes "$available") available" \
        "lower --mem or --workspace-size, destroy sessions you no longer need, or use --workspace-driver local"
  else
    ok "memory: the session may use up to $(human_bytes "$NEED_MEMORY"); $(human_bytes "$available") is available"
  fi
}

# ---------------------------------------------------------------------------
# Sessions past their time limit still hold their workspace.  [logical B26]
# ---------------------------------------------------------------------------
check_sessions() {
  local dir key value deadline now found=0
  now="$(date +%s)"
  for dir in "$SANDBOX_STATE_DIR"/asb-*; do
    [ -f "$dir/state" ] || continue
    deadline=""
    while IFS='=' read -r key value; do
      [ "$key" = DEADLINE_EPOCH ] && deadline="$value"
    done < "$dir/state"
    case "$deadline" in ''|*[!0-9]*) continue ;; esac
    if [ "$now" -ge "$deadline" ]; then
      found=1
      warn "session ${dir##*/} is past its time limit and still holds its workspace: SANDBOX_SESSION=${dir##*/} ./sandbox export, then destroy"
    fi
  done
  [ "$found" -eq 1 ] || ok "no session is past its time limit"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --preflight)    MODE=preflight ;;
      --runtime-only) MODE=runtime ;;
      --io)           NEED_IO=1 ;;
      --memory|--store|--store-device)
        [ $# -ge 2 ] || { echo "doctor: $1 needs a value" >&2; exit 2; }
        case "$1" in
          --memory)       NEED_MEMORY="$2" ;;
          --store)        STORE="$2" ;;
          --store-device) STORE_DEVICE="$2" ;;
        esac
        shift
        ;;
      *) echo "doctor: unknown option $1" >&2; exit 2 ;;
    esac
    shift
  done
  case "$NEED_MEMORY" in *[!0-9]*) echo "doctor: --memory takes a number of bytes" >&2; exit 2 ;; esac

  check_account
  check_podman
  if [ "$MODE" != runtime ]; then
    if [ "$PODMAN_USABLE" -eq 1 ]; then
      check_cgroups
      check_id_range
      [ "$MODE" != full ] || check_confinement
    fi
    check_files_and_tools
    [ "$MODE" != full ] || check_core_pattern
    if [ -n "$STORE" ]; then check_store; else note_no_store; fi
    if [ -n "$NEED_MEMORY" ] && [ "$PODMAN_USABLE" -eq 1 ]; then check_memory; fi
    [ "$MODE" != full ] || check_sessions
  fi

  if [ "$FAILED" -ne 0 ]; then
    [ "$MODE" != full ] || printf '\nNot safe to run yet: fix the FAIL lines above.\n'
    exit 1
  fi
  [ "$MODE" != full ] || printf '\nThis host is ready.\n'
}

main "$@"
