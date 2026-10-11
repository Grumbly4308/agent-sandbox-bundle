# 07 — Troubleshooting

Start with:

```bash
./sandbox doctor
```

It prints a green or red line per check and, under each red, the command that
fixes it.

> The failures the first real run met, with their causes and fixes, are in
> [docs/archive/phase-b/results.md](archive/phase-b/results.md). The rest of
> this page is what the design expects.

## `login` will not store the credential

| Message | Why | What to do |
|---|---|---|
| `your account has no keyring` | On Linux the keyring is made by your desktop login. An account reached over SSH with no password never had one, and gnome-keyring can only create one through a graphical prompt. | `scripts/keyring-unlock.py` creates it over D-Bus with a password you choose. `gnome-keyring-daemon --unlock` does not help: on the systemd-managed daemon (gnome-keyring 48) it returns 0 and changes nothing. |
| `your keyring is locked` | It is locked after every reboot, and nothing without a display can prompt you to unlock it. | At a terminal, `run`, `resume` and `login` ask `Keyring password:` themselves and go on once it is open; this message means that was not possible (no terminal, three wrong passwords) or the state was found by `doctor`. By hand: `scripts/keyring-unlock.py`. Or skip it: `run` asks for the credential when the keyring will not answer. |
| `that is not the keyring's password` (from the script) | The keyring was made earlier, by PAM at a password login or by an earlier attempt, with another password. | If nothing in it matters: `rm ~/.local/share/keyrings/login.keyring && systemctl --user restart gnome-keyring-daemon`, then run the script again to make a new one. |
| `secret-tool: Cannot create an item in a locked collection` | The same two causes, reported by `secret-tool` itself on a version of `./sandbox` before this check existed, or when `busctl` is not installed and the state could not be read. | As above. `./sandbox doctor` says which it is when it can. |

## `run` refuses to start

| Message | Why | What to do |
|---|---|---|
| `refusing to run as root` | A breakout would land as root. There is no override. | Use an ordinary account. See the [quickstart](01-quickstart.md). |
| `Podman is running as root (rootful)` or `Podman is a remote client` | The containers would not run as your unprivileged user on this machine. | Use rootless Podman locally. Unset `CONTAINER_HOST`. On macOS use the default `podman machine`. |
| `this host uses cgroup v1` | The kernel would ignore the memory, CPU and process limits. | Boot with cgroup v2. Any current distribution does by default. |
| `your user may not set limits for: cpu` | systemd has not handed that controller to your user (older than 252). | The fix doctor prints: a one-line drop-in under `/etc/systemd/system/user@.service.d/`, then log in again. |
| `Podman ... is too old` | 4.4 or newer is needed. Ubuntu 22.04 ships 3.4, Debian 12 ships 4.3. | Use a newer distribution (Ubuntu 24.04, Debian 13, current Fedora), or run the sandbox in a VM (`extras/vm-wrapper/`). |
| `--git-token is for pushing to an https:// repository` | The token is for where `push` sends the work: the address you gave, or a path's `origin`. A token is presented over HTTPS only; an `ssh` address uses a key, which is the thing `--git-token` exists to avoid, and a path with no `origin` has nowhere to push. | Give the `https://` address of the repository. For a path (such as an earlier session's export), give it an `https://` origin first: `git -C <path> remote add origin https://...`. |
| `could not clone https://...` with `--git-token` | The token cannot read that repository, or has expired. | Make a fine-grained token with *Contents* read access on that repository, and check its expiry. |
| `push` says `the session's token is gone` and git asks for a password | The cache forgets the token at the session's time limit, and a reboot ends the cache. | Type the token at git's prompt (user name `x-access-token`), or push from your workstation after pulling the exported branch. |
| `your subordinate uid range does not reach 61003` | Podman maps container users onto a range of ids your account owns; it is too small. | `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER`, then `podman system migrate`. |
| `images/PINS still has UNPINNED base images` | Base images are pinned by exact version, and the placeholders have not been filled in. | `scripts/pin-images.sh` |
| `the session may use up to N of memory and this host has M` | The session's ceiling (your `--mem` plus `/tmp` and home, plus the workspace if it is held in memory) is more than the host has free. A session that is already running holds its share, so a second `run` on a small host often hits this. | To get back into a session you already have, `./sandbox resume` instead of `run`: it takes no new memory. Otherwise make the disk store if you have none (`./sandbox doctor` prints how), lower `--mem`, or destroy a session you no longer need. |
| `there is more than one session. Set SANDBOX_SESSION to one of:` | Every command but `run` works on one session, and there are several. | Put the one you mean in front: `SANDBOX_SESSION=asb-... ./sandbox export`. See [09 — Sessions](09-sessions.md#several-sessions-side-by-side). |
| `there is no session` | The session was destroyed; or it was started by 2.0.0, whose records a reboot emptied. | `./sandbox run` a new one. An export from the old one is still in `~/agent-sandbox-out/`; its workspace may still be on the store ([getting back into a session](#getting-back-into-a-session)). |
| `the repository's HEAD points at no commit, but it has branches: ...` | A bare repository you pushed to (option 2 in the quickstart) was made with a different first branch than the one you pushed. | Point HEAD at your branch with the `git ... symbolic-ref` command the message prints, then `run` again. (`--branch <that branch>` also starts, but then the agent works on that branch itself rather than on a branch of its own.) |
| A barrier check fails at start | `verify` found a barrier that does not hold. The session is stopped. | Read the `fix:` line under the failed check. Do not work around it. |

## Inside a session

**"No space left on device" in the workspace.** On the disk store this means
the store itself is full: destroy sessions you no longer need, or make a
bigger store. Held in memory, the workspace is capped at `--workspace-size`
(4 GB by default): raise it, or make the disk store (below).

**The session stopped by itself: "its workspace grew past --workspace-size".**
On the disk store each session has a share, 4 GB by default. The work is still
there: `./sandbox export`. Start the next session with a larger
`--workspace-size`, or raise `WORKSPACE_SIZE` in your settings.

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

## Getting back into a session

`./sandbox resume` is the answer to "the agent exited", "the time limit
passed", "the host rebooted" and "I closed the terminal". It starts whatever
of the session is stopped (in the same order `run` did), hands the sidecar
the credential again, and attaches you to the agent in the same workspace.
Nothing is created and no memory check is repeated: the containers are the
ones `run` made. With more than one session, `SANDBOX_SESSION=<name>` picks
one, as for every other command.

What `resume` cannot bring back is what lived only in memory: the agent's
home directory (its conversation and caches), `/tmp`, and a sibling
service's data. These are gone once a container is stopped, by a time limit,
a reboot, or the agent ending its own container. The files in the workspace
are what survives, so ask the agent to put anything you want to keep (a
review, a plan, notes) into a file in the repository, and to commit it.

`resume` refuses when:

| Message | Why | What to do |
|---|---|---|
| `held its workspace in memory, and this host has rebooted since` | There was no disk store, so the workspace was in memory, and a reboot emptied it. | Nothing to recover. `./sandbox destroy`, make the disk store, `run` again. |
| `container ... is gone; the session cannot be resumed` | Something removed a container of the session (`podman rm`, `podman system reset`). | `./sandbox export` what is left, then `destroy`. |
| `there is no session` after a reboot | The session was started by 2.0.0, which kept its records under `/run/user`, emptied at every reboot. | Its workspace is still on the store. Read it as your own user: `podman unshare ls /var/lib/agent-sandbox-store/<session>/repo`, and copy out what you need with `podman unshare cp -r ... ~/rescued`. Then `./sandbox destroy --all` removes what Podman still holds. |

## Time limit

There is none unless you give one: `--ttl 2h` at `run`, or `TTL=2h` in your
settings file. At the deadline everything except the workspace is stopped:
the agent's container is killed, and so are the proxy and the sidecar. The
work is still there. `./sandbox export` works; `./sandbox shell` does not;
`./sandbox resume` starts the session again, with a fresh deadline of the
same length.

## Export

**The export has none of the agent's work in it**, or `export` prints
`N uncommitted change(s) in the workspace are NOT in this bundle`. Only
commits leave a session; files the agent wrote but did not commit stay in the
workspace. Either ask the agent to commit (`./sandbox resume`, then "commit
it"), or let export do it: `./sandbox export --commit` commits everything
uncommitted in the workspace as one commit, "Uncommitted work at export",
under your git identity, and then exports as usual. The agent container has
to be running for that (`resume` if it is not).

**Export did not change the repository I started from.** It is not meant
to: `export` writes a reviewed copy to `~/agent-sandbox-out/<session>/repo.git`
and nothing else. `./sandbox push` is what sends the branch to the address
`run` was given (or a path's `origin`); `export`'s last lines say where.

**`push` refuses: `SCAN=not-run`.** gitleaks is not installed on the host.
Install it and run `./sandbox export` again.

**`push` refuses: attribution.** A commit names an AI as its author or
committer, which export cannot rewrite. Fix the commit in a new session, or
amend it yourself in the exported repository.

**`push` refuses: the agent rewrote history.** The branch no longer continues
from the commit the session started at, so export had nothing sound to compare
with and printed everything. Read it. If it is what you want, push by hand from
the exported repository.

## The disk store

Workspaces are kept on the **disk store** when the host has one: a filesystem
of fixed size that an admin creates once. `./sandbox doctor` prints the
commands when there is none, and [01 — Quickstart](01-quickstart.md) has them
too. A store at `/var/lib/agent-sandbox-store` is found by itself; one
anywhere else is named with `STORE=` in your settings file.

- The store's size is the hard limit, shared by all sessions.
- `--workspace-size` is one session's share. It is watched from the host every
  30 seconds, and the session is stopped when it is passed.
- The files stay on the store, across a reboot too, until `destroy`.
- After a reboot the store must be mounted again; the line in `/etc/fstab`
  does that. If it is not, `run` refuses: "an ordinary directory, not a
  filesystem of its own".

Without a store, or with `--workspace-driver memory`, the workspace is held in
memory: nothing touches the disk and it is gone at a reboot, but it has to fit
in the memory the host can spare.

`--io-limit` (bytes per second written) works only with the store, and only if
your user may set I/O limits; `doctor` checks.

## macOS

Podman on a Mac runs its containers inside a small Linux VM (`podman machine`).
That is a second kernel between the agent and your Mac, which is good. There is
no disk store on a Mac yet, so workspaces are held in memory, and the memory
checks apply to the VM: one default session needs about 11 GB, so give the VM
that with `podman machine set --memory 12288`, or lower `MEM` and
`WORKSPACE_SIZE` in your settings.

## Cleaning up after a crash or a reboot

A reboot does not end a session: `./sandbox resume` carries on with one
whose workspace is on the disk store ([above](#getting-back-into-a-session)).
To remove sessions instead:

```bash
./sandbox destroy --all
```

removes everything carrying a session's label, and the session directories.
After a reboot memory-backed workspaces are already gone; those on the disk
store are still there until this command removes them.
