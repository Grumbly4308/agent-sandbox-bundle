#!/usr/bin/env bash
# seccomp/agent-seccomp.json is the file the reference script produced from
# the pinned upstream (hash check), has the properties B04 relies on, and
# scripts/make-seccomp.sh still carries the same pin and drop list.
# The script itself cannot be run here (it downloads with curl).
# Holds jq programs and literal text from the script in single quotes, hence:
# shellcheck disable=SC2016
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

profile="$root/seccomp/agent-seccomp.json"
script="$root/scripts/make-seccomp.sh"
expected="742274fe51492c308ee2b5f58bafab372699f07797a4643598e346ab41f991f2"

# The 25 system calls taken off the upstream list.
drop="ptrace process_vm_readv process_vm_writev mount umount umount2 pivot_root chroot setns unshare init_module finit_module delete_module kexec_load kexec_file_load reboot add_key keyctl request_key bpf perf_event_open open_by_handle_at name_to_handle_at swapon swapoff"

if [ "$(sha256_of "$profile")" = "$expected" ]; then
  pass "profile: sha256 is $expected"
else
  fail "profile: sha256 is $(sha256_of "$profile"), expected $expected"
fi
check "profile: valid JSON" jq -e . "$profile"
check "profile: anything not listed is refused" jq -e '.defaultAction == "SCMP_ACT_ERRNO"' "$profile"
check "profile: refusals are 'operation not permitted' (errno 1)" jq -e '.defaultErrnoRet == 1' "$profile"

for call in $drop; do
  if jq -e --arg c "$call" '[.syscalls[].names[]] | index($c)' "$profile" >/dev/null; then
    fail "profile: $call is still allowed by some rule"
  else
    pass "profile: $call appears in no rule"
  fi
done
check "profile: no rule was left with an empty name list" jq -e '[.syscalls[] | select((.names | length) == 0)] | length == 0' "$profile"

# Creating namespaces through clone stays conditional (the flag mask) and
# clone3 is answered "not implemented" so the C library falls back to clone.
check "profile: clone is allowed only without namespace flags" \
  jq -e '[.syscalls[] | select(.names == ["clone"] and .action == "SCMP_ACT_ALLOW" and (.args | length) > 0 and .args[0].value == 2114060288)] | length >= 1' "$profile"
check "profile: clone3 is answered ENOSYS" \
  jq -e '[.syscalls[] | select(.names == ["clone3"] and .action == "SCMP_ACT_ERRNO" and .errnoRet == 38)] | length == 1' "$profile"
# Ordinary work is still possible.
for call in read write openat execve clone fork socket connect; do
  check "profile: $call is still allowed" jq -e --arg c "$call" '[.syscalls[] | select(.action == "SCMP_ACT_ALLOW") | .names[]] | index($c)' "$profile"
done

# --- The generator ---------------------------------------------------------------
check "script: pinned to moby/profiles commit 836ae4d3 (seccomp/v0.2.3)" \
  grep -qx 'COMMIT="836ae4d37ef2ec995c77c99fc55f5b5f3af3a897"   # seccomp/v0.2.3' "$script"
check "script: checks the download's sha256" \
  grep -qx 'SHA256="536529b665dd0972c37bfb569f5d4ac8a53592e7b00752bc39ff063ca9864c74"' "$script"
check "script: fetches by commit, not by branch" \
  grep -qxF 'SRC="https://raw.githubusercontent.com/moby/profiles/$COMMIT/seccomp/default.json"' "$script"
check "script: writes seccomp/agent-seccomp.json" grep -qx 'OUT="seccomp/agent-seccomp.json"' "$script"
check "script: records the expected output hash" grep -q "^#   $expected\$" "$script"
check "script: prints the hash of what it wrote" grep -qF 'sha256 $(sha256_of "$OUT")' "$script"
check "script: refuses to write on a checksum mismatch" grep -q 'checksum mismatch' "$script"

# The DROP list in the script, as a sorted list of names.
in_script="$(sed -n "/^DROP='\\[/,/^\\]'/p" "$script" | grep -oE '"[a-z0-9_]+"' | tr -d '"' | sort | tr '\n' ' ' | sed 's/ $//')"
want="$(printf '%s' "$drop" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
if [ "$in_script" = "$want" ]; then
  pass "script: the drop list is the reference's 25 system calls"
else
  fail "script: drop list differs: [$in_script]"
fi

# The jq program in the script, applied to the committed profile, changes
# nothing: the profile is already the output of that program.
filtered="$(jq --argjson drop "$(sed -n "/^DROP='\\[/,/^\\]'/p" "$script" | sed "s/^DROP='//; s/'\$//")" '
  .syscalls |= map(.names -= $drop)
  | .syscalls |= map(select((.names | length) > 0))
' "$profile" | jq -cS .)"
if [ "$filtered" = "$(jq -cS . "$profile")" ]; then
  pass "script: its filter leaves the committed profile unchanged (already applied)"
else
  fail "script: its filter would change the committed profile"
fi

# topology.sh points at this file.
check "topology.sh applies seccomp/agent-seccomp.json to the agent" \
  grep -qF 'seccomp=${SANDBOX_ROOT:?}/seccomp/agent-seccomp.json' "$root/topology.sh"

finish
