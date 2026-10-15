#!/usr/bin/env python3
"""Asks the running sandbox to open addresses it must refuse, and checks that it does.

This is the address half of the sandbox's protection, tried from outside and
without a model. It sends `open_page` requests (the sandbox's POST /v1/fetch),
signed with the sandbox's secret file, straight to the sandbox on
127.0.0.1 (on the port `start` recorded) and expects every one of these to be
refused:

  private       loopback, private, link-local, shared, multicast and reserved
                IPv4 addresses, and IPv6 forms that hide such addresses
                (mapped, NAT64, 6to4, Teredo, site-local, documentation)
  numeric       spellings of 127.0.0.1 and other private addresses that a C
                library reads as an address: 2130706433, 0x7f000001, 127.1,
                0177.0.0.1, fullwidth digits and dots. The sandbox refuses
                every number that is not a plain dotted quad by its shape
                (invalid_url), because libc systems disagree on them (macOS
                reads 0177.0.0.1 as 177.0.0.1, glibc as 127.0.0.1)
  names         localhost and the container gateway name
  dns           host names that resolve to private addresses (localtest.me,
                *.nip.io and *.sslip.io; --1.sslip.io, which is ::1 and is
                only noted when a resolver cannot resolve it); these need DNS, so a network that
                blocks outside DNS or filters answers with private addresses
                (DNS rebinding protection) makes them "inconclusive"
  shape         other schemes, user names in the address, ports other than
                80 and 443, malformed addresses

and that a public page (https://example.com/) still loads, so that a refusal
means the check worked and not that the sandbox is down. The sandbox lists
the same cases in Sandbox/test_server.py and, shorter, in
`Scripts/research_sandbox.sh selftest`; this script is the long list, runnable
against the live sandbox.

Python 3 standard library only. Run it with the sandbox started
(`Scripts/research_sandbox.sh start`):

  python3 Scripts/research_address_check.py
  python3 Scripts/research_address_check.py --label "after the 0.1 build" \\
      --output address-check.txt

Exit status: 0 every address was refused and the control page loaded;
1 at least one address was NOT refused; 2 the sandbox does not answer (or a
bad option); 3 nothing was wrongly accepted, but some cases could not be
judged (a DNS name did not resolve, or the control page did not load).
"""

from __future__ import annotations

import argparse
import datetime
import hmac
import http.client
import json
import os
import re
import sys
import time
import unicodedata
import urllib.parse
from dataclasses import dataclass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_sandbox_signature as signing  # noqa: E402

# Without --sandbox the port is found as for verify_sandbox_signature.py: the
# environment, else the file `port` beside the secret.
DEFAULT_SECRET_FILE = os.path.join(os.path.expanduser("~"), "Library", "Application Support",
                                   "SandSeek", "sandbox", "secret")
LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "::1")
CONTROL_URL = "https://example.com/"

# Error codes with which the sandbox says "I will not fetch that address".
REFUSAL_CODES = frozenset({"blocked_address", "blocked_port", "invalid_url"})


@dataclass(frozen=True)
class Case:
    group: str
    url: str
    # "address": a literal or numeric address; the sandbox must refuse it (an
    #   address a C library cannot parse ends in dns_error, which is also a
    #   refusal: nothing was fetched).
    # "name": a host name that never leaves the VM (localhost and similar);
    #   it may also fail to resolve.
    # "resolves": a name that resolves to a private address. The sandbox must
    #   answer blocked_address. A name that does not resolve here proves
    #   nothing about the address check ("inconclusive").
    # "covered": like "resolves", but for a name whose address another case
    #   already checks (--1.sslip.io is ::1, see http://[::1]/). Resolvers
    #   that cannot resolve it (macOS rejects such names) only get a note,
    #   which does not make the run inconclusive. Anything other than a
    #   refusal still fails.
    # "shape": refused because of the form of the address.
    kind: str


def _cases(group: str, kind: str, urls: list[str]) -> list[Case]:
    return [Case(group, url, kind) for url in urls]


CASES: list[Case] = (
    _cases("private", "address", [
        "http://127.0.0.1/",
        "http://127.0.0.1:80/",
        "https://127.0.0.1/",
        "http://127.255.255.254/",
        "http://10.0.0.1/",
        "http://172.16.0.1/",
        "http://172.31.255.255/",
        "http://192.168.1.1/",
        "http://192.168.64.1/",
        "http://169.254.169.254/latest/meta-data/",
        "http://169.254.0.1/",
        "http://100.64.0.1/",
        "http://100.100.100.200/",
        "http://198.18.0.1/",
        "http://192.0.0.1/",
        "http://192.0.2.1/",
        "http://0.0.0.0/",
        "http://224.0.0.1/",
        "http://240.0.0.1/",
        "http://255.255.255.255/",
        "http://[::1]/",
        "http://[::]/",
        "http://[fd00::1]/",
        "http://[fc00::1]/",
        "http://[fe80::1]/",
        "http://[fe80::1%eth0]/",
        "http://[fec0::1]/",
        "http://[::ffff:127.0.0.1]/",
        "http://[::ffff:7f00:1]/",
        "http://[::ffff:192.168.64.1]/",
        "http://[::ffff:a00:1]/",
        "http://[::127.0.0.1]/",
        "http://[::10.0.0.1]/",
        "http://[::ffff:0:127.0.0.1]/",
        "http://[64:ff9b::a00:1]/",
        "http://[64:ff9b::c0a8:1]/",
        "http://[64:ff9b:1::a00:1]/",
        "http://[2002:c0a8:101::1]/",
        "http://[2002:7f00:1::1]/",
        "http://[2001:0:4136:e378:8000:63bf:3fff:fdd2]/",
        "http://[2001:db8::1]/",
        "http://[ff02::1]/",
    ])
    + _cases("numeric", "address", [
        "http://2130706433/",
        "http://3232235521/",
        "http://3232252929/",
        "http://0x7f000001/",
        "http://0xc0a80001/",
        "http://0x7f.1/",
        "http://0x7f.0x0.0x0.0x1/",
        "http://0177.0.0.1/",
        "http://017700000001/",
        "http://127.1/",
        "http://127.0.1/",
        "http://0/",
        "http://0x0/",
        "http://127.0.0.1./",
        "http://127.0.0.1.:80/",
        "http://①②⑦.0.0.1/",
        "http://127。0。0。1/",
        "http://１２７.0.0.1/",
    ])
    + _cases("names", "name", [
        "http://localhost/",
        "http://LOCALHOST/",
        "http://localhost./",
        "http://foo.localhost/",
        "http://localhost.localdomain/",
        "http://ip6-localhost/",
        "http://ip6-loopback/",
        "http://host.container.internal/",
        "http://metadata.google.internal/",
    ])
    + _cases("dns", "resolves", [
        # Public names whose DNS answer is a private address.
        "http://localtest.me/",
        "http://127.0.0.1.nip.io/",
        "http://10.0.0.1.nip.io/",
        "http://192.168.64.1.nip.io/",
        "http://169.254.169.254.nip.io/",
        "http://127-0-0-1.sslip.io/",
        "http://192-168-64-1.sslip.io/",
    ])
    + _cases("dns", "covered", [
        "http://--1.sslip.io/",
    ])
    + _cases("shape", "shape", [
        "file:///etc/passwd",
        "ftp://example.com/",
        "gopher://example.com/",
        "javascript:alert(1)",
        "data:text/html,hello",
        "http://user:pw@example.com/",
        "http://example.com%2f@127.0.0.1/",
        "http://127.0.0.1%2f@example.com/",
        "http://example.com\\@127.0.0.1/",
        "http://example.com:8080/",
        "https://example.com:80/",
        "http://example.com:22/",
        "http://example.com:11434/",
        "http:///nohost",
        "http://[::1/",
        "http://example.com＠127.0.0.1/",
        "http://example.com/a\x1b[2J",
        "http://example.com/a b",
        "http://example.com/​hidden",
        "not a url",
        "",
    ])
)

GROUPS = ["private", "numeric", "names", "dns", "shape"]


def classify(case: Case, status: int, payload: object) -> tuple[str, str]:
    """(verdict, detail) for one answer of the sandbox.

    verdict is "refused", "note", "inconclusive" or "FAIL". detail says what the
    sandbox answered."""
    code = ""
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict):
            code = str(error.get("code", ""))
    if status == 200:
        return "FAIL", "HTTP 200: the sandbox fetched it"
    if not code:
        return "FAIL", f"HTTP {status} without an error code (not a refusal)"
    if case.kind in ("resolves", "covered"):
        if code == "blocked_address":
            return "refused", code
        if code == "dns_error" and case.kind == "covered":
            return "note", "dns_error: the name did not resolve here; its address is checked by another case"
        if code == "dns_error":
            return "inconclusive", "dns_error: the name did not resolve here, so the address check was not tried"
        return "FAIL", f"{code} (HTTP {status}): not refused for its private address"
    if code == "dns_error":
        # Counts as refused (a name like localhost resolves through the VM's
        # hosts file, so a failed lookup means it was not reached), but it is
        # weaker evidence than an address check, and the report says so.
        return "refused", "dns_error (did not resolve; weaker evidence than an address check)"
    if code in REFUSAL_CODES:
        return "refused", code
    return "FAIL", f"{code} (HTTP {status}): the sandbox did not refuse the address itself"


def is_loopback(url: str) -> bool:
    try:
        return (urllib.parse.urlsplit(url).hostname or "").lower() in LOOPBACK_HOSTS
    except ValueError:
        return False


class UnsignedAnswer(OSError):
    """The answer did not carry the signature only the real sandbox can make."""


def signed_call(sandbox: str, secret: bytes, method: str, path: str, body: bytes,
                timeout: float) -> tuple[int, bytes]:
    """One signed request; (HTTP status, answer body). The sandbox refuses a
    request that is not signed, and an answer that is not signed correctly
    for this request is not trusted: it raises UnsignedAnswer."""
    parts = urllib.parse.urlsplit(sandbox)
    connection = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=timeout)
    nonce = os.urandom(32).hex()
    stamp = str(int(time.time()))
    headers = {"Host": f"127.0.0.1:{parts.port or 80}",
               "X-Sandbox-Nonce": nonce, "X-Sandbox-Time": stamp,
               "X-Sandbox-Auth": signing.request_auth(secret, method, path, nonce, stamp, body)}
    if method == "POST":
        headers["Content-Type"] = "application/json"
    try:
        connection.request(method, path, body=body or None, headers=headers)
        response = connection.getresponse()
        data = response.read()
        status, auth = response.status, response.getheader("X-Sandbox-Auth")
    finally:
        connection.close()
    expected = signing.response_auth(secret, method, path, nonce, status, data)
    if auth is None or not hmac.compare_digest(auth.strip().lower(), expected):
        raise UnsignedAnswer("the answer is not signed with the sandbox's secret")
    return status, data


def post_fetch(sandbox: str, secret: bytes, url: str, timeout: float) -> tuple[int, object]:
    """POST /v1/fetch with {"url": url}; (HTTP status, decoded JSON or the raw text)."""
    status, data = signed_call(sandbox, secret, "POST", "/v1/fetch",
                               json.dumps({"url": url}).encode(), timeout)
    try:
        return status, json.loads(data)
    except ValueError:
        return status, data.decode("utf-8", "replace")[:200]


def sandbox_answers(sandbox: str, secret: bytes) -> bool:
    try:
        status, data = signed_call(sandbox, secret, "GET", "/health", b"", 5)
        return status == 200 and b'"ok"' in data
    except (OSError, http.client.HTTPException):
        return False


def printable(text: str) -> str:
    """Control and invisible format characters shown as \\xNN or \\uNNNN, so
    that the report is plain visible text and an address that hides a
    character can be read."""
    if text == "":
        return "(empty)"

    def show(char: str) -> str:
        code = ord(char)
        if code < 0x100:
            return f"\\x{code:02x}"
        return f"\\u{code:04x}" if code < 0x10000 else f"\\U{code:08x}"

    return "".join(show(c) if unicodedata.category(c) in ("Cc", "Cf") else c for c in text)


class Report:
    def __init__(self) -> None:
        self.lines: list[str] = []

    def emit(self, text: str = "") -> None:
        print(text, flush=True)
        self.lines.append(text)

    def save(self, path: str) -> None:
        with open(path, "x", encoding="utf-8") as handle:  # never overwrite
            handle.write("\n".join(self.lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--sandbox",
                        help="the sandbox, such as http://127.0.0.1:49152 (default: the port "
                             "SANDSEEK_SANDBOX_PORT names, else the one `start` recorded); "
                             "loopback only")
    parser.add_argument("--secret-file", default=DEFAULT_SECRET_FILE, metavar="FILE",
                        help="the sandbox's secret, written by `research_sandbox.sh start` "
                             "(default: SandSeek/sandbox/secret in Application Support)")
    parser.add_argument("--only", choices=GROUPS, action="append",
                        help="run only this group (repeatable)")
    parser.add_argument("--no-control", action="store_true",
                        help="do not fetch the public control page (for a Mac without internet)")
    parser.add_argument("--timeout", type=float, default=60,
                        help="seconds to wait for one answer (default 60)")
    parser.add_argument("--label", help="name of this run, written at the top of the report")
    parser.add_argument("--output", metavar="FILE",
                        help="also write the report to this new file")
    parser.add_argument("--list", action="store_true",
                        help="print the addresses that would be tried, then exit")
    args = parser.parse_args()

    selected = [c for c in CASES if not args.only or c.group in args.only]
    if args.list:
        for case in selected:
            print(f"{case.group:<8}{printable(case.url)}")
        print(f"{len(selected)} addresses")
        return 0
    if args.sandbox and not is_loopback(args.sandbox):
        parser.error("--sandbox must be a loopback address, such as http://127.0.0.1:49152")
    if args.output and os.path.exists(args.output):
        parser.error(f"{args.output} already exists; choose a new --output file")
    try:
        secret = signing.read_secret(args.secret_file)
    except signing.SecretFileError as error:
        print(f"error: {error}; start the sandbox with Scripts/research_sandbox.sh start",
              file=sys.stderr)
        return 2
    if not args.sandbox:
        port = signing.sandbox_port(args.secret_file)
        if port is None:
            print("error: no sandbox port is recorded; start the sandbox with "
                  "Scripts/research_sandbox.sh start, or pass --sandbox", file=sys.stderr)
            return 2
        args.sandbox = f"http://127.0.0.1:{port}"
    if not sandbox_answers(args.sandbox, secret):
        print(f"error: the sandbox does not answer at {args.sandbox}, or its answer is not "
              "signed with the current secret; start it with Scripts/research_sandbox.sh start",
              file=sys.stderr)
        return 2

    report = Report()
    report.emit("SandSeek address check")
    if args.label:
        report.emit("Label: " + printable(args.label.strip()[:200]))
    report.emit("Date: " + datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"))
    report.emit(f"Sandbox: {args.sandbox}")
    report.emit(f"Addresses: {len(selected)} ({', '.join(sorted({c.group for c in selected}))})")
    report.emit()

    counts = {"refused": 0, "note": 0, "inconclusive": 0, "FAIL": 0}
    for case in selected:
        try:
            status, payload = post_fetch(args.sandbox, secret, case.url, args.timeout)
        except (OSError, http.client.HTTPException) as error:
            report.emit(f"FAIL  {case.group:<8}{printable(case.url)}")
            report.emit(f"        no answer from the sandbox: {error}")
            counts["FAIL"] += 1
            continue
        verdict, detail = classify(case, status, payload)
        counts[verdict] += 1
        mark = {"refused": "ok", "note": "note", "inconclusive": "warn", "FAIL": "FAIL"}[verdict]
        report.emit(f"{mark:<6}{case.group:<8}{printable(case.url)}  ->  {detail}")

    control_ok: bool | None = None
    if not args.no_control:
        report.emit()
        try:
            status, payload = post_fetch(args.sandbox, secret, CONTROL_URL, args.timeout)
            control_ok = status == 200 and isinstance(payload, dict) and bool(payload.get("text"))
        except (OSError, http.client.HTTPException):
            control_ok = False
        if control_ok:
            report.emit(f"ok    control   {CONTROL_URL} loaded, so refusals above are real refusals")
        else:
            report.emit(f"warn  control   {CONTROL_URL} did not load; check the VM's internet access. "
                        "Refusals above may only mean that the sandbox cannot fetch anything.")

    report.emit()
    report.emit("== Summary ==")
    if args.label:
        report.emit("Label: " + printable(args.label.strip()[:200]))
    report.emit(f"{counts['refused']} refused, {counts['inconclusive']} inconclusive, "
                f"{counts['FAIL']} NOT refused (of {len(selected)} addresses)"
                + (f", {counts['note']} noted" if counts["note"] else ""))
    if counts["FAIL"]:
        status_code = 1
        report.emit("RESULT: FAIL. The sandbox accepted an address it should refuse.")
    elif counts["inconclusive"] or control_ok is False:
        status_code = 3
        report.emit("RESULT: inconclusive. Nothing was wrongly accepted, but some cases "
                    "could not be judged (see the warn lines).")
    else:
        status_code = 0
        report.emit("RESULT: pass. Every address was refused"
                    + ("." if control_ok is None else ", and the public control page loaded."))
    if args.output:
        try:
            report.save(args.output)
        except OSError as error:
            print(f"error: could not write {args.output}: {error}", file=sys.stderr)
            return 2
        print(f"report written to {args.output}")
    return status_code


if __name__ == "__main__":
    sys.exit(main())
