#!/usr/bin/env bash
# Building images: `run` builds what is missing, from pinned bases only, and
# `upgrade` rebuilds every image from scratch and shows what changed.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup
make_root
make_repo "$T/src"
log="$FAKE_PODMAN_LOG"
tab="$(printf '\t')"
version="$(cat "$REPO/VERSION")"
export SANDBOX_TEST_ANTHROPIC_KEY="sk-ant-test-0123456789"
export FAKE_PODMAN_IMAGES=absent

says "upgrade with no image built yet says so" "there is no agent-sandbox image here yet" "$ROOT/sandbox" upgrade

# --- run builds what is missing ---------------------------------------------------
"$ROOT/sandbox" run "$T/src" --toolchain python </dev/null >/dev/null 2>&1 || fail "run failed"
before "images are built before anything is created" "^build${tab}" "^network${tab}create"
agent_build="$(grep "^build${tab}.*agent-claude:python-$version" "$log" || true)"
case "$agent_build" in
  *"--build-arg${tab}AGENT=claude${tab}--build-arg${tab}TOOLCHAIN=python"*) pass "the agent image is built for this agent and toolchain" ;;
  *) fail "agent build was: $agent_build" ;;
esac
case "$agent_build" in
  *"--build-arg${tab}NODE_BASE=docker.io/library/node:22-bookworm-slim@sha256:1111"*) pass "the pinned base image is passed in" ;;
  *) fail "no pinned base in: $agent_build" ;;
esac
case "$agent_build" in
  *"--file${tab}$ROOT/images/agent/Containerfile${tab}$ROOT") pass "agent image: context is the repository root" ;;
  *) fail "agent build context: $agent_build" ;;
esac
check "credsidecar image: context is the repository root" \
  grep -qE "^build${tab}.*--tag${tab}localhost/agent-sandbox/credsidecar:$version${tab}--file${tab}$ROOT/images/credsidecar/Containerfile${tab}$ROOT$" "$log"
check "proxy image: context is its own directory" \
  grep -qE "^build${tab}.*--tag${tab}localhost/agent-sandbox/proxy:$version${tab}--file${tab}$ROOT/images/proxy/Containerfile${tab}$ROOT/images/proxy$" "$log"
if grep -q "^build${tab}.*gitrelay" "$log"; then fail "the git relay image was built without --git-relay"; else pass "the git relay image is not built unless asked for"; fi
if grep -qE "^build${tab}.*(--no-cache|--pull)" "$log"; then fail "an ordinary build ignored the cache"; else pass "an ordinary build uses the cache"; fi
check "the agent image is labelled with the files it was built from" \
  grep -qE "^build${tab}.*--label${tab}agent-sandbox\.inputs=[0-9]+${tab}.*agent-claude:python-$version" "$log"

: > "$log"
"$ROOT/sandbox" run "$T/src" --toolchain python </dev/null >/dev/null 2>&1 || fail "second run failed"
if grep -q "^build${tab}" "$log"; then fail "existing images were rebuilt at run"; else pass "images that exist are not rebuilt at run"; fi


# --- upgrade ----------------------------------------------------------------------
: > "$log"
out="$(FAKE_PODMAN_VERSIONS_OLD="$(printf 'sandbox=2.0.0\nclaude-code=2.1.283')" \
       FAKE_PODMAN_VERSIONS_NEW="$(printf 'sandbox=2.0.0\nclaude-code=2.1.290')" \
       "$ROOT/sandbox" upgrade 2>&1)" || fail "upgrade failed: $out"
check "every image that exists is rebuilt" test "$(grep -c "^build${tab}" "$log")" -eq 3
check "each rebuild ignores the cache and re-pulls the base" test "$(grep -c "^build${tab}.*--no-cache${tab}--pull" "$log")" -eq 3
check "the agent image keeps its agent and toolchain" \
  grep -qE "^build${tab}.*AGENT=claude${tab}--build-arg${tab}TOOLCHAIN=python${tab}--label${tab}agent-sandbox\.inputs=[0-9]+${tab}--no-cache${tab}--pull.*--tag${tab}localhost/agent-sandbox/agent-claude:python-$version" "$log"
check "versions are read from an image with no network" \
  grep -qE "^run${tab}--rm${tab}--network${tab}none${tab}.*--entrypoint${tab}cat${tab}localhost/agent-sandbox/.*${tab}/usr/share/sandbox/versions$" "$log"
case "$out" in *"claude-code 2.1.283 -> 2.1.290"*) pass "upgrade prints old -> new versions" ;; *) fail "no version change in: $out" ;; esac
case "$out" in *"sandbox 2.0.0 (unchanged)"*) pass "and says what did not change" ;; *) fail "no unchanged line in: $out" ;; esac

# --- a changed plug-in rebuilds the agent image -----------------------------------
# The tag stays the same when a CLI pin or launch changes; the label does not.
printf '%s\n' '# stand-in, changed' 'DISABLE_AUTOUPDATER=1' > "$ROOT/agents/claude/env"
: > "$log"
out="$("$ROOT/sandbox" run "$T/src" --toolchain python </dev/null 2>&1)" || fail "run after a plug-in change failed: $out"
check "a changed plug-in rebuilds the agent image" grep -qE "^build${tab}.*agent-claude:python-$version" "$log"
if grep -qE "^build${tab}.*(proxy|credsidecar):" "$log"; then fail "a changed plug-in rebuilt other images"; else pass "and only the agent image"; fi
case "$out" in *"built from other files than these (images/agent agents/claude images/PINS)"*) pass "run says why it rebuilds" ;; *) fail "no reason given in: $out" ;; esac
: > "$log"
"$ROOT/sandbox" run "$T/src" --toolchain python </dev/null >/dev/null 2>&1 || fail "run after the rebuild failed"
if grep -q "^build${tab}" "$log"; then fail "the rebuilt image was rebuilt again"; else pass "the rebuilt image is used from then on"; fi

# --- so does any other image's ---------------------------------------------------
mkdir -p "$ROOT/images/credsidecar"
printf '// changed\n' > "$ROOT/images/credsidecar/sidecar-load"
: > "$log"
out="$("$ROOT/sandbox" run "$T/src" --toolchain python </dev/null 2>&1)" || fail "run after a sidecar change failed: $out"
check "a changed sidecar rebuilds the sidecar image" grep -qE "^build${tab}.*credsidecar:$version" "$log"
if grep -qE "^build${tab}.*(agent-claude|proxy):" "$log"; then fail "a changed sidecar rebuilt other images"; else pass "and only that image"; fi
check "the sidecar image is labelled with the files it was built from" \
  grep -qE "^build${tab}.*--label${tab}agent-sandbox\.inputs=[0-9]+${tab}.*credsidecar:$version" "$log"
# The sidecar image carries every agent's routes, not only this session's.
mkdir -p "$ROOT/agents/opencode" && printf '{}\n' > "$ROOT/agents/opencode/sidecar.json"
: > "$log"
"$ROOT/sandbox" run "$T/src" --toolchain python </dev/null >/dev/null 2>&1 || fail "run after a route change failed"
check "a changed agents/*/sidecar.json rebuilds the sidecar image too" grep -qE "^build${tab}.*credsidecar:$version" "$log"
rm -rf "$ROOT/agents/opencode"

# --- the pinned CLI is compared with npm's latest --------------------------------
# shellcheck disable=SC2016  # install.sh's own ${VERSION}, written literally
printf '%s\n' '# stand-in' 'VERSION="2.1.296"' 'WRAPPER_SPEC="@anthropic-ai/claude-code@${VERSION}"' \
  > "$ROOT/agents/claude/install.sh"
cat > "$T/bin/npm" <<'EOF'
#!/bin/sh
# stand-in: `npm view <package> dist-tags.latest` answers FAKE_NPM_LATEST
printf '%s\n' "$*" >> "$FAKE_NPM_LOG"
[ "${FAKE_NPM_LATEST:-}" != fail ] || exit 1
printf '%s\n' "$FAKE_NPM_LATEST"
EOF
chmod +x "$T/bin/npm"
export FAKE_NPM_LOG="$T/npm.log"
out="$(FAKE_NPM_LATEST=2.1.296 "$ROOT/sandbox" run "$T/src" --toolchain python </dev/null 2>&1)" || fail "run with the latest CLI failed: $out"
case "$out" in *"npm's latest"*|*"could not ask npm"*) fail "a warning with the latest CLI pinned: $out" ;; *) pass "no warning when the pin is npm's latest" ;; esac
check "npm is asked for the pinned package" grep -qx "view @anthropic-ai/claude-code dist-tags.latest --registry https://registry.npmjs.org" "$FAKE_NPM_LOG"
out="$(FAKE_NPM_LATEST=2.1.300 "$ROOT/sandbox" run "$T/src" --toolchain python </dev/null 2>&1)" || fail "run with an older pin failed: $out"
case "$out" in
  *"pins @anthropic-ai/claude-code 2.1.296; npm's latest is 2.1.300"*) pass "an older pin is warned about, with both versions" ;;
  *) fail "no warning for an older pin in: $out" ;;
esac
case "$out" in *"error:"*) fail "an older pin stopped the session: $out" ;; *) pass "and the session starts all the same" ;; esac
out="$(FAKE_NPM_LATEST=fail "$ROOT/sandbox" run "$T/src" --toolchain python </dev/null 2>&1)" || fail "run without the registry failed: $out"
case "$out" in *"could not ask npm which @anthropic-ai/claude-code is the latest; carrying on with the pinned 2.1.296"*) pass "an unreachable registry is said, not fatal" ;; *) fail "no word of the registry in: $out" ;; esac
out="$(FAKE_NPM_LATEST="$(printf '9.9.9\033[2J')" "$ROOT/sandbox" run "$T/src" --toolchain python </dev/null 2>&1)" || fail "run with a garbled answer failed: $out"
case "$out" in *"could not ask npm"*) pass "an answer that is not a version is not printed" ;; *) fail "a garbled answer was trusted: $out" ;; esac
: > "$FAKE_NPM_LOG"
: > "$log"
FAKE_NPM_LATEST=2.1.296 "$ROOT/sandbox" upgrade --keep-clis >/dev/null 2>&1 || fail "upgrade --keep-clis with a pinned CLI failed"
check "upgrade --keep-clis asks npm too" test "$(grep -c 'dist-tags.latest' "$FAKE_NPM_LOG")" -eq 1

# --- upgrade moves the CLI pins first --------------------------------------------
# scripts/pin-clis.sh stands in: it notes the agents it was given and moves
# VERSION= to FAKE_PIN_LATEST; `fail` makes it refuse. (The real script is
# tested in tests/images/test-pin-clis.sh.)
cat > "$ROOT/scripts/pin-clis.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_PIN_LOG"
[ "${FAKE_PIN_LATEST:-}" != fail ] || { echo "pin-clis: stand-in refuses" >&2; exit 1; }
for agent in "$@"; do
  sed -i.bak "s/^VERSION=.*/VERSION=\"$FAKE_PIN_LATEST\"/" "$SANDBOX_ROOT/agents/$agent/install.sh" && rm -f "$SANDBOX_ROOT/agents/$agent/install.sh.bak"
  echo "agents/$agent/install.sh: moved to $FAKE_PIN_LATEST"
done
EOF
chmod +x "$ROOT/scripts/pin-clis.sh"
export FAKE_PIN_LOG="$T/pin.log"
: > "$FAKE_PIN_LOG"
: > "$FAKE_NPM_LOG"
: > "$log"
out="$(FAKE_PIN_LATEST=2.1.300 FAKE_NPM_LATEST=2.1.300 "$ROOT/sandbox" upgrade 2>&1)" || fail "upgrade failed: $out"
check "upgrade moves the pins of the agents whose images are here, before building" grep -qx "claude" "$FAKE_PIN_LOG"
check "the pin was moved" grep -qx 'VERSION="2.1.300"' "$ROOT/agents/claude/install.sh"
case "$out" in *"moved to 2.1.300"*) pass "upgrade shows what pin-clis did" ;; *) fail "pin-clis's output is missing from: $out" ;; esac
check "every image is still rebuilt" test "$(grep -c "^build${tab}" "$log")" -eq 3
check "the build does not ask npm again after the pins were moved" test "$(grep -c 'dist-tags.latest' "$FAKE_NPM_LOG")" -eq 0
case "$out" in *"npm's latest"*) fail "a stale-pin warning after the pins were moved: $out" ;; *) pass "and does not warn about a stale pin" ;; esac
: > "$FAKE_PIN_LOG"
: > "$log"
"$ROOT/sandbox" upgrade --keep-clis >/dev/null 2>&1 || fail "upgrade --keep-clis failed"
check "--keep-clis does not run pin-clis" test ! -s "$FAKE_PIN_LOG"
check "and still rebuilds" test "$(grep -c "^build${tab}" "$log")" -eq 3
: > "$log"
out="$(FAKE_PIN_LATEST=fail "$ROOT/sandbox" upgrade 2>&1)" && fail "upgrade carried on after pin-clis refused"
case "$out" in *"stand-in refuses"*"the CLI pins were not moved"*"--keep-clis"*) pass "a refused pin stops upgrade, with pin-clis's reason and the way round" ;; *) fail "no refusal in: $out" ;; esac
if grep -q "^build${tab}" "$log"; then fail "upgrade built after pin-clis refused"; else pass "and nothing is built"; fi
says "upgrade takes no other option" "usage: ./sandbox upgrade [--keep-clis]" "$ROOT/sandbox" upgrade --now
rm -f "$ROOT/agents/claude/install.sh" "$T/bin/npm" "$ROOT/scripts/pin-clis.sh"

"$ROOT/sandbox" destroy --all >/dev/null 2>&1
printf 'NODE_BASE=UNPINNED\nALPINE_BASE=UNPINNED\n' > "$ROOT/images/PINS"
: > "$log"
says "upgrade refuses unpinned base images" "still UNPINNED" "$ROOT/sandbox" upgrade
if grep -q "^build${tab}" "$log"; then fail "upgrade built from an unpinned base"; else pass "nothing is built from an unpinned base"; fi

finish
