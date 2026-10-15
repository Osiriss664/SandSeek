#!/usr/bin/env bash
# SandSeek's safety probe: looks at the web sandbox that is running now, from
# the Mac and from inside its VM, and says PASS, FAIL or NOTE for each promise
# docs/SECURITY.md makes. It starts nothing, stops nothing and changes nothing
# (only `container exec` probes, small signed requests and read-only looks at
# the Mac). It is SandSeek's version of the probe TUFF's safety test used
# (research/tuff-sandbox/safety-test/probe.sh).
#
#   Scripts/safety_probe.sh
#
# Start a sandbox first (Scripts/research_sandbox.sh start, or the app's Start
# button); the probe finds it through the files `start` records (vm-name and
# port, beside the secret) and refuses, with exit code 2, when there is none.
#
# Environment (all optional):
#   SKIP_PORT_SCAN=1        skip the scan of every TCP port of the Mac from inside the VM
#   SAFETY_SCAN_SECONDS=N   time limit of that scan (default 600; a scan that
#                           reaches it is reported as incomplete, not as a pass)
#   SAFETY_SECRET_FOLDER    the folder with secret, port and vm-name
#                           (default ~/Library/Application Support/SandSeek/sandbox)
#   SAFETY_LSOF, SAFETY_IFCONFIG  other programs in place of /usr/sbin/lsof and
#                           /sbin/ifconfig (for the tests; the real ones are used by
#                           absolute path and are never looked up on PATH)
#   SAFETY_CONTAINER        the container program (default /usr/local/bin/container
#                           when it exists, else `container` on PATH)
#   SAFETY_ROOT_ALLOW       an extended regular expression matched against the command line of
#                           root processes in the VM that the image needs (default: none)
#
# Output: one line per check, PASS, FAIL, NOTE or SKIP, then
# "Result: N pass, M fail" as the last line. Exit code 0 only with no FAIL, 1
# with at least one, 2 when no sandbox runs, 99 when a needed tool is missing.
# The secret is never printed: the checks that need it run in
# Scripts/safety_probe_api.py, which reads it from its file.
#
# Unattended: no input is read, nothing asks for sudo, no clicks. Every outside
# call has a time limit. Works with the bash 3.2 and BSD tools macOS ships.
# Python 3.9 or newer, curl, lsof, ifconfig and Apple's container are needed.

set -u
set -f

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
api="$here/safety_probe_api.py"
PY="${SAFETY_PYTHON:-python3}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
if [ $# -gt 0 ]; then
  echo "unknown argument: $1 (see --help)" >&2
  exit 2
fi

passes=0; fails=0; notes=0; skips=0
pass() { passes=$((passes + 1)); printf '  PASS  %s\n' "$*"; }
fail() { fails=$((fails + 1)); printf '  FAIL  %s\n' "$*"; }
note() { notes=$((notes + 1)); printf '  NOTE  %s\n' "$*"; }
skip() { skips=$((skips + 1)); printf '  SKIP  %s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }
cut_() { local s="$*"; [ ${#s} -gt 240 ] && s="${s:0:240}..."; printf '%s' "$s"; }

secret_folder="${SAFETY_SECRET_FOLDER:-$HOME/Library/Application Support/SandSeek/sandbox}"
secret_file="$secret_folder/secret"

CONTAINER="${SAFETY_CONTAINER:-}"
if [ -z "$CONTAINER" ]; then
  if [ -x /usr/local/bin/container ]; then CONTAINER=/usr/local/bin/container; else CONTAINER=container; fi
fi
lsof_bin="${SAFETY_LSOF:-/usr/sbin/lsof}"
ifconfig_bin="${SAFETY_IFCONFIG:-/sbin/ifconfig}"
for tool in "$CONTAINER" "$PY" "$lsof_bin" "$ifconfig_bin" curl awk sort stat ps; do
  command -v "$tool" >/dev/null 2>&1 || { echo "needs $tool" >&2; exit 99; }
done

if [ "$(uname -s)" = Darwin ]; then
  mode_of() { stat -f '%Lp' "$1" 2>/dev/null; }
  owner_of() { stat -f '%u' "$1" 2>/dev/null; }
else
  mode_of() { stat -c '%a' "$1" 2>/dev/null; }
  owner_of() { stat -c '%u' "$1" 2>/dev/null; }
fi

# --- helpers ---------------------------------------------------------------------

# limited SECONDS COMMAND...: runs the command with no input and ends it (and
# anything it started) after SECONDS; exit code 124 then. Output passes through.
limited() {
  local seconds="$1"; shift
  "$PY" -c '
import os, signal, subprocess, sys
process = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL, start_new_session=True)
try:
    sys.exit(process.wait(timeout=float(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    sys.exit(124)
' "$seconds" "$@"
}

in_vm() { limited 60 "$CONTAINER" exec "$name" "$@"; }
as_user() { limited 60 "$CONTAINER" exec --user 10001:10001 "$name" "$@"; }
# A Python snippet in the VM, as the server's user (py_user) or as root (py_root).
py_user() { local code="$1"; shift; as_user python3 -c "$code" "$@" 2>/dev/null; }
py_root() { local code="$1"; shift; in_vm python3 -c "$code" "$@" 2>/dev/null; }

# Reads "PASS text" / "FAIL text" / "NOTE text" / "SKIP text" lines (the
# helper's) on standard input into the counters.
relay() {
  local line seen=0
  while IFS= read -r line; do
    case "$line" in
      "PASS "*) pass "${line#PASS }"; seen=1 ;;
      "FAIL "*) fail "${line#FAIL }"; seen=1 ;;
      "NOTE "*) note "${line#NOTE }"; seen=1 ;;
      "SKIP "*) skip "${line#SKIP }"; seen=1 ;;
      "") ;;
      *) fail "unexpected output of the helper: $(cut_ "$line")" ;;
    esac
  done
  [ "$seen" = 1 ] || fail "the helper printed nothing"
}

# Every IPv4 and IPv6 address of the Mac that is up, lower case, zone ids
# removed, one per line, as the launcher collects them.
mac_addresses() {
  "$ifconfig_bin" 2>/dev/null | LC_ALL=C awk '
    NF >= 2 && ($1 == "inet" || $1 == "inet6") { a = $2; sub(/%.*/, "", a); print tolower(a) }' | sort -u
}

# --- the Python snippets that run in the VM; the first line names each one ------------

connect_py='# probe:connect
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
try:
    socket.create_connection((host, port), timeout=4).close()
    print("connected")
except ConnectionRefusedError:
    print("refused")
except socket.timeout:
    print("timeout")
except OSError as error:
    print("error", type(error).__name__, getattr(error, "errno", ""))
'
dns_py='# probe:dns
import socket, sys
try:
    print("resolved", socket.getaddrinfo(sys.argv[1], 443)[0][4][0])
except OSError as error:
    print("failed", type(error).__name__)
'
privileges_py='# probe:privileges
import glob
for path in glob.glob("/proc/[0-9]*/cmdline"):
    try:
        if b"/app/server.py" not in open(path, "rb").read().split(b"\0"):
            continue
        status = dict(l.split(":", 1) for l in open(path[:-7] + "status") if ":" in l)
    except OSError:
        continue
    caps = [n for n in ("CapPrm", "CapEff", "CapBnd", "CapAmb") if int(status[n], 16)]
    print(status["Uid"].split()[0], ",".join(caps) or "none", status.get("NoNewPrivs", "?").strip())
    break
'
processes_py='# probe:processes
import glob, os
mine = set()
pid = os.getpid()
while pid > 1:
    mine.add(str(pid))
    try:
        pid = int([l for l in open("/proc/%d/status" % pid) if l.startswith("PPid:")][0].split()[1])
    except (OSError, IndexError, ValueError):
        break
for path in sorted(glob.glob("/proc/[0-9]*/cmdline"), key=lambda p: int(p.split("/")[2])):
    pid = path.split("/")[2]
    if pid in mine:
        continue
    try:
        parts = open(path, "rb").read().split(b"\0")
        uid = [l for l in open("/proc/%s/status" % pid) if l.startswith("Uid:")][0].split()[1]
    except (OSError, IndexError):
        continue
    print(pid, uid, b" ".join(p for p in parts if p)[:120].decode("utf-8", "replace"))
'
ipv6_py='# probe:ipv6
for line in open("/proc/net/if_inet6"):
    raw, _, _, scope, _, name = line.split()[:6]
    if scope == "00":
        print(":".join(raw[i:i+4] for i in range(0, 32, 4)), name)
'
scan_py='# probe:scan
import socket, sys, time
from concurrent.futures import ThreadPoolExecutor
host, limit = sys.argv[1], float(sys.argv[2])
end = time.time() + limit
def probe(port):
    if time.time() > end:
        return port, None
    try:
        socket.create_connection((host, port), timeout=1).close()
        return port, True
    except OSError:
        return port, False
found, skipped = [], 0
with ThreadPoolExecutor(64) as pool:
    for port, state in pool.map(probe, range(1, 65536)):
        if state is None:
            skipped += 1
        elif state:
            found.append(port)
print(" ".join(str(p) for p in found) + "|" + str(65535 - skipped))
'

# --- find the sandbox -------------------------------------------------------------------

refuse() {
  echo "no sandbox to probe: $*" >&2
  echo "Start one first: Scripts/research_sandbox.sh start (or the app's Start button), then run this again." >&2
  exit 2
}

name=""; port=""
if [ -f "$secret_folder/vm-name" ]; then name="$(head -c 64 "$secret_folder/vm-name" 2>/dev/null | tr -d '\n')"; fi
if [ -n "${SANDSEEK_SANDBOX_PORT:-}" ]; then
  port="$SANDSEEK_SANDBOX_PORT"
elif [ -f "$secret_folder/port" ]; then
  port="$(head -c 16 "$secret_folder/port" 2>/dev/null | tr -d '\n')"
fi
[ -n "$name" ] || refuse "no VM name is recorded ($secret_folder/vm-name is missing)"
[[ "$name" =~ ^sandseek-sandbox-[0-9a-f]{8}$ ]] || refuse "the recorded VM name is not one SandSeek makes"
[ -n "$port" ] || refuse "no port is recorded ($secret_folder/port is missing)"
[[ "$port" =~ ^[0-9]{4,5}$ ]] && [ "$((10#$port))" -ge 1024 ] && [ "$((10#$port))" -le 65535 ] \
  || refuse "the recorded port is not a port number from 1024 to 65535"
port=$((10#$port))
[ -f "$secret_file" ] || refuse "there is no secret file, so the sandbox is not running"

running="$(limited 60 "$CONTAINER" list --quiet 2>/dev/null </dev/null)" || running=""
printf '%s\n' "$running" | grep -qxF "$name" || refuse "the recorded VM $name is not running"

printf 'SandSeek safety probe: %s on 127.0.0.1:%s\n' "$name" "$port"

# --- Mac side ------------------------------------------------------------------------------

head_ "the sandbox from the Mac's side"
all_vms="$(limited 60 "$CONTAINER" list --all --quiet 2>/dev/null </dev/null || true)"
sandseek_vms="$(printf '%s\n' "$all_vms" | grep '^sandseek' || true)"
vm_count="$(printf '%s\n' "$sandseek_vms" | grep -c . || true)"
if [ "$vm_count" = 1 ] && [ "$sandseek_vms" = "$name" ]; then
  pass "exactly one sandseek VM exists: $name"
else
  fail "$vm_count sandseek VMs exist ($(printf '%s' "$sandseek_vms" | tr '\n' ' ')); exactly one, $name, is expected"
fi

listing="$(limited 60 "$lsof_bin" -nP -iTCP:"$port" -sTCP:LISTEN -Fcn 2>/dev/null </dev/null || true)"
bound="$(printf '%s\n' "$listing" | grep '^n' | sort -u || true)"
if [ -z "$bound" ]; then
  fail "nothing on the Mac listens on port $port"
elif [ "$bound" = "n127.0.0.1:$port" ]; then
  pass "port $port is bound to 127.0.0.1 only ($(printf '%s\n' "$listing" | grep '^c' | sort -u | sed 's/^c//' | tr '\n' ' '))"
else
  fail "port $port is open on more than 127.0.0.1: $(cut_ "$(printf '%s' "$bound" | tr '\n' ' ')")"
fi

http_status() { # curl arguments...
  curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 "$@" </dev/null 2>/dev/null
}
base="http://127.0.0.1:$port"
s="$(http_status "$base/health")"
[ "$s" = 401 ] && pass "an unsigned request is refused (401)" || fail "an unsigned request answered $s (401 expected)"
s="$(http_status -H 'Host: attacker.example' "$base/health")"
[ "$s" = 403 ] && pass "a foreign Host header is refused (403)" || fail "a foreign Host header answered $s (403 expected)"
s="$(http_status -H 'Content-Type: text/plain' --data '{"url":"https://example.com/"}' "$base/v1/fetch")"
case "$s" in
  401|403|415) pass "a browser-style POST (text/plain, unsigned) is refused ($s)" ;;
  *) fail "a browser-style POST answered $s (401, 403 or 415 expected)" ;;
esac
s="$(http_status -X OPTIONS -H 'Origin: http://attacker.example' -H 'Access-Control-Request-Method: POST' "$base/v1/fetch")"
case "$s" in
  401|403|405|501) pass "a CORS preflight is refused ($s)" ;;
  *) fail "a CORS preflight answered $s (401, 403, 405 or 501 expected)" ;;
esac
cors=""; cors_unreachable=""
for request in "-X OPTIONS -H Origin:http://attacker.example" "-H Origin:http://attacker.example" ""; do
  # shellcheck disable=SC2086
  headers="$(curl -s --noproxy '*' -D - -o /dev/null --max-time 10 $request "$base/health" </dev/null 2>/dev/null)"
  curl_rc=$?
  if [ "$curl_rc" != 0 ]; then cors_unreachable="$cors_unreachable [curl exit code $curl_rc]"; continue; fi
  cors="$cors$(printf '%s\n' "$headers" | grep -i '^access-control-' || true)"
done
if [ -n "$cors_unreachable" ]; then
  fail "CORS headers: curl could not get an answer from $base/health:$cors_unreachable; nothing was checked"
elif [ -z "$cors" ]; then
  pass "no CORS header (Access-Control-*) is ever sent"
else
  fail "a CORS header is sent: $(cut_ "$cors")"
fi

# The secret: file 0600, folder 0700, and its text nowhere a process list or
# `container inspect` would show it. The comparison runs in the helper.
folder_mode="$(mode_of "$secret_folder")"
file_mode="$(mode_of "$secret_file")"
[ "$folder_mode" = 700 ] && pass "the secret folder has mode 0700" || fail "the secret folder has mode ${folder_mode:-unknown} (0700 expected)"
if [ "$file_mode" = 600 ] && [ "$(owner_of "$secret_file")" = "$(id -u)" ]; then
  pass "the secret file has mode 0600 and is yours"
else
  fail "the secret file has mode ${file_mode:-unknown} or another owner (0600, yours, expected)"
fi
loose=""
for other in port vm-name blocked-addresses lock; do
  [ -e "$secret_folder/$other" ] || continue
  [ "$(mode_of "$secret_folder/$other")" = 600 ] || loose="$loose $other"
done
[ -z "$loose" ] && pass "port, vm-name, blocked-addresses and lock have mode 0600" || fail "these files in the secret folder are not 0600:$loose"
out="$("$PY" "$api" secret-leaks "$secret_file" "$CONTAINER" "$name" 2>&1 </dev/null)" || true
relay <<<"$out"

# --- firewall shape, read inside the VM -----------------------------------------------------

head_ "the VM's firewall (read inside the VM)"
gateway="$(in_vm python3 /app/default_gateway.py 2>/dev/null | head -n 1 || true)"
if [[ "$gateway" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  pass "the VM's default gateway, the Mac as the VM sees it, is $gateway"
else
  fail "could not read the VM's default gateway (got: $(cut_ "$gateway"))"
  gateway=""
fi
table=sandseek_sandbox
if in_vm nft list table inet $table >/dev/null 2>&1; then
  pass "the firewall table $table is loaded"
else
  fail "the firewall table $table is NOT loaded"
fi
input_rules="$(in_vm nft -nn list chain inet $table input 2>/dev/null || true)"
output_rules="$(in_vm nft -nn list chain inet $table output 2>/dev/null || true)"

# A rule list, one rule per line, with the leading blanks and the nfproto
# prefix removed, so that the spelling of `nft -nn` does not matter.
normalise() { sed -E 's/^[[:space:]]+//; s/^meta nfproto (ipv4|2) //; s/^meta nfproto (ipv6|10) //; s/[[:space:]]+$//'; }

if printf '%s' "$input_rules" | grep -q 'hook input.*policy drop'; then
  pass "input policy is drop"
else
  fail "input policy is not drop: $(cut_ "$input_rules")"
fi
input_accepts="$(printf '%s\n' "$input_rules" | normalise | grep 'accept' | grep -vE '^iifname "lo" accept$|^ct state [^ ]+ accept$' || true)"
if [ -n "$gateway" ] && [ "$input_accepts" = "ip saddr $gateway tcp dport 9100 accept" ]; then
  pass "input: the only new connections accepted are to the in-VM port 9100 from the gateway $gateway"
else
  fail "input: accepted besides loopback and replies: $(cut_ "${input_accepts:-nothing}") (expected: ip saddr ${gateway:-GATEWAY} tcp dport 9100 accept)"
fi
if printf '%s' "$output_rules" | grep -q 'hook output.*policy drop'; then
  pass "output policy is drop"
else
  fail "output policy is not drop: $(cut_ "$output_rules")"
fi
missing_rules=""
for set_name in blocked4 blocked6 private4 refused6; do
  printf '%s\n' "$output_rules" | grep "daddr @$set_name" | grep -q reject || missing_rules="$missing_rules @$set_name"
done
if [ -z "$missing_rules" ]; then
  pass "output rejects the blocked sets (the Mac's addresses), the private IPv4 ranges and the refused IPv6 ranges"
else
  fail "output has no reject rule for:$missing_rules"
fi
# The private ranges: sample addresses must be elements of private4.
not_private=""
for sample in 10.0.0.1 100.64.0.1 127.0.0.1 169.254.169.254 172.16.0.1 192.168.1.1; do
  in_vm nft get element inet $table private4 "{ $sample }" >/dev/null 2>&1 || not_private="$not_private $sample"
done
if [ -z "$not_private" ]; then
  pass "private4 holds the private, shared, loopback and link-local ranges"
else
  fail "these sample addresses are not in private4:$not_private"
fi

# DNS: the exception covers exactly the name servers in resolv.conf.
resolvers="$(in_vm awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//' || true)"
normalised_output="$(printf '%s\n' "$output_rules" | normalise)"
dns_lines="$(printf '%s\n' "$normalised_output" | grep -E '^ip6? daddr [^ ]+ (udp|tcp) dport 53 accept$' || true)"
dns_servers="$(printf '%s\n' "$dns_lines" | awk 'NF { print $3 }' | sort -u | tr '\n' ' ' | sed 's/ $//')"
dns_rule_count="$(printf '%s\n' "$dns_lines" | grep -c . || true)"
stray_dns="$(printf '%s\n' "$normalised_output" | grep 'dport 53' | grep -vE '^ip6? daddr [^ ]+ (udp|tcp) dport 53 accept$' | grep accept || true)"
if [ "$dns_servers" = "$resolvers" ] && [ -z "$stray_dns" ] && [ "$dns_rule_count" = $((2 * $(printf '%s\n' "$resolvers" | wc -w))) ]; then
  pass "the DNS exception (udp and tcp port 53) covers only resolv.conf's name servers: ${resolvers:-none}"
else
  fail "the DNS exception does not match resolv.conf: rules for [$dns_servers] ($dns_rule_count rules), resolv.conf names [$resolvers]${stray_dns:+; other port-53 accept: $(cut_ "$stray_dns")}"
fi
# No other accept rule: loopback, replies, the DNS rules above, public IPv4 and
# global IPv6. The one IPv4 accept is `meta nfproto ipv4 accept` (nft 1.0.9; `meta
# nfproto 2 accept` in numeric form) and it must come after the private4 reject,
# or the private ranges would be accepted before they are refused.
rule_lines="$(printf '%s\n' "$output_rules" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
v4_accept_line="$(printf '%s\n' "$rule_lines" | grep -nE '^meta nfproto (ipv4|2) accept$' | cut -d: -f1 | tr '\n' ' ' | sed 's/ $//')"
private4_reject_line="$(printf '%s\n' "$rule_lines" | grep -n 'daddr @private4' | grep reject | cut -d: -f1 | tail -n 1)"
extra="$(printf '%s\n' "$rule_lines" | grep -vE '^meta nfproto (ipv4|2) accept$' | sed -E 's/^meta nfproto (ipv4|2) //; s/^meta nfproto (ipv6|10) //' | grep 'accept' \
  | grep -vE '^oifname "lo" accept$|^ct state [^ ]+ accept$|^ip6 daddr 2000::/3 accept$|^ip6? daddr [^ ]+ (udp|tcp) dport 53 accept$' || true)"
if [ -n "$extra" ]; then
  fail "unexpected accept rule(s): $(cut_ "$(printf '%s' "$extra" | tr '\n' ';')") (only expected with SEARXNG_URL set)"
elif [ -z "$v4_accept_line" ] || [ "${v4_accept_line#* }" != "$v4_accept_line" ]; then
  fail "output: expected exactly one 'meta nfproto ipv4 accept' rule, found at line(s): ${v4_accept_line:-none}"
elif [ -z "$private4_reject_line" ] || [ "$v4_accept_line" -lt "$private4_reject_line" ]; then
  fail "output: the IPv4 accept (line $v4_accept_line) does not come after the private4 reject (line ${private4_reject_line:-none})"
else
  pass "no accept rule besides loopback, replies, DNS to the name servers, public IPv4 (after the private4 reject) and global IPv6"
fi

# --- blocked sets against the Mac now --------------------------------------------------------

head_ "the Mac's addresses right now against the blocked sets"
current="$(mac_addresses)"
if [ -z "$current" ]; then
  fail "could not read the Mac's addresses with ifconfig"
else
  in_sets=0; covered=""; absent=""
  for address in $current; do
    case "$address" in *:*) set_name=blocked6 ;; *) set_name=blocked4 ;; esac
    if in_vm nft get element inet $table $set_name "{ $address }" >/dev/null 2>&1; then
      in_sets=$((in_sets + 1))
      continue
    fi
    # Not in the set: refused anyway by the private ranges (IPv4), or by the
    # rule that accepts global IPv6 (2000::/3) only? Then the bridge address
    # the Mac gets while the VM runs is no gap.
    if [ "$set_name" = blocked4 ]; then
      if in_vm nft get element inet $table private4 "{ $address }" >/dev/null 2>&1; then
        covered="$covered $address"; continue
      fi
    else
      if "$PY" -c '
import ipaddress, sys
a = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if a not in ipaddress.ip_network("2000::/3") else 1)' "$address" 2>/dev/null; then
        covered="$covered $address"; continue
      elif in_vm nft get element inet $table refused6 "{ $address }" >/dev/null 2>&1; then
        covered="$covered $address"; continue
      fi
    fi
    absent="$absent $address"
  done
  [ -z "$covered" ] || note "not in the blocked sets, but refused by the private or non-global ranges (the bridge to the VM exists only while it runs):$covered"
  if [ -z "$absent" ]; then
    pass "every address the Mac has now is refused ($in_sets in the blocked sets, the rest by the range rules)"
  else
    fail "Mac addresses in neither blocked set nor a refused range:$absent. If the Mac gained them after the sandbox started (a rotated temporary IPv6 address, a VPN), this is the documented limit (docs/SECURITY.md): stop and start the sandbox and run the probe again. A FAIL that stays is real"
  fi
fi
v6="$(py_root "$ipv6_py")"; v6_rc=$?
if [ "$v6_rc" != 0 ]; then
  fail "could not read the VM's IPv6 addresses (exec exit code $v6_rc); nothing was checked"
else
  # fc00::/7 (unique local) is not global, whatever the kernel's scope says.
  v6_global="$(printf '%s\n' "$v6" | grep -viE '^f[cd][0-9a-f]{2}:' | grep . || true)"
  v6_ula="$(printf '%s\n' "$v6" | grep -iE '^f[cd][0-9a-f]{2}:' || true)"
  [ -z "$v6_ula" ] || note "the VM has a unique-local IPv6 address (fc00::/7, not global): $(printf '%s' "$v6_ula" | tr '\n' ';')"
  if [ -n "$v6_global" ]; then
    note "the VM has a global IPv6 address ($(printf '%s' "$v6_global" | tr '\n' ';')): a LAN host with a global IPv6 address is reachable (documented limit)"
  else
    pass "the VM has no global IPv6 address"
  fi
fi

# --- reachability, as the server's user ------------------------------------------------------

head_ "what the server's user can reach from inside the VM (controls first)"
controls_ok=1
r="$(py_user "$connect_py" 1.1.1.1 443)"
if [ "$r" = connected ]; then
  pass "control: a public HTTPS address (1.1.1.1:443) can be reached, so the refusals below mean something"
else
  fail "control: 1.1.1.1:443 gave '${r:-nothing}'. The VM has no internet; the refusals below would mean nothing"
  controls_ok=0
fi
r="$(py_user "$dns_py" example.com)"
case "$r" in
  resolved*) pass "control: a name lookup works ($r)" ;;
  *) fail "control: the name lookup of example.com gave '${r:-nothing}'"; controls_ok=0 ;;
esac

# Must be refused: connected is a FAIL, a refusal (connection reset) is the
# expected PASS, any other failure to connect is a PASS with a NOTE.
expect_refused() { # LABEL HOST PORT
  local result
  result="$(py_user "$connect_py" "$2" "$3")"
  case "$result" in
    connected) fail "the VM CAN connect to $1" ;;
    refused) pass "$1 refused at once (the firewall's reject)" ;;
    "") fail "$1: the probe gave no answer" ;;
    *) pass "$1 not reachable ($result)"; note "$1 did not get a reset: $result" ;;
  esac
}
if [ "$controls_ok" != 1 ]; then
  skip "the refusal checks (controls failed, so a refusal would prove nothing)"
elif [ -z "$gateway" ]; then
  skip "the refusal checks against the gateway (no gateway known)"
else
  for p in 22 80 443 5000 8080 8443; do
    expect_refused "the gateway $gateway:$p" "$gateway" "$p"
  done
  expect_refused "the gateway at the published port ($gateway:$port)" "$gateway" "$port"
  for target in 192.168.1.1 10.0.0.1 172.16.0.1 100.64.0.1 169.254.169.254; do
    expect_refused "$target:80" "$target" 80
  done
  skipped_addresses=""
  for address in $current; do
    case "$address" in
      127.*|::1) skipped_addresses="$skipped_addresses $address"; continue ;;
      fe80:*) skipped_addresses="$skipped_addresses $address"; continue ;;
    esac
    expect_refused "the Mac's own address $address:80" "$address" 80
  done
  [ -z "$skipped_addresses" ] || note "not connected to (loopback is the VM's own, link-local needs a zone id):$skipped_addresses"

  if [ "${SKIP_PORT_SCAN:-0}" = 1 ]; then
    skip "the full TCP scan of the Mac from inside the VM (SKIP_PORT_SCAN=1)"
  else
    scan_limit="${SAFETY_SCAN_SECONDS:-600}"
    printf '  ...   scanning all 65535 TCP ports of %s from inside the VM (up to %s s)\n' "$gateway" "$scan_limit"
    scan="$(limited $((scan_limit + 90)) "$CONTAINER" exec --user 10001:10001 "$name" python3 -c "$scan_py" "$gateway" "$scan_limit" 2>/dev/null || true)"
    case "$scan" in
      *"|"*) ;;
      *) scan="error|0" ;;
    esac
    open_ports="${scan%%|*}"
    scanned="${scan##*|}"
    # Port 53 is the one exception, when the Mac is the VM's name server.
    if printf '%s\n' "$resolvers" | tr ' ' '\n' | grep -qxF "$gateway"; then
      kept=""
      for p in $open_ports; do
        if [ "$p" = 53 ]; then note "the Mac's port 53 answers: the allowed DNS exception, the Mac being the VM's name server"; else kept="$kept $p"; fi
      done
      open_ports="${kept# }"
    fi
    if [ "$open_ports" = error ]; then
      fail "the port scan did not run"
    elif [ -n "$open_ports" ]; then
      fail "the VM can reach these TCP ports on the Mac: $open_ports"
    elif [ "$scanned" -lt 65535 ] 2>/dev/null; then
      note "the port scan reached its time limit after $scanned of 65535 ports and found nothing open; not a complete pass"
    else
      pass "a full scan of all 65535 TCP ports of the Mac found none reachable from the VM"
    fi
  fi
fi

# --- privileges ----------------------------------------------------------------------------------

head_ "privileges inside the VM"
p="$(py_root "$privileges_py" || true)"
case "$p" in
  "10001 none 1") pass "server.py runs as user 10001 with no capabilities and NoNewPrivs 1" ;;
  *) fail "server.py user, capabilities and NoNewPrivs: '${p:-not found}' (10001 none 1 expected)" ;;
esac
procs="$(py_root "$processes_py")"; procs_rc=$?
note "processes in the VM (pid uid command): $(printf '%s' "$procs" | tr '\n' ';' | cut -c1-400)"
roots="$(printf '%s\n' "$procs" | awk '$2 == "0"' || true)"
if [ -n "${SAFETY_ROOT_ALLOW:-}" ]; then
  # The expression is matched against the command line alone, without "pid uid".
  roots="$(printf '%s\n' "$roots" | while IFS= read -r line; do
    printf '%s\n' "${line#* * }" | grep -qE "$SAFETY_ROOT_ALLOW" || printf '%s\n' "$line"
  done)"
fi
if [ "$procs_rc" != 0 ] || ! printf '%s\n' "$procs" | grep -qF '/app/server.py'; then
  fail "root processes: the process listing of the VM is empty or does not contain /app/server.py (exec exit code $procs_rc), so nothing was checked"
elif [ -z "$roots" ]; then
  pass "no root process runs in the VM besides what the image needs"
else
  fail "root process(es) in the VM: $(cut_ "$(printf '%s' "$roots" | tr '\n' ';')")"
fi
out="$(as_user nft list ruleset 2>&1 || true)"
if printf '%s' "$out" | grep -q 'table inet'; then
  fail "the server's user can read the firewall with nft"
elif printf '%s' "$out" | grep -qiE 'permission denied|operation not permitted|not permitted|must be root'; then
  pass "nft as the server's user is refused"
else
  fail "nft as the server's user gave an unclear answer: $(cut_ "$out")"
fi
out="$(as_user sh -c 'unshare -Urn sh -c "nft flush ruleset" 2>&1; echo "exit=$?"' 2>&1 || true)"
unshare_rc="$(printf '%s\n' "$out" | tail -n 1 | sed -n 's/^exit=\([0-9]*\)$/\1/p')"
if [ -z "$unshare_rc" ]; then
  fail "the user-namespace flush attempt did not run (no exit code): $(cut_ "$out")"
elif [ "$unshare_rc" = 126 ] || [ "$unshare_rc" = 127 ]; then
  skip "the user-namespace flush attempt: unshare is not available in the VM (exit code $unshare_rc), so nothing was tried"
elif in_vm nft list table inet $table >/dev/null 2>&1; then
  pass "the firewall table is still in place after a user-namespace flush attempt (exit code $unshare_rc)"
else
  fail "the firewall table is GONE after a user-namespace flush attempt as the server's user"
fi
# Control first: the same user can write to /tmp, so a refusal under /app means something.
if ! as_user sh -c 'echo x > /tmp/probe-write-control && rm -f /tmp/probe-write-control' >/dev/null 2>&1; then
  fail "control: the server's user cannot write to /tmp either, so the /app write check would prove nothing"
elif as_user sh -c 'echo x > /app/probe-write' >/dev/null 2>&1; then
  fail "the server's user can write under /app"
  in_vm rm -f /app/probe-write >/dev/null 2>&1 || true
else
  pass "the server's user cannot write under /app (control: /tmp is writable)"
fi
if as_user sh -c 'test -r /run/sandseek-sandbox/secret' >/dev/null 2>&1; then
  note "the secret is readable by the server's user inside the VM (documented: it protects against other programs on the Mac, not against code taken over in the VM)"
else
  note "the secret is NOT readable by the server's user inside the VM (better than documented)"
fi

# --- hostile requests through the signed API --------------------------------------------------------

head_ "hostile requests through the signed API"
addresses="$current"
[ -z "$gateway" ] || addresses="$gateway
$current"
addresses="$(printf '%s\n' "$addresses" | sort -u)"
# shellcheck disable=SC2086
out="$("$PY" "$api" hostile "$secret_file" "$port" "$secret_folder/blocked-addresses" $addresses 2>&1 </dev/null)" || true
relay <<<"$out"

printf '\nCounts: %d notes, %d skipped\n' "$notes" "$skips"
printf 'Result: %d pass, %d fail\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
