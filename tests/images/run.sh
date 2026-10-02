#!/usr/bin/env bash
# Run every test in this directory. Exit status 1 if any of them fails.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
for t in "$here"/test-*.sh; do
  printf '\n== %s\n' "$(basename "$t")"
  bash "$t" || failed=$((failed + 1))
done
printf '\n'
if [ "$failed" -gt 0 ]; then
  echo "tests/images: $failed test file(s) failed"
  exit 1
fi
echo "tests/images: all test files passed"
