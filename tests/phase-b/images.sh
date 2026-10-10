#!/usr/bin/env bash
# Build and verify the images for the agents the cycle does not exercise
# (Codex, OpenCode), and the python and full toolchains. Passed on a real
# host on 2026-10-10 (docs/08-verification.md).
#
# No vendor is contacted with a real credential: each session's sidecar is
# given a made-up key, typed in below, and the CLI is only asked for its
# version. What this proves is that each image builds, each CLI starts from
# the unpacked install, and the barrier checks `run --strict` makes before it
# attaches pass on that image. (A second `./sandbox verify` afterwards would
# have no credential to search the container for: the key was typed in.)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

# This script ends with `destroy --all`, which removes every session on this
# Podman, yours included. So it does not start while one exists.
if [ -n "$(podman ps -a --filter label=agent-sandbox.session --format '{{.Names}}' 2>/dev/null)" ]; then
  echo "There are sandbox sessions on this host. Export what you need, run ./sandbox destroy --all, then start again." >&2
  exit 1
fi

# Your own settings file, read below for the disk store before this script
# switches to a settings file of its own.
own_settings="${SANDBOX_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-sandbox}/settings"
work="$(mktemp -d)"
export SANDBOX_STATE_DIR="$work/state"
export SANDBOX_CONFIG_DIR="$work/config"
# Small sizes: the test repositories are tiny, and with these a session takes
# far less of the host's memory than with the defaults.
mkdir -p "$SANDBOX_CONFIG_DIR"
printf '%s\n' MEM=2g WORKSPACE_SIZE=1g TMP_SIZE=512m HOME_SIZE=512m > "$SANDBOX_CONFIG_DIR/settings"
# The disk store, if this host has one: the one your own settings name, or
# the one at the usual place. With it the workspace is on disk, which is the
# default; without it, it is held in memory.
store="$(sed -n 's/^STORE=//p' "$own_settings" 2>/dev/null | tail -n 1)"
if [ -z "$store" ] && mountpoint -q /var/lib/agent-sandbox-store 2>/dev/null; then
  store=/var/lib/agent-sandbox-store
fi
if [ -n "$store" ]; then
  printf 'STORE=%s\n' "$store" >> "$SANDBOX_CONFIG_DIR/settings"
  printf 'Workspaces: on the disk store at %s.\n' "$store"
else
  printf 'Workspaces: held in memory (this host has no disk store; ./sandbox doctor says how to make one).\n'
fi
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
  if ! printf 'sk-phase-b-not-a-real-key-0123456789abcdefABCDEF\n' |
    ./sandbox run "$work/mini-node" --agent "$agent" --auth apikey \
      --toolchain "$toolchain" --strict --ttl 15m --budget 1 -- --version; then
    printf 'PROBLEM: run failed for %s (build, barrier checks, or the CLI itself)\n' "$combo"
    problems=$((problems + 1))
  fi
  ./sandbox destroy --all >/dev/null 2>&1 || true
done

[ "$problems" -eq 0 ] || { printf '\n%s problem(s)\n' "$problems"; exit 1; }
printf '\nEvery image built, passed the barrier checks at run, and started its CLI.\n'
