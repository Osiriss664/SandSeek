#!/bin/sh
# Loads the VM's firewall (outbound and inbound), adds the Mac's own addresses
# to it, then starts the server, which drops root
# and every capability before it serves anything. Refuses to start without
# the firewall.
set -eu
# Inbound port 9100 is accepted from the VM's default gateway only, the address
# `container run --publish` connects from. Read it from the routing table
# (the network may take a moment to come up), check it again here, and refuse
# to start without it rather than open 9100 to every address.
gateway=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  gateway="$(python3 /app/default_gateway.py 2>/dev/null)" && break
  gateway=""
  sleep 0.5
done
if [ -z "$gateway" ]; then
  python3 /app/default_gateway.py >&2 || true
  echo "no usable default gateway; cannot restrict port 9100 to it, refusing to start" >&2
  exit 1
fi
# Exactly four dot-separated groups of one to three digits.
if [ "$(expr "x$gateway" : 'x[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}$')" = 0 ]; then
  echo "default gateway '$gateway' is not an IPv4 address; refusing to start" >&2
  exit 1
fi
if ! nft -D "gateway=$gateway" -f /app/firewall.nft; then
  echo "could not load the sandbox firewall; refusing to start" >&2
  exit 1
fi
echo "firewall: inbound port 9100 accepted from the default gateway $gateway only" >&2
# The Mac's own interface addresses, one per line, from the file the launcher
# writes into the secret folder. The private ranges in the firewall do not
# cover a public IPv4 or global IPv6 address of the Mac, so each one goes into
# the set of its family (blocked4 or blocked6, see firewall.nft), and
# server.py refuses them again. The file is read strictly: a missing file or
# anything in it that is not an IP address stops the start, since a hole in
# this list would be silent. The addresses are not secret.
blocked_file=/run/sandseek-sandbox/blocked-addresses
if [ ! -f "$blocked_file" ] || [ -L "$blocked_file" ]; then
  echo "the list of the Mac's addresses ($blocked_file) is missing; the launcher script and this image do not match; refusing to start" >&2
  exit 1
fi
rules="$(python3 - "$blocked_file" <<'PY'
import ipaddress, re, sys
with open(sys.argv[1], "rb") as handle:
    data = handle.read(65537)
if len(data) > 65536:
    sys.exit("the list is longer than 65536 bytes")
found = set()
for part in re.split(r"[,\r\n\t ]+", data.decode("ascii")):
    if not part:
        continue
    if "%" in part:
        sys.exit(f"an address with a zone id is not accepted: {part[:64]!r}")
    ip = ipaddress.ip_address(part)
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    found.add(ip)
if not found or len(found) > 256:
    sys.exit(f"{len(found)} addresses; one to 256 are expected")
for ip in sorted(found, key=lambda a: (a.version, a.packed)):
    print(ip.version, ip)
PY
)" || { echo "the list of the Mac's addresses cannot be read; refusing to start" >&2; exit 1; }
if [ -z "$rules" ]; then
  echo "the list of the Mac's addresses is empty; refusing to start" >&2
  exit 1
fi
# The here-document, not a pipe, keeps a failing nft inside this shell, so
# set -e stops the start.
blocked_count=0
while read -r family address; do
  [ -n "$address" ] || continue
  nft add element inet sandseek_sandbox "blocked$family" "{ $address }"
  blocked_count=$((blocked_count + 1))
done <<RULES
$rules
RULES
echo "firewall: $blocked_count of the Mac's own addresses refused" >&2
# The VM's DNS servers. By default that is the Mac, which forwards to the
# same DNS the rest of the Mac uses; the firewall refuses the Mac, so its
# address gets an exception for DNS (port 53) only. Public resolvers set
# with SANDSEEK_DNS are allowed anyway and need no exception.
for server in $(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf); do
  family="$(python3 -c 'import ipaddress, sys; print("ip6" if ipaddress.ip_address(sys.argv[1]).version == 6 else "ip")' "$server")" \
    || { echo "unreadable nameserver $server; refusing to start" >&2; exit 1; }
  nft insert rule inet sandseek_sandbox output "$family" daddr "$server" udp dport 53 accept
  nft insert rule inet sandseek_sandbox output "$family" daddr "$server" tcp dport 53 accept
done
# A SearXNG instance is the operator's own service and usually sits on a
# private address, so it gets the one exception: its address and port only.
if [ -n "${SEARXNG_URL:-}" ]; then
  rule="$(python3 - "$SEARXNG_URL" <<'PY'
import ipaddress, socket, sys, urllib.parse
parts = urllib.parse.urlsplit(sys.argv[1])
port = parts.port or (443 if parts.scheme == "https" else 80)
address = socket.getaddrinfo(parts.hostname, port, type=socket.SOCK_STREAM)[0][4][0]
family = "ip6" if ipaddress.ip_address(address).version == 6 else "ip"
print(f"{family} daddr {address} tcp dport {port} accept")
PY
)" || { echo "could not resolve SEARXNG_URL; refusing to start" >&2; exit 1; }
  # Inserted first, ahead of the rules that refuse private addresses.
  nft insert rule inet sandseek_sandbox output $rule
fi
exec python3 /app/server.py
