#!/usr/bin/env bash
# tests/verify/host-fake-podman.sh — scripts/verify.sh against a fake `podman`.
#
# There is no container runtime on the machine these tests run on, so this
# cannot show that a barrier holds. What it shows is that the HOST-SIDE logic
# of verify.sh is not vacuous: given what Podman would report for a good
# session it passes, and given what Podman would report for a broken one (a
# writable bind mount, a gateway on the network, a capability added,
# privileged, the real token inside, ...) the right check FAILS and the exit
# status is 1.
#
# How
#   * A fake `podman` is written into this test's temporary directory and put
#     first on PATH. It answers `inspect`, `network inspect`, `volume
#     inspect`, `ps`, `info` and `logs` from canned files, one set per
#     scenario. It does NOT check that the --format templates are ones a real
#     Podman accepts: only a real Podman can.
#   * `podman exec <agent> verify-inside.sh ...` is answered with canned PASS
#     lines: the in-container probes have their own test (inside-smoke.sh).
#   * The second sidecar that verify.sh starts for B22-B25 is REAL: the fake
#     `podman start` runs images/credsidecar/sidecar.mjs as a plain process
#     on loopback, verify.sh's own mock vendor runs beside it, and the
#     agent's requests are made by the real images/agent/verify-inside.sh.
#     So those checks are exercised end to end, minus the container.
#   * A fake `secret-tool` stands in for the keyring and holds a made-up
#     token; a stand-in `sandbox` offers `logs` with the launcher's real
#     output filter.
#
# Exit 0 = every scenario behaved as expected.
set -euo pipefail
# The test card puts the test key in the terminal's environment, and verify.sh
# reads it; the "no credential" scenario below must not see it.
unset SANDBOX_TEST_ANTHROPIC_KEY

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

for tool in node tar shellcheck; do
  command -v "$tool" >/dev/null 2>&1 || { echo "tests/verify: $tool is needed and is not installed" >&2; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/verify-test.XXXXXX")"
SESSION=asb-test-abc123
# Made up for this test. It has the shape the search looks for (long, with a
# digit and both cases of letter) and opens nothing.
TOKEN="sk-ant-oat01-FAKEfake0123456789TESTtest0123456789abcdefXYZ"

stop_processes() {
  local file
  for file in "$T"/fake/*.pid; do
    if [ -f "$file" ]; then kill "$(cat "$file")" 2>/dev/null || true; fi
  done
  pkill -f "$T/fake" 2>/dev/null || true
}
trap 'stop_processes; rm -rf "$T"' EXIT

# The mock vendor inside verify.sh listens on 127.0.0.1:9000, as it does in
# the second sidecar's own loopback. Here that is this machine's loopback.
if ! node -e 'require("net").createServer().once("error",()=>process.exit(1)).listen(9000,"127.0.0.1",function(){this.close()})'; then
  echo "tests/verify: port 9000 on 127.0.0.1 is in use; the sidecar scenarios cannot run here" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# A copy of the repository's shape, with verify.sh as shipped.
# ---------------------------------------------------------------------------
mkdir -p "$T/root/scripts" "$T/bin" "$T/home"
cp "$repo/scripts/verify.sh" "$repo/scripts/allowlist.sh" "$T/root/scripts/"
cp "$repo/topology.sh" "$repo/VERSION" "$T/root/"
cp -R "$repo/policy" "$repo/agents" "$T/root/"

# A stand-in launcher: `logs`, printed through the real launcher's filter.
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  sed -n '/^filter_control() {$/,/^}$/p' "$repo/sandbox"
  cat <<'EOF'
[ "${1:-}" = logs ] || { echo "stand-in launcher: only logs" >&2; exit 1; }
if [ -e "$FAKE/knob.unfiltered-logs" ]; then
  podman logs "$SANDBOX_SESSION-$2"
else
  podman logs "$SANDBOX_SESSION-$2" 2>&1 | filter_control
fi
EOF
} > "$T/root/sandbox"
grep -q 'filter_control()' "$T/root/sandbox" || { echo "tests/verify: could not find filter_control in ./sandbox" >&2; exit 1; }
printf '#!/usr/bin/env bash\necho "doctor: all good"\n' > "$T/root/scripts/doctor.sh"
chmod +x "$T/root/sandbox" "$T/root/scripts/doctor.sh"

# The keyring.
cat > "$T/bin/secret-tool" <<'EOF'
#!/usr/bin/env bash
[ -e "$FAKE/knob.empty-keyring" ] && exit 1
[ "$*" = "lookup service agent-sandbox agent claude auth oauth" ] || exit 1
cat "$FAKE/keyring"
EOF

# A sidecar that does nothing a sidecar should: it forwards whatever it is
# sent, credential and all, to the mock vendor.
cat > "$T/bad-sidecar.js" <<'EOF'
const http = require("http");
http.createServer((req, res) => {
  if (req.method === "GET") { res.end("ok"); return; }
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const up = http.request({ host: "127.0.0.1", port: 9000, method: req.method, path: req.url, headers: req.headers }, (r) => {
      res.writeHead(r.statusCode, r.headers); r.pipe(res);
    });
    up.on("error", () => { res.writeHead(502); res.end(); });
    up.end(Buffer.concat(chunks));
  });
}).listen(Number(process.argv[2]), "127.0.0.1");
EOF

# ---------------------------------------------------------------------------
# The fake podman.
# ---------------------------------------------------------------------------
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
# A fake `podman` for tests/verify. Answers from canned files under $FAKE.
set -u
F="${FAKE:?}"; REPO="${FAKE_REPO:?}"; SESSION="${FAKE_SESSION:?}"
printf '%s\n' "$*" >> "$F/calls"
knob() { [ -e "$F/knob.$1" ]; }
role_of() { printf '%s' "${1#"$SESSION"-}"; }

# What the agent container answers when verify-inside.sh is run in it.
inside() {
  local arg name params=() names=() marker="" denied=""
  for arg in "$@"; do
    case "$arg" in
      marker=*) marker="${arg#marker=}"; params+=("$arg") ;;
      denied_host=*) denied="${arg#denied_host=}"; params+=("$arg") ;;
      *=*) params+=("$arg") ;;
      *) names+=("$arg") ;;
    esac
  done
  printf '%s\n' "${params[*]}" > "$F/last-params"
  for name in "${names[@]}"; do
    case "$name" in
      sidecar-probe)
        # The real probe, against the real sidecar on this machine's loopback.
        bash "$REPO/images/agent/verify-inside.sh" "${params[@]}" target=127.0.0.1 "sidecar_port=$(cat "$F/sidecar.port")" sidecar-probe
        continue ;;
      plant-escapes)
        printf '\033]0;%s\007\033[2J\033[31m%s\033[0m\n' "$marker" "$marker" >> "$F/agent.log"
        printf '[02/Oct/2026:10:00:00] src=10.201.7.10 TCP_DENIED/403 GET http://%s/%s%%1B]0;x%%07%%1B[2J\n' "$denied" "$marker" >> "$F/proxy.log"
        printf 'log planted\nrequest http 403\n'
        continue ;;
    esac
    if knob "drop-$name"; then continue; fi
    if knob "fail-$name"; then printf 'FAIL %s canned failure\n  fix: canned fix\n' "$name"; continue; fi
    if knob "skip-$name"; then printf 'SKIP %s (no-probe) canned: could not be tried\n  fix: canned fix\n' "$name"; continue; fi
    if knob "esc-$name"; then printf 'PASS %s canned \033]0;owned\007\033[2J\302\233 detail\n' "$name"; continue; fi
    case "$name" in
      B05-lsm-label) printf 'SKIP %s (no-selinux) canned\n' "$name" ;;
      B15-push) printf 'SKIP %s (no-remote) canned\n' "$name" ;;
      B30-*) printf 'SKIP %s (no-git-relay) canned\n' "$name" ;;
      B20-denied-host)
        printf '[02/Oct/2026:10:00:00] src=10.201.7.10 TCP_DENIED/403 CONNECT %s:443\n' "$denied" >> "$F/proxy.log"
        printf 'PASS %s canned by the fake podman\n' "$name" ;;
      *) printf 'PASS %s canned by the fake podman\n' "$name" ;;
    esac
  done
  if knob spoof && [ "${names[0]#B}" != "${names[0]}" ]; then
    # Lines nobody asked for, and a second answer for a name already given.
    printf 'PASS B99-never-asked spoofed\nPASS %s spoofed twice\nFAIL B98-never-asked spoofed\n  fix: none\n' "${names[0]}"
  fi
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  ps) cat "$F/containers" ;;
  info)
    case "$*" in
      *SELinuxEnabled*) cat "$F/selinux" ;;
      *Rootless*) cat "$F/info" ;;
    esac ;;
  inspect)
    template="$2"; file="$F/inspect/$(role_of "$3")"
    case "$template" in
      *'.Config.Env'*) cat "$F/env.config"; exit 0 ;;
    esac
    [ -f "$file" ] || { echo "Error: no such object: $3" >&2; exit 125; }
    if knob old-podman && [ "$(printf '%s\n' "$template" | grep -c .)" -gt 1 ]; then
      echo "Error: template: inspect:1:22: can't evaluate field Unknown" >&2; exit 125
    fi
    printf '%s\n' "$template" | while IFS= read -r line; do
      key="${line%%=*}"
      if ! grep -q "^$key=" "$file"; then
        echo "Error: template: inspect: can't evaluate field for $key" >&2; exit 125
      fi
      sed -n "s/^$key=/$key=/p" "$file" | head -n 1
    done
    exit "${PIPESTATUS[1]}" ;;
  network) cat "$F/network.json" ;;
  volume) cat "$F/volume" ;;
  logs)
    case "$(role_of "$1")" in
      agent) cat "$F/agent.log" ;;
      proxy) cat "$F/proxy.log" ;;
      verify-credsidecar) cat "$F/testsidecar.log" ;;
    esac ;;
  create)
    printf '%s\n' "$@" > "$F/created.args"
    printf '%s\n' "$@" | sed -n 's/^SANDBOX_BUDGET=//p' > "$F/budget" ;;
  start)
    if [ "$(role_of "$1")" = verify-credsidecar ]; then
      port="$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
      printf '%s\n' "$port" > "$F/sidecar.port"
      mkdir -p "$F/sidecar-state"
      if knob bad-sidecar; then
        node "$F/../bad-sidecar.js" "$port" > "$F/testsidecar.log" 2>&1 &
      else
        SANDBOX_AGENT=claude SANDBOX_AUTH=oauth SANDBOX_BUDGET="$(cat "$F/budget")" HTTPS_PROXY=http://127.0.0.1:3128 \
          SANDBOX_UPSTREAM_OVERRIDE="$(sed -n 's/^SANDBOX_UPSTREAM_OVERRIDE=//p' "$F/created.args")" \
          SANDBOX_SIDECAR_TLS="$(sed -n 's/^SANDBOX_SIDECAR_TLS=//p' "$F/created.args")" \
          SANDBOX_SIDECAR_LISTEN="127.0.0.1:$port" SANDBOX_SIDECAR_STATE_DIR="$F/sidecar-state" SANDBOX_AGENTS_DIR="$REPO/agents" \
          node "$REPO/images/credsidecar/sidecar.mjs" > "$F/testsidecar.log" 2>&1 &
      fi
      printf '%s\n' "$!" > "$F/sidecar.pid"
    fi ;;
  rm)
    for arg in "$@"; do
      if [ "$(role_of "$arg")" = verify-credsidecar ] && [ -f "$F/sidecar.pid" ]; then
        kill "$(cat "$F/sidecar.pid")" 2>/dev/null
        rm -f "$F/sidecar.pid"
      fi
    done ;;
  exec)
    envs=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -i) shift ;;
        -d) shift ;;
        --env) envs+=("$2"); shift 2 ;;
        *) break ;;
      esac
    done
    role="$(role_of "$1")"; shift
    case "$role:$1" in
      agent:/usr/share/sandbox/verify-inside.sh) shift; inside "$@" ;;
      agent:sleep) for item in "${envs[@]}"; do printf '%s\0' "$item" >> "$F/environ"; done ;;
      agent:tar) tar -cf - -C "$F/agentfs" home workspace tmp dev/shm ;;
      agent:rm) rm -f "$F/agentfs/tmp/.verify-canary" ;;
      *:sh)
        case "$3" in
          *'Max core file size'*) cat "$F/probe/$role" ;;
          *'.verify-canary'*) cat > "$F/agentfs/tmp/.verify-canary" ;;
          *environ*) cat "$F/environ" ;;
        esac ;;
      credsidecar:node)
        case "$*" in
          *sidecar.json*) SANDBOX_AGENTS_DIR="$REPO/agents" SANDBOX_AGENT=claude SANDBOX_AUTH=oauth node -e "$3" ;;
          *) cat > /dev/null; if knob vendor-refused; then echo "http 403"; else echo "http 200"; fi ;;
        esac ;;
      verify-credsidecar:sidecar-healthcheck)
        SANDBOX_SIDECAR_LISTEN="127.0.0.1:$(cat "$F/sidecar.port")" node "$REPO/images/credsidecar/sidecar-healthcheck" ;;
      verify-credsidecar:sidecar-load)
        SANDBOX_SIDECAR_STATE_DIR="$F/sidecar-state" node "$REPO/images/credsidecar/sidecar-load" ;;
      verify-credsidecar:node)
        if [ "$2" = - ]; then shift 2; exec node - "$@"; fi      # the mock vendor; its program is on stdin
        node -e "$3" ;;                                           # reading the mock's record
    esac ;;
esac
EOF
chmod +x "$T/bin/podman" "$T/bin/secret-tool"
shellcheck "$T/bin/podman" || { echo "tests/verify: the fake podman is not shellcheck clean" >&2; exit 1; }

# ---------------------------------------------------------------------------
# One fresh, GOOD world per scenario; scenarios then break one thing in it.
# ---------------------------------------------------------------------------
F="$T/fake"
canned_inspect() {   # <role> <user> <netmode> <networks> <timeout> <mounts>
  cat > "$F/inspect/$1" <<EOF
state=running
image=localhost/agent-sandbox/$1:2.0.0
user=$2
readonly=true
privileged=false
capadd=[]
effcaps=[]
bndcaps=[]
secopt=[no-new-privileges]
netmode=$3
pidmode=private
ipcmode=private
cgroupmode=private
devices=[]
memory=268435456
memswap=268435456
nanocpus=1000000000
pids=64
ulimits=RLIMIT_CORE:0:0
tmpfs=
timeout=$5
logdriver=k8s-file
logpath=/home/u/.local/share/containers/storage/overlay-containers/$1/userdata/ctr.log
runtime=crun
networks=$4
mounts=$6
label=
EOF
  cat > "$F/probe/$1" <<'EOF'
CapInh:0000000000000000
CapPrm:0000000000000000
CapEff:0000000000000000
CapBnd:0000000000000000
CapAmb:0000000000000000
NoNewPrivs:1
Core:0 0
Root:sh: can't create /.verify-probe: Read-only file system
Hosts:mounted=no other=none
EOF
}
set_field() {   # <role> <key> <value>
  local tmp="$F/inspect/$1.tmp"
  grep -v "^$2=" "$F/inspect/$1" > "$tmp" || true
  printf '%s=%s\n' "$2" "$3" >> "$tmp"
  mv "$tmp" "$F/inspect/$1"
}
set_probe() {   # <role> <Key> <value>
  local tmp="$F/probe/$1.tmp"
  grep -v "^$2:" "$F/probe/$1" > "$tmp" || true
  printf '%s:%s\n' "$2" "$3" >> "$tmp"
  mv "$tmp" "$F/probe/$1"
}

new_world() {
  stop_processes
  rm -rf "$F" "$T/state"
  mkdir -p "$F/inspect" "$F/probe" "$F/agentfs/home/agent/.claude" "$F/agentfs/workspace/repo" "$F/agentfs/tmp" "$F/agentfs/dev/shm"
  mkdir -p "$T/state/$SESSION/proxy"
  cat > "$T/state/$SESSION/state" <<EOF
SESSION=$SESSION
AGENT=claude
AUTH=oauth
TOOLCHAIN=node
BRANCH=agent/$SESSION
BASE_COMMIT=0000000000000000000000000000000000000000
ORIGIN_URL=
DEADLINE_EPOCH=15400
SUBNET=10.201.7.0/24
EGRESS_SUBNET=10.202.7.0/24
WORKSPACE_DRIVER=memory
SERVICES=
GIT_RELAY=0
CREATED_EPOCH=1000
WORKSPACE_BYTES=268435456
STORE=
EOF
  printf 'registry.npmjs.org\npypi.org\n' > "$T/state/$SESSION/proxy/agent.domains"
  printf 'api.anthropic.com\n' > "$T/state/$SESSION/proxy/sidecar.domains"
  : > "$T/state/$SESSION/proxy/extra.conf"

  printf '%s\n' "$SESSION-keeper" "$SESSION-proxy" "$SESSION-credsidecar" "$SESSION-agent" > "$F/containers"
  local volume="/home/u/.local/share/containers/storage/volumes/$SESSION-workspace/_data"
  canned_inspect keeper 61003:61003 none "" 0 "volume|false|/workspace|$volume;"
  canned_inspect proxy 31:31 bridge "$SESSION-egress $SESSION-sandbox " 14400 "bind|false|/etc/squid/session|$T/state/$SESSION/proxy;"
  canned_inspect credsidecar 61001:61001 bridge "$SESSION-sandbox " 14400 ""
  canned_inspect agent 61000:61000 bridge "$SESSION-sandbox " 14400 "volume|true|/workspace|$volume;"
  set_field agent memory 2684354560
  set_field agent memswap 2684354560
  set_field agent nanocpus 2000000000
  set_field agent pids 512
  set_field agent ulimits "RLIMIT_CORE:0:0 RLIMIT_NOFILE:65536:65536 RLIMIT_NPROC:512:512 RLIMIT_FSIZE:268435456:268435456 "
  set_field agent tmpfs "/dev/shm=rw,nosuid,nodev,noexec,size=64m,mode=1777;/home=rw,nosuid,nodev,size=1073741824,mode=1777;/tmp=rw,nosuid,nodev,size=1g,mode=1777;"
  set_field agent secopt "[no-new-privileges seccomp=$repo/seccomp/agent-seccomp.json]"

  cat > "$F/network.json" <<EOF
[
     {
          "name": "$SESSION-sandbox",
          "driver": "bridge",
          "network_interface": "podman7",
          "subnets": [
               {
                    "subnet": "10.201.7.0/24"
               }
          ],
          "ipv6_enabled": false,
          "internal": true,
          "dns_enabled": false,
          "ipam_options": {
               "driver": "host-local"
          }
     }
]
EOF
  printf 'local|tmpfs|tmpfs|size=268435456,nosuid,nodev,mode=1777\n' > "$F/volume"
  printf 'false\n' > "$F/selinux"
  printf 'true false\n' > "$F/info"
  printf 'HOME=/home/agent\nHTTPS_PROXY=http://10.201.7.2:3128\nSANDBOX_SIDECAR_URL=http://10.201.7.3:8080\n' > "$F/env.config"
  printf 'PATH=/usr/bin\0HOME=/home/agent\0' > "$F/environ"
  printf '{"claudeAiOauth":{"accessToken":"dummy-not-a-real-token"}}\n' > "$F/agentfs/home/agent/.claude/.credentials.json"
  printf 'hello\n' > "$F/agentfs/workspace/repo/README"
  printf 'sandbox-idle: started\n' > "$F/agent.log"
  : > "$F/proxy.log"; : > "$F/testsidecar.log"; : > "$F/calls"
  printf '%s' "$TOKEN" > "$F/keyring"
}

OUT=""; RC=0
verify() {   # arguments for verify.sh
  RC=0
  OUT="$(PATH="$T/bin:$PATH" HOME="$T/home" FAKE="$F" FAKE_REPO="$repo" FAKE_SESSION="$SESSION" SANDBOX_STATE_DIR="$T/state" \
         SANDBOX_CONFIG_DIR="$T/home/config" XDG_RUNTIME_DIR="" SANDBOX_RUNTIME_CLASS="${RUNTIME_CLASS:-}" \
         bash "$T/root/scripts/verify.sh" "$@" 2>&1)" || RC=$?
}

failures=0; scenarios=0; at_start=0
scenario() { scenarios=$((scenarios + 1)); CURRENT="$1"; at_start=$failures; }
not_ok() { failures=$((failures + 1)); printf 'not ok - %s: %s\n' "$CURRENT" "$1"; }
want_rc() { [ "$RC" -eq "$1" ] || not_ok "exit status $RC, expected $1"; }
want() { printf '%s\n' "$OUT" | grep -qE -- "$1" || not_ok "no line matching /$1/"; }
want_not() { if printf '%s\n' "$OUT" | grep -qE -- "$1"; then not_ok "unexpected line matching /$1/: $(printf '%s\n' "$OUT" | grep -E -- "$1" | head -n 1)"; fi; }
# only_failures <name>...: exactly these checks failed, no others.
only_failures() {
  local got want
  got="$(printf '%s\n' "$OUT" | sed -n -e 's/^FAIL \([^ ]*\) .*/\1/p' -e 's/^SKIP \([^ ]*\) .*counts as a failure.*/\1/p' | sort | tr '\n' ' ')"
  want="$(printf '%s\n' "$@" | sort | tr '\n' ' ')"
  [ "$got" = "$want" ] || not_ok "failed checks were [$got], expected [$want]"
}
# Says ok, or shows what verify printed when an assertion above failed.
done_scenario() {
  if [ "$failures" -eq "$at_start" ]; then
    printf 'ok   - %s\n' "$CURRENT"
  elif [ -n "${SHOW:-}" ]; then
    printf '%s\n' "$OUT" | sed 's/^/     | /'
  fi
}

# ---------------------------------------------------------------------------
scenario "a good session passes, quick"
new_world; verify --quick "$SESSION"
want_rc 0
want_not '^FAIL '
want_not 'counts as a failure'
for name in B01-user B02-caps-all B03-nnp-all B04-ptrace B06-private-modes B07-readonly-all B08-workspace-volume B09-host-mounts \
            B10-limits-all B11-core-all B12-network-attach B13-network-no-gateway B13-hosts-all B15-token-absent B20-never-allow B21-sidecar-allowed \
            B22-credential-swap B22-credential-replace B23-mcp-servers B23-web-fetch B24-oversized B24-budget B25-search-logged \
            B25-proxy-log B26-deadline-set B26-keeper B28-log-driver B29-rootless B32-logs-filter; do
  want "^PASS $name — "
done
for name in B05-lsm-label B06-runtime-class B08-fill B10-fork-limit B15-push B26-deadline B27-export B29-doctor B30-other-branch B30-force-push B31-destroy B33-store; do
  want "^SKIP $name — \\((no-selinux|no-runtime-class|quick|no-remote|separate|no-git-relay|memory-workspace)\\)"
done
want ' passed, 0 failed, 13 skipped for a stated reason'
# What the launcher asked Podman for reaches the in-container checks by value.
for pair in uid=61000 pids=512 mem=2684354560 cpu_milli=2000 nofile=65536 nproc=512 fsize=268435456 tmp_size=1073741824 \
            home_size=1073741824 shm_size=67108864 ws_size=268435456 ws_driver=memory subnet=10.201.7 gateway=10.201.7.1 \
            proxy=10.201.7.2 sidecar=10.201.7.3 allowed_host=registry.npmjs.org vendor_host=api.anthropic.com selinux=false; do
  grep -q "verify-inside.sh.* $pair " "$F/calls" || not_ok "verify-inside.sh was not given $pair"
done
# The second sidecar was asked for with the hardening of the first.
for flag in --read-only --cap-drop=ALL --security-opt=no-new-privileges "SANDBOX_BUDGET=3" "$SESSION-verify-credsidecar" "$SESSION-sandbox:ip=10.201.7.250"; do
  grep -qxF -- "$flag" "$F/created.args" || not_ok "the second sidecar was created without $flag"
done
# The real token never went into a container, by argument or by stdin.
if grep -qF "$TOKEN" "$F/calls" "$F/agentfs" -r 2>/dev/null; then not_ok "the real token was passed to podman or written into the agent"; fi
if printf '%s' "$OUT" | grep -qF "$TOKEN"; then not_ok "the real token was printed"; fi
done_scenario

# [TLS] run exports SANDBOX_SIDECAR_TLS=1 for a Codex subscription session and
# verify.sh inherits it. The second sidecar must stay plain HTTP all the same:
# it is created with the switch off, comes up, and B22-B25 run.
scenario "called from a TLS session, the second sidecar is still plain HTTP"
new_world
export SANDBOX_SIDECAR_TLS=1
verify --quick "$SESSION"
unset SANDBOX_SIDECAR_TLS
want_rc 0
want_not 'no-test-sidecar'
grep -qxF -- "SANDBOX_SIDECAR_TLS=" "$F/created.args" || not_ok "the second sidecar was not created with TLS switched off"
for name in B22-credential-swap B22-credential-replace B23-mcp-servers B23-web-fetch B24-oversized B24-budget B25-search-logged; do
  want "^PASS $name — "
done
done_scenario

scenario "a good session passes in full, and with stdout not a terminal there is no colour"
new_world; verify "$SESSION"
want_rc 0
want '^PASS B08-fill — '; want '^PASS B10-fork-limit — '; want '^PASS B29-doctor — '
want ' passed, 0 failed, 10 skipped'
if printf '%s' "$OUT" | LC_ALL=C grep -q $'\033'; then not_ok "escape characters in output that is not going to a terminal"; fi
done_scenario

scenario "a writable bind mount in the agent"
new_world; set_field agent mounts "volume|true|/workspace|/vol;bind|true|/host-data|/srv/data;"
verify --quick "$SESSION"; want_rc 1; only_failures B09-host-mounts
want 'FAIL B09-host-mounts — .*agent: /srv/data is mounted at /host-data'; want '^  fix: '; done_scenario

scenario "a read-only bind mount in the agent is still a host folder"
new_world; set_field agent mounts "volume|true|/workspace|/vol;bind|false|/opt/profile|/home/u/profile;"
verify --quick "$SESSION"; want_rc 1; only_failures B09-host-mounts; done_scenario

scenario "a writable host directory in the proxy, holding its log"
new_world; set_field proxy mounts "bind|false|/etc/squid/session|$T/state/$SESSION/proxy;bind|true|/var/log/squid|/home/u/.local/share/containers/storage/overlay-containers/proxy/userdata;"
verify --quick "$SESSION"; want_rc 1; only_failures B09-host-mounts B28-log-driver
want 'FAIL B28-log-driver — .*the log of proxy'; done_scenario

scenario "the keeper has the workspace writable"
new_world; set_field keeper mounts "volume|true|/workspace|/vol;"
verify --quick "$SESSION"; want_rc 1; only_failures B09-host-mounts; done_scenario

scenario "the network has a gateway"
new_world; sed -i.bak 's|"subnet": "10.201.7.0/24"|"subnet": "10.201.7.0/24",\n                    "gateway": "10.201.7.1"|' "$F/network.json"
verify --quick "$SESSION"; want_rc 1; only_failures B13-network-no-gateway
want 'FAIL B13-network-no-gateway — .*gateway address 10.201.7.1'; done_scenario

scenario "the network has its name service on"
new_world; sed -i.bak 's/"dns_enabled": false/"dns_enabled": true/' "$F/network.json"
verify --quick "$SESSION"; want_rc 1; only_failures B13-network-no-gateway; done_scenario

scenario "Podman wrote a container's /etc/hosts"
new_world; set_probe credsidecar Hosts "mounted=yes other= 192.168.1.20"
verify --quick "$SESSION"; want_rc 1; only_failures B13-hosts-all
want 'FAIL B13-hosts-all — .*credsidecar: Podman has mounted its own /etc/hosts'; done_scenario

scenario "a container's own /etc/hosts holds an outside address"
new_world; set_probe proxy Hosts "mounted=no other= 192.168.1.20"
verify --quick "$SESSION"; want_rc 1; only_failures B13-hosts-all
want 'FAIL B13-hosts-all — .*proxy: /etc/hosts holds addresses that are not loopback: 192.168.1.20'; done_scenario

scenario "the network is not internal"
new_world; sed -i.bak 's/"internal": true/"internal": false/' "$F/network.json"
verify --quick "$SESSION"; want_rc 1; only_failures B12-network-attach; done_scenario

scenario "the agent is on the egress network too"
new_world; set_field agent networks "$SESSION-egress $SESSION-sandbox "
verify --quick "$SESSION"; want_rc 1; only_failures B12-network-attach; done_scenario

scenario "a capability added to the proxy"
new_world; set_field proxy capadd "[CAP_NET_RAW]"; set_field proxy bndcaps "[CAP_NET_RAW]"; set_probe proxy CapBnd 0000000000002000
verify --quick "$SESSION"; want_rc 1; only_failures B02-caps-all
want 'FAIL B02-caps-all — .*proxy: Podman reports capadd=\[CAP_NET_RAW\]'; want 'proxy: the kernel reports CapBnd=0000000000002000'; done_scenario

scenario "capabilities only the kernel shows (Podman's report looks clean)"
new_world; set_probe credsidecar CapBnd 00000000a80425fb
verify --quick "$SESSION"; want_rc 1; only_failures B02-caps-all; done_scenario

scenario "a privileged container"
new_world; set_field credsidecar privileged true
verify --quick "$SESSION"; want_rc 1; only_failures B06-private-modes
want 'FAIL B06-private-modes — .*credsidecar: privileged=true'; done_scenario

scenario "host network, host process list"
new_world; set_field agent netmode host; set_field agent pidmode host
verify --quick "$SESSION"; want_rc 1; only_failures B06-private-modes
want 'agent: pidmode=host'; want 'agent: network mode host'; done_scenario

scenario "a device passed in"
new_world; set_field agent devices "[{/dev/fuse /dev/fuse rwm}]"
verify --quick "$SESSION"; want_rc 1; only_failures B06-private-modes; done_scenario

scenario "no-new-privileges missing on one container"
new_world; set_field proxy secopt "[]"; set_probe proxy NoNewPrivs 0
verify --quick "$SESSION"; want_rc 1; only_failures B03-nnp-all; done_scenario

scenario "a root filesystem that only LOOKS unwritable (permission denied, not read-only)"
new_world; set_field proxy readonly false; set_probe proxy Root "sh: can't create /.verify-probe: Permission denied"
verify --quick "$SESSION"; want_rc 1; only_failures B07-readonly-all
want "a write to / answered .*Permission denied"; done_scenario

scenario "swap allowance not zero, no CPU limit"
new_world; set_field agent memswap 5368709120; set_field proxy nanocpus 0
verify --quick "$SESSION"; want_rc 1; only_failures B10-limits-all; done_scenario

scenario "core dumps on in the sidecar"
new_world; set_probe credsidecar Core "unlimited unlimited"
verify --quick "$SESSION"; want_rc 1; only_failures B11-core-all; done_scenario

scenario "no deadline on the proxy; a deadline on the keeper"
new_world; set_field proxy timeout 0; set_field keeper timeout 14400
verify --quick "$SESSION"; want_rc 1; only_failures B26-deadline-set
want 'proxy: Podman.s own deadline is .0. s'; want 'the keeper has a deadline'; done_scenario

scenario "the keeper is on a network and runs as the agent's user"
new_world; set_field keeper netmode bridge; set_field keeper user 61000:61000
verify --quick "$SESSION"; want_rc 1; only_failures B26-keeper; done_scenario

scenario "logs go to the journal"
new_world; set_field agent logdriver journald
verify --quick "$SESSION"; want_rc 1; only_failures B28-log-driver; done_scenario

scenario "the workspace volume has no size cap"
new_world; printf 'local|tmpfs|tmpfs|nosuid,nodev,mode=1777\n' > "$F/volume"
verify --quick "$SESSION"; want_rc 1; only_failures B08-workspace-volume; done_scenario

scenario "Podman is not rootless"
new_world; printf 'false false\n' > "$F/info"
verify --quick "$SESSION"; want_rc 1; only_failures B29-rootless; done_scenario

scenario "the real token in a file in the agent's home"
new_world; printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$TOKEN" > "$F/agentfs/home/agent/.claude/.credentials.json"
verify --quick "$SESSION"; want_rc 1; only_failures B15-token-absent
want 'FAIL B15-token-absent — YOUR REAL CREDENTIAL IS INSIDE.*a file in the home directory'
if printf '%s' "$OUT" | grep -qF "$TOKEN"; then not_ok "the real token was printed"; fi
done_scenario

scenario "the real token inside a binary file in the workspace"
new_world; { head -c 100000 /dev/urandom; printf '%s' "$TOKEN"; head -c 100000 /dev/urandom; } > "$F/agentfs/workspace/repo/blob.bin"
verify --quick "$SESSION"; want_rc 1; only_failures B15-token-absent; done_scenario

scenario "the real token in the container's environment"
new_world; printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN" >> "$F/env.config"
verify --quick "$SESSION"; want_rc 1; only_failures B15-token-absent
want "the container's environment"; done_scenario

scenario "the real token in a running process's environment"
new_world; printf 'ANTHROPIC_API_KEY=%s\0' "$TOKEN" >> "$F/environ"
verify --quick "$SESSION"; want_rc 1; only_failures B15-token-absent
want "a running process's environment"; done_scenario

scenario "no credential in the keyring: not tested is not passed"
new_world; : > "$F/knob.empty-keyring"
verify --quick "$SESSION"; want_rc 1; only_failures B15-token-absent
want 'SKIP B15-token-absent — \(no-credential\).*counts as a failure'; want '^  fix: store it with ./sandbox login'; done_scenario

scenario "the copy out of the agent is empty: the canary is missed, so no pass"
new_world; cat > "$T/bin/tar" <<'EOF'
#!/bin/sh
exit 2
EOF
chmod +x "$T/bin/tar"
verify --quick "$SESSION"; rm -f "$T/bin/tar"; want_rc 1; only_failures B15-token-absent
want 'SKIP B15-token-absent — \(canary-not-found\)'; done_scenario

scenario "an in-container check fails"
new_world; : > "$F/knob.fail-B04-ptrace"
verify --quick "$SESSION"; want_rc 1; only_failures B04-ptrace
want '^FAIL B04-ptrace — canned failure$'; want '^  fix: canned fix$'; done_scenario

scenario "an in-container check never reports (the probe died)"
new_world; : > "$F/knob.drop-B12-no-route"
verify --quick "$SESSION"; want_rc 1; only_failures B12-no-route
want 'FAIL B12-no-route — the check inside the agent container did not report'; done_scenario

scenario "an in-container check could not run: SKIP for a reason not on the list is a failure"
new_world; : > "$F/knob.skip-B16-add-address"
verify --quick "$SESSION"; want_rc 1; only_failures B16-add-address
want 'SKIP B16-add-address — \(no-probe\) canned: could not be tried \[counts as a failure'; done_scenario

scenario "lines the container was not asked for are ignored"
new_world; : > "$F/knob.spoof"
verify --quick "$SESSION"; want_rc 0; want_not 'B99-never-asked|B98-never-asked|spoofed twice'; done_scenario

scenario "escape sequences from a container do not reach the terminal"
new_world; : > "$F/knob.esc-B01-user"
verify --quick "$SESSION"; want_rc 0; want '^PASS B01-user — canned .*owned.* detail$'
if [ "$(printf '%s' "$OUT" | LC_ALL=C tr -cd '\000-\010\013-\037\177' | wc -c)" -ne 0 ]; then not_ok "control characters in verify's output"; fi
if printf '%s' "$OUT" | LC_ALL=C grep -q $'\302\233'; then not_ok "the two-byte form of an escape character in verify's output"; fi
done_scenario

scenario "./sandbox logs prints a container's escape sequences unfiltered"
new_world; : > "$F/knob.unfiltered-logs"
verify --quick "$SESSION"; want_rc 1; only_failures B32-logs-filter; done_scenario

scenario "the proxy logged nothing"
new_world; : > "$F/knob.drop-B20-denied-host"
verify --quick "$SESSION"; want_rc 1; only_failures B20-denied-host B25-proxy-log; done_scenario

scenario "the vendor's host is refused even from the sidecar: the control fails"
new_world; : > "$F/knob.vendor-refused"
verify --quick "$SESSION"; want_rc 1; only_failures B21-sidecar-allowed; done_scenario

scenario "a sidecar that forwards everything: dummy credential, MCP, URL fetch, big bodies, no budget, no log"
new_world; : > "$F/knob.bad-sidecar"
verify --quick "$SESSION"; want_rc 1
only_failures B22-credential-swap B22-credential-replace B23-mcp-servers B23-web-fetch B24-oversized B24-budget B25-search-logged
want 'FAIL B22-credential-swap — .*dummy credential reached the vendor'; done_scenario

scenario "the never-allow list is not enforced"
new_world
cat > "$T/root/scripts/allowlist.sh" <<'EOF'
allowlist_add() { mkdir -p "$SANDBOX_CONFIG_DIR"; printf '%s\t%s\t%s\t%s\n' "$@" >> "$SANDBOX_CONFIG_DIR/allowlist.local"; }
allowlist_render() { cut -f2 "$SANDBOX_CONFIG_DIR/allowlist.local" > "$1/proxy/agent.domains"; }
EOF
verify --quick "$SESSION"; cp "$repo/scripts/allowlist.sh" "$T/root/scripts/allowlist.sh"
want_rc 1; only_failures B20-never-allow
want 'allowlist_add accepted it'; want 'allowlist_render wrote lists with it'; done_scenario

scenario "SANDBOX_RUNTIME_CLASS=runsc asked for, crun in use"
new_world; RUNTIME_CLASS=runsc verify --quick "$SESSION"; want_rc 1; only_failures B06-runtime-class; done_scenario

scenario "SANDBOX_RUNTIME_CLASS=runsc asked for and in use"
new_world; for role in keeper agent proxy credsidecar; do set_field "$role" runtime /usr/local/bin/runsc; done
RUNTIME_CLASS=runsc verify --quick "$SESSION"; want_rc 0; want '^PASS B06-runtime-class — '; done_scenario

scenario "a Podman that refuses the combined template: fields are read one by one"
new_world; : > "$F/knob.old-podman"
verify --quick "$SESSION"; want_rc 0; want_not '^FAIL '; done_scenario

scenario "a Podman without one of the fields: only the checks that need it fail"
new_world; : > "$F/knob.old-podman"
for role in keeper agent proxy credsidecar; do grep -v '^cgroupmode=' "$F/inspect/$role" > "$F/inspect/$role.tmp"; mv "$F/inspect/$role.tmp" "$F/inspect/$role"; done
verify --quick "$SESSION"; want_rc 1; only_failures B06-private-modes
want "cgroupmode=!unreadable \\(Error: template: inspect: can.t evaluate field for cgroupmode\\)"; done_scenario

scenario "SELinux host: the label is asked for inside"
new_world; printf 'true\n' > "$F/selinux"; set_field agent label "system_u:system_r:container_t:s0:c1,c2"
verify --quick "$SESSION"; want_rc 0
grep -q 'verify-inside.sh.* selinux=true label=system_u:system_r:container_t:s0:c1,c2 ' "$F/calls" || not_ok "the label was not handed to the in-container check"
grep -qxF 'label=type:container_t' "$F/created.args" || not_ok "the second sidecar was created without the SELinux option"
done_scenario

scenario "disk-backed workspace: the volume must be the session's directory on the store"
new_world
sed -i.bak -e 's/^WORKSPACE_DRIVER=.*/WORKSPACE_DRIVER=local/' -e 's|^STORE=.*|STORE=/srv/sandbox-store|' "$T/state/$SESSION/state"
printf 'local|none|/somewhere/else|bind,nosuid,nodev\n' > "$F/volume"
verify --quick "$SESSION"; want_rc 1; only_failures B08-workspace-volume
printf 'local|none|/srv/sandbox-store/%s|bind,nosuid,nodev\n' "$SESSION" > "$F/volume"
verify --quick "$SESSION"; want_rc 0; want 'SKIP B33-store — \(separate\)'; done_scenario

scenario "a stopped session is refused, not half-checked"
new_world; set_field agent state exited
verify --quick "$SESSION"; want_rc 1; want "the agent container of $SESSION is 'exited', not running"; want_not '^PASS '; done_scenario

scenario "usage errors"
new_world
verify --quick 'asb-x; rm -rf /'; want_rc 1; want 'is not a session name'
verify asb-none-000000; want_rc 1; want 'there is no session named'
verify; want_rc 1; want 'usage: verify.sh'
done_scenario

stop_processes
printf '\n%s scenarios, %s assertion(s) failed\n' "$scenarios" "$failures"
[ "$failures" -eq 0 ]
