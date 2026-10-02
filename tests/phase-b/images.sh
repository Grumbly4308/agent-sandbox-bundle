#!/usr/bin/env bash
# Build and verify the images for the agents the cycle does not exercise
# (Codex, OpenCode), and the python and full toolchains. NOT run in Phase A.
#
# No vendor is contacted with a real credential: each session's sidecar is
# given a made-up key, typed in below, and the CLI is only asked for its
# version. What this proves is that each image builds, each CLI starts from
# the unpacked install, and every barrier check passes on that image.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

work="$(mktemp -d)"
export SANDBOX_STATE_DIR="$work/state"
export SANDBOX_CONFIG_DIR="$work/config"
trap './sandbox destroy --all >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

cp -R tests/fixtures/mini-node "$work/mini-node"
git -C "$work/mini-node" init -q
git -C "$work/mini-node" add -A
git -C "$work/mini-node" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "fixture"

problems=0
for combo in codex:node opencode:node claude:python claude:full; do
  agent="${combo%%:*}" toolchain="${combo##*:}"
  printf '\n==== %s, toolchain %s\n' "$agent" "$toolchain"
  # The made-up key is given on standard input, where ./sandbox reads a
  # credential when there is none in the keyring.
  if printf 'sk-phase-b-not-a-real-key-0123456789abcdefABCDEF\n' |
    ./sandbox run "$work/mini-node" --agent "$agent" --auth apikey \
      --toolchain "$toolchain" --strict --ttl 15m --budget 1 -- --version; then
    SANDBOX_SESSION="$(find "$SANDBOX_STATE_DIR" -mindepth 1 -maxdepth 1 -type d -name 'asb-*' -exec basename {} \; | head -n 1)"
    export SANDBOX_SESSION
    ./sandbox verify --quick || { printf 'PROBLEM: verify failed for %s\n' "$combo"; problems=$((problems + 1)); }
  else
    printf 'PROBLEM: run failed for %s\n' "$combo"
    problems=$((problems + 1))
  fi
  ./sandbox destroy --all >/dev/null 2>&1 || true
  unset SANDBOX_SESSION
done

[ "$problems" -eq 0 ] || { printf '\n%s problem(s)\n' "$problems"; exit 1; }
printf '\nEvery image built, started and passed verify --quick.\n'
