#!/usr/bin/env bash
# The never-allow list [logical B20] and the upload warning list.
# Runs as a plain process; nothing here needs a container.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SANDBOX_ROOT="$root"
# shellcheck source-path=SCRIPTDIR source=../../scripts/allowlist.sh
source "$root/scripts/allowlist.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SANDBOX_CONFIG_DIR="$tmp/config"

fails=0
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

# hit <host> <entry it must be matched by>
hit() {
  local out
  if ! out="$(allowlist_never_allow_hit "$1")"; then
    fail "$1 is not caught by never-allow"
    return 0
  fi
  case "$out" in
    "$2"|"$2 "*) ;;
    *) fail "$1 was caught by '$out', expected the entry '$2'" ;;
  esac
}
no_hit() {
  local out
  if out="$(allowlist_never_allow_hit "$1")"; then
    fail "$1 is caught by never-allow ($out) and should not be"
  fi
}

# Direct hit: the host itself is on the list.
hit pastebin.com pastebin.com
hit storage.googleapis.com storage.googleapis.com
# The reason is printed with the entry.
case "$(allowlist_never_allow_hit transfer.sh)" in
  *"anonymous file upload"*) ;;
  *) fail "the reason for transfer.sh is not printed" ;;
esac

# Sub-domain hit: the list has a pattern (leading dot), the host is under it.
hit abc123.ngrok.io .ngrok.io
hit ngrok.io .ngrok.io
hit myaccount.blob.core.windows.net .blob.core.windows.net
hit .eu.ngrok.io .ngrok.io

# Wide-pattern hit: the allowlist entry is a pattern that would cover a
# listed host.
hit .googleapis.com storage.googleapis.com
hit .com storage.googleapis.com
hit .amazonaws.com amazonaws.com

# Not hits: a listed name without a leading dot is that one host only, and a
# name that merely ends with the same letters is a different host.
no_hit s3.eu-west-1.amazonaws.com
no_hit maps.googleapis.com
no_hit notpastebin.com
no_hit registry.npmjs.org
no_hit example.com

# allowlist_add refuses each kind of hit and writes nothing.
for host in pastebin.com abc123.ngrok.io .googleapis.com; do
  if allowlist_add host "$host" - 'test' 2>/dev/null; then
    fail "allowlist_add accepted the never-allow host $host"
  fi
done
if allowlist_add hostport transfer.sh:8443 - 'test' 2>/dev/null; then
  fail "allowlist_add accepted a never-allow host as host:port"
fi
if allowlist_add url http://webhook.site/abc - 'test' 2>/dev/null; then
  fail "allowlist_add accepted a never-allow host as a URL"
fi
if allowlist_add url https://webhook.site/abc - 'test' 2>/dev/null; then
  fail "allowlist_add accepted a never-allow host as an https URL"
fi
[ ! -e "$SANDBOX_CONFIG_DIR/allowlist.local" ] || fail "a refused entry was written to allowlist.local"

# A hand edit that puts one in allowlist.local stops the render, and the
# lists already in place stay as they were.
mkdir -p "$SANDBOX_CONFIG_DIR" "$tmp/session/proxy"
echo sentinel > "$tmp/session/proxy/agent.domains"
printf 'host\t.ngrok.io\t-\thand edit\n' > "$SANDBOX_CONFIG_DIR/allowlist.local"
if allowlist_render "$tmp/session" claude 2>/dev/null; then
  fail "allowlist_render accepted a never-allow host from allowlist.local"
fi
[ "$(cat "$tmp/session/proxy/agent.domains")" = sentinel ] || fail "a refused render changed agent.domains"
rm -f "$SANDBOX_CONFIG_DIR/allowlist.local"

# With the never-allow file missing, nothing can be added at all.
mkdir -p "$tmp/root/policy" "$tmp/root/agents"
if (SANDBOX_ROOT="$tmp/root"; allowlist_add host docs.example.com - 'test') 2>/dev/null; then
  fail "allowlist_add worked without a never-allow file"
fi

# Hosts known to accept uploads, for the launcher's warning.
for host in github.com api.github.com uploads.github.com gitlab.com \
  registry.npmjs.org upload.pypi.org .github.com .npmjs.org; do
  allowlist_upload_capable "$host" || fail "$host is not reported as accepting uploads"
done
for host in codeload.github.com raw.githubusercontent.com \
  objects.githubusercontent.com files.pythonhosted.org pypi.org example.com; do
  if allowlist_upload_capable "$host"; then
    fail "$host is reported as accepting uploads"
  fi
done

if [ "$fails" -gt 0 ]; then
  printf '%s never-allow check(s) failed\n' "$fails"
  exit 1
fi
echo "allowlist never-allow: all checks passed"
