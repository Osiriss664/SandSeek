#!/usr/bin/env python3
"""Tests for Scripts/full_test.sh, with stub programs, on any platform.

  python3 Scripts/test_full_test.py

The script is copied into a fake checkout together with stub swift, container,
codesign, curl and sandbox scripts, so nothing real is built or started.
"""

import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SECRET = "5ec12e7" * 9 + "abcd"  # 67 characters, not hex
HEX_SECRET = "ab" * 32
KEY = "sk-test-key-98765"


def write(path, text, mode=0o755):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(textwrap.dedent(text))
    os.chmod(path, mode)


class Fixture:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="fulltest-")
        self.repo = os.path.join(self.root, "repo")
        self.bin = os.path.join(self.root, "bin")
        self.home = os.path.join(self.root, "home")
        self.secret_folder = os.path.join(self.home, "sandbox")
        self.log = os.path.join(self.root, "calls.log")
        os.makedirs(self.home)
        for name in ("full_test.sh", "full_test_helpers.py"):
            dest = os.path.join(self.repo, "Scripts", name)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copy(os.path.join(HERE, name), dest)
        self.make_stubs()

    def make_stubs(self):
        r, b = self.repo, self.bin
        write(f"{b}/swift", """\
            #!/bin/bash
            echo "swift $1" >> "$FAKE_LOG"
            echo "stdin: $(cat | wc -c | tr -d ' ')"
            if [ "$FAKE_FAIL" = "swift-$1" ]; then
              for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do echo "noise $i"; done
              echo "FAKE FAILURE LINE"; exit 1
            fi
            [ "$1" = test ] && echo "Executed 7 tests, with 0 failures (0 unexpected)"
            exit 0
            """)
        write(f"{b}/container", """\
            #!/bin/bash
            echo "container $*" >> "$FAKE_LOG"
            case "$1 $2" in
              "image list") [ "$FAKE_IMAGE" = 1 ] && echo "sandseek-sandbox latest" ;;
              "image inspect") [ -n "$FAKE_IMAGE_CREATED" ] && printf '[{"name":"sandseek-sandbox","created":"%s"}]\\n' "$FAKE_IMAGE_CREATED" ;;
              "builder status") [ "$FAKE_BUILDER" = running ] && echo "buildkit" ;;
              "list --all") [ "$FAKE_EXISTING" = 1 ] && echo "sandseek-sandbox" ;;
            esac
            exit 0
            """)
        write(f"{b}/codesign", "#!/bin/bash\necho codesign >> \"$FAKE_LOG\"\n")
        write(f"{b}/curl", "#!/bin/bash\necho 401\n")
        write(f"{r}/Scripts/research_sandbox.sh", f"""\
            #!/bin/bash
            echo "sandbox $1" >> "$FAKE_LOG"
            case "$1" in
              build) echo built ;;
              start)
                mkdir -p "$FT_SECRET_FOLDER"
                # Another SandSeek's lock (a file the test makes) refuses a
                # start with exit code 75, as the real script does.
                [ -e "$FT_SECRET_FOLDER/lock-held" ] && {{ echo "Another SandSeek is using the web sandbox."; exit 75; }}
                [ "$FAKE_FAIL" = busy ] && {{ echo "Another SandSeek is using the web sandbox."; exit 75; }}
                printf '%s' "{SECRET}" > "$FT_SECRET_FOLDER/secret"
                echo "secret={SECRET} also {HEX_SECRET}"
                # Like the real script, a failed start removes its own secret.
                [ "$FAKE_FAIL" = start ] && {{ rm -f "$FT_SECRET_FOLDER/secret"; echo "start failed"; exit 1; }}
                echo ready ;;
              stop) [ "$FAKE_SLEEP" = stop ] && sleep 8
                    rm -f "$FT_SECRET_FOLDER/secret" "$FT_SECRET_FOLDER/lock-held"; echo stopped ;;
              status) echo answers ;;
              selftest)
                echo "  ok    one"; echo "  ok    two"
                [ "$FAKE_FAIL" = selftest-fail ] && echo "  FAIL  three"
                if [ "$FAKE_SLEEP" = selftest ]; then touch "$FAKE_LOG.sleeping"; sleep 60; fi ;;
            esac
            exit 0
            """)
        write(f"{r}/Scripts/package_app.sh", """\
            #!/bin/bash
            echo "package" >> "$FAKE_LOG"
            mkdir -p build/SandSeek.app/Contents/Resources
            : > build/SandSeek.app/Contents/Resources/AppIcon.icns
            python3 - <<'PY'
            import plistlib
            with open("build/SandSeek.app/Contents/Info.plist", "wb") as h:
                plistlib.dump({"CFBundleIconFile": "AppIcon"}, h)
            PY
            """)
        write(f"{r}/Scripts/verify_sandbox_signature.py",
              "import sys\nprint('matches: True')\n", 0o644)
        write(f"{r}/Scripts/research_address_check.py", """\
            import os, sys
            print("all refused")
            sys.exit(1 if os.environ.get("FAKE_FAIL") == "address" else 0)
            """, 0o644)
        write(f"{r}/Scripts/test_research_sandbox.py", """\
            import unittest
            class T(unittest.TestCase):
                def test_a(self): pass
            unittest.main()
            """, 0o644)
        write(f"{r}/Sandbox/test_server.py", """\
            import unittest
            class T(unittest.TestCase):
                def test_a(self): pass
                def test_b(self): pass
            """, 0o644)
        # Stand-ins for the safety scripts (--safety); the real ones are tested in
        # test_safety_probe.py.
        write(f"{r}/Scripts/safety_probe.sh", f"""\
            #!/bin/bash
            echo "safety_probe args=$* skipscan=$SKIP_PORT_SCAN folder=$SAFETY_SECRET_FOLDER" >> "$FAKE_LOG"
            echo "  PASS  stub check one"
            echo "  NOTE  stub note secret={SECRET}"
            [ "$FAKE_FAIL" = probe ] && echo "  FAIL  stub failure"
            echo "Result: 1 pass, $([ "$FAKE_FAIL" = probe ] && echo 1 || echo 0) fail"
            [ "$FAKE_FAIL" != probe ]
            """)
        write(f"{r}/Scripts/safety_lifecycle.sh", """\
            #!/bin/bash
            echo "safety_lifecycle args=$*" >> "$FAKE_LOG"
            echo "  PASS  stub lifecycle check"
            echo "Result: 1 pass, 0 fail"
            """)
        write(f"{r}/Scripts/other.sh", "#!/bin/bash\ntrue\n")
        write(f"{r}/sandseek-stub", f"""\
            #!/bin/bash
            echo "sandseek $*" >> "$FAKE_LOG"
            echo "using key {KEY} and secret {SECRET}" >&2
            if [ "$FAKE_NOT_INSTALLED" = 1 ]; then
              echo "error: the model server refused the request (HTTP 404): Gemma is not installed." >&2
              exit 1
            fi
            case "$1" in
              *Iceland*) if [ "$FAKE_ANSWER" = iceland-only ]; then echo "Iceland has 380000 people."
                         else echo "Iceland and Ireland compared."; fi ;;
              *) echo "Canberra is the capital of Australia." ;;
            esac
            echo
            echo "1. https://example.org/canberra"
            """)
        # A model server stub as a script, started by --start-server.
        # It says when it started and when it listens, so a failure shows
        # how far it got (its output goes to the run's logs/6.0.log).
        write(f"{r}/server/TUFFServer", f"""\
            #!{sys.executable}
            import sys
            print("stub started", flush=True)
            from http.server import BaseHTTPRequestHandler, HTTPServer
            port = int(sys.argv[sys.argv.index("--port") + 1])
            class H(BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200); self.end_headers(); self.wfile.write(b"{{}}")
                def log_message(self, *a): pass
            server = HTTPServer(("127.0.0.1", port), H)
            print("stub listening on", port, flush=True)
            server.serve_forever()
            """)

    def env(self, **extra):
        env = {
            "PATH": self.bin + os.pathsep + os.environ["PATH"],
            "HOME": self.home,
            "SANDSEEK_FULL_TEST_FAKE": "1",
            "FT_CONTAINER": f"{self.bin}/container",
            "FT_SECRET_FOLDER": self.secret_folder,
            "FT_SANDSEEK_BIN": f"{self.repo}/sandseek-stub",
            "FAKE_LOG": self.log,
            "FAKE_FAIL": "",
            "FAKE_NOT_INSTALLED": "",
            "SANDSEEK_FULL_TEST_MODEL": "",
            "SANDSEEK_SANDBOX_PORT": "49321",
            "SANDSEEK_MODEL_SERVER": "http://127.0.0.1:1",
            # Nothing that runs on the test machine may count: the address
            # where the script looks for Ollama is a port nobody listens on.
            "FT_OLLAMA_URL": "http://127.0.0.1:1",
            # Generous: a stub's first start on a CI runner can be slow.
            "FT_SERVER_WAIT": "90",
        }
        env.update(extra)
        return env

    def run(self, *args, stdin=None, timeout=120, **extra):
        process = subprocess.run(
            ["bash", f"{self.repo}/Scripts/full_test.sh", *args], env=self.env(**extra),
            input=stdin, capture_output=True, text=True, timeout=timeout)
        return process

    def calls(self):
        try:
            with open(self.log) as handle:
                return handle.read()
        except OSError:
            return ""

    def report_dir(self, process):
        for line in process.stdout.splitlines()[::-1]:
            if line.startswith("FULL_TEST_REPORT="):
                return os.path.dirname(line.split("=", 1)[1])
        raise AssertionError("no FULL_TEST_REPORT line:\n" + process.stdout)

    def results(self, process):
        directory = self.report_dir(process)
        with open(os.path.join(directory, "report.json")) as handle:
            data = json.load(handle)
        return data, {step["id"]: step for step in data["steps"]}, directory

    def server_log(self, process):
        """stdout plus the started server's own log, for failure messages."""
        path = os.path.join(self.report_dir(process), "logs", "6.0.log")
        try:
            with open(path) as handle:
                return f"{process.stdout}\n--- {path} ---\n{handle.read()}"
        except OSError as error:
            return f"{process.stdout}\n--- no server log: {error} ---"

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


class QuietHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


class ModelListHandler(BaseHTTPRequestHandler):
    """A server whose /v1/models names a default that it does not list."""
    listing = {"object": "list", "default": "gemma4",
               "data": [{"id": "qwen36"}, {"id": "ornith-9b"}]}

    def do_GET(self):
        body = json.dumps(self.listing).encode() if self.path == "/v1/models" else b"{}"
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class OllamaHandler(BaseHTTPRequestHandler):
    """A server that answers like Ollama: /api/version, and /api/ps with the
    models in `loaded` (none by default)."""
    loaded = []

    def do_GET(self):
        bodies = {"/api/version": {"version": "0.0.0"}, "/api/ps": {"models": self.loaded}}
        ok = self.path in bodies
        self.send_response(200 if ok else 404)
        self.end_headers()
        self.wfile.write(json.dumps(bodies.get(self.path, {})).encode())

    def log_message(self, *args):
        pass


class FullTestCase(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()
        self.addCleanup(self.fx.close)

    def everything_text(self, directory):
        found = ""
        for folder, _, names in os.walk(directory):
            for name in names:
                with open(os.path.join(folder, name), errors="replace") as handle:
                    found += handle.read()
        return found


class PassingRun(FullTestCase):
    def test_script_is_valid_bash(self):
        for name in ("full_test.sh",):
            subprocess.run(["bash", "-n", os.path.join(HERE, name)], check=True)

    def test_all_pass_and_report_files(self):
        process = self.fx.run()
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        data, steps, directory = self.fx.results(process)
        self.assertEqual(data["overall"], "PASS")
        self.assertTrue(process.stdout.rstrip().splitlines()[-1].startswith("FULL_TEST_REPORT="))
        with open(os.path.join(directory, "report.md")) as handle:
            markdown = handle.read()
        self.assertIn("| Step | Result | Time | Note |", markdown)
        self.assertIn("Still manual", markdown)
        self.assertIn("Print and Export as PDF", markdown)
        for step_id in ("1", "2.1", "2.2", "3.1", "3.2", "3.3", "4.1", "4.2", "4.3",
                        "5.2", "5.4", "5.5", "5.6", "5.7", "8"):
            self.assertEqual(steps[step_id]["result"], "PASS", step_id)
        self.assertIn("7 tests", steps["2.2"]["note"])
        self.assertIn("2 checks", steps["5.4"]["note"])
        # No model server answers: question and injection check are skipped.
        for step_id in ("6.1", "7"):
            self.assertEqual(steps[step_id]["result"], "SKIP", step_id)
        self.assertIn("no model server", steps["6.1"]["note"])
        self.assertEqual(data["steps"][-1]["id"], "8")

    def test_children_get_no_standard_input(self):
        process = self.fx.run(stdin="HELLO-FROM-PARENT\n")
        directory = self.fx.report_dir(process)
        text = self.everything_text(directory)
        self.assertIn("stdin: 0", text)
        self.assertNotIn("HELLO-FROM-PARENT", text)

    def test_secrets_are_masked_everywhere(self):
        key_file = os.path.join(self.fx.root, "key")
        with open(key_file, "w") as handle:
            handle.write(KEY)
        server = HTTPServer(("127.0.0.1", 0), QuietHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        process = self.fx.run("--server", f"http://127.0.0.1:{server.server_port}",
                              "--api-key-file", key_file)
        directory = self.fx.report_dir(process)
        text = process.stdout + process.stderr + self.everything_text(directory)
        for secret in (SECRET, HEX_SECRET, KEY):
            self.assertNotIn(secret, text)
        self.assertIn("***", text)

    def test_cleanup_runs_at_the_end(self):
        process = self.fx.run()
        calls = self.fx.calls()
        self.assertIn("sandbox stop", calls)
        self.assertFalse(os.path.exists(os.path.join(self.fx.secret_folder, "secret")))
        self.assertEqual(process.returncode, 0)


class Failures(FullTestCase):
    def test_failing_step_gives_exit_1_log_tail_and_cleanup(self):
        process = self.fx.run(FAKE_FAIL="swift-test")
        self.assertEqual(process.returncode, 1)
        data, steps, directory = self.fx.results(process)
        self.assertEqual(data["overall"], "FAIL")
        self.assertEqual(steps["2.2"]["result"], "FAIL")
        self.assertIn("FAKE FAILURE LINE", steps["2.2"]["log_tail"])
        self.assertLessEqual(len(steps["2.2"]["log_tail"].splitlines()), 15)
        with open(os.path.join(directory, "report.md")) as handle:
            markdown = handle.read()
        self.assertIn("## Failures", markdown)
        self.assertIn("FAKE FAILURE LINE", markdown)
        self.assertIn("sandbox stop", self.fx.calls())  # the later steps still ran

    def test_failed_start_skips_checks_and_leaves_nothing_behind(self):
        # A start that failed cleaned up after itself, so there is nothing of
        # ours to stop (and a sandbox that runs now is not ours).
        process = self.fx.run(FAKE_FAIL="start")
        self.assertEqual(process.returncode, 1)
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["5.2"]["result"], "FAIL")
        for step_id in ("5.3", "5.4", "5.5", "5.6", "5.7"):
            self.assertEqual(steps[step_id]["result"], "SKIP")
        self.assertNotIn("sandbox stop", self.fx.calls())
        self.assertFalse(os.path.exists(os.path.join(self.fx.secret_folder, "secret")))
        self.assertNotEqual(steps["8"]["result"], "FAIL")

    def test_a_busy_start_does_not_stop_the_other_sandseeks_sandbox(self):
        # Exit code 75: another SandSeek holds the lock (the app, started
        # after the run's check). The run fails, and its cleanup must not stop
        # that sandbox.
        os.makedirs(self.fx.secret_folder, exist_ok=True)
        lock = os.path.join(self.fx.secret_folder, "lock-held")
        with open(lock, "w") as handle:
            handle.write("held")
        process = self.fx.run()
        self.assertEqual(process.returncode, 1)
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["5.2"]["result"], "FAIL")
        self.assertIn("exit code 75", steps["5.2"]["note"])
        self.assertIn("sandbox start", self.fx.calls())
        self.assertNotIn("sandbox stop", self.fx.calls())
        self.assertTrue(os.path.exists(lock))
        self.assertNotEqual(steps["8"]["result"], "FAIL")

    def test_selftest_fail_line_fails_the_step(self):
        process = self.fx.run(FAKE_FAIL="selftest-fail")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["5.4"]["result"], "FAIL")
        self.assertEqual(process.returncode, 1)

    def test_leftover_secret_fails_the_cleanup_check(self):
        # A stop that leaves the secret behind must be reported.
        write(f"{self.fx.repo}/Scripts/research_sandbox.sh", """\
            #!/bin/bash
            echo "sandbox $1" >> "$FAKE_LOG"
            mkdir -p "$FT_SECRET_FOLDER"; : > "$FT_SECRET_FOLDER/secret"
            exit 0
            """)
        process = self.fx.run()
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["8"]["result"], "FAIL")
        self.assertIn("secret", steps["8"]["note"])
        self.assertEqual(process.returncode, 1)

    def test_sigint_cleans_up(self):
        process = subprocess.Popen(
            ["bash", f"{self.fx.repo}/Scripts/full_test.sh"], env=self.fx.env(FAKE_SLEEP="selftest"),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.time() + 60
        while not os.path.exists(self.fx.log + ".sleeping") and time.time() < deadline:
            time.sleep(0.1)
        self.assertTrue(os.path.exists(self.fx.log + ".sleeping"))
        process.send_signal(signal.SIGINT)
        out, _ = process.communicate(timeout=60)
        self.assertEqual(process.returncode, 130)
        self.assertIn("sandbox stop", self.fx.calls())
        self.assertFalse(os.path.exists(os.path.join(self.fx.secret_folder, "secret")))
        directory = os.path.dirname(out.strip().splitlines()[-1].split("=", 1)[1])
        with open(os.path.join(directory, "report.json")) as handle:
            data = json.load(handle)
        self.assertEqual(data["overall"], "FAIL")
        self.assertEqual(data["reason"], "interrupted")
        self.assertTrue(any(step["id"] == "5.4" and step["result"] == "FAIL" for step in data["steps"]))

    def test_whole_run_time_limit(self):
        started = time.time()
        process = self.fx.run(FAKE_SLEEP="selftest", FULL_TEST_TIME_LIMIT_SECONDS="4")
        self.assertLess(time.time() - started, 40)
        self.assertEqual(process.returncode, 124)
        data, _, _ = self.fx.results(process)
        self.assertEqual(data["overall"], "FAIL")
        self.assertIn("time limit", data["reason"])
        self.assertIn("sandbox stop", self.fx.calls())
        self.assertFalse(os.path.exists(os.path.join(self.fx.secret_folder, "secret")))

    def test_step_time_limit(self):
        # The helper kills a step that runs too long.
        log = os.path.join(self.fx.root, "slow.log")
        process = subprocess.run(
            [sys.executable, f"{self.fx.repo}/Scripts/full_test_helpers.py", "run", log, "1",
             "bash", "-c", "echo before; sleep 30"], capture_output=True, text=True, timeout=30)
        self.assertEqual(process.returncode, 124)
        with open(log) as handle:
            self.assertIn("before", handle.read())


class Flags(FullTestCase):
    def test_no_sandbox_skips_package_and_sandbox(self):
        process = self.fx.run("--no-sandbox")
        self.assertEqual(process.returncode, 0, process.stdout)
        _, steps, _ = self.fx.results(process)
        for step_id in ("4", "5", "6", "7", "8"):
            self.assertEqual(steps[step_id]["result"], "SKIP", step_id)
        self.assertEqual(steps["2.2"]["result"], "PASS")
        calls = self.fx.calls()
        self.assertNotIn("package", calls)
        self.assertNotIn("sandbox", calls)

    def test_quick_skips_package_and_image_build_when_present(self):
        os.makedirs(f"{self.fx.repo}/build/SandSeek.app/Contents/Resources")
        import plistlib
        with open(f"{self.fx.repo}/build/SandSeek.app/Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleIconFile": "AppIcon"}, handle)
        open(f"{self.fx.repo}/build/SandSeek.app/Contents/Resources/AppIcon.icns", "w").close()
        process = self.fx.run("--quick", FAKE_IMAGE="1")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["4.1"]["result"], "SKIP")
        self.assertEqual(steps["5.1"]["result"], "SKIP")
        self.assertEqual(steps["4.3"]["result"], "PASS")
        calls = self.fx.calls()
        self.assertNotIn("package", calls)
        self.assertNotIn("sandbox build", calls)

    def test_quick_still_builds_when_missing(self):
        process = self.fx.run("--quick")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["4.1"]["result"], "PASS")
        self.assertEqual(steps["5.1"]["result"], "PASS")
        self.assertIn("sandbox build", self.fx.calls())

    def test_unknown_flag_is_refused(self):
        self.assertEqual(self.fx.run("--bogus").returncode, 2)


class ModelServer(FullTestCase):
    def serve(self):
        server = HTTPServer(("127.0.0.1", 0), QuietHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}"

    def test_question_runs_when_a_server_answers(self):
        process = self.fx.run("--server", self.serve())
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.1"]["result"], "PASS", process.stdout)
        self.assertNotIn("6.2", steps)
        calls = self.fx.calls().replace("\n", " ")
        self.assertIn("sandseek What is the capital", calls)
        self.assertNotIn("--max-steps", calls)  # Quick = the CLI defaults
        self.assertNotIn("--min-pages", calls)
        self.assertEqual(steps["7"]["result"], "SKIP")

    def serve_models(self, listing=None):
        handler = type("H", (ModelListHandler,), {"listing": listing or ModelListHandler.listing})
        server = HTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}"

    def test_model_flag_is_passed_to_the_cli_and_shown_in_the_report(self):
        process = self.fx.run("--server", self.serve_models(), "--model", "qwen36")
        report, steps, directory = self.fx.results(process)
        self.assertEqual(steps["6.1"]["result"], "PASS", process.stdout)
        self.assertIn("--model qwen36", self.fx.calls().replace("\n", " "))
        self.assertEqual(report["model"], "qwen36")
        with open(os.path.join(directory, "report.md")) as handle:
            self.assertIn("Model: qwen36", handle.read())

    def test_model_comes_from_the_environment_too(self):
        process = self.fx.run("--server", self.serve_models(), SANDSEEK_FULL_TEST_MODEL="ornith-9b")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.1"]["result"], "PASS", process.stdout)
        self.assertIn("--model ornith-9b", self.fx.calls().replace("\n", " "))

    def test_no_model_means_none_is_passed_and_the_report_says_default(self):
        process = self.fx.run("--server", self.serve())
        report, _, _ = self.fx.results(process)
        self.assertNotIn("--model", self.fx.calls())
        self.assertEqual(report["model"], "(server default)")

    def test_a_default_that_is_not_listed_fails_with_a_note_to_pass_a_model(self):
        process = self.fx.run("--server", self.serve_models(), "--thorough")
        _, steps, _ = self.fx.results(process)
        for step_id in ("6.1", "6.2"):
            self.assertEqual(steps[step_id]["result"], "FAIL", process.stdout)
            self.assertIn("gemma4", steps[step_id]["note"])
            self.assertIn("--model", steps[step_id]["note"])
        self.assertNotIn("sandseek What", self.fx.calls())  # the question was not asked

    def test_a_listed_default_is_fine(self):
        listing = {"default": "qwen36", "data": [{"id": "qwen36"}]}
        process = self.fx.run("--server", self.serve_models(listing))
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.1"]["result"], "PASS", process.stdout)

    def test_an_explicit_model_skips_the_default_check(self):
        process = self.fx.run("--server", self.serve_models(), "--model", "qwen36")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.1"]["result"], "PASS")

    def test_not_installed_fails_with_a_note_to_pass_a_model(self):
        process = self.fx.run("--server", self.serve(), FAKE_NOT_INSTALLED="1")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.1"]["result"], "FAIL", process.stdout)
        self.assertIn("is not installed", steps["6.1"]["note"])
        self.assertIn("--model", steps["6.1"]["note"])

    def test_a_model_name_that_looks_like_an_option_is_refused(self):
        process = self.fx.run("--model", "--thorough")
        self.assertEqual(process.returncode, 2)

    def test_thorough_adds_a_question(self):
        process = self.fx.run("--server", self.serve(), "--thorough")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.1"]["result"], "PASS")
        self.assertEqual(steps["6.2"]["result"], "PASS", process.stdout)
        self.assertIn("--max-steps 30 --min-pages 6 --search-results 8",
                      self.fx.calls().replace("\n", " "))
        # and without --thorough there is no 6.2 at all (see the test above)

    def test_thorough_needs_both_countries(self):
        process = self.fx.run("--server", self.serve(), "--thorough", FAKE_ANSWER="iceland-only")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.2"]["result"], "FAIL")
        self.assertIn("Ireland", steps["6.2"]["note"])

    def test_answer_without_source_fails(self):
        write(f"{self.fx.repo}/sandseek-stub", "#!/bin/bash\necho 'Canberra'\n")
        process = self.fx.run("--server", self.serve())
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.1"]["result"], "FAIL")
        self.assertIn("numbered source", steps["6.1"]["note"])

    def test_start_server_starts_uses_and_stops_it(self):
        process = self.fx.run("--start-server", f"{self.fx.repo}/server/TUFFServer")
        self.assertEqual(process.returncode, 0, self.fx.server_log(process) + process.stderr)
        _, steps, directory = self.fx.results(process)
        self.assertEqual(steps["6.0"]["result"], "PASS")
        self.assertEqual(steps["6.1"]["result"], "PASS")
        note = steps["6.0"]["note"]
        port = note.split("port ")[1].split(" ")[0]
        pid = int(note.split("pid ")[1].rstrip(")"))
        self.assertIn(f"http://127.0.0.1:{port}", self.fx.calls())
        time.sleep(0.5)
        with self.assertRaises(OSError):
            os.kill(pid, 0)  # stopped by the cleanup

    def test_started_server_is_stopped_on_failure(self):
        process = self.fx.run("--start-server", f"{self.fx.repo}/server/TUFFServer",
                              FAKE_FAIL="selftest-fail")
        _, steps, _ = self.fx.results(process)
        self.assertIn("pid ", steps["6.0"]["note"], self.fx.server_log(process))
        pid = int(steps["6.0"]["note"].split("pid ")[1].rstrip(")"))
        time.sleep(0.5)
        with self.assertRaises(OSError):
            os.kill(pid, 0)
        self.assertEqual(process.returncode, 1)

    def test_start_server_with_bad_path_fails(self):
        process = self.fx.run("--start-server", "/nonexistent/TUFFServer")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.0"]["result"], "FAIL")
        self.assertEqual(process.returncode, 1)

    def test_start_server_refused_when_a_server_answers(self):
        process = self.fx.run("--start-server", f"{self.fx.repo}/server/TUFFServer",
                              "--server", self.serve())
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.0"]["result"], "FAIL")
        self.assertIn("already answers", steps["6.0"]["note"])
        self.assertEqual(steps["6.1"]["result"], "SKIP")
        self.assertEqual(process.returncode, 1)

    def test_start_server_refused_when_a_server_process_runs(self):
        write(f"{self.fx.bin}/fakepgrep", "#!/bin/bash\n[ \"$2\" = TUFFServer ] && { echo 4242; exit 0; }\nexit 1\n")
        process = self.fx.run("--start-server", f"{self.fx.repo}/server/TUFFServer",
                              FT_PGREP=f"{self.fx.bin}/fakepgrep")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.0"]["result"], "FAIL")
        self.assertIn("TUFFServer process", steps["6.0"]["note"])

    def test_ready_needs_status_200(self):
        write(f"{self.fx.repo}/server/TUFFServer", f"""\
            #!{sys.executable}
            import sys
            from http.server import BaseHTTPRequestHandler, HTTPServer
            port = int(sys.argv[sys.argv.index("--port") + 1])
            class H(BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(503); self.end_headers()
                def log_message(self, *a): pass
            HTTPServer(("127.0.0.1", port), H).serve_forever()
            """)
        process = self.fx.run("--start-server", f"{self.fx.repo}/server/TUFFServer",
                              FT_SERVER_WAIT="3")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.0"]["result"], "FAIL")
        self.assertIn("no answer", steps["6.0"]["note"])


class OllamaServer(FullTestCase):
    def serve_ollama(self, loaded=()):
        handler = type("H", (OllamaHandler,), {"loaded": list(loaded)})
        server = HTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}"

    def test_server_type_and_model_are_passed_to_the_cli(self):
        process = self.fx.run("--server", self.serve_ollama(), "--server-type", "ollama",
                              "--model", "qwen3:8b")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.1"]["result"], "PASS", process.stdout)
        calls = self.fx.calls().replace("\n", " ")
        self.assertIn("--server-type ollama", calls)
        self.assertIn("--model qwen3:8b", calls)

    def test_no_server_type_means_none_is_passed(self):
        self.fx.run("--server", self.serve_ollama())
        self.assertNotIn("--server-type", self.fx.calls())

    def test_other_server_types_are_passed(self):
        for kind in ("tuff", "llamacpp", "auto"):
            with self.subTest(kind=kind):
                self.fx.run("--server", self.serve_ollama(), "--server-type", kind)
                self.assertIn(f"--server-type {kind}", self.fx.calls().replace("\n", " "))

    def test_ollama_default_address_is_the_ollama_address(self):
        process = self.fx.run("--server-type", "ollama", "--model", "qwen3:8b",
                              SANDSEEK_MODEL_SERVER="", FT_OLLAMA_URL="http://127.0.0.1:2")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.1"]["result"], "SKIP")
        self.assertIn("http://127.0.0.1:2", steps["6.1"]["note"])

    def test_the_built_in_ollama_address_is_port_11434(self):
        with open(os.path.join(os.path.dirname(__file__), "full_test.sh")) as handle:
            self.assertIn("${FT_OLLAMA_URL:-http://127.0.0.1:11434}", handle.read())

    def test_a_running_ollama_with_no_loaded_model_does_not_block_start_server(self):
        process = self.fx.run("--start-server", f"{self.fx.repo}/server/TUFFServer",
                              FT_OLLAMA_URL=self.serve_ollama())
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.0"]["result"], "PASS", self.fx.server_log(process))

    def test_an_ollama_with_a_loaded_model_blocks_start_server(self):
        process = self.fx.run("--start-server", f"{self.fx.repo}/server/TUFFServer",
                              FT_OLLAMA_URL=self.serve_ollama(loaded=[{"name": "qwen3:8b"}]))
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.0"]["result"], "FAIL")
        self.assertIn("already answers", steps["6.0"]["note"])
        self.assertIn("loaded", steps["6.0"]["note"])

    def test_a_key_file_from_the_environment_is_ignored_with_a_note(self):
        key = os.path.join(self.fx.root, "key")
        write(key, "secret-key\n")
        process = self.fx.run("--server", self.serve_ollama(), "--server-type", "ollama",
                              "--model", "qwen3:8b", SANDSEEK_API_KEY_FILE=key)
        report, steps, directory = self.fx.results(process)
        self.assertEqual(steps["6.1"]["result"], "PASS", process.stdout)
        self.assertNotIn("--api-key-file", self.fx.calls())
        self.assertTrue(any("SANDSEEK_API_KEY_FILE is ignored" in n for n in report["notes"]))
        with open(os.path.join(directory, "report.md")) as handle:
            self.assertIn("SANDSEEK_API_KEY_FILE is ignored", handle.read())

    def test_an_explicit_server_wins_over_the_ollama_default(self):
        process = self.fx.run("--server-type", "ollama", "--model", "qwen3:8b",
                              "--server", "http://127.0.0.1:9")
        _, steps, _ = self.fx.results(process)
        self.assertIn("http://127.0.0.1:9", steps["6.1"]["note"])

    def test_an_ollama_server_is_not_started_over(self):
        process = self.fx.run("--start-server", f"{self.fx.repo}/server/TUFFServer",
                              "--server", self.serve_ollama())
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["6.0"]["result"], "FAIL")
        self.assertIn("already answers", steps["6.0"]["note"])


class Takeover(FullTestCase):
    def secret_exists(self):
        os.makedirs(self.fx.secret_folder, exist_ok=True)
        with open(os.path.join(self.fx.secret_folder, "secret"), "w") as handle:
            handle.write("x" * 20)

    def test_existing_secret_refuses_and_leaves_it_alone(self):
        self.secret_exists()
        process = self.fx.run()
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["5.0"]["result"], "FAIL")
        self.assertIn("Stop everything in SandSeek", steps["5.0"]["note"])
        self.assertIn("--take-over-sandbox", steps["5.0"]["note"])
        for step_id in ("5.2", "5.4"):
            self.assertEqual(steps[step_id]["result"], "SKIP")
        self.assertEqual(steps["8"]["result"], "SKIP")
        self.assertNotIn("sandbox stop", self.fx.calls())
        self.assertTrue(os.path.exists(os.path.join(self.fx.secret_folder, "secret")))
        self.assertEqual(process.returncode, 1)

    def test_listener_on_port_refuses(self):
        server = HTTPServer(("127.0.0.1", 0), QuietHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        process = self.fx.run(SANDSEEK_SANDBOX_PORT=str(server.server_port))
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["5.0"]["result"], "FAIL")
        self.assertNotIn("sandbox start", self.fx.calls())

    def test_existing_container_refuses(self):
        process = self.fx.run(FAKE_EXISTING="1")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["5.0"]["result"], "FAIL")
        self.assertNotIn("sandbox start", self.fx.calls())
        self.assertNotIn("sandbox stop", self.fx.calls())

    def test_take_over_flag_allows_it(self):
        self.secret_exists()
        process = self.fx.run("--take-over-sandbox")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["5.2"]["result"], "PASS")
        self.assertEqual(steps["8"]["result"], "PASS")
        self.assertEqual(process.returncode, 0, process.stdout)

    def test_take_over_stops_the_running_sandbox_before_the_start(self):
        # The running sandbox holds the lock, so a start alone would exit 75.
        self.secret_exists()
        lock = os.path.join(self.fx.secret_folder, "lock-held")
        with open(lock, "w") as handle:
            handle.write("held")
        process = self.fx.run("--take-over-sandbox")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["5.2"]["result"], "PASS", process.stdout)
        calls = self.fx.calls().splitlines()
        stops = [i for i, line in enumerate(calls) if line == "sandbox stop"]
        starts = [i for i, line in enumerate(calls) if line == "sandbox start"]
        self.assertEqual(len(starts), 1)
        self.assertEqual(len(stops), 2)  # before the start, and the cleanup
        self.assertLess(stops[0], starts[0])
        self.assertLess(starts[0], stops[1])
        self.assertFalse(os.path.exists(lock))
        self.assertEqual(steps["8"]["result"], "PASS")
        self.assertEqual(process.returncode, 0, process.stdout)

    def test_without_the_flag_nothing_is_stopped_before_the_start(self):
        process = self.fx.run()
        calls = self.fx.calls().splitlines()
        self.assertEqual(calls.count("sandbox stop"), 1)  # the cleanup only
        self.assertLess(calls.index("sandbox start"), calls.index("sandbox stop"))
        self.assertEqual(process.returncode, 0, process.stdout)


class Builder(FullTestCase):
    def test_idle_builder_is_stopped_even_if_build_is_cut_off(self):
        process = self.fx.run()
        self.assertIn("container builder stop", self.fx.calls())
        self.assertEqual(process.returncode, 0)

    def test_running_builder_is_left_alone(self):
        self.fx.run(FAKE_BUILDER="running")
        self.assertNotIn("container builder stop", self.fx.calls())

    def test_quick_image_exists_does_not_touch_builder(self):
        self.fx.run("--quick", FAKE_IMAGE="1")
        self.assertNotIn("container builder stop", self.fx.calls())

    def test_quick_notes_stale_image(self):
        process = self.fx.run("--quick", FAKE_IMAGE="1", FAKE_IMAGE_CREATED="2000-01-01T00:00:00Z")
        # build/SandSeek.app is missing, so only the image check matters here
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["5.1"]["result"], "SKIP")
        self.assertIn("newer than the image", steps["5.1"]["note"])


class Cleanup(FullTestCase):
    def test_stop_running_past_the_time_limit_still_ends_clean(self):
        started = time.time()
        process = self.fx.run(FAKE_SLEEP="stop", FULL_TEST_TIME_LIMIT_SECONDS="5", timeout=90)
        self.assertLess(time.time() - started, 80)
        self.assertFalse(os.path.exists(os.path.join(self.fx.secret_folder, "secret")))
        self.assertIn("sandbox stop", self.fx.calls())
        self.assertIn(process.returncode, (0, 124))
        self.fx.results(process)  # a report was written

    def test_sigterm_exits_143_and_cleans_up(self):
        process = subprocess.Popen(
            ["bash", f"{self.fx.repo}/Scripts/full_test.sh"], env=self.fx.env(FAKE_SLEEP="selftest"),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.time() + 60
        while not os.path.exists(self.fx.log + ".sleeping") and time.time() < deadline:
            time.sleep(0.1)
        process.send_signal(signal.SIGTERM)
        out, _ = process.communicate(timeout=60)
        self.assertEqual(process.returncode, 143)
        self.assertFalse(os.path.exists(os.path.join(self.fx.secret_folder, "secret")))
        self.assertIn("FULL_TEST_REPORT=", out)

    def test_killed_step_output_is_masked_at_the_end(self):
        key_file = os.path.join(self.fx.root, "key")
        with open(key_file, "w") as handle:
            handle.write(KEY)
        write(f"{self.fx.repo}/sandseek-stub", f"""\
            #!/bin/bash
            echo "key {KEY}"
            echo "key {KEY}" >&2
            sleep 30
            """)
        server = HTTPServer(("127.0.0.1", 0), QuietHandler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        write(f"{self.fx.repo}/Scripts/research_address_check.py", "print('x')\n", 0o644)
        process = self.fx.run("--server", f"http://127.0.0.1:{server.server_port}",
                              "--api-key-file", key_file, FULL_TEST_TIME_LIMIT_SECONDS="12", timeout=90)
        directory = self.fx.report_dir(process)
        self.assertNotIn(KEY, self.everything_text(directory))


class Safety(FullTestCase):
    def test_off_by_default(self):
        process = self.fx.run()
        self.assertEqual(process.returncode, 0, process.stdout)
        self.assertNotIn("safety_", self.fx.calls())
        _, steps, _ = self.fx.results(process)
        self.assertNotIn("7.1", steps)

    def test_safety_runs_probe_then_lifecycle_before_the_final_stop(self):
        process = self.fx.run("--safety", SKIP_PORT_SCAN="1")
        self.assertEqual(process.returncode, 0, process.stdout)
        data, steps, directory = self.fx.results(process)
        self.assertEqual(steps["7.1"]["result"], "PASS")
        self.assertEqual(steps["7.2"]["result"], "PASS")
        self.assertIn("Result: 1 pass, 0 fail", steps["7.1"]["note"])
        calls = self.fx.calls()
        self.assertIn("skipscan=1", calls)
        self.assertIn("safety_lifecycle args=--running", calls)
        self.assertLess(calls.index("safety_probe"), calls.index("safety_lifecycle"))
        self.assertLess(calls.index("safety_lifecycle"), calls.rindex("sandbox stop"))
        report = open(os.path.join(directory, "report.md")).read()
        self.assertIn("## Safety test", report)
        self.assertIn("PASS  stub check one", report)
        self.assertIn("NOTE  stub note", report)
        self.assertTrue(any("stub check one" in line for line in data["safety"]))

    def test_the_secret_is_masked_in_the_safety_output(self):
        process = self.fx.run("--safety")
        directory = self.fx.report_dir(process)
        everything = self.everything_text(directory) + process.stdout + process.stderr
        self.assertNotIn(SECRET, everything)

    def test_a_probe_failure_fails_the_run_and_still_cleans_up(self):
        process = self.fx.run("--safety", FAKE_FAIL="probe")
        self.assertEqual(process.returncode, 1)
        _, steps, directory = self.fx.results(process)
        self.assertEqual(steps["7.1"]["result"], "FAIL")
        self.assertIn("FAIL  stub failure", open(os.path.join(directory, "report.md")).read())
        self.assertIn("sandbox stop", self.fx.calls())

    def test_safety_is_skipped_without_a_running_sandbox(self):
        process = self.fx.run("--safety", FAKE_FAIL="start")
        _, steps, _ = self.fx.results(process)
        self.assertEqual(steps["7.1"]["result"], "SKIP")
        self.assertEqual(steps["7.2"]["result"], "SKIP")
        self.assertNotIn("safety_probe", self.fx.calls())

    def test_no_sandbox_flag_does_not_run_it(self):
        process = self.fx.run("--safety", "--no-sandbox")
        self.assertNotIn("safety_", self.fx.calls())


class Usage(FullTestCase):
    def test_models_without_start_server_is_a_usage_error(self):
        process = self.fx.run("--models", self.fx.root)
        self.assertEqual(process.returncode, 2)
        self.assertNotIn("FULL_TEST_REPORT", process.stdout)

    def test_models_must_be_an_existing_absolute_folder(self):
        process = self.fx.run("--start-server", f"{self.fx.repo}/server/TUFFServer",
                              "--models", "relative/folder")
        self.assertEqual(process.returncode, 2)

    def test_start_server_with_ollama_is_a_usage_error(self):
        process = self.fx.run("--server-type", "ollama", "--model", "qwen3:8b",
                              "--start-server", f"{self.fx.repo}/server/TUFFServer")
        self.assertEqual(process.returncode, 2)
        self.assertIn("TUFFServer only", process.stderr)
        self.assertNotIn("FULL_TEST_REPORT", process.stdout)

    def test_an_explicit_key_file_with_ollama_is_a_usage_error(self):
        key = os.path.join(self.fx.root, "key")
        write(key, "secret-key\n")
        process = self.fx.run("--server-type", "ollama", "--model", "qwen3:8b",
                              "--api-key-file", key)
        self.assertEqual(process.returncode, 2)
        self.assertIn("--api-key-file", process.stderr)
        self.assertNotIn("FULL_TEST_REPORT", process.stdout)

    def test_ollama_needs_a_model(self):
        process = self.fx.run("--server-type", "ollama")
        self.assertEqual(process.returncode, 2)
        self.assertIn("--model", process.stderr)

    def test_unknown_server_type_is_a_usage_error(self):
        process = self.fx.run("--server-type", "lmstudio")
        self.assertEqual(process.returncode, 2)

    def test_help_mentions_server_type(self):
        process = self.fx.run("--help")
        self.assertIn("--server-type", process.stdout)
        self.assertIn("ollama", process.stdout)

    def test_help_mentions_background_run(self):
        process = self.fx.run("--help")
        self.assertEqual(process.returncode, 0)
        self.assertIn("background", process.stdout)
        self.assertIn("--take-over-sandbox", process.stdout)


if __name__ == "__main__":
    unittest.main()
