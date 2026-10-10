#!/bin/sh
# Loads the VM's outbound firewall, then starts the server, which drops root
# and every capability before it serves anything. Refuses to start without
# the firewall.
set -eu
if ! nft -f /app/firewall.nft; then
  echo "could not load the sandbox firewall; refusing to start" >&2
  exit 1
fi
# The VM's DNS servers. By default that is the Mac, which forwards to the
# same DNS the rest of the Mac uses; the firewall refuses the Mac, so its
# address gets an exception for DNS (port 53) only. Public resolvers set
# with TUFF_RESEARCH_DNS are allowed anyway and need no exception.
for server in $(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf); do
  family="$(python3 -c 'import ipaddress, sys; print("ip6" if ipaddress.ip_address(sys.argv[1]).version == 6 else "ip")' "$server")" \
    || { echo "unreadable nameserver $server; refusing to start" >&2; exit 1; }
  nft insert rule inet tuff_sandbox output "$family" daddr "$server" udp dport 53 accept
  nft insert rule inet tuff_sandbox output "$family" daddr "$server" tcp dport 53 accept
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
  nft insert rule inet tuff_sandbox output $rule
fi
exec python3 /app/server.py
