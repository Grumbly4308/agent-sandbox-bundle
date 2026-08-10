# The egress gate. This is a stock Squid with a default-deny allowlist — no
# third-party image, nothing to trust but Alpine's package signing.
FROM alpine:3.20

RUN apk add --no-cache squid \
 && mkdir -p /var/cache/squid /var/log/squid /var/run/squid \
 && chown -R squid:squid /var/cache/squid /var/log/squid /var/run/squid

COPY squid.conf /etc/squid/squid.conf
# allowlist.txt is bind-mounted over this at runtime so you can edit the
# allowlist and reload without a rebuild. The baked copy is the fallback.
COPY allowlist.txt /etc/squid/allowlist.txt

EXPOSE 3128

# Run AS squid from the first instruction rather than starting as root and
# dropping privileges at runtime. Squid opens its log targets after the drop,
# and /dev/stdout belongs to the identity the container started with, so a
# root->squid drop ends in:
#     FATAL: Cannot open '/dev/stdout' for writing.
# Starting unprivileged removes the drop, and with it the failure.
USER squid

# -N keeps it in the foreground so Docker owns the lifecycle; -d 1 sends logs
# to the console.
CMD ["squid", "-N", "-d", "1", "-f", "/etc/squid/squid.conf"]
