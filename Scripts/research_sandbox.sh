#!/usr/bin/env bash
# Builds and runs the web research sandbox with Apple `container`.
#
#   Scripts/research_sandbox.sh build    build the tuff-web-research image
#   Scripts/research_sandbox.sh start    start a fresh sandbox on 127.0.0.1:9000 (TUFF_RESEARCH_SANDBOX_PORT)
#   Scripts/research_sandbox.sh stop     stop and remove the sandbox
#   Scripts/research_sandbox.sh status   report whether the sandbox answers
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
  *)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
