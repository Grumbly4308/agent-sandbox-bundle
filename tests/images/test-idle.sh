#!/usr/bin/env bash
# sandbox-idle: creates the home directory and the repository directory with
# mode 0700, carries on when the workspace is read-only, and ends by becoming
# `catatonit -P`. catatonit is a stand-in here that records how it was called.
# sandbox-launch: goes to the repository and hands over to the plug-in.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

idle="$root/images/agent/sandbox-idle"

mkdir -p "$scratch/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$$" "$@" > "%s/catatonit.called"\n' "$scratch" >"$scratch/bin/catatonit"
chmod +x "$scratch/bin/catatonit"

# /home and /workspace are open to all (1777) in the container; the script
# must end up with private directories inside them whatever the umask.
mkdir -p "$scratch/home" "$scratch/ws"
chmod 1777 "$scratch/home" "$scratch/ws"
if (umask 000 && HOME="$scratch/home/agent" SANDBOX_WORKSPACE_FOR_TESTS="$scratch/ws" \
  PATH="$scratch/bin:$PATH" "$idle" >/dev/null 2>&1); then
  pass "idle: runs"
else
  fail "idle: failed"
fi
if [ "$(mode_of "$scratch/home/agent")" = 700 ]; then pass "idle: home is 0700"; else fail "idle: home mode is $(mode_of "$scratch/home/agent")"; fi
if [ "$(mode_of "$scratch/ws/repo")" = 700 ]; then pass "idle: repo directory is 0700"; else fail "idle: repo mode is $(mode_of "$scratch/ws/repo")"; fi
if [ -z "$(ls -A "$scratch/ws/repo")" ]; then pass "idle: repo directory is empty"; else fail "idle: repo directory is not empty"; fi
if [ "$(sed -n 2p "$scratch/catatonit.called" 2>/dev/null)" = "-P" ] && [ "$(wc -l <"$scratch/catatonit.called")" -eq 2 ]; then
  pass "idle: becomes 'catatonit -P'"
else
  fail "idle: catatonit was not called with exactly -P"
fi
check "idle: uses exec, so catatonit takes over process 1" grep -q '^exec catatonit -P$' "$idle"

# A directory that exists already with loose permissions is tightened.
rm -f "$scratch/catatonit.called"
chmod 0755 "$scratch/home/agent" "$scratch/ws/repo"
HOME="$scratch/home/agent" SANDBOX_WORKSPACE_FOR_TESTS="$scratch/ws" PATH="$scratch/bin:$PATH" "$idle" >/dev/null 2>&1 || true
if [ "$(mode_of "$scratch/home/agent")" = 700 ] && [ "$(mode_of "$scratch/ws/repo")" = 700 ]; then
  pass "idle: tightens directories that already exist"
else
  fail "idle: left existing directories loose"
fi

# A read-only workspace (the keeper's and the export helper's view) is
# tolerated. Root ignores permission bits, so this part needs a normal user.
if [ "$(id -u)" -ne 0 ]; then
  rm -f "$scratch/catatonit.called"
  mkdir -p "$scratch/ro"
  chmod 0555 "$scratch/ro"
  if HOME="$scratch/home/agent" SANDBOX_WORKSPACE_FOR_TESTS="$scratch/ro" PATH="$scratch/bin:$PATH" "$idle" >/dev/null 2>"$scratch/ro.err" \
    && [ -e "$scratch/catatonit.called" ]; then
    pass "idle: tolerates a read-only workspace"
  else
    fail "idle: gave up on a read-only workspace"
  fi
  check "idle: says so" grep -q 'not prepared' "$scratch/ro.err"
else
  echo "SKIP idle: read-only workspace (running as root)"
fi

# sandbox-launch is two lines: go to the repository, become the plug-in.
launch="$root/images/agent/sandbox-launch"
check "launch: changes into /workspace/repo" grep -q '^cd /workspace/repo$' "$launch"
check "launch: execs the plug-in with every argument" grep -q '^exec /usr/share/sandbox/agent/launch "\$@"$' "$launch"

finish
