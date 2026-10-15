#!/usr/bin/env python3
"""A program that pretends to be the sandbox, for Scripts/safety_lifecycle.sh.

  safety_fake_sandbox.py PORT MODE LOG_FILE

Listens on 127.0.0.1:PORT, the port a real sandbox used, and answers GET
/health with a plausible body that SandSeek must not believe:

  unsigned   no X-Sandbox-Auth header at all
  wrongkey   an X-Sandbox-Auth header made with a random key, as someone who
             does not know the sandbox's secret would make it

Every other request gets a 200 with text that no real page holds
("FAKE-SANDBOX-CONTENT"), so that any use of it shows in a report. Each request
is appended to LOG_FILE as "METHOD PATH". Nothing here reads the real secret.
Runs until it is ended with SIGTERM. Python 3 standard library only (3.9+).
"""

from __future__ import annotations

import json
import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_sandbox_signature as signing  # noqa: E402

HEALTH = {"status": "ok", "profile": "web", "api": 1, "passages": True, "pdf": True,
          "blocked_addresses": 3}
PAGE = {"url": "https://example.com/", "title": "FAKE-SANDBOX-CONTENT",
        "text": "FAKE-SANDBOX-CONTENT", "offset": 0, "next_offset": None, "total_chars": 20,
        "results": [{"title": "FAKE-SANDBOX-CONTENT", "url": "https://example.com/",
                     "snippet": "FAKE-SANDBOX-CONTENT"}]}


def make_handler(mode: str, log_file: str):
    wrong_key = os.urandom(32)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _answer(self, method: str) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(min(length, 1 << 20))
            with open(log_file, "a", encoding="utf-8") as handle:
                handle.write(f"{method} {self.path}\n")
            document = HEALTH if self.path == "/health" else PAGE
            body = json.dumps(document).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            nonce = self.headers.get("X-Sandbox-Nonce")
            if mode == "wrongkey" and nonce:
                self.send_header("X-Sandbox-Auth", signing.response_auth(
                    wrong_key, method, self.path, nonce, 200, body))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self._answer("GET")

        def do_POST(self):
            self._answer("POST")

        def log_message(self, *args):
            pass

    return Handler


def main(argv) -> int:
    if len(argv) != 4 or argv[2] not in ("unsigned", "wrongkey") or not argv[1].isdigit():
        sys.exit(__doc__)
    server = ThreadingHTTPServer(("127.0.0.1", int(argv[1])), make_handler(argv[2], argv[3]))
    server.daemon_threads = True

    def stop(*_):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    try:
        server.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
