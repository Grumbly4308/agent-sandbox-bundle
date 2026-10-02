# OpenCode: credentials

One mode is legitimate for OpenCode: **an API key** (`--auth apikey`).

```
./sandbox login --agent opencode --auth apikey
./sandbox run <repo> --agent opencode --auth apikey
```

`./sandbox run --agent opencode --auth oauth` is refused.

## Why not a subscription login

- **It is not what the subscription is for.** OpenCode is a third-party
  client. A Claude or ChatGPT subscription login is issued for the vendor's
  own applications; as we read the vendors' terms, it may not be used from
  another product. Check the current terms of your plan before assuming
  otherwise. An API key is the credential the vendors provide for
  third-party tools.
- **It could not be made safe here anyway.** OpenCode's subscription
  sign-in ignores the address it is configured with and talks to the
  vendor's hosts directly (spike of 2026-10-01). The whole design rests on
  the real credential living in the sidecar and the agent holding a dummy
  `[logical B22]`; a login that cannot be routed through the sidecar would
  have to be put inside the agent container, which this sandbox never does
  `[physical B15]`.

## What `login` stores

`login` asks for an Anthropic API key and stores it in your operating
system's keyring. At `run` it is piped into the credential sidecar and never
enters the agent container. The agent holds a placeholder with the word
`dummy` in it.

Create the key in the Anthropic Console in a **workspace made for this
purpose, with a spend limit set on it**.

## Limit what a mistake can cost

The sidecar counts model requests and stops at `--budget`. That is a count,
not a money limit. The money limit is the dedicated workspace's spend limit.
Do not use a key from a workspace that other work depends on.

(For the agents that do take a subscription, the same advice reads: a
dedicated account, with overage billing off.)

## Revoking

- Delete the key in the Anthropic Console (API keys).
- Then delete the stored copy. `./sandbox login` prints the exact command;
  it is `secret-tool clear service agent-sandbox agent opencode auth apikey`
  on Linux and `security delete-generic-password -s agent-sandbox -a
  opencode-apikey` on macOS.

A session that is already running keeps the key in the sidecar's memory
until the session ends; `./sandbox destroy` ends it.
