#!/usr/bin/env bash
# Run every test that needs no container runtime.
#
#   tests/run.sh            everything
#   tests/run.sh sidecar    one directory under tests/
#
# These tests prove what the code asks Podman for and how the host-side parts
# behave. They do NOT prove that Podman does it: that is `./sandbox verify` on
# a real host, listed in PHASE-B.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

failed=""
run() {
  printf '== %s\n' "$*"
  if "$@" > "$log" 2>&1; then
    tail -n 1 "$log"
  else
    cat "$log"
    failed="$failed $*"
  fi
}

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

only="${1:-}"

if [ -z "$only" ] || [ "$only" = lint ]; then
  # Every shell file in the repository, found by its first line or its name.
  files=()
  while IFS= read -r f; do
    case "$f" in
      *.sh) files+=("$f") ;;
      *) if head -n 1 "$f" | grep -qE '^#!.*\b(ba)?sh\b'; then files+=("$f"); fi ;;
    esac
  done < <(git ls-files --cached --others --exclude-standard | grep -v '^reference/')
  run shellcheck -x "${files[@]}"
fi

for dir in tests/*/; do
  name="$(basename "$dir")"
  case "$name" in fakes | fixtures) continue ;; esac
  [ -z "$only" ] || [ "$only" = "$name" ] || continue
  if [ -f "$dir/run.sh" ]; then
    run bash "$dir/run.sh"
    continue
  fi
  for t in "$dir"*.sh; do
    [ -e "$t" ] || continue
    case "$(basename "$t")" in lib.sh) continue ;; esac
    run bash "$t"
  done
done

if [ -z "$only" ] || [ "$only" = fixtures ]; then
  run sh -c 'cd tests/fixtures/mini-node && node --test'
fi

if [ -n "$failed" ]; then
  printf '\nFAILED:%s\n' "$failed"
  exit 1
fi
printf '\nAll static tests passed. No barrier has been verified against Podman by this run.\n'
