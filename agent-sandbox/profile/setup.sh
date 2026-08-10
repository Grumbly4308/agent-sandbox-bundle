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
if [ -f requirements.txt ]; then
  echo "sandbox: pip install -r requirements.txt"
  python3 -m venv /tmp/venv && /tmp/venv/bin/pip install -q -r requirements.txt
  echo 'export PATH=/tmp/venv/bin:$PATH' >> "$HOME/.bashrc"
fi

exit 0
