# 10 — Getting the work back out: push and pull requests

The agent commits inside the container. Everything after that happens on the
host, in your environment, with your credentials. That is the point: the
sandbox is where mistakes are cheap, and your account is where they are not.

```
container            host
─────────            ────
agent commits  ──►   ./sandbox review    diff, untracked files, secret scan
                     ./sandbox push      branch → origin
                     ./sandbox pr        branch → origin, then open the PR/MR
```

---

## 1. Review before anything leaves

```bash
./sandbox review
```

Four things, in order:

- **the workspace's git config** — warns if `origin` no longer matches the URL
  `./sandbox new` recorded, or if a hook path, fsmonitor, ssh command or
  credential helper has been set in it (see below)
- **the diff against `origin/<default branch>`** — `--stat` only; read the full
  diff before you push, always
- **the commits** — messages, and whether they are the small reviewable steps
  `CLAUDE.md` asked for
- **an attribution check** — greps the commit bodies for `Co-Authored-By`,
  "Generated with" and robot emoji, so an AI trailer never reaches the remote
  (see docs/07 for the settings and `CLAUDE.md` rule that suppress them)
- **untracked files** — the agent's leftovers. These never appear in
  `git diff`, and they are exactly where an accidentally-written secret ends up
- **a secret scan** — `gitleaks` if installed, a crude grep otherwise

Then actually read it:

```bash
git -C workspace diff origin/main...HEAD
```

Three dots, not two: that compares against the merge base, so you see what the
branch *adds* rather than everything that has happened on `main` since.

---

## 2. Push

```bash
./sandbox push
```

Pushes `<branch>` from `workspace/`, on the host, using your normal git
credentials — SSH agent, credential helper, whatever you already have. No
token has to exist inside the container for this to work.

Where it pushes *to* is the URL `./sandbox new` recorded in `.env` as
`WORKSPACE_ORIGIN`, not whatever `workspace/.git/config` says now. `workspace/`
is a clone of `project/`, so its `origin` initially points at a directory on
your disk; `new` rewrites it to the real upstream and records that URL in the
same step.

Verify once, if you like:

```bash
grep WORKSPACE_ORIGIN .env
```

### Why the host never trusts the workspace's git config

Everything under `workspace/` is the agent's to write, `.git/config` and
`.git/hooks` included. Git runs what a repo's own config points it at —
`core.hooksPath`, `core.fsmonitor`, `core.pager`, `diff.external`, an `ext::`
remote — as the user who invoked it, and on the host that user is you, with
your credentials. So every git command `./sandbox` runs against the workspace
overrides those keys on the command line, `gh`/`glab` get the same overrides
and are told which repo to use, and push and fetch go to the recorded URL.
`./sandbox review` and `./sandbox doctor` warn when the workspace's `origin`
differs from the recorded one, or when `core.hooksPath`, `core.fsmonitor`,
`core.sshCommand`, `credential.helper` or similar are set — `new` writes none
of them, so the agent did. A plain `git -C workspace ...` from your shell has
none of this protection; read the warnings first.

---

## 3. Open a PR / MR

```bash
./sandbox pr                       # title = last commit subject
./sandbox pr "Fix session expiry"  # explicit title
```

It pushes first, then picks a path based on the remote's host:

**GitHub, with `gh` installed** — `gh pr create --base main --head agent/<task>`.
Authenticate `gh` once with `gh auth login`.

**GitHub, without `gh`** — prints the compare URL:

```
https://github.com/you/repo/compare/main...agent/fix-login?expand=1
```

**GitLab, with `glab` installed** — `glab mr create`. Works against self-hosted
instances; point it at yours with `glab auth login --hostname gitlab.example.org`.

**GitLab, without `glab`** — uses git push options, which GitLab implements
server-side:

```bash
git push -o merge_request.create \
         -o merge_request.target=main \
         -o merge_request.title="Fix session expiry" \
         origin agent/fix-login
```

Handy extras the same mechanism supports: `merge_request.draft`,
`merge_request.remove_source_branch`, `merge_request.assign="@you"`. If the
server is too old for push options, `./sandbox pr` falls back to printing the
"new merge request" URL.

---

## Letting the agent push, instead

Only if a long autonomous run genuinely needs it. Cost/benefit is in docs/06;
the short version is that a token inside the container is a token that a prompt
injection can use.

If you do:

- give it a **fine-grained, single-repo, ≤1-day** token as `GIT_TOKEN`, and
  set `SANDBOX_FORWARD_GIT_TOKEN=1` — without it the token stays on the host
- keep `Bash(git push:*)` in the `ask` list, and `--force` in `deny`
- expect it to push a branch, never to merge

```bash
# inside the container
git push "https://x-access-token:${GIT_TOKEN}@github.com/you/repo.git" HEAD
git push "https://oauth2:${GIT_TOKEN}@gitlab.com/you/repo.git" HEAD
```

A PR opened by the agent still gets reviewed by you before merge. Nothing in
this setup should ever produce a commit on `main` that no human read.

---

## After the merge

```bash
./sandbox destroy      # containers + workspace gone
```

`project/` stays as the canonical clone, so the next `./sandbox new` is a local
clone rather than a fresh network fetch. Revoke whatever you issued for the
session — `destroy` prints the list.
