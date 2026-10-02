#!/usr/bin/env bash
# images/agent/Containerfile, images/PINS and scripts/pin-images.sh, checked
# without a container runtime:
#   * the "base image must be pinned" guard, run as the shell snippet it is;
#   * the package lists: exactly the contract's toolchains, a reason above
#     each package, nothing forbidden;
#   * the fixed properties (user, entrypoint, git setting);
#   * pin-images.sh against a stand-in podman.
#
# Much of this looks for literal text such as ${NODE_BASE} in the
# Containerfile, hence:
# shellcheck disable=SC2016
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cf="$root/images/agent/Containerfile"
pins="$root/images/PINS"
digest="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# --- The guard ----------------------------------------------------------------
# One RUN line; ARG values reach it as environment variables.
guard="$(grep -m 1 '^RUN case "\${NODE_BASE}" in ' "$cf" | sed 's/^RUN //')"
if [ -n "$guard" ]; then pass "guard: found in the Containerfile"; else fail "guard: not found in the Containerfile"; fi
guard_accepts() { NODE_BASE="$1" sh -c "$guard" >/dev/null 2>&1; }

check_not "guard: refuses UNPINNED" guard_accepts UNPINNED
check_not "guard: refuses an empty value" guard_accepts ""
check_not "guard: refuses a tag without a digest" guard_accepts docker.io/library/node:22-bookworm-slim
check "guard: accepts tag@sha256:digest" guard_accepts "docker.io/library/node:22-bookworm-slim@$digest"
refusal="$(NODE_BASE=UNPINNED sh -c "$guard" 2>&1 || true)"
case "$refusal" in
  *pin-images.sh*) pass "guard: the refusal names scripts/pin-images.sh" ;;
  *) fail "guard: the refusal does not say what to do" ;;
esac
check "Containerfile: the default NODE_BASE is UNPINNED" grep -qx 'ARG NODE_BASE=UNPINNED' "$cf"
# The guard comes before anything is installed.
guard_at="$(grep -n '^RUN case "\${NODE_BASE}" in ' "$cf" | head -n 1 | cut -d: -f1)"
first_install="$(grep -n 'apt-get\|install.sh' "$cf" | grep -v '^[0-9]*:#' | head -n 1 | cut -d: -f1)"
if [ -n "$guard_at" ] && [ "$guard_at" -lt "$first_install" ]; then
  pass "guard: runs before anything is installed"
else
  fail "guard: something is installed before the guard"
fi

# --- images/PINS, as shipped or as pinned ---------------------------------------
pin_value() {   # <file> <NAME>
  local name value
  while IFS='=' read -r name value; do
    if [ "$name" = "$2" ]; then printf '%s\n' "$value"; fi
  done <"$1"
}
bad=0 prev=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '' | '#'*) ;;
    *)
      if ! [[ "$line" =~ ^[A-Z][A-Z0-9_]*=(UNPINNED|[a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64})$ ]]; then
        fail "PINS: not NAME=UNPINNED or NAME=registry/repo:tag@sha256:...: '$line'"
        bad=1
      fi
      case "$prev" in
        '# tag: '*) ;;
        *) fail "PINS: no '# tag: <reference>' line directly above '$line'"; bad=1 ;;
      esac
      ;;
  esac
  prev="$line"
done <"$pins"
if [ "$bad" -eq 0 ]; then pass "PINS: every entry is UNPINNED or digest-pinned, with its tag above it"; fi
check "PINS: has NODE_BASE" test -n "$(pin_value "$pins" NODE_BASE)"
check "PINS: has ALPINE_BASE" test -n "$(pin_value "$pins" ALPINE_BASE)"
check "PINS: NODE_BASE tag is node:22-bookworm-slim" grep -qx '# tag: docker.io/library/node:22-bookworm-slim' "$pins"
check "PINS: ALPINE_BASE tag is alpine:3.20" grep -qx '# tag: docker.io/library/alpine:3.20' "$pins"

node_base="$(pin_value "$pins" NODE_BASE)"
if [ "$node_base" = UNPINNED ]; then
  check_not "PINS as shipped (UNPINNED) is refused by the Containerfile's guard" guard_accepts "$node_base"
else
  check "PINS is pinned and accepted by the Containerfile's guard" guard_accepts "$node_base"
fi

# --- Packages -----------------------------------------------------------------
# A package line is six spaces, a name, and a line continuation. The line
# above it must be `# <name>: <reason>`.
expected="build-essential ca-certificates catatonit chromium curl git jq less patch procps python3 python3-dev python3-pip python3-venv ripgrep"
found="" prev="" unexplained=""
while IFS= read -r line; do
  if [[ "$line" =~ ^\ {6}([a-z0-9][a-z0-9.+-]*)\ \\$ ]]; then
    pkg="${BASH_REMATCH[1]}"
    found="$found $pkg"
    case "$prev" in
      "      # $pkg: "?*) ;;
      *) unexplained="$unexplained $pkg" ;;
    esac
  fi
  prev="$line"
done <"$cf"
found="$(printf '%s' "$found" | tr ' ' '\n' | grep . | sort | tr '\n' ' ' | sed 's/ $//')"
if [ "$found" = "$expected" ]; then
  pass "packages: exactly the contract's toolchains"
else
  fail "packages: installed [$found], expected [$expected]"
fi
if [ -z "$unexplained" ]; then pass "packages: each has a reason on the line above"; else fail "packages: no reason above:$unexplained"; fi
check "packages: recommended extras are never installed" test "$(grep -c 'apt-get install' "$cf")" = "$(grep -c 'apt-get install -y --no-install-recommends' "$cf")"

code="$(grep -vE '^[[:space:]]*#' "$cf")"
for banned in sudo openssh ssh-client netcat ncat docker.io podman nerdctl buildah chromium-sandbox; do
  if printf '%s\n' "$code" | grep -vE 'for forbidden in|must not be' | grep -qE "(^|[[:space:]])$banned([[:space:]]|\\\\|$)"; then
    fail "packages: '$banned' is installed"
  else
    pass "packages: no '$banned'"
  fi
done
check "build: fails if a runtime, sudo, ssh or netcat appears" \
  grep -q 'for forbidden in docker podman nerdctl buildah sudo ssh nc netcat ncat; do' "$cf"
check "build: fails if a setuid program was added" grep -q 'the build added setuid/setgid programs' "$cf"

# --- Fixed properties -----------------------------------------------------------
check "user: agent is 61000:61000" grep -q 'useradd --uid 61000 --gid 61000' "$cf"
check "user: the image runs as 61000:61000" grep -qx 'USER 61000:61000' "$cf"
check "user: the base image's node user is removed" grep -q 'userdel --remove node' "$cf"
check "user: no home directory is baked in" grep -q -- '--no-create-home' "$cf"
check "git: ext:: transport is off system-wide" grep -qx 'RUN git config --system protocol.ext.allow never' "$cf"
check "entrypoint: cleared" grep -qx 'ENTRYPOINT \[\]' "$cf"
check "command: sandbox-idle by default" grep -qx 'CMD \["sandbox-idle"\]' "$cf"
check "install: the plug-in's install.sh runs at build" grep -q 'bash /usr/share/sandbox/agent/install.sh' "$cf"
check "copy: the plug-in goes to /usr/share/sandbox/agent/" grep -qx 'COPY agents/${AGENT}/ /usr/share/sandbox/agent/' "$cf"
check "copy: verify-inside.sh goes to /usr/share/sandbox/" grep -q 'images/agent/verify-inside.sh .*/usr/share/sandbox/' "$cf"
for script in sandbox-idle sandbox-import sandbox-bundle sandbox-launch; do
  check "copy: $script goes to /usr/local/bin" grep -q "images/agent/$script" "$cf"
done
check "versions: written to /usr/share/sandbox/versions" grep -q '> /usr/share/sandbox/versions' "$cf"
for name in 'sandbox=' '${AGENT}=' 'node=' 'git=' 'toolchain='; do
  check "versions: has a $name line" grep -qF "echo \"$name" "$cf"
done
check "sbom: written to /usr/share/sandbox/sbom.json" grep -q '> /usr/share/sandbox/sbom.json' "$cf"
check "resolv.conf: an empty one is copied in last" grep -qx 'COPY --from=empty /out/resolv.conf /etc/resolv.conf' "$cf"
check "resolv.conf: marked unproven" grep -q 'UNPROVEN' "$cf"
check_not "no 'latest' anywhere" grep -qiw 'latest' "$cf"
if printf '%s\n' "$code" | grep -qE 'CLAUDE\.md|AGENTS\.md|settings\.json|opencode\.json'; then
  fail "the image is given rules for the agent (CLAUDE.md, AGENTS.md, settings.json)"
else
  pass "no rules shipped for the agent (CLAUDE.md, AGENTS.md, settings.json)"
fi
# Toolchain arguments the launcher passes: both spellings of the version.
check "args: accepts VERSION" grep -qx 'ARG VERSION' "$cf"
check "args: accepts SANDBOX_VERSION (what ./sandbox passes)" grep -qx 'ARG SANDBOX_VERSION' "$cf"

# --- scripts/pin-images.sh with a stand-in podman --------------------------------
fake_root="$scratch/root"
mkdir -p "$fake_root/images" "$fake_root/services" "$scratch/bin"
cp "$pins" "$fake_root/images/PINS"
cp -R "$root/services/postgres" "$root/services/redis" "$fake_root/services/"
# Start from the shipped state whatever the real files hold now.
for f in "$fake_root/images/PINS" "$fake_root"/services/*/service.conf; do
  sed -E 's/^([A-Z_]+)=[a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$/\1=UNPINNED/' "$f" >"$f.tmp"
  cat "$f.tmp" >"$f"
  rm -f "$f.tmp"
done
cp -R "$fake_root" "$scratch/root.before"

# `podman pull --quiet <ref>` succeeds; `podman image inspect --format
# {{.Digest}} <ref>` prints a digest made from the reference.
cat >"$scratch/bin/podman" <<'EOS'
#!/bin/sh
echo "$*" >>"$FAKE_PODMAN_LOG"
case "$1" in
  pull) exit 0 ;;
  image)
    for ref in "$@"; do :; done
    if [ -n "${FAKE_BAD_DIGEST:-}" ]; then echo "<no value>"; exit 0; fi
    printf 'sha256:%s\n' "$(printf '%s' "$ref" | sha256sum | cut -d' ' -f1)"
    ;;
  *) exit 97 ;;
esac
EOS
chmod +x "$scratch/bin/podman"
ref_digest() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"; }

# A digest podman cannot give: the script stops and changes nothing.
if PATH="$scratch/bin:$PATH" FAKE_PODMAN_LOG="$scratch/podman.log" FAKE_BAD_DIGEST=1 SANDBOX_ROOT="$fake_root" \
  bash "$root/scripts/pin-images.sh" >/dev/null 2>&1; then
  fail "pin-images: carried on without a digest"
else
  pass "pin-images: stops when podman reports no digest"
fi
if diff -r "$scratch/root.before" "$fake_root" >/dev/null; then
  pass "pin-images: a failed run changes no file"
else
  fail "pin-images: a failed run changed files"
fi

if PATH="$scratch/bin:$PATH" FAKE_PODMAN_LOG="$scratch/podman.log" SANDBOX_ROOT="$fake_root" \
  bash "$root/scripts/pin-images.sh" >"$scratch/pin.out" 2>"$scratch/pin.err"; then
  pass "pin-images: runs"
else
  fail "pin-images: failed: $(cat "$scratch/pin.err")"
fi
node_ref="docker.io/library/node:22-bookworm-slim"
alpine_ref="docker.io/library/alpine:3.20"
pg_ref="docker.io/library/postgres:16-alpine"
redis_ref="docker.io/library/redis:7-alpine"
check "pin-images: NODE_BASE rewritten as tag@digest" \
  grep -qx "NODE_BASE=$node_ref@$(ref_digest "$node_ref")" "$fake_root/images/PINS"
check "pin-images: ALPINE_BASE rewritten as tag@digest" \
  grep -qx "ALPINE_BASE=$alpine_ref@$(ref_digest "$alpine_ref")" "$fake_root/images/PINS"
check "pin-images: postgres IMAGE rewritten" \
  grep -qx "IMAGE=$pg_ref@$(ref_digest "$pg_ref")" "$fake_root/services/postgres/service.conf"
check "pin-images: redis IMAGE rewritten" \
  grep -qx "IMAGE=$redis_ref@$(ref_digest "$redis_ref")" "$fake_root/services/redis/service.conf"
check "pin-images: prints old -> new" grep -q "NODE_BASE: UNPINNED -> $node_ref@sha256:" "$scratch/pin.out"
check "pin-images: pulls each tag" grep -qx "pull --quiet $node_ref" "$scratch/podman.log"
check_not "pin-images: leaves no UNPINNED behind" grep -rq 'UNPINNED$' "$fake_root/images/PINS" "$fake_root/services"
# Only the pinned lines changed: four lines differ, everything else is byte-identical.
changed="$(diff -r "$scratch/root.before" "$fake_root" | grep -c '^>' || true)"
if [ "$changed" = 4 ]; then pass "pin-images: exactly the four entries changed"; else fail "pin-images: $changed lines changed, expected 4"; fi
# The empty COMMAND_ARG= line of the redis service must survive the rewrite.
check "pin-images: keeps redis's empty COMMAND_ARG= line" grep -qx 'COMMAND_ARG=' "$fake_root/services/redis/service.conf"
check "pinned NODE_BASE is accepted by the guard" guard_accepts "$(pin_value "$fake_root/images/PINS" NODE_BASE)"

# Running it again re-pins from the same tags: same result.
cp -R "$fake_root" "$scratch/root.pinned"
PATH="$scratch/bin:$PATH" FAKE_PODMAN_LOG="$scratch/podman.log" SANDBOX_ROOT="$fake_root" \
  bash "$root/scripts/pin-images.sh" >/dev/null 2>&1 || true
if diff -r "$scratch/root.pinned" "$fake_root" >/dev/null; then
  pass "pin-images: a second run gives the same files"
else
  fail "pin-images: a second run changed the files"
fi

finish
