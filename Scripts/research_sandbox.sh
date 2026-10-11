#!/usr/bin/env bash
# Builds and runs the web research sandbox with Apple `container`.
#
#   Scripts/research_sandbox.sh build    build the sandseek-sandbox image
#   Scripts/research_sandbox.sh start    start a fresh sandbox on 127.0.0.1:9100 (SANDSEEK_SANDBOX_PORT)
#   Scripts/research_sandbox.sh stop     stop and remove the sandbox
#   Scripts/research_sandbox.sh status   report whether the sandbox answers
#   Scripts/research_sandbox.sh selftest check that the sandbox refuses the Mac,
#                                        the local network and metadata addresses
#
# The sandbox is the only part of `sandseek` with internet access. It runs
# in its own Linux VM with a read-only root and no Mac folders mounted. A
# firewall inside the VM lets it reach public internet addresses, plus DNS on
# the Mac when the Mac is its name server, and accepts new inbound connections
# on port 9100 only, from the VM's default gateway (the address the published
# port connects from; anything that can send from that address, such as
# processes on the Mac, can still reach 9100). The
# server runs as a non-root user with no Linux capabilities. Its port is
# published to the Mac's loopback address only. See docs/SECURITY.md.
#
# Each `start` makes a new random secret, writes it to the file below (mode
# 0600, in a folder only you can write to) and hands it to the sandbox, which signs its answers
# with it, so SandSeek can tell the sandbox from another program on the port.
# `stop` leaves the file, so that program is still told apart when the sandbox
# is not running.

set -euo pipefail
# No file name expansion: $dns_servers is split into words below, not matched.
set -f

# The old TUFF_RESEARCH_ names are ignored now; say so instead of silently
# using the defaults. This does not stop the script.
for old_name in TUFF_RESEARCH_SANDBOX_PORT TUFF_RESEARCH_DNS; do
  if [[ -n "${!old_name+x}" ]]; then
    echo "warning: $old_name is the old name and is ignored; use SANDSEEK_${old_name#TUFF_RESEARCH_}" >&2
  fi
done

image="sandseek-sandbox:latest"
name="sandseek-sandbox"
port="${SANDSEEK_SANDBOX_PORT:-9100}"
# DNS servers for the VM, space-separated. Unset, the VM asks the Mac, which
# uses the same DNS as the rest of the Mac; set it (for example to
# "1.1.1.1 9.9.9.9") to use public resolvers instead.
dns_servers="${SANDSEEK_DNS:-}"
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
context="$script_directory/../Sandbox"
# Where the secret goes. SandSeek reads the same file (ResearchSandboxSecret in
# Sources/SandSeekCore/ResearchSandboxSigning.swift); change both together.
secret_file="$HOME/Library/Application Support/TUFF/web-sandbox.secret"

# SANDSEEK_SANDBOX_PORT and SANDSEEK_DNS go into `container run` arguments;
# a typo gives a confusing error from deep inside it, so check the form first.
check_port() {
  if ! [[ "$port" =~ ^[1-9][0-9]{1,4}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    echo "SANDSEEK_SANDBOX_PORT must be a port number from 10 to 65535, not: $port" >&2
    exit 2
  fi
  port=$((10#$port))
}

check_dns() {
  local server octet
  for server in $dns_servers; do
    if [[ "$server" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      for octet in ${server//./ }; do
        (( 10#$octet <= 255 )) || { echo "SANDSEEK_DNS: not an IPv4 address: $server" >&2; exit 2; }
      done
    elif ! [[ "$server" =~ ^[0-9a-fA-F:]{2,39}$ && "$server" == *:*:* && "$server" != *:::* ]]; then
      echo "SANDSEEK_DNS must list IPv4 or IPv6 addresses separated by spaces, not: $server" >&2
      exit 2
    fi
  done
}

require_container() {
  if ! command -v container >/dev/null 2>&1; then
    echo "Apple container is not installed; see https://github.com/apple/container" >&2
    exit 1
  fi
  container system status >/dev/null 2>&1 || container system start
}

# Makes a new secret (32 random bytes as 64 hex characters), writes it to
# $secret_file and prints it. The file is written to a temporary file in the
# same folder, given mode 0600 and then renamed over the old one, so a reader
# sees the old secret or the new one and never half of it. Everything here is a
# shell builtin or reads /dev/urandom, so the secret is never in a command line.
new_secret() {
  local folder modes secret temporary
  folder="$(dirname -- "$secret_file")"
  # A missing folder is made with mode 0700. An existing one (TUFF's own, for
  # example) is never changed: it only has to be yours, not a symlink, and not
  # writable by group or others, so that nobody else can replace the file.
  [[ -e "$folder" || -L "$folder" ]] || mkdir -p -m 700 -- "$folder"
  if [[ -L "$folder" || ! -d "$folder" || ! -O "$folder" ]]; then
    echo "$folder is not a folder of yours; not writing the sandbox secret" >&2
    return 1
  fi
  modes="$(ls -ld -- "$folder")"
  modes="${modes%% *}"
  if [[ "${modes:5:1}" == w || "${modes:8:1}" == [wtT] ]]; then
    echo "$folder can be written to by others (${modes}); not writing the sandbox secret. Run chmod go-w on it" >&2
    return 1
  fi
  if [[ -d "$secret_file" ]]; then
    echo "$secret_file is a folder; not writing the sandbox secret" >&2
    return 1
  fi
  secret="$(LC_ALL=C od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
  if [[ ! "$secret" =~ ^[0-9a-f]{64}$ ]]; then
    echo "could not make a random secret" >&2
    return 1
  fi
  temporary="$(umask 077 && mktemp -- "$folder/.web-sandbox.secret.XXXXXX")" || return 1
  if ! { printf '%s' "$secret" >"$temporary" \
         && chmod 600 -- "$temporary" \
         && mv -f -- "$temporary" "$secret_file"; }; then
    rm -f -- "$temporary"
    echo "could not write $secret_file" >&2
    return 1
  fi
  printf '%s' "$secret"
}

health() {
  curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1
}

health_json() {
  curl -fsS --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null
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
    # A trace would print the secret (`secret=...`, and the `container run`
    # line with it), so do not run under `bash -x` or `set -x`.
    if [[ $- == *x* ]]; then
      echo "not starting with xtrace on: the trace would print the sandbox secret" >&2
      exit 1
    fi
    check_port
    check_dns
    require_container
    container stop "$name" >/dev/null 2>&1 || true
    container delete "$name" >/dev/null 2>&1 || true
    # The entrypoint starts as root with these four capabilities only, to load
    # the firewall; the server then gives them all up and runs as user 10001.
    # The secret goes in by name only (`--env NAME`, no value): the container
    # tool takes the value from this script's environment, so it never appears
    # in a command line, where other users would see it in `ps`.
    run_options=(
      --detach --rm --name "$name"
      --env SANDSEEK_SANDBOX_SECRET
      --read-only --tmpfs /tmp
      --cap-drop ALL --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID --cap-add SETPCAP
      --ulimit nproc=512
      --cpus 2 --memory 1G
      --publish "127.0.0.1:$port:9100"
    )
    for server in $dns_servers; do
      run_options+=(--dns "$server")
    done
    if [[ -n "${SEARXNG_URL:-}" ]]; then
      run_options+=(--env "SEARXNG_URL=$SEARXNG_URL")
    fi
    # The file is complete before the sandbox starts listening. The old VM is
    # gone by now, so nothing is signing with the previous secret.
    secret="$(new_secret)" || exit 1
    SANDSEEK_SANDBOX_SECRET="$secret" container run "${run_options[@]}" "$image" >/dev/null
    unset secret
    # The entrypoint refuses to start when it finds no default gateway (see
    # Sandbox/entrypoint.sh) or cannot load the firewall, and `--rm` deletes the
    # container then, so keep the last non-empty log (a later "not found" error
    # must not replace it) to show below. The two flags are set from the whole
    # log, since the last five lines shown may not contain those lines.
    startup_log=""
    refused=0 firewall_loaded=0 listening=0 gone=0 firewall_line=""
    polls_after_listening=0
    # A hung curl or `container` call must not outlast the app's start timeout
    # (180 s), so the poll counts below also sit under an overall deadline.
    deadline=$((SECONDS + 120))
    for _ in $(seq 1 50); do
      if health; then
        reply="$(health_json || true)"
        if [[ "$reply" != *'"signed": true'* ]]; then
          echo "the sandbox started but is not signing its answers; the container did not get the secret (see docs/SECURITY.md). Stopping it." >&2
          container stop "$name" >/dev/null 2>&1 || true
          container delete "$name" >/dev/null 2>&1 || true
          exit 1
        fi
        echo "web research sandbox ready at http://127.0.0.1:$port"
        exit 0
      fi
      if out="$(container logs "$name" 2>/dev/null)" && [[ -n "$out" ]]; then
        startup_log="$(tail -n 5 <<<"$out")"
        [[ "$out" == *"refusing to start"* ]] && refused=1
        if [[ "$out" == *"firewall: inbound port 9100 accepted"* ]]; then
          firewall_loaded=1
          firewall_line="$(grep -m1 'firewall: inbound port 9100 accepted' <<<"$out")"
        fi
        [[ "$out" == *"SandSeek sandbox listening on"* ]] && listening=1
      fi
      # Stop early when the entrypoint refused to start or the container is gone.
      (( refused )) && break
      if remaining="$(container list --all --quiet 2>/dev/null)" \
          && ! grep -qxF "$name" <<<"$remaining"; then
        gone=1
        break
      fi
      # The server listens but nothing reached it: each poll can wait 2 s, so
      # give it a few more tries, not the whole 50. (Before the server listens,
      # a slow start is normal: the firewall, DNS rules and imports come first.)
      if (( listening )); then
        polls_after_listening=$((polls_after_listening + 1))
        (( polls_after_listening < 10 )) || break
      fi
      (( SECONDS < deadline )) || break
      sleep 0.2
    done
    if [[ -n "$startup_log" ]]; then
      echo "sandbox log:" >&2
      printf '%s\n' "$startup_log" >&2
    fi
    if (( refused || gone )); then
      # `--rm` has deleted the container, so `container logs` has nothing.
      debug_command="container run"
      for option in "${run_options[@]}"; do
        case "$option" in
          --rm|--detach) ;;
          # The value may hold credentials and this goes into error messages.
          SEARXNG_URL=*) debug_command+=" SEARXNG_URL=<your value>" ;;
          *) debug_command+=" $(printf '%q' "$option")" ;;
        esac
      done
      debug_command+=" $image"
      # --env SANDSEEK_SANDBOX_SECRET above carries the name only, never the
      # value; the container tool takes the value from its own environment.
      # Printed as a prefix to this one command, so the secret does not stay
      # exported in the terminal. The value itself is never printed.
      debug_command="SANDSEEK_SANDBOX_SECRET=\"\$(cat $(printf '%q' "$secret_file"))\" $debug_command"
      echo "the sandbox container exited and was removed (it runs with --rm)." >&2
      echo "To see why, run it once in the foreground without --rm (the prefix hands it the secret for this one command, so it signs its answers as the real start does): $debug_command" >&2
    else
      echo "sandbox started but did not answer on 127.0.0.1:$port; see: container logs $name" >&2
      if (( firewall_loaded && listening )); then
        echo "the server is listening, and the log said: $firewall_line" >&2
        echo "(if the published port connects from another address than that gateway, the server is unreachable; see docs/SECURITY.md)" >&2
      fi
    fi
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
    check_port
    if health; then
      echo "web research sandbox is answering at http://127.0.0.1:$port"
    else
      echo "web research sandbox is not answering at http://127.0.0.1:$port" >&2
      exit 1
    fi
    ;;
  selftest)
    check_port
    require_container
    health || { echo "start the sandbox first: $0 start" >&2; exit 1; }
    failures=0
    pass() { echo "  ok    $1"; }
    fail() { echo "  FAIL  $1" >&2; failures=$((failures + 1)); }

    echo "Fetches the sandbox must refuse:"
    # The same helper the entrypoint uses for the inbound rule.
    gateway="$(container exec "$name" env -u SANDSEEK_SANDBOX_SECRET python3 /app/default_gateway.py)" \
      || { echo "  FAIL  could not read the VM's default gateway (rebuild the image?)" >&2; exit 1; }
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
    if container exec "$name" env -u SANDSEEK_SANDBOX_SECRET nft list table inet sandseek_sandbox >/dev/null 2>&1; then
      pass "the firewall is loaded"
    else
      fail "the firewall is not loaded"
    fi
    # -nn prints the port as a number (nft would otherwise print a service name).
    # This reads the loaded rules; it does not send a packet from another
    # address, so it shows that the rule names the gateway, not that other
    # senders are refused.
    input_rules="$(container exec "$name" env -u SANDSEEK_SANDBOX_SECRET nft -nn list chain inet sandseek_sandbox input 2>/dev/null || true)"
    if grep -q 'hook input.*policy drop' <<<"$input_rules" \
        && grep -qF "ip saddr $gateway tcp dport 9100 accept" <<<"$input_rules" \
        && [[ "$(grep -c 'dport 9100' <<<"$input_rules")" == 1 ]]; then
      pass "the firewall drops new inbound connections except to port 9100 from the gateway $gateway"
    else
      fail "the firewall's input chain is missing or not as expected: ${input_rules:0:200}"
    fi
    privileges="$(container exec "$name" env -u SANDSEEK_SANDBOX_SECRET python3 -c '
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
      if container exec --user 10001:10001 "$name" env -u SANDSEEK_SANDBOX_SECRET python3 -c "
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
    open_ports="$(container exec --user 10001:10001 "$name" env -u SANDSEEK_SANDBOX_SECRET python3 -c '
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
    if container exec "$name" env -u SANDSEEK_SANDBOX_SECRET awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null \
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

    echo "The sandbox must sign its answers:"
    if [[ ! -e "$secret_file" ]]; then
      if [[ "$(health_json || true)" == *'"signed": true'* ]]; then
        fail "the sandbox signs its answers but $secret_file does not exist"
      else
        echo "  warn  no secret file and an unsigned sandbox: nothing to check"
      fi
    else
      # A fresh nonce, the answer's headers and body, and the checker that
      # knows the formula (Scripts/verify_sandbox_signature.py). It reads the
      # secret from the file itself; nothing secret is printed or in a command line.
      # The temporary files hold the public /health answer only.
      nonce="$(LC_ALL=C od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
      work="$(mktemp -d)"
      if [[ "$nonce" =~ ^[0-9a-f]{64}$ ]] \
          && curl -sS --max-time 5 -H "X-Sandbox-Nonce: $nonce" -D "$work/headers" \
              -o "$work/body" "http://127.0.0.1:$port/health" \
          && verdict="$(python3 "$script_directory/verify_sandbox_signature.py" \
              "$secret_file" "$nonce" - "$work/headers" "$work/body" 2>&1)"; then
        pass "/health is signed for a fresh nonce ($verdict)"
      else
        fail "/health is not signed correctly for a fresh nonce: ${verdict:-no valid answer}"
      fi
      rm -rf -- "$work"
      unset nonce work verdict
    fi

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
