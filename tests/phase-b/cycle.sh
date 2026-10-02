#!/usr/bin/env bash
# The full cycle on a real host with rootless Podman:
#   doctor -> run -> verify -> export -> destroy, then check nothing is left.
#
# NOT run in Phase A: the machine this was written on has no container
# runtime. PHASE-B.md says what to do before running it and what each failure
# means. It is not part of `make test`.
#
#   SANDBOX_TEST_ANTHROPIC_KEY=sk-ant-... tests/phase-b/cycle.sh
#
# The key must come from a dedicated workspace with a spend cap. It is read
# from that variable by ./sandbox (API-key mode, Claude only) and piped to the
# credential sidecar; it never enters the agent's container. ANTHROPIC_API_KEY
# is never used.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

: "${SANDBOX_TEST_ANTHROPIC_KEY:?set it to an API key from a dedicated workspace with a spend cap}"
url_repo="${SANDBOX_TEST_REPO_URL:-https://github.com/jonschlinkert/is-number}"

work="$(mktemp -d)"
# Sessions made by this script are kept apart from your own.
export SANDBOX_STATE_DIR="$work/state"
export SANDBOX_CONFIG_DIR="$work/config"
# Small sizes: the test repositories are tiny, and with these a session may
# take about 4.6 GB of the host's memory instead of the default 10.5 GB.
mkdir -p "$SANDBOX_CONFIG_DIR"
printf '%s\n' MEM=2g WORKSPACE_SIZE=1g TMP_SIZE=512m HOME_SIZE=512m > "$SANDBOX_CONFIG_DIR/settings"

step() { printf '\n==== %s\n' "$*"; }
problems=0
problem() { printf 'PROBLEM: %s\n' "$*"; problems=$((problems + 1)); }

cleanup() {
  ./sandbox destroy --all >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# One cycle: run the agent on a repository with a small task, verify, export,
# destroy, and check that nothing with the session's label is left.
cycle() {   # <what> <repository> <prompt>
  local what="$1" repo="$2" prompt="$3" session status=0 left

  step "$what: run"
  ./sandbox run "$repo" --agent claude --auth apikey --strict --auto \
    --ttl 30m --budget 40 -- -p "$prompt" || problem "$what: run exited $?"

  session="$(find "$SANDBOX_STATE_DIR" -mindepth 1 -maxdepth 1 -type d -name 'asb-*' -exec basename {} \; | head -n 1)"
  if [ -z "$session" ]; then
    problem "$what: no session was created"
    return 0
  fi
  export SANDBOX_SESSION="$session"

  step "$what: verify (every check, on session $session)"
  ./sandbox verify || problem "$what: verify reported a failed check"

  step "$what: export"
  ./sandbox export --out "$work/out" || status=$?
  # 0 = clean. 2 = exported, but something needs a person (for example
  # gitleaks is not installed). Anything else is a failure.
  case "$status" in
    0) ;;
    2) problem "$what: export needs a human; read its output above" ;;
    *) problem "$what: export failed with status $status" ;;
  esac
  [ -d "$work/out/$session/repo.git" ] || problem "$what: no exported repository"

  step "$what: destroy"
  ./sandbox destroy || problem "$what: destroy exited $?"
  left="$(podman ps -a --filter "label=agent-sandbox.session=$session" --format '{{.Names}}'
          podman volume ls --filter "label=agent-sandbox.session=$session" --format '{{.Name}}'
          podman network ls --filter "label=agent-sandbox.session=$session" --format '{{.Name}}')"
  [ -z "$left" ] || problem "$what: left behind after destroy: $left"
  [ ! -e "$SANDBOX_STATE_DIR/$session" ] || problem "$what: the session directory is still there"
  unset SANDBOX_SESSION
}

step "doctor"
./sandbox doctor || problem "doctor reported a red line"

# Path mode: the fixture, as a repository of its own.
cp -R tests/fixtures/mini-node "$work/mini-node"
git -C "$work/mini-node" init -q
git -C "$work/mini-node" add -A
git -C "$work/mini-node" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "fixture"
cycle "path mode" "$work/mini-node" \
  "Add a function isBlank(s) to slugify.js that returns true for empty or whitespace-only strings, add a test for it, run the tests with 'node --test', and commit."

# URL mode: a small public repository, cloned on the host.
cycle "URL mode" "$url_repo" \
  "Read the README, run the tests if the project has any, and commit a one-line addition to the README describing what you ran."

# The long-running checks have commands of their own.
step "verify: the deadline, export and destroy checks (creates its own short session)"
scripts/verify.sh --deadline-test || problem "the deadline test reported a failed check"

printf '\n'
if [ "$problems" -gt 0 ]; then
  printf '%s problem(s). Record each one in PHASE-B.md and fix the cause, not the check.\n' "$problems"
  exit 1
fi
printf 'The cycle completed: doctor, run, verify, export and destroy, in path mode and URL mode.\n'
