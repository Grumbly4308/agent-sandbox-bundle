# Claude Code: compatibility settings

Claude Code 2.1.296 (`@anthropic-ai/claude-code`, pinned in `install.sh`).

**Nothing on this page is a control.** Every setting below is applied by, or
readable and changeable by, the agent's own process. They exist so that the
CLI starts, finds the credential sidecar, and does not spend its time on
requests the proxy refuses. Delete them all and the sandbox is exactly as
safe: what the agent can reach is decided by the container, the proxy and
the sidecar (`topology.sh`, `docs/00-threat-model.md`), not here. We ship no
`CLAUDE.md`, no hooks, no permission rules and no `settings.json`.

"Proven necessary" means: the spike of 2026-10-01 ran the CLI with and
without the setting, against a mock API and a proxy that refuses everything,
and the CLI did not work without it. "No" means the CLI works without it and
the setting is a convenience. The spike used a mock; that the vendor accepts
the forwarded requests was proven on 2026-10-10 (test card F1, Claude Code
2.1.283 with a subscription).

`$SANDBOX_SIDECAR_URL` is the credential sidecar's address in this session,
for example `http://10.201.0.3:8080`. `topology.sh` sets it on the container.
It is an address, not a name: no container here is found by name.

| Setting | Where it is applied | Why | Proven necessary |
|---|---|---|---|
| `ANTHROPIC_BASE_URL=$SANDBOX_SIDECAR_URL` | `launch` | Sends every model request (`/v1/messages`, token counting, sub-agents, compaction, web search) to the sidecar instead of the vendor. The agent has no route to the vendor at all. | yes |
| `CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-sandbox-dummy-not-a-credential` (oauth) | `launch` | The CLI will not start without a credential. This is a placeholder; the sidecar discards it and uses the real token. With this variable the CLI needs no credentials file and never tries to refresh. | yes |
| `ANTHROPIC_API_KEY=sk-ant-api03-sandbox-dummy-not-a-credential` (apikey) | `launch` | Same, for API-key mode. | yes |
| `customApiKeyResponses.approved` = last 20 characters of the dummy key (apikey) | `launch` writes `~/.claude.json` | The interactive interface asks whether to use an API key found in the environment and sends nothing until it is approved. | yes, for the interactive interface |
| `hasCompletedOnboarding: true` | `launch` writes `~/.claude.json` | The home directory is new every session. Without this the interactive interface exits with status 1. | yes, for the interactive interface |
| `projects["/workspace/repo"].hasTrustDialogAccepted: true` | `launch` writes `~/.claude.json` | Without it the interface stops at "do you trust this folder" on every start. | yes, for an unattended start |
| `skipWebFetchPreflight: true` | `launch`, `--settings` on the command line | Before fetching a page the CLI asks a fixed vendor host about the domain; the proxy refuses that host and WebFetch fails. The fetch itself still goes through the proxy and its allowlist. | yes, for WebFetch |
| `attribution: {commit: "", pr: ""}` | `launch`, `--settings` on the command line | No AI attribution trailer on commits and pull requests. A courtesy only: `./sandbox export` strips attribution on the host and refuses if any survives. | no |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | `env` | Stops telemetry and similar background requests. In the spike this cut refused requests at start from about a dozen to one. | no |
| `CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1` | `env` | Stops the attempt to download the plug-in marketplace (`downloads.claude.ai`, `github.com`), which the proxy refuses. | no |
| `DISABLE_AUTOUPDATER=1` | `env` | The CLI is installed read-only and cannot update itself; this saves the check against the npm registry. Upgrading is `./sandbox upgrade`. | no |
| `--dangerously-skip-permissions` | `launch`, only with `run --auto` | Your choice, not a compatibility setting: no permission prompts. Prompts are for a person who is watching. | not applicable |

Two things the plug-in depends on but does not set itself: `NO_PROXY` must
contain the sidecar's address (set in `topology.sh`; without it model requests go to the
proxy and fail), and the sidecar must never answer 401 (the CLI ends the
turn; the sidecar answers 403 or 503 instead).

## Deliberately not set

- `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL`. The spike measured an 18-second
  stall at start with it.
- Any permission rule, hook or instruction file. See the top of this page.
- **Claude Code's own bubblewrap sandbox** is left at the vendor default,
  which is off. It could not work here anyway: it needs to create
  namespaces, and the container's system-call filter refuses that
  `[physical B04]`.

## What still reaches for a fixed host

Even with the settings above the CLI makes one request to `api.anthropic.com`
at start that cannot be redirected, and its login token address cannot be
redirected either. The proxy refuses both and the CLI carries on. None of
these hosts is on the agent's allowlist.

## Not covered by the spike

- With `--auto`, the interactive interface may show its own one-time
  "bypass permissions" confirmation. No setting is shipped to suppress it,
  because none was tested.
- WebSearch runs on the vendor's servers as part of a model request. The
  sidecar lets it through and logs the query `[logical B25]`; the allowlist
  does not apply to it.
