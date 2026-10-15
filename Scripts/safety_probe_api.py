#!/usr/bin/env python3
"""Mac-side helper of Scripts/safety_probe.sh: the checks that need the sandbox's
secret, so that the shell script never holds the secret in a variable or on a
command line.

  safety_probe_api.py secret-leaks SECRET_FILE CONTAINER_PROGRAM VM_NAME
  safety_probe_api.py hostile SECRET_FILE PORT BLOCKED_FILE [ADDRESS...]

Both print one line per result, "PASS text", "FAIL text", "NOTE text" or
"SKIP text", for the shell script to count. Neither prints the secret, or
anything made from it, or an exception's text (only its type).

secret-leaks   reads the secret and looks for its text in the output of
               `container inspect VM_NAME` and in the command line of every
               process on the Mac.
hostile        sends signed requests to the sandbox on 127.0.0.1:PORT that it
               must refuse, each with its error code: addresses of the private
               ranges, loopback, link-local, IPv4-mapped IPv6, NAT64, 6to4 and
               Teredo, every ADDRESS given (the Mac's own addresses and the
               VM's gateway), addresses with credentials, other schemes,
               other ports, and bad search arguments; one redirect to a
               private address through a public redirect service, when one
               answers. A signed /health request comes first as the control,
               and its count of blocked addresses is compared with the lines
               in BLOCKED_FILE.

The request and answer signatures are the formulas of Scripts/verify_sandbox_signature.py.
Python 3 standard library only (3.9 or newer).
"""

from __future__ import annotations

import hmac
import http.client
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_sandbox_signature as signing  # noqa: E402

FETCH_TIMEOUT = 100  # the sandbox's own limit for one request is 90 s

# Public redirect services, tried in this order. The redirect target is a
# private address over plain http, so the sandbox's own per-hop address check
# is what refuses it (a service that refuses such a target itself, or that
# redirects from https to http, proves nothing about the sandbox).
REDIRECT_SERVICES = ("httpbingo.org", "httpbin.org")
REDIRECT_TARGET = "http://169.254.169.254/latest/meta-data/"

NO_HOOK_REASON = (
    "the server has no test hook for an oversize or compressed page "
    "(Sandbox/server.py takes its size limits from the image, not from the request), "
    "so a page larger than the limit would need a public file of that size; "
    "Sandbox/test_server.py covers the limits")


def say(kind: str, text: str) -> None:
    print(f"{kind} {text}", flush=True)


def signed_call(port: int, secret: bytes, method: str, path: str, body: bytes = b"",
                content_type: str = "application/json", timeout: float = 30):
    """One signed request. Returns (status, answer_is_signed, parsed JSON or None)."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    nonce = os.urandom(32).hex()
    stamp = str(int(time.time()))
    headers = {"Host": f"127.0.0.1:{port}", "X-Sandbox-Nonce": nonce, "X-Sandbox-Time": stamp,
               "X-Sandbox-Auth": signing.request_auth(secret, method, path, nonce, stamp, body)}
    if method == "POST":
        headers["Content-Type"] = content_type
    try:
        connection.request(method, path, body=body or None, headers=headers)
        response = connection.getresponse()
        data = response.read()
        status, tag = response.status, response.getheader("X-Sandbox-Auth")
    finally:
        connection.close()
    expected = signing.response_auth(secret, method, path, nonce, status, data)
    signed = tag is not None and hmac.compare_digest(tag.strip().lower(), expected)
    try:
        parsed = json.loads(data)
    except ValueError:
        parsed = None
    return status, signed, parsed


def error_code(parsed) -> str:
    if isinstance(parsed, dict) and isinstance(parsed.get("error"), dict):
        code = parsed["error"].get("code", "")
        return code if isinstance(code, str) else ""
    return ""


def url_for(address: str) -> str:
    return f"http://[{address}]/" if ":" in address else f"http://{address}/"


# --- secret-leaks -----------------------------------------------------------------

def secret_leaks(secret_file: str, container: str, name: str) -> int:
    try:
        secret = signing.read_secret(secret_file)
    except signing.SecretFileError as error:
        say("FAIL", f"cannot read the secret file to compare it: {error}")
        return 0
    try:
        inspected = subprocess.run([container, "inspect", name], stdin=subprocess.DEVNULL,
                                   capture_output=True, timeout=60)
        if inspected.returncode != 0 and not inspected.stdout:
            say("FAIL", "could not run `container inspect` to look for the secret in it")
        elif secret in inspected.stdout + inspected.stderr:
            say("FAIL", "the secret appears in the output of `container inspect`")
        else:
            say("PASS", "the secret does not appear in the output of `container inspect`")
    except (OSError, subprocess.SubprocessError) as error:
        say("FAIL", f"could not run `container inspect`: {type(error).__name__}")
    try:
        listing = subprocess.run(["ps", "-axww", "-o", "command="], stdin=subprocess.DEVNULL,
                                 capture_output=True, timeout=60)
        if listing.returncode != 0 and not listing.stdout:
            say("FAIL", "could not list the processes to look for the secret on a command line")
        elif secret in listing.stdout:
            say("FAIL", "the secret appears on the command line of a process on the Mac")
        else:
            say("PASS", "the secret is on no process command line on the Mac")
    except (OSError, subprocess.SubprocessError) as error:
        say("FAIL", f"could not list the processes: {type(error).__name__}")
    return 0


# --- hostile ------------------------------------------------------------------------

class Group:
    """Cases that share one expectation; one PASS line when all hold."""

    def __init__(self, port: int, secret: bytes, title: str, expected: tuple):
        self.port, self.secret, self.title, self.expected = port, secret, title, expected
        self.count = 0
        self.failed = False

    def fetch(self, url: str, expected: tuple = ()) -> None:
        want = expected or self.expected
        self.count += 1
        shown = url if len(url) <= 80 else url[:77] + "..."
        try:
            status, signed, parsed = signed_call(
                self.port, self.secret, "POST", "/v1/fetch",
                json.dumps({"url": url}).encode(), timeout=FETCH_TIMEOUT)
        except (OSError, http.client.HTTPException) as error:
            self.failed = True
            say("FAIL", f"{self.title}: {shown} got no answer ({type(error).__name__})")
            return
        code = error_code(parsed)
        if status == 200:
            self.failed = True
            say("FAIL", f"{self.title}: {shown} was FETCHED (HTTP 200)")
        elif not signed:
            self.failed = True
            say("FAIL", f"{self.title}: the answer for {shown} was not signed")
        elif code not in want:
            self.failed = True
            say("FAIL", f"{self.title}: {shown} was refused with {code or 'no code'} "
                        f"(HTTP {status}), expected {' or '.join(want)}")

    def search(self, payload: dict, label: str) -> None:
        self.count += 1
        try:
            status, signed, parsed = signed_call(
                self.port, self.secret, "POST", "/v1/search", json.dumps(payload).encode())
        except (OSError, http.client.HTTPException) as error:
            self.failed = True
            say("FAIL", f"{self.title}: {label} got no answer ({type(error).__name__})")
            return
        code = error_code(parsed)
        if status == 200 or not signed or code not in self.expected:
            self.failed = True
            say("FAIL", f"{self.title}: {label} gave HTTP {status}, "
                        f"{'signed' if signed else 'unsigned'}, code {code or 'none'}")

    def done(self) -> None:
        if not self.failed:
            say("PASS", f"{self.title}: {self.count} refused with {' or '.join(self.expected)}")


PRIVATE_V4 = ["http://127.0.0.1/", "http://10.0.0.1/", "http://172.16.0.1/",
              "http://192.168.1.1/", "http://100.64.0.1/",
              "http://169.254.169.254/latest/meta-data/", "http://0.0.0.0/"]
IPV6_FORMS = ["http://[::1]/", "http://[fe80::1]/", "http://[fd00::1]/"]
MAPPED = ["http://[::ffff:127.0.0.1]/", "http://[::ffff:7f00:1]/", "http://[::ffff:10.0.0.1]/",
          "http://[::ffff:169.254.169.254]/", "http://[::ffff:192.168.1.1]/"]
EMBEDDED = ["http://[64:ff9b::a00:1]/", "http://[64:ff9b::7f00:1]/", "http://[64:ff9b:1::a00:1]/",
            "http://[2002:c0a8:101::1]/", "http://[2002:7f00:1::1]/",
            "http://[2001:0:4136:e378:8000:63bf:3fff:fdd2]/"]
CREDENTIALS = ["http://user:pass@example.com/", "https://user@example.com/",
               "http://example.com@127.0.0.1/", "http://:pass@example.com/"]
SCHEMES = ["ftp://example.com/", "file:///etc/passwd", "gopher://example.com/",
           "javascript:alert(1)", "data:text/plain,hello"]
PORTS = ["http://example.com:8080/", "https://example.com:8443/", "http://example.com:22/"]


def redirect_check(port: int, secret: bytes) -> None:
    """A public redirect service sends the sandbox to a private address; the
    sandbox must refuse that hop. Services that do not answer, or that refuse the
    target themselves, are passed over."""
    for service in REDIRECT_SERVICES:
        control = f"http://{service}/redirect-to?url=http://example.com/"
        try:
            status, signed, parsed = signed_call(
                port, secret, "POST", "/v1/fetch", json.dumps({"url": control}).encode(),
                timeout=FETCH_TIMEOUT)
        except (OSError, http.client.HTTPException):
            say("NOTE", f"redirect service {service}: no answer from the sandbox for the control")
            continue
        if status != 200 or not signed:
            say("NOTE", f"redirect service {service} did not answer usefully "
                        f"(control: HTTP {status}, {error_code(parsed) or 'no code'}); trying the next")
            continue
        url = f"http://{service}/redirect-to?url={REDIRECT_TARGET}"
        try:
            status, signed, parsed = signed_call(
                port, secret, "POST", "/v1/fetch", json.dumps({"url": url}).encode(),
                timeout=FETCH_TIMEOUT)
        except (OSError, http.client.HTTPException) as error:
            say("FAIL", f"redirect to a private address via {service} got no answer "
                        f"({type(error).__name__})")
            return
        code = error_code(parsed)
        if status == 200:
            say("FAIL", f"redirect to a private address via {service} was FOLLOWED (HTTP 200)")
        elif not signed:
            say("FAIL", f"redirect to a private address via {service}: the answer was not signed")
        elif code == "blocked_address":
            say("PASS", f"redirect to a private address via {service} refused with blocked_address "
                        "(the control redirect to a public page worked)")
        else:
            say("NOTE", f"redirect service {service} answered the private target with "
                        f"{code or 'no code'} (HTTP {status}), not by the sandbox's own check; "
                        "trying the next")
            continue
        return
    say("SKIP", "redirect to a private address: no public redirect service answered usefully "
                f"({', '.join(REDIRECT_SERVICES)})")
    say("NOTE", "the redirect check needs the internet and one of those services; "
                "Sandbox/test_server.py and Scripts/research_address_check.py cover redirects offline")


def hostile(secret_file: str, port: int, blocked_file: str, addresses: list) -> int:
    try:
        secret = signing.read_secret(secret_file)
    except signing.SecretFileError as error:
        say("FAIL", f"cannot read the secret file to sign requests: {error}")
        return 0
    # The control: a signed health request gets a signed 200 and the count of
    # blocked addresses the launcher wrote.
    try:
        status, signed, parsed = signed_call(port, secret, "GET", "/health")
    except (OSError, http.client.HTTPException) as error:
        say("FAIL", f"control: the signed /health request got no answer ({type(error).__name__}); "
                    "the hostile requests were not sent")
        return 0
    if status != 200 or not signed or not isinstance(parsed, dict) or parsed.get("status") != "ok":
        say("FAIL", f"control: the signed /health request gave HTTP {status}, "
                    f"{'signed' if signed else 'unsigned'}; the hostile requests were not sent")
        return 0
    say("PASS", "control: a signed /health request gets a signed answer")
    try:
        with open(blocked_file, encoding="ascii") as handle:
            listed = len([line for line in handle.read().split() if line])
    except (OSError, UnicodeError):
        listed = -1
    reported = parsed.get("blocked_addresses")
    if listed > 0 and reported == listed:
        say("PASS", f"the server refuses all {listed} addresses in the launcher's list")
    else:
        say("FAIL", f"the server reports {reported} blocked addresses, the launcher's list has "
                    f"{listed if listed >= 0 else 'no readable list'} (rebuild the image?)")

    refused = ("blocked_address",)
    group = Group(port, secret, "private, loopback, link-local and shared IPv4 addresses", refused)
    for url in PRIVATE_V4:
        group.fetch(url)
    group.done()
    group = Group(port, secret, "loopback, link-local and unique-local IPv6 addresses", refused)
    for url in IPV6_FORMS:
        group.fetch(url)
    group.done()
    group = Group(port, secret, "IPv4-mapped IPv6 addresses", refused)
    for url in MAPPED:
        group.fetch(url)
    group.done()
    group = Group(port, secret, "NAT64, 6to4 and Teredo addresses", refused)
    for url in EMBEDDED:
        group.fetch(url)
    group.done()
    group = Group(port, secret, "localhost", ("blocked_address", "dns_error"))
    group.fetch("http://localhost/")
    group.done()
    if addresses:
        group = Group(port, secret, f"the gateway and the Mac's own addresses ({len(addresses)})",
                      refused)
        for address in addresses:
            group.fetch(url_for(address))
        group.done()
    else:
        say("FAIL", "no Mac address was given, so the Mac's own addresses were not tried")
    group = Group(port, secret, "credentials in the address", ("invalid_url",))
    for url in CREDENTIALS:
        group.fetch(url)
    group.done()
    group = Group(port, secret, "schemes other than http and https", ("invalid_url",))
    for url in SCHEMES:
        group.fetch(url)
    group.done()
    group = Group(port, secret, "ports other than 80 and 443", ("blocked_port",))
    for url in PORTS:
        group.fetch(url)
    group.done()

    # /v1/search takes no address: its query is text for the search engine. What
    # the server can refuse there is a bad query or count.
    group = Group(port, secret, "bad search arguments", ("invalid_argument",))
    group.search({"query": ""}, "an empty query")
    group.search({"query": "x" * 401}, "a 401-character query")
    group.search({"query": "q", "max_results": 0}, "max_results 0")
    group.search({"query": "q", "max_results": 11}, "max_results 11")
    group.done()
    say("NOTE", "/v1/search takes text, not an address, so the address forms above go to /v1/fetch only")

    try:
        status, signed, parsed = signed_call(
            port, secret, "POST", "/v1/fetch", b'{"url":"https://example.com/"}',
            content_type="text/plain")
    except (OSError, http.client.HTTPException) as error:
        say("FAIL", f"a signed text/plain POST got no answer ({type(error).__name__})")
    else:
        if status == 415 and signed:
            say("PASS", "a signed POST that is not application/json is refused (415)")
        else:
            say("FAIL", f"a signed text/plain POST gave HTTP {status}, "
                        f"{'signed' if signed else 'unsigned'}; 415 was expected")

    say("SKIP", f"oversize or compressed page: {NO_HOOK_REASON}")
    redirect_check(port, secret)
    return 0


def main(argv: list) -> int:
    try:
        if len(argv) == 5 and argv[1] == "secret-leaks":
            return secret_leaks(argv[2], argv[3], argv[4])
        if len(argv) >= 5 and argv[1] == "hostile":
            if not (argv[3].isascii() and argv[3].isdigit()):
                sys.exit("PORT must be a number")
            return hostile(argv[2], int(argv[3]), argv[4], argv[5:])
    except Exception as error:  # never print the text of an error: it could hold the secret
        say("FAIL", f"the helper stopped with {type(error).__name__}")
        return 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
