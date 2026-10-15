#!/usr/bin/env bash
# Every shell file of this component parses (bash -n) and is shellcheck
# clean.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

files=(
  "$root/images/agent/sandbox-idle"
  "$root/images/agent/sandbox-import"
  "$root/images/agent/sandbox-bundle"
  "$root/images/agent/sandbox-launch"
  "$root/images/agent/make-sbom.sh"
  "$root/scripts/make-seccomp.sh"
  "$root/scripts/pin-images.sh"
  "$root/scripts/pin-clis.sh"
)
for agent in claude codex opencode; do
  files+=("$root/agents/$agent/install.sh" "$root/agents/$agent/launch")
done
for t in "$root"/tests/images/*.sh; do
  files+=("$t")
done

command -v shellcheck >/dev/null || fail "shellcheck is not installed"

for f in "${files[@]}"; do
  name="${f#"$root"/}"
  if [ ! -f "$f" ]; then
    fail "$name is missing"
    continue
  fi
  check "$name: starts with #!/usr/bin/env bash or is sourced" \
    grep -qE '^(#!/usr/bin/env bash|# shellcheck shell=bash)$' <(head -n 1 "$f")
  check "$name: bash -n" bash -n "$f"
  if out="$(shellcheck -x "$f" 2>&1)"; then
    pass "$name: shellcheck"
  else
    fail "$name: shellcheck"
    printf '%s\n' "$out"
  fi
  case "$name" in
    tests/* | */lib.sh) ;;
    *) check "$name: set -euo pipefail" grep -q '^set -euo pipefail$' "$f" ;;
  esac
done

for f in sandbox-idle sandbox-import sandbox-bundle sandbox-launch; do
  check "images/agent/$f is executable" test -x "$root/images/agent/$f"
done
for agent in claude codex opencode; do
  check "agents/$agent/launch is executable" test -x "$root/agents/$agent/launch"
done

finish
