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
# Each `start` makes a new random secret and writes it to a file (mode 0600, in
# a folder only you can write to). The folder is mounted read-only into the VM,
# and the sandbox reads the secret from it once, when it starts. Every request
# to the sandbox must be signed with the secret, and every answer is signed
# with it too, so SandSeek can tell the sandbox from another program on the
# port. The secret is in no environment variable and no command line. `stop`
# deletes the file: no secret means the sandbox is not running.

set -euo pipefail
# No file name expansion: $dns_servers is split into words below, not matched.
set -f

# A line break for ${...} patterns below: bash 3.2 (macOS /bin/bash) is not
# reliable with $'\n' written inside them.
nl=$'\n'

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
# The folder, not the file, is mounted into the VM, at the path below.
secret_folder="$HOME/Library/Application Support/SandSeek/sandbox"
secret_file="$secret_folder/secret"
vm_secret_folder="/run/sandseek-sandbox"
# SandSeek 0.1.0 wrote its secret here, in TUFF's folder; it is not TUFF's.
old_secret_file="$HOME/Library/Application Support/TUFF/web-sandbox.secret"

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

# Makes a new secret (32 random bytes as 64 hex characters) and writes it to
# $secret_file. The file is written to a temporary file in the same folder,
# given mode 0600 and then renamed over the old one, so a reader sees the old
# secret or the new one and never half of it. Everything here is a shell
# builtin or reads /dev/urandom, so the secret is never in a command line. The
# folder is made with mode 0700; an existing one only has to be yours, not a
# symlink, and not writable by group or others, so that nobody else can replace
# the file. Its path goes into `--mount`, which splits on commas, so a comma or
# a line break in it is refused.
write_secret() {
  local modes secret temporary
  if [[ "$secret_folder" == *,* || "$secret_folder" == *"$nl"* ]]; then
    echo "the sandbox secret folder's path has a comma or a line break in it; not writing the sandbox secret" >&2
    return 1
  fi
  [[ -e "$secret_folder" || -L "$secret_folder" ]] || mkdir -p -m 700 -- "$secret_folder"
  if [[ -L "$secret_folder" || ! -d "$secret_folder" || ! -O "$secret_folder" ]]; then
    echo "$secret_folder is not a folder of yours; not writing the sandbox secret" >&2
    return 1
  fi
  modes="$(ls -ld -- "$secret_folder")"
  modes="${modes%% *}"
  if [[ "${modes:5:1}" == w || "${modes:8:1}" == [wtT] ]]; then
    echo "$secret_folder can be written to by others (${modes}); not writing the sandbox secret. Run chmod go-w on it" >&2
    return 1
  fi
  chmod 700 "$secret_folder"
  if [[ -d "$secret_file" ]]; then
    echo "$secret_file is a folder; not writing the sandbox secret" >&2
    return 1
  fi
  secret="$(LC_ALL=C od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
  if [[ ! "$secret" =~ ^[0-9a-f]{64}$ ]]; then
    echo "could not make a random secret" >&2
    return 1
  fi
  # No `--` after the mode below: macOS chmod reads it as a file name. The
  # path is absolute ($HOME), so it cannot be taken for an option.
  temporary="$(umask 077 && mktemp -- "$secret_folder/.secret.XXXXXX")" || return 1
  if ! { printf '%s' "$secret" >"$temporary" \
         && chmod 600 "$temporary" \
         && mv -f -- "$temporary" "$secret_file"; }; then
    rm -f -- "$temporary"
    echo "could not write $secret_file" >&2
    return 1
  fi
}

# Removes the secret and, when nothing else is in it, its folder.
remove_secret() {
  rm -f -- "$secret_file"
  rmdir -- "$secret_folder" 2>/dev/null || true
}

# The file SandSeek 0.1.0 wrote in TUFF's folder. Only that file, and only a
# plain file of yours; TUFF's own files are never touched.
remove_old_secret() {
  if [[ -f "$old_secret_file" && ! -L "$old_secret_file" && -O "$old_secret_file" ]]; then
    rm -f -- "$old_secret_file"
  fi
}

# A request that is not signed is refused with 401 and the code `unauthorized`.
# That is the answer a running sandbox gives this script, which cannot sign
# (it has no tool for that on the Mac); SandSeek checks the real signature
# before it uses the sandbox. An image from before signed requests answers an
# unsigned /health with 200 instead. `probe` sets $health_state to `ok` (the
# 401), `old` (an unsigned 200) or `none`, and succeeds for `ok` only.
health_state=none
probe() {
  local reply
  health_state=none
  reply="$(curl -sS --max-time 2 -w '\n%{http_code}' "http://127.0.0.1:$port/health" 2>/dev/null)" \
    || return 1
  if [[ "${reply##*$nl}" == 401 && "$reply" == *'"unauthorized"'* ]]; then
    health_state=ok
  elif [[ "${reply##*$nl}" == 200 ]]; then
    health_state=old
  fi
  [[ "$health_state" == ok ]]
}

old_image_message="the sandbox image is older than this SandSeek and does not check signatures; rebuild it with: $0 build"

# Sends one request signed with the secret from inside the VM, where root can
# read it, and prints "STATUS signed" or "STATUS unsigned" (the answer's
# signature was checked), the answer's error code on a line of its own (empty
# when it has none), then the answer's body. MODE is `replay` (the same
# signed request twice; the second answer is printed), `plain` (Content-Type
# text/plain) or empty.
#   signed_call METHOD PATH BODY [MODE]
signed_client='
import hashlib, hmac, http.client, json, os, sys, time

method, path, body = sys.argv[1], sys.argv[2], sys.argv[3].encode()
mode = sys.argv[4] if len(sys.argv) > 4 else ""
with open("'"$vm_secret_folder"'/secret", "rb") as handle:
    secret = handle.read().removesuffix(b"\n")

def auth(*fields):
    return hmac.new(secret, "\n".join(fields).encode(), hashlib.sha256).hexdigest()

nonce = os.urandom(32).hex()
stamp = str(int(time.time()))
headers = {
    "Host": "127.0.0.1:9100",
    "X-Sandbox-Nonce": nonce,
    "X-Sandbox-Time": stamp,
    "X-Sandbox-Auth": auth("sandseek-sandbox-req-v1", method, path, nonce, stamp,
                           hashlib.sha256(body).hexdigest()),
}
if method == "POST":
    headers["Content-Type"] = "text/plain" if mode == "plain" else "application/json"

def send():
    connection = http.client.HTTPConnection("127.0.0.1", 9100, timeout=40)
    connection.request(method, path, body=body or None, headers=headers)
    response = connection.getresponse()
    data = response.read()
    connection.close()
    return response.status, response.getheader("X-Sandbox-Auth"), data

status, tag, data = send()
if mode == "replay":
    status, tag, data = send()
expected = auth("sandseek-sandbox-resp-v1", method, path, nonce, str(status),
                hashlib.sha256(data).hexdigest())
good = tag is not None and hmac.compare_digest(tag.strip().lower(), expected)
text = data.decode("utf-8", "replace")
try:
    code = json.loads(text).get("error", {}).get("code", "")
except (ValueError, AttributeError):
    code = ""
print(status, "signed" if good else "unsigned")
print(code if isinstance(code, str) else "")
print(text)
'

signed_call() {
  container exec "$name" python3 -c "$signed_client" "$@" 2>&1
}

# The first line of a signed_call answer: "200 signed".
call_status() { printf '%s' "${1%%$nl*}"; }
# The second line: the JSON error code in the answer, or empty.
call_code() {
  local rest="${1#*$nl}"
  printf '%s' "${rest%%$nl*}"
}
# Everything after the second line: the answer's body.
call_body() {
  local rest="${1#*$nl}"
  printf '%s' "${rest#*$nl}"
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
    # A trace would print the secret (`secret=...` while it is written), so do
    # not run under `bash -x` or `set -x`.
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
    # The secret goes in as a read-only file in a mounted folder, never in the
    # environment or a command line, where other users would see it in `ps`.
    run_options=(
      --detach --rm --name "$name"
      --mount "type=bind,source=$secret_folder,target=$vm_secret_folder,readonly"
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
    # The file is complete before the sandbox starts, which reads it once. The
    # old VM is gone by now, so nothing is signing with the previous secret.
    # From here on, every way out but success deletes the new secret and any
    # VM that was started, so a missing secret still means "not running".
    cleanup_failed_start() {
      container stop "$name" >/dev/null 2>&1 || true
      container delete "$name" >/dev/null 2>&1 || true
      remove_secret
    }
    trap cleanup_failed_start EXIT
    write_secret || exit 1
    remove_old_secret
    container run "${run_options[@]}" "$image" >/dev/null
    # The entrypoint refuses to start when it finds no default gateway (see
    # Sandbox/entrypoint.sh) or cannot load the firewall, and `--rm` deletes the
    # container then, so keep the last non-empty log (a later "not found" error
    # must not replace it) to show below. The two flags are set from the whole
    # log, since the last five lines shown may not contain those lines.
    startup_log=""
    refused=0 firewall_loaded=0 listening=0 gone=0 firewall_line=""
    polls_after_listening=0
    old_image=0 list_failed=0
    # A hung curl or `container` call must not outlast the app's start timeout
    # (180 s), so the poll counts below also sit under an overall deadline.
    deadline=$((SECONDS + 120))
    for _ in $(seq 1 50); do
      # Ready needs the container to be running as well as the port to give
      # the unsigned 401: something else on the port must not pass for it.
      if probe; then
        if ! running="$(container list --quiet 2>/dev/null)"; then
          list_failed=1
        elif grep -qxF "$name" <<<"$running"; then
          trap - EXIT
          echo "web research sandbox ready at http://127.0.0.1:$port"
          exit 0
        fi
      elif [[ "$health_state" == old ]]; then
        old_image=1
        break
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
    if (( old_image )); then
      echo "$old_image_message" >&2
    elif (( refused || gone )); then
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
      echo "the sandbox container exited and was removed (it runs with --rm)." >&2
      echo "The log above usually says why. Its secret was deleted with it, so to run it once in the foreground without --rm, first write a test secret to $secret_file (64 hex characters, chmod 600), then run: $debug_command" >&2
    else
      if (( list_failed )); then
        echo "the sandbox answered on 127.0.0.1:$port, but \`container list\` failed, so it could not be confirmed as this sandbox; it was stopped and its secret deleted. Try again" >&2
      else
        echo "sandbox started but did not answer on 127.0.0.1:$port; it was stopped and its secret deleted (the log is above)" >&2
      fi
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
    # No secret means no sandbox is running.
    remove_secret
    echo "web research sandbox stopped"
    ;;
  status)
    check_port
    probe || true
    if [[ "$health_state" == ok ]]; then
      echo "web research sandbox answers at http://127.0.0.1:$port and refuses unsigned requests; SandSeek checks its signature before use"
    elif [[ "$health_state" == old ]]; then
      echo "$old_image_message" >&2
      exit 1
    else
      echo "web research sandbox is not answering at http://127.0.0.1:$port" >&2
      exit 1
    fi
    ;;
  selftest)
    check_port
    require_container
    probe || true
    if [[ "$health_state" == old ]]; then
      echo "$old_image_message" >&2
      exit 1
    fi
    [[ "$health_state" == ok ]] || { echo "start the sandbox first: $0 start" >&2; exit 1; }
    failures=0
    pass() { echo "  ok    $1"; }
    fail() { echo "  FAIL  $1" >&2; failures=$((failures + 1)); }

    echo "Fetches the sandbox must refuse:"
    # The same helper the entrypoint uses for the inbound rule.
    gateway="$(container exec "$name" python3 /app/default_gateway.py)" \
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
      reply="$(signed_call POST /v1/fetch "{\"url\": \"$url\"}" || true)"
      code="$(call_code "$reply")"
      case "$code" in
        blocked_address|blocked_port|invalid_url|dns_error)
          if [[ "$(call_status "$reply")" == *" signed" ]]; then
            pass "$url refused ($code)"
          else
            fail "$url was refused ($code) but the answer was not signed"
          fi ;;
        *) fail "$url was not refused: ${reply:0:200}" ;;
      esac
    done

    echo "The VM's own protection:"
    if container exec "$name" nft list table inet sandseek_sandbox >/dev/null 2>&1; then
      pass "the firewall is loaded"
    else
      fail "the firewall is not loaded"
    fi
    # -nn prints the port as a number (nft would otherwise print a service name).
    # This reads the loaded rules; it does not send a packet from another
    # address, so it shows that the rule names the gateway, not that other
    # senders are refused.
    input_rules="$(container exec "$name" nft -nn list chain inet sandseek_sandbox input 2>/dev/null || true)"
    if grep -q 'hook input.*policy drop' <<<"$input_rules" \
        && grep -qF "ip saddr $gateway tcp dport 9100 accept" <<<"$input_rules" \
        && [[ "$(grep -c 'dport 9100' <<<"$input_rules")" == 1 ]]; then
      pass "the firewall drops new inbound connections except to port 9100 from the gateway $gateway"
    else
      fail "the firewall's input chain is missing or not as expected: ${input_rules:0:200}"
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
    status="$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
      --data '{"url":"https://example.com/"}' "http://127.0.0.1:$port/v1/fetch")"
    [[ "$status" == "401" ]] && pass "unsigned request refused" || fail "unsigned request answered $status"
    # Signed correctly, so it is the content type that is refused.
    reply="$(signed_call POST /v1/fetch '{"url":"https://example.com/"}' plain || true)"
    [[ "$(call_status "$reply")" == "415 signed" ]] \
      && pass "browser-style simple POST refused" || fail "simple POST answered: ${reply:0:200}"
    reply="$(signed_call POST /v1/fetch '{"url":"https://example.com/"}' replay || true)"
    if [[ "$(call_status "$reply")" == "401 signed" && "$(call_code "$reply")" == "replayed_request" ]]; then
      pass "a request sent twice is refused the second time"
    else
      fail "a repeated request was not refused: ${reply:0:200}"
    fi
    reply="$(signed_call PUT /health '' || true)"
    [[ "$(call_status "$reply")" == "405 signed" ]] \
      && pass "other methods are refused (after the signature check)" || fail "PUT answered: ${reply:0:200}"

    echo "The sandbox must check requests and sign its answers:"
    reply="$(signed_call GET /health '' || true)"
    body="$(call_body "$reply")"
    if [[ "$(call_status "$reply")" == "200 signed" && "$body" == *'"status": "ok"'* && "$body" == *'"api": 1'* ]]; then
      pass "a signed /health request is answered with a signed answer"
    else
      fail "a signed /health request was not answered with a signed answer: ${reply:0:200}"
    fi
    # The folder is mounted read-only; /proc/mounts in the VM shows whether
    # Apple container did that.
    mount_options="$(container exec "$name" awk -v dir="$vm_secret_folder" \
      '$2 == dir { print $4 }' /proc/mounts 2>/dev/null || true)"
    case ",$mount_options," in
      *,ro,*) pass "the secret folder is mounted read-only in the VM" ;;
      *) fail "the secret folder is not mounted read-only in the VM (mount options: ${mount_options:-none})" ;;
    esac
    if [[ -e "$secret_file" ]]; then
      pass "the secret file exists on the Mac ($secret_file)"
    else
      fail "the secret file $secret_file does not exist, so SandSeek cannot use the sandbox"
    fi

    echo "A public page must still work:"
    reply="$(signed_call POST /v1/fetch '{"url":"https://example.com/"}' || true)"
    if [[ "$(call_status "$reply")" == "200 signed" && "$reply" == *'"text"'* ]]; then
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
