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
check "the agent image is labelled with the plug-in files it was built from" \
  grep -qE "^build${tab}.*--label${tab}agent-sandbox\.plugin=[0-9]+${tab}.*agent-claude:python-$version" "$log"

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
  grep -qE "^build${tab}.*AGENT=claude${tab}--build-arg${tab}TOOLCHAIN=python${tab}--label${tab}agent-sandbox\.plugin=[0-9]+${tab}--no-cache${tab}--pull.*--tag${tab}localhost/agent-sandbox/agent-claude:python-$version" "$log"
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
case "$out" in *"built from other agents/claude files"*) pass "run says why it rebuilds" ;; *) fail "no reason given in: $out" ;; esac
: > "$log"
"$ROOT/sandbox" run "$T/src" --toolchain python </dev/null >/dev/null 2>&1 || fail "run after the rebuild failed"
if grep -q "^build${tab}" "$log"; then fail "the rebuilt image was rebuilt again"; else pass "the rebuilt image is used from then on"; fi

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
"$ROOT/sandbox" upgrade >/dev/null 2>&1 || fail "upgrade with a pinned CLI failed"
check "the build asks npm too" test "$(grep -c 'dist-tags.latest' "$FAKE_NPM_LOG")" -eq 1
rm -f "$ROOT/agents/claude/install.sh" "$T/bin/npm"

"$ROOT/sandbox" destroy --all >/dev/null 2>&1
printf 'NODE_BASE=UNPINNED\nALPINE_BASE=UNPINNED\n' > "$ROOT/images/PINS"
: > "$log"
says "upgrade refuses unpinned base images" "still UNPINNED" "$ROOT/sandbox" upgrade
if grep -q "^build${tab}" "$log"; then fail "upgrade built from an unpinned base"; else pass "nothing is built from an unpinned base"; fi

finish
