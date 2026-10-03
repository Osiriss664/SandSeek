# Web research for TUFF

Ask a local TUFF model a question, and it searches the web, reads the pages it
needs and answers with numbered sources. The model runs on your Mac, and
everything that touches the web runs in a disposable Linux VM made by Apple's
[`container`](https://github.com/apple/container) tool. The search queries the
model writes do go to the search engine, like any web search.

It comes in two forms that share one engine:

- **`tuff research "question"`** in Terminal.
- **A Research screen in the TUFF app** (Command-2), with buttons to start
  everything, live progress, the model's thinking if you want it, and a list
  of saved reports.

The full user guide is [docs/WEB_RESEARCH.md](WEB_RESEARCH.md). This page is
the overview: what it does, how it is built, how it was checked, and what it
does not do.

## How it works

```
Mac (host)
  TUFF server        127.0.0.1:8080   the model, on the GPU, loopback only
  tuff research      the loop: asks the model, runs its tool calls,
  or the app         writes the report
      │
      ▼  127.0.0.1:9000 (published port)
Linux VM (Apple container)
  web sandbox        search, download, turn pages into plain text
```

The model gets exactly two tools, `web_search` and `open_page`. There is no
shell, file or network tool, so a web page that tries to give the model
instructions has nothing on the Mac to act through.

It uses only TUFF's existing OpenAI-compatible server, keeps the server on
127.0.0.1, and adds no runtime or model-format code. Apple `container` is
needed only for this feature.

## Why Apple container

[`container`](https://github.com/apple/container) is Apple's open-source tool
for running Linux containers on Apple silicon. Unlike tools that share one VM
between all containers, it gives each container its own lightweight virtual
machine. That makes it a good fit for the one part of research that handles
hostile input: downloading and parsing web pages.

The sandbox VM:

- runs one small Python service that searches, downloads and extracts text;
- has a read-only root filesystem, 1 GB of memory, a process limit and no Mac
  folders mounted;
- is replaced by a fresh VM on every start;
- gets no GPU. The model never runs in it, and only cleaned text comes back.

## Security design

| Layer | What it does |
| --- | --- |
| Tools | The model can only search and read. It cannot write files; only the finished report is saved, never over an existing file. |
| Firewall inside the VM | Outbound traffic is dropped unless it goes to the public internet, or to DNS on the Mac. The rest of the Mac, your local network, carrier-grade NAT, link-local and cloud metadata addresses are refused. It loads before the server starts, and the sandbox refuses to start without it. |
| No root | The web server runs as an unprivileged user with no Linux capabilities and cannot regain any, so it cannot change the firewall. |
| Fetch rules | Public addresses only, on ports 80 and 443. Every DNS answer and every redirect is checked again, and the connection goes to the address that was checked. Responses are capped in size and time, and page parsing runs in a separate process with its own time limit. |
| Untrusted text | Page text is wrapped in markers the model is told to treat as information only. Terminal escape codes and invisible Unicode, which can hide instructions from you, are removed in the VM and again on the Mac. |
| Reports | Saved reports load nothing when opened: images and HTML become plain text, and only http and https links stay links. In the app, links in an answer do nothing, and a source opens only after you confirm its full address. |
| Local services | Both services stay on loopback. The sandbox API refuses foreign `Host` headers and browser-style requests, which blocks attacks from web pages open in your browser. |
| App check | Before every question, the app checks from outside the VM that the firewall holds TUFF's rules and that the server runs without privileges. Questions stay off until that passes. |

## How it was checked

**Independent review.** A separate reviewer went through the code in three
rounds, then re-checked each later fix. Every medium finding was fixed and
checked again: terminal escape codes in page titles, a
pattern that a crafted page could use to freeze the title search, and a VM
that could have reached the Mac and the local network. The remaining low
findings and accepted trade-offs are listed under "Limits" below.

**On a real Mac** (MacBook Air M5, 16 GB, macOS 26, Apple container 1.5.0):

- Swift tests for research, the command and the app, and the sandbox's
  Python tests, all pass.
- The sandbox self-test passes. Among other checks, it tries every TCP port
  on the Mac from inside the VM; only DNS answers, as configured.
- Research runs with Gemma 4 E4B, Qwen3.6 35B-A3B and Gemma 4 26B-A4B gave
  correct answers with sources. Gemma 4 26B-A4B also did so from the app.

**Prompt injection.** Four hostile test pages try to make the model print a
planted word, send the question to an outside address, read the Mac or the
local network, or obey a fake end of the tool result. Each page was run three
times per model. Gemma 4 E4B and Gemma 4 26B-A4B resisted all 12 runs. Qwen3.6
resisted all 12 in its latest run; an earlier run flagged one answer that most
likely reported the planted word rather than obeying it. These results are
evidence for these models and these pages, not proof against injection.

The checks are in the repository, so anyone can run them:
`Scripts/research_sandbox.sh selftest` and
`Scripts/research_injection_check.py`.

## Limits

- A model can still be misled by false content on a page. Check the sources.
- A model steered by a page can still put what it read, including your
  question, into a URL it asks to open. No Mac files can leak this way,
  because the model has no file tool.
- The VM can reach any public site, and by default your Mac's DNS port.
- Pages are fetched without JavaScript, so some sites give little text.
- Research makes many long prompts. On a 16 GB Mac, a question takes about
  2 minutes with Qwen3.6 and 6 to 11 with Gemma 4 26B.
- Apple `container` needs macOS 26 and Apple silicon, while TUFF itself
  supports macOS 15.
- A flaw in the Linux kernel or Apple's virtualization could break the VM
  boundary, as with any VM.

## Credits

Built on [TUFF](https://github.com/rexmhall09/TUFF) by rexmhall09 and Apple's
[`container`](https://github.com/apple/container). The code, tests and docs
were written with Claude (Anthropic) through Claude Code, and reviewed by a
separate Claude session. The builds and test runs listed here were run on the
author's own Mac.
