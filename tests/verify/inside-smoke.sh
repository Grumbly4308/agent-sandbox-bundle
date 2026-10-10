#!/usr/bin/env bash
# tests/verify/inside-smoke.sh — runs images/agent/verify-inside.sh as a
# plain process on the machine the tests run on.
#
# THIS IS NOT A VERIFY RESULT. The machine running the tests is not an
# agent-sandbox session, so whether a probe says PASS or FAIL here says
# nothing about the sandbox. (The build machine happens to be a container
# with no capabilities and a system-call filter, so many probes pass on it,
# and the ones about mounts, DNS and the gateway fail on it, rightly: it is
# the previous version of this sandbox.) Those lines are printed with the
# prefix "smoke:" so nobody mistakes them for a result.
#
# What IS asserted, because it holds on any Linux machine:
#   1. Shape: every check asked for prints exactly one PASS, FAIL or SKIP
#      line, every FAIL is followed by a fix line, the output is printable
#      ASCII, an unknown name is a FAIL.
#   2. Limits are compared by value: a check passes when given the number the
#      kernel really reports and fails when given a different one.
#   3. The skip reasons that depend only on arguments.
#   4. Proxy and sidecar probes against stand-ins on loopback: they pass
#      against a strict proxy, fail against one that allows everything or
#      believes a forged X-Forwarded-For, and fail (not pass!) against a dead
#      one. B23-unknown-path runs against the real sidecar program.
#   5. The raw system-call probes give the same answers through python3 and
#      through perl, and say SKIP when neither is there.
#
# Exit 0 = every assertion held.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
inside="$repo/images/agent/verify-inside.sh"

command -v node >/dev/null 2>&1 || { echo "tests/verify: node is needed and is not installed" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || { echo "tests/verify: the in-container probes read /proc and need Linux" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/verify-smoke.XXXXXX")"
# Process ids of the stand-ins started below, one per line: a file, because
# some are started inside $( ), where a variable would be lost.
: > "$T/pids"
tidy_up() {
  local pid
  while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$T/pids"
  rm -rf "$T"
}
trap tidy_up EXIT

failures=0
not_ok() { failures=$((failures + 1)); printf 'not ok - %s\n' "$1"; }
ok() { printf 'ok   - %s\n' "$1"; }
# status_of <output> <name> -> PASS|FAIL|SKIP|(nothing)
status_of() { printf '%s\n' "$1" | sed -n "s/^\\([A-Z]*\\) $2 .*/\\1/p" | head -n 1; }
expect() {   # <what> <output> <name> <wanted status>
  local got
  got="$(status_of "$2" "$3")"
  if [ "$got" = "$4" ]; then ok "$1: $3 is $4"; else not_ok "$1: $3 is '${got:-missing}', expected $4 ($(printf '%s\n' "$2" | grep " $3 " | head -n 1 | cut -c1-200))"; fi
}

# ---------------------------------------------------------------------------
# 1. Shape, with every check that is safe to run anywhere.
# ---------------------------------------------------------------------------
names="$(sed -n 's/^    \(B[0-9][0-9]-[a-z0-9-]*\)) .*/\1/p' "$inside" | grep -v -e '^B08-fill$' -e '^B10-fork-limit$' | tr '\n' ' ')"
[ "$(printf '%s' "$names" | wc -w)" -ge 45 ] || not_ok "could not read the list of check names from verify-inside.sh"

limit() { sed -n "s/^$1  *\\([^ ]*\\)  *\\([^ ]*\\).*/\\1/p" /proc/self/limits; }
limit_hard() { sed -n "s/^$1  *\\([^ ]*\\)  *\\([^ ]*\\).*/\\2/p" /proc/self/limits; }
cg() { cat "/sys/fs/cgroup/$1" 2>/dev/null || true; }
# shellcheck disable=SC2086  # $names is a list of words
out="$(bash "$inside" "uid=$(id -u)" "pids=$(cg pids.max)" "mem=$(cg memory.max)" \
        "nofile=$(limit 'Max open files')" "nproc=$(limit 'Max processes')" "fsize=$(limit 'Max file size')" \
        gateway=127.0.0.1 subnet=127.0.0 proxy=127.0.0.1 proxy_port=1 sidecar=127.0.0.1 sidecar_port=1 \
        allowed_host=allowed.test vendor_host=vendor.test denied_host=denied.test selinux=false \
        $names B99-no-such-check 2>&1)" || not_ok "verify-inside.sh ended with a non-zero status"

echo "--- smoke test on the build machine, NOT a verify result ---"
printf '%s\n' "$out" | grep -E '^(PASS|FAIL|SKIP) ' | cut -c1-160 | sed 's/^/smoke: /'
echo "--- end of smoke output ---"

shape=0
for name in $names; do
  count="$(printf '%s\n' "$out" | grep -c -E "^(PASS|FAIL|SKIP) $name " || true)"
  [ "$count" -eq 1 ] || { not_ok "shape: $name printed $count result lines, expected 1"; shape=1; }
done
# Every FAIL has its fix on the next line.
if ! printf '%s\n' "$out" | awk '/^FAIL / { want = 1; next } want { if ($0 !~ /^  fix: ./) bad = 1; want = 0 } END { exit bad || want }'; then
  not_ok "shape: a FAIL line is not followed by a fix line"; shape=1
fi
if [ "$(printf '%s' "$out" | LC_ALL=C tr -d '\12\40-\176' | wc -c)" -ne 0 ]; then
  not_ok "shape: the output has bytes that are not printable ASCII"; shape=1
fi
if printf '%s\n' "$out" | grep -v -E '^(PASS|FAIL|SKIP) B[0-9][0-9]-[a-z0-9-]+ .|^  fix: .' | grep -q .; then
  not_ok "shape: a line that is neither a result nor a fix: $(printf '%s\n' "$out" | grep -v -E '^(PASS|FAIL|SKIP) B[0-9][0-9]-[a-z0-9-]+ .|^  fix: .' | head -n 1)"; shape=1
fi
if [ "$shape" -eq 0 ]; then ok "shape: one result per check, a fix after every FAIL, printable ASCII only"; fi
expect "unknown name" "$out" B99-no-such-check FAIL
status=0; bash "$inside" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then ok "no arguments: usage, status 2"; else not_ok "no arguments gave status $status, expected 2"; fi

# ---------------------------------------------------------------------------
# 2. Compared by value.
# ---------------------------------------------------------------------------
expect "own uid" "$(bash "$inside" "uid=$(id -u)" B01-user)" B01-user PASS
expect "another uid" "$(bash "$inside" "uid=$(( $(id -u) + 1 ))" B01-user)" B01-user FAIL
# B11-ulimits wants soft = hard for each limit and core dumps off, so on a host
# whose hard limits are above its soft ones (a usual login) it must say FAIL.
real_limits=PASS
[ "$(limit 'Max core file size') $(limit_hard 'Max core file size')" = "0 0" ] || real_limits=FAIL
for label in 'Max open files' 'Max processes' 'Max file size'; do
  [ "$(limit "$label")" = "$(limit_hard "$label")" ] || real_limits=FAIL
done
expect "the real limits" "$(bash "$inside" "nofile=$(limit 'Max open files')" "nproc=$(limit 'Max processes')" "fsize=$(limit 'Max file size')" B11-ulimits)" B11-ulimits "$real_limits"
expect "one limit off by one" "$(bash "$inside" "nofile=$(( $(limit 'Max open files') + 1 ))" "nproc=$(limit 'Max processes')" "fsize=$(limit 'Max file size')" B11-ulimits)" B11-ulimits FAIL
expect "no value given" "$(bash "$inside" B10-pids-max)" B10-pids-max SKIP
case "$(cg pids.max)" in
  ''|*[!0-9]*) echo "note - no numeric /sys/fs/cgroup/pids.max here; its by-value check was not exercised" ;;
  *) expect "the real pids.max" "$(bash "$inside" "pids=$(cg pids.max)" B10-pids-max)" B10-pids-max PASS
     expect "pids.max off by one" "$(bash "$inside" "pids=$(( $(cg pids.max) + 1 ))" B10-pids-max)" B10-pids-max FAIL ;;
esac
case "$(cg memory.max)" in
  ''|*[!0-9]*) echo "note - no numeric /sys/fs/cgroup/memory.max here; its by-value check was not exercised" ;;
  *) expect "the real memory.max" "$(bash "$inside" "mem=$(cg memory.max)" B10-memory-max)" B10-memory-max PASS
     expect "memory.max doubled" "$(bash "$inside" "mem=$(( $(cg memory.max) * 2 ))" B10-memory-max)" B10-memory-max FAIL ;;
esac
read -r quota period <<EOF
$(cg cpu.max)
EOF
case "$quota${period:-x}" in
  *[!0-9]*) echo "note - no numeric /sys/fs/cgroup/cpu.max here; its by-value check was not exercised" ;;
  *) expect "the real cpu.max" "$(bash "$inside" "cpu_milli=$(( quota * 1000 / period ))" B10-cpu-max)" B10-cpu-max PASS
     expect "cpu.max off" "$(bash "$inside" "cpu_milli=$(( quota * 1000 / period + 500 ))" B10-cpu-max)" B10-cpu-max FAIL ;;
esac
# A largest-file limit set for this one run: a megabyte.
expect "write past a 1 MB file limit" "$( (ulimit -f 1024; bash "$inside" B11-fsize) 2>&1)" B11-fsize PASS
expect "no file limit to exceed" "$( (ulimit -f unlimited 2>/dev/null; bash "$inside" B11-fsize) 2>&1)" B11-fsize \
  "$([ "$(limit 'Max file size')" = unlimited ] && printf FAIL || printf PASS)"
if [ "$(id -u)" -ne 0 ]; then
  # A process limit a little above what this user runs now.
  now="$(ps -u "$(id -u)" -L --no-headers 2>/dev/null | wc -l)"
  expect "fork up to a limit" "$( (ulimit -u $((now + 40)); bash "$inside" "pids=$((now + 40))" B10-fork-limit) 2>&1)" B10-fork-limit PASS
  expect "fork with no limit near" "$(bash "$inside" pids=8 B10-fork-limit 2>&1)" B10-fork-limit FAIL
else
  echo "note - running as root, which the process ulimit does not bind; B10-fork-limit was not exercised"
fi
shm_kb="$(df -k /dev/shm 2>/dev/null | awk 'NR == 2 && $1 ~ /shm|tmpfs/ { print $2 }')"
if [ -n "$shm_kb" ] && [ "$shm_kb" -le 131072 ] && [ -w /dev/shm ]; then
  expect "fill /dev/shm ($((shm_kb / 1024)) MB)" "$(bash "$inside" writable=/dev/shm B08-fill)" B08-fill PASS
  if [ -z "$(find /dev/shm -maxdepth 1 -name '.verify-fill.*' 2>/dev/null)" ]; then ok "the fill files were removed"; else not_ok "B08-fill left files in /dev/shm"; fi
else
  echo "note - /dev/shm is not a small memory mount here; B08-fill was not exercised (it would fill it)"
fi

# ---------------------------------------------------------------------------
# 3. Skips that follow from the arguments alone.
# ---------------------------------------------------------------------------
out="$(bash "$inside" selinux=false allow_http=1 allowed_host=allowed.test git_relay=0 origin_url= B05-lsm-label B20-port-80 B30-other-branch B30-tag B15-push)"
for pair in "B05-lsm-label (no-selinux)" "B20-port-80 (http-allowed)" "B30-other-branch (no-git-relay)" "B30-tag (no-git-relay)" "B15-push (no-remote)"; do
  if printf '%s\n' "$out" | grep -qF "SKIP $pair "; then ok "skip reason: $pair"; else not_ok "expected 'SKIP $pair'"; fi
done

# ---------------------------------------------------------------------------
# 4. Proxy and sidecar probes against stand-ins on loopback.
# ---------------------------------------------------------------------------
cat > "$T/proxy.js" <<'EOF'
// A stand-in for the egress proxy. strict: a tunnel to allowed.test:443 and
// nothing else. open: everything. trusting: strict, but it believes
// X-Forwarded-For.
const net = require("net");
const mode = process.argv[2];
const server = net.createServer((s) => {
  let buf = "";
  s.on("error", () => {});
  s.on("data", (d) => {
    buf += d.toString("latin1");
    if (!buf.includes("\r\n\r\n")) return;
    const line = buf.split("\r\n")[0];
    const ok = mode === "open" || line === "CONNECT allowed.test:443 HTTP/1.1"
      || (mode === "trusting" && /x-forwarded-for: 127\.0\.0\.1/i.test(buf));
    s.end(ok ? "HTTP/1.1 200 Connection established\r\n\r\n" : "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n");
  });
}).listen(0, "127.0.0.1", () => console.log(server.address().port));
EOF
start_proxy() {   # <mode> -> port
  : > "$T/port"
  node "$T/proxy.js" "$1" > "$T/port" 2>/dev/null &
  printf '%s\n' "$!" >> "$T/pids"
  local tries=0
  until [ -s "$T/port" ]; do tries=$((tries + 1)); [ "$tries" -lt 50 ] || return 1; sleep 0.1; done
  cat "$T/port"
}
free_port() { node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }

# The real sidecar program, as a plain process. No credential is loaded: an
# unknown path must be refused before that matters.
sidecar_port="$(free_port)"
mkdir -p "$T/sidecar-state"
SANDBOX_AGENT=claude SANDBOX_AUTH=oauth SANDBOX_BUDGET=3 HTTPS_PROXY=http://127.0.0.1:3128 SANDBOX_UPSTREAM_OVERRIDE=http://127.0.0.1:9 \
  SANDBOX_SIDECAR_LISTEN="127.0.0.1:$sidecar_port" SANDBOX_SIDECAR_STATE_DIR="$T/sidecar-state" SANDBOX_AGENTS_DIR="$repo/agents" \
  node "$repo/images/credsidecar/sidecar.mjs" > "$T/sidecar.log" 2>&1 &
printf '%s\n' "$!" >> "$T/pids"
tries=0
until SANDBOX_SIDECAR_LISTEN="127.0.0.1:$sidecar_port" node "$repo/images/credsidecar/sidecar-healthcheck" >/dev/null 2>&1; do
  tries=$((tries + 1)); [ "$tries" -lt 50 ] || { not_ok "the sidecar program did not start: $(tail -n 1 "$T/sidecar.log")"; break; }
  sleep 0.1
done

refusals="B20-denied-host B20-port-80 B20-connect-port B20-ip-literal-v4 B20-ip-literal-v6 B21-vendor-plain B21-vendor-forged"
probe_proxy() {   # <proxy port> -> output of all proxy checks
  # shellcheck disable=SC2086
  bash "$inside" proxy=127.0.0.1 "proxy_port=$1" sidecar=127.0.0.1 "sidecar_port=$sidecar_port" \
    allowed_host=allowed.test vendor_host=vendor.test denied_host=denied.test B20-allowed-host $refusals B23-unknown-path
}
out="$(probe_proxy "$(start_proxy strict)")"
for name in B20-allowed-host $refusals B23-unknown-path; do expect "strict proxy, real sidecar" "$out" "$name" PASS; done
out="$(probe_proxy "$(start_proxy open)")"
expect "a proxy that allows everything" "$out" B20-allowed-host PASS
for name in $refusals; do expect "a proxy that allows everything" "$out" "$name" FAIL; done
out="$(probe_proxy "$(start_proxy trusting)")"
expect "a proxy that believes X-Forwarded-For" "$out" B21-vendor-plain PASS
expect "a proxy that believes X-Forwarded-For" "$out" B21-vendor-forged FAIL
# Nothing listening at all. A refusal check must not pass because nobody answered.
out="$(probe_proxy "$(free_port)")"
for name in B20-allowed-host $refusals; do expect "a dead proxy" "$out" "$name" FAIL; done
if printf '%s\n' "$out" | grep -q 'nothing was proven'; then ok "a dead proxy: the failure says nothing was proven"; else not_ok "a dead proxy: the reason is not stated"; fi
out="$(bash "$inside" sidecar=127.0.0.1 "sidecar_port=$(free_port)" B23-unknown-path)"
expect "a dead sidecar" "$out" B23-unknown-path FAIL

# [TLS] A TLS sidecar (Codex with a subscription): B23 speaks HTTPS to it
# with the session certificate, which must also name its address.
make_cert() {   # <dir>: key.pem and cert.pem for IP 127.0.0.1
  mkdir -p "$1"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1/key.pem" 2>/dev/null
  openssl req -x509 -key "$1/key.pem" -subj /CN=smoke -addext subjectAltName=IP:127.0.0.1 -days 1 -out "$1/cert.pem" 2>/dev/null
}
make_cert "$T/tls"
make_cert "$T/other-tls"
tls_port="$(free_port)"
mkdir -p "$T/tls-sidecar-state"
SANDBOX_AGENT=codex SANDBOX_AUTH=oauth SANDBOX_BUDGET=3 SANDBOX_SIDECAR_TLS=1 HTTPS_PROXY=http://127.0.0.1:3128 SANDBOX_UPSTREAM_OVERRIDE=http://127.0.0.1:9 \
  SANDBOX_SIDECAR_LISTEN="127.0.0.1:$tls_port" SANDBOX_SIDECAR_STATE_DIR="$T/tls-sidecar-state" SANDBOX_AGENTS_DIR="$repo/agents" \
  node "$repo/images/credsidecar/sidecar.mjs" > "$T/tls-sidecar.log" 2>&1 &
printf '%s\n' "$!" >> "$T/pids"
jq -n --rawfile key "$T/tls/key.pem" --rawfile cert "$T/tls/cert.pem" '{key: $key, cert: $cert}' \
  | SANDBOX_SIDECAR_STATE_DIR="$T/tls-sidecar-state" node "$repo/images/credsidecar/sidecar-load" --tls >/dev/null 2>&1 \
  || not_ok "the TLS sidecar did not take its key"
tries=0
until SANDBOX_SIDECAR_TLS=1 SANDBOX_SIDECAR_LISTEN="127.0.0.1:$tls_port" node "$repo/images/credsidecar/sidecar-healthcheck" >/dev/null 2>&1; do
  tries=$((tries + 1)); [ "$tries" -lt 50 ] || { not_ok "the TLS sidecar did not start: $(tail -n 1 "$T/tls-sidecar.log")"; break; }
  sleep 0.1
done
b64() { base64 < "$1" | tr -d '\n'; }
out="$(bash "$inside" sidecar=127.0.0.1 "sidecar_port=$tls_port" "sidecar_ca=$(b64 "$T/tls/cert.pem")" B23-unknown-path)"
expect "a TLS sidecar, with its certificate" "$out" B23-unknown-path PASS
if printf '%s\n' "$out" | grep -q 'over TLS'; then ok "a TLS sidecar: the pass says it was over TLS"; else not_ok "a TLS sidecar: the pass does not say TLS"; fi
out="$(bash "$inside" sidecar=127.0.0.1 "sidecar_port=$tls_port" "sidecar_ca=$(b64 "$T/other-tls/cert.pem")" B23-unknown-path)"
expect "a TLS sidecar, with some other certificate" "$out" B23-unknown-path FAIL
out="$(bash "$inside" sidecar=127.0.0.1 "sidecar_port=$tls_port" B23-unknown-path)"
expect "a TLS sidecar, asked in plain HTTP" "$out" B23-unknown-path FAIL

# ---------------------------------------------------------------------------
# 5. The raw system-call probes, through each interpreter.
# ---------------------------------------------------------------------------
raw="B02-raw-socket B04-ptrace B04-mount B04-clone-newuser B04-clone3 B04-setns B04-process-vm-readv B04-bpf B16-add-address B16-packet-socket"
bindir() {   # a PATH with everything of this machine's except the programs named
  local dir="$T/bin.$1" file base skip
  shift
  mkdir -p "$dir"
  for file in /usr/local/bin/* /usr/bin/* /bin/*; do
    base="${file##*/}"
    skip=0
    for unwanted in "$@"; do case "$base" in "$unwanted"*) skip=1 ;; esac; done
    if [ "$skip" -eq 0 ] && [ ! -e "$dir/$base" ]; then ln -s "$file" "$dir/$base"; fi
  done
  printf '%s' "$dir"
}
verdicts() { printf '%s\n' "$1" | sed -n 's/^\([A-Z]*\) \(B[^ ]*\) .*/\2=\1/p' | tr '\n' ' '; }
if command -v python3 >/dev/null 2>&1 && command -v perl >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  with_python="$(verdicts "$(PATH="$(bindir nopl perl)" bash "$inside" sidecar=127.0.0.1 $raw)")"
  # shellcheck disable=SC2086
  with_perl="$(verdicts "$(PATH="$(bindir nopy python)" bash "$inside" sidecar=127.0.0.1 $raw)")"
  if [ "$with_python" = "$with_perl" ] && [ "$(printf '%s' "$with_perl" | wc -w)" -eq 10 ]; then
    ok "python3 and perl give the same ten answers ($with_perl)"
  else
    not_ok "python3 says [$with_python], perl says [$with_perl]"
  fi
  case "$with_perl" in *=SKIP*) not_ok "a raw system-call probe was skipped although perl is here" ;; esac
else
  echo "note - python3 and perl are not both installed here; their answers were not compared"
fi
# shellcheck disable=SC2086
none="$(PATH="$(bindir none perl python)" bash "$inside" sidecar=127.0.0.1 $raw)"
if [ "$(printf '%s\n' "$none" | grep -c '^SKIP .* (no-probe) ')" -eq 10 ] && [ "$(printf '%s\n' "$none" | grep -c '^  fix: ')" -eq 10 ]; then
  ok "with neither python3 nor perl, all ten say SKIP (no-probe) with a fix, never PASS"
else
  not_ok "with neither interpreter the probes did not all say SKIP (no-probe): $(verdicts "$none")"
fi

printf '\n%s assertion(s) failed\n' "$failures"
[ "$failures" -eq 0 ]
