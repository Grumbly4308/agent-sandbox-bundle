# Codex CLI: compatibility settings

Codex CLI 0.162.1 (`@openai/codex`, pinned in `install.sh`).

**Nothing on this page is a control.** Every setting below is applied by, or
readable and changeable by, the agent's own process. They exist so that the
CLI starts, finds the credential sidecar, and does not spend its time on
requests that are refused. Delete them all and the sandbox is exactly as
safe: what the agent can reach is decided by the container, the proxy and
the sidecar (`topology.sh`, `docs/00-threat-model.md`), not here. We ship no
`AGENTS.md`, no hooks and no approval policy.

"Proven necessary" means: the spike of 2026-10-01 ran the CLI with and
without the setting, against a mock API and a proxy that refuses everything,
and the CLI did not work without it. "No" means the CLI works without it, or
the spike did not test the difference. The spike used a mock; that the
vendor accepts the forwarded requests was proven on 2026-10-10 (test card
F2, Codex 0.162.1, a Plus account), which took the two rows below on the
account id and on TLS.

`launch` writes `$CODEX_HOME/config.toml` (and, for a subscription,
`auth.json`) afresh at every start. `$CODEX_HOME` is `~/.codex`.

## Subscription (`--auth oauth`)

`$SANDBOX_SIDECAR_URL` is the credential sidecar's address in this session,
for example `https://10.201.0.3:8080`. `topology.sh` sets it on the container.
It is an address, not a name: no container here is found by name. In this
mode it is HTTPS (see the row on the sidecar's certificate); with an API key
it is plain HTTP.

| Setting | Where it is applied | Why | Proven necessary |
|---|---|---|---|
| `model_provider = "sidecar"` with `[model_providers.sidecar]` `name = "sidecar"`, `base_url = "$SANDBOX_SIDECAR_URL/backend-api/codex"`, `wire_api = "responses"` | `config.toml` | Codex's built-in `openai` provider takes its address from the vendor's own reply and insists on HTTPS; it cannot be pointed at the sidecar. A provider defined here can. | yes |
| `requires_openai_auth = true` (same table) | `config.toml` | Makes Codex send its ChatGPT login to this provider, so the request has the shape the vendor expects once the sidecar swaps the token. | yes |
| `chatgpt_base_url = "$SANDBOX_SIDECAR_URL/backend-api"` | `config.toml` | The account check the interactive interface makes at start (`/backend-api/wham/accounts/check`) goes to the sidecar, which forwards it. | yes, for the interactive interface |
| `auth.json` with dummy tokens: `id_token` and `access_token` shaped like JWTs that expire in 2100, a `refresh_token`, your real `account_id` (in both tokens and in `tokens.account_id`), `last_refresh` = now | `launch` writes `auth.json`; `./sandbox` hands in the account id as `SANDBOX_CODEX_ACCOUNT_ID` | Codex will not start a subscription session without a login file whose tokens parse and are not expired. Every token is a placeholder; the sidecar replaces it with the real one. | yes (see the note below) |
| The real account id in that login | `./sandbox` reads it from the stored login; `launch` writes it | At start the interactive interface looks the login's account up in the list `/backend-api/wham/accounts/check` returns for the real login, and stops with "selected workspace missing from routing discovery" if it is not there. It did, with `acct-sandbox-dummy`, against the real vendor on 2026-10-10. The agent can read the id: it names the account, it is not a credential. Without a stored id `launch` falls back to `acct-sandbox-dummy`. | yes |
| The sidecar speaks HTTPS, with a certificate made for the session; `CODEX_CA_CERTIFICATE=~/.codex/sidecar-ca.pem` | `./sandbox` makes the key and certificate (openssl) and pipes them to the sidecar (`sidecar-load --tls`); it hands the certificate alone to `launch` as `SANDBOX_SIDECAR_CA`, which writes the file | With the real account id, the interactive interface goes on to "workspace routing" and stops with "workspace backend must use an HTTPS origin without credentials": it refuses `chatgpt_base_url` in plain HTTP, even for an account whose routing is `NO_CONSTRAINT` (a Plus account, 2026-10-10). Both checks are in every version from 0.159.3 to 0.162.1, and no setting turns workspace routing off. Whether `CODEX_CA_CERTIFICATE` replaces or adds to Codex's trusted roots has not been checked; what the agent can reach is decided by the proxy either way. | yes |
| `CODEX_REFRESH_TOKEN_URL_OVERRIDE=$SANDBOX_SIDECAR_URL/oauth/token` | `launch` | A backstop. If Codex ever decides to refresh the dummy login, the attempt goes to the sidecar, which does not forward that path, instead of leaving for the vendor's login host. | no |

Note on `auth.json`: the spike's dummy tokens carried more claims (an email
address, a plan type, a user id). The ones written here carry only an expiry
and the account id. Codex 0.162.1 accepted the smaller token against the
real vendor (F2, 2026-10-10).

## API key (`--auth apikey`)

| Setting | Where it is applied | Why | Proven necessary |
|---|---|---|---|
| `openai_base_url = "$SANDBOX_SIDECAR_URL/v1"` | `config.toml` | Points the built-in provider at the sidecar. | yes |
| `CODEX_API_KEY` and `OPENAI_API_KEY` = `sk-sandbox-dummy-not-a-credential` | `launch` | Codex will not start without a key. A placeholder; the sidecar discards it and uses the real key. | yes (proven with `codex exec`; the interactive interface in this mode was not run) |

## Both modes

| Setting | Where it is applied | Why | Proven necessary |
|---|---|---|---|
| `sandbox_mode = "danger-full-access"` | `config.toml` | Codex's own sandbox works by creating namespaces, which this container's system-call filter refuses `[physical B04]`. In any other mode every command Codex runs fails. "Full access" here means full access to a container that has none. | yes |
| `check_for_update_on_startup = false` | `config.toml` | The CLI is installed read-only and cannot update itself; this saves the check. Upgrading is `./sandbox upgrade`. | no |
| `[analytics] enabled = false`, `[otel] metrics_exporter = "none"` | `config.toml` | Usage reporting. Its requests would only be refused. | no |
| `[features] apps = false`, `plugins = false`, `remote_plugin = false` | `config.toml` | The app and plug-in catalogues are fetched from paths the sidecar does not forward; with these off Codex does not ask. | no |
| `[projects."/workspace/repo"] trust_level = "trusted"` | `config.toml` | Skips the "do you trust this folder" prompt, which would return every session because the home directory is new each time. | no (carried over from the previous version; the spike did not test it) |
| `--dangerously-bypass-approvals-and-sandbox` | `launch`, only with `run --auto` | Your choice, not a compatibility setting: no approval prompts. Prompts are for a person who is watching. | not applicable |

Two things the plug-in depends on but does not set itself: `NO_PROXY` must
contain the sidecar's address (set in `topology.sh`), and the sidecar must never answer
401 (Codex would try to refresh the login; the sidecar answers 403 or 503
instead).

## What does not work

- **`codex cloud`** cannot be pointed at the sidecar and does not work in the
  sandbox. It would also hand the task to the vendor's machines, outside
  every barrier here.
- Codex's own sandbox (`codex sandbox`, the `read-only` and
  `workspace-write` modes): see `sandbox_mode` above.

## What still reaches for a fixed host

In the spike Codex also tried `ab.chatgpt.com`, `chatgpt.com`, `github.com`,
`api.github.com` and `raw.githubusercontent.com` by itself. The proxy refuses
them and the CLI carries on. None is on the agent's allowlist.

## Not covered by the spike

- Web search runs on the vendor's servers as part of a model request and can
  also open a page by its address. The sidecar lets it through; logging of
  the query for Codex is not yet proven `[logical B25]`.
