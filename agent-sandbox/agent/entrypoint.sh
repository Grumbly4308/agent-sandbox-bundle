#!/usr/bin/env bash
# Materialise the agent's home directory from the read-only profile mount.
#
# $HOME is a tmpfs: it is empty at every start and vanishes at every exit.
# That is the point — the agent cannot leave anything behind, and it cannot
# edit its own permission rules, because the source of truth for those rules
# is /opt/profile, mounted read-only.
set -euo pipefail

PROFILE_DIR="${PROFILE_DIR:-/opt/profile}"
HOME_DIR="${HOME:-/home/agent}"
AUTH_DIR="/run/auth"

install -d -m 0700 "$HOME_DIR/.claude" "$HOME_DIR/.ssh" "$HOME_DIR/.local/bin"

# --- 1. Agent configuration (settings.json, CLAUDE.md, commands/, agents/) ---
if [ -d "$PROFILE_DIR/claude" ]; then
  cp -a "$PROFILE_DIR/claude/." "$HOME_DIR/.claude/"
fi
# Codex reads ~/.codex (AGENTS.md, config.toml) the way Claude reads ~/.claude.
if [ -d "$PROFILE_DIR/codex" ]; then
  install -d -m 0700 "$HOME_DIR/.codex"
  cp -a "$PROFILE_DIR/codex/." "$HOME_DIR/.codex/"
fi

# --- 2. Custom commands on PATH ---------------------------------------------
if [ -d "$PROFILE_DIR/bin" ]; then
  cp -a "$PROFILE_DIR/bin/." "$HOME_DIR/.local/bin/"
  chmod -R u+x "$HOME_DIR/.local/bin" 2>/dev/null || true
fi
export PATH="$HOME_DIR/.local/bin:$PATH"

# --- 3. Shell defaults ------------------------------------------------------
if [ -f "$PROFILE_DIR/shellrc.sh" ]; then
  cp "$PROFILE_DIR/shellrc.sh" "$HOME_DIR/.bashrc"
fi

# --- 4. Saved login ---------------------------------------------------------
# The tmpfs $HOME means an interactive `/login` would have to be repeated every
# single session. auth/ on the host is mounted read-write here; we copy the
# session in at start, and (only when ./sandbox login asked for it) back out at
# exit. Nothing else in $HOME is ever persisted.
# .credentials.json is the session itself; .claude.json carries the account and
# onboarding state, and without it the CLI re-runs first-run setup every time.
#
# Only the ACTIVE agent's session is materialised and saved back. The inactive
# vendor's login sitting readable in $HOME would hand a prompt-injected agent a
# live token it has no business seeing — and one the profile's deny rules were
# never written to cover.
restore_auth() {
  if [ "${SANDBOX_AGENT:-claude}" = codex ]; then
    # Codex keeps its session in ~/.codex/auth.json; same dance, one file.
    if [ -s "$AUTH_DIR/codex-auth.json" ] && [ -r "$AUTH_DIR/codex-auth.json" ]; then
      install -d -m 0700 "$HOME_DIR/.codex"
      cp "$AUTH_DIR/codex-auth.json" "$HOME_DIR/.codex/auth.json"
      chmod 600 "$HOME_DIR/.codex/auth.json"
    fi
    return 0
  fi
  if [ -s "$AUTH_DIR/.credentials.json" ] && [ -r "$AUTH_DIR/.credentials.json" ]; then
    cp "$AUTH_DIR/.credentials.json" "$HOME_DIR/.claude/.credentials.json"
    chmod 600 "$HOME_DIR/.claude/.credentials.json"
  fi
  if [ -s "$AUTH_DIR/.claude.json" ] && [ -r "$AUTH_DIR/.claude.json" ]; then
    cp "$AUTH_DIR/.claude.json" "$HOME_DIR/.claude.json"
    chmod 600 "$HOME_DIR/.claude.json"
  fi
}

save_auth() {
  if [ ! -w "$AUTH_DIR" ]; then
    echo "sandbox: /run/auth is not writable; login not saved" >&2
    return 0
  fi
  if [ "${SANDBOX_AGENT:-claude}" = codex ]; then
    if [ -f "$HOME_DIR/.codex/auth.json" ]; then
      cp -f "$HOME_DIR/.codex/auth.json" "$AUTH_DIR/codex-auth.json"
      chmod 600 "$AUTH_DIR/codex-auth.json"
    fi
    return 0
  fi
  if [ -f "$HOME_DIR/.claude/.credentials.json" ]; then
    cp -f "$HOME_DIR/.claude/.credentials.json" "$AUTH_DIR/.credentials.json"
    chmod 600 "$AUTH_DIR/.credentials.json"
  fi
  if [ -f "$HOME_DIR/.claude.json" ]; then
    cp -f "$HOME_DIR/.claude.json" "$AUTH_DIR/.claude.json"
    chmod 600 "$AUTH_DIR/.claude.json"
  fi
  return 0
}

if [ -d "$AUTH_DIR" ]; then
  restore_auth
fi

# --- 4b. Credential hygiene --------------------------------------------------
# Only the active vendor's secrets stay in the environment. Compose passes both
# vendors' keys through unconditionally — interpolation cannot branch on
# SANDBOX_AGENT — so the inactive one is dropped here, before the agent starts.
# profile/setup.sh below gets none of them at all (step 7).
if [ "${SANDBOX_AGENT:-claude}" = codex ]; then
  unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
else
  unset OPENAI_API_KEY
fi

# --- 5. Git identity --------------------------------------------------------
git config --global user.name  "${GIT_AUTHOR_NAME:-agent}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-agent@sandbox.local}"
git config --global init.defaultBranch main
git config --global --add safe.directory /workspace/repo

# workspace/ is a full clone, so this should always hold. If it does not, the
# mount is an old-style linked worktree whose .git file points at a host path
# that does not exist in here — fail loudly instead of 40 confusing git errors.
if [ -f /workspace/repo/.git ] && ! git -C /workspace/repo rev-parse --git-dir >/dev/null 2>&1; then
  echo "sandbox: /workspace/repo is a linked git worktree, not a clone." >&2
  echo "sandbox: its .git points at project/.git/worktrees/... which is not" >&2
  echo "sandbox: mounted here. Run './sandbox doctor' on the host to fix." >&2
fi

# --- 6. Deploy key, if one was mounted --------------------------------------
# SSH cannot traverse an HTTP proxy on port 22, so we route it over 443 via
# CONNECT. GitHub and GitLab both publish an alt-SSH endpoint for exactly this.
if [ -e /run/secrets/deploy_key ]; then
  if [ ! -r /run/secrets/deploy_key ]; then
    # A 0600 file is readable only by its owning uid. If the key was created by
    # a different user (or with sudo) than the uid this container runs as, the
    # bind mount is visible but unreadable.
    echo "sandbox: /run/secrets/deploy_key exists but is not readable by uid $(id -u)." >&2
    echo "sandbox: on the host, run:" >&2
    echo "sandbox:   sudo chown $(id -u) secrets/deploy_key && chmod 600 secrets/deploy_key" >&2
    echo "sandbox: continuing without SSH — push from the host with ./sandbox push." >&2
  else
    install -m 0600 /run/secrets/deploy_key "$HOME_DIR/.ssh/id_ed25519"

    proxy_hostport="${HTTPS_PROXY#*://}"
    proxy_hostport="${proxy_hostport%/}"

    cat > "$HOME_DIR/.ssh/config" <<SSHCFG
Host github.com
  HostName ssh.github.com
  Port 443
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ProxyCommand nc -X connect -x ${proxy_hostport} %h %p

Host gitlab.com
  HostName altssh.gitlab.com
  Port 443
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ProxyCommand nc -X connect -x ${proxy_hostport} %h %p
SSHCFG

    # Self-hosted GitLab/Gitea: same trick, but the port has to be one the
    # proxy will CONNECT to (see the SSH_ports ACL in proxy/squid.conf).
    if [ -n "${GIT_SSH_HOST:-}" ]; then
      cat >> "$HOME_DIR/.ssh/config" <<SSHCFG

Host ${GIT_SSH_HOST}
  HostName ${GIT_SSH_HOST}
  Port ${GIT_SSH_PORT:-443}
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ProxyCommand nc -X connect -x ${proxy_hostport} %h %p
SSHCFG
    fi

    chmod 0600 "$HOME_DIR/.ssh/config"
  fi
fi

# --- 7. Per-project bootstrap ----------------------------------------------
# Non-fatal on purpose: a broken lockfile should drop you into a shell you can
# debug, not kill the container.
#
# It runs the repo's own install hooks (npm lifecycle scripts, pip builds) —
# untrusted code that has no business seeing a credential, the active vendor's
# key included. The agent needs them; the install does not. The proxy variables
# stay, or nothing installs.
if [ -x "$PROFILE_DIR/setup.sh" ]; then
  env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u OPENAI_API_KEY -u GIT_TOKEN \
    "$PROFILE_DIR/setup.sh" || echo "sandbox: profile/setup.sh exited $? (continuing)" >&2
fi
# setup.sh is a child process, so anything it wants on PATH (the venv) comes
# back through ~/.profile. Sourced here, before the exec, it is inherited by the
# agent and by every non-interactive shell the agent spawns.
if [ -f "$HOME_DIR/.profile" ]; then
  . "$HOME_DIR/.profile"
fi

# --- 8. Run the agent -------------------------------------------------------
# Not `exec`, because we may need to copy the login back out afterwards.
# tini is still PID 1, so subprocess reaping is unaffected.
if [ -n "${SANDBOX_PERSIST_AUTH:-}" ]; then
  trap save_auth EXIT INT TERM
  "$@"
else
  exec "$@"
fi
