#!/usr/bin/env bash
# scripts/doctor.sh: one line per check, a fix under every failure, exit 1 on
# any failure.  [logical B29]
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup
make_root
doctor() { "$ROOT/scripts/doctor.sh" "$@"; }

# --- a host that is ready -------------------------------------------------------
out="$(doctor 2>&1)" || fail "doctor failed on a good host: $out"
for text in "not root" "rootless, on this machine" "Podman is 4.4 or newer" "network backend is netavark" \
            "cgroup v2 with cpu, memory and pids delegated" "subordinate UIDs cover" "subordinate GIDs cover" \
            "seccomp/agent-seccomp.json is present" "git is installed" "base images are pinned by digest" \
            "no session is past its time limit" "This host is ready"; do
  case "$out" in *"$text"*) pass "doctor reports: $text" ;; *) fail "doctor does not report '$text'" ;; esac
done
case "$out" in *FAIL*) fail "a good host got a FAIL line: $out" ;; *) pass "a good host gets no FAIL line" ;; esac
# No store is not a refusal: workspaces are then held in memory, and doctor
# says how to make one and where to name it.
case "$out" in
  *"warn"*"no disk store is set up"*"mkfs.ext4"*"/etc/fstab"*"echo STORE=/var/lib/agent-sandbox-store >> "*"/settings"*) pass "without a store, doctor says how to make one" ;;
  *) fail "doctor does not explain the store: $out" ;;
esac
if command -v gitleaks >/dev/null 2>&1; then
  pass "gitleaks is installed here"
else
  case "$out" in *"warn"*"gitleaks is not installed"*) pass "missing gitleaks is a warning, not a failure" ;; *) fail "no gitleaks warning" ;; esac
fi
says "through ./sandbox, doctor checks a default session's memory" "memory: the session may use up to 0.7 GB" "$ROOT/sandbox" doctor

# --- each failure: named, with a fix, exit 1 ---------------------------------------
# red <description> <text of the failure> <text of the fix> <command...>
red() {
  local what="$1" problem="$2" fix="$3" out status=0
  shift 3
  out="$("$@" 2>&1)" || status=$?
  if [ "$status" -ne 1 ]; then fail "$what: exit status $status, expected 1"; return; fi
  case "$out" in
    *"FAIL"*"$problem"*"fix: "*"$fix"*) pass "$what" ;;
    *) fail "$what: expected FAIL '$problem' with fix '$fix' in: $out" ;;
  esac
}
FAKE_PODMAN_ROOTLESS=false red "root-run Podman" "running as root (rootful)" "ordinary user" doctor
FAKE_PODMAN_REMOTE=true    red "remote Podman" "remote client" "Podman installed on this machine" doctor
CONTAINER_HOST=tcp://10.0.0.5:2375 red "CONTAINER_HOST" "pointed at another machine" "unset CONTAINER_HOST" doctor
FAKE_PODMAN_VERSION=4.3.1  red "old Podman" "4.3.1 is too old" "upgrade Podman" doctor
FAKE_PODMAN_VERSION=3.4.4  red "older Podman" "3.4.4 is too old" "upgrade Podman" doctor
FAKE_PODMAN_BACKEND=cni    red "CNI backend" "not netavark" "netavark" doctor
FAKE_PODMAN_CGROUPS=v1     red "cgroup v1" "cgroup v1" "systemd.unified_cgroup_hierarchy=1" doctor
FAKE_PODMAN_CONTROLLERS="memory pids" red "cpu not delegated" "limits for: cpu" "Delegate=cpu cpuset io memory pids" doctor
FAKE_PODMAN_CONTROLLERS="" red "nothing delegated" "limits for: cpu memory pids" "delegate.conf" doctor
FAKE_PODMAN_CONTROLLERS="cpu memory pids" red "io not delegated, when --io-limit is used" "limits for: io" "Delegate=" doctor --io
FAKE_PODMAN_IDMAP="0:1 1:1000 " red "id range too short" "does not reach 61003" "usermod --add-subuids" doctor
red "not enough memory" "this host has" "lower --mem" doctor --memory 99999999999999
red "store that does not exist" "does not exist" "mkfs.ext4" doctor --store "$T/nowhere"
mkdir "$T/plain"
red "store that is an ordinary directory" "not a filesystem of its own" "/etc/fstab" doctor --store "$T/plain"
FAKE_PODMAN_VERSION=4.4.0 check "Podman 4.4.0 is new enough" doctor
FAKE_PODMAN_VERSION=4.9.3 check "Ubuntu 24.04's Podman (4.9.3) is new enough" doctor
FAKE_PODMAN_VERSION=10.0.1 check "Podman 10 is new enough" doctor

rm "$ROOT/seccomp/agent-seccomp.json"
red "missing seccomp profile" "agent-seccomp.json is missing" "make-seccomp.sh" doctor
printf '{}\n' > "$ROOT/seccomp/agent-seccomp.json"
printf 'NODE_BASE=UNPINNED\n' >> "$ROOT/images/PINS"
red "unpinned base images" "UNPINNED base images" "pin-images.sh" doctor
check "an unpinned base image does not stop a run whose images exist" doctor --preflight
sed -i.bak '/UNPINNED/d' "$ROOT/images/PINS"

# Podman missing altogether: a PATH with the usual tools but no podman.
mkdir "$T/tools"
for tool in bash env id uname git grep sed tr date dirname cat stat; do
  ln -s "$(command -v "$tool")" "$T/tools/$tool"
done
PATH="$T/tools" red "Podman not installed" "podman is not installed" "install Podman 4.4 or newer" "$ROOT/scripts/doctor.sh"

# --- the short forms print only failures ------------------------------------------
out="$(doctor --preflight 2>&1)" || fail "preflight failed on a good host"
check "preflight is silent on a good host" test -z "$out"
out="$(doctor --runtime-only 2>&1)" || fail "runtime-only failed on a good host"
check "runtime-only is silent on a good host" test -z "$out"
FAKE_PODMAN_CGROUPS=v1 check "runtime-only does not look at cgroups (destroy must work there)" doctor --runtime-only
FAKE_PODMAN_CGROUPS=v1 refuse "preflight does" doctor --preflight
FAKE_PODMAN_ROOTLESS=false refuse "runtime-only refuses a root-run Podman" doctor --runtime-only
refuse "an unknown option is an error" doctor --frobnicate

# --- sessions past their deadline ----------------------------------------------------
mkdir -p "$T/state/asb-old-0a1b2c" "$T/state/asb-live-0a1b2d"
printf 'SESSION=asb-old-0a1b2c\nDEADLINE_EPOCH=1\n' > "$T/state/asb-old-0a1b2c/state"
printf 'SESSION=asb-live-0a1b2d\nDEADLINE_EPOCH=%s\n' "$(( $(date +%s) + 3600 ))" > "$T/state/asb-live-0a1b2d/state"
out="$(doctor 2>&1)" || fail "an expired session made doctor fail"
case "$out" in *"warn"*"asb-old-0a1b2c is past its time limit"*) pass "an expired session is named" ;; *) fail "expired session not named: $out" ;; esac
case "$out" in *"asb-live-0a1b2d"*) fail "a live session was reported as expired" ;; *) pass "a live session is not" ;; esac

finish
