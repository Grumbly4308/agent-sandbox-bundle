# Claude Code: credentials

Two modes are legitimate for Claude Code. In both, the real credential is
kept in your operating system's keyring between sessions, piped into the
credential sidecar when a session starts, and never enters the agent
container `[physical B15, logical B22]`. The agent only ever holds a
placeholder with the word `dummy` in it.

## `--auth oauth` (default): a Claude subscription

For a Claude Pro, Max, Team or Enterprise seat. Claude Code is the vendor's
own client, so using a subscription with it is what the subscription is for.

`./sandbox login --agent claude --auth oauth` asks you to run
`claude setup-token` on a machine where you are signed in to Claude Code
with the account you want the sandbox to use, and to paste what it prints.
That command opens a browser, you approve, and it prints a token that:

- is valid for **one year**;
- is limited to model requests ("inference");
- has nothing to refresh, so no refresh token exists anywhere.

`login` stores that one token in the keyring. Your normal Claude Code login
(the one in `~/.claude` on your host) is not read, copied or mounted.
(Closes reference finding H1: the previous version mounted the whole-account
login into every run.)

## `--auth apikey`: an Anthropic API key

For pay-as-you-go use. Create the key in the Anthropic Console in a
**workspace made for this purpose, with a spend limit set on it**. `login`
asks for the key and stores it in the keyring.

## Limit what a mistake can cost

The sidecar counts model requests and stops at `--budget`. That is a count,
not a money limit. The money limit is the one you set on the account:

- **Subscription:** use a dedicated account, or at least turn extra-usage /
  overage billing **off** for the account whose token you store. Then the
  worst case is the plan's usage allowance for the period.
- **API key:** the dedicated workspace's spend limit is the ceiling.

## Revoking

Do this if the machine is lost, or when you stop using the sandbox.

- **Subscription token:** sign in to claude.ai as that account, open
  Settings, then Claude Code, and revoke the token. The year-long token
  stops working; your interactive logins are separate.
- **API key:** delete the key in the Anthropic Console (API keys).
- Then delete the stored copy. `./sandbox login` prints the exact command;
  it is `secret-tool clear service agent-sandbox agent claude auth oauth` on
  Linux and `security delete-generic-password -s agent-sandbox -a
  claude-oauth` on macOS (`apikey` in place of `oauth` for a key).

A session that is already running keeps the credential in the sidecar's
memory until the session ends; `./sandbox destroy` ends it. Once revoked,
the vendor answers 401, which the sidecar reports to the CLI as 403 with a
message saying the credential was rejected.
