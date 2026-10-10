#!/usr/bin/env python3
"""Records the raw server-sent events of one streamed chat completion.

For making real test fixtures on the Mac (Abschnitt 2a): a normal answer, a
tool call, and a context error, from a model server that is running on
loopback. It POSTs a JSON request file with "stream": true and writes the
bytes of the reply exactly as they arrive, comment lines (": ping") and the
blank lines between events included, to a file.

  Scripts/record_stream.py Tests/Fixtures/requests/answer.json answer.sse
  Scripts/record_stream.py Tests/Fixtures/requests/tool_call.json tool_call.sse
  Scripts/record_stream.py Tests/Fixtures/requests/context_error.json context_error.sse

Options:
  --url URL          chat endpoint (default http://127.0.0.1:8080/v1/chat/completions).
                     Only http on 127.0.0.1, localhost or ::1 is accepted.
  --bearer-env NAME  send the API key in this environment variable as a bearer
                     token (llama-server --api-key). The key is never printed.
  --no-usage         do not add stream_options.include_usage.
  --timeout SECONDS  give up when nothing arrives for this long (default 1800,
                     as long as SandSeek's step limit: a server reading in a
                     long prompt is silent for minutes).

The request file is the body of a chat completion request. This script sets
"stream": true and, unless --no-usage, "stream_options": {"include_usage": true}
(TUFF 8.3.1 accepts both). Top-level keys that start with an underscore are
notes for the reader and are removed before sending. One of them does
something: "_pad_last_user_message_chars": N makes the last user message at
least N characters long with filler text, to make a prompt that is longer
than the model's context window (the context error). TUFF refuses unknown
keys, which is why the script strips them.

The output file is new: an existing file is never overwritten. If the server
answers with a status other than 200, its body is written to the file as it
is, the status goes to standard error, and the exit code is 1. A refusal
before the stream is a plain JSON body; an error inside a stream arrives with
status 200 as `data: {"error": ...}`.

Needs only the Python standard library.
"""

import argparse
import http.client
import json
import os
import sys
import urllib.parse

LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}
DEFAULT_URL = "http://127.0.0.1:8080/v1/chat/completions"
FILLER = (
    "This sentence only makes the message long. It carries no question and "
    "no instruction. "
)


def loopback_endpoint(url):
    """Returns (host, port, path) for a loopback http URL, else exits."""
    try:
        parts = urllib.parse.urlsplit(url)
        host = (parts.hostname or "").lower()
        port = parts.port or 80
    except ValueError as error:
        sys.exit(f"error: cannot read the URL: {error}")
    if (
        parts.scheme.lower() != "http"
        or host not in LOOPBACK_HOSTS
        or parts.username is not None
        or parts.password is not None
        or parts.fragment
    ):
        sys.exit(
            "error: --url must be an http URL on 127.0.0.1, localhost or ::1 "
            "(this script only talks to a server on this Mac)"
        )
    path = parts.path or "/"
    if parts.query:
        path += "?" + parts.query
    return host, port, path


def build_body(path, include_usage):
    try:
        with open(path, encoding="utf-8") as handle:
            request = json.load(handle)
    except (OSError, ValueError) as error:
        sys.exit(f"error: cannot read the request file {path}: {error}")
    if not isinstance(request, dict):
        sys.exit(f"error: {path} must hold one JSON object")
    pad = request.get("_pad_last_user_message_chars")
    request = {key: value for key, value in request.items() if not key.startswith("_")}
    messages = request.get("messages")
    if pad is not None:
        if not isinstance(pad, int) or isinstance(pad, bool) or pad < 0:
            sys.exit("error: _pad_last_user_message_chars must be a whole number")
        users = [m for m in messages or [] if isinstance(m, dict) and m.get("role") == "user"]
        if not users or not isinstance(users[-1].get("content"), str):
            sys.exit("error: padding needs a user message with text content")
        text = users[-1]["content"]
        filler = (FILLER * (pad // len(FILLER) + 1))[: max(0, pad - len(text))]
        users[-1]["content"] = text + "\n\n" + filler if filler else text
    request["stream"] = True
    if include_usage:
        options = request.get("stream_options")
        options = dict(options) if isinstance(options, dict) else {}
        options["include_usage"] = True
        request["stream_options"] = options
    return json.dumps(request, ensure_ascii=False).encode("utf-8")


def main():
    parser = argparse.ArgumentParser(
        description="Record the raw SSE bytes of one streamed chat completion.")
    parser.add_argument("request", help="JSON file with the request body")
    parser.add_argument("output", help="new file for the raw stream")
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--bearer-env", metavar="NAME")
    parser.add_argument("--no-usage", action="store_true")
    parser.add_argument("--timeout", type=float, default=1800.0)
    args = parser.parse_args()

    host, port, path = loopback_endpoint(args.url)
    body = build_body(args.request, include_usage=not args.no_usage)
    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "Content-Length": str(len(body)),
    }
    if args.bearer_env:
        key = os.environ.get(args.bearer_env)
        if not key:
            sys.exit(f"error: environment variable {args.bearer_env} is not set")
        headers["Authorization"] = "Bearer " + key

    try:
        # "x" fails when the file exists: a recording is never overwritten.
        output = open(args.output, "xb")
    except OSError as error:
        sys.exit(f"error: cannot create {args.output}: {error}")

    # http.client never uses a proxy, so the request cannot leave this Mac.
    connection = http.client.HTTPConnection(host, port, timeout=args.timeout)
    status = None
    received = 0
    try:
        with output:
            connection.request("POST", path, body=body, headers=headers)
            response = connection.getresponse()
            status = response.status
            print(f"HTTP {status} {response.reason}", file=sys.stderr)
            while True:
                # read1 returns what has arrived, so the file fills as the
                # stream does and a long silence is not mistaken for the end.
                chunk = response.read1(65536)
                if not chunk:
                    break
                output.write(chunk)
                output.flush()
                received += len(chunk)
    except KeyboardInterrupt:
        print("interrupted; closing the connection", file=sys.stderr)
        return 130
    except (OSError, http.client.HTTPException) as error:
        print(f"error: {error} after {received} bytes", file=sys.stderr)
        return 1
    finally:
        connection.close()
    print(f"wrote {received} bytes to {args.output}", file=sys.stderr)
    return 0 if status == 200 else 1


if __name__ == "__main__":
    sys.exit(main())
