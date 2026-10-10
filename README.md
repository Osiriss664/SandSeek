# SandSeek

SandSeek answers a question by searching the web and reading pages with a
local model, and returns an answer with numbered sources. The model runs on
your Mac. Search and page fetching run inside a disposable Linux VM made by
Apple's [`container`](https://github.com/apple/container) tool. The model has
exactly two tools, `web_search` and `open_page`: no shell, no file access, no
network tool.

Status: pre-release, being moved out of a TUFF fork. The command-line tool and
the core library build as a standalone Swift package. The app in `App/` is
parked until it is rebuilt without TUFF modules. The guides in `docs/` still
show some old TUFF names while they are rewritten.

## Requirements

- Apple silicon, macOS 26 (needed by Apple `container`)
- [Apple `container`](https://github.com/apple/container)
- A local model server on 127.0.0.1: TUFF 8.3.1 or newer. llama.cpp
  (`llama-server`) support is planned, not tested yet. Streaming is not
  implemented yet.
- A Swift 6.2 toolchain to build

## Build

    swift build -c release

## Start the sandbox

    Scripts/research_sandbox.sh build      # once
    Scripts/research_sandbox.sh start      # listens on 127.0.0.1:9100
    Scripts/research_sandbox.sh selftest   # optional: check the VM's isolation

## Run

    .build/release/sandseek --server http://127.0.0.1:8080 "your question"

`sandseek --help` lists all options. Tests: `swift test`, and for the sandbox
server `python3 -m unittest Sandbox/test_server.py`.

## Security in short

- The VM has a read-only root filesystem, no Mac folders, a firewall that
  refuses the Mac, the local network and cloud metadata addresses, and a
  server running as an unprivileged user with no Linux capabilities.
- Fetches are limited to public addresses on ports 80 and 443; every DNS
  answer and redirect is checked again.
- Page text reaches the model wrapped in markers it is told to treat as
  information only; terminal escape codes and invisible Unicode are removed.
- Both services stay on loopback; the sandbox refuses foreign `Host` headers.
- Prompt-injection test pages are in `Sandbox/fixtures/injection`
  (`Scripts/research_injection_check.py`). A pass is evidence, not proof.
- A model can still be misled by false content on a page, and search queries
  go to the search engine like any web search. Check the sources.

## Licence

Apache License 2.0, see `LICENSE`. SandSeek began in a fork of TUFF; see
`NOTICE` and `Sandbox/fixtures/injection/THIRD_PARTY_NOTICES.md`.
