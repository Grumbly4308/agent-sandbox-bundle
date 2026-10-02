#!/usr/bin/env bash
# Each agent plug-in's `launch`, run with a fake CLI first on PATH and a
# temporary HOME. Asserts the files it writes and the arguments and
# environment the CLI receives, for oauth and apikey, with and without
# --auto, and that everything that looks like a credential is a dummy.
#
# The environment is built the way the container builds it: empty, plus the
# plug-in's `env` file if it has one, plus the sidecar's address for the
# session (topology.sh), plus what ./sandbox passes at `podman exec`.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mkdir -p "$scratch/bin"
for cli in claude codex opencode; do
  # The fake CLI writes its arguments, one per line, and its environment.
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "$FAKE_OUT/argv"\nenv > "$FAKE_OUT/env"\n' >"$scratch/bin/$cli"
  chmod +x "$scratch/bin/$cli"
done

# run_launch <agent> <auth> [launch args...]: fresh HOME, fresh output
# directory; leaves them in $home and $out, the exit status in $status.
run_launch() {
  local agent="$1" auth="$2" line envs=()
  shift 2
  home="$scratch/home.$agent.$auth.$#"
  out="$scratch/out.$agent.$auth.$#"
  rm -rf "${home:?}" "${out:?}"
  mkdir -p "$home" "$out"
  if [ -f "$root/agents/$agent/env" ]; then
    while IFS= read -r line; do
      envs+=("$line")
    done <"$root/agents/$agent/env"
  fi
  status=0
  env -i PATH="$scratch/bin:/usr/local/bin:/usr/bin:/bin" HOME="$home" FAKE_OUT="$out" \
    ${envs[@]+"${envs[@]}"} ${sidecar_url:+SANDBOX_SIDECAR_URL="$sidecar_url"} SANDBOX_AUTH="$auth" \
    "$root/agents/$agent/launch" "$@" >"$out/stdout" 2>"$out/stderr" || status=$?
}

argv_is() {   # <description> <expected args...>
  local what="$1" want
  shift
  want="$(printf '%s\n' "$@")"
  if [ "$#" -eq 0 ]; then want=""; fi
  if [ "$(cat "$out/argv")" = "$want" ]; then pass "$what"; else fail "$what: got [$(tr '\n' ' ' <"$out/argv")]"; fi
}
env_has() {   # <description> <NAME=value>
  if grep -qxF -- "$2" "$out/env"; then pass "$1"; else fail "$1: $2 not in the CLI's environment"; fi
}
env_lacks() {   # <description> <NAME>
  if grep -q "^$2=" "$out/env"; then fail "$1: $2 is set"; else pass "$1"; fi
}

# Everything that looks like a credential, anywhere the launch put it (the
# CLI's environment and arguments, every file under HOME), must contain the
# word "dummy".
all_dummy() {   # <description>
  local what="$1" bad="" token name value
  while IFS= read -r token; do
    case "$token" in *dummy*) ;; *) bad="$bad $token" ;; esac
  done < <(
    { cat "$out/env" "$out/argv"; find "$home" -type f -exec cat {} +; } 2>/dev/null \
      | grep -oE '(sk|rt|acct)-[A-Za-z0-9_-]{6,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' || true
  )
  # Variables named like secrets.
  while IFS='=' read -r name value; do
    case "$name" in
      *_KEY | *_TOKEN | *_SECRET | *_PASSWORD)
        case "$value" in *dummy*) ;; *) bad="$bad $name" ;; esac
        ;;
    esac
  done <"$out/env"
  if [ -z "$bad" ]; then pass "$what"; else fail "$what: not marked dummy:$bad"; fi
}

started() {   # <description>: the launch exited 0 and reached the CLI
  if [ "$status" -eq 0 ] && [ -e "$out/argv" ]; then pass "$1"; else fail "$1: exit $status: $(cat "$out/stderr")"; fi
}
refused() {   # <description>: the launch failed and never started the CLI
  if [ "$status" -ne 0 ] && [ ! -e "$out/argv" ]; then pass "$1"; else fail "$1"; fi
}

# The sidecar's address in a session, as topology.sh hands it in.
sidecar_url="http://10.201.7.3:8080"

settings='{"skipWebFetchPreflight":true,"attribution":{"commit":"","pr":""}}'

# ---------------------------------------------------------------------------
# Claude Code
# ---------------------------------------------------------------------------
run_launch claude oauth
started "claude oauth: launch succeeds"
argv_is "claude oauth: argv is --settings <json>" --settings "$settings"
env_has "claude oauth: dummy subscription token" "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-sandbox-dummy-not-a-credential"
env_lacks "claude oauth: no API key variable" ANTHROPIC_API_KEY
env_has "claude oauth: base URL is the sidecar" "ANTHROPIC_BASE_URL=http://10.201.7.3:8080"
env_has "claude oauth: non-essential traffic off" "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
env_has "claude oauth: marketplace auto-install off" "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1"
env_has "claude oauth: auto-updater off" "DISABLE_AUTOUPDATER=1"
env_lacks "claude oauth: first-party override is not set" _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL
if [ "$(jq -c . "$home/.claude.json")" = '{"hasCompletedOnboarding":true,"projects":{"/workspace/repo":{"hasTrustDialogAccepted":true}}}' ]; then
  pass "claude oauth: ~/.claude.json has onboarding and trust, nothing else"
else
  fail "claude oauth: unexpected ~/.claude.json: $(cat "$home/.claude.json")"
fi
if [ "$(mode_of "$home/.claude.json")" = 600 ]; then
  pass "claude oauth: ~/.claude.json is 0600"
else
  fail "claude oauth: ~/.claude.json mode $(mode_of "$home/.claude.json")"
fi
if [ -z "$(find "$home" -type f ! -name .claude.json)" ]; then
  pass "claude oauth: no settings.json, no CLAUDE.md, no hooks written"
else
  fail "claude oauth: extra files written: $(find "$home" -type f ! -name .claude.json | tr '\n' ' ')"
fi
all_dummy "claude oauth: credentials are dummies"

run_launch claude oauth --auto -p "say hi"
argv_is "claude oauth --auto: adds the bypass flag, keeps the arguments" \
  --settings "$settings" --dangerously-skip-permissions -p "say hi"

run_launch claude apikey
started "claude apikey: launch succeeds"
argv_is "claude apikey: argv is --settings <json>" --settings "$settings"
env_has "claude apikey: dummy API key" "ANTHROPIC_API_KEY=sk-ant-api03-sandbox-dummy-not-a-credential"
env_lacks "claude apikey: no subscription token variable" CLAUDE_CODE_OAUTH_TOKEN
key="sk-ant-api03-sandbox-dummy-not-a-credential"
if [ "$(jq -r '.customApiKeyResponses.approved[0]' "$home/.claude.json")" = "${key: -20}" ] \
  && [ "$(jq -c '.customApiKeyResponses.rejected' "$home/.claude.json")" = "[]" ] \
  && [ "$(jq -r '.hasCompletedOnboarding' "$home/.claude.json")" = true ] \
  && [ "$(jq -r '.projects["/workspace/repo"].hasTrustDialogAccepted' "$home/.claude.json")" = true ]; then
  pass "claude apikey: key approved by its last 20 characters, onboarding and trust set"
else
  fail "claude apikey: unexpected ~/.claude.json: $(cat "$home/.claude.json")"
fi
all_dummy "claude apikey: credentials are dummies"

run_launch claude apikey --auto
argv_is "claude apikey --auto: adds the bypass flag" --settings "$settings" --dangerously-skip-permissions

# A second start keeps what the CLI wrote into ~/.claude.json meanwhile.
run_launch claude oauth
printf '{"numStartups":3,"projects":{"/workspace/repo":{"lastSessionId":"x"},"/other":{"a":1}}}\n' >"$home/.claude.json"
env -i PATH="$scratch/bin:/usr/bin:/bin" HOME="$home" FAKE_OUT="$out" SANDBOX_SIDECAR_URL="$sidecar_url" SANDBOX_AUTH=oauth "$root/agents/claude/launch" >/dev/null 2>&1 || true
if [ "$(jq -c '[.numStartups, .projects["/workspace/repo"].lastSessionId, .projects["/other"].a, .hasCompletedOnboarding, .projects["/workspace/repo"].hasTrustDialogAccepted]' "$home/.claude.json")" = '[3,"x",1,true,true]' ]; then
  pass "claude: a second start merges into the existing ~/.claude.json"
else
  fail "claude: second start lost state: $(cat "$home/.claude.json")"
fi
printf 'not json\n' >"$home/.claude.json"
env -i PATH="$scratch/bin:/usr/bin:/bin" HOME="$home" FAKE_OUT="$out" SANDBOX_SIDECAR_URL="$sidecar_url" SANDBOX_AUTH=oauth "$root/agents/claude/launch" >/dev/null 2>&1 || true
check "claude: a corrupt ~/.claude.json is replaced" jq -e '.hasCompletedOnboarding == true' "$home/.claude.json"

run_launch claude ""
refused "claude: refuses to start without SANDBOX_AUTH"

# ---------------------------------------------------------------------------
# Codex
# ---------------------------------------------------------------------------
run_launch codex oauth
started "codex oauth: launch succeeds"
argv_is "codex oauth: no arguments added"
cfg="$home/.codex/config.toml"
auth="$home/.codex/auth.json"
for line in \
  'model_provider = "sidecar"' \
  'chatgpt_base_url = "http://10.201.7.3:8080/backend-api"' \
  'sandbox_mode = "danger-full-access"' \
  'check_for_update_on_startup = false' \
  '[model_providers.sidecar]' \
  'base_url = "http://10.201.7.3:8080/backend-api/codex"' \
  'wire_api = "responses"' \
  'requires_openai_auth = true' \
  '[analytics]' \
  '[otel]' \
  'metrics_exporter = "none"' \
  '[features]' \
  'apps = false' \
  'plugins = false' \
  'remote_plugin = false' \
  '[projects."/workspace/repo"]' \
  'trust_level = "trusted"'; do
  if grep -qxF -- "$line" "$cfg"; then pass "codex oauth: config.toml has: $line"; else fail "codex oauth: config.toml lacks: $line"; fi
done
# Top-level keys must precede the first table, or TOML files them under it.
first_table="$(grep -n '^\[' "$cfg" | head -n 1 | cut -d: -f1)"
for key in model_provider chatgpt_base_url sandbox_mode check_for_update_on_startup; do
  at="$(grep -n "^$key = " "$cfg" | cut -d: -f1)"
  if [ -n "$at" ] && [ "$at" -lt "$first_table" ]; then pass "codex oauth: $key is a top-level key"; else fail "codex oauth: $key is not above the first table"; fi
done
check_not "codex oauth: no approval policy is shipped" grep -q 'approval_policy' "$cfg"
if grep -oE 'https?://[^"/]+' "$cfg" | grep -qv '^http://10.201.7.3:8080$'; then
  fail "codex oauth: config.toml names a host other than the sidecar"
else
  pass "codex oauth: every URL in config.toml is the sidecar"
fi
if [ "$(mode_of "$auth")" = 600 ] && [ "$(mode_of "$home/.codex")" = 700 ]; then
  pass "codex oauth: auth.json 0600 in a 0700 directory"
else
  fail "codex oauth: loose permissions on the login file"
fi
check "codex oauth: auth.json is valid JSON in ChatGPT mode" jq -e '.auth_mode == "chatgpt" and .OPENAI_API_KEY == null' "$auth"
check "codex oauth: dummy refresh token and account id" \
  jq -e '.tokens.refresh_token == "rt-sandbox-dummy-not-a-credential" and .tokens.account_id == "acct-sandbox-dummy"' "$auth"
check "codex oauth: last_refresh is a timestamp" jq -e '.last_refresh | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$auth"
now="$(date +%s)"
for token in id_token access_token; do
  jwt="$(jq -r ".tokens.$token" "$auth")"
  IFS=. read -r h p s <<<"$jwt"
  # base64url -> JSON, with Node (it accepts the unpadded form).
  header="$(node -e 'process.stdout.write(Buffer.from(process.argv[1], "base64url").toString())' "$h")"
  payload="$(node -e 'process.stdout.write(Buffer.from(process.argv[1], "base64url").toString())' "$p")"
  check "codex oauth: $token header is JSON naming an algorithm" jq -e '.alg and .typ == "JWT"' <<<"$header"
  if [ "$(jq -r '.exp' <<<"$payload")" -gt $((now + 5 * 365 * 86400)) ]; then
    pass "codex oauth: $token expires far in the future"
  else
    fail "codex oauth: $token exp is not far in the future"
  fi
  if [ "$(jq -c 'keys' <<<"$payload")" = '["exp","https://api.openai.com/auth"]' ] \
    && [ "$(jq -r '."https://api.openai.com/auth".chatgpt_account_id' <<<"$payload")" = "acct-sandbox-dummy" ]; then
    pass "codex oauth: $token payload holds only exp and a dummy account"
  else
    fail "codex oauth: $token payload: $payload"
  fi
  case "$s" in *dummy*) pass "codex oauth: $token signature is marked dummy" ;; *) fail "codex oauth: $token signature is not marked dummy" ;; esac
  case "$h$p$s" in *[!A-Za-z0-9_-]*) fail "codex oauth: $token is not base64url" ;; *) pass "codex oauth: $token is three base64url parts" ;; esac
done
env_has "codex oauth: refresh backstop points at the sidecar" "CODEX_REFRESH_TOKEN_URL_OVERRIDE=http://10.201.7.3:8080/oauth/token"
env_lacks "codex oauth: no API key variable" OPENAI_API_KEY
env_lacks "codex oauth: no Codex API key variable" CODEX_API_KEY
all_dummy "codex oauth: credentials are dummies"

run_launch codex oauth --auto exec "fix it"
argv_is "codex oauth --auto: adds the bypass flag, keeps the arguments" \
  --dangerously-bypass-approvals-and-sandbox exec "fix it"

run_launch codex apikey
started "codex apikey: launch succeeds"
argv_is "codex apikey: no arguments added"
cfg="$home/.codex/config.toml"
for line in \
  'openai_base_url = "http://10.201.7.3:8080/v1"' \
  'sandbox_mode = "danger-full-access"' \
  'check_for_update_on_startup = false' \
  '[projects."/workspace/repo"]'; do
  if grep -qxF -- "$line" "$cfg"; then pass "codex apikey: config.toml has: $line"; else fail "codex apikey: config.toml lacks: $line"; fi
done
check_not "codex apikey: no custom provider" grep -q 'model_provider' "$cfg"
check_not "codex apikey: no login file" test -e "$home/.codex/auth.json"
env_has "codex apikey: dummy CODEX_API_KEY" "CODEX_API_KEY=sk-sandbox-dummy-not-a-credential"
env_has "codex apikey: dummy OPENAI_API_KEY" "OPENAI_API_KEY=sk-sandbox-dummy-not-a-credential"
all_dummy "codex apikey: credentials are dummies"

run_launch codex apikey --auto
argv_is "codex apikey --auto: adds the bypass flag" --dangerously-bypass-approvals-and-sandbox

run_launch codex ""
refused "codex: refuses to start without SANDBOX_AUTH"

# ---------------------------------------------------------------------------
# OpenCode
# ---------------------------------------------------------------------------
run_launch opencode apikey
started "opencode apikey: launch succeeds"
argv_is "opencode apikey: no arguments added"
env_has "opencode apikey: dummy API key in the environment" "ANTHROPIC_API_KEY=sk-ant-api03-sandbox-dummy-not-a-credential"
env_has "opencode apikey: models fetch off" "OPENCODE_DISABLE_MODELS_FETCH=1"
env_has "opencode apikey: auto-update off" "OPENCODE_DISABLE_AUTOUPDATE=1"
content="$(sed -n 's/^OPENCODE_CONFIG_CONTENT=//p' "$out/env")"
check "opencode apikey: OPENCODE_CONFIG_CONTENT is JSON" jq -e . <<<"$content"
check "opencode apikey: Anthropic base URL is the sidecar, with /v1" \
  jq -e '.provider.anthropic.options.baseURL == "http://10.201.7.3:8080/v1"' <<<"$content"
check "opencode apikey: sharing is disabled" jq -e '.share == "disabled"' <<<"$content"
check "opencode apikey: a default Anthropic model is pinned" jq -e '.model | startswith("anthropic/")' <<<"$content"
check "opencode apikey: the key is not in the configuration" jq -e '[.. | objects | has("apiKey")] | any | not' <<<"$content"
check "opencode apikey: no permission rules are shipped" jq -e 'has("permission") | not' <<<"$content"
if [ -z "$(find "$home" -type f)" ]; then pass "opencode apikey: writes no file"; else fail "opencode apikey: wrote $(find "$home" -type f | tr '\n' ' ')"; fi
all_dummy "opencode apikey: credentials are dummies"

run_launch opencode apikey --auto
argv_is "opencode apikey --auto (interactive): --auto" --auto
run_launch opencode apikey --auto run "fix it"
argv_is "opencode apikey --auto run: --auto right after run" run --auto "fix it"
run_launch opencode apikey run "fix it"
argv_is "opencode apikey run: arguments unchanged" run "fix it"

run_launch opencode oauth
refused "opencode oauth: refused, CLI not started"
check "opencode oauth: the refusal points at auth.md" grep -q 'auth.md' "$out/stderr"
run_launch opencode ""
refused "opencode: refuses to start without SANDBOX_AUTH"

# ---------------------------------------------------------------------------
# No plug-in ships rules for the agent.
# ---------------------------------------------------------------------------
for agent in claude codex opencode; do
  for banned in CLAUDE.md AGENTS.md settings.json opencode.json hooks; do
    check_not "$agent: ships no $banned" test -e "$root/agents/$agent/$banned"
  done
done

# ---------------------------------------------------------------------------
# No sidecar address, no start: a CLI left to its default would go to the
# vendor, and the proxy would refuse every request.
# ---------------------------------------------------------------------------
sidecar_url=""
for pair in claude:oauth codex:oauth codex:apikey opencode:apikey; do
  run_launch "${pair%%:*}" "${pair##*:}"
  refused "${pair%%:*} ${pair##*:}: refuses to start without the sidecar's address"
done

finish
