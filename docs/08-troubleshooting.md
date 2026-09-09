# 08 — Troubleshooting

Every entry below is a failure that actually happened while setting this up,
with the real cause rather than the plausible one. The plausible cause is
listed too, because in each case it was the first guess and it was wrong.

Start here: `./sandbox doctor` checks and repairs most of the state problems in
this document.

---

## Clone and remote

### `The project you were looking for could not be found or you don't have permission to view it`

You passed an SSH URL with a port in scp-style syntax:

```
git@gitlab.example.org:2222/group/repo.git
```

**Not** a permissions problem, and not a sandbox problem — this fails on the
host, in `./sandbox init`, before any container is involved.

git's scp-like syntax (`user@host:path`) has no port field. Everything after
the first colon is the *path*, so git connects on the default port 22 and asks
for a repository literally named `2222/group/repo.git`. GitLab returns the same
message for "does not exist" and "you may not see it" — by design, so the
server does not leak which private repos exist — so the error tells you nothing
about which it was.

Confirm the key itself is fine, which it usually is:

```bash
ssh -p 2222 -T git@gitlab.example.org      # → Welcome to GitLab, @you!
```

That test passes because you typed `-p 2222` explicitly. Git never did.

Use the `ssh://` form, the only one that can carry a port:

```bash
./sandbox init ssh://git@gitlab.example.org:2222/group/repo.git
```

`./sandbox init` now rewrites the scp-style form for you and prints what it
did. Or put the port in `~/.ssh/config` and use a host alias:

```
Host gitlab-work
  HostName gitlab.example.org
  Port 2222
  User git
```

```bash
./sandbox init gitlab-work:group/repo.git
```

### `INFO: Your SSH key expires soon`

GitLab-side key expiry, unrelated to the sandbox. Rotate it before it stops
you mid-session: generate a new key, add it under Preferences → SSH Keys, and
remove the old one.

---

## The egress proxy

### `dependency failed to start: container <name>-egress-proxy is unhealthy`

The agent never starts, because compose waits for
`egress-proxy: condition: service_healthy`. The healthcheck summary hides the
actual error. Get it:

```bash
docker compose logs egress-proxy
docker inspect --format='{{json .State.Health}}' <name>-egress-proxy | python3 -m json.tool
```

### `FATAL: Cannot open '/dev/stdout' for writing.`

The one that bites everybody. Full log signature:

```
ERROR: Cannot open cache_log (/dev/stderr) for writing;
    fopen(3) error: (13) Permission denied
...
FATAL: Cannot open '/dev/stdout' for writing.
The parent directory must be writeable by the user 'squid', which is the
cache_effective_user set in squid.conf.
```

Squid starts as root, reads its config, calls `setuid()` to the `squid` user
because of `cache_effective_user`, and only *then* opens its log targets. The
`/dev/stdout` and `/dev/stderr` streams were set up by Docker for the identity
the container started with — root — so after the privilege drop squid can no
longer open them by name. It exits, `restart: unless-stopped` brings it back,
and it loops.

Adding capabilities does not help: `CHOWN`, `SETUID`, `SETGID` and
`DAC_OVERRIDE` are all cleared by the kernel the moment `setuid()` lands on a
non-zero uid, which is before the log files are opened.

The fix is to never drop privileges at all — start as the unprivileged user:

```yaml
# docker-compose.yml
  egress-proxy:
    user: "squid:squid"
    cap_drop: [ALL]            # and delete the cap_add line entirely
```

```dockerfile
# proxy/Dockerfile
USER squid
```

```
# proxy/squid.conf — squid can no longer write the default /var/run/squid.pid
pid_filename /var/cache/squid/squid.pid
```

All three are already applied in this bundle. `cache_effective_user squid` can
stay; with the container already running as `squid` it is a no-op.

### Everything is denied, including hosts that are on the list

CRLF line endings in `proxy/allowlist.txt`. Squid reads `github.com\r` as a
different domain:

```bash
sed -i 's/\r$//' proxy/allowlist.txt && ./sandbox reload
```

### The proxy is healthy but a host is still refused

That is the sandbox working. `./sandbox logs proxy` shows the `TCP_DENIED/403`
and the exact hostname the agent asked for. If it should be allowed:

```bash
./sandbox allow docs.internal.example.com
```

---

## Workspace and git state

These three errors are the same root problem seen from different angles: the
old design used a `git worktree`, whose state is split between `workspace/`
and `project/.git/worktrees/<name>/`. Break either half and git gets confused
in a way that neither `prune` nor `remove` fully clears.

**This bundle no longer uses worktrees.** `./sandbox new` makes a full clone,
which is self-contained. If you are on an older copy, `./sandbox doctor` will
offer to convert.

### `fatal: not a git repository: .../project/.git/worktrees/workspace`

The checkout exists; its registration does not. Usually because `project/` was
deleted and re-cloned (say, while fixing the SSH URL above) while an old
`workspace/` was left behind. `git worktree prune` does *not* fix this — it
only cleans the opposite case.

```bash
rm -rf workspace
./sandbox new <task>
```

### `'.../workspace' is a missing but already registered worktree`

The mirror image: the registration exists, the checkout does not — the state
you land in right after the `rm -rf` above.

```bash
git -C project worktree prune -v
./sandbox new <task>
```

### `fatal: a branch named 'agent/<task>' already exists`

`git worktree add -b` creates the branch *before* it fails on the missing
directory, so a failed attempt leaves the branch behind and the retry collides
with it.

```bash
git -C project branch -D agent/<task>
./sandbox new <task>
```

With clone-based workspaces this cannot happen: each `./sandbox new` starts
from a fresh clone, so there is no branch left over to collide with.

### `fatal: not a git repository` **inside the container**

Symptom: everything builds, the proxy reports `Healthy`, the agent container is
created, and then git fails immediately.

A linked worktree's `.git` is not a directory — it is a file containing an
absolute host path:

```
gitdir: /home/you/agent-sandbox/project/.git/worktrees/workspace
```

`project/` is deliberately never mounted into the container, so that path does
not exist there and every git command dies. Mounting `project/` would "fix" it
and destroy the isolation the design exists for — the container would get write
access to the canonical clone's object store and refs.

A clone is the right shape for this boundary. `./sandbox verify` now checks it:

```
✓ /workspace/repo is a clone, not a worktree
```

---

## Podman

### `failed to connect to the docker API at unix:///run/user/…/podman.sock`

Usually seen with a confusing companion line:

```
>>>> Executing external compose provider ".../docker-compose" <<<<
ERRO[0000] Can't add file .../proxy/Dockerfile to tar: io: read/write on closed pipe
failed to connect to the docker API at unix:///run/user/1000/podman/podman.sock
```

Nothing is wrong with the Dockerfile. `podman compose` is a dispatcher that
delegated to the `docker-compose` plugin, and that plugin speaks to the Podman
**API socket** rather than the podman CLI. The socket is not running, the
connection dies, and the client reports it as a tar error.

```bash
systemctl --user enable --now podman.socket
# no user systemd session (containers, minimal images):
podman system service --time=0 "unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock" &
```

Or sidestep the socket entirely by installing the native provider, which drives
the CLI directly:

```bash
sudo dnf install podman-compose        # or apt / pacman / pipx
```

`./sandbox` prefers `podman-compose` when present and starts the socket itself
when it does not have that option. `SANDBOX_COMPOSE` in `.env` pins the choice;
`./sandbox doctor` shows which provider is active and whether the socket is up.
See [11 — Podman](11-podman.md).

### `Error: --userns and --pod cannot be set together`

podman-compose puts every service into one shared **pod**, and a pod owns its
own user namespace — so the per-container `userns_mode: keep-id` the agent
needs cannot also apply. The proxy comes up, then creating the agent container
fails.

The fix is to stop using a pod, which bought nothing here anyway: the isolation
comes from the `internal:` network and the container flags, not from
co-locating services.

```bash
podman-compose --in-pod=false ...
```

`./sandbox` now passes that automatically whenever it drives podman-compose
with keep-id enabled. If your podman-compose predates the flag it warns and
tells you the alternative — set `SANDBOX_USERNS=off` in `.env` (which drops
`docker-compose.podman-userns.yml` from the overlay chain) and repair ownership
afterwards:

```bash
podman unshare chown -R 0:0 workspace     # 0 inside the userns == you outside
```

### `the container name "<name>-egress-proxy" is already in use by <id>`

```
Error: creating container storage: the container name
"agent-sandbox-egress-proxy" is already in use by 74abc3d4. You have to
remove that container to be able to reuse that name ... or use --replace
```

Not two sandboxes fighting over one name (that case is a distinct
`SANDBOX_NAME` per `.env`, see below) — it is a *leftover*: the proxy has a
fixed `container_name`, and an unclean stop (host reboot, podman-compose
killed mid-run, a renamed bundle) leaves the old container registered.
docker compose reconciles an existing container on the next `up`;
podman-compose just tries to create a new one and collides.

`./sandbox up` now checks for this before starting: if the container exists
but is not running, it forwards `--replace` to podman when the installed
podman-compose can carry it, and removes the dead container directly when it
cannot. A proxy that is *running* is left alone. On an older copy of the
bundle, do it by hand:

```bash
podman rm -f <name>-egress-proxy
./sandbox up
```

### `npm WARN EBADENGINE ... required: { node: '>=22.0.0' }`

```
npm WARN EBADENGINE package: '@anthropic-ai/claude-code@2.1.223'
npm WARN EBADENGINE required: { node: '>=22.0.0' }
npm WARN EBADENGINE current:  { node: 'v18.19.1', npm: '9.2.0' }
```

A **warning**, so the build succeeds and the CLI then misbehaves at runtime —
the worst kind of failure. Ubuntu 24.04's `nodejs` package is Node 18.19; the
CLI needs 22+.

The agent image is built `FROM node:22-bookworm-slim` for exactly this reason,
and the build now ends with `node --version` so a wrong version fails the build
instead of shipping. If you are on an older copy of this bundle, rebuild:

```bash
docker compose build --no-cache agent      # or podman-compose build agent
```

Do not reach for a piped NodeSource installer — a sandbox guide should not open
by running an unverified script as root.

### `Error: unknown mount option "uid=1001": invalid mount option`

From the tmpfs mounts in `docker-compose.yml`. Docker accepts `uid=`/`gid=` as
tmpfs options; Podman's `--tmpfs` parser accepts only a subset and rejects them
outright, so the agent container is never created.

The compose file no longer uses them:

```yaml
    tmpfs:
      - /tmp:mode=1777,size=1g
      - /home/agent:mode=0777,size=1g     # not mode=0700,uid=...,gid=...
```

Without an owner the tmpfs belongs to root, so the mode has to be what lets the
agent write to its own `$HOME`. `0777` on a per-container tmpfs that serves one
user and is destroyed on exit is not a meaningful exposure.

If you are on an older copy, edit that one line. Nothing needs rebuilding —
tmpfs options are applied at container creation, not at build.

### Files in `workspace/` owned by `nobody` under Podman

Rootless Podman maps container uid 1000 to a subuid (~100999) unless told
otherwise. `docker-compose.podman.yml` sets `userns_mode: "keep-id"` on the
agent; if your compose provider dropped that key, the mapping is wrong.

```bash
podman unshare chown -R 0:0 workspace     # 0 inside the userns == you outside
```

Verify the fix stuck with the ownership probe in [11 — Podman](11-podman.md).

### `mem_limit` / `cpus` appear to do nothing

Rootless Podman on **cgroups v1** ignores them silently.

```bash
[ -f /sys/fs/cgroup/cgroup.controllers ] && echo "v2 — enforced" || echo "v1 — ignored"
```

`./sandbox doctor` reports this too.

## The host account

### `this account can run sudo WITHOUT a password prompt right now`

`./sandbox` warns because the account you are running it from can become root.
An escape from the container, or a command pasted on the agent's suggestion,
would land somewhere that reaches root — which is most of what the sandbox
exists to prevent. Cloud images make this the default: `ubuntu`, `ec2-user` and
`azureuser` all ship `NOPASSWD:ALL` in `/etc/sudoers.d/`.

Move to a dedicated unprivileged account (step 1 of the
[quickstart](01-quickstart.md)), or accept the risk explicitly:

```
SANDBOX_ALLOW_PRIVILEGED=1
```

One false positive worth knowing: if you ran `sudo` in this shell a few minutes
ago, sudo's timestamp cache makes the check fire even without a `NOPASSWD` rule.
`sudo -k` clears it, then re-run. The definitive check is:

```bash
sudo -l -U "$(id -un)"
sudo grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/
```

### `this account is in the 'docker' group`

Equivalent to root on the host — `docker run -v /:/host` mounts the whole
filesystem. Either use rootless Podman (the default here), or remove the
account from the group and accept that it can no longer drive Docker.

## The agent CLI itself

### `Last update attempt: failed (install_failed)` / "the npm global folder isn't writable"

Expected, and correct. The CLI is installed as root into `/usr/local`, the
rootfs is mounted read-only, and the agent runs unprivileged — so it cannot
rewrite its own binary. That is deliberate: an agent that can replace its own
harness can replace its own permission checks.

Every suggested fix is wrong *here*, even though each is right elsewhere:
a native install, a sudo-free npm via nvm, or `npm config set prefix
~/.npm-global` would all put the CLI somewhere the agent can write — and the
container is discarded on exit anyway, so the update would not survive the
session.

`profile/claude/settings.json` therefore sets `DISABLE_AUTOUPDATER=1`, which
removes a network call that is guaranteed to fail. The image becomes the single
source of truth for the version. Move it forward deliberately:

```bash
./sandbox upgrade          # rebuild without cache, then print the new version
./sandbox upgrade 2.1.223  # pin that version in .env, then rebuild
./sandbox upgrade latest   # drop the pin again
```

The pin lands in `.env` as `AGENT_CLI=@anthropic-ai/claude-code@2.1.223`, which
you can also write by hand — `upgrade` recognizes and preserves it.

### `Remote Control is unavailable` / feature flags not evaluating

A consequence of `DISABLE_TELEMETRY=1` in the profile: feature-flag evaluation
goes through the same telemetry endpoint. Not a fault, a trade.

If you want those features, drop `DISABLE_TELEMETRY` from
`profile/claude/settings.json` and allowlist the endpoint:

```bash
./sandbox allow statsig.anthropic.com
```

Decide that on purpose. Every allowlisted host is another channel out
(see the limits section of the guide) — which is the same reasoning that put
the flag there in the first place.

### `Path: .../bin/claude.exe` on Linux

Cosmetic. That is just the filename the npm package ships its launcher under;
it is a Node script, not a Windows binary, and `Platform: linux-x64` on the line
above confirms the right build is running.

## Credentials

### `install: cannot open '/run/secrets/deploy_key' for reading: Permission denied`

The mount is there and the file exists — `[ -f ]` passes — but the container's
user cannot read it. A `0600` file is readable only by its owning uid, and the
container runs as `HOST_UID` from `.env`. If the key was created by a different
user, or with `sudo`, or `.env` was written under a different account, the uids
do not match.

```bash
ls -la secrets/deploy_key          # owner uid
grep HOST_UID .env                 # what the container runs as
id -u                              # what you are now
sudo chown "$(id -u):$(id -g)" secrets/deploy_key
chmod 600 secrets/deploy_key
```

If `.env` is the stale side, fix it there instead and rebuild:

```bash
sed -i "s/^HOST_UID=.*/HOST_UID=$(id -u)/;s/^HOST_GID=.*/HOST_GID=$(id -g)/" .env
docker compose build --no-cache agent
```

`./sandbox go` now warns about both mismatches before starting, and the
entrypoint prints the fix instead of dying.

### `warning: ANTHROPIC_API_KEY is empty in .env`

Only a warning. Either put a key in `.env`, or log in once and save the session:

```bash
./sandbox login
```

See `06-credentials.md` for what that stores and what it costs you.

---

## Everything else

| Symptom | Cause and fix |
|---|---|
| `permission denied` talking to docker (Linux) | `sudo usermod -aG docker $USER`, then log out and back in. |
| Files in `workspace/` owned by root or nobody | Under Docker this used to mean a stale `HOST_UID` in `.env`; `./sandbox` now takes the ids live from `id(1)` on every run and rewrites `.env` when they differ, so this should self-heal. Under rootless Podman it means `keep-id` did not apply — see the Podman section. |
| `read-only file system` where a tool needs a cache | Add a tmpfs for it: `- /home/agent/.npm:size=512m`. Don't reach for `read_only: false`. |
| `$HOME` not writable inside the container | The tmpfs `uid=`/`gid=` options didn't apply on your Docker version. Use mode `0777`, or `--userns=keep-id` under Podman. |
| `git push` hangs from inside the container | Port 22 is not proxyable. Use the deploy-key setup (docs/06), which routes over 443, or push from the host with `./sandbox push`. |
| Build fails at `npm install -g` | Build-time network is *not* proxied — ordinary connectivity, or a corporate MITM proxy whose CA the image needs. |
| Agent stops running commands mid-session | Hit `pids_limit`. Raise it, and check `tini` is PID 1: `docker compose exec agent ps 1`. |
| Container name conflicts between two projects | Set a distinct `SANDBOX_NAME` in each `.env`. See `09-multiple-projects.md`. |
