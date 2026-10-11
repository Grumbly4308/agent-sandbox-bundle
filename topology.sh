# shellcheck shell=bash
# topology.sh — what a session is made of, and every flag it runs with.
#
# SKELETON for review. Nothing in this file has been run against Podman yet.
#
# ./sandbox sources this file. It is the only place that decides how a
# network, a volume or a container is created: each function below fills the
# array TOPO with the arguments for one `podman ... create` call, and
# ./sandbox passes that array on unchanged. To see what protects you, read
# this file; to change it, change this file.
#
# How to read it
#   * Every barrier is tagged with its tier and its number in the register in
#     docs/00-threat-model.md:
#       [physical] the kernel enforces it
#       [logical]  a separate process enforces it
#     Nothing here asks the agent to restrain itself (the third tier, vapor):
#     no permission rules, no hooks, no instructions.
#   * The SANDBOX_ variables are set by ./sandbox from your command line and
#     your settings file. The one you may set yourself is
#     SANDBOX_RUNTIME_CLASS.
#   * The only runtime is rootless Podman, driven directly. There is no
#     compose file and no second tool whose version could change the result.
#   * `mode=1777` on a memory-backed mount means "anyone may create files
#     here, only the owner may delete them", like /tmp. Such a mount starts
#     out owned by root, so each container's single user creates a private
#     directory inside it.
#
# One set of objects per session: every name starts with the session name and
# every object carries the session label, so sessions never share a proxy, a
# credential or a workspace, and `destroy` removes everything by label.

# TOPO is read by ./sandbox after each call.
# shellcheck disable=SC2034
TOPO=()

# ---------------------------------------------------------------------------
# Networks
# ---------------------------------------------------------------------------

# The agent's only network.
topo_network_sandbox() {
  TOPO=(
    --label "agent-sandbox.session=${SANDBOX_SESSION:?}"
    # [physical B12] No route to anywhere else.
    --internal
    # [physical B13, B14] No name service on this network, so there is
    # nothing to ask about names. Today Podman then gives the network no
    # gateway address either; verify fails if one ever appears.
    --disable-dns
    # Picked per session by ./sandbox, outside the ranges Podman hands out by
    # itself, so sessions can run side by side. Fixed addresses start at .2.
    --subnet "${SANDBOX_SUBNET:?}"
    "${SANDBOX_SESSION}-sandbox"
  )
}

# The ordinary outbound network. Only the proxy is attached to it.
topo_network_egress() {
  TOPO=(
    --label "agent-sandbox.session=${SANDBOX_SESSION:?}"
    # No name service of Podman's here either: the proxy uses your host's
    # resolvers, and nothing else on this network needs a name.
    --disable-dns
    --subnet "${SANDBOX_EGRESS_SUBNET:?}"
    "${SANDBOX_SESSION}-egress"
  )
}

# ---------------------------------------------------------------------------
# The workspace volume  [physical B08, B09]
# ---------------------------------------------------------------------------
# A named volume made for this session, never a folder of yours. Code arrives
# and leaves as a git bundle piped by ./sandbox. The repository itself goes in
# /workspace/repo, created 0700 by the agent's user at start.
#
# It is a directory on the disk store when the host has one, and held in
# memory when it has not; ./sandbox decides which and says so at `run`.
#
# A memory-backed volume exists only while some running container has it
# mounted. That container is the keeper (see topo_keeper), not the agent, so
# the workspace outlives the agent container.
topo_volume_workspace() {
  TOPO=(--label "agent-sandbox.session=${SANDBOX_SESSION:?}")
  case "${SANDBOX_WORKSPACE_DRIVER:?}" in
    memory)
      # For a host with no disk store. Held in memory, capped by the kernel
      # for this session alone, never on disk. Everything in the workspace
      # has to fit in the memory the host can spare.
      TOPO+=(
        --opt type=tmpfs
        --opt device=tmpfs
        --opt "o=size=${SANDBOX_WORKSPACE_SIZE:?},nosuid,nodev,mode=1777"
      )
      ;;
    local)
      # The default when there is a store: a directory on it. The store is a
      # filesystem of fixed size that `doctor` helps you create once. This IS
      # a directory on your host's disk, made for the purpose. The kernel's
      # cap is the size of that filesystem, shared by every session that uses
      # it. ./sandbox watches this session's share from the host [logical
      # B33] and refuses this driver when the store does not exist. The data
      # is on disk, across a reboot too, until `destroy`.
      TOPO+=(
        --opt type=none
        --opt "device=${SANDBOX_STORE:?}/${SANDBOX_SESSION}"
        --opt "o=bind,nosuid,nodev"
      )
      ;;
    *)
      echo "topology: unknown workspace driver '${SANDBOX_WORKSPACE_DRIVER}'" >&2
      return 1
      ;;
  esac
  TOPO+=("${SANDBOX_SESSION}-workspace")
}

# ---------------------------------------------------------------------------
# Shared building blocks
# ---------------------------------------------------------------------------

# Hardening every container gets. The agent adds a stricter system-call
# filter and more limits on top (see topo_agent).
_topo_hardening() {
  local name="$1"
  TOPO=(
    --name "${SANDBOX_SESSION:?}-${name}"
    --label "agent-sandbox.session=${SANDBOX_SESSION}"
    --pull=never                    # images are built or fetched by digest beforehand; nothing is pulled at start
    --http-proxy=false              # [physical B15] Podman would otherwise copy your own proxy settings, and any password in them, into the container
    --no-hosts                      # [physical B13] Podman's own /etc/hosts would name your host and give one of its addresses; without it the container sees the file in its image (the agent image names only localhost)
    --read-only                     # [physical B07] root filesystem is immutable
    --read-only-tmpfs=false         # [physical B08] without this, Podman adds writable /tmp, /run, /var/tmp and /dev/shm itself
    --cap-drop=ALL                  # [physical B02] no Linux capabilities; none are added back anywhere in this file
    --security-opt=no-new-privileges  # [physical B03] a setuid program gains nothing
                                    # seccomp: Podman's default filter applies unless one is named
    --ipc=private                   # [physical B06] own shared-memory namespace
    --pid=private                   # [physical B06] own process list
    --cgroupns=private              # [physical B06] own view of the cgroup tree
    --ulimit core=0:0               # [physical B11] no core dumps: a crash must not copy a container's memory (the sidecar's holds a token) to disk
    --restart=no                    # a container that died stays dead; nothing restarts it unseen
    --stop-timeout=5                # how long `podman stop` waits before killing; `destroy` should be quick
    # [logical B28] Logs: stdout/stderr, collected by Podman into a file that
    # belongs to the container and is deleted with it. No log path is mounted
    # into any container. Stated explicitly because some hosts default to the
    # system journal, which would outlive `destroy`.
    --log-driver=k8s-file
    --log-opt max-size=10m
  )
  # [physical B05] SELinux, named explicitly where the host runs it. Set by
  # ./sandbox to `label=type:container_t` on such hosts and left empty
  # elsewhere: rootless Podman applies no AppArmor profile.
  if [ -n "${SANDBOX_SELINUX_OPT:-}" ]; then
    TOPO+=(--security-opt "$SANDBOX_SELINUX_OPT")
  fi
  # Opt-in: `runsc` = gVisor. Untested until a host with gVisor is available;
  # verify checks the runtime really in use.
  if [ -n "${SANDBOX_RUNTIME_CLASS:-}" ]; then
    TOPO+=(--runtime "$SANDBOX_RUNTIME_CLASS")
  fi
  # No --privileged, no --network=host, no --pid=host, no devices, no runtime
  # socket mounted — in any container [physical B06].
}

# [physical B10] cgroup limits: CPU, memory, process count. The memory-plus-
# swap limit is set equal to the memory limit, so the swap allowance is zero
# and nothing can be pushed to the host's swap. (If a Podman insists that the
# second number be larger, the fallback is --cgroup-conf=memory.swap.max=0.)
_topo_limits() {
  local cpus="$1" memory="$2" pids="$3"
  TOPO+=(
    --cpus "$cpus"
    --memory "$memory"
    --memory-swap "$memory"
    --pids-limit "$pids"
  )
}

# [logical B26] The deadline. Podman's own monitor, a process outside the
# container, kills the container when the time is up, whether or not
# ./sandbox is still running. Every container gets one except the keeper.
# 0 is Podman's own "no timeout": a session started with `--ttl none` (the
# default) runs until `destroy`. The timer starts again whenever the
# container does (`resume`).
_topo_deadline() {
  TOPO+=(--timeout "${SANDBOX_TTL_SECONDS:?}")
}

# ---------------------------------------------------------------------------
# agent — the untrusted part. Everything else exists to contain this.
# ---------------------------------------------------------------------------
topo_agent() {
  _topo_hardening agent
  # Memory limit = the agent's allowance plus the caps on /tmp, home and
  # /dev/shm, plus the workspace's cap when that is held in memory: files in
  # memory count as memory. Without the sum, a full workspace would get
  # the agent killed instead of getting "no space left". ./sandbox prints
  # the total and refuses if the host has less.
  _topo_limits "${SANDBOX_CPUS:?}" "${SANDBOX_MEM_LIMIT:?}" "${SANDBOX_PIDS:?}"
  _topo_deadline
  TOPO+=(
    # [physical B01] A fixed, non-root user that exists only inside the
    # image. It does not need to match your host user: no host directory is
    # mounted. Under rootless Podman it is not even a real user on your host.
    --user 61000:61000

    # [physical B04] A stricter system-call filter than the default: also
    # removes ptrace and reading another process's memory, and keeps mount,
    # unshare, setns and bpf refused whatever capabilities are present.
    # Generated by scripts/make-seccomp.sh from a pinned, checksummed
    # upstream.
    --security-opt "seccomp=${SANDBOX_ROOT:?}/seccomp/agent-seccomp.json"

    # [physical B08] The writable places: /tmp, the home directory, /dev/shm
    # and the workspace. All size-capped, and `nosuid,nodev` means nothing in
    # them can be a setuid program or a device. `exec` is stated on purpose:
    # builds and test runners execute files from /tmp and the home directory.
    --tmpfs "/tmp:size=${SANDBOX_TMP_SIZE:?},mode=1777,nosuid,nodev,exec"
    # Mounted one level up; the real home, /home/agent, is created inside it
    # at start with mode 0700.
    --tmpfs "/home:size=${SANDBOX_HOME_SIZE:?},mode=1777,nosuid,nodev,exec"
    # Shared memory. Python's test tools need it. Counted in the memory limit.
    --tmpfs "/dev/shm:size=64m,mode=1777,nosuid,nodev,noexec"
    # [physical B09] The workspace volume. Nothing else is mounted here apart
    # from two small read-only files Podman generates itself (/etc/hostname
    # and a marker file).
    --mount "type=volume,source=${SANDBOX_SESSION}-workspace,destination=/workspace"
    --workdir /workspace            # where `podman exec` starts

    # [physical B11] Per-process ceilings.
    --ulimit nofile=65536:65536     # open files; build tools open many
    # Counted per user id across all sessions (they all use 61000); the
    # per-session limit is --pids-limit above. Default 512; raise it in your
    # settings file if you run several sessions together.
    --ulimit "nproc=${SANDBOX_NPROC:?}:${SANDBOX_NPROC}"
    --ulimit "fsize=${SANDBOX_FSIZE_BYTES:?}:${SANDBOX_FSIZE_BYTES}"   # largest single file, in bytes = the workspace cap

    # [physical B12] One network, and it has no route out. The address is
    # fixed so the proxy can tell the agent from the sidecar; with no
    # capabilities the agent cannot change it [physical B16].
    --network "${SANDBOX_SESSION}-sandbox:ip=${SANDBOX_AGENT_IP:?}"
    # [physical B14] Podman writes no resolver configuration; the image ships
    # an empty one, on a read-only root. Name lookups fail at once. Nothing
    # here depends on names: the proxy, the sidecar, the git relay and any
    # sibling service are reached by address.
    --dns=none
    # The container's own name, which the image's /etc/hosts points at
    # loopback: some tools (Java, some test runners) look their own name up.
    --hostname sandbox

    --env HOME=/home/agent
    # Where the credential sidecar is. agents/<name>/launch points the CLI at
    # it; the address differs from session to session. HTTPS when the CLI
    # needs it (SANDBOX_SIDECAR_TLS, set by ./sandbox for Codex with a
    # subscription); the certificate is the session's own, see ./sandbox.
    --env "SANDBOX_SIDECAR_URL=http${SANDBOX_SIDECAR_TLS:+s}://${SANDBOX_SIDECAR_IP:?}:8080"
    # The only way out for everything that is not a model call.
    --env "HTTP_PROXY=http://${SANDBOX_PROXY_IP:?}:3128"
    --env "HTTPS_PROXY=http://${SANDBOX_PROXY_IP}:3128"
    --env "http_proxy=http://${SANDBOX_PROXY_IP}:3128"    # lowercase too: curl, pip and git read these
    --env "https_proxy=http://${SANDBOX_PROXY_IP}:3128"
    # Reached directly. Left out, the CLI would send its model calls to the
    # proxy instead and every one would fail. ./sandbox adds the addresses of
    # any sibling services and the git relay.
    --env "NO_PROXY=localhost,127.0.0.1,${SANDBOX_SIDECAR_IP}${SANDBOX_NO_PROXY_EXTRA:-}"
    --env "no_proxy=localhost,127.0.0.1,${SANDBOX_SIDECAR_IP}${SANDBOX_NO_PROXY_EXTRA:-}"
    # Package caches go to the workspace, not the smaller home directory.
    --env npm_config_cache=/workspace/.cache/npm
    --env PIP_CACHE_DIR=/workspace/.cache/pip
    # [physical B15] No API key, no login, no git token. Connection strings
    # for sibling services are passed by ./sandbox when it starts the CLI.
  )
  # Settings this agent's CLI needs that are the same in every session, if
  # its plug-in has any. One file per agent, so a new agent needs no change
  # here; agents/<name>/compat.md lists every line. ./sandbox accepts only
  # NAME=value lines in this file: a bare name would copy that variable in
  # from your own environment.
  if [ -f "${SANDBOX_ROOT}/agents/${SANDBOX_AGENT:?}/env" ]; then
    TOPO+=(--env-file "${SANDBOX_ROOT}/agents/${SANDBOX_AGENT}/env")
  fi
  # Only with the disk-backed workspace: slow writes to the store's disk to
  # this many bytes a second. `doctor` checks your user may set this.
  if [ -n "${SANDBOX_IO_LIMIT:-}" ]; then
    TOPO+=(--device-write-bps "${SANDBOX_STORE_DEVICE:?}:${SANDBOX_IO_LIMIT}")
  fi
  TOPO+=(
    # One image per agent and toolchain, built here by ./sandbox; CLI version
    # and base image digest are pinned in agents/<name>/install.sh and
    # images/agent/Containerfile. `localhost/` = built on this machine.
    "localhost/agent-sandbox/agent-${SANDBOX_AGENT}:${SANDBOX_TOOLCHAIN:?}-${SANDBOX_VERSION:?}"
    # The container does nothing by itself: this is a do-nothing first
    # process that also cleans up finished children. `run`, `shell` and
    # `verify` enter with `podman exec`. It runs as the agent's user, so the
    # agent can end this container; the workspace survives that, because the
    # keeper holds it.
    sandbox-idle
  )
}

# ---------------------------------------------------------------------------
# keeper — holds the workspace open.  [logical B26]
# A container with no network and nothing to do. Its one job is to keep the
# workspace mounted, so the work is still there for `export` after the
# deadline has killed the agent container, or after the agent has ended it.
# (A workspace held in memory would vanish with its last container; one on
# the disk store would not, and the keeper is kept there too so that both
# kinds behave alike.) It is the only container with no deadline: it stays
# until you run `destroy`.
# ---------------------------------------------------------------------------
topo_keeper() {
  _topo_hardening keeper
  _topo_limits 0.1 16m 8
  TOPO+=(
    --user 61003:61003              # its own user; the agent cannot signal it
    --network none                  # reachable by nobody
    --init                          # Podman's tiny first process, so `sleep` below is cleaned up properly
    # Read-only here: the keeper never writes to the workspace.
    --mount "type=volume,source=${SANDBOX_SESSION}-workspace,destination=/workspace,ro"
    "localhost/agent-sandbox/agent-${SANDBOX_AGENT:?}:${SANDBOX_TOOLCHAIN:?}-${SANDBOX_VERSION:?}"
    sleep infinity
  )
}

# ---------------------------------------------------------------------------
# export helper — a short-lived container that writes the git bundle.
# [logical B27]
# Started by ./sandbox for each `export`, removed when it exits. It has no
# network and the agent's processes are not in it, so the agent cannot stand
# between ./sandbox and the bundle. git still reads a tree the agent wrote,
# which is why this happens in here and not on your host.
# ---------------------------------------------------------------------------
topo_export() {
  _topo_hardening export
  _topo_limits 1 1g 64
  TOPO+=(
    --rm                            # gone as soon as it exits
    --timeout 600                   # a bundle that takes longer than ten minutes is not coming
    --user 61000:61000              # the workspace's owner
    --network none
    --security-opt "seccomp=${SANDBOX_ROOT:?}/seccomp/agent-seccomp.json"   # [physical B04] as for the agent
    --tmpfs "/tmp:size=64m,mode=1777,nosuid,nodev,noexec"
    --mount "type=volume,source=${SANDBOX_SESSION}-workspace,destination=/workspace,ro"
    "localhost/agent-sandbox/agent-${SANDBOX_AGENT:?}:${SANDBOX_TOOLCHAIN:?}-${SANDBOX_VERSION:?}"
    sandbox-bundle                  # writes one bundle of the session branch to stdout
  )
}

# ---------------------------------------------------------------------------
# proxy — the only container with a route to the internet.  [logical B20]
# ---------------------------------------------------------------------------
topo_proxy() {
  _topo_hardening proxy
  _topo_limits 1 256m 64
  _topo_deadline
  TOPO+=(
    --user 31:31                    # Squid's own user, fixed in images/proxy/Containerfile; Squid never needs root here
    # Squid's scratch space. Nothing is cached; these hold a pid file and the
    # configuration rendered at start from the variables below.
    --tmpfs "/var/cache/squid:size=16m,mode=1777,nosuid,nodev,noexec"
    --tmpfs "/var/run/squid:size=16m,mode=1777,nosuid,nodev,noexec"
    # Squid 6 keeps its collapsed-forwarding tables in POSIX shared memory,
    # which is /dev/shm. Without a writable one it dies at start with
    # "shm_open ... Read-only file system", even with caching off. Proven on
    # Alpine's Squid 6.9 in Phase B.
    --tmpfs "/dev/shm:size=16m,mode=1777,nosuid,nodev,noexec"
    # The allowlists for this session, written by ./sandbox on the host and
    # mounted read-only. `./sandbox allow` and `deny` rewrite a list and tell
    # Squid to re-read it: no rebuild, no restart. ./sandbox creates the
    # directory 0755 and the lists 0644: Squid reads them as "anyone", and
    # they hold host names, not secrets. `z` relabels the directory so a
    # container on an SELinux host may read it; it is ignored elsewhere.
    # The agent cannot see this mount: it belongs to a different container.
    --volume "${SANDBOX_SESSION_DIR:?}/proxy:/etc/squid/session:ro,z"
    --network "${SANDBOX_SESSION}-sandbox:ip=${SANDBOX_PROXY_IP:?}"
    --network "${SANDBOX_SESSION}-egress"
    # [logical B21] Squid matches these exact addresses, never the whole
    # network, so a sibling service is refused everything.
    --env "SANDBOX_AGENT_IP=${SANDBOX_AGENT_IP:?}"       # may reach the general allowlist
    --env "SANDBOX_SIDECAR_IP=${SANDBOX_SIDECAR_IP:?}"   # the only address that may reach the model vendor
    --env "SANDBOX_RELAY_IP=${SANDBOX_RELAY_IP:-}"       # may reach the relay's one git host; empty unless --git-relay
    --env "SANDBOX_EGRESS_SUBNET=${SANDBOX_EGRESS_SUBNET:?}"   # so the proxy refuses names that resolve into its own outbound network
    --env "SANDBOX_ALLOW_HTTP=${SANDBOX_ALLOW_HTTP:-0}"  # plaintext port 80 is off unless asked for
    # Size caps. They apply to plaintext HTTP only: inside an HTTPS tunnel
    # the proxy cannot see sizes.
    --env "SANDBOX_REQUEST_MAX_MB=${SANDBOX_REQUEST_MAX_MB:-25}"
    --env "SANDBOX_REPLY_MAX_MB=${SANDBOX_REPLY_MAX_MB:-200}"
    "localhost/agent-sandbox/proxy:${SANDBOX_VERSION:?}"
  )
}

# ---------------------------------------------------------------------------
# credsidecar — holds the real model token so the agent never does.
# [logical B22-B25]
# ---------------------------------------------------------------------------
topo_sidecar() {
  _topo_hardening credsidecar
  _topo_limits 1 256m 64
  _topo_deadline
  TOPO+=(
    --user 61001:61001              # its own user, different from the agent's
    # Where the token is kept while the session runs: a memory-backed mount
    # in this container only. ./sandbox pipes it in over stdin after start
    # (`podman exec -i`), so it never appears in an environment variable, in
    # this file or in the session directory, and it is gone when the
    # container is. For Codex, ./sandbox pipes in a fresh token the same way
    # before the old one runs out; the long-lived login never leaves your
    # keyring.
    --tmpfs "/run/sidecar:size=1m,mode=1777,nosuid,nodev,noexec"
    --network "${SANDBOX_SESSION}-sandbox:ip=${SANDBOX_SIDECAR_IP:?}"
    --dns=none                      # resolves nothing itself; the proxy does that for it
    --env "SANDBOX_AGENT=${SANDBOX_AGENT:?}"       # which vendor's routes to serve
    --env "SANDBOX_AUTH=${SANDBOX_AUTH:?}"         # oauth (subscription) or apikey
    --env "SANDBOX_BUDGET=${SANDBOX_BUDGET:?}"     # [logical B24] model requests allowed this run
    --env "SANDBOX_SIDECAR_TLS=${SANDBOX_SIDECAR_TLS:+1}"   # 1: HTTPS only, once sidecar-load --tls has given it a key
    # Its own way out is the same proxy; it has no second network.
    --env "HTTPS_PROXY=http://${SANDBOX_PROXY_IP:?}:3128"
    "localhost/agent-sandbox/credsidecar:${SANDBOX_VERSION:?}"
  )
  # Until the token has been piped in, the sidecar answers "not ready" (503),
  # never "unauthorised" (401), which would end the CLI's turn. ./sandbox
  # pipes the token before it starts the CLI.
}

# ---------------------------------------------------------------------------
# gitrelay — optional (`run --git-relay`), off by default.  [logical B30]
# For workflows where the agent has to push by itself. It holds one narrow
# git token, piped in over stdin like the sidecar's, and accepts pushes to
# one remote and the session branch only. What it pushes does NOT go through
# `export`.
# ---------------------------------------------------------------------------
topo_gitrelay() {
  _topo_hardening gitrelay
  _topo_limits 1 128m 64
  _topo_deadline
  TOPO+=(
    --user 61002:61002              # its own user
    --tmpfs "/run/relay:size=1m,mode=1777,nosuid,nodev,noexec"   # holds the token, in memory
    --network "${SANDBOX_SESSION}-sandbox:ip=${SANDBOX_RELAY_IP:?}"
    --dns=none                      # resolves nothing itself
    --env "RELAY_UPSTREAM=${SANDBOX_RELAY_UPSTREAM:?}"        # the one repository it forwards to: the address recorded at `run`
    --env "RELAY_BRANCH=${SANDBOX_BRANCH:?}"                   # the one branch it lets a push through to
    --env "HTTPS_PROXY=http://${SANDBOX_PROXY_IP:?}:3128"      # its only way out
    "localhost/agent-sandbox/gitrelay:${SANDBOX_VERSION:?}"
  )
}

# ---------------------------------------------------------------------------
# Sibling services — started by you with `run --service <name>:<version>`,
# never by the agent. They get the shared hardening and the same no-route
# network. Treat one as part of the agent's reach: the agent holds its
# password and can run code in it.
#
# Each service is described by services/<name>/service.conf, which ./sandbox
# reads into the SVC_ variables before calling this. A new service is a new
# directory there, with no change here:
#   SVC_IMAGE    the image, pinned by digest
#   SVC_USER     the image's own non-root user
#   SVC_TMPFS    its writable paths, memory-backed and capped ("path:options")
#   SVC_ENV      its settings ("NAME=value")
#   SVC_MEMORY   memory limit, at least the sum of SVC_TMPFS plus working room
#   SVC_PIDS     process limit
#   SVC_COMMAND  the command, when the image's default would write to disk
# ---------------------------------------------------------------------------
topo_service() {
  local name="$1" address="$2" item
  _topo_hardening "svc-${name}"
  _topo_limits 1 "${SVC_MEMORY:?}" "${SVC_PIDS:?}"
  _topo_deadline
  TOPO+=(
    --user "${SVC_USER:?}"
    --network "${SANDBOX_SESSION}-sandbox:ip=${address}"
    --dns=none                      # resolves nothing
    --tmpfs "/dev/shm:size=64m,mode=1777,nosuid,nodev,noexec"   # shared memory; Postgres needs it
    # [physical B08, B09] An image may declare a data directory, and Podman
    # would quietly give it a volume on your disk with no size cap. Ignored:
    # a service's writable paths are the SVC_TMPFS lines and nothing else.
    --image-volume=ignore
  )
  # The ${name[@]+...} form matters: a service may have no entries, and old
  # bash treats expanding an empty array as an error.
  for item in ${SVC_TMPFS[@]+"${SVC_TMPFS[@]}"}; do
    TOPO+=(--tmpfs "$item")
  done
  for item in ${SVC_ENV[@]+"${SVC_ENV[@]}"}; do
    TOPO+=(--env "$item")
  done
  TOPO+=("${SVC_IMAGE:?}")
  for item in ${SVC_COMMAND[@]+"${SVC_COMMAND[@]}"}; do
    TOPO+=("$item")
  done
}
