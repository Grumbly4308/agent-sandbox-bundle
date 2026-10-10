#!/usr/bin/env bash
# Pin every image this project starts from to a digest.
#
#   scripts/pin-images.sh
#
# A tag such as `node:22-bookworm-slim` is a name its publisher can point at
# new contents at any time. A digest (`@sha256:...`) names one exact set of
# bytes. This script turns the first into the second, for
#
#   * each `NAME=` entry in images/PINS (the base images we build on), and
#   * the `IMAGE=` entry in each services/<name>/service.conf (the sibling
#     services, which are used as published).
#
# For each entry it reads the tag from the `# tag: <reference>` comment above
# the entry, pulls that tag with Podman, asks Podman for the digest of what
# it pulled, and rewrites the entry as `registry/repo:tag@sha256:...`. It
# prints `old -> new` for every entry, so `git diff` and this output agree.
#
# Run it on a host with Podman and ordinary network access: once after
# cloning (the files ship with UNPINNED), and again whenever you want newer
# images. Nothing else in the project ever pulls by tag. Closes reference
# finding M2 (unpinned images).
#
# When you run it, and in particular for an image published
# for several processor types, check that the digest printed is the one of
# the multi-platform list (the "index digest" the registry shows), so the
# same PINS file works on Intel and ARM hosts.
set -euo pipefail

SANDBOX_ROOT="${SANDBOX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

command -v podman >/dev/null || { echo "pin-images: podman is required" >&2; exit 1; }

# digest_of <reference>: pull the tag, print `sha256:...` of what was pulled.
digest_of() {
  local ref="$1" digest
  podman pull --quiet "$ref" >/dev/null
  digest="$(podman image inspect --format '{{.Digest}}' "$ref")"
  case "$digest" in
    sha256:*) ;;
    *) echo "pin-images: podman reported no sha256 digest for $ref (got '$digest')" >&2; return 1 ;;
  esac
  # 64 hexadecimal characters after the prefix, nothing else.
  if [ "${#digest}" -ne 71 ] || [ -n "$(printf '%s' "${digest#sha256:}" | tr -d '0-9a-f')" ]; then
    echo "pin-images: malformed digest for $ref: '$digest'" >&2
    return 1
  fi
  printf '%s\n' "$digest"
}

# pin_file <file> <key-pattern>: rewrite every `KEY=value` line whose key
# matches the shell pattern, using the nearest `# tag:` comment above it.
# Every other line is copied through untouched.
pin_file() {
  local file="$1" pattern="$2" line key old new tag="" digest tmp
  tmp="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "# tag: "*)
        tag="${line#"# tag: "}"
        printf '%s\n' "$line" >>"$tmp"
        continue
        ;;
      \#* | "")
        printf '%s\n' "$line" >>"$tmp"
        continue
        ;;
    esac
    key="${line%%=*}"
    old="${line#*=}"
    # The pattern is a shell pattern on purpose (NAME= entries in PINS are
    # matched with '*', service files with 'IMAGE').
    # shellcheck disable=SC2254
    case "$key" in
      $pattern)
        if [ -z "$tag" ]; then
          echo "pin-images: $file: no '# tag: <reference>' comment above $key" >&2
          rm -f "$tmp"
          return 1
        fi
        if ! digest="$(digest_of "$tag")"; then
          rm -f "$tmp"
          return 1
        fi
        new="${tag}@${digest}"
        printf '%s=%s\n' "$key" "$new" >>"$tmp"
        printf '%s: %s: %s -> %s\n' "${file#"$SANDBOX_ROOT"/}" "$key" "$old" "$new"
        tag=""
        ;;
      *)
        printf '%s\n' "$line" >>"$tmp"
        ;;
    esac
  done <"$file"
  # Write through the existing file so its permissions stay as they are.
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

pin_file "$SANDBOX_ROOT/images/PINS" '*'

for conf in "$SANDBOX_ROOT"/services/*/service.conf; do
  [ -f "$conf" ] || continue
  pin_file "$conf" 'IMAGE'
done

echo "pin-images: done. Review with 'git diff', then commit."
