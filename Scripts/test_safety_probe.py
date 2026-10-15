#!/usr/bin/env python3
"""Tests for Scripts/safety_probe.sh, safety_lifecycle.sh and their helpers, on any
platform, with a fake `container`, `lsof` and `ifconfig` on PATH and a small
fake sandbox on a loopback port.

  python3 Scripts/test_safety_probe.py

Nothing real is started. What they cannot show is how the real Apple
`container`, `nft` and the real sandbox answer; that is the Mac run.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import verify_sandbox_signature as signing  # noqa: E402

SECRET = "9f" * 32
NAME = "sandseek-sandbox-0a1b2c3d"
GATEWAY = "192.168.64.1"


def write(path, text, mode=0o755):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(textwrap.dedent(text))
    os.chmod(path, mode)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


FAKE_CONTAINER = r'''#!__PYTHON__
import json, os, sys
a = sys.argv[1:]
env = os.environ.get
name = env("FAKE_NAME")
secret = open(env("FAKE_SECRET_FILE")).read() if os.path.exists(env("FAKE_SECRET_FILE", "")) else ""

def vms():
    path = env("FAKE_VMS")
    if path and os.path.exists(path):
        return [l for l in open(path).read().split() if l]
    return [name] + (env("FAKE_EXTRA_VM", "").split(",") if env("FAKE_EXTRA_VM") else [])

if a[:1] == ["list"]:
    if env("FAKE_LIST_FAIL") and os.path.exists(env("FAKE_LIST_FAIL")):
        sys.stderr.write("container list failed\n"); sys.exit(1)
    print("\n".join(vms()))
    sys.exit(0)
if a[:1] == ["inspect"]:
    print(json.dumps([{"configuration": {"id": a[1], "note": secret if env("FAKE_LEAK") else "ok"}}]))
    sys.exit(0)
if a[:1] in (["stop"], ["delete"]):
    sys.exit(0)
if a[:1] != ["exec"]:
    sys.exit(1)
user = "--user" in a
rest = a[3:] if user else a[1:]
rest = rest[1:]            # the VM name
if rest[0] == "python3" and rest[1] == "/app/default_gateway.py":
    print("192.168.64.1"); sys.exit(0)
if rest[0] == "python3" and rest[1] == "-c":
    code, args = rest[2], rest[3:]
    if env("FAKE_FAIL_PROBE") and ("probe:" + env("FAKE_FAIL_PROBE")) in code:
        sys.stderr.write("exec failed\n"); sys.exit(1)
    if "probe:connect" in code:
        key = args[0] + ":" + args[1]
        if key in env("FAKE_REACHABLE", "").split(","):
            print("connected")
        elif args[0] == "1.1.1.1":
            print("timeout" if env("FAKE_NO_CONTROL") else "connected")
        else:
            print("refused")
    elif "probe:dns" in code:
        print("failed gaierror" if env("FAKE_NO_CONTROL") else "resolved 93.184.216.34")
    elif "probe:privileges" in code:
        print(env("FAKE_PRIV", "10001 none 1"))
    elif "probe:processes" in code:
        if not env("FAKE_NO_PROCS"):
            print("1 10001 python3 /app/server.py")
        if env("FAKE_ROOT"):
            print("7 0 " + env("FAKE_ROOT"))
    elif "probe:ipv6" in code:
        if env("FAKE_IPV6"):
            print(env("FAKE_IPV6"))
    elif "probe:scan" in code:
        print(env("FAKE_OPEN", "") + "|65535")
    sys.exit(0)
if rest[0] == "nft":
    words = rest[1:]
    if words[:2] == ["list", "table"]:
        sys.exit(0)
    if words[:1] == ["list"]:     # list ruleset, as the server's user
        sys.stderr.write("Operation not permitted (you must be root)\n"); sys.exit(1)
    if words[:1] == ["-nn"] and words[1:3] == ["list", "chain"]:
        chain = words[5]
        if chain == "input":
            print("table inet sandseek_sandbox {\n\tchain input {\n\t\ttype filter hook input priority filter; policy drop;\n"
                  '\t\tiifname "lo" accept\n\t\tct state 0x2,0x4 accept\n\t\tip saddr 192.168.64.1 tcp dport 9100 accept\n'
                  + ("\t\ttcp dport 22 accept\n" if env("FAKE_OPEN_INPUT") else "") + "\t}\n}")
        else:
            print("table inet sandseek_sandbox {\n\tchain output {\n\t\ttype filter hook output priority filter; policy drop;\n"
                  '\t\toifname "lo" accept\n\t\tct state 0x2,0x4 accept\n'
                  "\t\tip daddr 192.168.64.1 tcp dport 53 accept\n\t\tip daddr 192.168.64.1 udp dport 53 accept\n"
                  + ("\t\tip daddr 10.9.9.9 tcp dport 8080 accept\n" if env("FAKE_EXTRA_ACCEPT") else "")
                  + ("\t\tmeta nfproto 2 accept\n" if env("FAKE_ACCEPT_EARLY") else "")
                  + "".join(f"\t\tmeta nfproto {f} ip{'6' if f == 'ipv6' else ''} daddr @{s} reject\n"
                           for f, s in (("ipv4", "blocked4"), ("ipv6", "blocked6"), ("ipv4", "private4"), ("ipv6", "refused6")))
                  + ("" if env("FAKE_ACCEPT_EARLY") else "\t\tmeta nfproto 2 accept\n")
                  + "\t\tmeta nfproto 10 ip6 daddr 2000::/3 accept\n\t\treject\n\t}\n}")
        sys.exit(0)
    if words[:2] == ["get", "element"]:
        s, addr = words[4], words[5].strip("{} ")
        if s == "private4":
            sys.exit(0 if addr.startswith(("10.", "100.64.", "127.", "169.254.", "172.16.", "192.168.")) else 1)
        if s == "refused6":
            sys.exit(1)
        sys.exit(0 if addr in env("FAKE_BLOCKED", "").split(",") else 1)
if rest[0] == "awk":
    print("192.168.64.1"); sys.exit(0)
if rest[0] == "sh":
    text = rest[2]
    if "unshare" in text:
        print("exit=" + env("FAKE_UNSHARE_RC", "1")); sys.exit(0)
    if "/tmp/probe-write" in text:
        sys.exit(1 if env("FAKE_NO_TMP") else 0)
    if "/app/probe-write" in text:
        sys.exit(0 if env("FAKE_APP_WRITABLE") else 1)
    sys.exit(0)
sys.exit(0)
'''


class Handler(BaseHTTPRequestHandler):
    """A stand-in for the sandbox: right answers to the probe's requests."""
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, document, sign=None, nonce=None, method="GET"):
        body = json.dumps(document).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        if sign and nonce:
            self.send_header("X-Sandbox-Auth", signing.response_auth(
                SECRET.encode(), method, self.path, nonce, status, body))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        nonce = self.headers.get("X-Sandbox-Nonce")
        error = lambda s, c: self.reply(s, {"error": {"code": c, "message": c}}, True, nonce, method)  # noqa: E731
        if method == "OPTIONS":
            return self.reply(501, {"error": {"code": "x"}})
        if self.headers.get("Host", "").split(":")[0] != "127.0.0.1":
            return self.reply(403, {"error": {"code": "forbidden_host"}})
        auth = self.headers.get("X-Sandbox-Auth")
        expected = signing.request_auth(SECRET.encode(), method, self.path, nonce or "",
                                        self.headers.get("X-Sandbox-Time", ""), body)
        if not auth or not hmac.compare_digest(auth, expected):
            return self.reply(401, {"error": {"code": "unauthorized"}})
        if method == "GET":
            return self.reply(200, {"status": "ok", "api": 1, "blocked_addresses": self.server.blocked_count},
                              True, nonce, method)
        if not self.headers.get("Content-Type", "").startswith("application/json"):
            return error(415, "invalid_request")
        request = json.loads(body)
        if self.path == "/v1/search":
            return error(422, "invalid_argument")
        url = request.get("url", "")
        if self.server.leak and "169.254.169.254" in url and "[" not in url:
            return self.reply(200, {"url": url, "text": "x"}, True, nonce, method)
        if "redirect-to" in url:
            return error(502, "http_error")
        if not url.startswith(("http://", "https://")) or "@" in url:
            return error(422, "invalid_url")
        if url.count(":") == 2 and url.rsplit(":", 1)[1].rstrip("/").isdigit():
            return error(422, "blocked_port")
        return error(403, "blocked_address")

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_OPTIONS(self):
        self.handle_any("OPTIONS")


class Fixture:
    def __init__(self, with_sandbox=True):
        self.root = tempfile.mkdtemp(prefix="safety-")
        self.bin = os.path.join(self.root, "bin")
        self.folder = os.path.join(self.root, "sandbox")
        self.port = free_port()
        os.makedirs(self.folder, mode=0o700)
        os.chmod(self.folder, 0o700)
        write(f"{self.bin}/container", FAKE_CONTAINER.replace("__PYTHON__", sys.executable))
        write(f"{self.bin}/lsof", f"""\
            #!/bin/bash
            if [ -n "$FAKE_LSOF" ]; then printf '%s\\n' "$FAKE_LSOF"; exit 0; fi
            printf 'p1\\ncfake-runtime\\nn127.0.0.1:%s\\n' "{self.port}"
            """)
        write(f"{self.bin}/ifconfig", """\
            #!/bin/bash
            if [ -n "$FAKE_IFCONFIG" ]; then printf '%b\\n' "$FAKE_IFCONFIG"; exit 0; fi
            printf '\\tinet 127.0.0.1 netmask 0xff000000\\n\\tinet 192.168.4.96 netmask 0xffffff00\\n'
            printf '\\tinet6 fe80::1%%lo0 prefixlen 64\\n\\tinet6 2A02:1::5 prefixlen 64\\n'
            """)
        self.server = None
        if with_sandbox:
            self.record()
            self.server = ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
            self.server.blocked_count = 5
            self.server.leak = False
            self.server.daemon_threads = True
            threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def file(self, name, text, mode=0o600):
        path = os.path.join(self.folder, name)
        with open(path, "w") as handle:
            handle.write(text)
        os.chmod(path, mode)

    def record(self):
        self.file("secret", SECRET)
        self.file("port", f"{self.port}\n")
        self.file("vm-name", f"{NAME}\n")
        self.file("blocked-addresses", "127.0.0.1\n192.168.4.96\n::1\n2a02:1::5\n198.41.0.4\n")

    def env(self, **extra):
        env = {
            "PATH": self.bin + os.pathsep + os.environ["PATH"],
            "SAFETY_LSOF": f"{self.bin}/lsof",
            "SAFETY_IFCONFIG": f"{self.bin}/ifconfig",
            "HOME": self.root,
            "SAFETY_SECRET_FOLDER": self.folder,
            "SAFETY_CONTAINER": f"{self.bin}/container",
            "FAKE_NAME": NAME,
            "FAKE_SECRET_FILE": os.path.join(self.folder, "secret"),
            "FAKE_BLOCKED": "127.0.0.1,192.168.4.96,::1,2a02:1::5,198.41.0.4",
            "SKIP_PORT_SCAN": "",
        }
        env.update(extra)
        return env

    def run(self, script="safety_probe.sh", *args, timeout=120, **extra):
        return subprocess.run(["bash", os.path.join(HERE, script), *args], env=self.env(**extra),
                              capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)

    def close(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
        shutil.rmtree(self.root, ignore_errors=True)


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()
        self.addCleanup(self.fx.close)

    def lines(self, result, kind):
        return [l for l in result.stdout.splitlines() if l.startswith(f"  {kind}  ")]

    def test_scripts_are_valid_bash(self):
        for name in ("safety_probe.sh", "safety_lifecycle.sh"):
            self.assertEqual(subprocess.run(["bash", "-n", os.path.join(HERE, name)]).returncode, 0, name)

    def test_a_good_sandbox_passes_and_ends_with_the_result_line(self):
        result = self.fx.run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.rstrip("\n").splitlines()[-1].split(",")[1].strip(), "0 fail")
        self.assertRegex(result.stdout.splitlines()[-2] + result.stdout.splitlines()[-1],
                         r"Counts: \d+ notes, \d+ skipped\s*Result: \d+ pass, 0 fail")
        self.assertEqual(self.lines(result, "FAIL"), [])
        text = result.stdout
        for expected in ("exactly one sandseek VM", "bound to 127.0.0.1 only", "foreign Host",
                         "CORS preflight", "mode 0700", "mode 0600", "does not appear in the output of `container inspect`",
                         "input policy is drop", "output policy is drop", "DNS exception",
                         "control: a public HTTPS address", "full scan of all 65535", "NoNewPrivs 1",
                         "nft as the server's user is refused", "still in place", "cannot write under /app",
                         "NOTE  the secret is readable", "IPv4-mapped IPv6", "NAT64", "credentials in the address",
                         "schemes other than", "SKIP  oversize or compressed page", "SKIP  redirect to a private"):
            self.assertIn(expected, text)

    def test_the_secret_is_never_printed(self):
        for extra in ({}, {"FAKE_LEAK": "1"}):
            result = self.fx.run(**extra)
            self.assertNotIn(SECRET, result.stdout + result.stderr)
            self.assertNotIn(SECRET[:20], result.stdout + result.stderr)

    def test_a_leak_into_container_inspect_is_a_fail(self):
        result = self.fx.run(FAKE_LEAK="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  the secret appears in the output of `container inspect`", result.stdout)
        self.assertIn(" 1 fail", result.stdout.splitlines()[-1])

    def test_a_reachable_gateway_port_is_one_fail(self):
        result = self.fx.run(FAKE_REACHABLE=f"{GATEWAY}:22")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.lines(result, "FAIL"), [f"  FAIL  the VM CAN connect to the gateway {GATEWAY}:22"])
        self.assertTrue(result.stdout.rstrip().endswith("1 fail"))

    def test_failed_controls_skip_the_refusal_checks(self):
        result = self.fx.run(FAKE_NO_CONTROL="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  control: 1.1.1.1:443", result.stdout)
        self.assertIn("SKIP  the refusal checks (controls failed", result.stdout)
        self.assertNotIn("refused at once", result.stdout)

    def test_a_mac_address_missing_from_the_blocked_sets_is_a_fail(self):
        result = self.fx.run(FAKE_BLOCKED="127.0.0.1,192.168.4.96,::1,198.41.0.4")
        self.assertEqual(result.returncode, 1)
        self.assertIn("2a02:1::5. If the Mac gained them after the sandbox started", result.stdout)
        self.assertIn("documented limit", result.stdout)

    def test_a_private_address_missing_from_the_sets_is_only_a_note(self):
        result = self.fx.run(FAKE_BLOCKED="127.0.0.1,::1,2a02:1::5,198.41.0.4")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("NOTE  not in the blocked sets, but refused by", result.stdout)

    def test_firewall_shape_failures(self):
        self.assertIn("unexpected accept rule", self.fx.run(FAKE_EXTRA_ACCEPT="1").stdout)
        self.assertIn("input: accepted besides loopback", self.fx.run(FAKE_OPEN_INPUT="1").stdout)

    def test_privilege_failures(self):
        self.assertIn("FAIL  server.py user", self.fx.run(FAKE_PRIV="0 CapEff 0").stdout)
        self.assertIn("FAIL  root process", self.fx.run(FAKE_ROOT="/usr/sbin/sshd").stdout)
        self.assertIn("PASS  no root process", self.fx.run(FAKE_ROOT="/sbin/init", SAFETY_ROOT_ALLOW="^/sbin/init$").stdout)
        self.assertIn("FAIL  the server's user can write under /app", self.fx.run(FAKE_APP_WRITABLE="1").stdout)

    def test_port_scan_runs_by_default_can_be_skipped_and_reports_open_ports(self):
        self.assertIn("PASS  a full scan of all 65535", self.fx.run().stdout)
        skipped = self.fx.run(SKIP_PORT_SCAN="1")
        self.assertIn("SKIP  the full TCP scan", skipped.stdout)
        self.assertNotIn("a full scan", skipped.stdout)
        found = self.fx.run(FAKE_OPEN="8021 53")
        self.assertIn("FAIL  the VM can reach these TCP ports on the Mac: 8021", found.stdout)

    def test_root_check_fails_on_an_empty_listing_or_failed_exec(self):
        for extra in ({"FAKE_NO_PROCS": "1"}, {"FAKE_FAIL_PROBE": "processes"}):
            result = self.fx.run(**extra)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("FAIL  root processes: the process listing", result.stdout)
            self.assertNotIn("PASS  no root process", result.stdout)

    def test_ipv6_check_fails_when_the_exec_fails_and_ula_is_not_global(self):
        result = self.fx.run(FAKE_FAIL_PROBE="ipv6")
        self.assertIn("FAIL  could not read the VM's IPv6 addresses", result.stdout)
        self.assertNotIn("PASS  the VM has no global IPv6", result.stdout)
        result = self.fx.run(FAKE_IPV6="fd00:0000:0000:0000:0000:0000:0000:0005 eth0")
        self.assertIn("NOTE  the VM has a unique-local IPv6 address", result.stdout)
        self.assertNotIn("global IPv6 address (", result.stdout)
        self.assertIn("PASS  the VM has no global IPv6", result.stdout)

    def test_cors_check_fails_when_curl_cannot_connect(self):
        self.fx.server.shutdown()
        self.fx.server.server_close()
        self.fx.server = None
        result = self.fx.run()
        self.assertIn("FAIL  CORS headers: curl could not get an answer", result.stdout)
        self.assertNotIn("PASS  no CORS header", result.stdout)

    def test_app_write_check_needs_a_working_control(self):
        result = self.fx.run(FAKE_NO_TMP="1")
        self.assertIn("FAIL  control: the server's user cannot write to /tmp", result.stdout)
        self.assertNotIn("PASS  the server's user cannot write under /app", result.stdout)

    def test_unshare_missing_is_not_a_pass(self):
        for code in ("126", "127"):
            result = self.fx.run(FAKE_UNSHARE_RC=code)
            self.assertIn("SKIP  the user-namespace flush attempt: unshare is not available", result.stdout)
            self.assertNotIn("PASS  the firewall table is still in place", result.stdout)

    def test_the_ipv4_accept_must_come_after_the_private4_reject(self):
        result = self.fx.run(FAKE_ACCEPT_EARLY="1")
        self.assertIn("FAIL  output: the IPv4 accept", result.stdout)

    def test_listener_on_more_than_loopback_is_a_fail(self):
        result = self.fx.run(FAKE_LSOF=f"p1\ncx\nn*:{self.fx.port}")
        self.assertIn("is open on more than 127.0.0.1", result.stdout)
        self.assertEqual(result.returncode, 1)

    def test_loose_modes_are_fails(self):
        os.chmod(os.path.join(self.fx.folder, "secret"), 0o644)
        result = self.fx.run()
        self.assertIn("FAIL  the secret file has mode", result.stdout)

    def test_a_second_vm_is_a_fail(self):
        result = self.fx.run(FAKE_EXTRA_VM="sandseek-sandbox-ffffffff")
        self.assertIn("2 sandseek VMs exist", result.stdout)

    def test_a_server_that_fetches_a_private_address_is_a_fail(self):
        self.fx.server.leak = True
        result = self.fx.run()
        self.assertIn("was FETCHED", result.stdout)
        self.assertEqual(result.returncode, 1)

    def test_no_sandbox_gives_a_clear_refusal_and_no_result_line(self):
        fx = Fixture(with_sandbox=False)
        self.addCleanup(fx.close)
        result = fx.run()
        self.assertEqual(result.returncode, 2)
        self.assertIn("no sandbox to probe", result.stderr)
        self.assertIn("research_sandbox.sh start", result.stderr)
        self.assertNotIn("Result:", result.stdout)

    def test_a_recorded_vm_that_is_not_running_is_refused(self):
        result = self.fx.run(FAKE_NAME="sandseek-sandbox-99999999")
        self.assertEqual(result.returncode, 2)
        self.assertIn("is not running", result.stderr)

    def test_unknown_argument_is_refused(self):
        self.assertEqual(self.fx.run("safety_probe.sh", "--nonsense").returncode, 2)


# --- the lifecycle script with a stub for the start/stop script --------------------------------

STUB_SANDBOX = r'''#!/bin/bash
# A stand-in for research_sandbox.sh: state in $FAKE_STATE, files in the secret folder.
folder="$SAFETY_SECRET_FOLDER"
case "$1" in
  start)
    if [ -f "$folder/lock" ]; then
      read -r pid _ < "$folder/lock"
      state="$(ps -o stat= -p "$pid" 2>/dev/null | cut -c1)"
      if [ -n "$state" ] && [ "$state" != Z ]; then echo "Another SandSeek is using the web sandbox. Close it first." >&2; exit 75; fi
    fi
    : > "$FAKE_VMS"            # leftovers of a crash are removed
    name="sandseek-sandbox-$(printf '%08x' $RANDOM$RANDOM | cut -c1-8)"
    echo "$name" > "$FAKE_VMS"
    printf '%s\n' "$name" > "$folder/vm-name"
    printf '%s\n' "$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')" > "$folder/port"
    printf 'abcd' > "$folder/secret"; printf '127.0.0.1\n' > "$folder/blocked-addresses"
    python3 -c 'import time; time.sleep(600)' sandseek-lock-holder "$folder/lock" </dev/null >/dev/null 2>&1 &
    echo "$! 1" > "$folder/lock"
    echo "web research sandbox ready" ;;
  stop)
    [ -n "$STUB_LIST_BREAKS" ] && : > "$FAKE_LIST_FAIL"
    if read -r pid _ < "$folder/lock" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        state="$(ps -o stat= -p "$pid" 2>/dev/null | cut -c1)"
        [ -z "$state" ] || [ "$state" = Z ] && break
        sleep 0.1
      done
    fi
    : > "$FAKE_VMS"
    if [ -n "$STUB_LEFTOVER_FORWARDER" ]; then   # the old forwarder still holds the port
      python3 -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5); time.sleep(600)' \
        "$(cat "$folder/port")" sandseek-leftover-forwarder </dev/null >/dev/null 2>&1 &
      sleep 0.5
    fi
    rm -f "$folder/port" "$folder/vm-name" "$folder/blocked-addresses"
    [ -n "$STUB_LEFTOVER_SECRET" ] || rm -f "$folder/secret"
    echo "web research sandbox stopped" ;;
  status) [ -f "$folder/vm-name" ] && echo answers || exit 1 ;;
esac
'''

STUB_SANDSEEK = r'''#!__PYTHON__
import hmac, http.client, os, sys
sys.path.insert(0, "__HERE__")
if os.environ.get("STUB_NO_CONTACT"):
    sys.stderr.write("error: no secret\n"); sys.exit(1)
import verify_sandbox_signature as signing
url = sys.argv[sys.argv.index("--sandbox") + 1]
port = int(url.rsplit(":", 1)[1])
secret = open(os.path.join(os.environ["SAFETY_SECRET_FOLDER"], "secret"), "rb").read()
c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
nonce = os.urandom(32).hex()
c.request("GET", "/health", headers={"X-Sandbox-Nonce": nonce, "X-Sandbox-Time": "1", "X-Sandbox-Auth": "00"})
r = c.getresponse(); body = r.read(); tag = r.getheader("X-Sandbox-Auth")
ok = tag and hmac.compare_digest(tag, signing.response_auth(secret, "GET", "/health", nonce, r.status, body))
if not ok and os.environ.get("STUB_BELIEVES"):
    print("the capital is Canberra"); sys.exit(0)
if os.environ.get("STUB_HANG"):
    open(os.environ["STUB_HANG"], "w").close()
    import time; time.sleep(4)
sys.stderr.write("error: the answer on 127.0.0.1:%d is not signed by the SandSeek sandbox; another program may be using the port\n" % port)
sys.exit(1)
'''


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture(with_sandbox=False)
        self.addCleanup(self.fx.close)
        self.vms = os.path.join(self.fx.root, "vms")
        open(self.vms, "w").close()
        write(f"{self.fx.root}/sandbox.sh", STUB_SANDBOX)
        write(f"{self.fx.root}/sandseek", STUB_SANDSEEK.replace("__PYTHON__", sys.executable).replace("__HERE__", HERE))
        self.extra = {"FAKE_VMS": self.vms, "SAFETY_SANDBOX_SCRIPT": f"{self.fx.root}/sandbox.sh",
                      "SAFETY_SANDSEEK_BIN": f"{self.fx.root}/sandseek"}
        self.addCleanup(self.kill_holders)

    def kill_holders(self):
        subprocess.run(["pkill", "-f", f"sandseek-lock-holder {self.fx.folder}"], capture_output=True)
        subprocess.run(["pkill", "-f", "sandseek-leftover-forwarder"], capture_output=True)

    def run_it(self, *args, **extra):
        return self.fx.run("safety_lifecycle.sh", *args, timeout=180, **{**self.extra, **extra})

    def test_everything_passes_and_the_run_ends_stopped(self):
        result = self.run_it()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.rstrip().splitlines()[-1].split(": ")[1].split(",")[1].strip(), "0 fail")
        for expected in ("fake sandbox (unsigned): reached the fake (GET /health), refused", "fake sandbox (wrongkey): reached the fake (GET /health), refused",
                         "a second start was refused with exit code 75", "the first sandbox is untouched",
                         "exactly one VM", "was removed; the new one is", "zero sandseek VMs remain",
                         "no secret, port, vm-name or blocked-addresses file remains",
                         "no lock holder process remains", "nothing listens on the old port"):
            self.assertIn(expected, result.stdout)
        self.assertEqual(os.listdir(self.fx.folder), ["lock"])

    def test_a_command_that_believes_the_fake_is_a_fail(self):
        result = self.run_it(STUB_BELIEVES="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL  fake sandbox (unsigned): the command was NOT stopped", result.stdout)

    def test_skip_flags(self):
        result = self.run_it(SKIP_FAKE_SANDBOX="1", SKIP_LIFECYCLE="1")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("SKIP  fake sandbox (SKIP_FAKE_SANDBOX=1)", result.stdout)
        self.assertIn("SKIP  second starter, crash and stop", result.stdout)

    def test_a_missing_command_skips_only_the_fake_part(self):
        result = self.run_it(SAFETY_SANDSEEK_BIN=f"{self.fx.root}/nothing")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("SKIP  fake sandbox: the sandseek command is not built", result.stdout)
        self.assertIn("zero sandseek VMs remain", result.stdout)

    def test_it_refuses_to_touch_a_sandbox_it_did_not_start(self):
        self.fx.record()
        result = self.run_it()
        self.assertEqual(result.returncode, 2)
        self.assertIn("does not run on one it did not start", result.stderr)
        self.assertNotIn("Result:", result.stdout)
        self.assertTrue(os.path.exists(os.path.join(self.fx.folder, "secret")))

    def test_the_fake_check_does_not_pass_when_it_never_reached_the_fake(self):
        result = self.run_it(STUB_NO_CONTACT="1")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL  fake sandbox (unsigned): the command never reached the fake (no GET /health", result.stdout)
        self.assertNotIn("PASS  fake sandbox (unsigned)", result.stdout)

    def test_a_leftover_secret_is_a_fail_and_is_not_overwritten(self):
        result = self.run_it(STUB_LEFTOVER_SECRET="1")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL  fake sandbox: could not write the throwaway secret file", result.stdout)
        self.assertNotIn("PASS  fake sandbox (", result.stdout)

    def test_a_port_held_by_an_old_forwarder_is_a_fail(self):
        result = self.run_it(STUB_LEFTOVER_FORWARDER="1")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL  fake sandbox: port", result.stdout)
        self.assertIn("already in use before the fake started", result.stdout)
        self.assertNotIn("PASS  fake sandbox (", result.stdout)

    def test_a_failed_container_list_is_never_zero_vms(self):
        result = self.run_it(STUB_LIST_BREAKS="1", FAKE_LIST_FAIL=os.path.join(self.fx.root, "list-fails"))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("FAIL  the VM list could not be read", result.stdout)
        self.assertNotIn("PASS  zero sandseek VMs remain", result.stdout)
        self.assertNotIn("PASS  the sandbox started again", result.stdout)

    def test_a_listing_failure_before_the_start_is_refused(self):
        marker = os.path.join(self.fx.root, "list-fails")
        open(marker, "w").close()
        result = self.run_it(FAKE_LIST_FAIL=marker)
        self.assertEqual(result.returncode, 2)
        self.assertIn("could not list the VMs", result.stderr)

    def test_term_removes_the_throwaway_secret_and_stops_the_sandbox(self):
        hang = os.path.join(self.fx.root, "hang-started")
        process = subprocess.Popen(
            ["bash", os.path.join(HERE, "safety_lifecycle.sh")], env=self.fx.env(**self.extra, STUB_HANG=hang),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, stdin=subprocess.DEVNULL)
        self.addCleanup(process.kill)
        deadline = time.time() + 60
        while not os.path.exists(hang) and time.time() < deadline:
            time.sleep(0.1)
        self.assertTrue(os.path.exists(hang), "the command stub never ran")
        secret = os.path.join(self.fx.folder, "secret")
        self.assertTrue(os.path.exists(secret), "the throwaway secret should exist while the fake runs")
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=60)
        self.assertEqual(process.returncode, 143)
        self.assertFalse(os.path.exists(secret), "the throwaway secret was left behind")
        with open(self.vms) as handle:
            self.assertEqual(handle.read().strip(), "", "the sandbox the script started was left running")
        self.assertEqual(os.listdir(self.fx.folder), ["lock"])

    def test_cleanup_leaves_a_secret_that_is_not_the_throwaway(self):
        # The throwaway is only removed while it still holds what was written.
        hang = os.path.join(self.fx.root, "hang-started")
        process = subprocess.Popen(
            ["bash", os.path.join(HERE, "safety_lifecycle.sh")], env=self.fx.env(**self.extra, STUB_HANG=hang),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, stdin=subprocess.DEVNULL)
        self.addCleanup(process.kill)
        deadline = time.time() + 60
        while not os.path.exists(hang) and time.time() < deadline:
            time.sleep(0.1)
        secret = os.path.join(self.fx.folder, "secret")
        with open(secret, "w") as handle:
            handle.write("someone-elses")
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=60)
        with open(secret) as handle:
            self.assertEqual(handle.read(), "someone-elses")

    def test_running_without_a_sandbox_is_refused(self):
        result = self.run_it("--running")
        self.assertEqual(result.returncode, 2)
        self.assertIn("no sandbox to work on", result.stderr)


if __name__ == "__main__":
    unittest.main()
