#!/usr/bin/env bash
# tests/verify/run.sh — the tests of `verify` that need no container runtime.
# Exit 0 = all passed.
#
#   static.sh            shellcheck, bash 3.2 constructs, the two halves agree,
#                        every barrier has a check
#   inside-smoke.sh      images/agent/verify-inside.sh as a plain process on
#                        this machine (a smoke test, NOT a verify result)
#   host-fake-podman.sh  scripts/verify.sh against a fake podman: a good
#                        session passes, some fifty broken ones fail at the
#                        right check
#   lifecycle-fake.sh    --deadline-test and --store-test against a fake
#                        podman, with the real launcher's export and destroy
#
# None of this shows that a barrier holds. Only `./sandbox verify` on a host
# with rootless Podman can; until then every check is "not run".
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
for test in static.sh inside-smoke.sh host-fake-podman.sh lifecycle-fake.sh; do
  printf '\n===== tests/verify/%s =====\n' "$test"
  bash "$here/$test" || { status=1; printf '***** tests/verify/%s FAILED *****\n' "$test"; }
done
exit "$status"
