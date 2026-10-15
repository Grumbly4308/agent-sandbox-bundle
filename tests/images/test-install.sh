#!/usr/bin/env bash
# agents/<name>/install.sh: each names an exact version and sha512 hashes,
# never "latest", never `npm install`; a tarball whose hash is not the
# pinned one stops the install before anything is unpacked; and the
# verify/unpack functions do what they say. npm is a stand-in here: nothing
# is downloaded.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The versions the build contract pins.
expected_version() {
  case "$1" in
    claude) echo 2.1.300 ;;
    codex) echo 0.162.1 ;;
    opencode) echo 1.18.34 ;;
  esac
}
# Package names each script must pin a hash for, as the scripts spell them
# (with a literal ${VERSION}).
# shellcheck disable=SC2016
expected_specs() {
  case "$1" in
    claude) echo '@anthropic-ai/claude-code@${VERSION} @anthropic-ai/claude-code-linux-x64@${VERSION} @anthropic-ai/claude-code-linux-arm64@${VERSION}' ;;
    codex) echo '@openai/codex@${VERSION} @openai/codex@${VERSION}-linux-x64 @openai/codex@${VERSION}-linux-arm64' ;;
    opencode) echo 'opencode-ai@${VERSION} opencode-linux-x64@${VERSION} opencode-linux-arm64@${VERSION}' ;;
  esac
}

# A stand-in npm. `npm pack <spec> --pack-destination <dir> ...` copies
# $FAKE_TARBALL into <dir>; anything else fails loudly.
mkdir -p "$scratch/bin"
cat >"$scratch/bin/npm" <<'EOS'
#!/bin/sh
echo "$*" >>"$FAKE_NPM_LOG"
[ "$1" = pack ] || { echo "fake npm: unexpected command: $*" >&2; exit 97; }
dest=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--pack-destination" ]; then dest="$2"; fi
  shift
done
[ -n "$dest" ] || exit 98
cp "$FAKE_TARBALL" "$dest/package-0.0.0.tgz"
EOS
chmod +x "$scratch/bin/npm"

# A small npm-shaped tarball: everything under package/, one file with the
# setuid bit and write permission for everyone, to see them removed.
mkdir -p "$scratch/pkg/package/bin"
printf '{"name":"fake","version":"0.0.0"}\n' >"$scratch/pkg/package/package.json"
printf '#!/bin/sh\necho fake\n' >"$scratch/pkg/package/bin/tool"
chmod 4777 "$scratch/pkg/package/bin/tool"
chmod 0666 "$scratch/pkg/package/package.json"
tar -czf "$scratch/fake.tgz" -C "$scratch/pkg" package
# Its hash, computed without the code under test.
fake_integrity="sha512-$(python3 -c 'import base64,hashlib,sys; print(base64.b64encode(hashlib.sha512(open(sys.argv[1],"rb").read()).digest()).decode())' "$scratch/fake.tgz")"

for agent in claude codex opencode; do
  file="$root/agents/$agent/install.sh"
  version="$(expected_version "$agent")"

  check "$agent: pins VERSION=\"$version\"" grep -qx "VERSION=\"$version\"" "$file"

  hashes="$(grep -oE '^[A-Z0-9_]+_INTEGRITY="sha512-[A-Za-z0-9+/]{86}=="$' "$file" || true)"
  count="$(printf '%s\n' "$hashes" | grep -c . || true)"
  if [ "$count" -ge 3 ]; then pass "$agent: pins $count sha512 integrity hashes"; else fail "$agent: only $count integrity hashes"; fi
  if [ "$(printf '%s\n' "$hashes" | cut -d= -f2- | sort -u | grep -c .)" = "$count" ]; then
    pass "$agent: the hashes are all different"
  else
    fail "$agent: the same hash is pinned twice"
  fi
  # Every *_INTEGRITY assignment is a full sha512, not a placeholder.
  if [ "$(grep -cE '^[A-Z0-9_]+_INTEGRITY=' "$file")" = "$count" ]; then
    pass "$agent: no malformed or empty hash"
  else
    fail "$agent: an _INTEGRITY line is not a sha512-...== value"
  fi

  for spec in $(expected_specs "$agent"); do
    check "$agent: pins a hash for $spec" grep -qF "_SPEC=\"$spec\"" "$file"
  done
  # Each pinned spec has its hash, and each is used.
  while IFS= read -r name; do
    check "$agent: ${name}_SPEC has ${name}_INTEGRITY" grep -q "^${name}_INTEGRITY=" "$file"
    check "$agent: ${name} is verified before use" grep -q "\"\$${name}_INTEGRITY\"" "$file"
  done < <(grep -oE '^[A-Z0-9_]+_SPEC=' "$file" | sed 's/_SPEC=//')

  check_not "$agent: the word 'latest' appears nowhere" grep -qiw 'latest' "$file"
  # Code lines only (comments explain what is NOT done).
  code="$(grep -vE '^[[:space:]]*#' "$file")"
  for banned in 'npm install' 'npm i ' 'npm ci' 'npx ' 'curl ' 'wget ' 'postinstall' 'install.cjs'; do
    if printf '%s\n' "$code" | grep -qF -- "$banned"; then fail "$agent: code runs or names '$banned'"; else pass "$agent: code has no '$banned'"; fi
  done
  check "$agent: npm pack runs with --ignore-scripts" grep -qE 'npm pack .*--ignore-scripts' "$file"
  check "$agent: ends by printing the version" grep -qF "printf '%s\\n' \"\$VERSION\"" "$file"

  # --- End to end with a tarball that is not the pinned one ------------------
  prefix="$scratch/prefix.$agent"
  log="$scratch/npm.$agent.log"
  : >"$log"
  if PATH="$scratch/bin:$PATH" FAKE_TARBALL="$scratch/fake.tgz" FAKE_NPM_LOG="$log" \
    SANDBOX_INSTALL_PREFIX="$prefix" bash "$file" >"$scratch/install.out" 2>"$scratch/install.err"; then
    fail "$agent: installed a tarball with the wrong hash"
  else
    pass "$agent: a tarball with the wrong hash stops the install"
  fi
  check "$agent: says 'integrity mismatch'" grep -q 'integrity mismatch' "$scratch/install.err"
  check "$agent: shows the pinned and the downloaded hash" grep -qF "$fake_integrity" "$scratch/install.err"
  if [ -e "$prefix" ]; then fail "$agent: something was unpacked before verification"; else pass "$agent: nothing was unpacked"; fi
  if [ ! -s "$scratch/install.out" ]; then pass "$agent: prints no version on failure"; else fail "$agent: printed '$(cat "$scratch/install.out")' on failure"; fi
  check "$agent: asked npm for the exact version" grep -q "^pack .*@$version" "$log"
  check_not "$agent: asked npm for nothing but pack" grep -qv '^pack ' "$log"

  # --- The functions, loaded without running main ----------------------------
  rc=0
  (
    # shellcheck disable=SC1090
    source "$file"
    [ "$(integrity_of "$scratch/fake.tgz")" = "$fake_integrity" ] || exit 11
    work="$scratch/work.$agent"
    mkdir -p "$work"
    export PATH="$scratch/bin:$PATH" FAKE_TARBALL="$scratch/fake.tgz" FAKE_NPM_LOG="$log"
    got="$(fetch_verified "fake@0.0.0" "$fake_integrity" "$work/ok" 2>/dev/null)" || exit 12
    [ -f "$got" ] || exit 13
    if fetch_verified "fake@0.0.0" "sha512-AAAA" "$work/bad" >/dev/null 2>&1; then exit 14; fi
    unpack "$got" "$work/unpacked" || exit 15
    [ -f "$work/unpacked/package.json" ] && [ -x "$work/unpacked/bin/tool" ] || exit 15
    # No setuid, setgid or sticky bit; nothing writable by group or others.
    [ -z "$(find "$work/unpacked" -perm /7022)" ] || exit 16
  ) || rc=$?
  case "$rc" in
    0) pass "$agent: integrity_of, fetch_verified and unpack behave (hash match accepted, mismatch refused, setuid and loose permissions removed)" ;;
    11) fail "$agent: integrity_of computes a different hash than python's hashlib" ;;
    12 | 13) fail "$agent: fetch_verified refused a tarball with the right hash" ;;
    14) fail "$agent: fetch_verified accepted a tarball with the wrong hash" ;;
    15) fail "$agent: unpack did not strip the package/ prefix or lost the executable bit" ;;
    16) fail "$agent: unpack left setuid or group/world-writable files" ;;
    *) fail "$agent: function test ended with status $rc" ;;
  esac
done

finish
