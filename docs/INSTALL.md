# Installing SandSeek

SandSeek is built from source on your Mac. There is no installer and no
download of a finished app yet. This page covers what you need, how to build and
package the app, how to start a model server safely, the first run, where
things are stored and how to remove everything again.

For what the security design does and does not promise, read
[SECURITY.md](SECURITY.md).

## Requirements

- A Mac with Apple silicon and **macOS 26** (Apple `container` needs it).
- **16 GB of memory** is the size the project was tested on. A model server with
  a loaded model uses most of it, so run only one server at a time.
- **Apple `container`**, from its
  [releases page](https://github.com/apple/container/releases). After the
  installer has run, `container system start` starts its background service
  (SandSeek's scripts do this when it is not running).
- A **Swift 6.2 toolchain** to build: Xcode 26, or the command line tools that
  come with it. `swift --version` should print 6.2 or newer.
- A **local model server** that SandSeek can connect to:
  - **TUFF 8.3.1 or newer** (the official release), with a Qwen model for
    research; or
  - **llama.cpp** (`llama-server`), with a model that supports tool calls (the
    project probed it with Bonsai). llama.cpp is experimental in 0.1.0: no
    streaming, the Thinking switch has no effect on it yet, and no research
    run was measured with it; see [SECURITY.md](SECURITY.md).
  - Ollama and LM Studio are planned (the picker shows them as "later");
    other servers are not supported yet.
- Research makes many long prompts, so model speed matters. Qwen3.6 35B-A3B on
  TUFF gives good answers and takes a few minutes per question; Gemma 4 E4B is
  faster and weaker. A model that has to stream far more than the installed
  memory is too slow for multi-step research on most Macs.
- An internet connection. The first sandbox start downloads a base image and
  builds the sandbox image, which takes a few minutes.

## Build the command and the tests

From the folder of your SandSeek checkout:

```sh
swift build -c release
swift test
python3 -m unittest Sandbox/test_server.py
```

The first build fetches nothing from the internet: SandSeek uses only Apple's
own libraries. `swift build` produces the `sandseek` command in
`.build/release/sandseek`.

## Build and package the app

```sh
Scripts/package_app.sh
open build/SandSeek.app
```

The script builds the app in release mode, assembles `build/SandSeek.app` with
the sandbox files inside it and signs it ad hoc. That is enough to run it on
the Mac that built it. It is not notarized: if you copy it to another Mac,
macOS may refuse to open it, and you have to approve it in System Settings under
Privacy & Security. You can drag `build/SandSeek.app` to the Applications
folder.

`swift run SandSeekApp` also opens the window, but a bare executable has no
sandbox files inside it. Set `SANDSEEK_SOURCE_DIR=/path/to/checkout` to point
such a debug build at your checkout.

## Start a model server safely

SandSeek connects to a model server on this Mac's loopback address (127.0.0.1)
only. You can start the server yourself, or click **Start server** on the model
server card: SandSeek then runs the program you chose (`TUFFServer` or
`llama-server`) without a shell, on 127.0.0.1 and the port of the card's
address, and **Stop server** (or quitting SandSeek normally) stops it again. It
stops only a server it started. After a crash or `kill -9` a server SandSeek
started can keep running (in our test a Force Quit from the Dock ended it with
the app): the next launch finds it and offers **Stop server**, or quit it in
Activity Monitor. Run only one SandSeek
at a time: a second one would take over the first one's server as a leftover and
stop it when it quits.

**The server must listen on 127.0.0.1 only**, never on all addresses: a server
that listens on the network can be used by every machine on it. Started from
the card it does. If you start it yourself, SandSeek checks this for you (see
below), but the safe start is the better protection.

### TUFF

Either click **Start server** in SandSeek, or start TUFF's **Background API** on
its Server screen, or (if the `tuff` command is installed; a clone build has
none) run `tuff serve`. TUFF listens on 127.0.0.1:8080 unless you change the
port, and nowhere else.

To use the button, choose the program once. SandSeek always starts `TUFFServer`
itself, because stopping `tuff` would leave the `TUFFServer` it started running
with the model loaded. So choose `TUFFServer` (in a clone:
`.build/release/TUFFServer`; press Cmd-Shift-. in the dialog to show the hidden
`.build` folder), or `tuff` or `TUFF.app`, and SandSeek uses the
`TUFFServer` beside it; the card shows the path that will run. SandSeek passes
only `--port` (from the card's address) and, if you chose a models folder,
`--models-root`. Without a folder TUFFServer uses the installed TUFF's models
folder; a TUFF built from a clone keeps its models in `<clone>/scratch`, so
choose that folder. The server gets only `PATH`, `HOME` and `TMPDIR` as its
environment (`HOME` from the account database, `TMPDIR` from the system), so
`TUFF_*` settings in your environment do not apply to a server SandSeek starts.
Check it:

```sh
curl -s http://127.0.0.1:8080/tuff/v1/status
```

An answer with a version number means it runs. TUFF 8.3.1 has no check of the
`Host` header, so quit the server when you are not using it (see
[SECURITY.md](SECURITY.md)). If you start it with the button, it is easy to
leave it running for hours with the window open: click **Stop server** when you
are done.

### llama.cpp

llama.cpp must be started with `--host 127.0.0.1` **and** a key file, because it
has no host check either. The key is what stops a web page in your browser from
using the server.

1. Open SandSeek and choose **llama.cpp** on the model server card. The app
   makes a random key once and keeps it in
   `~/Library/Application Support/SandSeek/State/llamacpp-api-key` (readable
   only by you), and the card shows a start command that names that file. **Copy
   start command** copies it. The key itself is never in the command.

   Without the app, make the key file by hand:

   ```sh
   mkdir -p ~/Library/Application\ Support/SandSeek/State
   chmod 700 ~/Library/Application\ Support/SandSeek/State
   openssl rand -hex 32 > ~/Library/Application\ Support/SandSeek/State/llamacpp-api-key
   chmod 600 ~/Library/Application\ Support/SandSeek/State/llamacpp-api-key
   ```

2. Click **Start server** after choosing `llama-server` and a `.gguf` model on
   the card. SandSeek starts it only when the key file exists, belongs to you,
   has mode 0600 and holds the key; it never starts llama-server without the
   key. Or run the command in Terminal. It looks like this:

   ```sh
   llama-server -m <model.gguf> --alias <name> --host 127.0.0.1 --port 8081 \
     -c 16384 -np 1 --jinja \
     --api-key-file ~/Library/Application\ Support/SandSeek/State/llamacpp-api-key
   ```

   `--host 127.0.0.1` keeps it on this Mac, `-np 1` gives one slot the whole
   context, `--jinja` turns on tool calls, and `--api-key-file` makes the server
   ask for the key. Do not use `--api-key <key>`: it would show the key in the
   process list and your shell history. The `sandseek` command takes the same
   file: `--api-key-file <path>`. The button runs the same arguments (with
   `--alias` set from the model's file name). The server gets only `PATH`,
   `HOME` and `TMPDIR`, so `LLAMA_ARG_*` settings in your environment do not
   apply to it.

### If macOS asks for permission or blocks the program

A server SandSeek starts counts as SandSeek for macOS privacy. A model in
Downloads, Documents, Desktop, iCloud Drive or on an external disk makes macOS
ask whether SandSeek may access it, and the answer is asked again after you
rebuild the app. If you say no, the server ends with "failed to open", which the
card shows. A program that you downloaded in a browser carries a "downloaded"
mark. It is refused until macOS has approved it: run it once from Terminal and
allow it in System Settings > Privacy & Security, or, if you trust where it came
from, remove the mark with `xattr -d com.apple.quarantine <file>`. The
server's output goes to `~/Library/Application Support/SandSeek/Logs/model-server.log`
(readable only by you, replaced on every start, never sent to the model).

### Check that nothing else can reach the server

With the server running:

```sh
.build/release/sandseek --check-exposure --server http://127.0.0.1:8081
```

Use the port of your server (8080 for TUFF). The command tries each of this
Mac's own network addresses on that port and on the sandbox's port, and sends
nothing. Every address comes out as accepted, refused or not known (a timeout
or another failure, for example macOS Local Network privacy). Exit codes:

- 0: every address refused the connection. Nothing answers on the network.
- 3: something answered. Stop the server and start it again so that it
  listens on 127.0.0.1 only (llama-server: `--host 127.0.0.1`). TUFF always
  stays on 127.0.0.1, so on its port this means another program answers there.
- 4: the model server does not answer on this Mac at all; start it first.
- 5: some address neither accepted nor refused, so the result says nothing.
  If macOS asks SandSeek for Local Network access, allow it and run the check
  again.
- 2: bad arguments.

The app does the same check for the model server's port when you press **Check**
on the model server card, and shows a warning if the server is reachable, or a
note if it could not tell.

## First run

1. Open `SandSeek.app`. The window has a sidebar (Research, Reports, Settings).
   The Research screen has the question box on top, then a **Model server**
   card and a **Sandbox** card. The arrow by a card's title folds it; the (i)
   button has the longer explanations. **Start everything** does steps 2 and 3
   for you (it starts the model server only if you chose a program for it, see
   above), then runs the security check. **Stop everything** stops the
   question and the sandbox (also one you started yourself), and the model
   server only if SandSeek started it.
2. On the model server card, choose TUFF or llama.cpp, check the address, and
   press **Check**. It should say **Connected** and list the models.
3. On the sandbox card, press **Start Sandbox**. The first start builds the
   image and takes a few minutes. When it says **Ready**, the app has checked the
   firewall and the server's privileges from outside the VM, and the card shows
   **Signed** with the time of the last signed health check.
   **Security check** runs the longer self-test (about a minute).
4. Pick the model, choose **Quick answer** or **Thorough**, type a question and
   press **Research** (Command-Return). Progress and answer appear side by side;
   **Stop** ends the question. A saved report opened during a run gets its own
   window. Sources are cards; **Copy answer** copies the answer as plain text,
   and a report can be printed (Command-P) or exported with **Export as PDF…**.

From Terminal, with the sandbox started (`Scripts/research_sandbox.sh build`
once, then `start`) and a server running:

```sh
.build/release/sandseek --server http://127.0.0.1:8080 "your question"
```

The answer is printed as Markdown with numbered sources. `--output notes.md`
also writes it to a new file, `--show-thinking` prints the model's reasoning
under each step, and `--max-steps <1...100>` sets how many search and read
rounds the model may take (default 8). `sandseek --help` lists all options.
`Scripts/research_sandbox.sh stop` stops the sandbox when you are done.

## Where things are stored

| What | Where |
| --- | --- |
| Finished reports (Markdown and JSON) | `~/Library/Application Support/SandSeek/Reports` |
| The llama.cpp key file | `~/Library/Application Support/SandSeek/State/llamacpp-api-key` |
| A note that SandSeek started a model server (so a later launch can find it) | `~/Library/Application Support/SandSeek/State/model-server-started-by-app.json` |
| The log of the model server SandSeek started | `~/Library/Application Support/SandSeek/Logs/model-server.log` |
| The app's settings (server choice, addresses, the chosen server program, model and models folder, presets, last question) | the app's preferences file in `~/Library/Preferences` (its name contains `sandseek`) |
| The sandbox image and VM | Apple `container`: image `sandseek-sandbox:latest`, VM `sandseek-sandbox` |
| The built app and command | `build/SandSeek.app`, `.build/release/sandseek` in your checkout |

Reports from TUFF's research screen (in `~/Library/Application Support/TUFF/Research
Reports`) are copied into the Reports folder once each when the app starts. The
originals are never changed or removed.

## Update

Fetch the new code, then build and package again. The app rebuilds the sandbox
image by itself when anything in `Sandbox/` changed; by hand, run
`Scripts/research_sandbox.sh build`. Quit the app and stop the sandbox first
(**Stop everything**, or `Scripts/research_sandbox.sh stop`).

After updating from the first release, the first **Start** rebuilds the sandbox image, which
takes a few minutes. The old secret file in TUFF's folder is removed.

## Uninstall

Nothing is installed outside your home folder and Apple `container`. Remove the
parts you do not want, by hand. **Move things to the Trash instead of deleting
them with a command**, so you can still get them back.

1. Quit SandSeek. Stop the sandbox with **Stop Sandbox** or
   `Scripts/research_sandbox.sh stop`, and the model server (**Stop server**, or
   its own window). Check that no `TUFFServer` or `llama-server` is left in
   Activity Monitor.
2. Remove the sandbox image. List the images with `container image list`, then
   remove `sandseek-sandbox:latest` with `container image delete
   sandseek-sandbox:latest` (see `container image --help` if your version names
   the command differently). This only removes the image, which can be built
   again. If you no longer use Apple `container` at all, uninstall it by its
   own instructions.
3. In Finder, move `SandSeek.app` to the Trash (and the `build` folder of your
   checkout, if you built it there).
4. **Your reports are in `~/Library/Application Support/SandSeek/Reports`.** If
   you want to keep them, copy that folder somewhere else first. Then, in
   Finder, choose Go > Go to Folder, open `~/Library/Application Support` and
   move the `SandSeek` folder to the Trash. It holds the reports, the key
   file and the model server's log; move that folder only when you no longer need any of them. A llama.cpp
   server started with that key file will not start again without it.
5. In `~/Library/Preferences`, move the preferences file whose name contains
   `sandseek` to the Trash.
6. Move the checkout folder to the Trash if you no longer need the source code.

## Troubleshooting

- **"Apple container is not installed"**: install it from the releases page above.
- **The sandbox does not become Ready, or "Not verified"**: stop it and start it
  again. If it stays red, run `Scripts/research_sandbox.sh selftest` and read the
  `FAIL` lines.
- **The model server card says "Not running"**: start the server (see above) and
  press **Check**. The address must be on 127.0.0.1 with a port, and not 9100,
  which is the sandbox's.
- **llama.cpp: "refused the key"**: the server was started without the key file
  the app made. Start it again with the command on the card.
- **A question is very slow**: a 16 GB Mac holds one model at a time. Quit other
  servers and large apps. Thinking and long pages make steps slower.
