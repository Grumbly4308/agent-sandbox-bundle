#!/usr/bin/env bash
# verify-inside.sh — the in-container halves of `./sandbox verify`.
#
# scripts/verify.sh runs this inside the agent container, as the agent's own
# user, with `podman exec`. Each check below ATTEMPTS the bypass a barrier in
# docs/00-threat-model.md is there to stop, and reports what the kernel (or
# the proxy, or the sidecar) answered.
#
# Usage
#   verify-inside.sh [name=value]... <check-name>...
#
#   name=value   what the launcher asked Podman for (limits, sizes, addresses).
#                verify.sh reads these from `podman inspect` on the host and
#                passes them in, so every limit is compared BY VALUE with the
#                request, not merely checked for being present.
#   check-name   one of the names in the list at the end of this file.
#
# Output, one line per check, plain ASCII:
#   PASS <name> <what was tried and what happened>
#   FAIL <name> <what was tried and what happened>
#     fix: <what to do>
#   SKIP <name> (<reason-code>) <why it could not be tried>
# A SKIP is not a pass. verify.sh counts it as a failure unless the reason
# code is on its short list of legitimate ones.
#
# No vacuous checks (closes reference finding M4: the old `cannot sudo` test
# passed because sudo was simply absent). Every check here exercises the
# thing it names, and where a refusal could come from the wrong cause (a dead
# proxy, a file permission instead of a read-only mount) the check tells the
# two apart or runs a control that must succeed.
#
# What this needs from the image, and why
#   bash, coreutils, findutils   the probes themselves
#   node                         network probes (precise error codes); it is
#                                in every toolchain
#   python3 OR perl              raw system calls (ptrace, mount, unshare,
#                                clone, clone3, raw sockets, interface
#                                addresses). node cannot make a raw system
#                                call. python3 is only in the python and full
#                                toolchains; perl is not on the image's list
#                                of installed tools, but `perl-base` is part
#                                of Debian's essential base system, so it is
#                                in the default image all the same. When
#                                neither is there, those checks say SKIP, and
#                                verify.sh counts that as a failure: "could
#                                not test" is never reported as a pass.
#
# This file is a test tool, not a barrier. It runs as the agent's user: on a
# session where untrusted code has already run, its answers are only as
# trustworthy as the container (see the threat model).
set -euo pipefail
export LC_ALL=C

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
declare -A P=(
  [uid]=61000                                   # the agent's fixed user id [B01]
  [writable]="/tmp /home /dev/shm /workspace"   # the only places that may accept files [B08]
  [ws_driver]=memory
  [proxy]=proxy [proxy_port]=3128               # where the egress proxy listens
  [sidecar]=sidecar [sidecar_port]=8080         # where the credential sidecar listens
  [allow_http]=0
  [git_relay]=0
)
CHECKS=()
for arg in "$@"; do
  if [[ "$arg" =~ ^([a-z_]+)=(.*)$ ]]; then
    P[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
  else
    CHECKS+=("$arg")
  fi
done
param() { printf '%s' "${P[$1]:-}"; }

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
REPORTED=0
# Details can contain text that came from files or from the network. Keep
# printable ASCII only, on one line, so nothing printed here can steer the
# operator's terminal. verify.sh filters again on the host. [logical B32]
tidy() { printf '%s' "$1" | tr '\n\r\t' '   ' | tr -cd '\40-\176' | cut -c1-600; }
pass() { printf 'PASS %s %s\n' "$1" "$(tidy "$2")"; REPORTED=1; }
fail() { printf 'FAIL %s %s\n  fix: %s\n' "$1" "$(tidy "$2")" "$(tidy "$3")"; REPORTED=1; }
skip() {   # <name> <reason-code> <detail> [fix]
  printf 'SKIP %s (%s) %s\n' "$1" "$2" "$(tidy "$3")"
  if [ -n "${4:-}" ]; then printf '  fix: %s\n' "$(tidy "$4")"; fi
  REPORTED=1
}
have() { command -v "$1" >/dev/null 2>&1; }

ME_UID="$(id -u)"
ME_GID="$(id -g)"

status_field() {   # <Name> -> the rest of that line of /proc/self/status
  local key value
  while IFS=: read -r key value; do
    if [ "$key" = "$1" ]; then printf '%s' "$value" | tr -s '\t ' ' ' | sed 's/^ //'; return 0; fi
  done < /proc/self/status
  return 1
}

# ---------------------------------------------------------------------------
# Raw system calls: python3 (ctypes) when it is there, else perl (its built-in
# `syscall`). Prints `ok` when the call SUCCEEDED (which is the bad outcome),
# `errno <number> <text>` when the kernel refused, `unavailable <why>` when
# the call could not be made at all.
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"

SYS_PY='
import ctypes, os, socket, struct, sys
arch, what = sys.argv[1], sys.argv[2]
arg = sys.argv[3:]
NR = {"x86_64":  dict(ptrace=101, mount=165, umount2=166, unshare=272, setns=308, clone=56,  clone3=435, pvr=310, bpf=321),
      "aarch64": dict(ptrace=117, mount=40,  umount2=39,  unshare=97,  setns=268, clone=220, clone3=435, pvr=270, bpf=280)}.get(arch)
if NR is None:
    print("unavailable no system call numbers for " + arch); sys.exit(0)
libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
L = ctypes.c_long
def report(r):
    if r == -1:
        e = ctypes.get_errno(); print("errno %d %s" % (e, os.strerror(e)))
    else:
        print("ok")
def child(r):
    # A clone that worked returns twice. The copy must not carry on.
    if r == 0: os._exit(0)
    if r > 0: os.waitpid(r, 0)
    report(r)
def sock(*a):
    try:
        socket.socket(*a); print("ok")
    except OSError as e:
        print("errno %d %s" % (e.errno, e.strerror))
if what == "ptrace":      report(libc.syscall(L(NR["ptrace"]), L(0), L(0), L(0), L(0)))            # PTRACE_TRACEME
elif what == "mount":
    r = libc.syscall(L(NR["mount"]), ctypes.c_char_p(b"none"), ctypes.c_char_p(arg[0].encode()), ctypes.c_char_p(b"tmpfs"), L(0), L(0))
    e = ctypes.get_errno()
    if r == 0: libc.syscall(L(NR["umount2"]), ctypes.c_char_p(arg[0].encode()), L(0))
    ctypes.set_errno(e); report(r)
elif what == "unshare":   report(libc.syscall(L(NR["unshare"]), L(0x10000000)))                    # CLONE_NEWUSER
elif what == "setns":
    fd = os.open("/proc/self/ns/user", os.O_RDONLY)
    report(libc.syscall(L(NR["setns"]), L(fd), L(0x10000000)))
elif what == "clone":     child(libc.syscall(L(NR["clone"]), L(0x10000000 | 17), L(0), L(0), L(0), L(0)))   # CLONE_NEWUSER | SIGCHLD
elif what == "clone3":
    buf = ctypes.create_string_buffer(struct.pack("8Q", 0x10000000, 0, 0, 0, 17, 0, 0, 0), 64)
    child(libc.syscall(L(NR["clone3"]), buf, L(64)))
elif what == "pvr":
    src = ctypes.create_string_buffer(b"verify!!", 8); dst = ctypes.create_string_buffer(8)
    class IOV(ctypes.Structure): _fields_ = [("base", ctypes.c_void_p), ("len", ctypes.c_size_t)]
    l = IOV(ctypes.addressof(dst), 8); r = IOV(ctypes.addressof(src), 8)
    report(libc.syscall(L(NR["pvr"]), L(os.getpid()), ctypes.byref(l), L(1), ctypes.byref(r), L(1), L(0)))
elif what == "bpf":       report(libc.syscall(L(NR["bpf"]), L(0), ctypes.create_string_buffer(64), L(64)))
elif what == "rawsock":   sock(socket.AF_INET, socket.SOCK_RAW, 1)                                 # ICMP
elif what == "pktsock":   sock(17, socket.SOCK_RAW, socket.htons(3))                               # AF_PACKET, every frame
elif what == "addaddr":
    import fcntl
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ifr = struct.pack("16sH2s4s8s", arg[0].encode(), socket.AF_INET, b"\0\0", socket.inet_aton(arg[1]), b"\0" * 8)
    try:
        fcntl.ioctl(s, 0x8916, ifr)                                                                # SIOCSIFADDR
        print("ok")
    except OSError as e:
        print("errno %d %s" % (e.errno, e.strerror))
else: print("unavailable unknown probe " + what)
'

# shellcheck disable=SC2016  # perl code, not shell: the $ signs are perl's
SYS_PL='
use strict; use warnings;
my ($arch, $what, @arg) = @ARGV;
my %all = (
  x86_64  => { ptrace => 101, mount => 165, umount2 => 166, unshare => 272, setns => 308, clone => 56,  clone3 => 435, pvr => 310, bpf => 321 },
  aarch64 => { ptrace => 117, mount => 40,  umount2 => 39,  unshare => 97,  setns => 268, clone => 220, clone3 => 435, pvr => 270, bpf => 280 },
);
my $nr = $all{$arch};
if (!$nr) { print "unavailable no system call numbers for $arch\n"; exit 0; }
sub report { my ($r) = @_; if (!defined $r || $r == -1) { printf "errno %d %s\n", $! + 0, $!; } else { print "ok\n"; } }
sub child {
  # A clone that worked returns twice. The copy must not carry on.
  my ($r) = @_; my $e = $! + 0;
  if ($r == 0) { require POSIX; POSIX::_exit(0); }
  waitpid($r, 0) if $r > 0;
  $! = $e; report($r);
}
$! = 0;
if ($what eq "ptrace") { report(syscall($nr->{ptrace}, 0, 0, 0, 0)); }                              # PTRACE_TRACEME
elsif ($what eq "mount") {
  my ($s, $t, $f) = ("none", $arg[0], "tmpfs");
  my $r = syscall($nr->{mount}, $s, $t, $f, 0, 0); my $e = $! + 0;
  syscall($nr->{umount2}, $t, 0) if $r == 0;
  $! = $e; report($r);
}
elsif ($what eq "unshare") { report(syscall($nr->{unshare}, 0x10000000)); }                         # CLONE_NEWUSER
elsif ($what eq "setns") {
  open(my $fh, "<", "/proc/self/ns/user") or do { print "unavailable cannot open /proc/self/ns/user\n"; exit 0; };
  report(syscall($nr->{setns}, fileno($fh), 0x10000000));
}
elsif ($what eq "clone") { child(syscall($nr->{clone}, 0x10000000 | 17, 0, 0, 0, 0)); }             # CLONE_NEWUSER | SIGCHLD
elsif ($what eq "clone3") { my $buf = pack("Q8", 0x10000000, 0, 0, 0, 17, 0, 0, 0); child(syscall($nr->{clone3}, $buf, 64)); }
elsif ($what eq "pvr") {
  my $src = "verify!!"; my $dst = "\0" x 8;
  my $l = pack("QQ", unpack("Q", pack("P", $dst)), 8); my $r = pack("QQ", unpack("Q", pack("P", $src)), 8);
  report(syscall($nr->{pvr}, $$, $l, 1, $r, 1, 0));
}
elsif ($what eq "bpf") { my $attr = "\0" x 64; report(syscall($nr->{bpf}, 0, $attr, 64)); }
elsif ($what eq "rawsock") { report(socket(my $s, 2, 3, 1) ? 0 : -1); }                             # AF_INET, SOCK_RAW, ICMP
elsif ($what eq "pktsock") { report(socket(my $s, 17, 3, 0x0300) ? 0 : -1); }                       # AF_PACKET, every frame
elsif ($what eq "addaddr") {
  socket(my $s, 2, 2, 0) or do { print "unavailable cannot open a socket\n"; exit 0; };
  my $ifr = pack("a16 S x2 a4 x8", $arg[0], 2, pack("C4", split(/\./, $arg[1])));
  report(defined(ioctl($s, 0x8916, $ifr)) ? 0 : -1);                                                # SIOCSIFADDR
}
else { print "unavailable unknown probe $what\n"; }
'

SYS=""
sys() {   # <probe> [args]; the result goes into SYS
  if have python3 && python3 -c 'import ctypes' 2>/dev/null; then
    SYS="$(python3 -c "$SYS_PY" "$ARCH" "$@" 2>&1 | tail -n 1)" || true
  elif have perl; then
    SYS="$(perl -e "$SYS_PL" "$ARCH" "$@" 2>&1 | tail -n 1)" || true
  else
    SYS="unavailable neither python3 nor perl is in this image"
  fi
  [ -n "$SYS" ] || SYS="unavailable the probe printed nothing (it may have been killed)"
}

NO_SYSCALL_FIX="the image needs python3 or perl for this probe. perl-base is part of Debian's base system: do not remove it from the agent image, or use --toolchain python"

# refused <check> <what was tried> <fix> <accepted errno>...
# Runs after sys(): PASS when the kernel refused with one of the accepted
# error numbers, FAIL when the call worked or failed for another reason.
refused() {
  local name="$1" tried="$2" fix="$3" number
  shift 3
  case "$SYS" in
    unavailable*) skip "$name" no-probe "$tried: not attempted, ${SYS#unavailable }" "$NO_SYSCALL_FIX" ;;
    ok) fail "$name" "$tried: the kernel ALLOWED it" "$fix" ;;
    errno\ *)
      number="${SYS#errno }"; number="${number%% *}"
      if [[ " $* " == *" $number "* ]]; then
        pass "$name" "$tried: refused (${SYS#errno })"
      else
        fail "$name" "$tried: failed, but with ${SYS#errno }, which is not the refusal this barrier gives (expected error number $*)" "$fix"
      fi ;;
    *) fail "$name" "$tried: unexpected answer from the probe: $SYS" "$fix" ;;
  esac
}

SECCOMP_FIX="the agent must be created with --security-opt seccomp=<repo>/seccomp/agent-seccomp.json (topology.sh, topo_agent); regenerate the file with scripts/make-seccomp.sh"

# ---------------------------------------------------------------------------
# Network probes, in node (standard library only).
# ---------------------------------------------------------------------------
NET_JS='
"use strict";
const net = require("net"), dgram = require("dgram"), dns = require("dns"), http = require("http"), https = require("https"), cp = require("child_process");
const [cmd, ...a] = process.argv.slice(1);
const out = (s) => process.stdout.write(s + "\n");

function tcp(host, port, ms) {
  return new Promise((resolve) => {
    let done = false;
    const s = net.connect({ host, port: Number(port) });
    const fin = (r) => { if (!done) { done = true; s.destroy(); resolve(r); } };
    s.setTimeout(Number(ms), () => fin("timeout"));
    s.on("connect", () => fin("connected"));
    s.on("error", (e) => fin(e.code || "error"));
  });
}
// Send raw bytes, answer with the status of the first HTTP reply line.
function exchange(host, port, head, ms) {
  return new Promise((resolve) => {
    let buf = "", done = false;
    const s = net.connect({ host, port: Number(port) });
    const fin = (r) => { if (!done) { done = true; s.destroy(); resolve(r); } };
    s.setTimeout(Number(ms), () => fin("timeout"));
    s.on("connect", () => s.write(head, "latin1"));
    s.on("data", (d) => {
      buf += d.toString("latin1");
      const m = /^HTTP\/1\.[01] (\d{3})/.exec(buf);
      if (m) fin("http " + m[1]); else if (buf.length > 64) fin("garbage");
    });
    s.on("end", () => fin("closed"));
    s.on("error", (e) => fin("error " + (e.code || "unknown")));
  });
}
function dnsQuery(host, name, ms) {
  return new Promise((resolve) => {
    const labels = name.split(".").map((l) => Buffer.concat([Buffer.from([l.length]), Buffer.from(l)]));
    const q = Buffer.concat([Buffer.from([0x5a, 0x5a, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]), ...labels, Buffer.from([0, 0, 1, 0, 1])]);
    const s = dgram.createSocket(net.isIPv6(host) ? "udp6" : "udp4");
    let done = false;
    const fin = (r) => { if (!done) { done = true; try { s.close(); } catch {} resolve(r); } };
    s.on("message", (m) => fin("reply rcode=" + (m.length > 3 ? (m[3] & 15) : "?")));
    s.on("error", (e) => fin("error " + (e.code || "unknown")));
    s.send(q, 53, host, (e) => { if (e) fin("error " + (e.code || "unknown")); });
    setTimeout(() => fin("timeout"), Number(ms));
  });
}
function body(dialect, kind, marker) {
  const text = kind === "search" ? "Perform a web search for the query: " + marker
    : kind === "big" ? "a".repeat(33 * 1024 * 1024) : "verify";
  if (dialect === "anthropic-messages") {
    const b = { model: "claude-verify", max_tokens: 1, messages: [{ role: "user", content: text }] };
    if (kind === "mcp") b.mcp_servers = [{ type: "url", url: "https://mcp.verify.invalid/sse", name: "verify" }];
    if (kind === "webfetch") b.tools = [{ type: "web_fetch_20250910", name: "web_fetch", max_uses: 1 }];
    if (kind === "search") b.tools = [{ type: "web_search_20250305", name: "web_search", max_uses: 1 }];
    return b;
  }
  if (dialect === "openai-responses") {
    const b = { model: "gpt-verify", stream: true, input: [{ role: "user", content: [{ type: "input_text", text }] }] };
    if (kind === "mcp") b.tools = [{ type: "mcp", server_label: "verify", server_url: "https://mcp.verify.invalid/sse" }];
    if (kind === "webfetch") b.input[0].content.push({ type: "input_image", image_url: "https://fetch.verify.invalid/x.png" });
    if (kind === "search") b.tools = [{ type: "web_search" }];
    return b;
  }
  const b = { model: "gpt-verify", messages: [{ role: "user", content: [{ type: "text", text }] }] };
  if (kind === "mcp") b.tools = [{ type: "mcp", server_label: "verify", server_url: "https://mcp.verify.invalid/sse" }];
  if (kind === "webfetch") b.messages[0].content.push({ type: "image_url", image_url: { url: "https://fetch.verify.invalid/x.png" } });
  return b;
}
function request(host, port, method, path, payload, dummy, ms) {
  return new Promise((resolve) => {
    let done = false, status = null, text = "";
    const fin = (r) => { if (!done) { done = true; resolve(r); } };
    const headers = { authorization: "Bearer " + dummy, "x-api-key": dummy, "anthropic-version": "2023-06-01" };
    if (payload !== null) { headers["content-type"] = "application/json"; headers["content-length"] = payload.length; }
    // PROBE_CA_B64: the server speaks TLS with this certificate, which must
    // also name the address asked for (a TLS sidecar).
    const ca = process.env.PROBE_CA_B64 ? Buffer.from(process.env.PROBE_CA_B64, "base64") : null;
    const req = (ca ? https : http).request({ host, port: Number(port), method, path, headers, agent: false, ...(ca ? { ca } : {}) }, (res) => {
      status = res.statusCode;
      res.on("data", (d) => { if (text.length < 200) text += d.toString("latin1"); });
      // One line, whatever the body: a streamed reply has line breaks in
      // it, and the host reads the last line the probe prints as the answer.
      res.on("end", () => fin("http " + status + " " + text.slice(0, 160).replace(/[\r\n]+/g, " ")));
      res.on("error", () => fin("http " + status));
    });
    req.setTimeout(Number(ms), () => { req.destroy(); fin(status ? "http " + status : "timeout"); });
    // A server that refuses a large body may close while it is still being
    // sent. If the status line arrived first, that is the answer.
    req.on("error", (e) => setTimeout(() => fin(status ? "http " + status : "error " + (e.code || "unknown")), 200));
    req.end(payload === null ? undefined : payload);
  });
}

(async () => {
  if (cmd === "tcp") {                       // tcp <host> <ms> <port>...
    const results = await Promise.all(a.slice(2).map((p) => tcp(a[0], p, a[1])));
    a.slice(2).forEach((p, i) => out(p + " " + results[i]));
  } else if (cmd === "connect") {            // connect <proxy> <port> <target> <ms> [header]...
    const extra = a.slice(4).map((h) => h + "\r\n").join("");
    out(await exchange(a[0], a[1], "CONNECT " + a[2] + " HTTP/1.1\r\nHost: " + a[2] + "\r\n" + extra + "\r\n", a[3]));
  } else if (cmd === "get") {                // get <proxy> <port> <url> <ms>
    const host = new URL(a[2]).host;
    out(await exchange(a[0], a[1], "GET " + a[2] + " HTTP/1.1\r\nHost: " + host + "\r\nConnection: close\r\n\r\n", a[3]));
  } else if (cmd === "escget") {             // escget <proxy> <port> <host> <marker> <ms>: a request line carrying escape sequences
    const line = "GET http://" + a[2] + "/" + a[3] + "\x1b]0;" + a[3] + "\x07\x1b[2J HTTP/1.1\r\nHost: " + a[2] + "\r\nConnection: close\r\n\r\n";
    out(await exchange(a[0], a[1], line, a[4]));
  } else if (cmd === "dns") {                // dns <server> <name> <ms>
    out(await dnsQuery(a[0], a[1], a[2]));
  } else if (cmd === "udp") {                // udp <host> <ms>: can a datagram be sent at all
    out(await dnsQuery(a[0], "example.com", a[1]));
  } else if (cmd === "lookup") {             // lookup <name>: the system resolver, as any program would use it
    dns.lookup(a[0], (e, address) => out(e ? "error " + (e.code || "unknown") : "address " + address));
  } else if (cmd === "post") {               // post <host> <port> <method> <path> <dialect> <kind> <dummy> <marker> <ms>
    const payload = a[5] === "path" ? null : Buffer.from(JSON.stringify(body(a[4], a[5], a[7])));
    out(await request(a[0], a[1], a[2], a[3], payload, a[6], a[8]));
  } else if (cmd === "fork") {               // fork <attempts>: start processes until the kernel says no
    const kids = [];
    let refusal = "never";
    for (let i = 0; i < Number(a[0]); i++) {
      const c = cp.spawn("sleep", ["120"], { stdio: "ignore" });
      if (c.pid === undefined) {
        refusal = await new Promise((r) => { c.on("error", (e) => r(e.code || "error")); setTimeout(() => r("unknown"), 2000); });
        break;
      }
      c.on("error", () => {});
      kids.push(c);
    }
    for (const k of kids) k.kill("SIGKILL");
    out("spawned " + kids.length + " refused " + refusal);
  } else {
    out("unknown probe " + cmd);
  }
})().catch((e) => out("error " + (e && e.code ? e.code : "probe-crashed")));
'

netprobe() {
  if ! have node; then printf 'unavailable node is not in this image\n'; return 0; fi
  node -e "$NET_JS" "$@" 2>/dev/null || printf 'unavailable the node probe died\n'
}

# ---------------------------------------------------------------------------
# /proc/self/mountinfo, one mount at a time.
# each_mount writable|flags|binds: calls that check's per-mount function with
# mount-point, root-within-filesystem, mount options, filesystem type,
# per-filesystem options.
# ---------------------------------------------------------------------------
each_mount() {
  local what="$1" _id _parent _dev root mp opts rest tail fstype _source sopts
  while read -r _id _parent _dev root mp opts rest; do
    case "$rest" in
      "- "*) tail="${rest#- }" ;;
      *) tail="${rest#* - }" ;;
    esac
    read -r fstype _source sopts <<<"$tail"
    # Spaces in paths are written \040 in this file.
    mp="$(printf '%b' "$mp")"; root="$(printf '%b' "$root")"
    case "$what" in
      writable) _writable_one "$mp" ;;
      flags)    _flags_one "$mp" "$root" "$opts" "$fstype" "${sopts:-}" ;;
      binds)    _bind_one "$mp" "$root" "$opts" "$fstype" ;;
    esac
  done < /proc/self/mountinfo
}

has_opt() { [[ ",$1," == *",$2,"* ]]; }

net_ifaces() {   # every network interface except loopback, on one line
  local dir
  for dir in /sys/class/net/*; do
    if [ -e "$dir" ] && [ "${dir##*/}" != lo ]; then printf '%s ' "${dir##*/}"; fi
  done
}

# ===========================================================================
# The checks. One function per name; `-` in a name is `_` here.
# ===========================================================================

# --- B01: a fixed non-root user ---------------------------------------------
c_B01_user() {
  local uids gids want
  want="$(param uid)"
  uids="$(status_field Uid)"; gids="$(status_field Gid)"
  if [ "$uids" = "$want $want $want $want" ] && [ "$gids" = "$want $want $want $want" ]; then
    pass B01-user "read its own ids from the kernel: real, effective, saved and filesystem uid and gid are all $want"
  else
    fail B01-user "read its own ids from the kernel: uid '$uids', gid '$gids', expected all $want" \
      "the agent must be created with --user $want:$want (topology.sh, topo_agent)"
  fi
}

# --- B02: no capabilities ----------------------------------------------------
c_B02_caps() {
  local name value bad="" all=""
  for name in CapInh CapPrm CapEff CapBnd CapAmb; do
    value="$(status_field "$name")"
    all="$all $name=$value"
    [[ "$value" =~ ^0+$ ]] || bad="$bad $name=$value"
  done
  if [ -z "$bad" ]; then
    pass B02-caps "read the five capability sets from the kernel: all empty (CapBnd, the ceiling for anything started here, included)"
  else
    fail B02-caps "capability sets are not empty:$bad" \
      "the container must be created with --cap-drop=ALL and no --cap-add (topology.sh, _topo_hardening)"
  fi
}

c_B02_raw_socket() {
  sys rawsock
  refused B02-raw-socket "opened a raw ICMP socket, which needs the NET_RAW capability" \
    "the container must be created with --cap-drop=ALL (topology.sh, _topo_hardening)" 1
}

# --- B03: no-new-privileges ---------------------------------------------------
c_B03_nnp_flag() {
  local value
  value="$(status_field NoNewPrivs)" || value="(no such line)"
  if [ "$value" = 1 ]; then
    pass B03-nnp-flag "the kernel reports NoNewPrivs: 1 for this process"
  else
    fail B03-nnp-flag "the kernel reports NoNewPrivs: $value" \
      "the container must be created with --security-opt=no-new-privileges (topology.sh, _topo_hardening)"
  fi
}

c_B03_setuid_inert() {
  local list count file out euid egid shown tried=0
  # Setuid files first, then the ones that are only setgid.
  list="$( { find / -xdev -type f -perm -4000 2>/dev/null | sort; find / -xdev -type f -perm -2000 ! -perm -4000 2>/dev/null | sort; } | head -n 200)" || true
  if [ -z "$list" ]; then
    skip B03-setuid-inert no-setuid-files "searched the root filesystem for setuid and setgid files and found none, so there is none to run. The kernel flag itself is B03-nnp-flag; a new one cannot be made because every writable place is mounted nosuid (B08-mount-flags)"
    return
  fi
  count="$(printf '%s\n' "$list" | grep -c .)"
  shown="$(printf '%s\n' "$list" | head -n 6 | tr '\n' ' ')"
  # glibc prints the identity a program starts with when LD_SHOW_AUXV is set,
  # and ignores that variable for a program the kernel has given privileges.
  # So: the identity is printed and it is ours = the setuid bit did nothing.
  while IFS= read -r file; do
    [ -x "$file" ] || continue
    tried=$((tried + 1))
    out="$(LD_SHOW_AUXV=1 timeout 5 "$file" --version </dev/null 2>/dev/null | grep -E '^AT_E(UID|GID):' | tr -s ' ' | tr '\n' ' ')" || true
    euid="$(printf '%s' "$out" | sed -n 's/.*AT_EUID: \([0-9]*\).*/\1/p')"
    egid="$(printf '%s' "$out" | sed -n 's/.*AT_EGID: \([0-9]*\).*/\1/p')"
    [ -n "$euid" ] || continue
    if [ "$euid" = "$ME_UID" ] && [ "$egid" = "$ME_GID" ]; then
      pass B03-setuid-inert "found $count setuid/setgid files on the root filesystem ($shown); ran $file: it started with effective uid $euid and gid $egid, still the agent's"
    else
      fail B03-setuid-inert "ran the setuid/setgid program $file: it started with effective uid $euid and gid $egid, not the agent's $ME_UID:$ME_GID" \
        "the container must be created with --security-opt=no-new-privileges (topology.sh, _topo_hardening)"
    fi
    return
  done <<<"$list"
  fail B03-setuid-inert "ran $tried of the $count setuid/setgid files ($shown) and none showed its start-up identity: the loader treated each one as privileged, which is what happens when no-new-privileges is NOT in force" \
    "the container must be created with --security-opt=no-new-privileges (topology.sh, _topo_hardening)"
}

# --- B04: the system-call filter ---------------------------------------------
c_B04_seccomp_mode() {
  local mode
  mode="$(status_field Seccomp)" || mode="(no such line)"
  if [ "$mode" = 2 ]; then
    pass B04-seccomp-mode "the kernel reports Seccomp: 2 (a filter is attached to this process)"
  else
    fail B04-seccomp-mode "the kernel reports Seccomp: $mode; 2 means a filter is attached" "$SECCOMP_FIX"
  fi
}
# PTRACE_TRACEME needs no target and no privilege: the kernel always allows
# it, and so does Podman's default filter. Only our stricter filter says no,
# so a refusal here proves agent-seccomp.json is the one in force.
c_B04_ptrace()  { sys ptrace;  refused B04-ptrace "called ptrace(PTRACE_TRACEME), which the kernel and Podman's default filter both allow" "$SECCOMP_FIX" 1; }
c_B04_mount() {
  local dir="/tmp/.verify-mnt.$$"
  mkdir -p "$dir" 2>/dev/null || true
  sys mount "$dir"
  rmdir "$dir" 2>/dev/null || true
  refused B04-mount "called mount() to put a new filesystem on $dir (the system call itself, not the mount program, which gives up before asking)" "$SECCOMP_FIX" 1
}
c_B04_unshare_user() {
  local out rc=0
  if have unshare; then
    out="$(unshare -U true 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      fail B04-unshare-user "ran 'unshare -U true': it WORKED, a new user namespace was created" "$SECCOMP_FIX"
      return
    fi
    case "$out" in
      *"Operation not permitted"*) pass B04-unshare-user "ran 'unshare -U true' to create a user namespace: refused ($out)" ;;
      *) fail B04-unshare-user "ran 'unshare -U true': it failed, but not with a refusal: $out" "$SECCOMP_FIX" ;;
    esac
    return
  fi
  sys unshare
  refused B04-unshare-user "called unshare(CLONE_NEWUSER) to create a user namespace (no unshare program in the image, so the system call was made directly)" "$SECCOMP_FIX" 1
}
c_B04_clone_newuser() { sys clone;  refused B04-clone-newuser "called clone() with CLONE_NEWUSER to start a process in a new user namespace" "$SECCOMP_FIX" 1; }
# clone3 hides its flags in a structure the filter cannot read, so the filter
# answers "no such system call" (38) and the C library falls back to clone.
c_B04_clone3()        { sys clone3; refused B04-clone3 "called clone3() with CLONE_NEWUSER" "$SECCOMP_FIX" 38 1; }
# Joining the user namespace you are already in is EINVAL (22) from the
# kernel. "Operation not permitted" (1) can only come from the filter.
c_B04_setns()         { sys setns;  refused B04-setns "called setns() on its own user namespace, which the kernel alone would answer with 'invalid argument'" "$SECCOMP_FIX" 1; }
# Reading your OWN memory this way is always allowed by the kernel.
c_B04_process_vm_readv() { sys pvr; refused B04-process-vm-readv "called process_vm_readv() on its own process, which the kernel alone always allows" "$SECCOMP_FIX" 1; }
c_B04_bpf()           { sys bpf;    refused B04-bpf "called bpf() to create a map" "$SECCOMP_FIX" 1; }

# --- B05: SELinux label --------------------------------------------------------
c_B05_lsm_label() {
  local current asked type
  current="$(tr -d '\0' < /proc/self/attr/current 2>/dev/null)" || current=""
  asked="$(param label)"
  case "$(param selinux)" in
    true)
      type="$(printf '%s' "$current" | cut -d: -f3)"
      if [ "$type" != container_t ]; then
        fail B05-lsm-label "the kernel reports the label '$current' for this process; the type should be container_t" \
          "the container must be created with --security-opt label=type:container_t on an SELinux host (./sandbox, set_selinux_opt)"
      elif [ -n "$asked" ] && [ "$asked" != "$current" ]; then
        fail B05-lsm-label "the kernel reports the label '$current'; Podman says it asked for '$asked'" \
          "look at 'podman inspect' of the agent container: the label in force is not the one Podman set"
      else
        pass B05-lsm-label "the kernel reports the label '$current' for this process: type container_t, as asked for"
      fi ;;
    false)
      skip B05-lsm-label no-selinux "this host does not run SELinux, so there is no label to compare (the kernel reports '${current:-nothing}'). Rootless Podman applies no AppArmor profile either: this barrier is absent on this host" ;;
    *)
      skip B05-lsm-label unknown "verify.sh did not say whether the host runs SELinux (the kernel reports '${current:-nothing}')" \
        "run this through scripts/verify.sh, which asks 'podman info'" ;;
  esac
}

# --- B06: private namespaces, no runtime inside ---------------------------------
c_B06_runtime_sockets() {
  local found="" path sock known allowed place
  for path in /var/run/docker.sock /run/docker.sock /run/podman/podman.sock /run/containerd/containerd.sock \
              /run/crio/crio.sock /var/run/crio/crio.sock "/run/user/$ME_UID/podman/podman.sock" "/run/user/$ME_UID/docker.sock"; do
    if [ -e "$path" ]; then found="$found $path"; fi
  done
  for known in DOCKER_HOST CONTAINER_HOST; do
    if [ -n "${!known:-}" ]; then found="$found \$$known=${!known}"; fi
  done
  # Every socket file anywhere. On a read-only root none can exist outside
  # the writable places unless it was mounted in from the host.
  while IFS= read -r sock; do
    [ -n "$sock" ] || continue
    allowed=0
    for place in $(param writable); do
      case "$sock" in "$place"/*) allowed=1 ;; esac
    done
    if [ "$allowed" -eq 0 ]; then found="$found $sock"; fi
  done <<<"$(find / \( -path /proc -o -path /sys \) -prune -o -type s -print 2>/dev/null | head -n 100)"
  if [ -z "$found" ]; then
    pass B06-runtime-sockets "looked for the Docker, Podman, containerd and CRI-O sockets by path and by environment variable, and searched every mount for socket files outside the writable places: none"
  else
    fail B06-runtime-sockets "found a socket a container runtime could be driven through:$found" \
      "nothing may be mounted into the agent container but the workspace volume: remove the mount (topology.sh, topo_agent)"
  fi
}

c_B06_runtime_binaries() {
  local name found="" where
  for name in docker podman nerdctl buildah; do
    where="$(command -v "$name" 2>/dev/null)" || where=""
    if [ -n "$where" ]; then found="$found $where"; fi
  done
  where="$(find / -xdev -type f \( -name docker -o -name dockerd -o -name podman -o -name podman-remote -o -name nerdctl -o -name buildah -o -name containerd -o -name runc -o -name crun \) -perm /111 2>/dev/null | head -n 20 | tr '\n' ' ')" || true
  found="$found $where"
  if [ -z "${found// /}" ]; then
    pass B06-runtime-binaries "looked on PATH for docker, podman, nerdctl and buildah, and searched the whole root filesystem for those programs and for dockerd, containerd, runc and crun: none"
  else
    fail B06-runtime-binaries "found a container runtime in the image:$found" \
      "remove it from the image (images/agent/Containerfile); no toolchain may contain a container runtime"
  fi
}

c_B06_pid1() {
  local owner owners dir count=0 comm
  owner="$(stat -c %u /proc/1 2>/dev/null)" || owner="?"
  comm="$(cat /proc/1/comm 2>/dev/null)" || comm="?"
  owners="$(for dir in /proc/[0-9]*; do stat -c %u "$dir" 2>/dev/null || true; done | sort -u | tr '\n' ' ')"
  for dir in /proc/[0-9]*; do count=$((count + 1)); done
  if [ "$owner" = "$ME_UID" ] && [ "$owners" = "$ME_UID " ]; then
    pass B06-pid1 "listed every process visible here: $count, all owned by uid $ME_UID; process 1 is '$comm', the container's own first process, not the host's"
  else
    fail B06-pid1 "process 1 is '$comm' owned by uid $owner, and the $count visible processes belong to uids: $owners. Only the agent's own processes (uid $ME_UID) should be visible" \
      "the container must be created with --pid=private (topology.sh, _topo_hardening)"
  fi
}

c_B06_cgroupns() {
  local seen
  seen="$(tr '\n' ' ' < /proc/self/cgroup)"
  if [ "$seen" = "0::/ " ]; then
    pass B06-cgroupns "/proc/self/cgroup reads '0::/': this process sees the root of its own cgroup tree and nothing of the host's"
  else
    fail B06-cgroupns "/proc/self/cgroup reads '$seen'; in a private cgroup namespace it reads '0::/'" \
      "the container must be created with --cgroupns=private on a cgroup v2 host (topology.sh, _topo_hardening; ./sandbox doctor)"
  fi
}

# --- B07: read-only root ------------------------------------------------------
# As a non-root user a write to /etc fails on a WRITABLE root too, with
# "Permission denied". Only "Read-only file system" proves the mount itself
# refuses, which is what stops root as well.
c_B07_readonly_root() {
  local dir probe out bad="" tried=""
  for dir in / /usr /etc; do
    probe="${dir%/}/.verify-probe.$$"
    if out="$( { : > "$probe"; } 2>&1 )"; then
      rm -f "$probe"
      bad="$bad created $probe;"
    elif [[ "$out" != *"Read-only file system"* ]]; then
      bad="$bad $probe was refused only by file permissions (${out##*: });"
    fi
    if out="$(mkdir "$probe.d" 2>&1)"; then
      rmdir "$probe.d"
      bad="$bad created directory $probe.d;"
    elif [[ "$out" != *"Read-only file system"* ]]; then
      bad="$bad directory $probe.d was refused only by file permissions (${out##*: });"
    fi
    tried="$tried $dir"
  done
  if [ -z "$bad" ]; then
    pass B07-readonly-root "tried to create a file and a directory in each of$tried: every attempt answered 'Read-only file system'"
  else
    fail B07-readonly-root "the root filesystem is not read-only:$bad" \
      "the container must be created with --read-only (topology.sh, _topo_hardening)"
  fi
}

# --- B08: the writable places ---------------------------------------------------
try_write() {   # 0 writable, 1 refused, 2 not a place files can be made (a device)
  local path="$1" probe
  if [ -d "$path" ]; then
    probe="${path%/}/.verify-w.$$"
    if ( : > "$probe" ) 2>/dev/null; then rm -f "$probe"; return 0; fi
    if mkdir "$probe" 2>/dev/null; then rmdir "$probe"; return 0; fi
    return 1
  elif [ -f "$path" ]; then
    # Open for appending and write nothing: succeeds only if writing is allowed.
    if ( : >> "$path" ) 2>/dev/null; then return 0; fi
    return 1
  fi
  return 2
}

W_TRIED=0; W_WRITABLE=""
_writable_one() {
  local mp="$1"
  W_TRIED=$((W_TRIED + 1))
  if try_write "$mp"; then
    case " $W_WRITABLE " in *" $mp "*) ;; *) W_WRITABLE="$W_WRITABLE $mp" ;; esac
  fi
}
c_B08_writable_set() {
  local mp extra="" missing="" note="" limit
  W_TRIED=0; W_WRITABLE=""
  each_mount writable
  for mp in $W_WRITABLE; do
    case " $(param writable) " in
      *" $mp "*) ;;
      *)
        if [ "$mp" = /dev/mqueue ]; then
          # Not a place for files: each entry is a POSIX message queue, held
          # in kernel memory and capped per user by the msgqueue ulimit.
          limit="$(limit_of 'Max msgqueue size')"
          case "${limit%% *}" in
            unlimited|'') extra="$extra /dev/mqueue(no msgqueue limit)" ;;
            *) note=" /dev/mqueue also accepts entries: they are message queues, not files, capped at ${limit%% *} bytes per user by ulimit." ;;
          esac
        else
          extra="$extra $mp"
        fi ;;
    esac
  done
  for mp in $(param writable); do
    case " $W_WRITABLE " in *" $mp "*) ;; *) missing="$missing $mp" ;; esac
  done
  if [ -n "$extra" ]; then
    fail B08-writable-set "tried to create a file in each of the $W_TRIED mounts; it worked outside the allowed places ($(param writable)), in:$extra" \
      "remove that mount or make it read-only (topology.sh, topo_agent). Podman adds /run, /var/tmp and more unless --read-only-tmpfs=false is given"
  else
    pass B08-writable-set "tried to create a file in each of the $W_TRIED mounts; it worked only in:$W_WRITABLE.$note${missing:+ Not writable although allowed:$missing.}"
  fi
}

M_SEEN=""; M_BAD=""
_flags_one() {
  local mp="$1" opts="$3" fstype="$4" sopts="$5" place want size key
  for place in $(param writable); do
    [ "$mp" = "$place" ] || continue
    M_SEEN="$M_SEEN $mp"
    has_opt "$opts" nosuid || M_BAD="$M_BAD $mp lacks nosuid;"
    has_opt "$opts" nodev || M_BAD="$M_BAD $mp lacks nodev;"
    if [ "$mp" = /dev/shm ] && ! has_opt "$opts" noexec; then M_BAD="$M_BAD /dev/shm lacks noexec;"; fi
    case "$mp" in
      /tmp) key=tmp_size ;; /home) key=home_size ;; /dev/shm) key=shm_size ;; /workspace) key=ws_size ;; *) key="" ;;
    esac
    if [ "$mp" = /workspace ] && [ "$(param ws_driver)" = local ]; then
      continue   # on the disk store: its cap is the store's own size [B33]
    fi
    if [ "$fstype" != tmpfs ]; then M_BAD="$M_BAD $mp is on $fstype, not held in memory;"; continue; fi
    want="$(param "$key")"
    size="$(printf '%s' "$sopts" | tr ',' '\n' | sed -n 's/^size=\([0-9]*\)k$/\1/p')"
    if [ -z "$want" ]; then
      M_BAD="$M_BAD $mp: verify.sh did not say what size was asked for;"
    elif [ -z "$size" ]; then
      M_BAD="$M_BAD $mp has no size cap;"
    elif [ $((size * 1024)) -lt "$want" ] || [ $((size * 1024 - want)) -ge 65536 ]; then
      M_BAD="$M_BAD $mp is capped at $((size * 1024)) bytes, asked for $want;"
    fi
  done
}
c_B08_mount_flags() {
  local place dir mode
  M_SEEN=""; M_BAD=""
  each_mount flags
  for place in $(param writable); do
    case " $M_SEEN " in *" $place "*) ;; *) M_BAD="$M_BAD $place is not a mount of its own;" ;; esac
  done
  # [closes M5] The home directory and the repository are the agent's alone.
  for dir in "${HOME:-/home/agent}" /workspace/repo; do
    mode="$(stat -c '%a %u' "$dir" 2>/dev/null)" || mode="missing"
    [ "$mode" = "700 $ME_UID" ] || M_BAD="$M_BAD $dir is '$mode', expected mode 700 owned by $ME_UID;"
  done
  if [ -z "$M_BAD" ]; then
    pass B08-mount-flags "read the kernel's mount table: $(param writable) are each nosuid,nodev, capped at the size asked for, /dev/shm also noexec; the home directory and /workspace/repo are mode 700"
  else
    fail B08-mount-flags "the writable places are not as asked for:$M_BAD" \
      "compare the --tmpfs and --mount lines in topology.sh (topo_agent, topo_volume_workspace) with 'podman inspect'; images/agent/sandbox-idle creates the two directories"
  fi
}

# Fills every memory-backed writable place at once and leaves them full until
# all are done: the memory limit is meant to cover the processes AND all of
# these, so each must answer "No space left" and nothing may be killed.
c_B08_fill() {
  local place n out rc bad="" done_places="" total=0
  for place in $(param writable); do
    if [ "$place" = /workspace ] && [ "$(param ws_driver)" = local ]; then continue; fi
    n=0
    while :; do
      rc=0
      # One gigabyte per file, to stay under the largest-file limit [B11].
      out="$(dd if=/dev/zero of="$place/.verify-fill.$n" bs=1048576 count=1024 2>&1)" || rc=$?
      [ "$rc" -eq 0 ] || break
      n=$((n + 1)); total=$((total + 1))
      if [ "$n" -ge 256 ]; then out="wrote 256 GB and it never filled"; rc=99; break; fi
    done
    if [ "$rc" -gt 128 ]; then
      bad="$bad $place: the writer was killed by signal $((rc - 128)) instead of being told the place is full;"
    elif [[ "$out" != *"No space left on device"* ]]; then
      bad="$bad $place: stopped for another reason ($(printf '%s' "$out" | head -n 1));"
    fi
    done_places="$done_places $place"
  done
  for place in $(param writable); do rm -f "$place"/.verify-fill.* 2>/dev/null || true; done
  if [ -z "$bad" ]; then
    pass B08-fill "filled$done_places to the brim, all at the same time ($total full gigabytes plus the remainders): each answered 'No space left on device' and no process was killed"
  else
    fail B08-fill "filling the writable places did not end with 'No space left':$bad" \
      "the agent's memory limit must be --mem plus the caps on /tmp, home, /dev/shm and the workspace (./sandbox, SANDBOX_MEM_LIMIT), and every place needs a size= cap (topology.sh)"
  fi
}

# --- B09: nothing of the host's is mounted --------------------------------------
B_BAD=""; B_FILES=""; B_COUNT=0
_bind_one() {
  local mp="$1" root="$2" opts="$3" fstype="$4"
  B_COUNT=$((B_COUNT + 1))
  [ "$mp" != / ] || return 0          # the container's own root
  if [ "$root" = / ]; then
    # A whole filesystem. Only the kinds a container is made of.
    case "$fstype" in
      proc|sysfs|cgroup2|devpts|mqueue) return 0 ;;
      tmpfs)
        case " $(param writable) /dev " in *" $mp "*) return 0 ;; esac
        # Podman hides parts of /proc and /sys under empty read-only mounts.
        if has_opt "$opts" ro; then return 0; fi
        B_BAD="$B_BAD $mp (a writable memory filesystem that topology.sh does not ask for);" ;;
      *) B_BAD="$B_BAD $mp (a whole $fstype filesystem);" ;;
    esac
    return 0
  fi
  # Part of some other filesystem made visible here: a bind mount.
  case "$fstype" in proc|cgroup2|devpts) return 0 ;; esac     # /proc/sys and friends, the terminal
  case "$mp" in
    /etc/hostname|/run/.containerenv)
      B_FILES="$B_FILES $mp"
      has_opt "$opts" ro || B_BAD="$B_BAD $mp (generated by Podman, but mounted writable);"
      return 0 ;;
    /workspace)
      if [ "$(param ws_driver)" = local ]; then return 0; fi ;;
  esac
  # Under rootless Podman the standard devices are the host's device files,
  # and files Podman hides (/proc/kcore ...) are covered with /dev/null.
  case "$root" in
    /null) return 0 ;;
    /zero|/full|/random|/urandom|/tty)
      if [ "$mp" = "/dev$root" ]; then return 0; fi ;;
  esac
  B_BAD="$B_BAD $mp (host path $root on $fstype, $(has_opt "$opts" ro && printf 'read-only' || printf 'WRITABLE'));"
}
c_B09_mounts() {
  B_BAD=""; B_FILES=""; B_COUNT=0
  each_mount binds
  if [ -z "$B_BAD" ]; then
    pass B09-mounts "went through all $B_COUNT mounts in the kernel's table: the only host files are the ones Podman generates, read-only ($B_FILES)$([ "$(param ws_driver)" = local ] && printf ', and the workspace on the disk store')"
  else
    fail B09-mounts "something of the host's is mounted in the agent container:$B_BAD" \
      "remove the mount: the agent gets the workspace volume and nothing else (topology.sh, topo_agent). --dns=none stops Podman adding /etc/resolv.conf"
  fi
}

# --- B10: cgroup limits, compared by value ----------------------------------------
cg() { cat "/sys/fs/cgroup/$1" 2>/dev/null || printf 'absent'; }
CGROUP_FIX="the limit Podman was asked for is not the one in force. ./sandbox doctor checks that the cpu, memory and pids controllers are delegated to your user (cgroup v2); the flags are in topology.sh, _topo_limits"

c_B10_pids_max() {
  local got want
  got="$(cg pids.max)"; want="$(param pids)"
  if [ -z "$want" ]; then skip B10-pids-max unknown "pids.max reads '$got', but verify.sh did not say what was asked for" "run this through scripts/verify.sh"
  elif [ "$got" = "$want" ]; then pass B10-pids-max "/sys/fs/cgroup/pids.max reads $got, the --pids-limit asked for"
  else fail B10-pids-max "/sys/fs/cgroup/pids.max reads '$got'; $want was asked for" "$CGROUP_FIX"; fi
}
c_B10_memory_max() {
  local got want
  got="$(cg memory.max)"; want="$(param mem)"
  if [ -z "$want" ]; then skip B10-memory-max unknown "memory.max reads '$got', but verify.sh did not say what was asked for" "run this through scripts/verify.sh"
  elif [[ "$got" =~ ^[0-9]+$ ]] && [ "$got" -le "$want" ] && [ $((want - got)) -lt 65536 ]; then
    pass B10-memory-max "/sys/fs/cgroup/memory.max reads $got bytes, the --memory asked for ($want)"
  else fail B10-memory-max "/sys/fs/cgroup/memory.max reads '$got'; $want bytes were asked for" "$CGROUP_FIX"; fi
}
# Three outcomes, on purpose. 0 = no swap allowance: pass. Anything else on a
# host that HAS swap = files held in memory can be pushed to the host's swap:
# fail. Anything else on a host with no swap = the limit was not applied (the
# kernel has no swap accounting, or Podman dropped it), which costs nothing
# today and becomes a hole the day swap is added: said out loud, as a SKIP.
c_B10_swap_max() {
  local got swap_kb
  got="$(cg memory.swap.max)"
  swap_kb="$(sed -n 's/^SwapTotal: *\([0-9]*\) kB$/\1/p' /proc/meminfo)"
  if [ "$got" = 0 ]; then
    pass B10-swap-max "/sys/fs/cgroup/memory.swap.max reads 0: nothing of this container can be pushed to swap"
  elif [ "${swap_kb:-1}" = 0 ]; then
    skip B10-swap-max no-swap "memory.swap.max reads '$got', so no swap limit is in force; this host has no swap (SwapTotal 0), so nothing can be swapped out today. If swap is ever added to this host, this becomes a failure"
  else
    fail B10-swap-max "/sys/fs/cgroup/memory.swap.max reads '$got' and this host has ${swap_kb:-an unknown amount of} kB of swap: memory-backed files can be pushed to the host's disk" \
      "--memory-swap must equal --memory (topology.sh, _topo_limits). If Podman warns that it dropped the swap limit, enable swap accounting on the host, or use --cgroup-conf=memory.swap.max=0"
  fi
}
c_B10_cpu_max() {
  local got quota period want
  got="$(cg cpu.max)"; want="$(param cpu_milli)"
  read -r quota period <<<"$got"
  if [ -z "$want" ]; then skip B10-cpu-max unknown "cpu.max reads '$got', but verify.sh did not say what was asked for" "run this through scripts/verify.sh"
  elif [[ "$quota" =~ ^[0-9]+$ ]] && [[ "${period:-}" =~ ^[1-9][0-9]*$ ]] && [ $((quota * 1000 / period)) -eq "$want" ]; then
    pass B10-cpu-max "/sys/fs/cgroup/cpu.max reads '$got': $quota/$period = $((want / 1000)).$(printf '%03d' $((want % 1000))) processors, the --cpus asked for"
  else fail B10-cpu-max "/sys/fs/cgroup/cpu.max reads '$got'; $want thousandths of a processor were asked for" "$CGROUP_FIX"; fi
}

c_B10_fork_limit() {
  local want out spawned refusal before after by
  want="$(param pids)"
  if ! [[ "$want" =~ ^[0-9]+$ ]]; then
    skip B10-fork-limit unknown "verify.sh did not say what process limit was asked for" "run this through scripts/verify.sh"; return
  fi
  before="$(sed -n 's/^max \([0-9]*\)$/\1/p' /sys/fs/cgroup/pids.events 2>/dev/null)"
  out="$(netprobe fork $((want + 64)))"
  after="$(sed -n 's/^max \([0-9]*\)$/\1/p' /sys/fs/cgroup/pids.events 2>/dev/null)"
  spawned="$(printf '%s' "$out" | sed -n 's/^spawned \([0-9]*\) refused .*/\1/p')"
  refusal="${out##* refused }"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then by="the cgroup's pids.max"; else by="the per-user process ulimit"; fi
  if [ -z "$spawned" ]; then
    skip B10-fork-limit no-probe "the fork probe did not report: $out" "node must be in the agent image"
  elif [ "$refusal" = EAGAIN ] && [ "$spawned" -lt "$want" ]; then
    pass B10-fork-limit "started processes until the kernel refused: $spawned started, then 'resource temporarily unavailable' from $by; the limit asked for is $want (it also counts the processes already running)"
  else
    fail B10-fork-limit "started $spawned processes with a limit of $want asked for; the kernel's answer was '$refusal'" "$CGROUP_FIX"
  fi
}

# --- B11: ulimits -------------------------------------------------------------------
limit_of() {   # <label as in /proc/self/limits> -> "soft hard"
  local line soft hard _rest
  while IFS= read -r line; do
    case "$line" in
      "$1"*) read -r soft hard _rest <<<"${line#"$1"}"; printf '%s %s' "$soft" "$hard"; return 0 ;;
    esac
  done < /proc/self/limits
  return 0
}
c_B11_ulimits() {
  local bad="" got want label key
  for key in nofile nproc fsize; do
    case "$key" in
      nofile) label='Max open files' ;; nproc) label='Max processes' ;; fsize) label='Max file size' ;;
    esac
    got="$(limit_of "$label")"; want="$(param "$key")"
    if [ -z "$want" ]; then bad="$bad $key: verify.sh did not say what was asked for;"
    elif [ "$got" != "$want $want" ]; then bad="$bad $key is '$got' (soft hard), asked for $want;"; fi
  done
  got="$(limit_of 'Max core file size')"
  [ "$got" = "0 0" ] || bad="$bad core is '$got', must be 0 0;"
  if [ -z "$bad" ]; then
    pass B11-ulimits "read /proc/self/limits: open files $(param nofile), processes $(param nproc), largest file $(param fsize) bytes, core dumps 0, each as asked for, soft and hard"
  else
    fail B11-ulimits "the limits in force are not the ones asked for:$bad" \
      "compare the --ulimit lines in topology.sh (topo_agent, _topo_hardening) with /proc/self/limits; a rootless Podman cannot set a limit above your own"
  fi
}
c_B11_fsize() {
  local limit file out rc=0
  limit="$(limit_of 'Max file size')"; limit="${limit%% *}"
  if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
    fail B11-fsize "there is no largest-file limit to exceed: /proc/self/limits says '$limit'" "the agent must be created with --ulimit fsize=<bytes> (topology.sh, topo_agent)"; return
  fi
  file="/tmp/.verify-fsize.$$"
  # One byte written just past the limit. The file is sparse: nothing but
  # that byte is stored, so this costs no memory.
  out="$(dd if=/dev/zero of="$file" bs=1 count=1 seek="$limit" 2>&1)" || rc=$?
  rm -f "$file"
  if [ "$rc" -eq 153 ] || [[ "$out" == *"File too large"* ]] || [[ "$out" == *"File size limit exceeded"* ]]; then
    pass B11-fsize "wrote one byte at offset $limit, just past the largest-file limit: refused ($([ "$rc" -eq 153 ] && printf 'the writer got the file-size signal' || printf 'File too large'))"
  elif [ "$rc" -eq 0 ]; then
    fail B11-fsize "wrote one byte at offset $limit, past the largest-file limit, and it WORKED" "the agent must be created with --ulimit fsize=<bytes> (topology.sh, topo_agent)"
  else
    fail B11-fsize "writing past the largest-file limit failed for another reason: $out" "check that /tmp is writable (B08-writable-set)"
  fi
}

# --- B12: no route out -----------------------------------------------------------------
c_B12_no_route() {
  local routes="" ifaces out4 out6 udp bad="" iface dest mask _gw _flags _ref _use _metric _rest
  # The kernel's IPv4 routing table: a default route is destination 0, mask 0.
  while read -r iface dest _gw _flags _ref _use _metric mask _rest; do
    if [ "$dest" = 00000000 ] && [ "$mask" = 00000000 ]; then routes="$routes$iface "; fi
  done < /proc/net/route
  [ -z "$routes" ] || bad="$bad a default route exists (via $routes);"
  ifaces="$(net_ifaces)"
  [ "$(printf '%s' "$ifaces" | wc -w)" -le 1 ] || bad="$bad more than one network interface ($ifaces);"
  out4="$(netprobe tcp 1.1.1.1 3000 443 80 | tr '\n' ' ')$(netprobe tcp 8.8.8.8 3000 53 | tr '\n' ' ')"
  out6="$(netprobe tcp 2606:4700:4700::1111 3000 443 | tr '\n' ' ')"
  udp="$(netprobe udp 8.8.8.8 2000)"
  case "$out4$out6" in
    *unavailable*) skip B12-no-route no-probe "could not attempt a connection: $out4" "node must be in the agent image"; return ;;
    *connected*) bad="$bad a direct connection to a public address WORKED ($out4$out6);" ;;
  esac
  case "$udp" in reply*) bad="$bad a public DNS server answered a datagram ($udp);" ;; esac
  if [ -z "$bad" ]; then
    pass B12-no-route "connected straight to public addresses, ignoring the proxy: 1.1.1.1 [$out4] 2606:4700:4700::1111 [$out6] datagram to 8.8.8.8 [$udp]; the routing table has no default route and the only interface besides loopback is $ifaces"
  else
    fail B12-no-route "the agent can reach the internet without the proxy:$bad" \
      "the agent's only network must be the session's --internal network (topology.sh, topo_network_sandbox and topo_agent)"
  fi
}

# --- B13: the host is not on this network -------------------------------------------------
c_B13_gateway_ports() {
  local gw out line port result bad="" quiet=""
  gw="$(param gateway)"
  if [ -z "$gw" ]; then skip B13-gateway-ports unknown "verify.sh did not say which address a gateway would have" "run this through scripts/verify.sh"; return; fi
  out="$(netprobe tcp "$gw" 5000 22 53 80 443 2375 2376 3000 5432 8080)"
  while read -r port result; do
    case "$result" in
      connected) bad="$bad port $port ACCEPTED a connection;" ;;
      # A refusal is an answer too: some machine owns that address.
      ECONNREFUSED) bad="$bad port $port answered 'connection refused', so a machine does have this address;" ;;
      EHOSTUNREACH|ENETUNREACH|timeout|EHOSTDOWN) quiet="$quiet $port:$result" ;;
      *) bad="$bad port $port: unexpected result '$result';" ;;
    esac
  done <<<"$out"
  if [ -z "$bad" ] && [ -n "$quiet" ]; then
    pass B13-gateway-ports "probed $gw, the address a gateway would have, on 22 53 80 443 2375 2376 3000 5432 8080: nothing answered ($quiet )"
  else
    fail B13-gateway-ports "something answers at $gw, the address a gateway would have:$bad${quiet:+ silent:$quiet}" \
      "the session network must be created with --internal and --disable-dns, which leaves it without a gateway address (topology.sh, topo_network_sandbox); check 'podman network inspect'"
  fi
}

c_B13_etc_hosts() {
  local address names bad="" count=0 _id _parent _dev _root mp _rest
  # A file Podman manages is mounted over the image's own; with --no-hosts
  # nothing is mounted there.
  while read -r _id _parent _dev _root mp _rest; do
    [ "$mp" != /etc/hosts ] || bad="$bad Podman has mounted its own /etc/hosts over the image's;"
  done < /proc/self/mountinfo
  if [ ! -r /etc/hosts ]; then
    fail B13-etc-hosts "/etc/hosts cannot be read, so what it names could not be checked" \
      "the agent image ships a hosts file naming only localhost (images/agent/Containerfile, the last COPY); rebuild with ./sandbox upgrade"
    return
  fi
  while read -r address names; do
    case "$address" in ''|'#'*) continue ;; esac
    count=$((count + 1))
    case "$address" in
      127.*|::1|fe00::*|ff00::*|ff02::*) ;;                       # loopback and the usual IPv6 boilerplate
      *) bad="$bad '$address $names' is not a loopback address;" ;;
    esac
  done < /etc/hosts
  if [ -z "$bad" ]; then
    pass B13-etc-hosts "read all $count entries of /etc/hosts: loopback only, and the file is the image's own, not one Podman wrote (which would name the host)"
  else
    fail B13-etc-hosts "/etc/hosts can tell the agent where the host is:$bad" \
      "every container is created with --no-hosts (topology.sh, _topo_hardening), so that Podman writes no hosts file; the agent image's own names only localhost (images/agent/hosts)"
  fi
}

# --- B14: no resolver ------------------------------------------------------------------------
c_B14_no_resolver() {
  local servers control answer lookup bad="" how=""
  servers="$(sed -n 's/^[[:space:]]*nameserver[[:space:]]*//p' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')" || servers=""
  [ -z "$servers" ] || bad="$bad /etc/resolv.conf names a resolver ($servers);"
  if have getent; then
    # The control: the same tool must be able to answer from /etc/hosts.
    control="$(getent hosts localhost 2>/dev/null)" || control=""
    if [ -z "$control" ]; then
      bad="$bad getent could not even look up localhost, so its failure for example.com proves nothing;"
    elif answer="$(getent hosts example.com 2>/dev/null)" && [ -n "$answer" ]; then
      bad="$bad getent hosts example.com ANSWERED ($answer);"
    else
      how="'getent hosts example.com' found nothing (and found localhost, so the tool works)"
    fi
  fi
  lookup="$(netprobe lookup example.com)"
  case "$lookup" in
    address*) bad="$bad a program's own lookup of example.com ANSWERED ($lookup);" ;;
    error*) how="${how:+$how; }a lookup from node failed with ${lookup#error }" ;;
  esac
  if [ -n "$bad" ]; then
    fail B14-no-resolver "names can be resolved inside the agent container:$bad" \
      "the agent must be created with --dns=none and the network with --disable-dns (topology.sh); the image's /etc/resolv.conf must be empty"
  elif [ -z "$how" ]; then
    skip B14-no-resolver no-probe "neither getent nor node could attempt a lookup" "getent (libc-bin) and node must be in the agent image"
  else
    pass B14-no-resolver "/etc/resolv.conf names no resolver; $how"
  fi
}

c_B14_dns_by_hand() {
  local gw out
  gw="$(param gateway)"
  if [ -z "$gw" ]; then skip B14-dns-by-hand unknown "verify.sh did not say which address a gateway would have" "run this through scripts/verify.sh"; return; fi
  out="$(netprobe dns "$gw" example.com 2000)"
  case "$out" in
    reply*) fail B14-dns-by-hand "sent a hand-made DNS question for example.com to $gw port 53 and got an ANSWER ($out)" \
              "the session network must be created with --disable-dns (topology.sh, topo_network_sandbox)" ;;
    timeout|error*) pass B14-dns-by-hand "sent a hand-made DNS question for example.com to $gw port 53, where a gateway's name service would be: no answer ($out)" ;;
    *) skip B14-dns-by-hand no-probe "could not send the question: $out" "node must be in the agent image" ;;
  esac
}

# --- B15: no credential of yours inside (the token search itself runs on the host) ---------
c_B15_key_files() {
  local found="" file name helper
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "${file##*/}" in
      id_rsa|id_dsa|id_ecdsa|id_ed25519)
        # Only a real private key counts, not a file that happens to share the name.
        grep -q 'PRIVATE KEY' "$file" 2>/dev/null || continue ;;
    esac
    found="$found $file"
  done <<<"$(find / \( -path /proc -o -path /sys -o -path /dev -o -path /workspace/repo \) -prune -o -type f \
      \( -name id_rsa -o -name id_dsa -o -name id_ecdsa -o -name id_ed25519 -o -name .git-credentials -o -name .netrc -o -name .pgpass \
         -o -path '*/.aws/credentials' -o -path '*/.config/gcloud/*' -o -path '*/.docker/config.json' -o -path '*/.config/gh/hosts.yml' -o -path '*/.kube/config' \) \
      -print 2>/dev/null | head -n 50)"
  for name in SSH_AUTH_SOCK GIT_ASKPASS GH_TOKEN GITHUB_TOKEN GITLAB_TOKEN NPM_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN GOOGLE_APPLICATION_CREDENTIALS AZURE_CLIENT_SECRET; do
    if [ -n "${!name:-}" ]; then found="$found \$$name"; fi
  done
  if have git; then
    helper="$(git config --system --get-all credential.helper 2>/dev/null; git config --global --get-all credential.helper 2>/dev/null)" || true
    [ -z "$helper" ] || found="$found git-credential-helper:$helper"
  fi
  if [ -z "$found" ]; then
    pass B15-key-files "searched every mount except the repository itself for SSH private keys, .git-credentials, .netrc and cloud, Docker, GitHub-CLI and Kubernetes credential files; looked for a git credential helper and for token variables in the environment: none"
  else
    fail B15-key-files "found credentials inside the agent container:$found" \
      "nothing of yours may be mounted or passed into the agent container; remove it (topology.sh, topo_agent; agents/<name>/env)"
  fi
}

c_B15_push() {
  local url out rc=0
  url="$(param origin_url)"
  case "$url" in
    http://*|https://*|ssh://*|git://*|*@*:*) ;;
    *) skip B15-push no-remote "this session's repository was given as a local path, so there is no remote to push to"; return ;;
  esac
  if ! have git || ! git -C /workspace/repo rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    skip B15-push no-probe "there is no commit in /workspace/repo to push, so a push could not be attempted" "import a repository first (./sandbox run does)"; return
  fi
  # --dry-run sends nothing, but it does log in to the remote first, which is
  # the part being tested.
  out="$(GIT_TERMINAL_PROMPT=0 timeout 30 git -C /workspace/repo push --dry-run "$url" "HEAD:refs/heads/sandbox-verify-probe" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail B15-push "ran 'git push --dry-run' to $url and the remote ACCEPTED the login: a credential of yours is reachable from the agent" \
      "find what authenticated it (git config -l --show-origin, the environment) and remove it from the image or the session"
  else
    pass B15-push "ran 'git push --dry-run' to $url as the agent: refused ($(printf '%s' "$out" | tail -n 1))"
  fi
}

# --- B16: cannot take another address --------------------------------------------------------
c_B16_add_address() {
  local iface target
  iface="$(net_ifaces)"; iface="${iface%% *}"
  target="$(param sidecar)"
  [[ "$target" =~ ^[0-9.]+$ ]] || target=192.0.2.1
  if [ -z "$iface" ]; then
    skip B16-add-address no-probe "there is no network interface besides loopback to add an address to" "the agent container should have exactly one interface (topology.sh, topo_agent)"; return
  fi
  sys addaddr "$iface:9" "$target"
  refused B16-add-address "tried to add $target (the sidecar's address) to interface $iface, which needs the NET_ADMIN capability" \
    "the container must be created with --cap-drop=ALL (topology.sh, _topo_hardening). The session should be destroyed: its addresses may have been changed" 1
}
c_B16_packet_socket() {
  sys pktsock
  refused B16-packet-socket "opened a packet socket, the kind used to forge another machine's address" \
    "the container must be created with --cap-drop=ALL (topology.sh, _topo_hardening)" 1
}

# --- B20, B21: the egress proxy -----------------------------------------------------------------
PROXY_FIX="look at ./sandbox logs proxy; the rules are images/proxy/squid.conf.template and the lists under <session dir>/proxy/"
# proxy_expect <check> <what was tried> <probe result> <wanted status> <fix>
# A refusal only counts when the PROXY said it (HTTP 403). A dead proxy also
# "refuses" everything, and that must not pass.
proxy_expect() {
  local name="$1" tried="$2" got="$3" want="$4" fix="$5"
  case "$got" in
    "http $want") pass "$name" "$tried: the proxy answered $want $([ "$want" = 403 ] && printf '(refused)' || printf '(allowed)')" ;;
    http\ *) fail "$name" "$tried: the proxy answered ${got#http }, expected $want" "$fix" ;;
    unavailable*) skip "$name" no-probe "$tried: not attempted, ${got#unavailable }" "node must be in the agent image" ;;
    *) fail "$name" "$tried: no answer from the proxy at $(param proxy):$(param proxy_port) ($got), so nothing was proven" "the proxy container must be running and reachable from the agent: ./sandbox logs proxy" ;;
  esac
}
c_B20_denied_host() {
  local host
  host="$(param denied_host)"; [ -n "$host" ] || host=example.com
  proxy_expect B20-denied-host "asked the proxy for a tunnel to $host:443, a host on no list" \
    "$(netprobe connect "$(param proxy)" "$(param proxy_port)" "$host:443" 8000)" 403 "$PROXY_FIX"
}
c_B20_allowed_host() {
  local host
  host="$(param allowed_host)"
  if [ -z "$host" ]; then skip B20-allowed-host unknown "verify.sh did not name a host from the allowlist" "the session's agent.domains list is empty: nothing can be reached at all"; return; fi
  proxy_expect B20-allowed-host "asked the proxy for a tunnel to $host:443, a host on the agent's list (the control: refusals mean nothing if nothing is ever allowed)" \
    "$(netprobe connect "$(param proxy)" "$(param proxy_port)" "$host:443" 20000)" 200 "the proxy must be able to resolve and reach $host: check the host's own network, then $PROXY_FIX"
}
c_B20_port_80() {
  local host
  host="$(param allowed_host)"
  if [ "$(param allow_http)" = 1 ]; then
    skip B20-port-80 http-allowed "plaintext HTTP was switched on for this session by an 'allow --url http://...' entry, so port 80 is open on purpose"; return
  fi
  if [ -z "$host" ]; then skip B20-port-80 unknown "verify.sh did not name a host from the allowlist" "the session's agent.domains list is empty"; return; fi
  proxy_expect B20-port-80 "asked the proxy for http://$host/ in plaintext on port 80 (an ALLOWED host, so only the port rule can refuse it)" \
    "$(netprobe get "$(param proxy)" "$(param proxy_port)" "http://$host/" 8000)" 403 "$PROXY_FIX"
}
c_B20_connect_port() {
  local host
  host="$(param allowed_host)"
  if [ -z "$host" ]; then skip B20-connect-port unknown "verify.sh did not name a host from the allowlist" "the session's agent.domains list is empty"; return; fi
  proxy_expect B20-connect-port "asked the proxy for a tunnel to $host:8443 (an ALLOWED host, so only the port rule can refuse it)" \
    "$(netprobe connect "$(param proxy)" "$(param proxy_port)" "$host:8443" 8000)" 403 "$PROXY_FIX"
}
c_B20_ip_literal_v4() {
  proxy_expect B20-ip-literal-v4 "asked the proxy for a tunnel to the bare address 1.1.1.1:443" \
    "$(netprobe connect "$(param proxy)" "$(param proxy_port)" 1.1.1.1:443 8000)" 403 "$PROXY_FIX"
}
c_B20_ip_literal_v6() {
  proxy_expect B20-ip-literal-v6 "asked the proxy for a tunnel to the bare address [2606:4700:4700::1111]:443" \
    "$(netprobe connect "$(param proxy)" "$(param proxy_port)" '[2606:4700:4700::1111]:443' 8000)" 403 "$PROXY_FIX"
}
c_B21_vendor_plain() {
  local host
  host="$(param vendor_host)"
  if [ -z "$host" ]; then skip B21-vendor-plain unknown "verify.sh did not name the model vendor's host" "the session's sidecar.domains list is empty"; return; fi
  proxy_expect B21-vendor-plain "asked the proxy, from the agent, for a tunnel to the model vendor's host $host:443 (B21-sidecar-allowed shows the same request is allowed from the sidecar)" \
    "$(netprobe connect "$(param proxy)" "$(param proxy_port)" "$host:443" 8000)" 403 "$PROXY_FIX"
}
c_B21_vendor_forged() {
  local host sidecar
  host="$(param vendor_host)"; sidecar="$(param sidecar)"
  if [ -z "$host" ]; then skip B21-vendor-forged unknown "verify.sh did not name the model vendor's host" "the session's sidecar.domains list is empty"; return; fi
  proxy_expect B21-vendor-forged "asked again for $host:443, this time claiming to be the sidecar with X-Forwarded-For: $sidecar and Forwarded: for=$sidecar" \
    "$(netprobe connect "$(param proxy)" "$(param proxy_port)" "$host:443" 8000 "X-Forwarded-For: $sidecar" "Forwarded: for=$sidecar")" 403 "$PROXY_FIX"
}

# --- B23: the sidecar forwards only what the CLI needs ---------------------------------------------
c_B23_unknown_path() {
  local out
  out="$(PROBE_CA_B64="$(param sidecar_ca)" netprobe post "$(param sidecar)" "$(param sidecar_port)" GET /verify-not-forwarded none path verify-dummy none 8000)"
  case "$out" in
    "http 404"*) pass B23-unknown-path "asked this session's sidecar for /verify-not-forwarded, a path no CLI uses$( [ -z "$(param sidecar_ca)" ] || printf ' (over TLS, with the session certificate)'): 404, not forwarded" ;;
    http\ *) fail B23-unknown-path "asked the sidecar for /verify-not-forwarded and it answered ${out#http }, expected 404" "the sidecar must forward only the routes in agents/<agent>/sidecar.json (images/credsidecar/sidecar.mjs)" ;;
    unavailable*) skip B23-unknown-path no-probe "not attempted: ${out#unavailable }" "node must be in the agent image" ;;
    *) fail B23-unknown-path "no answer from the sidecar at $(param sidecar):$(param sidecar_port) ($out), so nothing was proven" "the sidecar container must be running and reachable from the agent: ./sandbox logs sidecar" ;;
  esac
}

# --- B30: the git relay (only with --git-relay) --------------------------------------------------------
relay_push() {   # <check> <ref> <what>
  local name="$1" ref="$2" what="$3" url out rc=0
  if [ "$(param git_relay)" != 1 ]; then
    skip "$name" no-git-relay "this session has no git relay (it is off unless you pass --git-relay)"; return
  fi
  url="http://$(param relay):8081/verify.git"
  if ! have git || ! git -C /workspace/repo rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    skip "$name" no-probe "there is no commit in /workspace/repo to push" "import a repository first (./sandbox run does)"; return
  fi
  # The control: the relay must answer a harmless listing, or a failed push
  # would prove nothing.
  if ! GIT_TERMINAL_PROMPT=0 timeout 30 git -c http.proxy= ls-remote "$url" >/dev/null 2>&1; then
    skip "$name" no-probe "the relay at $url did not answer a plain listing, so a refused push would prove nothing" "./sandbox logs relay: is the relay running and was its token accepted?"; return
  fi
  out="$(GIT_TERMINAL_PROMPT=0 timeout 60 git -C /workspace/repo -c http.proxy= push "$url" "HEAD:$ref" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$name" "pushed $what through the relay and it was ACCEPTED: $ref now exists on your remote" \
      "delete $ref on the remote by hand, then look at the push filter in images/gitrelay/relay.mjs"
  else
    pass "$name" "pushed $what ($ref) through the relay: refused ($(printf '%s' "$out" | grep -E 'rejected|error|fatal' | head -n 1))"
  fi
}
c_B30_other_branch() { relay_push B30-other-branch "refs/heads/sandbox-verify-probe-$$" "to a branch other than the session's"; }
c_B30_tag()          { relay_push B30-tag "refs/tags/sandbox-verify-probe-$$" "a tag"; }

# ---------------------------------------------------------------------------
# Helpers for checks that verify.sh judges on the host. They print a bare
# result, not PASS/FAIL: the host combines it with what it sees from outside.
# ---------------------------------------------------------------------------
# One request to a sidecar, as the CLI would send it, with a dummy credential.
h_sidecar_probe() {
  netprobe post "$(param target)" "$(param sidecar_port)" "$(param route_method)" "$(param route_path)" "$(param dialect)" "$(param kind)" "$(param dummy)" "$(param marker)" 30000
  REPORTED=1
}
# [B32] Writes escape sequences where the launcher will later print them:
# into this container's own log (the first process's output, which Podman
# collects) and into a request line the proxy logs.
h_plant_escapes() {
  local marker
  marker="$(param marker)"
  if printf '\033]0;%s\007\033[2J\033[31m%s\033[0m\n' "$marker" "$marker" > /proc/1/fd/1 2>/dev/null; then
    printf 'log planted\n'
  else
    printf 'log failed\n'
  fi
  printf 'request %s\n' "$(netprobe escget "$(param proxy)" "$(param proxy_port)" "$(param denied_host)" "$marker" 8000)"
  REPORTED=1
}

# ---------------------------------------------------------------------------
# Run what was asked for.
# ---------------------------------------------------------------------------
if [ "${#CHECKS[@]}" -eq 0 ]; then
  printf 'usage: verify-inside.sh [name=value]... <check-name>...\n' >&2
  exit 2
fi
for check in "${CHECKS[@]}"; do
  REPORTED=0
  case "$check" in
    sidecar-probe) h_sidecar_probe || true; continue ;;
    plant-escapes) h_plant_escapes || true; continue ;;
  esac
  # Each check decides for itself what a failing command means, so errors
  # inside one must not end the script.
  set +e
  case "$check" in
    B01-user)              c_B01_user ;;
    B02-caps)              c_B02_caps ;;
    B02-raw-socket)        c_B02_raw_socket ;;
    B03-nnp-flag)          c_B03_nnp_flag ;;
    B03-setuid-inert)      c_B03_setuid_inert ;;
    B04-seccomp-mode)      c_B04_seccomp_mode ;;
    B04-ptrace)            c_B04_ptrace ;;
    B04-mount)             c_B04_mount ;;
    B04-unshare-user)      c_B04_unshare_user ;;
    B04-clone-newuser)     c_B04_clone_newuser ;;
    B04-clone3)            c_B04_clone3 ;;
    B04-setns)             c_B04_setns ;;
    B04-process-vm-readv)  c_B04_process_vm_readv ;;
    B04-bpf)               c_B04_bpf ;;
    B05-lsm-label)         c_B05_lsm_label ;;
    B06-runtime-sockets)   c_B06_runtime_sockets ;;
    B06-runtime-binaries)  c_B06_runtime_binaries ;;
    B06-pid1)              c_B06_pid1 ;;
    B06-cgroupns)          c_B06_cgroupns ;;
    B07-readonly-root)     c_B07_readonly_root ;;
    B08-writable-set)      c_B08_writable_set ;;
    B08-mount-flags)       c_B08_mount_flags ;;
    B08-fill)              c_B08_fill ;;
    B09-mounts)            c_B09_mounts ;;
    B10-pids-max)          c_B10_pids_max ;;
    B10-memory-max)        c_B10_memory_max ;;
    B10-swap-max)          c_B10_swap_max ;;
    B10-cpu-max)           c_B10_cpu_max ;;
    B10-fork-limit)        c_B10_fork_limit ;;
    B11-ulimits)           c_B11_ulimits ;;
    B11-fsize)             c_B11_fsize ;;
    B12-no-route)          c_B12_no_route ;;
    B13-gateway-ports)     c_B13_gateway_ports ;;
    B13-etc-hosts)         c_B13_etc_hosts ;;
    B14-no-resolver)       c_B14_no_resolver ;;
    B14-dns-by-hand)       c_B14_dns_by_hand ;;
    B15-key-files)         c_B15_key_files ;;
    B15-push)              c_B15_push ;;
    B16-add-address)       c_B16_add_address ;;
    B16-packet-socket)     c_B16_packet_socket ;;
    B20-denied-host)       c_B20_denied_host ;;
    B20-allowed-host)      c_B20_allowed_host ;;
    B20-port-80)           c_B20_port_80 ;;
    B20-connect-port)      c_B20_connect_port ;;
    B20-ip-literal-v4)     c_B20_ip_literal_v4 ;;
    B20-ip-literal-v6)     c_B20_ip_literal_v6 ;;
    B21-vendor-plain)      c_B21_vendor_plain ;;
    B21-vendor-forged)     c_B21_vendor_forged ;;
    B23-unknown-path)      c_B23_unknown_path ;;
    B30-other-branch)      c_B30_other_branch ;;
    B30-tag)               c_B30_tag ;;
    *) fail "$(tidy "$check")" "there is no check of this name in verify-inside.sh" "scripts/verify.sh and images/agent/verify-inside.sh are out of step: rebuild the agent image" ;;
  esac
  set -e
  if [ "$REPORTED" -eq 0 ]; then
    fail "$check" "the check ended without a result" "run it by hand in './sandbox shell' to see the error: /usr/share/sandbox/verify-inside.sh $check"
  fi
done
exit 0

# The check names, and the barrier each one tests:
#   B01-user               B01  fixed non-root user
#   B02-caps               B02  capability sets are empty
#   B02-raw-socket         B02  raw socket refused
#   B03-nnp-flag           B03  no-new-privileges flag
#   B03-setuid-inert       B03  a setuid program gains nothing
#   B04-seccomp-mode       B04  a filter is attached
#   B04-ptrace             B04  ptrace refused (proves OUR filter)
#   B04-mount              B04  mount refused
#   B04-unshare-user       B04  unshare -U refused
#   B04-clone-newuser      B04  clone(CLONE_NEWUSER) refused
#   B04-clone3             B04  clone3 refused
#   B04-setns              B04  setns refused
#   B04-process-vm-readv   B04  reading process memory refused
#   B04-bpf                B04  bpf refused
#   B05-lsm-label          B05  SELinux label
#   B06-runtime-sockets    B06  no runtime socket
#   B06-runtime-binaries   B06  no runtime program
#   B06-pid1               B06  private process list
#   B06-cgroupns           B06  private cgroup namespace
#   B07-readonly-root      B07  read-only root
#   B08-writable-set       B08  which mounts accept files
#   B08-mount-flags        B08  nosuid, nodev, size caps, 0700 home
#   B08-fill               B08  full means "no space left", not a kill (slow)
#   B09-mounts             B09  no host file or folder mounted
#   B10-pids-max           B10  process limit, by value
#   B10-memory-max         B10  memory limit, by value
#   B10-swap-max           B10  swap allowance zero
#   B10-cpu-max            B10  CPU limit, by value
#   B10-fork-limit         B10  forking up to the limit is refused (slow)
#   B11-ulimits            B11  ulimits, by value
#   B11-fsize              B11  writing past the largest-file limit
#   B12-no-route           B12  direct connection to a public address
#   B13-gateway-ports      B13  nothing at the gateway's address
#   B13-etc-hosts          B13  /etc/hosts is the image's, loopback only
#   B14-no-resolver        B14  names do not resolve
#   B14-dns-by-hand        B14  hand-made DNS question
#   B15-key-files          B15  no key or credential files
#   B15-push               B15  no authenticated push
#   B16-add-address        B16  cannot add an address
#   B16-packet-socket      B16  cannot open a packet socket
#   B20-denied-host        B20  host not on the list
#   B20-allowed-host       B20  control: an allowed host works
#   B20-port-80            B20  plaintext port 80
#   B20-connect-port       B20  tunnel to a port other than 443
#   B20-ip-literal-v4      B20  bare IPv4 address
#   B20-ip-literal-v6      B20  bare IPv6 address
#   B21-vendor-plain       B21  vendor's host from the agent
#   B21-vendor-forged      B21  the same with a forged forwarding header
#   B23-unknown-path       B23  a path the sidecar does not forward
#   B30-other-branch       B30  push to another branch through the relay
#   B30-tag                B30  push a tag through the relay
