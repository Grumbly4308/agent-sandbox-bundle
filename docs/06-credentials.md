# 06 — Layer 3: credentials, GitHub and GitLab

> **Defends:** credential theft (threat 2), lateral movement (threat 7).

The best-protected secret is one that was never in the container. Work down this
list in order and stop at the first option that covers your workflow.

## Option A — no credentials at all (start here)

The agent writes code and commits. **You** push, from the host:

```bash
./sandbox review     # read the diff, run the secret scan
./sandbox push       # uses your normal git credentials, outside the sandbox
```

The container gets an `ANTHROPIC_API_KEY` and nothing else. There is no repo
token to steal because there is no repo token.

For the large majority of work this is the right answer, and it is what the
scaffold ships with. Only move down this page when a workflow genuinely needs
the agent to push on its own — long autonomous runs, or an agent that opens its
own pull requests.

## Option B — a scoped HTTPS token

**GitHub.** Settings → Developer settings → **Fine-grained** tokens.

- Repository access: **only select repositories** → the one repo.
- Permissions: Contents `read/write`. Add Pull requests `read/write` only if it
  should open PRs.
- Expiration: **1 day**.

**GitLab.** Project → Settings → Access tokens.

- Role `Developer`, scope `write_repository`, expiry tomorrow.

Either way, paste it into `.env` as `GIT_TOKEN`. Inside the container:

```bash
# GitHub
git push "https://x-access-token:${GIT_TOKEN}@github.com/you/project.git" HEAD

# GitLab
git push "https://oauth2:${GIT_TOKEN}@gitlab.com/you/project.git" HEAD
```

> **Classic PATs are not an acceptable substitute.** A classic PAT with `repo`
> scope grants access to *every* repository you can see. One leak and the blast
> radius is your entire account, not one project.

## Option C — an SSH deploy key

Per-repository, no account-wide reach, revocable from the repo's own settings.
This is the best option if the agent must push regularly.

```bash
ssh-keygen -t ed25519 -C "agent-sandbox" -f secrets/deploy_key -N ""
chmod 600 secrets/deploy_key
cat secrets/deploy_key.pub
```

Add the public key:

- **GitHub** — repo → Settings → Deploy keys → Add deploy key → tick **Allow
  write access**.
- **GitLab** — project → Settings → Repository → Deploy keys → tick **Grant
  write permissions**.

`secrets/` is bind-mounted read-only at `/run/secrets`, and the entrypoint
installs the key at `~/.ssh/id_ed25519` with mode 600.

### The port 22 problem, and how it's solved

There is a wrinkle worth understanding, because it is the thing that makes most
"agent behind a proxy" setups quietly fail.

The sandbox has **no direct network route** — everything goes through an HTTP
proxy. An HTTP proxy cannot carry SSH on port 22. So a deploy key that works
fine on your laptop simply hangs inside the sandbox.

Both GitHub and GitLab publish an SSH endpoint on **port 443** for exactly this
situation. The entrypoint detects a mounted key and generates the config:

```
Host github.com
  HostName ssh.github.com          # GitHub's SSH-over-443 endpoint
  Port 443
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ProxyCommand nc -X connect -x egress-proxy:3128 %h %p

Host gitlab.com
  HostName altssh.gitlab.com       # GitLab's equivalent
  Port 443
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ProxyCommand nc -X connect -x egress-proxy:3128 %h %p
```

`nc -X connect` issues an HTTP `CONNECT` through Squid, which permits it because
port 443 is in `SSL_ports` and both hostnames are covered by the default
allowlist (`.github.com`, `.gitlab.com`). From the agent's point of view,
`git push` just works.

**Host key verification.** The generated config uses
`StrictHostKeyChecking accept-new` — trust on first use. To close that window,
drop a `known_hosts` file into `profile/` and copy it in the entrypoint; GitHub
and GitLab both publish their host key fingerprints.

### The deploy key has to be readable by the container's uid

The mount is read-only and the key is `0600`, which means it is readable by
**its owning uid and nobody else**. The container runs as `HOST_UID` from
`.env`. If those differ, the entrypoint sees the file and cannot open it:

```
install: cannot open '/run/secrets/deploy_key' for reading: Permission denied
```

This happens when the key was generated with `sudo`, copied from elsewhere, or
`.env` was written by a different account than the one you are using now.

```bash
ls -la secrets/deploy_key      # owner
grep HOST_UID .env             # who the container is
id -u                          # who you are
sudo chown "$(id -u):$(id -g)" secrets/deploy_key && chmod 600 secrets/deploy_key
```

`./sandbox go` warns about this before starting, and `./sandbox doctor` checks
it explicitly.

## The model API key

Create a **separate** key with its own spend limit — not the one your other
projects use.

Anthropic Console → API keys → new key, scoped to a workspace with a limit you'd
be annoyed but not ruined by. An agent in a retry loop is the classic way to
discover what your monthly budget looks like when it is gone.

Set it as `ANTHROPIC_API_KEY` in `.env`.

## Staying logged in between sessions

`$HOME` in the container is a tmpfs, so an interactive `/login` dies with the
container and you get asked again on the next `./sandbox go`. There are three
ways out, in increasing order of how much you are trusting the host.

**1. An API key.** `ANTHROPIC_API_KEY` in `.env`. No login flow at all, and the
key has a spend limit you set. Best option for unattended runs.

**2. A saved OAuth session.** Log in once; the session is stored on the host in
`auth/` and copied into `$HOME` at every start:

```bash
./sandbox login          # run /login inside, finish in the browser, exit
./sandbox go             # and every run after this — no login prompt
./sandbox logout         # delete it again
```

Mechanically: `auth/` is bind-mounted read-write at `/run/auth`; the entrypoint
copies `.credentials.json` (the session) and `.claude.json` (account and
onboarding state, without which the CLI redoes first-run setup) into place at
start. It only ever writes *back* when `./sandbox login` sets
`SANDBOX_PERSIST_AUTH=1`, so an ordinary session cannot modify your saved login.

Be clear-eyed about the tradeoff. `auth/.credentials.json` is a live login to
your Claude account — broader than a scoped API key, and it now sits on disk
and is mounted into a container that runs model-directed code. Accordingly:

- `auth/` is `chmod 700` and in `.gitignore`
- `settings.json` denies the agent `Read(//run/auth/**)` — not a real boundary
  against a compromised process, but it keeps ordinary tool calls away from it
- do not use a saved session for unattended runs; use an API key with a limit
- `./sandbox logout` clears the file; revoke the session in your Claude account
  settings if the machine is shared

**3. A long-lived token.** If your CLI version provides one — check
`claude setup-token` — put the result in `.env` as `CLAUDE_CODE_OAUTH_TOKEN`.
The compose file already passes it through. Same caveats as (2): treat it as a
password, prefer an API key where a spend limit matters.

## Self-hosted GitLab or GitHub Enterprise

Two extra steps:

```bash
./sandbox allow gitlab.internal.example.com
```

If the instance offers SSH on a non-standard port, Squid must be told to allow
`CONNECT` to that port — it refuses anything not listed. In `proxy/squid.conf`:

```
acl SSH_ports port 2222
acl Safe_ports port 2222
http_access deny CONNECT !SSL_ports !SSH_ports    # replaces the !SSL_ports line
```

and in `.env`, so the entrypoint writes a matching `~/.ssh/config` block:

```
GIT_SSH_HOST=gitlab.internal.example.com
GIT_SSH_PORT=2222
```

Every port you open here is another way out of the sandbox. If you push from
the host with `./sandbox push` — the default, and the recommendation — you do
not need any of this.

Remember that the *clone URL* also needs the `ssh://` form to carry a port;
`git@host:2222/group/repo.git` means port 22 and a path beginning `2222/`. See
`08-troubleshooting.md`.

If it uses an internal CA, copy the root certificate into the image
(`COPY ca.crt /usr/local/share/ca-certificates/` + `update-ca-certificates` in
`agent/Dockerfile`) — the container has no access to your host's trust store.

## Rotate, every time

`./sandbox destroy` ends by printing exactly which credentials the session used
and where to revoke them:

```
Now do the part no script can do for you:
  - revoke GIT_TOKEN        (GitHub: Settings > Developer settings > Fine-grained tokens)
  - revoke ANTHROPIC_API_KEY (console.anthropic.com)
  - delete secrets/deploy_key and the deploy key in the repo's settings
```

Do it. A one-day token you forget to revoke is a one-day token. A one-day token
you *renew out of habit* is a permanent credential wearing a disguise.

## Scan before anything leaves

`./sandbox review` runs `gitleaks` over the worktree (falling back to a grep if
it isn't installed) and lists untracked files. This matters more than it looks:
the egress allowlist controls destinations, not content, and an agent with push
access to an allowlisted host can carry a secret out in a commit. The scan is
the check that catches it.

Next: [07 — Layer 4, the profile](07-profile.md).
