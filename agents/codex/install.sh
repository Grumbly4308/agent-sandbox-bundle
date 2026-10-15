#!/usr/bin/env bash
# agents/codex/install.sh — put the Codex CLI into the agent image.
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
#   npm view @openai/codex@0.162.1 dist.integrity
#   npm view @openai/codex@0.162.1 optionalDependencies dependencies --json
#   npm view @openai/codex@0.162.1-linux-<arch> dist.integrity
# The package has no ordinary `dependencies` and no lifecycle scripts. Its
# optionalDependencies are six per-platform packages, each holding the native
# program. They are published as *versions of the same package*
# (`@openai/codex@0.162.1-linux-x64`) and installed under another name
# (`@openai/codex-linux-x64`) through an npm alias. The two Linux ones are
# pinned here and the other four are never downloaded.
#
# How it installs, and what that relies on:
#   1. `npm pack` downloads each tarball. Nothing is unpacked or run yet.
#   2. Node computes the sha512 of each file; any mismatch stops the build.
#   3. The tarballs are unpacked with tar into the places `npm install -g`
#      would use, the platform package under its alias name. npm's installer
#      is not involved, so no dependency is resolved and no lifecycle script
#      can run. (npm cannot install an alias from a local file, so tar is
#      also the only way to keep the vendor's layout from verified files.)
#   4. `codex` on PATH is a link straight to the native program,
#      vendor/<target>/bin/codex inside the platform package. The package's
#      own Node wrapper (bin/codex.js) only finds and starts that program;
#      the spike of 2026-10-01 ran the native program directly, installed
#      without lifecycle scripts, and that is what this relies on. The
#      program is statically linked (musl), so it needs nothing from Debian.
#
# To move to a new version: `./sandbox upgrade` (scripts/pin-clis.sh) asks the
# registry for the newest version, rewrites VERSION and the three hashes here, and
# rebuilds. By hand: change VERSION, run the three `npm view` commands above
# for it, replace the three hashes, rebuild.
set -euo pipefail

VERSION="0.162.1"

WRAPPER_SPEC="@openai/codex@${VERSION}"
WRAPPER_INTEGRITY="sha512-NWZdi/kxyjv/8EUGFupziGU38YyleugZRM4JXgY5XFH7FUmaFA33NZS2Bmq0HPazf7S3jJQQWsZ/jAK9jsrV3Q=="

X64_SPEC="@openai/codex@${VERSION}-linux-x64"
X64_INTEGRITY="sha512-cjK2mdHIfEepZ1lQ1MX3aTQC+8ncIsvnacl/6vI2dIIcfP8/MrhTQ2+qRlkXFNDzJSj1d36quIszP+3/4CUJWQ=="

ARM64_SPEC="@openai/codex@${VERSION}-linux-arm64"
ARM64_INTEGRITY="sha512-Ss7W/SrKtQFNaMtSojNoiykJgX+iDC8daM+YrcvgmJADtQPk0cd3w6Dna4CYH2CYvf9nQranj69fpcTzZ3sQIQ=="

# Where things go. SANDBOX_INSTALL_PREFIX exists only so tests/images/ can
# exercise this script without being root. Nothing else sets it.
PREFIX="${SANDBOX_INSTALL_PREFIX:-/usr/local}"

# Scratch directory for downloads; made in main, removed on exit.
work=""

say() { echo "install(codex): $*" >&2; }

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
  local arch platform_spec platform_integrity target
  case "$(uname -m)" in
    x86_64) arch=x64; target=x86_64-unknown-linux-musl; platform_spec="$X64_SPEC"; platform_integrity="$X64_INTEGRITY" ;;
    aarch64 | arm64) arch=arm64; target=aarch64-unknown-linux-musl; platform_spec="$ARM64_SPEC"; platform_integrity="$ARM64_INTEGRITY" ;;
    *) say "unsupported processor: $(uname -m)"; exit 1 ;;
  esac

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  # Download and verify everything before anything is unpacked.
  local wrapper_tgz platform_tgz
  wrapper_tgz="$(fetch_verified "$WRAPPER_SPEC" "$WRAPPER_INTEGRITY" "$work/wrapper")"
  platform_tgz="$(fetch_verified "$platform_spec" "$platform_integrity" "$work/platform")"

  local pkg="$PREFIX/lib/node_modules/@openai/codex"
  # The alias name the vendor's wrapper looks the platform package up under.
  local platform_dir="$pkg/node_modules/@openai/codex-linux-${arch}"
  local native="$platform_dir/vendor/$target/bin/codex"
  rm -rf "$pkg"
  unpack "$wrapper_tgz" "$pkg"
  unpack "$platform_tgz" "$platform_dir"

  [ -f "$native" ] || { say "the platform package has no vendor/$target/bin/codex"; exit 1; }
  chmod 0755 "$native"
  mkdir -p "$PREFIX/bin"
  ln -sf "../lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-${arch}/vendor/$target/bin/codex" "$PREFIX/bin/codex"

  # Prove it runs and is the version pinned. HOME and CODEX_HOME point at
  # the scratch directory so the CLI leaves nothing behind in the image.
  local reported
  reported="$(HOME="$work" CODEX_HOME="$work/codex-home" "$PREFIX/bin/codex" --version)"
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
