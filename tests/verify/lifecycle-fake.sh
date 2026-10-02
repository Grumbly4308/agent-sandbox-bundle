#!/usr/bin/env bash
# tests/verify/lifecycle-fake.sh — `verify.sh --deadline-test` and
# `--store-test` against a fake `podman`.
#
# These two commands make a session of their own, wait for its time limit,
# export from it and destroy it. Without a container runtime none of that
# can be shown to work. What this test shows is that verify.sh's own logic
# runs from end to end and judges rightly:
#
#   * `./sandbox run` is a stand-in that only records a session (with a time
#     limit of three seconds) and makes a small git repository where the
#     workspace would be. Everything else is the REAL launcher: export and
#     destroy run as shipped, over the fake podman.
#   * The plant script from verify.sh (hostile .git/config and hooks, an
#     attribution trailer, a fake secret, a hidden lockfile change, a
#     symlink, escape sequences in a commit message) runs for real in that
#     repository, the real images/agent/sandbox-bundle bundles it, and the
#     real scripts/export.sh reviews the bundle. So B27 and B32 are judged on
#     what export really prints.
#   * gitleaks is a stand-in: "found something" in the good scenario,
#     "found nothing" in the bad one.
#
# Scenarios: everything as it should be; everything wrong at once (an agent
# that survives its deadline, a host that ran the planted command, export
# printing an escape sequence, a secret scan fooled by the tree, destroy
# leaving a volume); `run` failing. Then the same for the disk store.
#
# Exit 0 = every scenario behaved as expected. Takes about a minute and a
# half: the waits are real.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
for tool in git node shellcheck; do
  command -v "$tool" >/dev/null 2>&1 || { echo "tests/verify: $tool is needed and is not installed" >&2; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/verify-life.XXXXXX")"
trap 'rm -rf "$T"' EXIT
F="$T/fake"

# A copy of the repository's shape: verify.sh, the launcher, export, and the
# files they read, as shipped. doctor is a stand-in (there is no Podman to
# examine).
mkdir -p "$T/root/scripts" "$T/root/images/agent" "$T/bin" "$T/home/config" "$T/store"
cp "$repo/scripts/verify.sh" "$repo/scripts/export.sh" "$repo/scripts/allowlist.sh" "$T/root/scripts/"
cp "$repo/topology.sh" "$repo/VERSION" "$T/root/"
cp "$repo/sandbox" "$T/root/sandbox.real"
cp -R "$repo/policy" "$repo/agents" "$T/root/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/root/scripts/doctor.sh"
chmod +x "$T/root/scripts/doctor.sh"

# `run` is the stand-in; every other command is the real launcher.
cat > "$T/root/sandbox" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
knob() { [ -e "$FAKE/knob.$1" ]; }
if [ "${1:-}" != run ]; then
  if [ "$1" = export ] && knob host-runs-git && [ -f "$FAKE/canary" ]; then
    touch "$(cat "$FAKE/canary")"            # as if git had been run inside the agent's tree
  fi
  status=0
  "$root/sandbox.real" "$@" || status=$?
  if [ "$1" = export ] && knob export-prints-escapes; then printf '\033]0;owned\007\033[2J\n'; fi
  exit "$status"
fi
if knob run-fails; then echo "error: no oauth credential for claude in your keyring"; exit 1; fi
source_repo="$2"; driver=memory; size=1048576
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace-driver) driver="$2" ;;
  esac
  shift
done
session=asb-life-abcdef
dir="$SANDBOX_STATE_DIR/$session"
mkdir -p "$dir/proxy" "$dir/export"
now="$(date +%s)"
store=""; [ "$driver" = local ] && store="$FAKE_STORE"
cat > "$dir/state" <<STATE
SESSION=$session
AGENT=claude
AUTH=oauth
TOOLCHAIN=node
BRANCH=agent/$session
BASE_COMMIT=$(git -C "$source_repo" rev-parse HEAD)
ORIGIN_URL=
DEADLINE_EPOCH=$((now + 3))
SUBNET=10.201.9.0/24
EGRESS_SUBNET=10.202.9.0/24
WORKSPACE_DRIVER=$driver
SERVICES=
GIT_RELAY=0
CREATED_EPOCH=$now
WORKSPACE_BYTES=$size
STORE=$store
STATE
rm -rf "$FAKE/ws"; mkdir -p "$FAKE/ws"
git clone -q "$source_repo" "$FAKE/ws/repo"
git -C "$FAKE/ws/repo" checkout -q -b "agent/$session"
printf '%s running\n' "$session-keeper" "$session-proxy" "$session-credsidecar" "$session-agent" > "$FAKE/containers"
printf '%s\n' "$session-sandbox" "$session-egress" > "$FAKE/networks"
printf '%s\n' "$session-workspace" > "$FAKE/volumes"
printf '%s\n' "$((now + 3))" > "$FAKE/deadline"
rm -f "$FAKE/overwritten"
if [ "$driver" = local ] && ! knob no-watch; then
  # The host's watch: stops the session once its share is exceeded.
  ( while [ ! -e "$FAKE/overwritten" ]; do sleep 1; done
    sleep 2
    sed -i.bak "s/^$session-agent running/$session-agent exited/" "$FAKE/containers"
    echo "its workspace grew past --workspace-size" > "$dir/stopped" ) >/dev/null 2>&1 &
  echo "$!" > "$dir/watchdog.pid"
fi
echo "Session $session runs until soon, at most 500 model requests."
EOF
chmod +x "$T/root/sandbox" "$T/root/sandbox.real"

cat > "$T/bin/gitleaks" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then echo "8.21.2"; exit 0; fi
# FAKE is not passed on by export.sh (it empties the environment), so the
# switch is a file beside this program.
if [ -e "$(dirname "$0")/gitleaks-is-fooled" ]; then echo "no leaks found"; exit 0; fi
echo "leaks found: 1"; exit 1
EOF

cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
# A fake `podman` for tests/verify/lifecycle-fake.sh.
set -u
F="${FAKE:?}"; REPO="${FAKE_REPO:?}"
printf '%s\n' "$*" >> "$F/calls"
knob() { [ -e "$F/knob.$1" ]; }
# After the deadline everything but the keeper is dead, as Podman's own
# timer would leave it.
states() {
  local name state
  [ -f "$F/containers" ] || return 0
  while read -r name state; do
    if [ -f "$F/deadline" ] && [ "$(date +%s)" -ge "$(cat "$F/deadline")" ] && [ "${name##*-}" != keeper ] && ! knob survivor; then state=exited; fi
    printf '%s %s\n' "$name" "$state"
  done < "$F/containers"
}
list() {   # <file> <prefix when a --format asks for one> <arguments of the call>
  local file="$1" prefix=""
  case "$3" in *"$2"*) prefix="$2" ;; esac
  [ -f "$file" ] || return 0
  sed "s/^/$prefix/" "$file"
}
drop() { [ -f "$1" ] && { grep -v "^$2\( \|\$\)" "$1" > "$1.tmp" || true; mv "$1.tmp" "$1"; }; }

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  info) echo false ;;
  ps)
    case "$*" in
      *'.State'*) states ;;
      *'container:'*) states | sed 's/ .*//; s/^/container:/' ;;
      *) states | sed 's/ .*//' ;;
    esac ;;
  network)
    case "$1" in
      ls) list "$F/networks" network: "$*" ;;
      rm) drop "$F/networks" "${*: -1}" ;;
    esac ;;
  volume)
    case "$1" in
      ls) list "$F/volumes" volume: "$*" ;;
      rm) knob undead-volume || drop "$F/volumes" "${*: -1}" ;;
    esac ;;
  rm) drop "$F/containers" "${*: -1}" ;;
  stop) : ;;
  inspect)
    name="${*: -1}"
    case "$2" in
      *'.State.Running'*) if states | grep -q "^$name running"; then echo true; else echo false; fi ;;
      *'.State.Status'*) states | sed -n "s/^$name //p" ;;
    esac ;;
  run)
    # The export helper: the real sandbox-bundle, over the stand-in workspace.
    branch="${*: -1}"
    SANDBOX_WORKSPACE_FOR_TESTS="$F/ws" bash "$REPO/images/agent/sandbox-bundle" "$branch" ;;
  exec)
    while [ $# -gt 0 ]; do
      case "$1" in -i|-d) shift ;; --env) shift 2 ;; *) break ;; esac
    done
    shift      # the container
    case "$1 ${2:-}" in
      "bash -s")
        # The plant script, run for real, in the stand-in workspace and
        # nowhere else: its one `cd` is pointed there.
        printf '%s\n' "$5" > "$F/canary"
        sed "s|^cd /workspace/repo\$|cd '$F/ws/repo'|" > "$F/plant.sh"
        grep -q "^cd '$F/ws/repo'\$" "$F/plant.sh" || { echo "the plant script has no 'cd /workspace/repo' line to redirect"; exit 1; }
        bash "$F/plant.sh" "$4" "$5" "$6" ;;
      "bash -c") : ;;                                   # the fork loop
      "dd "*) : > "$F/overwritten" ;;                  # writing past the session's share
      "sh -c")
        if knob store-never-fills; then echo never-filled
        else echo "dd: error writing '/workspace/.verify-full.3': No space left on device"; fi ;;
    esac ;;
esac
EOF
chmod +x "$T/bin/podman" "$T/bin/gitleaks"
shellcheck "$T/bin/podman" "$T/root/sandbox" || { echo "tests/verify: a stand-in is not shellcheck clean" >&2; exit 1; }

OUT=""; RC=0
verify() {
  rm -rf "$F"; mkdir -p "$F"
  local knob
  for knob in $KNOBS; do : > "$F/knob.$knob"; done
  RC=0
  OUT="$(PATH="$T/bin:$PATH" HOME="$T/home" FAKE="$F" FAKE_REPO="$repo" FAKE_STORE="$T/store" SANDBOX_CONFIG_DIR="$T/home/config" \
         XDG_RUNTIME_DIR="" TMPDIR="$T" bash "$T/root/scripts/verify.sh" "$@" 2>&1)" || RC=$?
}
failures=0; scenarios=0; at_start=0
scenario() { scenarios=$((scenarios + 1)); CURRENT="$1"; at_start=$failures; }
not_ok() { failures=$((failures + 1)); printf 'not ok - %s: %s\n' "$CURRENT" "$1"; }
want_rc() { [ "$RC" -eq "$1" ] || not_ok "exit status $RC, expected $1"; }
want() { printf '%s\n' "$OUT" | grep -qE -- "$1" || not_ok "no line matching /$1/"; }
only_failures() {
  local got want
  got="$(printf '%s\n' "$OUT" | sed -n -e 's/^FAIL \([^ ]*\) .*/\1/p' -e 's/^SKIP \([^ ]*\) .*counts as a failure.*/\1/p' | sort | tr '\n' ' ')"
  want="$(printf '%s\n' "$@" | sort | tr '\n' ' ')"
  [ "$got" = "$want" ] || not_ok "failed checks were [$got], expected [${want# }]"
}
done_scenario() {
  if [ "$failures" -eq "$at_start" ]; then printf 'ok   - %s\n' "$CURRENT"
  elif [ -n "${SHOW:-}" ]; then printf '%s\n' "$OUT" | sed 's/^/     | /'; fi
}
# Nothing of the test may be left in the real repository the tests run from.
head_before="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"

# ---------------------------------------------------------------------------
scenario "--deadline-test: everything as it should be"
rm -f "$T/bin/gitleaks-is-fooled"
KNOBS="" verify --deadline-test
want_rc 0
for name in B26-deadline B26-export-after-deadline B27-git-config-hook B27-attribution B27-secret-scan B27-dependency-diff B27-symlink B27-endless-stream B31-destroy B32-export-filter; do
  want "^PASS $name — "
done
want '^10 passed, 0 failed'
[ -z "$(find "$T" -maxdepth 1 -name 'sandbox-verify.*')" ] || not_ok "verify left its scratch directory behind"
done_scenario

scenario "--deadline-test: everything wrong at once"
: > "$T/bin/gitleaks-is-fooled"
KNOBS="survivor host-runs-git export-prints-escapes undead-volume" verify --deadline-test
rm -f "$T/bin/gitleaks-is-fooled"
want_rc 1
only_failures B26-deadline B27-git-config-hook B27-secret-scan B32-export-filter B31-destroy
want 'FAIL B26-deadline — .*asb-life-abcdef-agent is still running'
want 'FAIL B27-git-config-hook — .*HAD RUN ON THIS HOST'
want 'FAIL B31-destroy — .*volume:asb-life-abcdef-workspace'
done_scenario

scenario "--deadline-test: run brings no session up"
KNOBS="run-fails" verify --deadline-test
want_rc 1
want 'SKIP B26-deadline — \(no-session\).*counts as a failure'
want '^0 passed, 10 failed'
done_scenario

scenario "--store-test: no store configured is a stated skip, not a failure"
rm -f "$T/home/config/settings"
KNOBS="" verify --store-test
want_rc 0; want 'SKIP B33-share-watch — \(no-store\)'; want 'SKIP B33-store-full — \(no-store\)'
done_scenario

printf 'STORE=%s\n' "$T/store" > "$T/home/config/settings"
scenario "--store-test: the watch stops the session, the store fills"
KNOBS="" verify --store-test
want_rc 0; want '^PASS B33-share-watch — '; want '^PASS B33-store-full — '
done_scenario

scenario "--store-test: no watch, and a store that never fills"
KNOBS="no-watch store-never-fills" verify --store-test
want_rc 1; only_failures B33-share-watch B33-store-full
done_scenario

[ "$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)" = "$head_before" ] || { failures=$((failures + 1)); echo "not ok - the test moved HEAD of the real repository"; }
printf '\n%s scenarios, %s assertion(s) failed\n' "$scenarios" "$failures"
[ "$failures" -eq 0 ]
