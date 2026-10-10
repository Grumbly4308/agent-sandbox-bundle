#!/usr/bin/env bash
# Tests for the git relay [logical B30]. Plain processes: node's built-in test
# runner and the real git client. No container, no network beyond 127.0.0.1,
# nothing installed.
#
#   filter.test.mjs  the pkt-line reader and the push filter, with hand-made bodies
#   http.test.mjs    the relay as an HTTP server in front of a recording mock
#   e2e.test.mjs     real `git` through the relay to `git http-backend`, then
#                    the same over HTTPS through a mock CONNECT proxy
#
# The end-to-end file skips itself, and says UNPROVEN, when `git http-backend`
# (or, for its HTTPS half, `openssl`) is not installed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v node >/dev/null || { echo "gitrelay tests: node is not installed" >&2; exit 1; }
command -v git >/dev/null || { echo "gitrelay tests: git is not installed" >&2; exit 1; }

# The tests talk to 127.0.0.1 only. A proxy set in this shell must not get in
# between, and this machine's git configuration must not change the result.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy

cd "$here"
exec node --test filter.test.mjs http.test.mjs e2e.test.mjs
