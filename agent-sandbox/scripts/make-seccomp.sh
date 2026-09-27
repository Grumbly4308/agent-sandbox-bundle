#!/usr/bin/env bash
# Build a tightened seccomp profile from Docker's default.
#
#   ./scripts/make-seccomp.sh
#
# The result, agent-seccomp.json, is committed and docker-compose.yml applies
# it on every start, so this only needs re-running to move to a newer upstream
# profile. The output is deterministic: same pin, same file, so a diff in the
# committed copy means the pin or the DROP list changed.
#
# This is Layer 4 — defense in depth. Cheap for casual use; essential if the
# agent routinely runs code you did not write.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Docker's default profile lives in github.com/moby/profiles (moby/moby only
# vendors it now, so the old .../moby/moby/master/... URL is a 404). Pinned to
# a commit rather than a branch: fetching a branch lets whoever controls that
# repo — or the path to it — decide which syscalls the agent may make, and a
# hash check on a moving target is no check at all.
#
# To move the pin: take the seccomp/vX.Y.Z tag that moby's vendor/modules.txt
# names, put its commit in COMMIT, empty SHA256, and run once. The script
# prints the hash of what it fetched and stops without writing; paste that
# hash into SHA256 and run again. Never fill SHA256 from anything but a run.
COMMIT="836ae4d37ef2ec995c77c99fc55f5b5f3af3a897"   # seccomp/v0.2.3
SHA256="536529b665dd0972c37bfb569f5d4ac8a53592e7b00752bc39ff063ca9864c74"
SRC="https://raw.githubusercontent.com/moby/profiles/$COMMIT/seccomp/default.json"
OUT="agent-seccomp.json"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "==> fetching Docker's default seccomp profile (moby/profiles@${COMMIT:0:12})"
curl -fsSL "$SRC" -o "$tmp"

got="$(sha256sum "$tmp" | cut -d' ' -f1)"
if [ -z "$SHA256" ]; then
  echo "SHA256 is empty — not writing $OUT." >&2
  echo "Fetched file hashes to: $got" >&2
  echo "Put that in SHA256 at the top of this script and run again." >&2
  exit 1
elif [ "$got" != "$SHA256" ]; then
  echo "checksum mismatch for $SRC" >&2
  echo "  expected $SHA256" >&2
  echo "  got      $got" >&2
  echo "Not writing $OUT. Either upstream rewrote a pinned commit (it should" >&2
  echo "not) or something between you and GitHub altered the download." >&2
  exit 1
fi

# Syscalls an AI coding agent has no legitimate use for, and which appear in
# most container-escape chains. ptrace is the one cap_drop does NOT cover:
# same-uid tracing needs no capability, so without this a compromised process
# can read the agent's memory — and every key in it.
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
' "$tmp" > "$OUT"

echo "==> wrote $OUT"
echo
echo "docker-compose.yml already applies it; the next ./sandbox go picks it up."
echo "Commit the new $OUT alongside the pin change."
echo
echo "Note: removing unshare/setns breaks tools that create their own"
echo "namespaces (some sandboxed test runners, nested containers). If a build"
echo "starts failing with EPERM right after enabling this, that is why."
