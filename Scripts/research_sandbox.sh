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
# in its own Linux VM with a read-only root, no Linux capabilities, a non-root
# user and no Mac folders mounted. Its port is published to the Mac's loopback
# address only. See docs/WEB_RESEARCH.md.

set -euo pipefail

image="tuff-web-research:latest"
name="tuff-web-research"
port="${TUFF_RESEARCH_SANDBOX_PORT:-9000}"
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
    container build -t "$image" "$context"
    ;;
  start)
    require_container
    container stop "$name" >/dev/null 2>&1 || true
    container delete "$name" >/dev/null 2>&1 || true
    run_options=(
      --detach --rm --name "$name"
      --read-only --tmpfs /tmp
      --cap-drop ALL --user 10001:10001
      --cpus 2 --memory 1G
      --publish "127.0.0.1:$port:9000"
    )
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

    echo "Direct connections from inside the VM:"
    for target in "$gateway:8080" "$gateway:22" "$gateway:5000"; do
      if container exec "$name" python3 -c "
import socket, sys
host, port = sys.argv[1].rsplit(':', 1)
try:
    socket.create_connection((host, int(port)), timeout=3).close()
except OSError:
    sys.exit(1)
" "$target" >/dev/null 2>&1; then
        if [[ "$target" == *:8080 ]]; then
          fail "the VM can open a connection to the TUFF server port at $target"
        else
          # Not a sandbox failure: some Mac service listens on every interface.
          # Fetches still refuse it, but the VM itself can connect.
          echo "  warn  the VM can connect to a Mac service at $target; consider turning it off"
        fi
      else
        pass "the VM cannot connect to the Mac at $target"
      fi
    done

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
