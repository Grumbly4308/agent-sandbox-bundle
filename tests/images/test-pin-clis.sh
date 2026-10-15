#!/usr/bin/env bash
# scripts/pin-clis.sh against a stand-in npm (and a stand-in curl for the
# host without npm): it moves VERSION= and every *_INTEGRITY= line of each
# agents/*/install.sh to what the registry says is the latest, and changes
# nothing else; it refuses, and changes nothing, when the registry cannot be
# trusted for that version.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fake_root="$scratch/root"
mkdir -p "$fake_root/agents" "$scratch/bin"
cp -R "$root/agents/claude" "$root/agents/codex" "$root/agents/opencode" "$fake_root/agents/"
cp -R "$fake_root" "$scratch/root.before"
reset_root() { rm -rf "$fake_root"; cp -R "$scratch/root.before" "$fake_root"; }
unchanged() { diff -r "$scratch/root.before" "$fake_root" >/dev/null; }

# The integrity the stand-ins give a spec: made from the spec, so a test can
# say what it expects.
integrity_for() { printf 'sha512-%s' "$(printf '%s' "$1" | openssl dgst -sha512 -binary | openssl base64 -A)"; }

# `npm view <pkg> dist-tags.latest --registry <r>` answers FAKE_NPM_LATEST
# (`fail`: exits 1). `npm view <pkg>@<ver> --json --registry <r>` answers a
# manifest for that version; FAKE_NPM_DEPS names a package that gets an
# ordinary dependency, FAKE_NPM_BAD_INTEGRITY makes every integrity sha1,
# FAKE_NPM_MISSING names a package the registry does not have.
cat >"$scratch/bin/npm" <<'EOS2'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_NPM_LOG"
[ "$1" = view ] || exit 97
spec="$2"
case "$3" in
  dist-tags.latest)
    [ "${FAKE_NPM_LATEST:-}" != fail ] || exit 1
    printf '%s\n' "$FAKE_NPM_LATEST" ;;
  --json)
    pkg="${spec%@*}"; ver="${spec##*@}"
    integrity="sha512-$(printf '%s' "$spec" | openssl dgst -sha512 -binary | openssl base64 -A)"
    [ -z "${FAKE_NPM_BAD_INTEGRITY:-}" ] || integrity="sha1-deadbeef"
    [ "${FAKE_NPM_MISSING:-}" != "$pkg" ] || exit 1
    deps='{}'
    [ "${FAKE_NPM_DEPS:-}" != "$pkg" ] || deps='{"left-pad":"1.3.0"}'
    printf '{"name":"%s","version":"%s","dependencies":%s,"dist":{"integrity":"%s"}}\n' "$pkg" "$ver" "$deps" "$integrity" ;;
  *) exit 97 ;;
esac
EOS2
chmod +x "$scratch/bin/npm"
export FAKE_NPM_LOG="$scratch/npm.log"
run_pin() {   # [env assignments...] [-- agents...]
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ $# -eq 0 ] || shift
  PATH="$scratch/bin:$PATH" SANDBOX_ROOT="$fake_root" env ${envs[@]+"${envs[@]}"} bash "$root/scripts/pin-clis.sh" "$@"
}

# --- every agent, to a new version ------------------------------------------------
: >"$FAKE_NPM_LOG"
if run_pin FAKE_NPM_LATEST=9.9.9 >"$scratch/pin.out" 2>"$scratch/pin.err"; then
  pass "pin-clis: runs"
else
  fail "pin-clis: failed: $(cat "$scratch/pin.err")"
fi
today="$(date +%Y-%m-%d)"
for agent in claude codex opencode; do
  f="$fake_root/agents/$agent/install.sh"
  check "pin-clis: $agent VERSION moved" grep -qx 'VERSION="9.9.9"' "$f"
  check "pin-clis: $agent 'values read on' date is today" grep -qx "# Values read on $today with" "$f"
  was="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$scratch/root.before/agents/$agent/install.sh")"
  check_not "pin-clis: $agent header commands name the old version no more" grep -q "^#   npm view .*@$was" "$f"
  check "pin-clis: $agent header commands name the new one" grep -q "^#   npm view .*@9\.9\.9" "$f"
  # Each KEY_SPEC's hash is the one the registry gave for the spec at 9.9.9.
  while IFS=' ' read -r key value; do
    # shellcheck disable=SC2016  # install.sh's literal ${VERSION}
    spec="${value//'${VERSION}'/9.9.9}"
    check "pin-clis: $agent ${key}_INTEGRITY is the registry's for $spec" \
      grep -qx "${key}_INTEGRITY=\"$(integrity_for "$spec")\"" "$f"
  done < <(sed -n 's/^\([A-Z0-9_]*\)_SPEC="\(.*\)"$/\1 \2/p' "$f")
  check "pin-clis: $agent executable bit kept" test -x "$f"
  is "pin-clis: $agent old -> new printed" \
    "$(grep -c "^agents/$agent/install.sh: .*: [0-9.]* -> 9.9.9$" "$scratch/pin.out")" 1
done
# Only the pinned lines changed: VERSION, the hashes, the date and the three
# `npm view` lines of each header. claude and codex pin three hashes, opencode four.
# A header whose date is already today (a pin moved by hand today) has no
# date line to change.
dated_today="$(grep -lx "# Values read on $today with" "$scratch"/root.before/agents/*/install.sh | wc -l || true)"
changed="$(diff -r "$scratch/root.before" "$fake_root" | grep -c '^>' || true)"
is "pin-clis: exactly the pinned lines changed" "$changed" "$((3 * 5 + 3 + 3 + 4 - dated_today))"
check "pin-clis: asks for latest once per agent" test "$(grep -c 'dist-tags.latest' "$FAKE_NPM_LOG")" -eq 3
check "pin-clis: asks the registry given" grep -q -- '--registry https://registry.npmjs.org' "$FAKE_NPM_LOG"

# --- already the latest: nothing to do ----------------------------------------------
reset_root
pinned="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$fake_root/agents/claude/install.sh")"
: >"$FAKE_NPM_LOG"
out="$(run_pin FAKE_NPM_LATEST="$pinned" -- claude 2>&1)" || fail "pin-clis: a pin at the latest failed: $out"
case "$out" in *"agents/claude/install.sh: @anthropic-ai/claude-code $pinned (already the latest)"*) pass "pin-clis: says when the pin is the latest" ;; *) fail "pin-clis: no word of the latest in: $out" ;; esac
check "pin-clis: and changes nothing" unchanged
check_not "pin-clis: and reads no manifest" grep -q -- '--json' "$FAKE_NPM_LOG"

# --- one agent named: only that file -----------------------------------------------
run_pin FAKE_NPM_LATEST=9.9.9 -- codex >/dev/null 2>&1 || fail "pin-clis codex failed"
check "pin-clis: the named agent moved" grep -qx 'VERSION="9.9.9"' "$fake_root/agents/codex/install.sh"
check "pin-clis: the others did not" diff "$scratch/root.before/agents/claude/install.sh" "$fake_root/agents/claude/install.sh"
reset_root

# --- refusals: the file stays as it was ---------------------------------------------
refuses() {   # <description> <text expected> [env...]
  local what="$1" text="$2" out
  shift 2
  if out="$(run_pin "$@" -- claude 2>&1)"; then
    fail "pin-clis: $what: carried on: $out"
  else
    case "$out" in *"$text"*) pass "pin-clis: $what" ;; *) fail "pin-clis: $what: wrong reason: $out" ;; esac
  fi
  check "pin-clis: $what: changes nothing" unchanged
}
refuses "stops when the registry cannot be asked" "could not ask" FAKE_NPM_LATEST=fail
refuses "stops on an answer that is not a version" "could not ask" FAKE_NPM_LATEST="$(printf '9.9.9\033[2J')"
refuses "stops when the wrapper gained ordinary dependencies" "ordinary dependencies (left-pad)" \
  FAKE_NPM_LATEST=9.9.9 FAKE_NPM_DEPS=@anthropic-ai/claude-code
refuses "stops on an integrity that is not sha512" "no sha512 integrity" FAKE_NPM_LATEST=9.9.9 FAKE_NPM_BAD_INTEGRITY=1
refuses "stops when a platform package is missing at that version" "has no @anthropic-ai/claude-code-linux-arm64@9.9.9" \
  FAKE_NPM_LATEST=9.9.9 FAKE_NPM_MISSING=@anthropic-ai/claude-code-linux-arm64
check_not "pin-clis: an unknown agent is refused" run_pin FAKE_NPM_LATEST=9.9.9 -- nosuch

# --- without npm: curl and jq ---------------------------------------------------------
# A PATH with only what the script needs, and a curl that answers the two
# registry URLs the way registry.npmjs.org does.
mkdir -p "$scratch/nonpm"
for t in bash jq sed grep date mktemp cat rm head tr openssl env diff; do
  ln -s "$(command -v "$t")" "$scratch/nonpm/$t"
done
cat >"$scratch/nonpm/curl" <<'EOS2'
#!/bin/bash
url="${*: -1}"
printf '%s\n' "$url" >>"$FAKE_CURL_LOG"
case "$url" in
  */-/package/*/dist-tags) printf '{"latest":"%s"}\n' "$FAKE_NPM_LATEST" ;;
  *)
    path="${url#*://*/}"; pkg="${path%/*}"; pkg="${pkg//%2f//}"; ver="${path##*/}"
    integrity="sha512-$(printf '%s' "$pkg@$ver" | openssl dgst -sha512 -binary | openssl base64 -A)"
    printf '{"name":"%s","version":"%s","dist":{"integrity":"%s"}}\n' "$pkg" "$ver" "$integrity" ;;
esac
EOS2
chmod +x "$scratch/nonpm/curl"
export FAKE_CURL_LOG="$scratch/curl.log"
if PATH="$scratch/nonpm" SANDBOX_ROOT="$fake_root" FAKE_NPM_LATEST=8.8.8 bash "$root/scripts/pin-clis.sh" claude >"$scratch/curl.out" 2>"$scratch/curl.err"; then
  pass "pin-clis: runs without npm"
else
  fail "pin-clis: failed without npm: $(cat "$scratch/curl.err")"
fi
check "pin-clis: curl asked for the dist-tags" grep -qx 'https://registry.npmjs.org/-/package/@anthropic-ai%2fclaude-code/dist-tags' "$FAKE_CURL_LOG"
check "pin-clis: curl asked for each manifest, scope encoded" grep -qx 'https://registry.npmjs.org/@anthropic-ai%2fclaude-code-linux-x64/8.8.8' "$FAKE_CURL_LOG"
check "pin-clis: VERSION moved without npm" grep -qx 'VERSION="8.8.8"' "$fake_root/agents/claude/install.sh"
check "pin-clis: hashes moved without npm" \
  grep -qx "X64_INTEGRITY=\"$(integrity_for '@anthropic-ai/claude-code-linux-x64@8.8.8')\"" "$fake_root/agents/claude/install.sh"

finish
