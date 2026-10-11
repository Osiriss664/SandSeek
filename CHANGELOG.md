# Changelog

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
