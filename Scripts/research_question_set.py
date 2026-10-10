#!/usr/bin/env python3
# Third-party notice: the SimpleQA grading prompt (GRADER_TEMPLATE) and the
# question format come from OpenAI simple-evals (simpleqa_eval.py),
# https://github.com/openai/simple-evals, MIT License. The SimpleQA question
# file (simple_qa_test_set.csv) is not part of this repository and has its own
# terms; it is downloaded by hand.
#
# MIT License
#
# Copyright (c) 2024 OpenAI
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
"""A fixed question set for `tuff research`: pick, run, grade, compare.

The questions come from OpenAI's SimpleQA (MIT, https://github.com/openai/simple-evals).
Each has one short, checked answer that does not change over time, so the same
set can be run on every build and the numbers compared.

  select   pick N questions from simple_qa_test_set.csv, the same ones every time
  run      ask each question with the research command and save the reports
  grade    mark each answer CORRECT, INCORRECT or NOT_ATTEMPTED
  compare  put two graded runs side by side

Typical use on the Mac (one heavy job at a time; quit the TUFF app first):

  curl -fLo simple_qa_test_set.csv \\
    https://openaipublic.blob.core.windows.net/simple-evals/simple_qa_test_set.csv
  python3 Scripts/research_question_set.py select --csv simple_qa_test_set.csv --out questions.json
  python3 Scripts/research_question_set.py run --questions questions.json \\
    --research-bin .build/release/TUFFResearch --out-dir runs/baseline
  python3 Scripts/research_question_set.py grade --run-dir runs/baseline --model qwen3.6-35b-a3b
  python3 Scripts/research_question_set.py compare runs/baseline runs/spotlight

Grading uses the grader prompt from simple-evals (MIT) and asks the model on
the local TUFF server, with thinking off. Before that, a plain text check
marks answers that contain the reference answer word for word. Every answer
where the two disagree is listed for a person to check by hand: write
CORRECT, INCORRECT or NOT_ATTEMPTED into the "hand" field of grades.json and
run grade again; a hand mark always wins.

Only the Python standard library is used.
"""

from __future__ import annotations

import argparse
from math import comb
import ast
import csv
import hashlib
import json
import os
import random
import re
import statistics
import subprocess
import sys
import time
import unicodedata
import urllib.request

# --- select -----------------------------------------------------------------

DEFAULT_COUNT = 25
DEFAULT_SEED = 2026
MAX_ANSWER_CHARS = 40
MAX_QUESTION_CHARS = 300


def load_simpleqa(path: str) -> list[dict]:
    rows = []
    with open(path, newline="", encoding="utf-8") as handle:
        for index, row in enumerate(csv.DictReader(handle)):
            try:
                metadata = ast.literal_eval(row.get("metadata", "") or "{}")
            except (ValueError, SyntaxError):
                metadata = {}
            rows.append({
                "row": index,
                "question": row["problem"].strip(),
                "answer": row["answer"].strip(),
                "topic": str(metadata.get("topic", "Other")),
                "answer_type": str(metadata.get("answer_type", "Other")),
                "reference_urls": [str(u) for u in metadata.get("urls", [])][:5],
            })
    return rows


def eligible(row: dict) -> bool:
    # Short reference answers can be checked by eye; very long questions are
    # rare and mostly lists, which grade badly.
    return (0 < len(row["answer"]) <= MAX_ANSWER_CHARS
            and len(row["question"]) <= MAX_QUESTION_CHARS)


def select(rows: list[dict], count: int, seed: int) -> list[dict]:
    """Round robin over topics, each topic shuffled with a fixed seed, so the
    set covers every topic and is the same on every machine."""
    by_topic: dict[str, list[dict]] = {}
    for row in rows:
        if eligible(row):
            by_topic.setdefault(row["topic"], []).append(row)
    rng = random.Random(seed)
    topics = sorted(by_topic)
    for topic in topics:
        rng.shuffle(by_topic[topic])
    chosen: list[dict] = []
    while len(chosen) < count and any(by_topic[t] for t in topics):
        for topic in topics:
            if by_topic[topic] and len(chosen) < count:
                chosen.append(by_topic[topic].pop())
    for number, row in enumerate(chosen, 1):
        row["id"] = f"sqa-{number:02d}"
    return chosen


def command_select(args: argparse.Namespace) -> int:
    with open(args.csv, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
    rows = load_simpleqa(args.csv)
    chosen = select(rows, args.count, args.seed)
    payload = {
        "source": "OpenAI SimpleQA, simple_qa_test_set.csv (licence of the CSV: check before "
              "publishing; simple-evals code is MIT)",
        "csv_sha256": digest,
        "csv_rows": len(rows),
        "seed": args.seed,
        "rules": f"answer <= {MAX_ANSWER_CHARS} chars, question <= {MAX_QUESTION_CHARS} "
                 "chars, round robin over topics",
        "questions": chosen,
    }
    if os.path.exists(args.out):
        print(f"error: {args.out} exists; choose a new file", file=sys.stderr)
        return 2
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
    topics: dict[str, int] = {}
    for row in chosen:
        topics[row["topic"]] = topics.get(row["topic"], 0) + 1
    print(f"{len(chosen)} questions from {len(rows)} rows (sha256 {digest[:12]}):")
    for topic, n in sorted(topics.items()):
        print(f"  {topic}: {n}")
    return 0


# --- run --------------------------------------------------------------------

# Places where SimpleQA questions and answers are published. A run that reads
# one of them found the answer key, not the answer, and does not count.
LEAK_PATTERN = (r"(huggingface\.co/datasets|github\.com/openai/simple-evals|"
                r"openaipublic\.blob\.core\.windows\.net|kaggle\.com|simpleqa|simple_qa)")
CONSECUTIVE_FAILURES_TO_STOP = 3


def report_parts(markdown: str) -> dict:
    """Pulls the answer and simple counts out of a research report."""
    body = markdown.split("\n", 1)[1] if markdown.startswith("# ") else markdown
    # The report adds its own sections after the answer, in this order. The
    # answer may contain look-alike headings, so each is found from the end.
    starts = {}
    end = len(body)
    for name in ("Searches", "Figure check", "Sources"):
        found = body.rfind(f"\n## {name}\n", 0, end)
        if found >= 0:
            starts[name] = found
            end = found
    answer = body[:end]
    # Notes the loop appends ("_The research ...", "_No web page was read ...")
    # are not part of the answer.
    answer = re.split(r"\n_(?:The |No web page was read|Only one search)", answer,
                      maxsplit=1)[0].strip()

    def section(name: str) -> str:
        if name not in starts:
            return ""
        rest = body[starts[name] + len(name) + 5:]
        # Up to the next section; intro and note lines in _italics_ are skipped
        # by counting only "- " and "1. " lines.
        return rest.split("\n## ", 1)[0]

    ended_early = "This research ended early" in markdown
    return {
        "answer": "" if ended_early else answer,
        "ended_early": ended_early,
        "sources": len(re.findall(r"^\d+\. \[", section("Sources"), re.M)),
        "searches": len(re.findall(r"^- ", section("Searches"), re.M)),
        "figure_check_items": len(re.findall(r"^- ", section("Figure check"), re.M)),
        "budget_ran_out": "step budget ran out" in markdown,
        "no_pages_read": "No web page was read" in markdown,
        "leak_sources": sorted(set(re.findall(LEAK_PATTERN, section("Sources"), re.I))),
    }


def command_run(args: argparse.Namespace) -> int:
    with open(args.questions, encoding="utf-8") as handle:
        questions = json.load(handle)["questions"]
    all_questions = list(questions)
    if args.only:
        wanted = set(args.only.split(","))
        questions = [q for q in questions if q["id"] in wanted]
    os.makedirs(args.out_dir, exist_ok=True)
    results_path = os.path.join(args.out_dir, "results.json")
    results: dict[str, dict] = {}
    if os.path.exists(results_path):
        with open(results_path, encoding="utf-8") as handle:
            results = json.load(handle)
    env = dict(os.environ)
    for pair in args.env or []:
        key, _, value = pair.partition("=")
        env[key] = value
    settings = {"questions_sha256": file_sha256(args.questions),
                "research_bin": os.path.abspath(args.research_bin),
                "research_bin_sha256": file_sha256(args.research_bin),
                "thinking": args.thinking, "model": args.model or "default",
                "max_steps": args.max_steps, "extra": args.extra or [],
                "env": sorted(f"{k}={v}" for k, v in env.items()
                              if k.startswith(("TUFF_", "TFF_")))}
    earlier = {json.dumps(r.get("settings"), sort_keys=True) for r in results.values()}
    now = json.dumps(settings, sort_keys=True)
    if earlier and earlier != {now} and not args.mixed:
        print("error: this folder holds answers made with other settings or another "
              "build; use a new --out-dir (or --mixed if that is intended)", file=sys.stderr)
        return 2
    with open(os.path.join(args.out_dir, "questions.json"), "w", encoding="utf-8") as handle:
        json.dump({"questions": all_questions}, handle, ensure_ascii=False, indent=2)
    failures = 0
    for number, question in enumerate(questions, 1):
        done = results.get(question["id"])
        if done and done["exit"] == 0 and not args.again:
            continue
        command = [args.research_bin, "--quiet", "--max-steps", str(args.max_steps),
                   "--thinking", args.thinking]
        for flag, value in (("--model", args.model), ("--server", args.server),
                            ("--sandbox", args.sandbox)):
            if value:
                command += [flag, value]
        if args.save_pages:
            pages = os.path.abspath(os.path.join(args.out_dir, f"{question['id']}.pages.json"))
            if os.path.exists(pages):
                os.remove(pages)
            command += ["--save-pages", pages]
        command += args.extra or []
        command += ["--", question["question"]]
        print(f"[{number}/{len(questions)}] {question['id']}: {question['question'][:70]}",
              flush=True)
        started = time.monotonic()
        try:
            completed = subprocess.run(command, capture_output=True, text=True,
                                       timeout=args.timeout, env=env)
            seconds = time.monotonic() - started
            markdown, error, code = completed.stdout, completed.stderr, completed.returncode
        except subprocess.TimeoutExpired as expired:
            seconds = time.monotonic() - started
            markdown = expired.stdout or ""
            if isinstance(markdown, bytes):
                markdown = markdown.decode("utf-8", "replace")
            error, code = f"timed out after {args.timeout} s", -1
        with open(os.path.join(args.out_dir, f"{question['id']}.md"), "w",
                  encoding="utf-8") as handle:
            handle.write(markdown)
        entry = {"id": question["id"], "seconds": round(seconds, 1), "exit": code,
                 "error": error.strip()[-300:] if code else "", "settings": settings,
                 "at": time.strftime("%Y-%m-%d %H:%M:%S")}
        entry.update(report_parts(markdown))
        results[question["id"]] = entry
        with open(results_path, "w", encoding="utf-8") as handle:
            json.dump(results, handle, ensure_ascii=False, indent=2)
        print(f"    {seconds:.0f} s, exit {code}, {entry['sources']} pages", flush=True)
        # A broken server or sandbox fails every question at once; stop rather
        # than record a run of empty answers.
        failed = code != 0 and (not entry["answer"] or entry["ended_early"])
        failures = failures + 1 if failed else 0
        if failures >= CONSECUTIVE_FAILURES_TO_STOP:
            print(f"error: {failures} questions in a row failed without an answer; "
                  f"last error: {entry['error']}. Check the server and the sandbox, "
                  "then run the same command again.", file=sys.stderr)
            return 1
    # The questions travel with the run, so grading works after a move.
    with open(os.path.join(args.out_dir, "questions.json"), "w", encoding="utf-8") as handle:
        json.dump({"questions": all_questions}, handle, ensure_ascii=False, indent=2)
    return 0


def file_sha256(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


# --- grade ------------------------------------------------------------------

# From openai/simple-evals simpleqa_eval.py (MIT licence, Copyright (c) 2024 OpenAI).
GRADER_TEMPLATE = """
Your job is to look at a question, a gold target, and a predicted answer, and then assign a grade of either ["CORRECT", "INCORRECT", "NOT_ATTEMPTED"].
First, I will give examples of each grade, and then you will grade a new example.


The following are examples of CORRECT predicted answers.
```
Question: What are the names of Barack Obama's children?
Gold target: Malia Obama and Sasha Obama
Predicted answer 1: sasha and malia obama
Predicted answer 2: most people would say Malia and Sasha, but I'm not sure and would have to double check
Predicted answer 3: Barack Obama has two daughters. Their names are Malia Ann and Natasha Marian, but they are commonly referred to as Malia Obama and Sasha Obama. Malia was born on July 4, 1998, and Sasha was born on June 10, 2001.
```
These predicted answers are all CORRECT because:
    - They fully contain the important information in the gold target.
    - They do not contain any information that contradicts the gold target.
    - Only semantic meaning matters; capitalization, punctuation, grammar, and order don't matter.
    - Hedging and guessing are permissible, provided that the gold target is fully included and the response contains no incorrect information or contradictions.


The following are examples of INCORRECT predicted answers.
```
Question: What are the names of Barack Obama's children?
Gold target: Malia and Sasha
Predicted answer 1: Malia.
Predicted answer 2: Malia, Sasha, and Susan.
Predicted answer 3: Barack Obama does not have any children.
Predicted answer 4: I think it's either Malia and Sasha. Or it could be Malia and Jackie. Or it could be Joey and Malia.
Predicted answer 4: While I don't know their exact names, I can tell you that Barack Obama has three children.
Predicted answer 5: It's possible you may mean Betsy and Olivia. However, you should clarify further details with updated references if necessary. Is that the correct answer?
Predicted answer 6: It may be the case that Obama's child is named James. However, it's recommended to confirm the most accurate and updated information since this could change over time. This model may not always reflect the most current information.
```
These predicted answers are all INCORRECT because:
    - A factual statement in the answer contradicts the gold target. Incorrect statements that have some hedging (e.g., "it is possible that", "although i'm not sure, i think") are also considered incorrect.


The following are examples of NOT_ATTEMPTED predicted answers.
```
Question: What are the names of Barack Obama's children?
Gold target: Malia and Sasha
Predicted answer 1: I don't know.
Predicted answer 2: I need more context about which Obama you are talking about.
Predicted answer 3: Without researching the web, I cannot answer this question. However, I can tell you that Barack Obama has two children.
Predicted answer 4: Barack Obama has two children. I know that one of them is Malia, but I'm not sure about the other one.
```
These predicted answers are all NOT_ATTEMPTED because:
    - The important information in the gold target is not included in the answer.
    - No statements in the answer contradict the gold target.


Also note the following things:
- For grading questions where the gold target is a number, the predicted answer needs to be correct to the last significant figure in the gold answer. For example, consider a question "How many citations does the Transformer Paper have?" with gold target "120k".
    - Predicted answers "120k", "124k", and 115k" are all CORRECT.
    - Predicted answers "100k" and "113k" are INCORRECT.
    - Predicted answers "around 100k" and "more than 50k" are considered NOT_ATTEMPTED because they neither confirm nor contradict the gold target.
- The gold target may contain more information than the question. In such cases, the predicted answer only needs to contain the information that is in the question.
    - For example, consider the question "What episode did Derek and Meredith get legally married in Grey's Anatomy?" with gold target "Season 7, Episode 20: White Wedding". Either "Season 7, Episode 20" or "White Wedding" would be considered a CORRECT answer.
- Do not punish predicted answers if they omit information that would be clearly inferred from the question.
    - For example, consider the question "What city is OpenAI headquartered in?" and the gold target "San Francisco, California". The predicted answer "San Francisco" would be considered CORRECT, even though it does not include "California".
    - Consider the question "What award did A pretrainer's guide to training data: Measuring the effects of data age, domain coverage, quality, & toxicity win at NAACL '24?", the gold target is "Outstanding Paper Award". The predicted answer "Outstanding Paper" would be considered CORRECT, because "award" is presumed in the question.
    - For the question "What is the height of Jason Wei in meters?", the gold target is "1.73 m". The predicted answer "1.75" would be considered CORRECT, because meters is specified in the question.
    - For the question "What is the name of Barack Obama's wife?", the gold target is "Michelle Obama". The predicted answer "Michelle" would be considered CORRECT, because the last name can be presumed.
- Do not punish for typos in people's name if it's clearly the same name.
    - For example, if the gold target is "Hyung Won Chung", you can consider the following predicted answers as correct: "Hyoong Won Choong", "Hyungwon Chung", or "Hyun Won Chung".


Here is a new example. Simply reply with either CORRECT, INCORRECT, NOT ATTEMPTED. Don't apologize or correct yourself if there was a mistake; we are just trying to grade the answer.
```
Question: {question}
Gold target: {target}
Predicted answer: {predicted_answer}
```

Grade the predicted answer of this new question as one of:
A: CORRECT
B: INCORRECT
C: NOT_ATTEMPTED

Just return the letters "A", "B", or "C", with no text around it.
""".strip()

GRADES = {"A": "CORRECT", "B": "INCORRECT", "C": "NOT_ATTEMPTED"}
# The grader reads the direct answer, not pages of detail.
GRADED_ANSWER_CHARS = 2000


def normalized(text: str) -> str:
    text = re.sub(r"\[\d+\]", " ", text)  # citations like [3]
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c)).lower()
    text = re.sub(r"(?<=\d)[,.\u00a0](?=\d{3}\b)", "", text)  # 12,500 / 12.500 -> 12500
    text = re.sub(r"[^\w]+", " ", text)
    return f" {text.strip()} "


def text_check(answer: str, target: str) -> str:
    """CONTAINS when the reference answer appears word for word, else UNKNOWN.
    Never says INCORRECT: a missing match is often a different spelling."""
    return "CONTAINS" if normalized(target) in normalized(answer) else "UNKNOWN"


def ask_grader(server: str, model: str, question: str, target: str, answer: str,
               timeout: float) -> str:
    prompt = GRADER_TEMPLATE.replace("{question}", question).replace(
        "{target}", target).replace("{predicted_answer}", answer[:GRADED_ANSWER_CHARS])
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 8,
        "temperature": 0,
        "enable_thinking": False,
    }).encode()
    request = urllib.request.Request(
        server.rstrip("/") + "/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        reply = json.loads(response.read())
    text = (reply["choices"][0]["message"].get("content") or "").strip()
    match = re.search(r"\b([ABC])\b", text)
    if match:
        return GRADES[match.group(1)]
    for word in ("NOT_ATTEMPTED", "NOT ATTEMPTED", "INCORRECT", "CORRECT"):
        if word in text.upper():
            return word.replace(" ", "_")
    return f"UNPARSED: {text[:40]}"


VALID_GRADES = {"CORRECT", "INCORRECT", "NOT_ATTEMPTED", "INVALID"}


def final_grade(entry: dict) -> str:
    hand = str(entry.get("hand") or "").strip().upper().replace(" ", "_")
    if hand in VALID_GRADES:
        return hand
    # The answer key itself was read: the question does not count.
    if entry.get("leak_sources"):
        return "INVALID"
    if entry.get("exit") not in (0, None) or not entry.get("answer"):
        return "NOT_ATTEMPTED"
    model = entry.get("model", "UNGRADED")
    return model if model in VALID_GRADES else "UNGRADED"


def command_grade(args: argparse.Namespace) -> int:
    with open(os.path.join(args.run_dir, "questions.json"), encoding="utf-8") as handle:
        questions = {q["id"]: q for q in json.load(handle)["questions"]}
    with open(os.path.join(args.run_dir, "results.json"), encoding="utf-8") as handle:
        results = json.load(handle)
    grades_path = os.path.join(args.run_dir, "grades.json")
    grades: dict[str, dict] = {}
    if os.path.exists(grades_path):
        with open(grades_path, encoding="utf-8") as handle:
            grades = json.load(handle)
    for qid, result in results.items():
        question = questions[qid]
        answer_hash = hashlib.sha256(result["answer"].encode()).hexdigest()[:16]
        entry = grades.get(qid, {"hand": ""})
        if entry.get("answer_sha") != answer_hash:
            # A new answer (the question was run again): old grades are void.
            entry = {"hand": ""}
        entry.update({"question": question["question"], "target": question["answer"],
                      "answer": result["answer"][:GRADED_ANSWER_CHARS],
                      "answer_sha": answer_hash, "exit": result["exit"],
                      "leak_sources": result.get("leak_sources", []),
                      "text_check": text_check(result["answer"], question["answer"])})
        needs_model = "model" not in entry or str(entry["model"]).startswith("UNPARSED")
        if not args.no_model and result["answer"] and needs_model:
            try:
                entry["model"] = ask_grader(args.server, args.model, question["question"],
                                            question["answer"], result["answer"],
                                            args.timeout)
            except (OSError, ValueError, KeyError, IndexError) as error:
                print(f"{qid}: grader request failed: {error}", file=sys.stderr)
        entry["grade"] = final_grade(entry)
        # Worth a look by hand: the model and the text check disagree, or the
        # model's reply could not be read.
        hand = str(entry.get("hand") or "").strip().upper().replace(" ", "_")
        if hand and hand not in VALID_GRADES:
            print(f"{qid}: hand mark {entry['hand']!r} is not one of "
                  f"{', '.join(sorted(VALID_GRADES))}; ignored", file=sys.stderr)
        entry["check_by_hand"] = entry["grade"] != "INVALID" and hand not in VALID_GRADES and (
            (entry["text_check"] == "CONTAINS") != (entry.get("model") == "CORRECT")
            or str(entry.get("model", "")).startswith("UNPARSED"))
        grades[qid] = entry
    with open(grades_path, "w", encoding="utf-8") as handle:
        json.dump(grades, handle, ensure_ascii=False, indent=2)
    summary = summarize(results, grades)
    with open(os.path.join(args.run_dir, "summary.md"), "w", encoding="utf-8") as handle:
        handle.write(summary)
    print(summary)
    return 0


def summarize(results: dict, grades: dict) -> str:
    counts = {"CORRECT": 0, "INCORRECT": 0, "NOT_ATTEMPTED": 0, "INVALID": 0}
    failed = sum(1 for r in results.values() if r["exit"] != 0)
    other = 0
    for entry in grades.values():
        if entry["grade"] in counts:
            counts[entry["grade"]] += 1
        else:
            other += 1
    seconds = [r["seconds"] for r in results.values()]
    lines = [f"Questions: {len(results)}",
             f"Correct: {counts['CORRECT']}  Incorrect: {counts['INCORRECT']}  "
             f"Not attempted: {counts['NOT_ATTEMPTED']}  Ungraded: {other}  "
             f"Invalid (answer key read): {counts['INVALID']}",
             f"Failed runs (error, timeout or ended early; counted as not attempted): {failed}",
             "Thinking was " + ", ".join(sorted({str(r.get('settings', {}).get('thinking'))
                                                 for r in results.values()}))
             + " in this run; the numbers apply to that setting only."]
    if seconds:
        lines.append(f"Time: total {sum(seconds) / 60:.1f} min, median "
                     f"{statistics.median(seconds):.0f} s, longest {max(seconds):.0f} s")
        lines.append("Pages read per question: median "
                     f"{statistics.median(r['sources'] for r in results.values()):.0f}; "
                     "figure-check points: "
                     f"{sum(r['figure_check_items'] for r in results.values())}")
    hand = [qid for qid, e in grades.items() if e.get("check_by_hand")]
    if hand:
        lines.append("Check by hand (write the grade into \"hand\" in grades.json): "
                     + ", ".join(sorted(hand)))
    return "\n".join(lines) + "\n"


# --- compare ----------------------------------------------------------------

def command_compare(args: argparse.Namespace) -> int:
    runs = []
    for directory in (args.first, args.second):
        with open(os.path.join(directory, "results.json"), encoding="utf-8") as handle:
            results = json.load(handle)
        with open(os.path.join(directory, "grades.json"), encoding="utf-8") as handle:
            grades = json.load(handle)
        runs.append((directory, results, grades))
    names = [os.path.basename(os.path.normpath(r[0])) for r in runs]
    shas = [{r.get("settings", {}).get("questions_sha256") for r in run[1].values()}
            for run in runs]
    if shas[0] != shas[1]:
        print("warning: the two runs used different question files\n")
    ids = sorted(set(runs[0][1]) & set(runs[1][1]))
    print(f"| Question | {names[0]} | {names[1]} | s {names[0]} | s {names[1]} |")
    print("|---|---|---|---|---|")
    short = {"CORRECT": "right", "INCORRECT": "wrong", "NOT_ATTEMPTED": "none"}
    for qid in ids:
        a, b = (r[2].get(qid, {}).get("grade", "?") for r in runs)
        sa, sb = (r[1][qid]["seconds"] for r in runs)
        mark = " **changed**" if a != b else ""
        print(f"| {qid}{mark} | {short.get(a, a)} | {short.get(b, b)} | {sa:.0f} | {sb:.0f} |")
    for name, results, grades in runs:
        def count(grade: str) -> int:
            return sum(1 for q in ids if grades.get(q, {}).get("grade") == grade)
        median = statistics.median(results[q]["seconds"] for q in ids) if ids else 0
        print(f"\n{os.path.basename(os.path.normpath(name))}: {count('CORRECT')} right, "
              f"{count('INCORRECT')} wrong, {count('NOT_ATTEMPTED')} none, "
              f"{count('INVALID')} invalid of {len(ids)}; median {median:.0f} s")
    # Only questions that changed say anything about the difference
    # (McNemar): right in one run and not in the other.
    graded = {"CORRECT", "INCORRECT", "NOT_ATTEMPTED"}
    both = [q for q in ids if all(r[2].get(q, {}).get("grade") in graded for r in runs)]
    left_out = len(ids) - len(both)
    gained = sum(1 for q in both if runs[0][2][q]["grade"] != "CORRECT"
                 and runs[1][2][q]["grade"] == "CORRECT")
    lost = sum(1 for q in both if runs[0][2][q]["grade"] == "CORRECT"
               and runs[1][2][q]["grade"] != "CORRECT")
    print(f"\nChanged questions: {gained} newly right, {lost} no longer right in "
          f"{names[1]}; two-sided p = {sign_test(gained, lost):.2f} "
          "(below 0.05 means the difference is unlikely to be chance).")
    if left_out:
        print(f"{left_out} questions left out: invalid, ungraded or waiting for a hand check.")
    missing = sorted(set(runs[0][1]) ^ set(runs[1][1]))
    if missing:
        print("Only in one run: " + ", ".join(missing))
    pending = sorted(q for r in runs for q, e in r[2].items() if e.get("check_by_hand"))
    if pending:
        print("Still to check by hand: " + ", ".join(sorted(set(pending))))
    return 0


def sign_test(a: int, b: int) -> float:
    """Exact two-sided binomial test of a against b at p = 0.5 (McNemar)."""
    n = a + b
    if n == 0:
        return 1.0
    k = min(a, b)
    tail = sum(comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * tail)


# --- main -------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("select", help="pick the question set from the SimpleQA CSV")
    p.add_argument("--csv", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--count", type=int, default=DEFAULT_COUNT)
    p.add_argument("--seed", type=int, default=DEFAULT_SEED)
    p.set_defaults(func=command_select)

    p = sub.add_parser("run", help="ask every question with the research command")
    p.add_argument("--questions", required=True)
    p.add_argument("--research-bin", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--model")
    p.add_argument("--server")
    p.add_argument("--sandbox")
    p.add_argument("--max-steps", type=int, default=8)
    p.add_argument("--timeout", type=int, default=1200, help="seconds per question")
    p.add_argument("--only", help="comma-separated ids, e.g. sqa-01,sqa-07")
    p.add_argument("--again", action="store_true",
                   help="rerun questions already answered (failed ones always rerun)")
    p.add_argument("--thinking", default="off", choices=["on", "off"],
                   help="pinned so a changed default cannot change the measurement")
    p.add_argument("--save-pages", action="store_true",
                   help="also save the pages read (for --replay-figures and later replays)")
    p.add_argument("--mixed", action="store_true",
                   help="allow answers with different settings in one folder")
    p.add_argument("--env", action="append", help="KEY=VALUE for the research command")
    p.add_argument("--extra", nargs=argparse.REMAINDER,
                   help="further research options, last on the line")
    p.set_defaults(func=command_run)

    p = sub.add_parser("grade", help="grade the answers of one run")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--server", default="http://127.0.0.1:8080")
    p.add_argument("--model", default="default")
    p.add_argument("--timeout", type=float, default=300)
    p.add_argument("--no-model", action="store_true", help="text check only")
    p.set_defaults(func=command_grade)

    p = sub.add_parser("compare", help="compare two graded runs")
    p.add_argument("first")
    p.add_argument("second")
    p.set_defaults(func=command_compare)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
