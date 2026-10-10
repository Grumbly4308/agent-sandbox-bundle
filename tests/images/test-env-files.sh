#!/usr/bin/env bash
# agents/<name>/env, for the agents that have one: NAME=value lines and
# nothing else (a bare NAME would copy that variable in from the operator's
# own environment), no secrets, and no address: addresses differ from session
# to session and are set by topology.sh and the launch scripts.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for agent in claude opencode; do
  file="$root/agents/$agent/env"
  if [ ! -f "$file" ]; then
    fail "$agent: env is missing"
    continue
  fi
  n=0 bad=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if ! [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=.+$ ]]; then
      fail "$agent: env line $n is not NAME=value: '$line'"
      bad=1
    fi
  done <"$file"
  if [ "$bad" -eq 0 ] && [ "$n" -gt 0 ]; then pass "$agent: env has only NAME=value lines ($n)"; fi

  if [ -n "$(tail -c 1 "$file")" ]; then fail "$agent: env does not end with a newline"; else pass "$agent: env ends with a newline"; fi

  # No credential, not even a dummy one: those are set by launch, by mode.
  if grep -qE '^[A-Za-z0-9_]*(_KEY|_TOKEN|_SECRET|PASSWORD)=' "$file"; then
    fail "$agent: env sets something named like a secret"
  else
    pass "$agent: env sets nothing named like a secret"
  fi

  # No address at all: a name would not resolve (no container is found by
  # name), and an address is only known once the session exists.
  if grep -qE '[a-z]+://' "$file"; then
    fail "$agent: env holds an address"
  else
    pass "$agent: env holds no address"
  fi

  # No name twice.
  if [ -n "$(cut -d= -f1 "$file" | sort | uniq -d)" ]; then
    fail "$agent: env sets a name twice"
  else
    pass "$agent: env sets each name once"
  fi

  # The proxy variables belong to topology.sh, not to a plug-in.
  check_not "$agent: env leaves the proxy variables alone" grep -qiE '^(https?_proxy|no_proxy)=' "$file"
done

# shellcheck disable=SC2016  # the text searched for, not a variable of this script
check "claude: launch takes the base URL from the session's sidecar address" \
  grep -q '^export ANTHROPIC_BASE_URL="${SANDBOX_SIDECAR_URL:?' "$root/agents/claude/launch"
for name in CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL DISABLE_AUTOUPDATER; do
  check "claude: $name=1" grep -qx "$name=1" "$root/agents/claude/env"
done
check_not "claude: the first-party override is not set anywhere executable" \
  grep -q '_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL' "$root/agents/claude/env" "$root/agents/claude/launch"
check_not "codex: has no env file (every setting of its is written by launch)" test -e "$root/agents/codex/env"
for agent in claude codex opencode; do
  check_not "$agent: launch names no container by name" grep -qE '//(sidecar|proxy|gitrelay)\b' "$root/agents/$agent/launch"
done
check "opencode: models fetch off" grep -qx 'OPENCODE_DISABLE_MODELS_FETCH=1' "$root/agents/opencode/env"
check "opencode: auto-update off" grep -qx 'OPENCODE_DISABLE_AUTOUPDATE=1' "$root/agents/opencode/env"

# Every variable an env file sets is explained in that agent's compat.md.
for agent in claude codex opencode; do
  if [ -f "$root/agents/$agent/env" ]; then
    while IFS='=' read -r name _; do
      check "$agent: compat.md explains $name" grep -q "$name" "$root/agents/$agent/compat.md"
    done <"$root/agents/$agent/env"
  fi
  check "$agent: compat.md explains SANDBOX_SIDECAR_URL" grep -q 'SANDBOX_SIDECAR_URL' "$root/agents/$agent/compat.md"
  check "$agent: compat.md says nothing in it is a control" grep -q 'Nothing on this page is a control' "$root/agents/$agent/compat.md"
  check "$agent: compat.md has a 'Proven necessary' column" grep -q '| Proven necessary |' "$root/agents/$agent/compat.md"
  check "$agent: auth.md exists and covers revoking" grep -q '^## Revoking' "$root/agents/$agent/auth.md"
done
check "opencode: auth.md says oauth is refused" grep -q 'auth oauth` is refused' "$root/agents/opencode/auth.md"

finish
