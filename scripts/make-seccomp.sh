#!/usr/bin/env bash
# Build the agent's system-call filter from the container runtimes' default.
# [physical B04]
#
#   scripts/make-seccomp.sh
#
# The result, seccomp/agent-seccomp.json, is committed, and topology.sh
# applies it to the agent container and to the export helper on every start.
# So this only needs running again to move to a newer upstream profile.
#
# What the filter is: a list of the system calls (requests a program makes to
# the kernel) that the agent's processes may use. Anything not on the list is
# refused. We start from the list Docker and Podman use by default and take
# 25 more calls off it (the DROP list below).
#
# The output is deterministic: same pin, same DROP list, same file. With the
# pin below, the file this script writes must have the sha256
#
#   742274fe51492c308ee2b5f58bafab372699f07797a4643598e346ab41f991f2
#
# which is the hash of the committed seccomp/agent-seccomp.json. The script
# prints the hash of what it wrote; if it differs and you did not change the
# pin or the DROP list, do not commit the result. (This script needs curl and
# has not been run on the machine it was written on: the committed file was
# produced by the previous version of this script from the same pin.)
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
# Then update the expected output hash in the header above.
COMMIT="836ae4d37ef2ec995c77c99fc55f5b5f3af3a897"   # seccomp/v0.2.3
SHA256="536529b665dd0972c37bfb569f5d4ac8a53592e7b00752bc39ff063ca9864c74"
SRC="https://raw.githubusercontent.com/moby/profiles/$COMMIT/seccomp/default.json"
OUT="seccomp/agent-seccomp.json"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

# sha256 of a file. Linux has sha256sum; macOS has shasum.
sha256_of() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "==> fetching the default seccomp profile (moby/profiles@${COMMIT:0:12})"
curl -fsSL "$SRC" -o "$tmp"

got="$(sha256_of "$tmp")"
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
# most container-escape chains. ptrace is the one that dropping capabilities
# does NOT cover: tracing a process of the same user needs no capability, so
# without this one process in the container can read another's memory.
# The others are already refused to a container with no capabilities; taking
# them off the list keeps them refused whatever capabilities are present.
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
echo "    sha256 $(sha256_of "$OUT")"
echo
echo "topology.sh already applies it; the next ./sandbox run picks it up."
echo "Commit the new $OUT alongside the pin change."
echo
echo "Note: removing unshare/setns breaks tools that create their own"
echo "namespaces (some sandboxed test runners, nested containers, a browser's"
echo "own sandbox). If a build starts failing with 'Operation not permitted'"
echo "right after a profile change, that is why."
