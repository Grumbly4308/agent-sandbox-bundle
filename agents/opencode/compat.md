# OpenCode: compatibility settings

OpenCode 1.18.34 (`opencode-ai`, pinned in `install.sh`). Closes reference
finding L2 (no OpenCode).

**Nothing on this page is a control.** Every setting below is applied by, or
readable and changeable by, the agent's own process. They exist so that the
CLI starts and finds the credential sidecar. Delete them all and the sandbox
is exactly as safe: what the agent can reach is decided by the container,
the proxy and the sidecar (`topology.sh`, `docs/00-threat-model.md`), not
here. We ship no `AGENTS.md`, no `opencode.json` and no permission rules.

## The one thing to understand about OpenCode

OpenCode has a built-in provider called `opencode` that needs **no key** and
sends model requests to `opencode.ai`. **A repository's own `opencode.json`
can select it**, for the default model or for a single agent or command. It
is also what OpenCode falls back to by itself when it finds no key at all.
The settings below pin the *default* provider and model to the sidecar; they do
not and cannot stop a file in the repository from choosing another one.

**Only the egress proxy stops that traffic** `[logical B20]`: `opencode.ai`,
`opncd.ai` and `models.opencode.ai` are not on the allowlist, so the request
is refused and the session shows an error instead of sending the
conversation to a third party. The pin is a convenience. Do not add those
hosts to the allowlist.

## Settings

"Proven necessary" means: the spike of 2026-10-01 ran the CLI with and
without the setting, against a mock API and a proxy that refuses everything,
and the CLI did not work without it. "No" means the CLI works without it.
The spike used a mock; that the vendor accepts the forwarded requests is not
yet proven.

`$SANDBOX_SIDECAR_URL` is the credential sidecar's address in this session,
for example `http://10.201.0.3:8080`. `topology.sh` sets it on the container.
It is an address, not a name: no container here is found by name.

| Setting | Where it is applied | Why | Proven necessary |
|---|---|---|---|
| `provider.anthropic.options.baseURL = "$SANDBOX_SIDECAR_URL/v1"` in `OPENCODE_CONFIG_CONTENT` | `launch` | Sends Anthropic model requests to the sidecar. **The `/v1` at the end is mandatory**: without it requests go to the wrong path and fail. Given through this variable because it wins over the repository's and the user's configuration; `ANTHROPIC_BASE_URL` does not. | yes |
| `ANTHROPIC_API_KEY=sk-ant-api03-sandbox-dummy-not-a-credential` | `launch`, in the environment | OpenCode does not offer the Anthropic provider without a key. A placeholder; the sidecar discards it and uses the real key. In the environment and not in the configuration: as a configuration value OpenCode drops the `anthropic-beta` request headers for extended thinking and streamed tool calls. | yes |
| `model = "anthropic/claude-sonnet-4-6"` in `OPENCODE_CONFIG_CONTENT` | `launch` | A fixed default model. It is the one OpenCode 1.18.34 picks by itself when only an Anthropic key is present; stating it keeps the default from being taken from the repository's configuration. Choose another with `-m` or `/models`. | no |
| `share = "disabled"` in `OPENCODE_CONFIG_CONTENT` | `launch` | Session sharing uploads the conversation to `opncd.ai`. The proxy refuses that host anyway; this saves the attempt. | no |
| `OPENCODE_DISABLE_MODELS_FETCH=1` | `env` | OpenCode fetches its model list from `models.opencode.ai` at start. The proxy refuses it and the built-in list is used; this saves the attempt. | no |
| `OPENCODE_DISABLE_AUTOUPDATE=1` | `env` | The CLI is installed read-only and cannot update itself. Upgrading is `./sandbox upgrade`. The spike saw no change in traffic with it. | no |
| `--auto` | `launch`, only with `run --auto` | Your choice, not a compatibility setting: OpenCode's flag that approves every permission request not explicitly denied. Prompts are for a person who is watching. | not applicable |

`NO_PROXY` must contain the sidecar's address (set in `topology.sh`); without it model
requests go to the proxy and fail.

## `--auto`: what is and is not proven

- `opencode run --auto <message>` was run in the spike: a file write that is
  refused without the flag went through with it. `launch` puts the flag
  right after `run`, as there.
- For the interactive interface (`opencode --auto`), the flag is listed in
  `opencode --help` for the default command, with the same description. It
  was **not** run in the spike.
- Without `--auto`, `opencode run` rejects permission requests by itself
  (nobody can answer them) and the interactive interface asks.

## What still reaches for a fixed host

OpenCode contacts `registry.npmjs.org` at start, and `models.opencode.ai`
and `opncd.ai` unless told not to as above. The npm registry is on the base allowlist; the other two are refused
and the CLI carries on.

## Not covered by the spike

- Models from vendors other than Anthropic. The sidecar forwards the
  Anthropic API only for this agent.
- OpenCode's `webfetch` tool runs in the container and is bounded by the
  allowlist like everything else.
