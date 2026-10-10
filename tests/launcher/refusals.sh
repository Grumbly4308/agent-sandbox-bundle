#!/usr/bin/env bash
# Everything `./sandbox run` must refuse, and that a refusal or a failure
# half-way leaves nothing behind.  [logical B29, B31]
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup
make_root
make_repo "$T/src"
export SANDBOX_TEST_ANTHROPIC_KEY="sk-ant-test-0123456789"

run() { "$ROOT/sandbox" run "$T/src" "$@" </dev/null; }

# refused <description> <text the refusal must contain> <command...>
# The command must fail, say why, create nothing in Podman and leave no
# session behind.
refused() {
  local what="$1" text="$2" out status=0
  shift 2
  : > "$FAKE_PODMAN_LOG"
  out="$("$@" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    fail "$what: it was not refused"
  elif [[ "$out" != *"$text"* ]]; then
    fail "$what: refused, but without '$text': $out"
  elif grep -qE '^(create|network	create|volume	create|start)' "$FAKE_PODMAN_LOG"; then
    fail "$what: refused, but only after creating something"
  elif [ -n "$(only_session)" ]; then
    fail "$what: refused, but a session directory was left"
  else
    pass "$what"
  fi
}

# nothing_left <description>: no session directory, and nothing in the fake
# Podman's books.
nothing_left() {
  local left
  left="$(find "$SANDBOX_STATE_DIR" -mindepth 1 | head -5; find "$FAKE_PODMAN_STATE/containers" "$FAKE_PODMAN_STATE/networks" "$FAKE_PODMAN_STATE/volumes" -type f | head -5)"
  if [ -z "$left" ]; then pass "$1"; else fail "$1: left behind: $left"; fi
}

# --- root  [closes M3] ---------------------------------------------------------
# A stand-in `id` that claims to be root; everything else goes to the real one.
real_id="$(command -v id)"
# shellcheck disable=SC2016  # the stand-in's own $1 and $@, not this script's
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo 0; else exec %s "$@"; fi\n' "$real_id" > "$T/bin/id"
chmod +x "$T/bin/id"
refused "run refuses as root" "refusing to run as root" run
refused "there is no flag that lets root through" "refusing to run as root" run --accept-rootful
refused "shell refuses as root" "refusing to run as root" "$ROOT/sandbox" shell
refused "destroy refuses as root" "refusing to run as root" "$ROOT/sandbox" destroy --all
if [ -s "$FAKE_PODMAN_LOG" ]; then fail "podman was called as root"; else pass "podman is never called as root"; fi
says   "doctor reports root in red" "running as root" "$ROOT/sandbox" doctor
refuse "doctor exits non-zero as root" "$ROOT/sandbox" doctor
rm -f "$T/bin/id"

# --- Podman that is not rootless and local --------------------------------------
FAKE_PODMAN_ROOTLESS=false refused "run refuses a root-run Podman" "running as root (rootful)" run
FAKE_PODMAN_REMOTE=true    refused "run refuses a remote Podman" "remote client" run
CONTAINER_HOST=ssh://elsewhere/run/podman.sock refused "run refuses CONTAINER_HOST" "pointed at another machine" run
CONTAINER_CONNECTION=prod refused "run refuses CONTAINER_CONNECTION" "pointed at another machine" run
FAKE_PODMAN_ROOTLESS=false refused "destroy refuses a root-run Podman too" "rootful" "$ROOT/sandbox" destroy --all
FAKE_PODMAN_VERSION=4.3.1  refused "run refuses Podman older than 4.4" "too old" run
FAKE_PODMAN_BACKEND=cni    refused "run refuses the CNI network backend" "netavark" run

# --- a kernel that cannot enforce the limits  [physical B10] ---------------------
FAKE_PODMAN_CGROUPS=v1 refused "run refuses cgroup v1" "cgroup v1" run
FAKE_PODMAN_CGROUPS=v1 says "cgroup v1: the fix is printed" "systemd.unified_cgroup_hierarchy=1" run
FAKE_PODMAN_CONTROLLERS="memory pids" refused "run refuses when cpu is not delegated" "may not set limits for: cpu" run
FAKE_PODMAN_CONTROLLERS="cpu pids"    refused "run refuses when memory is not delegated" "may not set limits for: memory" run
FAKE_PODMAN_CONTROLLERS="cpu memory"  refused "run refuses when pids is not delegated" "may not set limits for: pids" run
FAKE_PODMAN_CONTROLLERS="" says "undelegated controllers: the fix is printed" "Delegate=cpu cpuset io memory pids" run
FAKE_PODMAN_IDMAP="0:1 " refused "run refuses when the id range does not reach the container users" "does not reach 61003" run

# --- memory  [physical B10] ------------------------------------------------------
refused "run refuses when the session needs more memory than the host has" "this host has" run --mem 900000g
says    "the refusal prints the session's total" "may use up to 900000." run --mem 900000g

# --- options that no longer exist ------------------------------------------------
refused "--keep is rejected, with the reason" "--keep no longer exists" run --keep
refused "--accept-rootful is rejected, with the reason" "--accept-rootful no longer exists" run --accept-rootful

# --- values --------------------------------------------------------------------
refused "a size without a unit" "is not a size" run --mem 4096
refused "a size with an unknown unit" "is not a size" run --workspace-size 4t
refused "a duration with an unknown unit" "is not a duration" run --ttl 4w
refused "zero cpus" "not a number above zero" run --cpus 0
refused "a zero process limit" "not a whole number above zero" run --pids 0
refused "a zero budget" "not a whole number above zero" run --budget 0
refused "--flag=value spelling" "unknown option" run --mem=4g
refused "an option missing its value" "needs a value" run --mem
refused "an unknown agent" "there is no agents/nosuch" run --agent nosuch
refused "an agent name that is a path" "there is no agents/" run --agent ../scripts
refused "an unknown toolchain" "--toolchain is node, python or full" run --toolchain rust
refused "an unknown credential mode" "--auth is oauth or apikey" run --auth password
printf '{\n  "modes": {\n    "apikey": {\n      "routes": []\n    }\n  }\n}\n' > "$ROOT/agents/claude/sidecar.json"
refused "a credential mode the agent's plug-in does not offer" "claude does not take --auth oauth" run --auth oauth
check   "a mode it does offer is accepted" "$ROOT/sandbox" run "$T/src" --auth apikey
"$ROOT/sandbox" destroy >/dev/null 2>&1
rm "$ROOT/agents/claude/sidecar.json" "$T/config/verified"
refused "an invalid branch name" "is not a branch name" run --branch 'a..b'
refused "a branch name git takes but export would refuse" "is not a branch name" run --branch 'fix+x'
refused "two repositories" "takes one repository" run "$T/src"
refused "no repository" "usage: ./sandbox run" "$ROOT/sandbox" run
refused "a directory that is not a repository" "is not a git repository" "$ROOT/sandbox" run "$T/home"
refused "a repository address with a password in it" "user name or token in it" "$ROOT/sandbox" run "https://me:hunter2@git.example.test/x.git"
refused "a repository address with a token as its user name" "user name or token in it" "$ROOT/sandbox" run "https://ghp_0123456789abcdefABCDEF@git.example.test/x.git"

# --- workspace on disk  [physical B08] --------------------------------------------
refused "the local driver without a store" "needs a disk store" run --workspace-driver local
mkdir "$T/store"
printf 'STORE=%s\n' "$T/store" >> "$T/config/settings"
refused "the local driver with a store that is an ordinary directory" "not a filesystem of its own" run --workspace-driver local
refused "the same store, used because it is set and nothing else was asked for" "not a filesystem of its own" run
printf 'STORE=\n' >> "$T/config/settings"      # the last line wins: no store from here on
refused "--io-limit with the memory-backed workspace" "memory-backed workspace has none" run --io-limit 10m
refused "an unknown workspace driver" "--workspace-driver is memory or local" run --workspace-driver nfs

# --- services --------------------------------------------------------------------
refused "an unknown service" "no services/mysql/service.conf" run --service mysql:8
refused "a service version that is not offered" "offered in version 7, not 6" run --service redis:6
refused "a service whose image is not pinned" "not pinned by digest" run --service unpinned:1
refused "a service name that is a path" "is not name:version" run --service ../x:1

# --- files the session needs -------------------------------------------------------
mv "$ROOT/seccomp/agent-seccomp.json" "$T/seccomp.aside"
refused "a missing seccomp profile" "agent-seccomp.json is missing" run
mv "$T/seccomp.aside" "$ROOT/seccomp/agent-seccomp.json"
printf 'ANTHROPIC_API_KEY\n' >> "$ROOT/agents/claude/env"
refused "an env file that would copy a host variable in" "is not NAME=value" run
printf 'DISABLE_AUTOUPDATER=1\n' > "$ROOT/agents/claude/env"

# --- credentials  [physical B15] ---------------------------------------------------
unset SANDBOX_TEST_ANTHROPIC_KEY
refused "no stored credential and no terminal: points at login" "./sandbox login --agent claude --auth apikey" run
ANTHROPIC_API_KEY=sk-ant-from-the-shell refused "ANTHROPIC_API_KEY in the environment is not used" "./sandbox login" run
SANDBOX_TEST_ANTHROPIC_KEY='bad"token' refused "a credential that is not a token" "does not look like a token" run
SANDBOX_TEST_ANTHROPIC_KEY='user:0123456789abcdef' refused "a credential the sidecar would refuse (a colon)" "does not look like a token" run
SANDBOX_TEST_ANTHROPIC_KEY='short' refused "a credential the sidecar would refuse (too short)" "does not look like a token" run
export SANDBOX_TEST_ANTHROPIC_KEY="sk-ant-test-0123456789"

# --- failures half-way leave nothing behind  [logical B31, closes L1] --------------
: > "$FAKE_PODMAN_LOG"
sed 's/^NODE_BASE=.*/NODE_BASE=UNPINNED/' "$ROOT/images/PINS" > "$T/pins" && cp "$T/pins" "$ROOT/images/PINS"
says "an unpinned base image stops the build" "NODE_BASE is still UNPINNED" env FAKE_PODMAN_IMAGES=absent "$ROOT/sandbox" run "$T/src"
if grep -q '^build' "$FAKE_PODMAN_LOG"; then fail "something was built from an unpinned base"; else pass "nothing is built from an unpinned base"; fi
nothing_left "after a refused build"
printf 'NODE_BASE=docker.io/library/node:22@sha256:1111\nALPINE_BASE=docker.io/library/alpine:3.20@sha256:2222\n' > "$ROOT/images/PINS"

refuse "run fails when a container does not start" env FAKE_PODMAN_FAIL=start "$ROOT/sandbox" run "$T/src"
nothing_left "after a container failed to start"

refuse "run fails when the sidecar rejects the credential" env FAKE_PODMAN_FAIL=exec:sidecar-load "$ROOT/sandbox" run "$T/src"
nothing_left "after the sidecar rejected the credential"

says "a failed barrier check stops the session" "a barrier check failed" env FAKE_VERIFY_EXIT=1 "$ROOT/sandbox" run "$T/src"
nothing_left "after a failed barrier check"
if [ -e "$T/config/verified" ]; then fail "a failed check was recorded as passed"; else pass "a failed check is not recorded as passed"; fi
if grep -q 'sandbox-launch' "$FAKE_PODMAN_LOG"; then fail "the agent was started after a failed check"; else pass "the agent is not started after a failed check"; fi

if ls "$T"/agent-sandbox-import.* >/dev/null 2>&1 || ls "${TMPDIR:-/tmp}"/agent-sandbox-import.* >/dev/null 2>&1; then
  fail "a temporary clone was left behind"
else
  pass "no temporary clone is left behind"
fi


# --- a state directory that is not yours -----------------------------------------
# In a shared /tmp another user can make the directory first, or put a link
# there. Every command must notice before it reads or changes anything in it.
mkdir "$T/elsewhere"
ln -s "$T/elsewhere" "$T/state-link"
out="$(SANDBOX_STATE_DIR="$T/state-link" "$ROOT/sandbox" allow docs.example.com --reason "test" 2>&1)" && fail "a linked state directory was accepted"
case "$out" in *"not a directory of yours"*) pass "a state directory that is a link is refused, for every command" ;; *) fail "linked state directory: $out" ;; esac
check "and the place it points to was not touched" test "$(stat -c %a "$T/elsewhere" 2>/dev/null || stat -f %Lp "$T/elsewhere")" != 700

# A bare repository that was pushed to, with HEAD still where `git init` left
# it: the branches are named and so is the fix, instead of "no commits yet".
git init --quiet --bare --initial-branch=master "$T/pushed.git"
git -C "$T/src" push --quiet "$T/pushed.git" main
says "a repository whose HEAD points at no commit names its branches" "it has branches: main." "$ROOT/sandbox" run "$T/pushed.git" </dev/null
says "... and the fix" "symbolic-ref HEAD refs/heads/<branch>" "$ROOT/sandbox" run "$T/pushed.git" </dev/null
git init --quiet --bare "$T/empty.git"
says "a repository with no commits says so" "has no commits yet" "$ROOT/sandbox" run "$T/empty.git" </dev/null

finish
