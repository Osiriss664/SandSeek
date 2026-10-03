#!/usr/bin/env bash
# Builds and runs the web research sandbox with Apple `container`.
#
#   Scripts/research_sandbox.sh build    build the tuff-web-research image
#   Scripts/research_sandbox.sh start    start a fresh sandbox on 127.0.0.1:9000 (TUFF_RESEARCH_SANDBOX_PORT)
#   Scripts/research_sandbox.sh stop     stop and remove the sandbox
#   Scripts/research_sandbox.sh status   report whether the sandbox answers
#   Scripts/research_sandbox.sh selftest check that the sandbox refuses the Mac,
#                                        the local network and metadata addresses
#
# The sandbox is the only part of `tuff research` with internet access. It runs
# in its own Linux VM with a read-only root and no Mac folders mounted. A
# firewall inside the VM lets it reach public internet addresses, plus DNS on
# the Mac when the Mac is its name server, and the
# server runs as a non-root user with no Linux capabilities. Its port is
# published to the Mac's loopback address only. See docs/WEB_RESEARCH.md.

set -euo pipefail

image="tuff-web-research:latest"
name="tuff-web-research"
port="${TUFF_RESEARCH_SANDBOX_PORT:-9000}"
# DNS servers for the VM, space-separated. Unset, the VM asks the Mac, which
# uses the same DNS as the rest of the Mac; set it (for example to
# "1.1.1.1 9.9.9.9") to use public resolvers instead.
dns_servers="${TUFF_RESEARCH_DNS:-}"
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
context="$script_directory/../Sandbox/web-research"

require_container() {
  if ! command -v container >/dev/null 2>&1; then
    echo "Apple container is not installed; see https://github.com/apple/container" >&2
    exit 1
  fi
  container system status >/dev/null 2>&1 || container system start
}

health() {
  curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1
}

case "${1:-}" in
  build)
    require_container
    # `container build` starts a builder VM (2 CPUs, 2 GB) that keeps running
    # afterwards. Stop it again unless it was already running before. With
    # --quiet, `container builder status` prints the builder's ID only while
    # it runs; if the check itself fails, the builder is left alone.
    builder_was_running=1
    if builder="$(container builder status --quiet 2>/dev/null)" && [[ -z "$builder" ]]; then
      builder_was_running=""
    fi
    build_status=0
    container build -t "$image" "$context" || build_status=$?
    if [[ -z "$builder_was_running" ]]; then
      container builder stop >/dev/null 2>&1 || true
    fi
    exit "$build_status"
    ;;
  start)
    require_container
    container stop "$name" >/dev/null 2>&1 || true
    container delete "$name" >/dev/null 2>&1 || true
    # The entrypoint starts as root with these four capabilities only, to load
    # the firewall; the server then gives them all up and runs as user 10001.
    run_options=(
      --detach --rm --name "$name"
      --read-only --tmpfs /tmp
      --cap-drop ALL --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID --cap-add SETPCAP
      --ulimit nproc=512
      --cpus 2 --memory 1G
      --publish "127.0.0.1:$port:9000"
    )
    for server in $dns_servers; do
      run_options+=(--dns "$server")
    done
    if [[ -n "${SEARXNG_URL:-}" ]]; then
      run_options+=(--env "SEARXNG_URL=$SEARXNG_URL")
    fi
    container run "${run_options[@]}" "$image" >/dev/null
    for _ in $(seq 1 50); do
      if health; then
        echo "web research sandbox ready at http://127.0.0.1:$port"
        exit 0
      fi
      sleep 0.2
    done
    echo "sandbox started but did not answer on 127.0.0.1:$port; see: container logs $name" >&2
    exit 1
    ;;
  stop)
    require_container
    container stop "$name" >/dev/null 2>&1 || true
    container delete "$name" >/dev/null 2>&1 || true
    if ! remaining="$(container list --all --quiet 2>/dev/null)" \
        || grep -qx "$name" <<<"$remaining"; then
      echo "could not confirm the sandbox was removed; see: container list --all" >&2
      exit 1
    fi
    echo "web research sandbox stopped"
    ;;
  status)
    if health; then
      echo "web research sandbox is answering at http://127.0.0.1:$port"
    else
      echo "web research sandbox is not answering at http://127.0.0.1:$port" >&2
      exit 1
    fi
    ;;
  selftest)
    require_container
    health || { echo "start the sandbox first: $0 start" >&2; exit 1; }
    failures=0
    pass() { echo "  ok    $1"; }
    fail() { echo "  FAIL  $1" >&2; failures=$((failures + 1)); }

    echo "Fetches the sandbox must refuse:"
    gateway="$(container exec "$name" python3 -c '
import socket, struct
for line in open("/proc/net/route").read().splitlines()[1:]:
    fields = line.split()
    if fields[1] == "00000000":
        print(socket.inet_ntoa(struct.pack("<L", int(fields[2], 16))))
        break
')"
    blocked_urls=(
      "http://$gateway/"
      "http://$gateway:8080/v1/models"
      "http://127.0.0.1:8080/v1/models"
      "http://localhost/"
      "http://[::1]/"
      "http://10.0.0.1/"
      "http://172.16.0.1/"
      "http://192.168.1.1/"
      "http://169.254.169.254/latest/meta-data/"
      "http://100.100.100.200/"
      "http://0.0.0.0/"
      "http://localtest.me/"
      "http://example.com:8080/"
      "file:///etc/passwd"
      "ftp://example.com/"
    )
    for url in "${blocked_urls[@]}"; do
      reply="$(curl -sS --max-time 20 -H 'Content-Type: application/json' \
        --data "{\"url\": \"$url\"}" "http://127.0.0.1:$port/v1/fetch")"
      code="$(printf '%s' "$reply" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error",{}).get("code",""))' 2>/dev/null || true)"
      case "$code" in
        blocked_address|blocked_port|invalid_url|dns_error) pass "$url refused ($code)" ;;
        *) fail "$url was not refused: ${reply:0:200}" ;;
      esac
    done

    echo "The VM's own protection:"
    if container exec "$name" nft list table inet tuff_sandbox >/dev/null 2>&1; then
      pass "the firewall is loaded"
    else
      fail "the firewall is not loaded"
    fi
    privileges="$(container exec "$name" python3 -c '
import glob
for path in glob.glob("/proc/[0-9]*/cmdline"):
    try:
        if b"/app/server.py" not in open(path, "rb").read().split(b"\0"):
            continue
        status = dict(l.split(":", 1) for l in open(path[:-7] + "status") if ":" in l)
    except OSError:
        continue
    caps = [n for n in ("CapPrm", "CapEff", "CapBnd", "CapAmb") if int(status[n], 16)]
    print(status["Uid"].split()[0], ",".join(caps) or "none")
    break
' 2>/dev/null || true)"
    if [[ "$privileges" == "10001 none" ]]; then
      pass "the server runs as user 10001 with no capabilities"
    else
      fail "the server's user and capabilities are not as expected: ${privileges:-not found}"
    fi

    # These run as the server's user, as code that took the server over would.
    echo "Direct connections from inside the VM, which must fail:"
    # The Mac's DNS port (53) is the one exception, when the VM uses it.
    for target in "$gateway:8080" "$gateway:22" "$gateway:5000" "$gateway:443" \
                  "192.168.1.1:80" "192.168.0.1:80" "10.0.0.1:80" "169.254.169.254:80"; do
      if container exec --user 10001:10001 "$name" python3 -c "
import socket, sys
host, port = sys.argv[1].rsplit(':', 1)
try:
    socket.create_connection((host, int(port)), timeout=3).close()
except OSError:
    sys.exit(1)
" "$target" >/dev/null 2>&1; then
        fail "the VM can open a connection to $target"
      else
        pass "the VM cannot connect to $target"
      fi
    done

    # Every TCP port on the Mac. DNS (53) may answer when the VM's name server
    # is the Mac, which is the default; nothing else may.
    echo "Every TCP port on the Mac, from inside the VM:"
    open_ports="$(container exec --user 10001:10001 "$name" python3 -c '
import socket, sys
from concurrent.futures import ThreadPoolExecutor
host = sys.argv[1]
def probe(port):
    try:
        socket.create_connection((host, port), timeout=1).close()
        return port
    except OSError:
        return None
with ThreadPoolExecutor(64) as pool:
    print(" ".join(str(p) for p in pool.map(probe, range(1, 65536)) if p))
' "$gateway" 2>/dev/null)" || open_ports="error"
    mac_dns="no"
    if container exec "$name" awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null \
        | grep -qx "$gateway"; then
      mac_dns="yes"
    fi
    case "$open_ports" in
      "")
        pass "no port on the Mac is reachable" ;;
      53)
        if [[ "$mac_dns" == "yes" ]]; then
          pass "only the Mac's DNS port (53) is reachable, as configured"
        else
          fail "the Mac's port 53 is reachable although the VM does not use the Mac for DNS"
        fi ;;
      error)
        fail "the port scan of the Mac did not run" ;;
      *)
        fail "the VM can reach these ports on the Mac: $open_ports" ;;
    esac

    echo "Requests to the sandbox API that must be refused:"
    status="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: attacker.example' \
      -H 'Content-Type: application/json' --data '{"url":"https://example.com/"}' \
      "http://127.0.0.1:$port/v1/fetch")"
    [[ "$status" == "403" ]] && pass "foreign Host header refused" || fail "foreign Host header answered $status"
    status="$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: text/plain' \
      --data '{"url":"https://example.com/"}' "http://127.0.0.1:$port/v1/fetch")"
    [[ "$status" == "415" ]] && pass "browser-style simple POST refused" || fail "simple POST answered $status"

    echo "A public page must still work:"
    if curl -fsS --max-time 30 -H 'Content-Type: application/json' \
        --data '{"url":"https://example.com/"}' "http://127.0.0.1:$port/v1/fetch" | grep -q '"text"'; then
      pass "https://example.com/ fetched"
    else
      fail "https://example.com/ could not be fetched; check the VM's internet access"
    fi

    if [[ "$failures" -gt 0 ]]; then
      echo "$failures check(s) failed" >&2
      exit 1
    fi
    echo "all sandbox checks passed"
    ;;
  *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
