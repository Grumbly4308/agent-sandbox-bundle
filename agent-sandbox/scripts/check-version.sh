#!/usr/bin/env bash
# Is this bundle copy current? Run from the agent-sandbox directory:
#     bash scripts/check-version.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ok(){ printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
no(){ printf '  \033[1;31m✗\033[0m %s\n' "$1"; }

echo "bundle self-check"
grep -q 'in-pod' sandbox                     && ok "sandbox passes --in-pod=false"          || no "sandbox is OLD — no --in-pod handling"
[ -f docker-compose.podman-userns.yml ]      && ok "keep-id overlay is separable"           || no "docker-compose.podman-userns.yml MISSING"
grep -q 'in_pod' docker-compose.podman.yml   && ok "compose file sets x-podman.in_pod"      || no "docker-compose.podman.yml is OLD"
grep -q 'node:22' agent/Dockerfile           && ok "agent image is Node 22"                 || no "agent/Dockerfile is OLD — ships Node 18"
grep -q 'uid=' docker-compose.yml            && no "docker-compose.yml is OLD — tmpfs uid= breaks Podman" || ok "tmpfs has no uid=/gid="
grep -q 'resolve_identity' sandbox           && ok "uid/gid resolved live from id(1)"    || no "sandbox is OLD — uid/gid frozen in .env"
grep -q 'USER squid' proxy/Dockerfile        && ok "proxy starts unprivileged"              || no "proxy/Dockerfile is OLD"
grep -q 'attribution' profile/claude/settings.json && ok "attribution suppressed"           || no "settings.json is OLD"
grep -q '^SANDBOX_NAME=' .env 2>/dev/null    && ok "SANDBOX_NAME set ($(grep '^SANDBOX_NAME=' .env | cut -d= -f2))" || no ".env has no SANDBOX_NAME"
grep -q '^SANDBOX_USERNS=' .env 2>/dev/null  && ok "SANDBOX_USERNS present"                 || no ".env predates SANDBOX_USERNS (add it, or copy .env.example keys)"
echo
echo "image actually in use:"
{ podman run --rm localhost/${SANDBOX_NAME:-agent-sandbox}-agent node --version 2>/dev/null \
  || docker run --rm ${SANDBOX_NAME:-agent-sandbox}-agent node --version 2>/dev/null \
  || echo "  (could not run the agent image — build it first)"; } | sed 's/^/  node /'
