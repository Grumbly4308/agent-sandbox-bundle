# 02 — Egress: what the agent can reach

The agent's container is attached to one network, and that network has no
route to anywhere (barrier B12). Two doors lead out of it:

- the **proxy** (Squid), for everything that is not a model call;
- the **credential sidecar**, for model calls, which itself goes out through
  the proxy.

This page is about the proxy. The rules below are barriers B20 and B21 in the
[threat model](00-threat-model.md).

## What the proxy allows

Default deny. In order:

1. A destination written as a bare IP address is refused. (So the proxy never
   has to look anything up for a destination nobody named.)
2. A request from any address other than the agent's, the sidecar's or the git
   relay's is refused. A database started with `--service` gets nothing.
3. Only `CONNECT` to port 443, which is how an HTTPS connection is opened
   through a proxy. Plaintext port 80 is closed.
4. The agent may reach the hosts on its list. The sidecar may reach the model
   vendor's hosts. **The agent may not reach the vendor's hosts at all**, so it
   cannot use somebody else's API key to send your code to the vendor under
   another account.
5. A name that is on a list but resolves to a private or loopback address is
   refused.
6. Everything else is refused.

There is no TLS interception. For HTTPS the proxy sees the host name the agent
asked for and nothing else: not the path, not the size, not the content. That
is a decision, not an omission: intercepting TLS would mean a certificate
authority inside the container and a plaintext copy of the traffic.

## What is on the list by default

`policy/allowlist.base.txt`, three hosts:

| Host | Why |
|---|---|
| `registry.npmjs.org` | `npm install`. It also accepts publishes: see the warning below. |
| `pypi.org` | `pip install`: the index. |
| `files.pythonhosted.org` | `pip install`: the files. |

Each agent adds its own in `agents/<name>/allowlist.txt`. For all three shipped
agents the agent's own section is empty: everything their CLIs try to reach
besides the model API is optional, and they work with it refused.

**`github.com` is not on the list.** Your repository arrives as a file, not by
a clone from inside, so the agent does not need it; and GitHub accepts pushes.

## Adding a host

```bash
./sandbox allow docs.example.com --reason "API docs the tests quote"
./sandbox allow docs.example.com --reason "..." --until 2026-12-31
./sandbox allow registry.example.com:8443 --reason "our private registry"
./sandbox allow --preset github-downloads --reason "build fetches source archives"
./sandbox deny docs.example.com
```

- It applies to running sessions at once and to every later one. Nothing is
  rebuilt and nothing restarts.
- The reason is required and is stored next to the entry.
- With `--until`, the entry stops being used after that date.
- Your entries live in `~/.config/agent-sandbox/allowlist.local`, not in this
  repository.

### The GitHub download preset

`--preset github-downloads` adds three hosts that only serve downloads:
`codeload.github.com`, `objects.githubusercontent.com` and
`raw.githubusercontent.com`. It does not make `git clone` from GitHub work,
and it does not cover the usual link to a release file, which starts with a
redirect from `github.com` itself.

### URLs

```bash
./sandbox allow --url https://example.com/docs/ --reason "..."
```

For an `https://` URL **only the host name is enforced**; the command says so
when you run it. A path rule is only possible for plaintext `http://`, where
the proxy can see the path. Such a rule opens that path prefix and nothing else
on port 80.

## What cannot be added

`policy/never-allow.txt` lists hosts that `allow` refuses outright: shared
storage (`storage.googleapis.com`, bare `amazonaws.com`), tunnels (`ngrok`),
paste sites, webhook catchers. On those, a host name says nothing about who is
on the other end. A pattern wide enough to cover one of them is refused too.

The model vendor's hosts cannot be added to the agent's list either.

## The warning that matters

The proxy checks **who** the agent talks to, not **what** it says. A host that
accepts uploads is a way out for your whole workspace to anyone who brings an
account of their own: injected instructions can carry the attacker's GitHub or
npm token. `allow` warns you when you add such a host. `registry.npmjs.org` is
one, and it is on the default list because `npm install` cannot work without
it.

## Watching it

```bash
./sandbox logs proxy
```

One line per request, allowed or denied. `TCP_DENIED/403` is the proxy doing
its job, and the line names the host the agent wanted, which is usually all you
need to decide whether to allow it.

## DNS

The agent has no resolver (barrier B14). Its network has no name service, and
the resolver file in its image is empty. It reaches the proxy and the sidecar
by address: nothing inside a session is found by name. Names are resolved by
the proxy, and only after they have matched a list.

## The host's own services

A container network normally has a "gateway" address that belongs to the host,
and through it a container can reach anything the host listens on: SSH, a
development server, a database. Here (barrier B13):

- Podman runs as your user, and its networks are kept apart from the host's
  own. The host's services are not listening there.
- The agent's network is created with its name service off. Today Podman then
  gives it no gateway address at all. `./sandbox verify` checks this each time
  and does not assume it.
- Podman normally writes a line into every container's `/etc/hosts` naming
  your host and giving one of its addresses. Here it writes no `/etc/hosts`
  at all: the agent sees the one in its image, which names only `localhost`.

If `verify` ever reports that something answers at the gateway address, the
host-side rule that closes it is, as root:

```bash
# nftables: drop everything arriving from the sandbox's bridge that is
# addressed to the host itself. Replace podman1 with the interface name
# `podman network inspect <session>-sandbox` reports.
nft add table inet agent_sandbox
nft add chain inet agent_sandbox input '{ type filter hook input priority -10 ; policy accept ; }'
nft add rule inet agent_sandbox input iifname "podman1" drop
```

It has to be in the `input` hook: the traffic is addressed to the host, not
passing through it. This rule has not been tested by this project, because
under rootless Podman the situation it guards against does not arise.

Next: [03 — Credentials](03-credentials.md).
