# Interactive shell defaults for the agent container.
# Copied to ~/.bashrc by the entrypoint on every start.

export PATH="$HOME/.local/bin:$PATH"
export EDITOR=nano
export PAGER=less
export LESS=-FRX

# A prompt that makes it obvious you are inside the sandbox, not on the host.
PS1='\[\e[1;33m\][sandbox]\[\e[0m\] \w $(git branch --show-current 2>/dev/null | sed "s/.*/(&) /")\$ '

alias ll='ls -alFh'
alias gs='git status -sb'
alias gd='git diff'
alias gl='git log --oneline --graph -20'

# Where things are.
alias repo='cd /workspace/repo'
cd /workspace/repo 2>/dev/null || true

cat <<'BANNER'
  sandbox: read-only rootfs, allowlist egress, ephemeral home.
           /workspace/repo persists. /logs persists. nothing else does.
           `qa` runs this project's checks.
BANNER
