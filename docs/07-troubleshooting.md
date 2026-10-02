# 07 — Troubleshooting

Start with:

```bash
./sandbox doctor
```

It prints a green or red line per check and, under each red, the command that
fixes it.

> Nothing on this page comes from a real run yet: the sandbox has not been
> started on Podman. These are the failures the design expects, with their
> causes. [PHASE-B.md](../PHASE-B.md) is where real ones will be recorded.

## `run` refuses to start

| Message | Why | What to do |
|---|---|---|
| `refusing to run as root` | A breakout would land as root. There is no override. | Use an ordinary account. See the [quickstart](01-quickstart.md). |
| `Podman is running as root (rootful)` or `Podman is a remote client` | The containers would not run as your unprivileged user on this machine. | Use rootless Podman locally. Unset `CONTAINER_HOST`. On macOS use the default `podman machine`. |
| `this host uses cgroup v1` | The kernel would ignore the memory, CPU and process limits. | Boot with cgroup v2. Any current distribution does by default. |
| `your user may not set limits for: cpu` | systemd has not handed that controller to your user (older than 252). | The fix doctor prints: a one-line drop-in under `/etc/systemd/system/user@.service.d/`, then log in again. |
| `Podman ... is too old` | 4.4 or newer is needed. Ubuntu 22.04 ships 3.4, Debian 12 ships 4.3. | Use a newer distribution (Ubuntu 24.04, Debian 13, current Fedora), or run the sandbox in a VM (`extras/vm-wrapper/`). |
| `your subordinate uid range does not reach 61003` | Podman maps container users onto a range of ids your account owns; it is too small. | `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER`, then `podman system migrate`. |
| `images/PINS still has UNPINNED base images` | Base images are pinned by exact version, and the placeholders have not been filled in. | `scripts/pin-images.sh` |
| `the session may use up to N of memory and this host has M` | The session's ceiling (your `--mem` plus the memory-backed workspace, `/tmp` and home) is more than the host has free. | Lower `--mem` or `--workspace-size`, or destroy an old session. |
| A barrier check fails at start | `verify` found a barrier that does not hold. The session is stopped. | Read the `fix:` line under the failed check. Do not work around it. |

## Inside a session

**"No space left on device" in the workspace.** The workspace is capped
(4 GB by default) and held in memory. Raise `--workspace-size`, or for a large
repository use the disk store (below).

**Things stop starting; "Resource temporarily unavailable".** The process
limit. Raise `--pids`. If you run several sessions at once they also share the
per-user limit `NPROC` in your settings file; raise that too.

**A download fails with 403.** The proxy refused the host. `./sandbox logs
proxy` names it. If the agent should have it: `./sandbox allow <host> --reason
"..."`. It applies at once. See [02](02-egress.md).

**Name lookups fail (`Could not resolve host`).** Expected for anything that
does not go through the proxy: the agent has no resolver. Tools that honour
`HTTPS_PROXY` are unaffected. A tool that ignores the proxy settings cannot
reach the network at all, by design.

**`git push` fails inside the session.** Also by design: there is no git
credential inside. Use `./sandbox export` and `./sandbox push`, or start the
session with `--git-relay` ([03](03-credentials.md)).

**The agent's CLI says it is not logged in, or model requests fail.**
`./sandbox logs sidecar`. A `503` means the credential was never loaded: run
`./sandbox login` and start again. A `403` with "credential was rejected" means
the vendor refused the token: it was revoked or has expired. A `403` with
"budget" means the session used its `--budget`.

**Chromium will not start.** In the `full` toolchain it must be run with
`--no-sandbox`: its own sandbox needs to create namespaces, which this
container does not allow.

**A build tries to start a container.** Not possible inside. See
[06](06-services.md).

## Time limit

At the deadline everything except the workspace is stopped: the agent's
container is killed, and so are the proxy and the sidecar. The work is still
there. `./sandbox export` works; `./sandbox shell` does not. Start a new
session to carry on.

## Export

**`push` refuses: `SCAN=not-run`.** gitleaks is not installed on the host.
Install it and run `./sandbox export` again.

**`push` refuses: attribution.** A commit names an AI as its author or
committer, which export cannot rewrite. Fix the commit in a new session, or
amend it yourself in the exported repository.

**`push` refuses: the agent rewrote history.** The branch no longer continues
from the commit the session started at, so export had nothing sound to compare
with and printed everything. Read it. If it is what you want, push by hand from
the exported repository.

## The disk-backed workspace

For repositories too large for memory:

```bash
./sandbox run <repo> --workspace-driver local --workspace-size 20g
```

It needs a **store**: a filesystem of fixed size that you create once, as root.
Without `STORE` in your settings file the option is refused. Set `STORE` to
the path the store will have, and `doctor` prints the commands to make it. The store's size is the hard limit, shared by
all sessions that use it; `--workspace-size` is watched from the host and ends
the session when it is passed. Unlike the default, the data is on your disk
until `destroy`.

`--io-limit` (bytes per second written) works only with the store, and only if
your user may set I/O limits; `doctor` checks.

## macOS

Podman on a Mac runs its containers inside a small Linux VM (`podman machine`).
That is a second kernel between the agent and your Mac, which is good. The
memory checks apply to the VM: give it enough with `podman machine set
--memory`.

## Cleaning up after a crash or a reboot

```bash
./sandbox destroy --all
```

removes everything carrying a session's label, and the session directories.
After a reboot the memory-backed workspaces are already gone.
