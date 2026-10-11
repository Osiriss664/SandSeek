#!/usr/bin/env python3
"""Checks the signature of one sandbox answer, for the Mac test steps.

  verify_sandbox_signature.py SECRET_FILE NONCE REQUEST_BODY_FILE HEADERS_FILE BODY_FILE

REQUEST_BODY_FILE is the file that was sent as the request body, or - for a GET.
HEADERS_FILE is `curl -D` output (the status line and the headers) and BODY_FILE
the answer's body. The secret is read from SECRET_FILE and never printed or
taken from an argument, so it does not appear in `ps`. The formula is the one in
Sandbox/server.py. Prints one line; exits 0 when the signature is present and
right, 1 otherwise.
"""

import hashlib
import hmac
import sys


def main(argv):
    if len(argv) != 6:
        sys.exit(__doc__)
    secret_path, nonce, request_path, header_path, body_path = argv[1:]
    with open(secret_path, "rb") as handle:
        secret = handle.read().removesuffix(b"\n")
    request = b""
    if request_path != "-":
        with open(request_path, "rb") as handle:
            request = handle.read()
    with open(header_path, encoding="latin-1") as handle:
        lines = handle.read().splitlines()
    with open(body_path, "rb") as handle:
        body = handle.read()
    status = int(lines[0].split()[1])
    signature = next((line.split(":", 1)[1].strip() for line in lines
                      if line.lower().startswith("x-sandbox-signature:")), None)
    message = (b"tuff-sandbox-v1\n" + nonce.encode() + b"\n"
               + hashlib.sha256(request).hexdigest().encode() + b"\n"
               + str(status).encode() + b"\n" + body)
    expected = hmac.new(secret, message, hashlib.sha256).hexdigest()
    matches = signature is not None and hmac.compare_digest(signature.lower(), expected)
    print(f"status {status} | signature: {'missing' if signature is None else 'present'}"
          f" | matches: {matches}")
    return 0 if matches else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
