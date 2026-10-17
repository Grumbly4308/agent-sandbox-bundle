# 03 — Credentials

The best-protected secret is one that was never in the container. Nothing that
can log in as you is ever inside the agent's container: no model login, no git
token, no SSH key (barrier B15 in the [threat model](00-threat-model.md)).

## How the agent talks to the model without holding the login

```
agent  ──dummy token──►  credential sidecar  ──real token──►  proxy  ──►  vendor
```

- The agent's CLI is given a **dummy** token and a base URL that points at the
  sidecar.
- The **sidecar** is a separate container. It throws the dummy away, puts the
  real token on the request, and sends it to exactly one place: the vendor's
  API, through the proxy (barrier B22).
- The agent cannot reach the vendor itself. The proxy allows the vendor's hosts
  from the sidecar's address only (B21).

The sidecar also:

- forwards only the API paths the CLI uses, and refuses request features that
  would make the vendor's servers fetch a URL or connect to an MCP server on
  the agent's behalf (B23). Web search is let through;
- counts model requests and stops at `--budget` (B24). This is a count, not a
  spend limit;
- logs every request, including web search queries (B25);
- never answers "unauthorised" to the agent, because the CLIs react to that by
  trying to refresh a login they do not have.

The real token reaches the sidecar on standard input when a session starts. It
is never in an environment variable, a command line, a file on your disk or the
session directory, and it is gone when the container is.

For Codex with a subscription the agent talks to the sidecar in HTTPS, because
Codex refuses a ChatGPT backend that is not. `run` makes a new key and a
certificate for the sidecar's address at every start, with `openssl` on your
host, and pipes both in the same way. The key exists only in that pipe and in
the sidecar's memory. The agent is given the certificate alone, and is told to
trust it (`CODEX_CA_CERTIFICATE`); the session directory keeps a copy for
`shell` and `verify`. Every other agent's sidecar is plain HTTP, on the
session's internal network.

> **Proven against the real vendors on 2026-10-10** for Claude Code with a
> subscription (F1) and Codex with a subscription (F2): both started with a
> dummy credential and answered through the sidecar. The API-key paths
> (Claude, Codex, OpenCode) have run against a mock only and were closed
> without a check; see [08 — Verification](08-verification.md).

## Which credential, for which agent

| Agent | `--auth oauth` (subscription) | `--auth apikey` |
|---|---|---|
| Claude Code | A one-year token limited to model requests, from `claude setup-token` | An API key |
| Codex | Your ChatGPT login; only short-lived access tokens reach the sidecar | An API key |
| OpenCode | **Not available.** OpenCode cannot legitimately use a Claude or ChatGPT subscription login | An API key |

Each agent's `agents/<name>/auth.md` has the details.

### Claude Code with a subscription

```bash
claude setup-token        # on any machine where you are signed in with the sandbox account
./sandbox login           # paste the token it printed
```

The token is valid for a year and can do one thing: make model requests. There
is nothing to refresh, so a session cannot lose its login half-way through, and
several sessions can share it.

### Codex with a ChatGPT plan

```bash
codex login               # on the host, with the sandbox account
./sandbox login --agent codex
```

A ChatGPT login is a pair: an access token that lasts about ten days and a
refresh token that can be used once to get the next pair. The refresh token
**never enters a container**. A small background process on your host renews
the pair before it runs out, writes the new one to your keyring, and pipes
only the new access token to the sidecar. It takes a lock first, so two
sessions never spend the same refresh token.

This path is the least proven part of the design: the renewal request has not
yet been made against the real service.

### An API key

```bash
./sandbox login --agent claude --auth apikey
```

Use a key from a **dedicated workspace with a spend cap**. With an API key the
request budget limits how many requests are made, not what they cost.

## Three things to do with the account

`./sandbox login` prints these every time, because they matter more than the
mechanism:

1. **Use a dedicated account for sandboxes.** A subscription login is a login
   to the whole account.
2. **Switch off extra usage** (overage billing) on it. Then the most an agent
   can spend is the plan you already paid for.
3. **Know how to revoke it.** The command prints the steps for the credential
   you just stored.

## Where the credential rests

In your OS keyring: `secret-tool` on Linux, the Keychain on macOS. Not in this
repository, not in a file the tool wrote. `./sandbox doctor` warns if no
keyring tool is installed, or if the keyring is missing or locked; in any of
those cases you are asked for the credential at each `run`.

On Linux the keyring is created and unlocked by your desktop login. The
headless account the quickstart recommends has no desktop, so it starts with no
keyring and no way to make one: gnome-keyring does both through a graphical
prompt. `scripts/keyring-unlock.py` does it over D-Bus instead, with a
password you choose. The keyring then stays open until the daemon stops (a
reboot). After that, `run`, `resume` and `login` find it locked and run the
script for you at the terminal: you type the keyring's password, and they go
on. Without a terminal (a script piping the credential in) nothing is asked
and `run` reads the credential from standard input as before.

Be clear about what the keyring buys. It keeps the token out of files,
environments, command lines and shell history, and encrypted at rest (a VM
snapshot or a copied disk image gets nothing). It is **not** a barrier against
a breakout: the daemon runs as your user, unlocked, because `run` needs it;
and at `run` the token is in the launcher's memory and in the sidecar
container regardless. What limits the damage there is the token itself, which
can only make model requests, on an account you chose for the purpose. On a
headless host where the per-boot unlock is a nuisance, skipping the keyring
and typing the token at each `run` is an equally sound choice, not a
degraded one; `login` is then simply not used.

A keyring is only as safe as the account it belongs to. That is one more reason
for the ordinary, no-`sudo` account in the [quickstart](01-quickstart.md).

## Git credentials

None inside. Your repository is cloned on the host and handed to the sandbox
as a file; the work comes back out the same way, and `./sandbox push` pushes
it from the host. See
[How code gets in and out](00-threat-model.md#how-code-gets-in-and-out).

That keeps the git credential from the agent. It does not keep it from a
kernel-bug breakout, which lands in the account that runs the sandbox and finds
whatever that account holds (the [prerequisite](00-threat-model.md#the-prerequisite-that-voids-everything-else)).
Weigh what it would find. The model token is a one-year, inference-only token
on a dedicated account: a breakout costs you the rest of a plan and a revoke.
A personal SSH key or a classic token on the same host can read and push
**every repository you have access to, for as long as it lives**. That is the
larger asset by far, and the architecture gains nothing from isolating the
small one if the large one sits in `~/.ssh`.

So: **never put a personal SSH key or a broad token on the host that runs
sandboxes.** The choices, from strongest to weakest:

| | Scope | Lifetime | A breakout gets | Cost |
|---|---|---|---|---|
| **No git credential on the host.** Clone on your workstation, send the code over the SSH link you already have, `run` it from the path, pull the exported branch back and push from the workstation. | none | — | nothing | `push` and `pr` are done from the workstation |
| **`run --git-token`.** A token for one repository with a short expiry, typed at `run`, held in memory, gone at `destroy`. | one repository | the session | one repository, for the session | a token per session or per day |
| **A read-only deploy token** (GitLab) on the one repository, used to clone on the host; `run` from the path. | one repository, read | until you revoke it | one repository, to read | `push` and `pr` are done from the workstation |
| **A deploy key** on the one repository, in `~/.ssh` of the sandbox host. | one repository | until you rotate it | one repository | one setup per repository |
| A personal key, a classic token, `gh auth login` with its default scopes. | everything | years | everything | none, which is the problem |

The first three are described in the [quickstart](01-quickstart.md#15-decide-how-the-work-gets-back-to-github).
For the second, a GitHub fine-grained token with *Contents: read and write* on
the one repository (and *Pull requests: read and write* if `pr` is to open
one) and the shortest expiry the form allows is right; on GitLab, a project
access token with `read_repository` and `write_repository`, which the
launcher presents under the user name `oauth2`. A GitLab deploy token is not
accepted that way (it has a user name of its own, and cannot push), which is
why it gets the third row: it clones, and nothing more. Short expiry is the
control; `destroy` forgetting the token is hygiene. If the agent got out
during the session, the token was already exposed, and only the server
refusing it afterwards limits the damage.

Whatever the credential, it never goes into a repository address. `run`
refuses an `https://user:token@host/...` address, given directly or found in
a path's `origin`, because the address is recorded with the session, printed,
and handed to `export`. Git's credential helpers exist for this.

The order of trust is workstation to sandbox host, never back. The host has
your key in `authorized_keys`; it holds no key to the workstation. **Do not
forward your SSH agent** (`ssh -A`) into the sandbox host: that puts your
workstation's key within reach of everything running as your user there.

### If the agent has to push by itself

```bash
./sandbox run https://github.com/you/project.git --git-relay
```

This starts one more container, the git relay, which holds a git token you type
in for that session (barrier B30). It lets a push through only to the session's
branch on the one repository the session came from: no other branch, no tags,
no deletes.

Know what you give up:

- What the agent pushes this way **does not go through `export`**. No
  attribution strip, no RUNS LATER section, no secret scan.
- The relay cannot tell a rewrite of history from an ordinary push. Protect the
  branch against force-pushes on the git host.
- Use a token that can push to that one repository and nothing else, with a
  short expiry.

Next: [04 — Monitoring](04-monitoring.md).
