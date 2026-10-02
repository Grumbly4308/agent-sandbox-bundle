# Codex CLI: credentials

Two modes are legitimate for Codex. In both, the real credential is kept in
your operating system's keyring between sessions and never enters the agent
container `[physical B15, logical B22]`. The agent only ever holds
placeholders with the word `dummy` in them.

## `--auth oauth` (default): a ChatGPT subscription

For a ChatGPT plan that includes Codex. Codex CLI is the vendor's own
client, so using a subscription with it is what the subscription is for.

Unlike Claude, there is no long-lived, inference-only token to ask for. A
ChatGPT login is a pair: a short-lived access token and a long-lived refresh
token that can mint more. So the two are kept apart:

1. Sign in once on your host with the Codex CLI (`codex login`). It writes
   `~/.codex/auth.json`.
2. `./sandbox login --agent codex --auth oauth` reads that file and stores
   the login, whole, in the keyring.
3. At `run`, the host takes the **access token** and the account id out of
   the stored login and pipes only those into the credential sidecar. Before
   the access token runs out, the host renews it (the refresh happens **on
   your host**, never in a container), stores the renewed login back in the
   keyring, and pipes the next access token in.

The refresh token never reaches any container. What the sidecar holds is
good for model requests for a short time and for nothing after that.

## `--auth apikey`: an OpenAI API key

For pay-as-you-go use. Create the key in the OpenAI platform console in a
**project made for this purpose, with a spend limit (budget) set on it**.
`login` asks for the key and stores it in the keyring.

## Limit what a mistake can cost

The sidecar counts model requests and stops at `--budget`. That is a count,
not a money limit. The money limit is the one you set on the account:

- **Subscription:** use a dedicated account, not your everyday one, and
  switch extra usage (overage billing, credits) **off** on it. Then the
  worst case is the plan's usage allowance for the period.
- **API key:** the dedicated project's budget is the ceiling.

## Revoking

Do this if the machine is lost, or when you stop using the sandbox.

- **Subscription login:** sign in to chatgpt.com as that account, open
  Settings, then Security, and log out of all devices. That invalidates the
  stored refresh token. Sign in again with `codex login` and repeat
  `./sandbox login` when you next need it.
- **API key:** delete the key in the OpenAI platform console (API keys).
- Then delete the stored copy. `./sandbox login` prints the exact command;
  it is `secret-tool clear service agent-sandbox agent codex auth oauth` on
  Linux and `security delete-generic-password -s agent-sandbox -a
  codex-oauth` on macOS (`apikey` in place of `oauth` for a key).
- Delete `~/.codex/auth.json` on your host too if you no longer use Codex
  there: it is the same login.

A session that is already running keeps its current access token in the
sidecar's memory until the session ends; `./sandbox destroy` ends it.
