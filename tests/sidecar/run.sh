#!/usr/bin/env bash
# tests/sidecar/run.sh — the credential sidecar's tests. Exit 0 = all passed.
#
# Needs only Node 22: no container runtime, no network, no packages. It
# starts three kinds of ordinary process on this machine's loopback address:
#   tests/sidecar/mock-upstream.mjs   plays the model vendor and records
#                                     every request it is sent
#   images/credsidecar/sidecar.mjs    the real server, as shipped
#   images/credsidecar/sidecar-load   the real loader, fed a fake credential
# and then plays the agent's CLI with a dummy token (tests/sidecar/test.mjs).
# Ports are picked by the kernel; the credential goes to a temporary
# directory that is removed at the end.
#
# What it shows: the vendor is sent the real credential and never the dummy;
# the real one never comes back to the client or into a log; unlisted paths,
# remote-fetch features, oversized bodies and requests past the budget are
# refused before anything is sent. It cannot show that the real vendors
# accept what the sidecar forwards.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "tests/sidecar: node is not installed (Node 22 is needed)" >&2
  exit 1
fi
major="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$major" -lt 22 ]; then
  echo "tests/sidecar: Node 22 or newer is needed, found $(node --version)" >&2
  exit 1
fi

exec node "$here/test.mjs"
