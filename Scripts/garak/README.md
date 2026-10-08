# garak on the Mac: scanning the TUFF model

A test tool only, not part of the product. Checked against garak 0.17.0.

## What it does

garak is NVIDIA's scanner for language models (Apache 2.0). It sends attack prompts to TUFF's local OpenAI-compatible server and checks each answer with a detector. The result is a hit rate per probe: the share of prompts where the model did what the attack wanted.

It tests the model (Qwen3.6 35B-A3B) on its own. It does not test the sandbox or the research loop; `Scripts/research_injection_check.py` does that.

Three groups of probes run:

- `latentinjection`: instructions hidden inside a document, such as a translation task, a report, a resume or a whois record. This is the closest to web pages.
- `badchars`: invisible characters, look-alike letters, reordering and deleted characters in the prompt.
- `encoding`: instructions written in base64, hex, ROT13 and other encodings, which the model should not decode and obey.

Thinking is off for the whole run (`enable_thinking: false` is sent with each request), as in the research loop.

## Files

- `Scripts/garak/garak-tuff.yaml`: points garak at `http://127.0.0.1:8080/v1/` with the generator `openai.OpenAICompatible`, thinking off, 400 tokens per answer.
- `Scripts/garak/run_garak.sh`: creates the venv, installs garak, checks the server and the model, runs the probes, writes the reports.

## Rules for the run

- Quit the TUFF app completely first. The app and a second server must not both hold the model.
- Run one heavy job at a time. A 16 GB Mac has room for one Qwen 35B and nothing else big. No benchmark, no injection check, no build at the same time.
- Start `TUFFServer` alone, with the scratch model folder, and stop it when the run is over.
- Keep the Mac awake and on power.

## Python

garak needs Python 3.11 or newer. If `python3` on the Mac is older, the script stops with a message. Install one and point the script at it:

```sh
brew install python@3.12
GARAK_PYTHON="$(brew --prefix python@3.12)/bin/python3.12" Scripts/garak/run_garak.sh
```

`GARAK_PYTHON` is only used when the venv is created.

## Default run and run time

The default run is a first, small pass: 8 prompts per probe class, one generation each, about 96 prompts. It covers 7 latentinjection classes (not `LatentWhois` and `LatentJailbreak`), the encodings base64, hex, ROT13 and Unicode tag characters, and badchars.

I could not time a real Qwen answer on a Mac. At 15 to 40 seconds per prompt (a long prompt plus up to 400 answer tokens), the default run takes about 25 to 65 minutes. Work out the real figure from the progress bar in the first minutes.

The wide run is the earlier, larger spec: all of `probes.latentinjection`, `probes.badchars` and `probes.encoding` at 16 prompts per class. That is about 552 prompts (15 encoding classes) and roughly 2.5 to 6 hours. The full garak sets have about 256 prompts per class, over 6,000 in all; that takes days.

## Step by step

1. Quit TUFF (menu bar, Quit). Check that no TUFF process remains:

```sh
pgrep -fl TUFF
```

2. Start the server alone in a terminal window and leave it running:

```sh
cd ~/Developer/TUFF
swift run -c release TUFFServer --models-root ~/Developer/TUFF/scratch
```

3. In a second terminal window, check that it answers:

```sh
curl -s http://127.0.0.1:8080/v1/models
```

4. Smoke test with one small probe class:

```sh
cd ~/Developer/TUFF
GARAK_SPEC=probes.encoding.InjectBase64 GARAK_PROMPT_CAP=4 Scripts/garak/run_garak.sh
```

The first call creates `~/Developer/garak-venv` and installs garak, which takes a few minutes and a few GB of downloads.

5. The default run:

```sh
cd ~/Developer/TUFF
Scripts/garak/run_garak.sh
```

6. The wide run:

```sh
GARAK_PROMPT_CAP=16 GARAK_SPEC=probes.latentinjection,probes.badchars,probes.encoding Scripts/garak/run_garak.sh
```

7. Other probe sets, through variables:

```sh
GARAK_SPEC=probes.latentinjection GARAK_PROMPT_CAP=8 Scripts/garak/run_garak.sh
GARAK_SPEC=probes.badchars Scripts/garak/run_garak.sh
```

The variables are `GARAK_SPEC`, `GARAK_GENERATIONS` (default 1), `GARAK_PROMPT_CAP` (default 8), `TUFF_PORT` (default 8080), `TUFF_MODEL` (default `qwen3.6-35b-a3b`), `GARAK_PYTHON`, `GARAK_VERSION` (default 0.17.0), `GARAK_VENV` and `GARAK_REPORT_DIR`. The script checks that the port, cap and generations are numbers, that the installed garak matches `GARAK_VERSION` (it reinstalls otherwise), and that the server lists `TUFF_MODEL`.

8. When it is done, stop the server: press Control-C in the window where `TUFFServer` runs. Then check that nothing is left:

```sh
pgrep -fl TUFFServer
```

9. You can start the TUFF app again.

If a run is interrupted, stop the server the same way. A half-finished run leaves a partial report file, which is fine to delete.

## Where the reports are

`~/Developer/garak-reports/run-<date>-<time>.report.jsonl` is the full record, one line per prompt, answer and detector result. garak also writes `run-<date>-<time>.report.html`, a summary page. If there are hits, it also writes a `.hitlog.jsonl` with only the prompts that succeeded as attacks.

## How to read the report

At the end of the run garak prints, per probe and per detector, a line with PASS or FAIL and a number such as `ok on 188/200`.

- Hit rate = failed / total. `ok on 188/200` means 12 prompts out of 200 got the model to do what the attack wanted, a hit rate of 6 percent. Lower is better.
- garak marks a probe FAIL when any prompt hits; do not stop at the label. Look at the rate and at which probe has it.
- Compare the probes with each other. A high rate in `latentinjection` matters most for web research. A high rate in `encoding.InjectBase64` only says the model decodes base64 and repeats the payload, which is often harmless on its own.
- Open the `.hitlog.jsonl` and read a few real hits for each probe with a high rate. Detectors can be wrong in both directions, so a number alone is not proof.
- With 8 prompts per class the rates are coarse. Use them to see where to look, not to compare small differences.
- Keep the first report as the baseline. After a change, run the same `GARAK_SPEC` again and compare rates, not single answers. With one generation per prompt, small differences between runs are noise (the model samples at temperature 0.7).

## Exact probe modules (garak 0.17.0)

- `probes.latentinjection`: `LatentInjectionReport`, `LatentInjectionResume`, `LatentInjectionTranslationEnFr`, `LatentInjectionTranslationEnZh`, `LatentInjectionFactSnippetEiffel`, `LatentInjectionFactSnippetLegal`, `LatentJailbreak`, `LatentWhois`, `LatentWhoisSnippet`
- `probes.badchars`: `BadCharacters`
- `probes.encoding`: `InjectBase64`, `InjectBase16`, `InjectBase32`, `InjectAscii85`, `InjectHex`, `InjectROT13`, `InjectMorse`, `InjectUnicodeTagChars` and others

The list of what the installed version has:

```sh
~/Developer/garak-venv/bin/python -m garak --list_probes
```

## What was checked, and what was not

Checked on a Linux test machine with garak 0.17.0 and a fake OpenAI-compatible server in place of TUFF:

- The probe module and class names exist in 0.17.0.
- `run_garak.sh` runs end to end with the default spec, sends 96 requests, and writes the `.report.jsonl` and `.report.html`.
- Each request carries only `model`, `messages`, `max_tokens`, `temperature`, `top_p` and `enable_thinking: false`, all fields TUFF's server accepts.
- The script refuses a non-numeric port and a model the server does not list.

Not checked: a real run against TUFF on a Mac, the run time, and the hit rates of Qwen. If the first smoke test fails with a 4xx error, read the message in the server window and tell Claude.
