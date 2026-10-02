#!/usr/bin/env bash
# The two policy files export.sh reads: every pattern has a reason, the list
# covers what B27 promises, and the gitleaks configuration extends the default
# rules without any way to let a secret through.

# shellcheck source=tests/export/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PATTERNS_FILE=$ROOT/policy/runs-later.txt
GITLEAKS_FILE=$ROOT/policy/gitleaks.toml

# --- runs-later.txt ---------------------------------------------------------
# Every line that is not a comment, blank or a [group] is `pattern   # why`.
bad=$(grep -vE '^[[:space:]]*(#.*)?$|^\[[a-z]+\] [A-Za-z ]+$|^[A-Za-z0-9._*/-]+[[:space:]]+# [^[:space:]].{10,}$' "$PATTERNS_FILE" || true)
if [ -n "$bad" ]; then fail "runs-later.txt has lines without a pattern and a reason: $bad"; fi
ok "every pattern in runs-later.txt has a reason"

for pattern in \
  package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lockb poetry.lock Pipfile.lock uv.lock \
  Cargo.lock go.sum Gemfile.lock composer.lock \
  package.json pyproject.toml 'requirements*.txt' setup.py setup.cfg go.mod Cargo.toml Gemfile composer.json \
  '.github/workflows/**' .gitlab-ci.yml '.circleci/**' azure-pipelines.yml Jenkinsfile '.buildkite/**' \
  Makefile makefile GNUmakefile justfile Taskfile.yml 'Dockerfile*' 'Containerfile*' 'docker-compose*.yml' \
  'compose*.yml' '*.gradle' pom.xml \
  '.husky/**' .pre-commit-config.yaml '.githooks/**' .envrc .npmrc '.yarnrc*' .pnpmfile.cjs .vscode/tasks.json \
  .vscode/launch.json '.devcontainer/**' '.claude/**' .mcp.json AGENTS.md CLAUDE.md '.codex/**' opencode.json \
  '.opencode/**' .gitattributes .gitmodules; do
  if ! awk -v want="$pattern" '$1 == want { found = 1 } END { exit !found }' "$PATTERNS_FILE"; then
    fail "runs-later.txt lacks the pattern: $pattern"
  fi
done
first_group=$(grep -m1 '^\[' "$PATTERNS_FILE")
second_group=$(grep '^\[' "$PATTERNS_FILE" | awk 'NR == 2')
assert_eq "${first_group%%]*}" "[lockfiles" "the first group"
assert_eq "${second_group%%]*}" "[manifests" "the second group"
ok "runs-later.txt has every pattern B27 names, lockfiles and manifests first"

# One file per group, in odd places and odd case, to see the patterns match
# the way the file says they do.
fake_gitleaks 8.24.2 0
SRC=$WORK/src
new_repo "$SRC"
mkdir -p "$SRC/a/b/.GitHub/Workflows/deep" "$SRC/svc/.devcontainer/x" "$SRC/src/requirements"
echo x >"$SRC/a/b/.GitHub/Workflows/deep/ci.yml"
echo x >"$SRC/svc/.devcontainer/x/Dockerfile"
echo x >"$SRC/a/requirements-dev.txt"
echo x >"$SRC/a/Cargo.LOCK"
echo x >"$SRC/a/build.gradle.kts"
echo x >"$SRC/src/requirements/notes.md"
echo x >"$SRC/src/Makefile.md"
echo x >"$SRC/src/my-package.json"
commit_all "$SRC" "Files in odd places"
make_bundle "$SRC" "$WORK/odd.bundle"
next_session
run_export "$WORK/odd.bundle" "$WORK/out" "$SESSION" "$BASE" work
assert_rc 0
assert_has "Lockfiles: 1 changed"
assert_has "  A  a/Cargo.LOCK"
assert_has "Dependency manifests: 1 changed"
assert_has "  A  a/requirements-dev.txt"
assert_has "CI pipelines: 1 changed"
assert_has "Build and task files: 2 changed"
assert_has "Hooks and tool configuration that executes: 1 changed"
assert_has "RUNS LATER — 6 path(s)"
CODE=${OUTPUT%%"==== RUNS LATER"*}
for plain in src/requirements/notes.md src/Makefile.md src/my-package.json; do
  case $CODE in
    *"b/$plain"*) ;;
    *) fail "$plain is an ordinary file and should be in the code diff" ;;
  esac
done
ok "patterns match in any directory and any case, and only whole file names"

# --- gitleaks.toml ----------------------------------------------------------
grep -qx 'useDefault = true' "$GITLEAKS_FILE" || fail "gitleaks.toml does not extend the default rules"
if grep -v '^[[:space:]]*#' "$GITLEAKS_FILE" | grep -qiE 'allowlist|stopwords|disabledRules|\[extend\][^#]*path'; then
  fail "gitleaks.toml contains something that weakens the default rules"
fi
ok "gitleaks.toml extends the default rules and has no allowlist"

# The file must be valid TOML and its extra rule must match what it is for.
# (gitleaks is not here to say so; python 3.11 reads TOML.)
if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
  python3 - "$GITLEAKS_FILE" <<'PY' || fail "gitleaks.toml: see the message above"
import re, sys, tomllib

with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)
assert config["extend"] == {"useDefault": True}, "the [extend] table has more than useDefault"
assert set(config) <= {"title", "extend", "rules"}, "unexpected top-level keys: %s" % sorted(config)
for rule in config["rules"]:
    assert set(rule) <= {"id", "description", "regex", "keywords"}, "rule %s has keys that could weaken it" % rule["id"]
    pattern = re.compile(rule["regex"])
    token = "sk-ant-" + "oat01-" + "A1b2C3d4_" * 6
    assert pattern.search("token = " + token), "the rule does not match an OAuth token"
    assert pattern.search("sk-ant-" + "api03-" + "x" * 95), "the rule does not match an API key"
    assert not pattern.search("sk-ant-short"), "the rule matches a string that is no token"
PY
  ok "gitleaks.toml is valid TOML and its rule matches Anthropic tokens"
else
  echo "skip - no python3 with tomllib: gitleaks.toml not parsed"
fi

echo "test-policy: all passed"
