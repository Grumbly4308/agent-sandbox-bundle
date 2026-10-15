#!/usr/bin/env bash
# Move an agent's CLI pin to a newer version, with the hashes to match.
#
#   scripts/pin-cli.sh <agent> [version]
#
# Each agents/<agent>/install.sh names one exact version and the sha512 of
# every tarball it will unpack. A build with a changed VERSION and the old
# hashes fails, correctly, as an integrity mismatch. This script does the
# whole move so that cannot happen by hand:
#
#   1. asks the npm registry which version is current (or takes the one
#      given), and what it publishes as each tarball's `dist.integrity`;
#   2. downloads every tarball install.sh pins and hashes it here; a hash that
#      differs from what the registry publishes stops everything, since the
#      two have come apart;
#   3. refuses a wrapper package that has grown ordinary `dependencies`, as
#      install.sh unpacks with tar and would silently leave them out;
#   4. rewrites VERSION, every *_INTEGRITY and the header of install.sh, and
#      the version named in compat.md, docs/05-agents-and-toolchains.md and
#      tests/images/test-install.sh;
#   5. runs tests/images/test-install.sh, then install.sh itself against the
#      downloaded tarballs into a scratch prefix, so the unpack, the links and
#      the CLI's own `--version` are seen to work before anything is built.
#
# It touches files in the working tree only. Read `git diff`, commit, then
# `./sandbox upgrade` rebuilds the images onto the new pin. With the version
# already pinned it changes nothing and only re-verifies the hashes.
#
# Needs curl, jq, tar, openssl (or sha512sum) and node; the same registry
# setting as ./sandbox: SANDBOX_NPM_REGISTRY (default https://registry.npmjs.org).
set -euo pipefail

SANDBOX_ROOT="${SANDBOX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REGISTRY="${SANDBOX_NPM_REGISTRY:-https://registry.npmjs.org}"

usage() { echo "usage: scripts/pin-cli.sh <agent> [version]" >&2; exit 2; }
say() { echo "pin-cli: $*" >&2; }
die() { say "$*"; exit 1; }

if [ $# -lt 1 ] || [ $# -gt 2 ]; then usage; fi
agent="$1"; want="${2:-}"
case "$agent" in *[!a-z0-9-]*|'') die "agent names are lower-case letters, digits and hyphens" ;; esac
install="$SANDBOX_ROOT/agents/$agent/install.sh"
[ -f "$install" ] || die "no such agent: $install"
for tool in curl jq tar node; do command -v "$tool" >/dev/null || die "$tool is required"; done
case "$want" in ''|[0-9]*) ;; *) die "a version looks like 2.1.300, not '$want'" ;; esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- read the pins -----------------------------------------------------------
old="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$install")"
[ -n "$old" ] || die "$install has no VERSION= line"
# The *_SPEC names, in file order; each has a matching *_INTEGRITY.
# shellcheck disable=SC2016  # the ${VERSION} searched for is install.sh's, written literally
names="$(sed -n 's/^\([A-Z0-9_]*\)_SPEC="[^"]*\${VERSION}[^"]*"$/\1/p' "$install")"
[ -n "$names" ] || die "$install has no *_SPEC=\"...\${VERSION}...\" lines"
spec_of() { sed -n "s/^${1}_SPEC=\"\(.*\)\"\$/\1/p" "$install"; }
for n in $names; do
  grep -q "^${n}_INTEGRITY=\"sha512-" "$install" || die "${n}_SPEC has no ${n}_INTEGRITY line"
done

# package_of / version_of <spec with ${VERSION} filled in>: split at the last '@'.
package_of() { printf '%s\n' "${1%@*}"; }
version_of() { printf '%s\n' "${1##*@}"; }
url_of() { printf '%s/%s\n' "$REGISTRY" "${1//\//%2f}"; }   # a scoped name is one path segment

wrapper_pkg="$(package_of "$(spec_of WRAPPER)")"
[ -n "$wrapper_pkg" ] || die "no WRAPPER_SPEC in $install"

# --- which version -------------------------------------------------------------
if [ -z "$want" ]; then
  want="$(curl -fsS --max-time 20 "$(url_of "$wrapper_pkg")/latest" | jq -r '.version // empty')" \
    || die "could not ask $REGISTRY about $wrapper_pkg"
  case "$want" in ''|*[!0-9A-Za-z.+-]*) die "the registry's answer is not a version: '$want'" ;; esac
fi
if [ "$want" = "$old" ]; then
  say "$agent: $wrapper_pkg $old is already the pin; verifying the hashes only"
else
  say "$agent: $wrapper_pkg $old -> $want"
fi

# --- fetch, hash, compare -----------------------------------------------------------
integrity_of() {
  if command -v openssl >/dev/null; then
    printf 'sha512-%s\n' "$(openssl dgst -sha512 -binary "$1" | base64 -w0)"
  else
    printf 'sha512-%s\n' "$(sha512sum "$1" | cut -d' ' -f1 | xxd -r -p | base64 -w0)"
  fi
}

mkdir -p "$work/tarballs"
: > "$work/map"      # "<spec>\t<tarball path>" for the stand-in npm below
declare -A NEW_INTEGRITY=()
for n in $names; do
  spec="$(spec_of "$n")"; spec="${spec//\$\{VERSION\}/$want}"
  pkg="$(package_of "$spec")"; ver="$(version_of "$spec")"
  meta="$work/$n.json"
  curl -fsS --max-time 60 "$(url_of "$pkg")/$ver" -o "$meta" \
    || die "the registry has no $spec. Is $ver published for every platform package yet?"
  published="$(jq -r '.dist.integrity // empty' "$meta")"
  tarball_url="$(jq -r '.dist.tarball // empty' "$meta")"
  if [ -z "$published" ] || [ -z "$tarball_url" ]; then die "$spec: the registry lists no dist.integrity or dist.tarball"; fi
  case "$published" in sha512-*) ;; *) die "$spec: the registry publishes '$published', not a sha512" ;; esac
  file="$work/tarballs/$n.tgz"
  curl -fsS --max-time 600 "$tarball_url" -o "$file" || die "could not download $tarball_url"
  got="$(integrity_of "$file")"
  if [ "$got" != "$published" ]; then
    say "$spec: the tarball does not match what the registry publishes for it"
    say "  published  $published"
    say "  downloaded $got"
    die "stopping: nothing is pinned until the registry and its tarball agree"
  fi
  NEW_INTEGRITY[$n]="$got"
  printf '%s\t%s\n' "$spec" "$file" >> "$work/map"
  say "  $spec  $got"
  if [ "$n" = WRAPPER ]; then
    deps="$(jq -c '.dependencies // {}' "$meta")"
    [ "$deps" = '{}' ] || die "$spec has ordinary dependencies $deps; install.sh unpacks with tar and would not install them. Read install.sh before moving this pin."
    say "  $spec: no ordinary dependencies; $(jq -r '(.optionalDependencies // {}) | length' "$meta") optional (per-platform) packages; lifecycle scripts: $(jq -r '(.scripts // {}) | keys | join(" ") | if . == "" then "none" else . end' "$meta")"
  fi
done

# --- rewrite ------------------------------------------------------------------
esc() { printf '%s\n' "$1" | sed 's/[.[\*^$/]/\\&/g'; }     # literal, for sed patterns
old_re="$(esc "$old")"
today="$(date +%F)"

if [ "$want" != "$old" ]; then
  sed -i \
    -e "s/^VERSION=\"${old_re}\"\$/VERSION=\"${want}\"/" \
    -e "/^# *Values read on [0-9-]* with\$/ s/[0-9][0-9-]*/${today}/" \
    -e "/^#/ s/@${old_re}\\b/@${want}/g" \
    "$install"
fi
for n in $names; do
  sed -i "s|^${n}_INTEGRITY=\"sha512-[^\"]*\"\$|${n}_INTEGRITY=\"${NEW_INTEGRITY[$n]}\"|" "$install"
done
grep -q "^VERSION=\"${want}\"\$" "$install" || die "VERSION was not rewritten in $install"

# The other places that name the version, when they exist and name the old one.
compat="$SANDBOX_ROOT/agents/$agent/compat.md"
[ -f "$compat" ] && sed -i -E "/pinned in \`install\.sh\`/ s/ ${old_re}( \()/ ${want}\1/" "$compat"
docs="$SANDBOX_ROOT/docs/05-agents-and-toolchains.md"
[ -f "$docs" ] && sed -i -E "/^Shipped:/ s/(\`${agent}\` \([^)]* )${old_re}\)/\1${want})/" "$docs"
test_install="$SANDBOX_ROOT/tests/images/test-install.sh"
[ -f "$test_install" ] && sed -i -E "s/^( *${agent}\) echo )${old_re}( ;;)\$/\1${want}\2/" "$test_install"

# --- prove it ------------------------------------------------------------------------------
say "running tests/images/test-install.sh"
bash "$test_install" >"$work/test.log" 2>&1 || { cat "$work/test.log" >&2; die "tests/images/test-install.sh failed; the files are changed, read the diff"; }
tail -n 1 "$work/test.log" >&2

# install.sh end to end, with a stand-in npm that hands over the tarballs
# verified above instead of downloading, into a scratch prefix.
mkdir -p "$work/bin"
cat > "$work/bin/npm" <<'NPM'
#!/usr/bin/env bash
# stand-in npm for scripts/pin-cli.sh: `npm pack <spec> --pack-destination <dir> ...`
# copies the tarball already verified for <spec>; anything else fails.
set -eu
[ "${1:-}" = pack ] || { echo "stand-in npm: only pack" >&2; exit 1; }
spec="$2"; shift 2; dest=""
while [ $# -gt 0 ]; do case "$1" in --pack-destination) dest="$2"; shift 2 ;; *) shift ;; esac; done
file="$(awk -F'\t' -v s="$spec" '$1 == s { print $2 }' "$PIN_CLI_MAP")"
[ -n "$file" ] && [ -n "$dest" ] || { echo "stand-in npm: no tarball for $spec" >&2; exit 1; }
cp "$file" "$dest/$(basename "$file")"
NPM
chmod 0755 "$work/bin/npm"
say "running agents/$agent/install.sh against the downloaded tarballs"
if PIN_CLI_MAP="$work/map" SANDBOX_INSTALL_PREFIX="$work/prefix" PATH="$work/bin:$PATH" \
     bash "$install" >"$work/install.out" 2>"$work/install.err"; then
  sed 's/^/  /' "$work/install.err" >&2
else
  cat "$work/install.err" >&2
  die "install.sh failed against the new tarballs; the files are changed, read the diff"
fi
[ "$(tail -n 1 "$work/install.out")" = "$want" ] || die "install.sh printed '$(tail -n 1 "$work/install.out")' as its version, not $want"

# --- done ------------------------------------------------------------------------------
say "done. Changed:"
(cd "$SANDBOX_ROOT" && git --no-pager diff --stat -- "agents/$agent/install.sh" "agents/$agent/compat.md" docs/05-agents-and-toolchains.md tests/images/test-install.sh >&2) || true
if [ "$want" = "$old" ]; then
  say "nothing to commit: $old was already pinned, and its hashes still match the registry."
else
  say "Review with 'git diff', then:"
  say "  git commit -am 'Move $agent to $want'"
  say "  ./sandbox upgrade        # rebuilds the images onto the new pin"
fi
