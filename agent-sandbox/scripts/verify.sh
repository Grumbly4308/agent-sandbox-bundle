#!/usr/bin/env bash
# Sandbox self-test. Runs INSIDE the container: ./sandbox verify
#
# Every check here corresponds to a wall the guide claims to build. If one
# fails, that wall is not there — fix it before you let an agent loose.

pass=0; fail=0
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[1;31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }
deny() { if eval "$2" >/dev/null 2>&1; then no "$1"; else ok "$1"; fi; }

echo
echo "── identity ──"
check "running as non-root (uid $(id -u))"        '[ "$(id -u)" -ne 0 ]'
deny  "cannot sudo"                                'command -v sudo && sudo -n true'
check "all capabilities dropped"                   'grep -q "^CapEff:\s*0\{16\}$" /proc/self/status'

echo
echo "── filesystem ──"
deny  "/ is read-only"                             'touch /etc/sandbox-probe'
deny  "/usr is read-only"                          'touch /usr/local/bin/sandbox-probe'
check "/tmp is writable"                           'touch /tmp/sandbox-probe && rm /tmp/sandbox-probe'
check "\$HOME is writable"                         'touch "$HOME/.probe" && rm "$HOME/.probe"'
check "/workspace/repo is mounted"                 '[ -d /workspace/repo ]'
check "/workspace/repo is a usable git repo"       'git -C /workspace/repo rev-parse --git-dir'
# A linked worktree's .git is a FILE pointing at project/.git/worktrees/<name>,
# a host path that is not mounted here. It must be a directory: a real clone.
check "/workspace/repo is a clone, not a worktree" '[ -d /workspace/repo/.git ]'
check "/logs is writable"                          'touch /logs/.probe && rm /logs/.probe'
deny  "profile mount is read-only"                 'touch /opt/profile/.probe'

echo
echo "── credentials ──"
deny  "no host ssh keys reachable"                 'ls /home/*/.ssh/id_* 2>/dev/null | grep -q id_'
deny  "no ~/.aws"                                  '[ -d "$HOME/.aws" ]'
deny  "no ~/.config/gcloud"                        '[ -d "$HOME/.config/gcloud" ]'
deny  "host root filesystem not mounted"           '[ -d /host ] || [ -d /mnt/host ]'

echo
echo "── egress (allowlist) ──"
# The reachable/blocked pair swaps with the active agent: the *other* vendor's
# API must be refused, or the per-agent allowlist swap is not actually applied.
if [ "${SANDBOX_AGENT:-claude}" = codex ]; then
  api_ok=api.openai.com;    url_ok=https://api.openai.com/v1/models
  api_no=api.anthropic.com; url_no=https://api.anthropic.com/v1/models
else
  api_ok=api.anthropic.com; url_ok=https://api.anthropic.com/v1/models
  api_no=api.openai.com;    url_no=https://api.openai.com/v1/models
fi
check "proxy env is set"                           '[ -n "$HTTPS_PROXY" ]'
deny  "no direct route to the internet"            'curl -s --noproxy "*" --max-time 5 https://example.com'
check "allowed host reachable ($api_ok)"           'curl -sS -o /dev/null --max-time 15 $url_ok'
deny  "inactive agent blocked ($api_no)"           'curl -sS -o /dev/null --max-time 15 --fail $url_no'
deny  "blocked host refused (example.com)"         'curl -sS -o /dev/null --max-time 15 --fail https://example.com'

echo
echo "── profile ──"
if [ "${SANDBOX_AGENT:-claude}" = codex ]; then
  check "AGENTS.md materialised"                   '[ -f "$HOME/.codex/AGENTS.md" ]'
  check "AGENTS.md forbids AI attribution"         'grep -qi "co-authored-by" "$HOME/.codex/AGENTS.md"'
else
  check "settings.json materialised"               '[ -f "$HOME/.claude/settings.json" ]'
  check "settings.json is valid JSON"              'jq -e . "$HOME/.claude/settings.json"'
  check "attribution trailers suppressed"          'jq -e ".attribution.commit == \"\" and .attribution.pr == \"\"" "$HOME/.claude/settings.json"'
  check "CLAUDE.md materialised"                   '[ -f "$HOME/.claude/CLAUDE.md" ]'
  check "CLAUDE.md forbids AI attribution"         'grep -qi "co-authored-by" "$HOME/.claude/CLAUDE.md"'
fi
check "qa is on PATH"                              'command -v qa'

echo
echo "── limits ──"
check "pid limit set"                              '[ "$(cat /sys/fs/cgroup/pids.max 2>/dev/null || echo max)" != "max" ]'
check "memory limit set"                           '[ "$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)" != "max" ]'

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && echo "sandbox: walls are solid." || echo "sandbox: FIX THE FAILURES ABOVE before using this."
exit $(( fail > 0 ))
