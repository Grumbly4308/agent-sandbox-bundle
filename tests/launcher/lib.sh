# shellcheck shell=bash
# Shared set-up for the launcher tests. Each test sources this file; run by
# itself it does nothing.
#
# Nothing here needs a container runtime. tests/fakes/podman stands in for
# Podman, and the parts of agent-sandbox that other files provide (the
# allowlist functions, export.sh, verify.sh, an agent plug-in, a service) are
# small stand-ins written into a temporary copy of the repository, so these
# tests exercise ./sandbox and scripts/doctor.sh and nothing else.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAILS=0
T=""          # the test's temporary directory
ROOT=""       # the temporary copy of the repository ./sandbox runs from

fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
pass() { printf 'ok   %s\n' "$*"; }

# check <description> <command...>: the command must succeed. It runs in a
# subshell, because the launcher's functions exit when they refuse something.
check() {
  local what="$1"
  shift
  if ( "$@" ) >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}

# refuse <description> <command...>: the command must fail.
refuse() {
  local what="$1"
  shift
  if ( "$@" ) >/dev/null 2>&1; then fail "$what (it succeeded)"; else pass "$what"; fi
}

# says <description> <text> <command...>: the command's output (both streams)
# must contain the text.
says() {
  local what="$1" text="$2" out
  shift 2
  out="$( ("$@") 2>&1 || true)"
  case "$out" in
    *"$text"*) pass "$what" ;;
    *) fail "$what: expected '$text' in: $out" ;;
  esac
}

# The line number of the first recorded podman call matching a pattern
# (grep -E against the tab-separated line); empty when there is none.
call_line() {
  grep -nE -- "$1" "$FAKE_PODMAN_LOG" | head -1 | cut -d: -f1 || true
}

# before <description> <pattern A> <pattern B>: A was called before B.
before() {
  local a b
  a="$(call_line "$2")"
  b="$(call_line "$3")"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
    pass "$1"
  else
    fail "$1 (lines: '${a:-none}' and '${b:-none}')"
  fi
}

finish() {
  if [ "$FAILS" -ne 0 ]; then
    printf '%s: %s check(s) failed\n' "${0##*/}" "$FAILS"
    exit 1
  fi
  printf '%s: all checks passed\n' "${0##*/}"
}

cleanup() {
  local pid
  # A test that started a watchdog must not leave it behind.
  for pid in "$T"/state/*/watchdog.pid; do
    [ -f "$pid" ] || continue
    kill "$(cat "$pid")" 2>/dev/null || true
  done
  rm -rf "$T"
}

# setup: a temporary directory, the fake podman first on PATH, and an
# environment in which ./sandbox sees none of your own settings.
setup() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-test.XXXXXX")"
  trap cleanup EXIT
  ROOT="$T/root"
  mkdir -p "$T/bin" "$T/home" "$T/config" "$T/state"
  export PATH="$T/bin:$REPO/tests/fakes:$PATH"
  export FAKE_PODMAN_LOG="$T/podman.log"
  export FAKE_PODMAN_STATE="$T/podman.state"
  : > "$FAKE_PODMAN_LOG"
  export SANDBOX_STATE_DIR="$T/state" SANDBOX_CONFIG_DIR="$T/config"
  export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  unset XDG_RUNTIME_DIR XDG_CONFIG_HOME CONTAINER_HOST CONTAINER_CONNECTION SANDBOX_SESSION
  unset SANDBOX_ROOT SANDBOX_VERSION SANDBOX_TEST_ANTHROPIC_KEY ANTHROPIC_API_KEY
  git config --global user.name "Test Operator"
  git config --global user.email "operator@example.test"
  git config --global init.defaultBranch main
  # Small sizes, so the memory check passes on any machine that runs this.
  printf '%s\n' AGENT=claude AUTH=apikey TOOLCHAIN=node MEM=64m CPUS=1 PIDS=128 NPROC=128 \
    TTL=1h BUDGET=50 TMP_SIZE=16m HOME_SIZE=16m WORKSPACE_SIZE=32m WORKSPACE_DRIVER=memory \
    STORE= STORE_DEVICE= "OUT_DIR=$T/out" > "$T/config/settings"
}

# make_root: a copy of the files under test plus stand-ins for everything
# they call.
make_root() {
  mkdir -p "$ROOT/scripts" "$ROOT/agents/claude" "$ROOT/agents/codex" "$ROOT/seccomp" \
           "$ROOT/images" "$ROOT/services/redis" "$ROOT/services/unpinned"
  cp "$REPO/sandbox" "$REPO/topology.sh" "$REPO/VERSION" "$ROOT/"
  cp "$REPO/scripts/doctor.sh" "$ROOT/scripts/"
  printf '{}\n' > "$ROOT/seccomp/agent-seccomp.json"
  printf '%s\n' '# stand-in' \
    'NODE_BASE=docker.io/library/node:22-bookworm-slim@sha256:1111' \
    'ALPINE_BASE=docker.io/library/alpine:3.20@sha256:2222' > "$ROOT/images/PINS"
  printf '%s\n' '# stand-in' 'ANTHROPIC_BASE_URL=http://sidecar:8080' > "$ROOT/agents/claude/env"
  printf '%s\n' 'CODEX_HOME=/home/agent/.codex' > "$ROOT/agents/codex/env"
  printf '%s\n' '# stand-in' 'IMAGE=docker.io/library/redis:7-alpine@sha256:3333' 'VERSIONS=7' \
    'USER=999:1000' 'COMMAND_ARG=redis-server' 'COMMAND_ARG=--save' 'COMMAND_ARG=' \
    'ENV=EXAMPLE=1' 'TMPFS=/data:size=8m,mode=1777,nosuid,nodev,noexec' \
    'MEMORY=32m' 'PIDS=32' 'PORT=6379' 'URL_VAR=REDIS_URL' \
    'URL_TEMPLATE=redis://{host}:6379/0' 'HEALTH=redis-cli -h 127.0.0.1 ping' \
    > "$ROOT/services/redis/service.conf"
  printf '%s\n' 'IMAGE=UNPINNED' 'VERSIONS=1' 'USER=1:1' 'MEMORY=32m' 'PIDS=8' \
    > "$ROOT/services/unpinned/service.conf"

  # scripts/allowlist.sh: the six functions of the contract, in miniature.
  cat > "$ROOT/scripts/allowlist.sh" <<'STANDIN'
# shellcheck shell=bash
allowlist_valid_host() {
  case "$1" in
    *[!a-z0-9.-]*|'') echo "allowlist: '$1' is not a host name" >&2; return 1 ;;
    *.*) return 0 ;;
  esac
  echo "allowlist: '$1' is not a host name" >&2
  return 1
}
allowlist_never_allow_hit() {
  case "$1" in *pastebin.com) echo "pastebin.com — anyone can post there"; return 0 ;; esac
  return 1
}
allowlist_upload_capable() { [ "$1" = github.com ]; }
allowlist_add() {
  local host="$2"
  case "$1" in
    hostport) host="${2%:*}" ;;
    url) host="${2#*://}"; host="${host%%/*}" ;;
    preset) host="" ;;
  esac
  if [ -n "$host" ]; then
    allowlist_valid_host "$host" || return 1
    if allowlist_never_allow_hit "$host" >/dev/null; then
      echo "allowlist: $host is on the never-allow list" >&2
      return 1
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$SANDBOX_CONFIG_DIR/allowlist.local"
}
allowlist_remove() {
  local file="$SANDBOX_CONFIG_DIR/allowlist.local"
  grep -q "	$1	" "$file" 2>/dev/null || { echo "allowlist: $1 is not in $file" >&2; return 1; }
  grep -v "	$1	" "$file" > "$file.tmp" || true
  mv "$file.tmp" "$file"
}
allowlist_render() {
  local dir="$1/proxy" kind value rest
  mkdir -p "$dir"
  printf 'RENDER\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$SANDBOX_CONFIG_DIR/render.calls"
  echo registry.npmjs.org > "$dir/agent.domains"
  echo api.anthropic.com > "$dir/sidecar.domains"
  printf '%s' "${3:+$3
}" > "$dir/relay.domains"
  : > "$dir/extra.conf"
  [ -f "$SANDBOX_CONFIG_DIR/allowlist.local" ] || return 0
  while IFS='	' read -r kind value rest; do
    case "$kind:$value" in
      host:*) echo "$value" >> "$dir/agent.domains" ;;
      url:http://*) echo "acl extra_1_url url_regex ^$value" >> "$dir/extra.conf" ;;
    esac
  done < "$SANDBOX_CONFIG_DIR/allowlist.local"
}
STANDIN

  # scripts/verify.sh: notes how it was called.
  cat > "$ROOT/scripts/verify.sh" <<'STANDIN'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX_CONFIG_DIR/verify.calls"
printf 'PASS B01 stand-in \033[31mcheck\033[0m\n'
exit "${FAKE_VERIFY_EXIT:-0}"
STANDIN

  # scripts/export.sh: fetches the bundle into a bare repository and writes
  # the status file, as the contract describes; reviews nothing.
  cat > "$ROOT/scripts/export.sh" <<'STANDIN'
#!/usr/bin/env bash
set -euo pipefail
bundle="$1" out="$2/$3" base="$4" branch="$5" origin="${6:-}"
printf '%s\n' "$*" >> "$SANDBOX_CONFIG_DIR/export.calls"
mkdir -p "$out"
rm -rf "$out/repo.git"
git init --quiet --bare "$out/repo.git"
git --git-dir="$out/repo.git" fetch --quiet "$bundle" "refs/heads/$branch:refs/heads/$branch"
tip="$(git --git-dir="$out/repo.git" rev-parse "refs/heads/$branch")"
printf '%s\n' "SCAN=${FAKE_EXPORT_SCAN:-passed}" "ATTRIBUTION=clean" "TIP=$tip" "BRANCH=$branch" \
  "ORIGIN_URL=$origin" "HISTORY=${FAKE_EXPORT_HISTORY:-intact}" > "$out/export.status"
printf 'code diff from %s \033]0;owned\007title\n' "${base:0:7}"
exit "${FAKE_EXPORT_EXIT:-0}"
STANDIN
  chmod +x "$ROOT/scripts/verify.sh" "$ROOT/scripts/export.sh"
}

# make_repo <dir>: a small git repository with one commit on main.
make_repo() {
  git init --quiet "$1"
  printf 'hello\n' > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit --quiet -m "first commit"
}

# The one session in the state directory.
only_session() {
  local dir
  for dir in "$SANDBOX_STATE_DIR"/asb-*; do
    if [ -d "$dir" ]; then printf '%s' "${dir##*/}"; fi
  done
}
