#!/usr/bin/env python3
"""Helpers for Scripts/full_test.sh (bash 3.2 and BSD tools have no timeout,
no JSON and no portable port probe, so they live here).

  full_test_helpers.py run LOGFILE SECONDS COMMAND [ARGS...]
      Runs COMMAND with stdin from /dev/null in its own process group, writes
      its output to LOGFILE with secrets masked, and kills the whole group
      after SECONDS (exit 124) or when this process gets SIGTERM/SIGINT
      (exit 143). Otherwise exits with the command's status.
  full_test_helpers.py mask            masks stdin to stdout
  full_test_helpers.py http-code URL   prints the HTTP status, or 000 when nothing answers
  full_test_helpers.py listening PORT  exit 0 when something listens on 127.0.0.1:PORT
  full_test_helpers.py free-port       prints a free loopback port
  full_test_helpers.py home            prints the account's home folder
  full_test_helpers.py report RUN_DIR OVERALL REASON
      Reads RUN_DIR/results.tsv and writes report.md and report.json, and
      prints the one-screen summary.

Secrets are masked with the contents of the files named in FT_MASK_FILES
(separated like PATH), any run of 64 hex characters, and Bearer tokens.
Python 3 standard library only.
"""

import json
import os
import pwd
import re
import signal
import socket
import subprocess
import sys
import urllib.error
import urllib.request

MASK = "***"
HEX64 = re.compile(r"\b[0-9a-fA-F]{64}\b")
BEARER = re.compile(r"(?i)(bearer\s+)\S+")
TAIL_LINES = 15

STILL_MANUAL = [
    "Dock icon look (the icon file is checked; how it looks is not)",
    "Folding cards in the window",
    "The Start everything and Stop everything buttons",
    "Print and Export as PDF dialogs",
    "The report window",
    "Copy answer",
]


def secrets():
    found = []
    for path in os.environ.get("FT_MASK_FILES", "").split(os.pathsep):
        if not path:
            continue
        try:
            with open(path, "rb") as handle:
                value = handle.read(8192).decode("utf-8", "replace").strip()
        except OSError:
            continue
        if len(value) >= 6:
            found.append(value)
    return sorted(set(found), key=len, reverse=True)


def mask(text, known=None):
    for value in (secrets() if known is None else known):
        text = text.replace(value, MASK)
    text = HEX64.sub(MASK, text)
    return BEARER.sub(lambda match: match.group(1) + MASK, text)


def run(log, seconds, command):
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    state = {"stop": None}

    def kill_group():
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass

    def on_signal(number, _frame):
        state["stop"] = 143
        kill_group()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    # Reading in a thread-free way: a timer thread kills the group on time.
    import threading
    timer = threading.Timer(seconds, lambda: (state.__setitem__("stop", 124), kill_group()))
    timer.daemon = True
    timer.start()
    chunks = []
    try:
        for line in iter(process.stdout.readline, b""):
            chunks.append(line)
    finally:
        process.wait()
        timer.cancel()
        kill_group()  # stray children that kept the group alive
    text = b"".join(chunks).decode("utf-8", "replace")
    if state["stop"] == 124:
        text += f"\n[full_test: stopped after {seconds} s]\n"
    with open(log, "w", encoding="utf-8") as handle:
        handle.write(mask(text))
    if state["stop"]:
        return state["stop"]
    return process.returncode if process.returncode >= 0 else 128 - process.returncode


def http_code(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as answer:
            return str(answer.status)
    except urllib.error.HTTPError as error:
        return str(error.code)
    except Exception:
        return "000"


def listening(port):
    with socket.socket() as probe:
        probe.settimeout(2)
        return probe.connect_ex(("127.0.0.1", int(port))) == 0


def tail(path, count=TAIL_LINES):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return mask("".join(handle.readlines()[-count:])).rstrip("\n")
    except OSError:
        return "(no log)"


def read_results(run_dir):
    rows = []
    try:
        with open(os.path.join(run_dir, "results.tsv"), encoding="utf-8") as handle:
            for line in handle:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 4:
                    continue
                parts += [""] * (6 - len(parts))
                rows.append({"id": parts[0], "name": parts[1], "result": parts[2],
                             "seconds": int(parts[3] or 0), "note": mask(parts[4]),
                             "log": parts[5]})
    except OSError:
        pass
    return rows


def report(run_dir, overall, reason):
    rows = read_results(run_dir)
    counts = {key: sum(1 for row in rows if row["result"] == key) for key in ("PASS", "FAIL", "SKIP")}
    for row in rows:
        row["log_tail"] = tail(row["log"]) if row["result"] == "FAIL" and row["log"] else ""
    total = sum(row["seconds"] for row in rows)
    lines = [f"# SandSeek full test: {overall}", "",
             f"Run folder: `{run_dir}`", "",
             f"{counts['PASS']} passed, {counts['FAIL']} failed, {counts['SKIP']} skipped, "
             f"{total} s in steps." + (f" Stopped early: {reason}." if reason else ""), "",
             "| Step | Result | Time | Note |", "|---|---|---|---|"]
    for row in rows:
        note = row["note"].replace("|", "/")
        lines.append(f"| {row['id']} {row['name']} | {row['result']} | {row['seconds']} s | {note} |")
    failed = [row for row in rows if row["result"] == "FAIL"]
    if failed:
        lines += ["", "## Failures"]
        for row in failed:
            lines += ["", f"### {row['id']} {row['name']}", "", row["note"], "", "```",
                      row["log_tail"], "```", "", f"Full log: `{row['log']}`"]
    lines += ["", "## Still manual", ""] + [f"- {item}" for item in STILL_MANUAL]
    text = mask("\n".join(lines) + "\n")
    with open(os.path.join(run_dir, "report.md"), "w", encoding="utf-8") as handle:
        handle.write(text)
    data = {"overall": overall, "reason": reason, "run_folder": run_dir,
            "counts": counts, "seconds": total,
            "steps": [{"id": row["id"], "name": row["name"], "result": row["result"],
                       "seconds": row["seconds"], "note": row["note"],
                       "log": row["log"], "log_tail": row["log_tail"]} for row in rows],
            "still_manual": STILL_MANUAL}
    with open(os.path.join(run_dir, "report.json"), "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    # One screen: the table, then the failures' notes.
    shown = [f"SandSeek full test: {overall}  ({counts['PASS']} pass, {counts['FAIL']} fail, "
             f"{counts['SKIP']} skip)"]
    for row in rows:
        shown.append(f"  {row['result']:<5}{row['seconds']:>5} s  {row['id']} {row['name']}"
                     + (f"  ({row['note'][:70]})" if row["note"] else ""))
    if reason:
        shown.append(f"  stopped early: {reason}")
    print(mask("\n".join(shown)))


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    command = argv[1]
    if command == "run" and len(argv) >= 5:
        return run(argv[2], float(argv[3]), argv[4:])
    if command == "mask":
        sys.stdout.write(mask(sys.stdin.read()))
        return 0
    if command == "http-code" and len(argv) == 3:
        print(http_code(argv[2]))
        return 0
    if command == "listening" and len(argv) == 3:
        return 0 if listening(argv[2]) else 1
    if command == "free-port":
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            print(probe.getsockname()[1])
        return 0
    if command == "home":
        print(pwd.getpwuid(os.getuid()).pw_dir)
        return 0
    if command == "report" and len(argv) == 5:
        report(argv[2], argv[3], argv[4])
        return 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
