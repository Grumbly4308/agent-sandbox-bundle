#!/usr/bin/env bash
# agents/opencode/install.sh — put OpenCode into the agent image.
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
# Values read on 2026-10-02 with
#   npm view opencode-ai@1.18.34 dist.integrity
#   npm view opencode-ai@1.18.34 optionalDependencies dependencies --json
#   npm view opencode-linux-<arch>@1.18.34 dist.integrity
# The package has no ordinary `dependencies`. Its optionalDependencies are
# twelve per-platform packages, each holding one native program. Three are
# pinned here: Linux arm64, Linux x64, and Linux x64 "baseline" for
# processors without AVX2 (the ordinary x64 program stops with "illegal
# instruction" on those). The other nine are never downloaded.
#
# How it installs, and what that relies on:
#   1. `npm pack` downloads each tarball. Nothing is unpacked or run yet.
#   2. Node computes the sha512 of each file; any mismatch stops the build.
#   3. The tarballs are unpacked with tar into the places `npm install -g`
#      would use. npm's installer is not involved, so no dependency is
#      resolved and no lifecycle script can run. That matters here: the
#      package's `postinstall`, when it cannot find the platform package,
#      runs a second `npm install` for it by name, which no hash of ours
#      would cover.
#   4. The one useful thing the skipped postinstall does is done by hand:
#      the native program replaces the small placeholder at bin/opencode.exe
#      (a hard link, as the vendor's postinstall.mjs makes). The spike of
#      2026-10-01 ran the native program directly, installed without
#      lifecycle scripts, and that is what this relies on.
#
# To move to a new version: change VERSION, run the three `npm view` commands
# above for it, replace the four hashes, rebuild.
set -euo pipefail

VERSION="1.18.34"

WRAPPER_SPEC="opencode-ai@${VERSION}"
WRAPPER_INTEGRITY="sha512-9WUS2T0t4HHDVzXvuwTHF0nvhXvZ9mQ0r+ozCvKdJu0LVoQpOzqAW4qWTC3ygNc5Oedcc7j+Oct24JYlQYnySA=="

X64_SPEC="opencode-linux-x64@${VERSION}"
X64_INTEGRITY="sha512-RTAMjCve4euxP2QKLuvRmdoW5J5DQK1DiZqt+7slfixyjAEi79QC2Df2oYKogibaAI4IEU8uzenoJeEl3k+UEw=="

X64_BASELINE_SPEC="opencode-linux-x64-baseline@${VERSION}"
X64_BASELINE_INTEGRITY="sha512-StWC81sqAGzsig602U6xui3t0Y/kJtZRmJd+H1xYTY7zVLIZ4Iucb1Wp0no6A7/sDj6VqtFKdL718usH92sHBA=="

ARM64_SPEC="opencode-linux-arm64@${VERSION}"
ARM64_INTEGRITY="sha512-ZSjqcH0MEbAzLEmkRC9Aop1PbWZxe2NuKONAE/x8MRQdjKdOepX7M50UpjbsNoiLMkP584Z98Mg4a42fJhouvA=="

# Where things go. SANDBOX_INSTALL_PREFIX exists only so tests/images/ can
# exercise this script without being root. Nothing else sets it.
PREFIX="${SANDBOX_INSTALL_PREFIX:-/usr/local}"

# Scratch directory for downloads; made in main, removed on exit.
work=""

say() { echo "install(opencode): $*" >&2; }

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

# has_avx2: true when this processor has the AVX2 instructions the ordinary
# x64 program needs. Same test the vendor's postinstall makes.
has_avx2() {
  grep -qiE '(^|[[:space:]])avx2([[:space:]]|$)' /proc/cpuinfo 2>/dev/null
}

main() {
  local platform_spec platform_integrity platform_name
  case "$(uname -m)" in
    x86_64)
      if has_avx2; then
        platform_name=opencode-linux-x64; platform_spec="$X64_SPEC"; platform_integrity="$X64_INTEGRITY"
      else
        platform_name=opencode-linux-x64-baseline; platform_spec="$X64_BASELINE_SPEC"; platform_integrity="$X64_BASELINE_INTEGRITY"
      fi
      ;;
    aarch64 | arm64) platform_name=opencode-linux-arm64; platform_spec="$ARM64_SPEC"; platform_integrity="$ARM64_INTEGRITY" ;;
    *) say "unsupported processor: $(uname -m)"; exit 1 ;;
  esac

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  # Download and verify everything before anything is unpacked.
  local wrapper_tgz platform_tgz
  wrapper_tgz="$(fetch_verified "$WRAPPER_SPEC" "$WRAPPER_INTEGRITY" "$work/wrapper")"
  platform_tgz="$(fetch_verified "$platform_spec" "$platform_integrity" "$work/platform")"

  local pkg="$PREFIX/lib/node_modules/opencode-ai"
  local native="$pkg/node_modules/$platform_name/bin/opencode"
  rm -rf "$pkg"
  unpack "$wrapper_tgz" "$pkg"
  unpack "$platform_tgz" "$pkg/node_modules/$platform_name"

  [ -f "$native" ] || { say "the platform package has no bin/opencode"; exit 1; }
  chmod 0755 "$native"
  # What the package's postinstall would have done.
  ln -f "$native" "$pkg/bin/opencode.exe"
  mkdir -p "$PREFIX/bin"
  ln -sf ../lib/node_modules/opencode-ai/bin/opencode.exe "$PREFIX/bin/opencode"

  # Prove it runs and is the version pinned. HOME points at the scratch
  # directory so the CLI leaves nothing behind in the image.
  local reported
  reported="$(HOME="$work" "$PREFIX/bin/opencode" --version)"
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
