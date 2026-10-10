#!/usr/bin/env bash
# agents/claude/install.sh — put Claude Code into the agent image.
#
# Runs once, as root, while the image is built (images/agent/Containerfile).
# Everything it installs is owned by root, so the agent, which runs as
# another user on a read-only root filesystem, cannot modify its own CLI.
#
# What is pinned (closes reference finding M2, "unpinned CLI"):
#   * the exact version, and
#   * the sha512 of each tarball, as npm's registry published it
#     (`dist.integrity`). A different tarball under the same version number
#     fails the build.
# Values read on 2026-10-10 with
#   npm view @anthropic-ai/claude-code@2.1.296 dist.integrity
#   npm view @anthropic-ai/claude-code@2.1.296 optionalDependencies dependencies --json
#   npm view @anthropic-ai/claude-code-linux-<arch>@2.1.296 dist.integrity
# The package has no ordinary `dependencies` ({}), so nothing else would be
# fetched. Its optionalDependencies are eight per-platform packages, each
# holding one native program; the two for Debian (glibc) Linux are pinned
# here and the other six are never downloaded.
#
# How it installs, and what that relies on:
#   1. `npm pack` downloads each tarball. Nothing is unpacked or run yet.
#   2. Node computes the sha512 of each file; any mismatch stops the build.
#   3. The tarballs are unpacked with tar into the places `npm install -g`
#      would use. npm's installer is not involved, so no dependency is
#      resolved and no lifecycle script (the package has a `postinstall`) can
#      run. This is stricter than `npm install --ignore-scripts`.
#   4. The one useful thing the skipped postinstall does is done by hand:
#      the native program replaces the small placeholder at bin/claude.exe
#      (a hard link, as the vendor's install.cjs makes). The result is the
#      same tree an ordinary global install produces, which is the layout the
#      spike of 2026-10-01 ran.
#
# To move to a new version: change VERSION, run the three `npm view` commands
# above for it, replace the three hashes, rebuild.
set -euo pipefail

VERSION="2.1.296"

WRAPPER_SPEC="@anthropic-ai/claude-code@${VERSION}"
WRAPPER_INTEGRITY="sha512-OX/k/rpcthMqnFKOWcpNcbiLsMKtAjLOpQNJHlYiDCFUznWCIwdRTyl/p9SdHVrsrzZuPMCNqZjnpakIni6upw=="

X64_SPEC="@anthropic-ai/claude-code-linux-x64@${VERSION}"
X64_INTEGRITY="sha512-+m01urgelnI+VJxPaKPEK0wixgq42uZ8PeCaUk5tX/8YoDBvSmC/REVQG2jQfJAr8dxunpjJ600FvLrcj1WWTw=="

ARM64_SPEC="@anthropic-ai/claude-code-linux-arm64@${VERSION}"
ARM64_INTEGRITY="sha512-Q6Qh6qFmwuBG9rQFiDR6bY3XkFnwTN9AAPrnnDgBvr9sbg1Ql5wrf0lfoCDiV369EUHOzxI4i5OdHW9Vf2/oeA=="

# Where things go. SANDBOX_INSTALL_PREFIX exists only so tests/images/ can
# exercise this script without being root. Nothing else sets it.
PREFIX="${SANDBOX_INSTALL_PREFIX:-/usr/local}"

# Scratch directory for downloads; made in main, removed on exit.
work=""

say() { echo "install(claude): $*" >&2; }

# integrity_of <file>: print the file's hash the way npm writes it.
integrity_of() {
  node -e '
    const hash = require("node:crypto").createHash("sha512");
    hash.update(require("node:fs").readFileSync(process.argv[1]));
    process.stdout.write("sha512-" + hash.digest("base64") + "\n");
  ' "$1"
}

# fetch_verified <npm spec> <expected integrity> <directory>: download one
# tarball into the (empty) directory and stop the build unless its hash is
# the pinned one. Prints the tarball's path.
fetch_verified() {
  local spec="$1" want="$2" dir="$3" file got
  mkdir -p "$dir"
  npm pack "$spec" --pack-destination "$dir" --ignore-scripts \
    --cache "$work/npm-cache" --loglevel=error >/dev/null
  file="$(find "$dir" -maxdepth 1 -type f -name '*.tgz')"
  if [ -z "$file" ] || [ "$(printf '%s\n' "$file" | wc -l)" -ne 1 ]; then
    say "expected exactly one tarball for $spec"
    return 1
  fi
  got="$(integrity_of "$file")"
  if [ "$got" != "$want" ]; then
    say "integrity mismatch for $spec"
    say "  pinned     $want"
    say "  downloaded $got"
    say "refusing to install. Either the registry served something else under"
    say "this version, or the pin in this file is wrong."
    return 1
  fi
  say "verified $spec"
  printf '%s\n' "$file"
}

# unpack <tarball> <directory>: unpack an npm tarball (everything in it sits
# under package/) as root-owned files nobody else can write, with no setuid
# bits whatever the archive says.
unpack() {
  local file="$1" dir="$2"
  mkdir -p "$dir"
  tar -xzf "$file" -C "$dir" --strip-components=1 --no-same-owner
  chmod -R u=rwX,go=rX,ug-s,o-t "$dir"
}

main() {
  local arch platform_spec platform_integrity platform_name
  case "$(uname -m)" in
    x86_64) arch=x64; platform_spec="$X64_SPEC"; platform_integrity="$X64_INTEGRITY" ;;
    aarch64 | arm64) arch=arm64; platform_spec="$ARM64_SPEC"; platform_integrity="$ARM64_INTEGRITY" ;;
    *) say "unsupported processor: $(uname -m)"; exit 1 ;;
  esac
  platform_name="@anthropic-ai/claude-code-linux-${arch}"

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  # Download and verify everything before anything is unpacked.
  local wrapper_tgz platform_tgz
  wrapper_tgz="$(fetch_verified "$WRAPPER_SPEC" "$WRAPPER_INTEGRITY" "$work/wrapper")"
  platform_tgz="$(fetch_verified "$platform_spec" "$platform_integrity" "$work/platform")"

  local pkg="$PREFIX/lib/node_modules/@anthropic-ai/claude-code"
  local native="$pkg/node_modules/$platform_name/claude"
  rm -rf "$pkg"
  unpack "$wrapper_tgz" "$pkg"
  unpack "$platform_tgz" "$pkg/node_modules/$platform_name"

  [ -f "$native" ] || { say "the platform package has no 'claude' program"; exit 1; }
  chmod 0755 "$native"
  # What the package's postinstall would have done.
  ln -f "$native" "$pkg/bin/claude.exe"
  mkdir -p "$PREFIX/bin"
  ln -sf ../lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe "$PREFIX/bin/claude"

  # Prove it runs and is the version pinned. HOME points at the scratch
  # directory so the CLI leaves nothing behind in the image.
  local reported
  reported="$(HOME="$work" "$PREFIX/bin/claude" --version)"
  case "$reported" in
    *"$VERSION"*) ;;
    *) say "installed CLI reports '$reported', expected $VERSION"; exit 1 ;;
  esac
  say "installed: $reported"
  # Last line of standard output: the version, for /usr/share/sandbox/versions.
  printf '%s\n' "$VERSION"
}

# Run only when executed, so the tests can load the functions above.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
