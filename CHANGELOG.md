# Changelog

## Unreleased

### Added

- `sandseek --check-host-header` checks whether the model server refuses a
  request that names another host (the `Host` header), which is what stops a
  web page from using DNS rebinding to reach it. It sends three read-only GET
  requests to one path (`/v1/models`, or `/api/tags` for Ollama), never a
  prompt, and tells whether the server refuses the other host, asks for a key,
  or answers any host. It also notes an open `Access-Control-Allow-Origin`.
  Exit code 0: refused or a key is required; 3: any host is answered and no key
  is needed; 4: nothing answers on the port; 5: cannot tell; 2: bad arguments.
  It takes `--server`, `--server-type`, `--api-key-file` and `--quiet`.
- **Check** on the model server card now also shows this result below the
  network exposure notice. llama.cpp gets SandSeek's own key in these requests;
  the other servers get none.

### Security

- The model server's `Host` handling was not checked before. A server that
  answers any `Host` and needs no key can be reached by a web page through DNS
  rebinding while it runs; the new check and the card say so.
- The sandbox no longer trusts the emSign ECC Root CA - G3 certificate:
  intermediates under it had their private keys compromised
  (GHSA-6q48-6c7w-9gw2). The image removes it from the system CA store that
  the sandbox's page fetches use, and the build stops if it is still there.
- Sandbox packages updated: certifi 2026.7.22 to 2026.10.19 (same advisory;
  certifi is not used for SandSeek's own fetches) and pypdf 6.20.1 to 6.21.1
  (GHSA-5hx5-vpf9-5wcv; the sandbox has no Pillow, so it was not affected).
  The sandbox image is rebuilt on the next Start.
- Search results: only links on duckduckgo.com itself are unwrapped as
  DuckDuckGo redirects; a look-alike host such as `evilduckduckgo.com` is
  treated as an ordinary result (found by CodeQL).

## 0.4.1 (16 October 2026)

New: the app starts and stops Ollama, lists the models already on this Mac, and has a Tips page and a Light/Dark choice.
The sandbox image changes (three small package updates), so the first Start
after updating rebuilds it, which takes a few minutes.

- New **Models on this Mac** menu on the model server card, for llama.cpp and
  TUFF. It lists the models already on disk (`.gguf` files from llama.cpp, LM
  Studio and Hugging Face folders; installed TUFF models in TUFF's models
  folder and the clone's `scratch`), and picking one does what **Choose
  model…** or **Choose models folder…** does. **Look again** searches again.
  The search is read-only, bounded and runs in the background; SandSeek never
  downloads a model. Ollama is unchanged.
- The model server card can now start and stop Ollama (experimental, like the rest of the Ollama support): **Choose program…**,
  **Start server** and **Stop server**, like TUFF and llama.cpp. SandSeek runs
  `ollama serve` with `OLLAMA_HOST=127.0.0.1:<port>` and `OLLAMA_NO_CLOUD=1`
  and no other variable from its own environment. It stops only an Ollama it
  started (also on **Stop everything**, on quit, and after a crash, as for the
  other servers). If something already listens on the port, for example the
  Ollama menu-bar app, Start refuses. The copy inside `Ollama.app` updates
  itself; the card says so, and the Homebrew version does not.
- Start and Stop for Ollama, after a security review: when the Ollama
  menu-bar app ends the Ollama SandSeek started and starts its own, the card
  says that the Ollama answering now is not SandSeek's and runs its full Check
  (with the network check) on it once. Start waits one more poll after the
  first answer, so a server that took the port meanwhile is not taken for
  SandSeek's. A stop that needs SIGKILL also ends that Ollama's model runners.
  For Ollama, Start needs the address `http://127.0.0.1:<port>`, not
  `localhost`. SECURITY.md says what Ollama's `Host` check does and does not
  stop.
- New Tips page in the sidebar: short hints for using the app (Quick answer
  or Thorough, which model server, one model server at a time on a 16 GB Mac,
  the Figure check list) and what our own tests on a Mac found.
- Settings has an Appearance choice: System (the default, follows the Mac),
  Light or Dark. It applies to all SandSeek windows; printed and PDF reports
  stay black on white.
- Sandbox packages updated: pypdf 6.20.0 to 6.20.1, trafilatura 2.3.0 to
  2.3.1, pytz 2026.4 to 2026.5 (still pinned by hash in
  `Sandbox/requirements.txt`). pypdf 6.20.1 includes a security fix for
  cyclic outline trees in code SandSeek does not use (it only reads text);
  the other two are bug fixes.

### Security

- The pypdf update (6.20.0 to 6.20.1) includes a security fix for cyclic
  outline trees, in code SandSeek does not use (it only reads text). The
  Ollama Start and Stop changes had a security review; what it changed is
  listed above.
- No security advisories were published for this release.

## 0.3.0 (16 October 2026)

New: Ollama as a third model server, next to TUFF and llama.cpp. The sandbox
image did not change; no rebuild is needed.

- Experimental Ollama support (`--server-type ollama`, or the Ollama choice on
  the model server card), through Ollama's native `/api/chat` with streaming.
  Tested once on a Mac with Ollama 0.40.4 and Gemma 4 12B (MLX build) from the
  command line; the app's Ollama card was not tried by hand. You start Ollama
  yourself; SandSeek never starts or stops it. The model must support tool calls and run on this Mac: Ollama cloud
  models are refused. The context is 32,768 tokens (or the model's maximum if
  smaller; `--context-tokens N` changes it, up to the model's maximum). With
  Ollama, `think` is sent only to models that can think, and then always as
  true or false. `--server-type ollama` defaults to port 11434. The exposure
  check advises `OLLAMA_HOST=127.0.0.1:11434`.
- The command's progress line for an Ollama model that can think ends with
  `thinking on` or `thinking off`.
- `--server-type auto` (the default) also recognises Ollama, by its
  `/api/version`. `Scripts/research_injection_check.py` accepts
  `--server-type ollama`.
- `Scripts/full_test.sh` takes `--server-type tuff|llamacpp|ollama|auto`.
- `web_search` accepts a list of queries and searches the first non-empty one;
  with more than one, it tells the model that only the first was used. Gemma 4 through Ollama sent the query as a list in 3 of 7 test
  runs and then got only errors until the step budget ran out.

### Security

No security advisories were published for this release.

## 0.2.0 (15 October 2026)

The sandbox image must be rebuilt: the app does it by itself on the first Start;
from the command line, run `Scripts/research_sandbox.sh build`.

Only SandSeek may use the sandbox.

- Every request to the sandbox is signed (HMAC with a secret only your Mac
  user can read) and carries a fresh number and the time. A request that is
  not signed correctly, is more than a minute old, or repeats an earlier one
  is refused. Every answer is signed too, whatever its status, and SandSeek
  uses it only if the signature fits the request it sent.
- The sandbox does not start without a secret.
- The secret is a read-only file in a folder that is mounted into the sandbox,
  no longer an environment variable. It lives in
  `~/Library/Application Support/SandSeek/sandbox` and is deleted when the
  sandbox is stopped, so no secret means the sandbox is not running. The file
  the first version left in TUFF's folder is removed on the next start.
- SandSeek checks the sandbox's identity again, with a signed health check,
  before a search or a page read that follows a pause of more than 5 seconds.
- `/health` now says `api` 1, and SandSeek refuses a sandbox that does not.
  Rebuild the sandbox image (`Scripts/research_sandbox.sh build`) after
  updating; a sandbox from the first version is not accepted.
- `POST /v1/raw` is removed. SandSeek never used it.
- `Scripts/verify_sandbox_signature.py` and `Scripts/research_address_check.py`
  sign their requests; the address check reads the secret file (`--secret-file`
  to name another).

One SandSeek at a time.

- The app, the `sandseek` command's scripts and a second copy of the app no
  longer stop each other's sandbox by accident. `Scripts/research_sandbox.sh
  start` takes a lock (a `lock` file in the sandbox folder, an operating system
  lock held by a small perl process for as long as the sandbox runs) and a
  second start says "Another SandSeek is using the web sandbox. Close it first,
  or press Stop in it." and touches nothing. The app remembers which lock holder
  its own start made (in its marker file) and Stop, Stop everything, the restart
  before a question and quitting act only while that same process holds the
  lock; if another SandSeek holds it, the app leaves that sandbox running. The
  command `research_sandbox.sh stop` is an explicit order and still stops
  whichever sandbox runs (not one whose start began under 5 seconds ago).
  The system drops the lock when its holder ends; a lock whose process is gone
  is taken over. If the app crashes or a start is cut off by the time limit, the
  holder and its VM keep running until Stop or the next start of the same app,
  which takes over from exactly that holder.
- The sandbox is published on a free port of 127.0.0.1 picked at each start, no
  longer fixed 9100. The port is recorded beside the secret (`port`, mode 0600),
  and the app, `sandseek` (without `--sandbox`), `research_sandbox.sh status` and
  `selftest`, `full_test.sh` and the two check scripts read it from there.
  `SANDSEEK_SANDBOX_PORT` still fixes the port, for tests. Inside the VM the
  server and firewall keep port 9100.
- Each VM is called `sandseek-sandbox-<random>` (recorded in `vm-name`). A start
  removes the VMs and the secret, port, name and address files that an earlier
  run left, once it holds the lock; `stop` removes exactly the VM it started.
  The app's Stop looks only for its own VM.
- The app still starts a fresh VM for each question, and now replaces its own
  running VM in one `start`, told the pid of its lock holder
  (`SANDSEEK_SANDBOX_REPLACE=<pid>`); any other holder is refused.
- `SANDSEEK_SANDBOX_PORT` must be 1024 to 65535 everywhere (`start` refuses
  anything else). The port file is read the same way by the app, the scripts
  and the check scripts: mode 0600, digits, at most one final line break.
- `Scripts/verify_sandbox_signature.py` and the scripts that import it run on
  macOS's Python 3.9 again.

A sturdier sandbox server.

- A whole request must arrive within 10 seconds (a body that stops short gets a
  signed 408), at most 32 connections are served at a time, and the request
  line and headers are limited (16 KiB, 50 headers, one `Content-Length`, no
  `Transfer-Encoding`, a short plain target), so a slow or greedy caller cannot
  tie the server up.
- Starting no longer waits for a slow name lookup.
- Log lines have only the method, path, status, size and time: no addresses,
  queries, headers or page text.
- A compressed page that would unpack past the size limit is refused with an
  `oversized` error instead of being cut.
- The server process turns off core dumps and memory reads of itself.
- The image installs `nftables` from a fixed Debian snapshot date, so a rebuild
  gives the same version. Rebuild the sandbox image after updating.

SandSeek runs only Apple's `container`.

- The app and `Scripts/research_sandbox.sh` run `/usr/local/bin/container`, where
  Apple's installer puts it, and never a `container` found through PATH. They
  first check that the file and every folder above it belong to root alone,
  that it is signed by Apple (not just by anyone), and that it is version 1.5.0
  or newer. If not, nothing is started and the sandbox card says why in plain
  words. **Apple container 1.5.0 or newer is now required.**
- The app checks the `container` tool again before a command if the file at its
  path is no longer the one it verified (file number, size and change time):
  the Apple signature and the version are then checked anew.
- `container`, `codesign` and the sandbox script run with a clean, fixed
  environment instead of a filtered copy of yours: only `HOME`, `USER`,
  `LOGNAME`, `TMPDIR`, a fixed `PATH` and language, and the settings the script
  reads (`SANDSEEK_DNS`, `SEARXNG_URL`, the port). Other variables, such as
  proxy settings, are no longer passed on.
- A `container` command that hangs is ended (`SIGTERM`, then `SIGKILL` three
  seconds later), and only the last 1 MiB of a command's output is kept.
- Calls to the sandbox have time limits of their own: 10 seconds for the health
  check, 100 for a search and 140 for a page, instead of the transport's half hour.

Fewer ways out of the sandbox.

- The Mac's own addresses are refused, public ones too. The firewall's ranges
  did not cover a public IPv4 or global IPv6 address of the Mac itself. At each
  start `Scripts/research_sandbox.sh` reads the addresses of the Mac's network
  interfaces (`ifconfig`), checks each strictly, and writes them to a file in
  the secret folder that is mounted read-only into the VM (not an environment
  variable). The VM's firewall rejects them, and the server refuses them in
  every URL, name lookup and redirect. A list that is missing or unreadable
  stops the start. Rebuild the sandbox image after updating.
- The address a page ends up at after redirects gets the same checks on the Mac
  as the one that was asked for (http or https, no user name or password, no
  local or private network host) before it becomes a source or can be opened
  from the report. A page that fails is no source, with a plain message.
- A redirect from https to http is refused, for pages and for search alike, and
  so is an answer with more than one `Location` header.
- The security check (`Scripts/research_sandbox.sh selftest` and the app's
  **Security check**) tries the Mac's addresses, including a public test
  address that only the new list can explain, and `/health` now reports how
  many addresses the server refuses (`blocked_addresses`). The app's own check
  before every question reads the inbound firewall rules too (drop by default,
  port 9100 from the gateway only), not just the outbound ones, and the
  Mac's blocked sets.
- Page titles and addresses are cleaned of bidirectional-text and other
  invisible characters when they arrive from the sandbox and again in saved
  reports; a title is cut to one line of 300 characters.

A better window.

- The app has its own icon: the SandSeek logo, a magnifying glass over sand
  dunes.
- The Model server card and the Web sandbox card fold with the arrow beside
  the title (or a click on the title row); the choice is remembered. When both
  are ready they fold once, and a card opens again when it stops being ready.
- **Start everything** starts the model server (only when you chose a program
  for it, otherwise it just checks it), then the sandbox, then runs the
  security check, and stops at the first thing that fails, with a short note
  saying where to look. It waits for a start or check that is already under
  way, never starts a second server or sandbox, and does not start a server
  you just stopped.
- **Stop everything** stops the question, the sandbox this app started (a
  sandbox another SandSeek or `research_sandbox.sh start` holds is left
  running), and the model server if SandSeek started it. A server you started
  yourself keeps running. The server and the sandbox are stopped together, and
  the start and stop buttons wait while it works. SandSeek writes when it
  starts and stops things to the system log (subsystem
  `io.github.osiriss664.sandseek`), without secrets, to help find out why
  something ended.
- Less text on the cards: the longer explanations and notes are behind an (i)
  button on each card. The one security warning about TUFF (it does not check
  which web page a request comes from) stays on the card as a short line while
  a TUFF server is in use. Long paths are shortened in the middle, with the
  full path as a tooltip.
- The question box is on top of the Research screen, the cards below it.
- A saved report opened while a question runs opens in its own window. Before,
  Open was off until the question finished.
- Sources are small cards (number, page title, site, Open). New **Copy answer**
  button copies the answer as plain text.
- A report can be printed (⌘P) or exported as a PDF (**Export as PDF…**) from
  the Research screen and from a report window: question, date, model, answer
  and the numbered sources with their full addresses as plain text, with the
  same warnings the screen shows. The PDF lists source addresses as plain text;
  some PDF viewers may still make them clickable.
- The sandbox card shows **Signed** with a checkmark and the time of its last
  signed health check ("checked 14:05", in the Mac's 12 or 24 hour style),
  only while the sandbox is verified. It says so in plain words when that
  check fails. A failed security check opens the card and shows "Check
  failed" instead of "Ready".
- The answer view, the report window and the saved report now list the figure
  check (each figure, date or name the cited page does not back up; the orange
  line counted them) and the pages that could not be read, with the reason,
  under **Figure check (N)** and **Pages that could not be read (N)**. On
  screen each list is folded until you click it, and nothing shows when there
  is nothing to list.

### Tests

- `Scripts/full_test.sh` runs every check that needs no clicks (build, tests,
  packaging, sandbox, self-test, one question). Options: `--quick`,
  `--no-sandbox`, `--thorough`, `--model`, `--take-over-sandbox`, `--safety`
  and `--start-server`.
- `Scripts/safety_probe.sh` and `Scripts/safety_lifecycle.sh` are the safety
  test, described in `docs/SAFETY_TEST.md`.
- Python tests for the scripts in `Scripts/`:
  `python3 -m unittest discover -s Scripts -p 'test_*.py'`.

### Security

- The hardening is described above: signed requests and answers, a secret
  kept in a read-only file, and `POST /v1/raw` removed.
- No security advisories were published for this release.

## 0.1.0 (11 October 2026)

First release. SandSeek lets a local model research the web from a sandbox
on your Mac.

- `sandseek` command and SandSeek app (macOS) share one Swift package and
  one research loop.
- Works with TUFF 8.3.1 or newer. llama.cpp support is experimental (see below).
- Web search and page reading run in a throwaway Apple `container` VM:
  no shell, no files or host folders, read-only, non-root, with a firewall
  that only lets the Mac reach port 9100 from the VM's gateway.
- Answers from the sandbox are signed (HMAC over a fresh nonce), and the
  client refuses redirects from the model server and the sandbox.
- Addresses: private and non-canonical numeric hosts are refused.
- Web text is cleaned of invisible characters and fenced as untrusted.
- Text PDFs are read inside the VM (up to 5 MB and 50 pages, no OCR) in a
  memory- and time-limited child process.
- The app checks that the model server is not reachable from the network and
  runs a sandbox security check on request.
- The model server card can start and stop `TUFFServer` or `llama-server`
  (Start server / Stop server): no shell, 127.0.0.1 only, llama.cpp only with
  its key file. Stop server, or quitting normally, stops only a server the app
  started. In the Mac test a Force Quit from the Dock ended the server together
  with the app; after a crash or `kill -9` it can keep running, and the next
  launch finds it and offers Stop. The program check
  reads Unix owner and permission bits only (no ACLs, no external-volume check),
  and a second SandSeek would take over the first one's server. TUFF has no
  Host-header check, so quit the server when you do not use it. The flag names
  were taken from TUFF 8.3.11.
- Reports are saved as JSON and Markdown and can be reopened in the app.

Tested on an Apple silicon Mac with 16 GB, macOS 27.0.1, Apple `container`
1.5.0, TUFF 8.3.1 and Qwen3.6 35B-A3B. Start server / Stop server was tested
by hand with TUFF 8.3.11 and llama.cpp; stopping a server while its model is
still loading was not tested.

Known limits:

- llama.cpp: no streaming, the Thinking switch has no effect, no research run
  measured, prompt-injection test with Bonsai not done.
- No OCR: scanned PDFs and text in images are not read.
- The app is signed ad hoc, not notarized: a copy downloaded from GitHub needs
  "Open Anyway" in System Settings, Privacy & Security, on first launch.
- A model can still follow instructions hidden in web pages or PDFs; it can
  then only search and read pages.

### Security

No security advisories were published for this release.
