# How SandSeek works

SandSeek answers a question by searching the web and reading pages with a
model that runs on your Mac, and it writes an answer with numbered sources.
This page explains the method in plain words: who does what, how a question is
worked through, and what the program does to keep a small local model on track.
For what is protected and how it was tested, see [SECURITY.md](SECURITY.md); to
install it, see [INSTALL.md](INSTALL.md).

## The parts

```
Mac
  model server        127.0.0.1:8080 (TUFF) or :8081 (llama.cpp)
                      runs the model on the GPU; started by you
  SandSeek            the app, or the `sandseek` command: the loop that asks
                      the model, runs its tool calls and writes the report
      |
      v  127.0.0.1:9100
Linux VM (Apple container)
  web sandbox         searches, downloads pages, turns them into plain text
```

- **The model server** is a program you start yourself: TUFF (8.3.1 or newer) or
  llama.cpp's `llama-server`. SandSeek connects to it and never starts or stops
  it. SandSeek talks to it only on 127.0.0.1. Start it so that it listens on
  127.0.0.1 only (see [INSTALL.md](INSTALL.md)); SandSeek's **Check** warns if it
  is reachable from the network.
- **SandSeek** is the loop. It asks the model for the next step, does what the
  model asks, and puts the results back in front of the model.
- **The web sandbox** is a small web server in a disposable Linux VM made by
  Apple's [`container`](https://github.com/apple/container) tool. It is the
  only part with internet access. Only cleaned text comes back from it.

The search queries the model writes do go to the search engine, like any web
search.

## Why the web part is in a VM

[`container`](https://github.com/apple/container) is Apple's open-source tool
for running Linux containers on Apple silicon. Unlike tools that share one VM
between all containers, it gives each container its own lightweight virtual
machine, with its own kernel, memory and network address, and nothing of the
Mac's files unless a folder is mounted. The sandbox mounts none. That fits the
one job that handles hostile input: downloading and parsing web pages. The model
itself cannot run in the VM (it has no GPU), and does not need to.

The VM has a read-only root filesystem, 1 GB of memory, a process limit and a
firewall of its own, and it is replaced by a fresh one before each question
after the first. Each start also makes a new random secret, which the sandbox
uses to sign its answers, so SandSeek can tell the real sandbox from another
program on the same port (see `docs/SECURITY.md`).

## What happens when you ask a question

1. **Checks.** SandSeek makes sure the model server answers, asks it which
   models it has and how large its memory (context window) is, and checks from
   outside that the sandbox's firewall is loaded and its server runs without
   privileges. The app does not let you ask until that passes.
2. **The model plans.** It is given a short research method (below) and two
   tools. It decides what to search for.
3. **Search and read, in rounds.** In each round the model may ask for up to a
   few searches and page reads. The loop runs them in the sandbox and returns
   the cleaned results, fenced as untrusted text. A round is called a step.
4. **Answer.** When the model has what it needs, or the step limit is reached,
   it writes the answer with source numbers. The loop checks the answer (see
   [What the loop does besides asking](#what-the-loop-does-besides-asking)),
   adds the list of sources and the searches, and saves the report.

The model has exactly two tools:

| Tool | What it does |
| --- | --- |
| `web_search(query)` | Searches the web with DuckDuckGo's HTML results, or a SearXNG instance when `SEARXNG_URL` is set for the sandbox. |
| `open_page(url, offset)` | Reads a page or a PDF as extracted text, a slice at a time. With the passages option it returns the best matching passages first. |

There is no shell, no file tool and no other network tool. An address that is
not http or https, a private or local address, or an address that never showed
up in a search result, a source or the question, is refused by the loop and
never reaches the sandbox.

## The method the model is walked through

The system prompt asks the model to work like a careful researcher:

- plan the facts it needs before searching;
- run two to four different searches: short keywords, synonyms, the official
  source, the newest state, English as well as the question's language;
  quotation marks only for exact phrases;
- read at least three independent pages (the setting `--min-pages`), compare
  their dates and claims, and not trust a page just because it was found;
- check every item against each condition in the question (for example
  "non-violent") and leave out or mark as excluded the ones that break it;
- answer in the question's language with a short answer first, then the
  details with source numbers, and then what it could not verify.

The model is told today's date, and that pages dated up to today are real, so a
model whose training ended earlier does not call recent news "simulated". The
last tool result of each step ends with a line such as `Research so far: 2
searches, 1 page read, step 3 of 8.`, so the model keeps track after older
results are shortened. A search it already ran is answered from the loop
without going to the search engine again. The report lists every search.

## What the loop does besides asking

Local models are small and slip. The loop does not rely on the model to get
these right.

**Keeping to the context window.** Long pages are read in slices. The loop
keeps room for the reply and, when the conversation would outgrow the model's
memory, shortens old results itself, not the model, so page text never gets a
chance to steer the shortening. Reasoning from earlier steps is dropped
first. Then a page read twice keeps only its newest copy, old searches, errors
and drafts are shortened, and outdated "Research so far" lines are dropped.
Pages come last: older pages keep the passages that contain words from the
question (text that is already short enough is left alone), and a page
shrinks to a single line only in an emergency. A shortening never ends the
research.

**Sites that refuse.** A site that refuses a read three times (HTTP 401, 403,
429 or 451) is skipped for the rest of the run; a good read from it resets the
count. Other failures, such as a timeout, do not count against the site.

**Rewrites.** After the answer, the loop may ask the model once to rewrite it
(sources it never read, missing source numbers, or the wrong language). It
skips that request when the context window cannot hold the answer twice, and
keeps the first answer.

**Getting the model to read.**
- A model that answers from memory without searching is asked once to search.
  One that answers from search previews alone is asked once to open pages.
- If it still does not read, or keeps repeating searches it already ran, or
  never opens a page, the loop opens the top search results itself (the first
  hit of every search before any second hit) and hands the pages over.
- A repeated search or page read is refused ("repeated search refused"). One
  exception: a page may be read again once after older results were shortened,
  since the model may no longer have the text.
- If two steps in a row do nothing but repeat, the loop stops and asks for the
  final answer.
- A question that names a number of sources ("at least 10 sources") is noticed;
  the model is reminded how many pages it has read and asked once to keep going.

**After the answer.**
- An answer that stopped at the token limit is given back once, with the cut-off
  text, to continue exactly where it stopped. A short answer that seems to end
  in the middle of a sentence is asked about once.
- An answer that cites source numbers no page was read for, leaves figures
  without a source number, or is in the wrong language (German or English, if
  the question asked) is rewritten once. The rewrite is kept only if it is
  complete and not worse.
- **Figure check.** The report flags figures, dates and names in the answer that
  the pages the same sentence cites do not back up: numbers not on the cited
  pages, numbers on a page but not next to what the sentence names, and names a
  cited page does not have. It is a hint, not proof: a page can state a figure
  in words or in another unit.

**Time limits.** A step with reasoning on that takes longer than the thinking
limit (3 minutes by default) is cancelled and asked again without reasoning,
which then stays off for the rest of the question. The timer covers the whole
request, including any wait behind another request and the time the server
needs to read the prompt. A step with reasoning already off that takes longer
than the step limit (30 minutes) is asked once more with older results
shortened; a second failure ends the question (the pages read are kept).

**Stop.** **Stop** (or Control-C in the terminal) closes the connection to the
model server. TUFF's replies are read as a stream, so the server notices that
nobody is listening and stops generating; a TUFF that is loading its model
notices only after it has loaded. llama.cpp, and TUFF from 8.3.11 on, also
stop without streaming. The Mac stays awake while a question runs.

**Ended early.** A question that ends with an error or is stopped after it
searched or read a page still keeps what it gathered: the report has no answer,
starts with a note that the research ended early and why, and lists the pages
read and the searches.

## Reading passages instead of page starts

With **Read the passages that best match the question first** (`--passages on`;
off by default) an `open_page` call returns the best matching paragraphs of a
page instead of its beginning. The ranking happens in the sandbox: it splits the
page text into paragraphs, scores them against the question and the model's
search with BM25 (pure Python, no extra package) and returns the best ones that
fit, in page order, each behind a line `[characters 3000-3048]`, with `[...]`
where passages did not stand next to each other. The next read returns the next
best passages. The same request always gets the same answer. A read is then 2000
characters unless `--page-chars` is given.

## Settings

The command line and the app's two presets (**Quick answer** and **Thorough**)
share these settings, with the same ranges. The app keeps what you changed
between launches. Run `sandseek --help` for every option.

| Command line | App | Default | What it does |
| --- | --- | --- | --- |
| `--max-steps <1...100>` | Steps | 8 | Search and read rounds before the model must answer. |
| `--thinking on\|off` | Thinking | server default | Reasoning on or off. `--show-thinking` turns it on unless it is off and prints it under each `[n] thinking…` line; it is not added to the report. |
| `--max-tokens <64...32768>` | Tokens per step | 2048, or 8192 with reasoning on | Tokens the model may write per step. |
| `--page-chars <500...20000>` | Page text per read | 3000 | Characters one page read returns. |
| `--passages on\|off` | Read the passages that best match the question first | off | See above. |
| `--context-chars <2000...1000000>` | Prompt budget (llama.cpp without a context size) | from the model | How long the conversation may grow before older results are shortened. |
| `--search-results <1...10>` | Results per search | 5 | Results each search returns. |
| `--tool-calls <1...8>` | Tool calls per step | 4 | Searches and page reads the model may ask for in one step. |
| `--min-pages <1...12>` | Pages to read | 3 | Pages the model is asked to read; the loop opens top results to reach it. |
| `--auto-open on\|off` | Open top results when too few pages are read | on | The loop opens top results itself. |
| `--nudges on\|off` | Ask the model to search, read and look wider | on | The requests to search first, open pages and look wider. |
| `--rewrite on\|off` | Rewrite answers that cite unread pages or lack citations | on | One rewrite for unread citations, figures without a source number, or the wrong language. |
| `--only-seen-urls on\|off` | (none, always on) | on | `open_page` opens only addresses shown to the model. Off is for measuring the model alone. |
| `--page-links on\|off` | (none, always off) | off | Also open addresses that appear only in the text of a page read. For comparing source counts. |
| `--step-timeout <1...60>` | Step time limit | 30 minutes | See time limits above. |
| `--thinking-limit <1...60>` | Thinking time limit | 3 minutes | See time limits above. |

The two presets: **Quick answer** is 8 steps, at least 3 pages and 5 results per
search; **Thorough** is 30 steps, at least 6 pages and 8 results per search. The
Thorough values are a first guess and will be adjusted after measuring.
Limits that protect the Mac are not settings: the sandbox, its firewall, the
loopback-only addresses, the fetch limits and the report rules stay fixed.

For measuring, three environment variables exist and the app has no setting
for them: `SANDSEEK_PRESERVE_THINKING=on|off|auto` (whether the model's earlier
reasoning is sent back with its tool calls, which keeps a Qwen server's prompt
cache valid), `SANDSEEK_MARKERS=fixed|nonce` (a random code in the markers
around web text) and `SANDSEEK_DUMP_ANSWER_REQUEST=<file>` (the command line
writes the final answer request to that file, to check what page text reached
the answer).

## The model servers

SandSeek asks every server the usual OpenAI-style way, and a small connector per
server covers the differences. A server without a connector is not used, even
if it calls itself OpenAI-compatible.

- **TUFF 8.3.1 or newer.** It reports the model's context window itself and
  rejects fields it does not know, so only known fields are sent. Replies are
  read as a stream. Research makes many long prompts, so model speed matters:
  Qwen3.6 35B-A3B gives good answers; a question takes roughly 2 to 8 minutes
  on a 16 GB Mac (estimates from earlier runs).
- **llama.cpp (`llama-server`).** The app reads the context window from `/props`;
  the `sandseek` command does not, and uses a 16,000-character prompt budget
  unless `--context-chars` is given. The key from the key file is sent with every
  request. Requests are plain (not
  streamed) for now. If the server gives no context size, Settings has a prompt
  budget.

On a Mac with 16 GB, run only one model server with a loaded model at a time.

## Reports

Every finished question is saved as Markdown and JSON in
`~/Library/Application Support/SandSeek/Reports`. A report holds the question,
the answer with numbered sources, the searches, the figure check and, if the
server sent it, the model's thinking. Reports load nothing when opened.
Reports saved by TUFF's research screen are copied once each into this folder
(the originals stay).

## What it cannot do

- It cannot read pages that need JavaScript, or scanned PDFs (there is no OCR).
  Text PDFs up to 5 MB and 50 pages are read; encrypted ones are refused.
- It cannot make a small model right: it can only make it check its work and
  show its sources. Read the sources.
- It cannot search or read without leaving traces: the search engine and the
  sites see your IP address.

The earlier, much more detailed guide (every rule of the loop and its history)
stays readable in the repository history: `git show e7fcff1:docs/WEB_RESEARCH.md`.

## Credits

SandSeek began in a fork of the TUFF project and uses Apple's `container`; see
`NOTICE` for the details and the licences. The code, tests and docs were written
with Claude (Anthropic) through Claude Code and reviewed by separate Claude
sessions. The builds and test runs listed in these pages were run on the
author's own Mac.
