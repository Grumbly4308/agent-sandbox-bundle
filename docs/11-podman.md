# 11 — Running on Podman instead of Docker

Rootless Podman is the better runtime for this on Linux, and the reason is
narrow but important: **there is no root daemon.** With Docker, the daemon runs
as root and membership of the `docker` group is equivalent to root on the host —
`docker run -v /:/host` is a one-line privilege escalation. A container escape
from a Docker container lands on the host as root. The same escape under
rootless Podman lands in your unprivileged user account, inside a user
namespace, holding no capabilities that matter.

That difference also changes the calculus in
[09 — Running more than one project](09-multiple-projects.md): separating
projects by Linux user only buys you isolation if the runtime is rootless.

## Switching

```bash
# in agent-sandbox/.env
SANDBOX_RUNTIME=podman
```

That is the whole change. `./sandbox` then uses `podman compose` (falling back
to `podman-compose`) and layers `docker-compose.podman.yml` on top of the base
compose file. Everything else — `init`, `new`, `go`, `verify`, `review`, `push`,
`pr`, `doctor` — behaves identically.

Leave `SANDBOX_RUNTIME` empty and the CLI takes whichever runtime is installed,
preferring Docker only because it is the more common default.

Check what you actually got:

```bash
./sandbox doctor        # reports runtime, compose provider, rootless, cgroups, SELinux
./sandbox verify        # the real self-test, inside the real container
```

## Install

```bash
# Fedora / RHEL / CentOS
sudo dnf install podman podman-compose

# Debian / Ubuntu
sudo apt install podman podman-compose

# Arch
sudo pacman -S podman podman-compose
```

### Two compose providers, and why the choice matters

`podman compose` is **not** an implementation. It is a dispatcher: if the
`docker-compose` plugin exists it delegates to that, and `docker-compose` talks
to the **Podman API socket**, not to the podman CLI. If that socket is not
running you get a failure that reads like a broken Dockerfile and is not:

```
>>>> Executing external compose provider "/usr/libexec/docker/cli-plugins/docker-compose" <<<<
ERRO[0000] Can't add file .../proxy/Dockerfile to tar: io: read/write on closed pipe
failed to connect to the docker API at unix:///run/user/1000/podman/podman.sock:
  dial unix /run/user/1000/podman/podman.sock: connect: no such file or directory
```

The build never started. The tar error is the client giving up on a dead
connection, not a problem with the file.

| Provider | Talks to | Socket needed | Notes |
|---|---|---|---|
| `podman-compose` | the podman CLI | no | native; understands podman-specific keys like `keep-id` directly |
| `podman compose` → `docker-compose` | the API socket | **yes** | fullest compose-spec support; needs `podman.socket` running |

`./sandbox` prefers `podman-compose` when it is installed, precisely because it
removes the socket from the equation. When it falls through to the socket-based
provider it starts the socket for you — `systemctl --user start podman.socket`,
or a direct `podman system service` if there is no user systemd session (which
is the usual case inside containers).

Start it by hand if you prefer:

```bash
systemctl --user enable --now podman.socket
# no systemd user session?
podman system service --time=0 "unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock" &
```

Pin the provider explicitly in `.env` if the automatic choice is wrong:

```
SANDBOX_COMPOSE=podman-compose
SANDBOX_COMPOSE="podman compose"
```

`./sandbox doctor` reports which provider is in use and, for the socket-based
one, whether the socket is actually up.

Enable lingering so your containers survive logout — relevant if you ever run
a long agent session over SSH:

```bash
sudo loginctl enable-linger "$USER"
```

## The two things that actually differ

Both are handled by `docker-compose.podman.yml`. They are worth understanding
because both fail *silently* — you get wrong behaviour rather than an error.

### 1. User namespaces, and files owned by nobody

Rootless Podman maps container uid 0 to **your** host uid, and container uid
1000 to a subuid from `/etc/subuid` — typically 100999. The agent runs as uid
1000 specifically so that files it writes into the mounted workspace come back
owned by you. Under default rootless mapping, they come back owned by 100999,
which the host renders as `nobody`, and you cannot commit or even delete them
without help.

`docker-compose.podman-userns.yml` fixes it:

```yaml
  agent:
    userns_mode: "keep-id"
```

`keep-id` maps your host uid to the same uid inside the container, which is
exactly what the image was built for (`HOST_UID`/`HOST_GID` build args).

Only the agent gets it. The proxy runs as `squid` (uid 31) — not your uid, so
there is nothing to keep — and only ever reads one world-readable file.

**Why it is a separate overlay file.** podman-compose places every service into
one shared pod, and a pod owns its own user namespace, so a per-container
userns cannot also apply:

```
Error: --userns and --pod cannot be set together
```

`./sandbox` passes `--in-pod=false` to podman-compose whenever keep-id is in
play, which resolves it — the pod was buying nothing here, since the isolation
comes from the `internal:` network and the container flags rather than from
co-locating services. If your podman-compose is older than that flag, the CLI
says so and you can set `SANDBOX_USERNS=off` in `.env` to drop the file, then
repair ownership by hand.

Verify with the thing that actually matters:

```bash
./sandbox shell
> touch /workspace/repo/ownership-probe && exit
ls -l workspace/ownership-probe     # must show YOU, not nobody/100999
rm workspace/ownership-probe
```

If it shows `nobody`, your Podman did not honour `keep-id` from the compose
file — some compose providers drop unknown keys quietly. Two fallbacks:

```bash
# a) bypass compose for the agent
podman run --rm -it --userns=keep-id \
  -v ./workspace:/workspace/repo:z ... localhost/agent-sandbox-agent

# b) repair ownership after the fact
podman unshare chown -R 0:0 workspace     # 0 inside the userns == you outside
```

Check you have subuid ranges at all — without them rootless Podman cannot map
anything:

```bash
grep "^$USER:" /etc/subuid /etc/subgid
# absent? →  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
#            podman system migrate
```

### 2. SELinux labels

On Fedora, RHEL and CentOS, a bind mount with no SELinux label is unreadable
inside the container. The symptom is a `Permission denied` on a file that
plainly exists and is plainly world-readable — the same shape as the deploy-key
uid problem in [06](06-credentials.md), and easy to misdiagnose as one.

The overlay adds `:z` to every bind mount:

```yaml
      - ./workspace:/workspace/repo:z
      - ./profile:/opt/profile:ro,z
```

`:z` (shared) rather than `:Z` (private), so a second sandbox — or you, on the
host — can still read the same paths. Be aware that this **relabels the real
directory on your disk**. Harmless for these paths; think twice before pointing
a `:z` mount at something like your home directory.

On a non-SELinux system the suffix is accepted and ignored, so the overlay is
safe on Debian, Ubuntu and Arch too.

## Things that behave differently, and what the CLI does about them

| | Docker | Podman | Handled by |
|---|---|---|---|
| `depends_on: service_healthy` | honoured | not honoured by all providers | `./sandbox` polls the proxy on port 3128 for up to 30s before starting the agent |
| `compose run --build` | supported | not universally | `./sandbox` builds first, then runs |
| `compose kill -s HUP` | supported | unreliable | `./sandbox reload` signals the container directly with `podman kill` |
| `mem_limit` / `cpus` | enforced | **ignored** on rootless cgroups v1 | `./sandbox doctor` warns; see below |

### Resource limits need cgroups v2

This is the one real capability gap. On rootless **cgroups v1**, `mem_limit`,
`cpus` and `pids_limit` are silently ignored — the fork bomb the sandbox is
supposed to contain is not contained, and nothing tells you.

```bash
[ -f /sys/fs/cgroup/cgroup.controllers ] && echo "v2 — good" || echo "v1 — limits ignored"
```

Any current Fedora, RHEL 9+, Ubuntu 22.04+ or Arch is already on v2. If you are
on v1, either boot with `systemd.unified_cgroup_hierarchy=1` or accept that
Part 8's ceilings are not in force and rely on the wall-clock kill switch
instead. `./sandbox doctor` reports this.

Also make sure you are using `crun` rather than `runc` — it is the default on
Podman 4+ and has better rootless cgroup v2 support:

```bash
podman info --format '{{.Host.OCIRuntime.Name}}'
```

## The other path: Docker Compose against the Podman socket

If your compose provider turns out to be missing features, you can keep the
real `docker compose` CLI and point it at a rootless Podman socket. You get
Podman's security model with Docker Compose's complete feature set —
`service_healthy`, `run --build`, all of it.

```bash
systemctl --user enable --now podman.socket
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"

cd agent-sandbox
SANDBOX_RUNTIME=docker ./sandbox go      # 'docker' CLI, Podman underneath
```

Keep `SANDBOX_RUNTIME=docker` in this mode — you *are* using the docker CLI —
but you still want the overlay's `keep-id` and `:z`, so pass it explicitly:

```bash
docker compose -f docker-compose.yml -f docker-compose.podman.yml up -d egress-proxy
```

Whether Podman's Docker-compatible API honours `UsernsMode: keep-id` varies by
version, so run the ownership probe above before trusting it.

## What does *not* change

Everything that carries the actual security properties works identically:
`read_only: true`, the tmpfs mounts, `cap_drop: [ALL]`,
`no-new-privileges`, the `internal: true` network with no route out, the Squid
allowlist, the seccomp profile from `scripts/make-seccomp.sh`, and every check
in `./sandbox verify`.

`./sandbox verify` is the answer to "did switching runtime break a wall?" — run
it after the switch, not before.
