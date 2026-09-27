#!/usr/bin/env bash
# Per-session project bootstrap. Runs once at container start, before the agent.
#
# The container is ephemeral, so this runs every session — keep it fast, or
# bake heavy dependencies into agent/Dockerfile instead. Failure here is
# non-fatal: you still get a shell.
set -uo pipefail

cd /workspace/repo 2>/dev/null || exit 0

# Node
if [ -f package-lock.json ]; then
  echo "sandbox: npm ci"   && npm ci --no-audit --no-fund
elif [ -f package.json ]; then
  echo "sandbox: npm install" && npm install --no-audit --no-fund
fi

# Python
if [ -f requirements.txt ] || [ -f pyproject.toml ]; then
  echo "sandbox: python3 -m venv /tmp/venv"
  if python3 -m venv /tmp/venv; then
    [ -f requirements.txt ] && /tmp/venv/bin/pip install -q -r requirements.txt
    [ -f pyproject.toml ]   && /tmp/venv/bin/pip install -q -e .
    # No PATH line in ~/.bashrc (only interactive shells read it; the agent's
    # tool calls are `bash -c`) and none in ~/.profile either: the entrypoint
    # puts /tmp/venv/bin on PATH itself when the directory exists, rather than
    # sourcing a file the install hooks above could have written.
  fi
fi

exit 0
