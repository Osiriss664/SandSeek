# Changelog

## 0.2.0 (unreleased)

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

A better window.

- The Model server card and the Web sandbox card fold with the arrow beside
  the title (or a click on the title row); the choice is remembered. When both
  are ready they fold once, and a card opens again when it stops being ready.
- **Start everything** starts the model server (only when you chose a program
  for it, otherwise it just checks it), then the sandbox, then runs the
  security check, and stops at the first thing that fails, with a short note
  saying where to look. It waits for a start or check that is already under
  way, never starts a second server or sandbox, and does not start a server
  you just stopped.
- **Stop everything** stops the question, the sandbox, and the model server
  if SandSeek started it. A server you started yourself keeps running.
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

## 0.1.0 (unreleased)

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
