# SandSeek

SandSeek answers a question by searching the web and reading pages with a
local model, and returns an answer with numbered sources. The model runs on
your Mac. Search and page fetching run inside a disposable Linux VM made by
Apple's [`container`](https://github.com/apple/container) tool. The model has
exactly two tools, `web_search` and `open_page`: no shell, no file access, no
network tool.

Status: pre-release, being moved out of a TUFF fork. The command-line tool,
the core library and the Mac app (a window with the same research loop) are one
Swift package. The app has not been compiled yet by the person who wrote it
(see "Left undone" below). The guides in `docs/` still show some old TUFF
names while they are rewritten.

## Requirements

- Apple silicon, macOS 26 (needed by Apple `container`)
- [Apple `container`](https://github.com/apple/container)
- A local model server on 127.0.0.1: TUFF 8.3.1 or newer. Streaming is on by
  default for TUFF, so that Stop and the time limits make it stop generating.
  llama.cpp (`llama-server`) works through `--server-type llamacpp` (plain
  requests, not tested against a real server yet). The app connects to a
  server that already runs; it never starts one.
- A Swift 6.2 toolchain to build

## Build

    swift build -c release

## The app

    Scripts/package_app.sh            # builds build/SandSeek.app
    open build/SandSeek.app

The script builds `SandSeekApp` in release mode, assembles `SandSeek.app`
(bundle id `io.github.osiriss664.sandseek`, version 0.1.0, macOS 26 or newer),
copies the sandbox files into `Contents/Resources/sandbox` and signs the bundle
ad hoc. There is no Sparkle update and no notarization yet. `swift run
SandSeekApp` also opens the window, but a bare executable has no sandbox
files inside it (see below).

The window has a sidebar (Research, Reports, Settings, the last few reports),
a card for the model server, a card for the sandbox with a Security check, a
question field with a model picker and a Quick answer / Thorough switch, and
progress and answer side by side. Stop is visible while a question runs.

- **Model server.** Pick TUFF (127.0.0.1:8080) or llama.cpp (127.0.0.1:8081);
  Ollama and LM Studio are listed as "later". The address can be edited but
  must be on this Mac's loopback interface. The card checks the server every
  few seconds (and with the Check button) and lists its models from
  `/v1/models`. For llama.cpp it offers a start command with a key SandSeek
  made once and stores in `~/Library/Application Support/SandSeek/State`; the
  key is sent as a Bearer token. Whether llama-server enforces `--api-key` is
  checked on the Mac in step 2b. On a Mac with 16 GB, run only one model
  server with a loaded model at a time.
- **Sandbox files.** The app carries `Scripts/research_sandbox.sh` and
  `Sandbox/` in `Contents/Resources/sandbox`. On first use, and whenever they
  differ from the copy (compared by a hash of every file), they are copied to
  `~/Library/Application Support/SandSeek/Sandbox`, and the script runs from
  that copy. For development, `SANDSEEK_SOURCE_DIR=/path/to/checkout` uses
  that checkout's files in place. The files are put into the bundle by the
  script and not declared as SwiftPM resources, because the sandbox script
  needs them as a plain folder laid out like a checkout (it builds the image
  from `../Sandbox`), and the app hashes and copies exactly that folder.
- **Reports.** Saved in `~/Library/Application Support/SandSeek/Reports`
  (JSON and Markdown; the format is unchanged, a report only gains the
  optional `serverKind`). Once per report id, the app copies the reports TUFF's
  research screen saved in `~/Library/Application Support/TUFF/Research
  Reports`. The originals are only read, never moved or deleted, and a report
  you delete in SandSeek does not come back.
- **Presets.** Quick answer: 8 steps, at least 3 pages, 5 results per search.
  Thorough: 30 steps, at least 10 pages, 8 results per search, thinking on.
  Both: 4 tool calls per step, 3,000 characters of page text, 2,048 tokens per
  step (8,192 with thinking), step limit 30 minutes, thinking limit 3 minutes,
  auto-open, nudges and rewrite on. Settings edits them within the ranges the
  command accepts. The Thorough values are not tested yet; they are measured
  in step 2c.
- **Safety rules** (shown in Settings, not editable): two tools only, a
  firewall in the VM, no root in the sandbox, a check before every question,
  and links open only after you confirm the full address.

## Start the sandbox

The app does this itself. By hand:

    Scripts/research_sandbox.sh build      # once
    Scripts/research_sandbox.sh start      # listens on 127.0.0.1:9100
    Scripts/research_sandbox.sh selftest   # optional: check the VM's isolation

## Run

    .build/release/sandseek --server http://127.0.0.1:8080 "your question"

`sandseek --help` lists all options. Tests: `swift test`, and for the sandbox
server `python3 -m unittest Sandbox/test_server.py`.

The command finds out which kind of model server it talks to before the sandbox
check: a model server that does not answer ends the run with exit code 1 (as
before), a server that is not recognised as TUFF with exit code 2 (use
`--server-type llamacpp` for llama-server; `research_question_set.py run` and
`research_injection_check.py` pass the option on).

To record real streams from a running server for test fixtures, use
`Scripts/record_stream.py` with the example requests in
`Tests/Fixtures/requests/` (loopback only).

## Left undone

- Nothing in the app was compiled or run where it was written (no Swift
  toolchain there). Expect a few compile fixes on the first `swift build` on
  the Mac, and run `swift test` for `SandSeekAppLogicTests`.
- llama.cpp: plain (non-streaming) requests, and the `--api-key` behaviour of
  llama-server is checked in step 2b. Ollama and LM Studio come later.
- Thorough preset values are a first guess (step 2c measures them).
- Model names in the picker are the ids the server lists; there is no table of
  display names.
- The Quick answer / Thorough switch is labelled in English like the rest of
  the window.
- No app icon, no Sparkle updates, no notarization.

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
