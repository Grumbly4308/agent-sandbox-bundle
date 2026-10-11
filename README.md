# agent-sandbox

Run an AI coding agent (Claude Code, Codex, OpenCode) on a repository of yours
inside a container that has none of your credentials, no route to the internet
except a short allowlist, and no way to touch your files.

It assumes the agent is hostile from the first second, because a sentence
hidden in a README or a web page can make it so, and asks what it can then
reach. The answer: one throwaway container, one copy of one repository, a
number of model requests you chose, and a short list of hosts.

> **Status: 2.0.0, verified on one real host.** Every barrier in the register
> was attempted and held on Debian 13 with rootless Podman 5.4.2, against the
> real vendors for Claude Code and Codex with subscriptions.
> [08 — Verification](docs/08-verification.md) says exactly what was proven,
> what was closed without a check, and what is still unproven (other hosts,
> above all).

## In one screen

```bash
./sandbox doctor                         # is this host safe to run on?
scripts/pin-images.sh                    # first time: pin the base images
./sandbox login                          # first time: store the model credential
./sandbox run https://github.com/you/project.git
./sandbox resume                         # back into the same session, any time later
./sandbox export                         # bring the work out and read it
./sandbox push                           # with your credentials, from a clean copy
./sandbox destroy
```

A session stays until you `destroy` it: through the agent exiting, through a
reboot (with the disk store), and with no time limit unless you set one with
`--ttl`. `resume` puts you back in. [09 — Sessions](docs/09-sessions.md) has
the details.

You need rootless Podman, git and bash, on Linux or macOS, and an account that
cannot become root.

## What the host holds

The container holds no credential of yours. The host account that runs it is
another matter: a kernel-bug breakout lands there and takes what it finds, so
the less that account holds, the less a breakout is worth.

- **The model token** is a one-year, inference-only token on an account you
  dedicate to sandboxes. Stored in the OS keyring, or typed at each `run`.
- **A git credential** is needed only for a private repository, and only on
  the host. Do not put a personal SSH key or a broad token there. Either clone
  on your workstation and send the code over SSH (`run` takes a path), or give
  `run --git-token` a token for that one repository, held in memory for the
  session and forgotten at `destroy`.

```bash
./sandbox run https://github.com/you/private.git --git-token
```

[03 — Credentials](docs/03-credentials.md#git-credentials) weighs the choices;
the [quickstart](docs/01-quickstart.md#15-decide-how-the-work-gets-back-to-github) shows both.

## More than one repository, more than one agent

A session holds **one repository and one agent**, on purpose: that is what
keeps a hostile agent in one repository away from the others. Everything
else follows from making more sessions:

- **One repository after another:** `export`, `destroy`, `run` the next one.
  The stored model credentials and the built images are reused; nothing else
  carries over.
- **Several at once:** one `run` each. Other commands then take
  `SANDBOX_SESSION=<name>` to say which session they mean.
- **Another agent on the same repository:** `run` it again with
  `--agent codex` (or `claude`). To have it carry on from the first agent's
  work, bring that work out first and name its branch with `--branch`:
  - **A, through the remote:** `export` and `push` the first session, then
    `run <repo-url> --agent codex --branch agent/<first session>`;
  - **B, straight from the export, nothing pushed:** `export` the first
    session, then
    `run ~/agent-sandbox-out/<first session>/repo.git --agent codex --branch agent/<first session>`.

[09 — Sessions](docs/09-sessions.md) has all of it, with what sessions side
by side share and how to push the result of B.

## Read these

| | |
|---|---|
| [00 — Threat model](docs/00-threat-model.md) | What this protects, what it does not, and every barrier with its test. **Start here.** |
| [01 — Quickstart](docs/01-quickstart.md) | From a brand-new Debian, Ubuntu or Fedora VM to a running agent, every command written out |
| [02 — Egress](docs/02-egress.md) | The proxy and the allowlist |
| [03 — Credentials](docs/03-credentials.md) | Why the agent never holds your login |
| [04 — Monitoring](docs/04-monitoring.md) | Logs, and what they can and cannot tell you |
| [05 — Agents and toolchains](docs/05-agents-and-toolchains.md) | Agent plug-ins, `--auto`, what is in the image |
| [06 — Services](docs/06-services.md) | A database beside the agent |
| [07 — Troubleshooting](docs/07-troubleshooting.md) | When it refuses, and why |
| [08 — Verification](docs/08-verification.md) | What the real run proved, what it fixed, and what is still unproven |
| [09 — Sessions](docs/09-sessions.md) | Several repositories, several agents, and handing work from one agent to another |
| [CHANGELOG](CHANGELOG.md) | What changed from version 1, finding by finding |
| [docs/archive/phase-b](docs/archive/phase-b/README.md) | The first run on a real host: plan, cards, results, logs |

## How it is laid out

```
sandbox                  the launcher: one bash file
topology.sh              every flag each container, network and volume is created with
seccomp/                 the system-call filter (generated by scripts/make-seccomp.sh)
images/agent/            the agent's image and the few scripts inside it
images/proxy/            the egress proxy (Squid)
images/credsidecar/      holds the model credential so the agent never does
images/gitrelay/         optional: lets the agent push one branch without holding a token
agents/<name>/           one directory per agent: installer, launcher, allowlist, notes
services/<name>/         databases and caches you can start beside the agent
policy/                  the default allowlist, the never-allow list, export rules
scripts/                 doctor, verify, export, allowlist handling
extras/                  optional host-side auditing; running it all in a VM
docs/                    these pages; docs/archive/ holds the record of the real run
tests/                   everything that can be tested without a container runtime
tests/phase-b/           the two scripts that need a real Podman: images, and the full cycle
```

## Tests

```bash
make test
```

runs every test that needs no container runtime. It proves what the code asks
Podman for and how the host-side parts behave. It does not prove Podman does
it: that is `./sandbox verify` on a real host, which
[08 — Verification](docs/08-verification.md) records.
