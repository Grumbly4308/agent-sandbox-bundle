# Test card, section F by hand: subscription logins

> **Archived.** Followed on 2026-10-10; the F rows are filled in in
> [results.md](results.md).

Steps F0 to F2 of [test-card.md](test-card.md), written out for doing them
yourself on this host. Each step says what to type, what you should see,
and what to write down. Keep the log of each step in `~/phase-b-logs/`, as
in the rest of the card.

**What you need**

- A dedicated Claude Pro or Max account and a dedicated ChatGPT account
  that includes Codex. Overage billing (extra usage) switched **off** on
  both, so the plan's allowance is the most an agent can spend.
- A machine with a browser (your laptop), with Claude Code and the Codex CLI
  installed on it. Tokens are made there and pasted or copied to the host.
- Admin (`sudo`) access on the host for one package in F0.
- Everything else from sections B and C is already done on this host:
  `~/mini-node` exists, `./sandbox doctor` says the host is ready, and the
  images are built.

Open a **new terminal** on the host as `sandboxer`, and make sure
`SANDBOX_TEST_ANTHROPIC_KEY` is not set in it:

```bash
unset SANDBOX_TEST_ANTHROPIC_KEY
cd ~/agent-sandbox
```

---

## F0. A working keyring

`./sandbox login` keeps the credential in the OS keyring through
`secret-tool`. This host is reached over SSH and has no keyring running:
the probe below was run during the automated pass and failed with

```
secret-tool: The name org.freedesktop.secrets was not provided by any .service files
```

(see `~/phase-b-logs/F0.log`). Start one by hand. This recipe is from the
card and has not been tried by the authors; if it fails, see "Without a
keyring" at the end of this step.

**1. As an admin**, install gnome-keyring (the only package needed):

```bash
sudo apt install -y gnome-keyring
```

**2. As `sandboxer`, in the terminal you will use for F1 and F2**, start and
unlock a keyring. The session D-Bus it registers on is already running for
this account (`systemctl --user is-active dbus` prints `active`).

```bash
printf '%s' 'a passphrase of your choice' | gnome-keyring-daemon --unlock --components=secrets
```

It prints a few `VAR=value` lines. If one of them is
`GNOME_KEYRING_CONTROL=...`, export it in this terminal:

```bash
export GNOME_KEYRING_CONTROL=/run/user/1002/keyring     # whatever it printed
```

**3. Probe it**, exactly as the card does:

```bash
( set -ex
  printf 'probe' | secret-tool store --label "probe" service agent-sandbox-probe agent probe
  secret-tool lookup service agent-sandbox-probe agent probe      # must print: probe
  secret-tool clear  service agent-sandbox-probe agent probe
) 2>&1 | tee ~/phase-b-logs/F0-2.log
echo "exit: ${PIPESTATUS[0]}"
```

**Good:** the lookup prints `probe` and `exit: 0`.

**Without a keyring:** you can still do F1. `./sandbox run` asks for the
token and uses it for that session only. A later `./sandbox verify` then
reports `B15-token-absent` as a `SKIP` that counts as a failure, because it
has nothing to search for; the same check already ran with the token at
`run --strict`. **F2 (Codex) needs the keyring**: `run` refuses with
`no Codex login in your keyring` otherwise.

☐ pass ☐ fail ☐ no keyring on this host

---

## F1. Claude Code with a Pro or Max subscription

**1. On your laptop**, signed in to Claude Code with the dedicated account:

```bash
claude setup-token
```

It opens the browser, you approve, and it prints a token. The token is
valid for one year and can make model requests and nothing else. Copy it.

**2. On the host**, store it:

```bash
./sandbox login
```

It says to run `claude setup-token`, then asks `Paste that token:`. Paste it
and press Enter (nothing is echoed). It answers with where it stored the
token and three things to read: use a dedicated account, switch overage
billing off, and how to revoke:

> sign in to claude.ai as that account, open Settings, then Claude Code,
> and revoke the token. Then delete the stored copy:
> `secret-tool clear service agent-sandbox agent claude auth oauth`

If it says `the keyring did not take the credential`, F0 is not done.

**3. Start a session:**

```bash
./sandbox run ~/mini-node --strict
```

**Good**, in order: the memory line, `Its workspace is on disk: up to 4g of
the store at /var/lib/agent-sandbox-store.`, `creating session
asb-mini-node-xxxxxx`, the barrier checks (72 `PASS`, 0 `FAIL`),
`Session ... runs until ...`, then Claude Code with **no login prompt**.
Ask it:

> Add a small function called double to index.js and commit it.

It answers, edits and commits. Then leave it with `/exit`. The session
stays.

**4. Verify, export, destroy:**

```bash
( set -ex
  ./sandbox verify
  ./sandbox export && ./sandbox destroy
) 2>&1 | tee ~/phase-b-logs/F1.log
echo "exit: ${PIPESTATUS[0]}"
```

**Good:**

- `verify` ends with `0 failed` and exits 0. Look for the line
  `PASS B15-token-absent`: the real token was searched for in the agent
  container and not found. (Without a keyring it is a `SKIP` that counts as
  a failure; write that down rather than a fail.)
- `export` lists the agent's commit under `Commits (1)`, the diff, and a
  `RUNS LATER` section; `secret scan: passed` (gitleaks 8.30.1 is installed
  for this user at `~/.local/bin/gitleaks`).
- `git --git-dir ~/agent-sandbox-out/<session>/repo.git log --oneline --all`
  shows the agent's commit, with no `Co-Authored-By` or "Generated with"
  line in its message.

**5. When you are done with Claude for good:** revoke the token on
claude.ai as `login` described, then

```bash
secret-tool clear service agent-sandbox agent claude auth oauth
```

☐ pass ☐ fail

---

## F2. Codex with a ChatGPT login

Codex has no long-lived, inference-only token. Its login is a pair: a
short-lived access token and a refresh token. `login` stores the pair in
the keyring; at `run` only the access token goes into the sidecar, and the
host renews it when it has under ten minutes left.

**1. On your laptop**, with the Codex CLI:

```bash
codex login
```

Sign in as the dedicated ChatGPT account in the browser. It writes
`~/.codex/auth.json`.

**2. Copy that file to the host**, somewhere only you can read:

```bash
scp ~/.codex/auth.json sandboxer@<host>:/home/sandboxer/codex-auth.json
```

**3. On the host**, store it:

```bash
./sandbox login --agent codex
```

It asks `Path to that file [/home/sandboxer/.codex/auth.json]:`. Type
`/home/sandboxer/codex-auth.json` and press Enter. It reads the file,
stores the login whole in the keyring, and prints the three things to read.
How to revoke:

> sign in to chatgpt.com as that account, open Settings, then Security,
> and log out of all devices. Then delete the stored copy:
> `secret-tool clear service agent-sandbox agent codex auth oauth`

If it says `... is not a Codex auth.json` or `has no subscription login in
it`, the file came from an API-key login, not `codex login`.

Then remove the copy on the host; the keyring has it now:

```bash
shred -u ~/codex-auth.json
```

**4. Start a session:**

```bash
./sandbox run ~/mini-node --agent codex --strict
```

**Good:** the same start-up as F1, then Codex with **no login prompt**. Ask
it the same thing as in F1. It answers, edits and commits. Leave Codex.

**5. Verify and destroy:**

```bash
( set -ex
  ./sandbox verify && ./sandbox destroy
) 2>&1 | tee ~/phase-b-logs/F2.log
echo "exit: ${PIPESTATUS[0]}"
```

**Good:** `verify` ends with `0 failed`, with `PASS B15-token-absent`.

**6. The renewal, later.** One thing a single sitting cannot show: the host
renews the access token only when it has under ten minutes left, roughly
ten days after `codex login`. Start a Codex session then:

```bash
./sandbox run ~/mini-node --agent codex --strict
```

It must start without asking you to sign in, and so must the one after it.
Until then, record the renewal as not run.

**7. When you are done with Codex for good:** log out of all devices on
chatgpt.com as `login` described, then

```bash
secret-tool clear service agent-sandbox agent codex auth oauth
```

☐ pass ☐ fail ☐ renewal not run

---

## F3. OpenCode with an API key

Not done: it needs an Anthropic API key, which this run does not have.

---

## Afterwards

```bash
( set -ex
  ./sandbox destroy --all
  podman ps -a; podman volume ls; podman network ls        # nothing starting asb-
) 2>&1 | tee ~/phase-b-logs/H-2.log
echo "exit: ${PIPESTATUS[0]}"
```

Then fill in the F rows of the table in
[results.md](results.md).

## If something refuses

| What you see | What it means |
|---|---|
| `secret-tool: The name org.freedesktop.secrets was not provided` | No keyring on the D-Bus of this terminal: F0 step 2 again, in this terminal. |
| `the keyring did not take the credential (is it unlocked?)` | The same, or the keyring is locked: run the `gnome-keyring-daemon --unlock` line again. |
| `that does not look like a token` | The paste was incomplete or had a newline in it. Paste again. |
| `no Codex login in your keyring` | F2 step 3 was not done in a terminal with the keyring. |
| Claude Code or Codex shows a login prompt | The credential did not reach the sidecar: `./sandbox logs sidecar`. |
| `403 the model vendor rejected the sandbox's credential` | The vendor answered 401: the token was revoked, or the account has no access. Make a new token and `./sandbox login` again. |
