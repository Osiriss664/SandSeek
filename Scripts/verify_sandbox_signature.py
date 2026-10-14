#!/usr/bin/env python3
"""Sends one signed request to the sandbox and checks the signature of the
answer, for the Mac test steps.

  verify_sandbox_signature.py SECRET_FILE [PORT]

Sends GET /health to 127.0.0.1:PORT (default 9100), signed with the secret in
SECRET_FILE, and checks that the answer is signed with the same secret for that
request. The secret is read from the file and never printed or taken from an
argument, so it does not appear in `ps`. The formulas are the ones in
Sandbox/server.py. Prints one line; exits 0 when the answer is a signed 200 that
matches, 1 otherwise.
"""

import hashlib
import hmac
import http.client
import os
import stat
import sys
import time

REQUEST_LABEL = "sandseek-sandbox-req-v1"
RESPONSE_LABEL = "sandseek-sandbox-resp-v1"
MIN_SECRET_BYTES = 32
MAX_SECRET_BYTES = 4096


class SecretFileError(Exception):
    """The secret file cannot be used; the message never holds the secret."""


def read_secret(path: str) -> bytes:
    """The secret in a file, without one trailing newline. The file is opened
    without following a symlink and must be a regular file that is yours, with
    no group or other permission bits, and 32 to 4096 bytes long (the checks
    SandSeek itself makes), so a planted file cannot make this tool sign with a
    key of someone else's choosing."""
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
                             | getattr(os, "O_NONBLOCK", 0))
    except OSError as error:
        raise SecretFileError(f"cannot open the secret file: {error.strerror}") from None
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise SecretFileError("the secret file is not a regular file")
        if info.st_uid != os.geteuid():
            raise SecretFileError("the secret file is not owned by you")
        if info.st_mode & 0o077:
            raise SecretFileError("the secret file can be read or written by others; "
                                  "run chmod 600 on it")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            value = handle.read(MAX_SECRET_BYTES + 2)
    except OSError as error:
        raise SecretFileError(f"cannot read the secret file: {error.strerror}") from None
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    value = value.removesuffix(b"\n")
    if not MIN_SECRET_BYTES <= len(value) <= MAX_SECRET_BYTES:
        raise SecretFileError(
            f"the secret must be {MIN_SECRET_BYTES} to {MAX_SECRET_BYTES} bytes long")
    return value


def request_auth(secret: bytes, method: str, path: str, nonce: str, timestamp: str,
                 body: bytes) -> str:
    text = "\n".join((REQUEST_LABEL, method, path, nonce, timestamp,
                      hashlib.sha256(body).hexdigest()))
    return hmac.new(secret, text.encode(), hashlib.sha256).hexdigest()


def response_auth(secret: bytes, method: str, path: str, nonce: str, status: int,
                  body: bytes) -> str:
    text = "\n".join((RESPONSE_LABEL, method, path, nonce, str(status),
                      hashlib.sha256(body).hexdigest()))
    return hmac.new(secret, text.encode(), hashlib.sha256).hexdigest()


def main(argv):
    if len(argv) not in (2, 3):
        sys.exit(__doc__)
    try:
        secret = read_secret(argv[1])
    except SecretFileError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    port = int(argv[2]) if len(argv) == 3 else 9100
    method, path = "GET", "/health"
    nonce = os.urandom(32).hex()
    stamp = str(int(time.time()))
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request(method, path, headers={
            "X-Sandbox-Nonce": nonce,
            "X-Sandbox-Time": stamp,
            "X-Sandbox-Auth": request_auth(secret, method, path, nonce, stamp, b""),
        })
        response = connection.getresponse()
        body = response.read()
        status = response.status
        signature = response.getheader("X-Sandbox-Auth")
    except (OSError, http.client.HTTPException) as error:
        print(f"no answer: {type(error).__name__}")
        return 1
    finally:
        connection.close()
    expected = response_auth(secret, method, path, nonce, status, body)
    matches = signature is not None and hmac.compare_digest(signature.lower(), expected)
    print(f"status {status} | signature: {'missing' if signature is None else 'present'}"
          f" | matches: {matches}")
    return 0 if matches and status == 200 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
