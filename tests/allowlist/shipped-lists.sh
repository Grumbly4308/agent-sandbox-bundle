#!/usr/bin/env bash
# The lists that ship with agent-sandbox, rendered for every agent.
#   * [logical B21] the model vendor's hosts are in sidecar.domains and
#     nowhere in agent.domains;
#   * github.com is on no default list;
#   * the github-downloads preset adds exactly its three hosts;
#   * every shipped entry carries a reason.
# Runs as a plain process; nothing here needs a container.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SANDBOX_ROOT="$root"
# shellcheck source-path=SCRIPTDIR source=../../scripts/allowlist.sh
source "$root/scripts/allowlist.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SANDBOX_CONFIG_DIR="$tmp/config"
export ALLOWLIST_TODAY=2026-06-15

fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

in_list() { grep -qxF -- "$2" "$1"; }

# covered <file> <host>: true when a line of the file would let <host>
# through, as a name or as a pattern above it.
covered() {
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if _allowlist_covers "$entry" "$2"; then
      return 0
    fi
  done < "$1"
  return 1
}

# What each shipped agent's sidecar must be able to reach.
vendor_hosts() {
  case "$1" in
    claude)   echo api.anthropic.com ;;
    codex)    echo chatgpt.com api.openai.com ;;
    opencode) echo api.anthropic.com api.openai.com ;;
  esac
}
all_vendor_hosts='api.anthropic.com chatgpt.com api.openai.com'

agents=0
for dir in "$root"/agents/*/; do
  agent="$(basename "$dir")"
  [ -f "$dir/allowlist.txt" ] || { fail "agents/$agent has no allowlist.txt"; continue; }
  agents=$((agents + 1))
  session="$tmp/session-$agent"
  allowlist_render "$session" "$agent" || { fail "$agent: render failed"; continue; }
  proxy="$session/proxy"

  # The vendor: sidecar only.
  [ -s "$proxy/sidecar.domains" ] || fail "$agent: sidecar.domains is empty"
  for host in $(vendor_hosts "$agent"); do
    in_list "$proxy/sidecar.domains" "$host" || fail "$agent: $host is not in sidecar.domains"
  done
  [ "$(wc -l < "$proxy/sidecar.domains")" -eq "$(vendor_hosts "$agent" | wc -w)" ] ||
    fail "$agent: sidecar.domains holds more than the vendor's hosts: $(tr '\n' ' ' < "$proxy/sidecar.domains")"
  while IFS= read -r host; do
    if covered "$proxy/agent.domains" "$host"; then
      fail "$agent: the vendor host $host is reachable from the agent's address"
    fi
  done < "$proxy/sidecar.domains"
  # No model vendor at all, this agent's or another's, and none of the hosts
  # a repository's configuration could send the conversation to.
  for host in $all_vendor_hosts auth.openai.com claude.ai platform.claude.com \
    opencode.ai opncd.ai models.opencode.ai; do
    if covered "$proxy/agent.domains" "$host"; then
      fail "$agent: $host is reachable from the agent's address"
    fi
  done
  # No sign-in or token endpoint for the sidecar either: it never refreshes.
  for host in auth.openai.com claude.ai platform.claude.com console.anthropic.com; do
    if covered "$proxy/sidecar.domains" "$host"; then
      fail "$agent: the sign-in host $host is on the sidecar's list"
    fi
  done

  # github.com: on no default list, under any spelling.
  for f in agent.domains sidecar.domains relay.domains; do
    for host in github.com api.github.com uploads.github.com gitlab.com upload.pypi.org; do
      if covered "$proxy/$f" "$host"; then
        fail "$agent: $host is reachable by default ($f)"
      fi
    done
    if grep -q 'github' "$proxy/$f"; then
      fail "$agent: a GitHub host is in the default $f"
    fi
  done
  [ ! -s "$proxy/extra.conf" ] || fail "$agent: extra.conf is not empty by default"

  # The default list for the agent is the base list and nothing more.
  expected="$(printf '%s\n' files.pythonhosted.org pypi.org registry.npmjs.org)"
  [ "$(cat "$proxy/agent.domains")" = "$expected" ] ||
    fail "$agent: the default agent.domains is not the three base hosts: $(tr '\n' ' ' < "$proxy/agent.domains")"

  # No default entry is a pattern, and none is on never-allow.
  if grep -q '^\.' "$proxy/agent.domains" "$proxy/sidecar.domains"; then
    fail "$agent: a default entry is a pattern (leading dot)"
  fi
done
[ "$agents" -ge 3 ] || fail "expected at least the three shipped agents, found $agents"
for agent in claude codex opencode; do
  [ -f "$root/agents/$agent/allowlist.txt" ] || fail "agents/$agent/allowlist.txt is missing"
done

# The operator cannot put a vendor's host on the agent's list either, as a
# name, as a pattern above it, as a host:port or as a URL.
for value in api.anthropic.com .anthropic.com api.openai.com .openai.com chatgpt.com .com; do
  if allowlist_add host "$value" - 'test' 2>/dev/null; then
    fail "add accepted the vendor host $value for the agent's list"
  fi
done
if allowlist_add hostport api.anthropic.com:443 - 'test' 2>/dev/null; then
  fail "add accepted a vendor host as host:port"
fi
if allowlist_add url https://api.openai.com/v1/files - 'test' 2>/dev/null; then
  fail "add accepted a vendor host as a URL"
fi
[ ! -e "$SANDBOX_CONFIG_DIR/allowlist.local" ] || fail "a refused vendor entry was written"
mkdir -p "$SANDBOX_CONFIG_DIR"
printf 'host\t.anthropic.com\t-\thand edit\n' > "$SANDBOX_CONFIG_DIR/allowlist.local"
if allowlist_render "$tmp/session-vendor" claude 2>/dev/null; then
  fail "render accepted a hand edit that opens the vendor to the agent"
fi
rm -f "$SANDBOX_CONFIG_DIR/allowlist.local"

# The preset: one command, exactly three hosts, and still no github.com.
allowlist_render "$tmp/before" claude || fail "render before the preset failed"
allowlist_add preset github-downloads - 'build scripts fetch source archives' || fail "adding the preset failed"
allowlist_render "$tmp/after" claude || fail "render with the preset failed"
added="$(comm -13 "$tmp/before/proxy/agent.domains" "$tmp/after/proxy/agent.domains")"
expected="$(printf '%s\n' codeload.github.com objects.githubusercontent.com raw.githubusercontent.com)"
[ "$added" = "$expected" ] || fail "the preset did not add exactly its three hosts: $(echo "$added" | tr '\n' ' ')"
[ -z "$(comm -23 "$tmp/before/proxy/agent.domains" "$tmp/after/proxy/agent.domains")" ] ||
  fail "the preset removed a host"
for f in sidecar.domains relay.domains extra.conf; do
  cmp -s "$tmp/before/proxy/$f" "$tmp/after/proxy/$f" || fail "the preset changed $f"
done
for host in github.com api.github.com uploads.github.com; do
  if covered "$tmp/after/proxy/agent.domains" "$host"; then
    fail "with the preset, $host is reachable"
  fi
done
while IFS= read -r host; do
  if allowlist_upload_capable "$host"; then
    fail "the preset holds $host, which accepts uploads"
  fi
done <<EOF
$added
EOF
allowlist_remove github-downloads || fail "removing the preset failed"
allowlist_render "$tmp/after" claude || fail "render after removing the preset failed"
cmp -s "$tmp/before/proxy/agent.domains" "$tmp/after/proxy/agent.domains" ||
  fail "removing the preset did not restore agent.domains"

# Every shipped entry has a reason on its line.
for f in "$root/policy/allowlist.base.txt" "$root"/policy/presets/*.txt "$root"/agents/*/allowlist.txt; do
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
      ''|'#'*|'['*) continue ;;
    esac
    case "$line" in
      *'#'*[a-zA-Z]*) ;;
      *) fail "${f#"$root"/} line $n has no reason: $line" ;;
    esac
  done < "$f"
done

# never-allow.txt keeps the entries of the previous version.
for entry in storage.googleapis.com amazonaws.com s3.amazonaws.com .blob.core.windows.net \
  .ngrok.io .ngrok-free.app .trycloudflare.com pastebin.com transfer.sh file.io 0x0.st \
  .discord.com .discordapp.com webhook.site .pipedream.net .burpcollaborator.net .interact.sh; do
  awk '{ print $1 }' "$root/policy/never-allow.txt" | grep -q -x -F -- "$entry" ||
    fail "policy/never-allow.txt has lost $entry"
done

if [ "$fails" -gt 0 ]; then
  printf '%s shipped-list check(s) failed\n' "$fails"
  exit 1
fi
echo "allowlist shipped lists: all checks passed"
