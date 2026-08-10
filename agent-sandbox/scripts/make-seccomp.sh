#!/usr/bin/env bash
# Build a tightened seccomp profile from Docker's default.
#
#   ./scripts/make-seccomp.sh
#   then uncomment the seccomp line in docker-compose.yml and rebuild.
#
# This is Layer 4 — defense in depth. Optional for casual use; worth it if the
# agent routinely runs code you did not write.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SRC="https://raw.githubusercontent.com/moby/moby/master/profiles/seccomp/default.json"
OUT="agent-seccomp.json"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

echo "==> fetching Docker's default seccomp profile"
curl -fsSL "$SRC" -o /tmp/default-seccomp.json

# Syscalls an AI coding agent has no legitimate use for, and which appear in
# most container-escape chains.
DROP='[
  "ptrace","process_vm_readv","process_vm_writev",
  "mount","umount","umount2","pivot_root","chroot",
  "setns","unshare",
  "init_module","finit_module","delete_module",
  "kexec_load","kexec_file_load","reboot",
  "add_key","keyctl","request_key",
  "bpf","perf_event_open",
  "open_by_handle_at","name_to_handle_at",
  "swapon","swapoff"
]'

echo "==> stripping $(jq -r 'length' <<<"$DROP") syscalls"
jq --argjson drop "$DROP" '
  .syscalls |= map(.names -= $drop)
  | .syscalls |= map(select((.names | length) > 0))
' /tmp/default-seccomp.json > "$OUT"

rm -f /tmp/default-seccomp.json
echo "==> wrote $OUT"
echo
echo "Next: uncomment this line in docker-compose.yml under agent.security_opt:"
echo "      - seccomp=./agent-seccomp.json"
echo
echo "Note: removing unshare/setns breaks tools that create their own"
echo "namespaces (some sandboxed test runners, nested containers). If a build"
echo "starts failing with EPERM right after enabling this, that is why."
