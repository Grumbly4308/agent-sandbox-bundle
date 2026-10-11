# 09 — Sessions: repositories and agents

A **session** is what `./sandbox run` makes: one agent, one copy of one
repository, its own containers, networks and workspace, a time limit and a
request budget. This page is about using more than one: one repository after
another, several side by side, and handing a repository from one agent to
another.

The short version:

| You want to | Do this |
|---|---|
| Work on another repository when this one is done | `export`, `destroy`, then `run` the next one. [Below](#one-repository-after-another). |
| Work on two repositories at once | Two sessions, one `run` each. [Below](#several-sessions-side-by-side). |
| Try Codex instead of Claude on a repository | A new session with `--agent codex`. [Below](#another-agent-on-the-same-repository). |
| Have Codex carry on from where Claude stopped | Bring Claude's work out first, then start Codex on it: [through the remote](#option-a-through-the-remote) or [straight from the export](#option-b-straight-from-the-export-nothing-pushed). |
| Give one agent two repositories in one session | Not possible, on purpose. [Why](#why-a-session-holds-one-repository). |

## One repository after another

This is the ordinary way to use the sandbox.

```bash
./sandbox export                 # bring the work out and read it
./sandbox push                   # if you want it on the remote
./sandbox destroy
./sandbox run https://github.com/you/next-repo.git
```

**`destroy` removes** everything the session had: its containers, its
networks, its volumes, its workspace (including its share of the disk store),
its directory of state and, with `--git-token`, the token. The next `run`
starts from nothing and shares nothing with the one before.

**`destroy` does not remove**, and the next session reuses:

- the model credentials you stored with `./sandbox login`, in your keyring;
- the images, so the next `run` starts in seconds rather than minutes;
- your settings file and your allowlist entries;
- **your exports** in `~/agent-sandbox-out/<session>/`. They are yours to
  delete when you are done with them.

**Export before you destroy.** The workspace is the only place the agent's
work exists until `export` brings it out. `destroy` does not ask.

The agent's work comes out only if it is **committed**. Tell the agent to
commit when it is done (or commit yourself from `./sandbox shell`); `export`
takes the session branch, not loose files.

A private repository needs `--git-token` again at each `run`: the last
session's token was forgotten at `destroy`.

## Several sessions side by side

Each `run` makes a separate session with a name of its own, and they do not
see each other:

```bash
# terminal 1
./sandbox run https://github.com/you/frontend.git
# terminal 2
./sandbox run https://github.com/you/backend.git
```

`run` prints the session's name early on (`creating session
asb-frontend-1a2b3c`). The name is the repository's name plus six random
characters.

**Every command other than `run` works on one session.** When there is only
one, it is that one. When there are several, the command refuses and lists
them:

```
error: there is more than one session. Set SANDBOX_SESSION to one of:
asb-frontend-1a2b3c
asb-backend-4d5e6f
```

Name the one you mean for that command:

```bash
SANDBOX_SESSION=asb-frontend-1a2b3c ./sandbox export
SANDBOX_SESSION=asb-backend-4d5e6f ./sandbox logs agent
SANDBOX_SESSION=asb-backend-4d5e6f ./sandbox destroy
```

or for every command in this terminal:

```bash
export SANDBOX_SESSION=asb-frontend-1a2b3c
./sandbox export
./sandbox destroy
unset SANDBOX_SESSION
```

There is no `list` command. To see which sessions exist:

```bash
ls -d "$XDG_RUNTIME_DIR"/agent-sandbox/asb-*
```

`./sandbox destroy --all` removes every session at once.

### What sessions side by side share

They are separate sessions, but they run on one host and under one account:

- **Memory.** Each session may take what `run` prints (about 6.6 GB with the
  defaults and a disk store, about 10.6 GB with the workspace in memory).
  `run` checks what the host has free at that moment and refuses a session
  that does not fit. Two default sessions need a host with about 14 GB.
- **Processes.** `NPROC` (default 512) is a ceiling per user id, and every
  session's containers run as the same few user ids. Raise it in your
  settings file if sessions run short of processes.
- **The disk store.** All sessions share its size (20 GB in the quickstart).
  Each session's share (`--workspace-size`, default 4 GB) is checked every 30
  seconds, so one session can fill the store in that window, and the others
  then get "no space left" until it is stopped (B33 in the
  [threat model](00-threat-model.md)).
- **The model account.** Each session counts its own `--budget`, but they all
  spend the same subscription allowance or API spend cap.
- **Codex logins.** Only one Codex renewal runs at a time on the host, so a
  second Codex session may wait a moment for the first.

## Another agent on the same repository

A session's agent is fixed when it is started: it is in the session's state
and each agent has an image of its own. To use another agent, start another
session with `--agent`.

Each agent needs its own credential, stored once (see
[03 — Credentials](03-credentials.md)):

```bash
./sandbox login --agent claude
./sandbox login --agent codex
```

### A fresh start

```bash
./sandbox run https://github.com/you/project.git --agent codex
```

This session starts from the repository as it is on the remote. It knows
nothing of any other session. You can have a Claude session and a Codex
session on the same repository at once; they are two copies, on two
branches, and `SANDBOX_SESSION` picks between them as above.

### Carrying on from another agent

A session starts from the repository **as it is when you run it**, so Codex
cannot see Claude's work until that work has come out of Claude's session.
There are two ways to do that.

Both use `--branch`. Without it, a session works on a new branch named after
itself (`agent/<session>`), starting from the repository's current commit.
With `--branch <name>` it works on the branch you name, and **if that branch
already exists it carries on from its last commit**. So
`--branch agent/<first session>` picks up exactly where the first agent
stopped, and later pushes go to the same branch.

Below, the first session is called `asb-project-1a2b3c`. Use the name your
`run` printed.

#### Option A: through the remote

Claude's branch goes to GitHub (or GitLab) first, and Codex is started from
there. Use this when the host may push: you started the first session with
`--git-token`, or the host has another git credential you accept.

```bash
# 1. Claude's session
./sandbox run https://github.com/you/project.git --git-token
#    ... work with Claude, have it commit, leave with /exit ...
./sandbox export          # read it: RUNS LATER first
./sandbox push            # agent/asb-project-1a2b3c is now on GitHub
./sandbox destroy

# 2. Codex's session, on the same branch
./sandbox run https://github.com/you/project.git --agent codex \
    --branch agent/asb-project-1a2b3c --git-token
#    ... work with Codex, have it commit, leave ...
./sandbox export          # shows only what Codex added
./sandbox push            # the same branch, moved forward
./sandbox pr              # once, at the end
./sandbox destroy
```

- The second `--git-token` is a new prompt: the first session's token was
  forgotten at its `destroy`. The same token works if it has not expired.
- If you opened the pull request after the first session, do not run `pr`
  again: `push` alone updates the open request.
- `push` never forces. If someone else moved the branch on the remote in the
  meantime, it refuses and you decide what to do.

#### Option B: straight from the export, nothing pushed

Codex is started from Claude's export on this host, with no push in between.
Use this when the host has **no git credential**, or when you want to review
both agents' work before anything reaches the remote.

`export` leaves a clean repository at
`~/agent-sandbox-out/<session>/repo.git`, and `run` takes a path. That export
is not removed by `destroy`.

```bash
# 1. Claude's session
./sandbox run https://github.com/you/project.git
#    ... work with Claude, have it commit, leave with /exit ...
./sandbox export          # read it: RUNS LATER first
./sandbox destroy         # the export in ~/agent-sandbox-out stays

# 2. Codex's session, from that export, on the same branch
./sandbox run ~/agent-sandbox-out/asb-project-1a2b3c/repo.git --agent codex \
    --branch agent/asb-project-1a2b3c
#    ... work with Codex, have it commit, leave ...
./sandbox export          # shows only what Codex added
```

This second session is named after the path, so it is called
`asb-repo-<six characters>`. Its export, in
`~/agent-sandbox-out/asb-repo-<...>/repo.git`, holds both agents' commits.

Getting the result to the remote. Pick one:

- **From your workstation, with no credential on the host** (the same way as
  in [the quickstart](01-quickstart.md#option-2-no-git-credential-on-the-host);
  `sandbox` is the SSH name set up there):

  ```bash
  # on your workstation, in your clone of the project
  git fetch sandbox:agent-sandbox-out/asb-repo-4d5e6f/repo.git agent/asb-project-1a2b3c
  git push origin FETCH_HEAD:refs/heads/agent/asb-project-1a2b3c
  ```

- **From the host, with `./sandbox push`.** Before step 2, give the first
  export the real repository's address. The second session then takes that
  as the place to push to:

  ```bash
  git --git-dir ~/agent-sandbox-out/asb-project-1a2b3c/repo.git \
      remote add origin https://github.com/you/project.git
  ```

  `push` then uses whatever git credential this host has. `--git-token`
  cannot be used here: it is for `https://` addresses, and this session was
  started from a path. Without the `remote add`, `push` would send the
  branch back into the first export, which is not what you want.

`pr` is refused for a session started from a path with no remote, since
there is nowhere to open a request. Open it in the web page instead.

> The way `run` takes in an exported repository (an existing branch is
> carried on, and the repository's `origin` decides where `push` goes) was
> checked against the real code. A whole run of Option B, with two agents on
> a real host, has not been done yet.

### Read each export before the next agent starts

The second agent works on whatever the first one left, so check the first
export before the second session starts. Read its **RUNS LATER** section
first: a lockfile, CI workflow or build script the first agent planted is
handed to the second agent along with everything else, and then to you.

Each export reviews only the commits made in its own session (the diff
starts where that session started). Before you merge, read the whole branch
against your main branch, in the pull request or on your workstation:

```bash
git diff main...agent/asb-project-1a2b3c
```

### Handing over notes

The second agent sees the code, not the first agent's conversation. If you
want it to know what was tried, ask the first agent to write a short
`HANDOFF.md` and commit it, then tell the second agent to read it. Remove the
file before you merge.

## Why a session holds one repository

The README promises "one throwaway container, one copy of one repository",
and the rest of the design relies on it:

- `export`, `push` and `pr` work on that repository's one session branch;
- `--git-relay` lets the agent push that one branch of that one repository
  and nothing else;
- a `--git-token` is meant to reach that one repository only.

Two repositories in one session would give a hostile agent, steered by
something it read in one of them, write access to the other.

If an agent really needs two repositories side by side, `run` takes a local
path, so you can combine them into one repository on your host and run that.
Then the whole thing is "the repository": it is exported and pushed as one,
and nothing separates the two parts inside the sandbox. Two sessions are
almost always the better answer.
