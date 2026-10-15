#!/usr/bin/env bash
# Pin every agent CLI to the version npm calls `latest`.
#
#   scripts/pin-clis.sh [agent...]        all of agents/*/install.sh, or the named ones
#
# Each agents/<name>/install.sh pins one exact version of its CLI and the
# sha512 (npm's `dist.integrity`) of every tarball it unpacks: the wrapper
# package and one native package per Linux processor type. The build fetches
# nothing else and runs no install script, so the three or four hashes are
# the whole trust the image places in the registry. This script moves that
# pin the way scripts/pin-images.sh moves the base-image digests: it asks the
# registry which version is `latest`, reads the integrity of each package at
# that version, and rewrites the VERSION= and *_INTEGRITY= lines. Nothing is
# downloaded or run; the build still verifies every tarball against what is
# written here. It prints `old -> new` for every line it changes, so
# `git diff` and this output agree.
#
# It refuses, and leaves the file as it was, when
#   * the registry cannot be asked, or answers something that is not a
#     version or not a sha512 integrity;
#   * the wrapper package at the new version has ordinary `dependencies`
#     (install.sh never resolves any, so such a version would be incomplete
#     as installed: read the top of that install.sh and move the pin by hand).
#
# `./sandbox upgrade` runs this before it rebuilds. npm is used when it is
# installed; otherwise curl and jq. SANDBOX_NPM_REGISTRY names another
# registry (tests).
set -euo pipefail

SANDBOX_ROOT="${SANDBOX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY="${SANDBOX_NPM_REGISTRY:-https://registry.npmjs.org}"

say() { echo "pin-clis: $*" >&2; }

command -v jq >/dev/null || { say "jq is required"; exit 1; }
if command -v npm >/dev/null; then
  HAVE_NPM=1
elif command -v curl >/dev/null; then
  HAVE_NPM=""
else
  say "npm or curl is required"
  exit 1
fi

# latest_of <package>: the version npm's `latest` tag names, or nothing.
latest_of() {
  if [ -n "$HAVE_NPM" ]; then
    npm view "$1" dist-tags.latest --registry "$REGISTRY" 2>/dev/null || true
  else
    curl -fsS --max-time 20 "$REGISTRY/-/package/${1//\//%2f}/dist-tags" 2>/dev/null \
      | jq -r '.latest // empty' 2>/dev/null || true
  fi
}

# manifest_of <package> <version>: that version's manifest, as JSON.
manifest_of() {
  if [ -n "$HAVE_NPM" ]; then
    npm view "$1@$2" --json --registry "$REGISTRY" 2>/dev/null
  else
    curl -fsS --max-time 20 "$REGISTRY/${1//\//%2f}/$2" 2>/dev/null
  fi
}

# A version as npm prints one: digits, letters, dots, hyphens and plus
# signs, nothing else (a stray control sequence must not reach the file).
is_version() {
  case "$1" in ''|*[!0-9A-Za-z.+-]*) return 1 ;; *) return 0 ;; esac
}

# pin_agent <name>: move agents/<name>/install.sh to the latest version.
pin_agent() {
  local name="$1" file rel version latest package wrapper_package key value spec
  local -a keys=() specs=() hashes=()
  local manifest integrity got deps tmp line today changed
  file="$SANDBOX_ROOT/agents/$name/install.sh"
  rel="agents/$name/install.sh"
  [ -f "$file" ] || { say "$rel: no such file"; return 1; }
  version="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$file")"
  [ -n "$version" ] || { say "$rel: no VERSION= line"; return 1; }
  # Every KEY_SPEC="<package>@<version>" line, with its ${VERSION} written out.
  while IFS=' ' read -r key value; do
    [ -n "$key" ] || continue
    keys+=("$key")
    # shellcheck disable=SC2016  # the literal ${VERSION} of install.sh
    specs+=("${value//'${VERSION}'/__VERSION__}")
  done < <(sed -n 's/^\([A-Z0-9_]*\)_SPEC="\(.*\)"$/\1 \2/p' "$file")
  [ "${#keys[@]}" -gt 0 ] || { say "$rel: no *_SPEC= lines"; return 1; }
  wrapper_package=""
  for i in "${!keys[@]}"; do
    [ "${keys[$i]}" = WRAPPER ] || continue
    spec="${specs[$i]}"; wrapper_package="${spec%@*}"
  done
  [ -n "$wrapper_package" ] || { say "$rel: no WRAPPER_SPEC= line"; return 1; }
  for key in "${keys[@]}"; do
    grep -q "^${key}_INTEGRITY=\"sha512-" "$file" \
      || { say "$rel: no ${key}_INTEGRITY= line for ${key}_SPEC"; return 1; }
  done

  latest="$(latest_of "$wrapper_package" | head -n 1)"
  if ! is_version "$latest"; then
    say "$rel: could not ask $REGISTRY which $wrapper_package is the latest"
    return 1
  fi
  if [ "$latest" = "$version" ]; then
    printf '%s: %s %s (already the latest)\n' "$rel" "$wrapper_package" "$version"
    return 0
  fi

  # Read every hash first; the file is written only when all of them are in.
  for i in "${!keys[@]}"; do
    spec="${specs[$i]//__VERSION__/$latest}"
    package="${spec%@*}"
    if ! manifest="$(manifest_of "$package" "${spec##*@}")" || [ -z "$manifest" ]; then
      say "$rel: $REGISTRY has no $spec"
      return 1
    fi
    got="$(printf '%s' "$manifest" | jq -r '.version // empty' 2>/dev/null || true)"
    integrity="$(printf '%s' "$manifest" | jq -r '.dist.integrity // empty' 2>/dev/null || true)"
    if [ "$got" != "${spec##*@}" ]; then
      say "$rel: asked $REGISTRY for $spec and was answered for '$got'"
      return 1
    fi
    case "$integrity" in
      sha512-*) ;;
      *) say "$rel: $REGISTRY gives no sha512 integrity for $spec (got '$integrity')"; return 1 ;;
    esac
    if [ -n "$(printf '%s' "$integrity" | tr -d 'A-Za-z0-9+/=-')" ]; then
      say "$rel: malformed integrity for $spec: '$integrity'"
      return 1
    fi
    if [ "${keys[$i]}" = WRAPPER ]; then
      deps="$(printf '%s' "$manifest" | jq -r '(.dependencies // {}) | keys | join(" ")' 2>/dev/null || echo '?')"
      if [ -n "$deps" ]; then
        say "$rel: $spec has ordinary dependencies ($deps), which install.sh never fetches."
        say "Read the top of $rel and move the pin by hand."
        return 1
      fi
    fi
    hashes+=("$integrity")
  done

  # Rewrite the pinned lines; every other line is copied through untouched.
  today="$(date +%Y-%m-%d)"
  tmp="$(mktemp)"
  changed=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "VERSION=\"$version\"")
        printf 'VERSION="%s"\n' "$latest" >>"$tmp"
        continue ;;
      "# Values read on "*" with")
        printf '# Values read on %s with\n' "$today" >>"$tmp"
        continue ;;
      "#   npm view "*"@$version"*)
        # The commands the header says the values came from: same version.
        printf '%s\n' "${line//"@$version"/"@$latest"}" >>"$tmp"
        continue ;;
      *_INTEGRITY=\"sha512-*)
        key="${line%%_INTEGRITY=*}"
        for i in "${!keys[@]}"; do
          [ "${keys[$i]}" = "$key" ] || continue
          printf '%s_INTEGRITY="%s"\n' "$key" "${hashes[$i]}" >>"$tmp"
          changed="$changed $key"
          continue 2
        done ;;
    esac
    printf '%s\n' "$line" >>"$tmp"
  done <"$file"
  for key in "${keys[@]}"; do
    case " $changed " in *" $key "*) ;; *) rm -f "$tmp"; say "$rel: ${key}_INTEGRITY= line not rewritten"; return 1 ;; esac
  done
  # Write through the existing file so its permissions stay as they are.
  cat "$tmp" >"$file"
  rm -f "$tmp"
  printf '%s: %s: %s -> %s\n' "$rel" "$wrapper_package" "$version" "$latest"
  for i in "${!keys[@]}"; do
    printf '  %s_INTEGRITY: %s %s\n' "${keys[$i]}" "${specs[$i]//__VERSION__/$latest}" "${hashes[$i]}"
  done
}

agents=("$@")
if [ "${#agents[@]}" -eq 0 ]; then
  for file in "$SANDBOX_ROOT"/agents/*/install.sh; do
    [ -f "$file" ] || continue
    file="${file%/install.sh}"
    agents+=("${file##*/}")
  done
fi
[ "${#agents[@]}" -gt 0 ] || { say "no agents/*/install.sh here"; exit 1; }

for agent in "${agents[@]}"; do
  pin_agent "$agent"
done

echo "pin-clis: done. Review with 'git diff', then commit."
