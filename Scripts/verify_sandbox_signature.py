#!/usr/bin/env python3
"""Sends one signed request to the sandbox and checks the signature of the
answer, for the Mac test steps.

  verify_sandbox_signature.py SECRET_FILE [PORT]

Sends GET /health to 127.0.0.1:PORT, signed with the secret in SECRET_FILE, and checks that the answer is signed with the same secret for that
request. Without PORT, the port is SANDSEEK_SANDBOX_PORT if that is set, else
the one `research_sandbox.sh start` recorded in the file `port` beside the
secret. The secret is read from the file and never printed or taken from an
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


def recorded_port(secret_path: str) -> int | None:
    """The port `research_sandbox.sh start` wrote to the file `port` beside the
    secret, or None. Strict, like the app: a plain file of yours, mode 0600,
    digits only (and one line break), 1024 to 65535."""
    path = os.path.join(os.path.dirname(os.path.abspath(secret_path)), "port")
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
                             | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        return None
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_mode & 0o077):
            return None
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            text = handle.read(32).decode("ascii", "replace")
    except OSError:
        return None
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    text = text.removesuffix("\n")
    if not (text.isascii() and text.isdigit() and 4 <= len(text) <= 5):
        return None
    return int(text) if 1024 <= int(text) <= 65535 else None


def sandbox_port(secret_path: str) -> int | None:
    """SANDSEEK_SANDBOX_PORT when it is set, else the recorded port."""
    fixed = os.environ.get("SANDSEEK_SANDBOX_PORT", "")
    if fixed:
        return int(fixed) if fixed.isascii() and fixed.isdigit() and 0 < int(fixed) < 65536 else None
    return recorded_port(secret_path)


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
    port = int(argv[2]) if len(argv) == 3 else sandbox_port(argv[1])
    if port is None:
        print("error: no sandbox port: pass PORT, or start the sandbox "
              "(Scripts/research_sandbox.sh start records it)", file=sys.stderr)
        return 1
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
