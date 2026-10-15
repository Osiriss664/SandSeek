"""Tests for Scripts/research_sandbox.sh that need no Mac, no `container` and no root.

Run with: python3 -m unittest discover -s Scripts -p 'test_*.py'

They read the script and run its small helper functions in bash. What they
cannot show is that a real, Apple-signed `container` passes `require_container`:
that needs a Mac with Apple container installed (docs/INSTALL.md).
"""

import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "research_sandbox.sh")

with open(SCRIPT, encoding="utf-8") as handle:
    TEXT = handle.read()


def code_lines():
    """The script's lines without whole-line comments."""
    return [line for line in TEXT.splitlines() if not line.lstrip().startswith("#")]


def helpers():
    """The script's container checks, from the tool's path to `require_container`."""
    start = TEXT.index("container_bin=/usr/local/bin/container")
    end = TEXT.index("# Refuses (exit 1) unless $container_bin")
    return TEXT[start:end]


def bash(snippet, env=None):
    return subprocess.run(
        ["bash", "-c", "set -euo pipefail\n" + helpers() + snippet],
        capture_output=True, text=True, env=env or {"PATH": "/usr/bin:/bin"}, timeout=30)


class NoBareContainerTests(unittest.TestCase):
    # `container` as the first word of a command: at the start of a line, or
    # after $( , ! , if , then , do , &&, || , ; or a pipe.
    COMMAND = re.compile(r"(^|\$\(|[;|!]|&&|\bif|\bthen|\bdo|\belse)\s*container\s", re.M)

    def test_every_container_command_uses_the_checked_path(self):
        found = [line for line in code_lines() if self.COMMAND.search(line)]
        self.assertEqual(found, [], "a bare `container` is looked up through PATH")

    def test_the_checked_path_is_apples_installer_path(self):
        self.assertIn("container_bin=/usr/local/bin/container\n", TEXT)
        self.assertNotIn("command -v container", "\n".join(code_lines()))
        self.assertNotIn("/usr/bin/env container", TEXT)

    def test_every_command_that_runs_container_checks_it_first(self):
        # Each branch of the final `case` that uses "$container_bin" calls
        # require_container before its first use.
        body = TEXT[TEXT.index('case "${1:-}" in'):]
        for branch in ("build)", "start)", "stop)", "selftest)"):
            section = body[body.index("\n  " + branch):]
            section = section[:section.index("\n    ;;")]
            self.assertIn("require_container", section, branch)
            self.assertLess(section.index("require_container"), section.index('"$container_bin"'), branch)

    def test_the_signature_requirement_names_apples_team(self):
        self.assertIn('leaf[subject.OU] = "UPBK2H6LZM"', TEXT)
        self.assertIn("anchor apple generic", TEXT)
        self.assertIn("/usr/bin/codesign --verify --strict", TEXT)

    def test_no_features_that_macos_bash_3_2_lacks(self):
        text = "\n".join(code_lines())
        for feature in ("readlink -f", "mapfile", "readarray", "declare -A", "&>>", "|&"):
            self.assertNotIn(feature, text)
        self.assertNotRegex(text, r"\$\{[a-zA-Z_]+(,,|\^\^)\}")


class ContainerCheckTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.folder, ignore_errors=True)

    def make(self, name, mode):
        path = os.path.join(self.folder, name)
        with open(path, "w") as handle:
            handle.write("#!/bin/sh\n")
        os.chmod(path, mode)
        return path

    def test_a_world_writable_file_is_rejected(self):
        path = self.make("tool", 0o777)
        self.assertNotEqual(bash(f'chain_is_closed "{path}"').returncode, 0)

    def test_the_failing_path_is_reported(self):
        os.chmod(self.folder, 0o777)
        path = self.make("tool", 0o755)
        result = bash(f'chain_is_closed "{path}" || true; echo "[$untrusted_path]"')
        self.assertIn(f"[{self.folder}]", result.stdout)
        os.chmod(self.folder, 0o755)
        path = self.make("tool2", 0o777)
        result = bash(f'chain_is_closed "{path}" || true; echo "[$untrusted_path]"')
        self.assertIn(f"[{path}]", result.stdout)

    def test_a_group_writable_file_is_rejected(self):
        path = self.make("tool", 0o775)
        self.assertNotEqual(bash(f'chain_is_closed "{path}"').returncode, 0)

    def test_a_folder_others_can_write_to_is_rejected(self):
        # Whoever owns the file, the folder above it is not closed.
        os.chmod(self.folder, 0o777)
        path = self.make("tool", 0o755)
        self.assertNotEqual(bash(f'chain_is_closed "{path}"').returncode, 0)

    def test_a_file_of_a_user_who_is_not_root_is_rejected(self):
        if os.geteuid() == 0:
            self.skipTest("this run is root, so everything it makes belongs to root")
        path = self.make("tool", 0o755)
        self.assertNotEqual(bash(f'owned_by_root_and_closed "{path}"').returncode, 0)

    def test_a_missing_path_and_a_relative_path_are_rejected(self):
        self.assertNotEqual(bash('chain_is_closed "/nonexistent/tool"').returncode, 0)
        self.assertNotEqual(bash('chain_is_closed "tool"').returncode, 0)

    def test_root_owned_system_folders_pass(self):
        if os.geteuid() != 0 and os.stat("/usr/bin").st_uid != 0:
            self.skipTest("unusual system layout")
        if os.stat("/usr/bin").st_mode & 0o022:
            self.skipTest("unusual system layout")
        self.assertEqual(bash('chain_is_closed "/usr/bin"').returncode, 0)

    def test_links_are_followed_to_the_real_file(self):
        target = self.make("real", 0o755)
        link = os.path.join(self.folder, "link")
        os.symlink("real", link)
        done = bash(f'resolve_path "{link}"')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout, os.path.realpath(target))
        chained = os.path.join(self.folder, "chained")
        os.symlink(link, chained)
        self.assertEqual(bash(f'resolve_path "{chained}"').stdout, os.path.realpath(target))

    def test_a_link_loop_is_refused(self):
        one = os.path.join(self.folder, "one")
        two = os.path.join(self.folder, "two")
        os.symlink(two, one)
        os.symlink(one, two)
        self.assertNotEqual(bash(f'resolve_path "{one}"').returncode, 0)

    def test_versions(self):
        for output, supported in [
            ("container CLI version 1.5.0 (build: release, commit: abc1234)", True),
            ("container CLI version 1.5.2", True),
            ("container CLI version 1.10.0", True),
            ("container CLI version 2.0.0", True),
            ("container version 1.5", True),
            ("container CLI version 1.4.9", False),
            ("container CLI version 0.9.0", False),
            ("container CLI version 1.4", False),
            ("no version here", False),
            ("", False),
        ]:
            with self.subTest(output=output):
                done = subprocess.run(
                    ["bash", "-c", "set -euo pipefail\n" + helpers() + 'version_is_supported "$1"',
                     "bash", output],
                    capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"})
                self.assertEqual(done.returncode == 0, supported, done.stderr)


class FixedEnvironmentTests(unittest.TestCase):
    def test_the_second_run_has_only_the_fixed_environment(self):
        # Everything up to the end of the environment block, then `env`.
        end = TEXT.index("export PATH\n") + len("export PATH\n")
        program = TEXT[:end] + "env\n"
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as handle:
            handle.write(program)
        self.addCleanup(os.unlink, handle.name)
        polluted = {
            "PATH": "/tmp/evil:/usr/bin:/bin", "HOME": "/home/someone", "USER": "someone",
            "BASH_ENV": "/tmp/evil.sh", "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "HTTPS_PROXY": "http://proxy.example:3128", "SSH_AUTH_SOCK": "/tmp/agent",
            "SANDSEEK_DNS": "1.1.1.1 9.9.9.9", "SEARXNG_URL": "http://127.0.0.1:8080",
            "SANDSEEK_SANDBOX_PORT": "9100", "SHELLOPTS": "xtrace",
        }
        done = subprocess.run(["bash", handle.name, "status"], capture_output=True, text=True,
                              env=polluted, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        seen = dict(line.split("=", 1) for line in done.stdout.splitlines() if "=" in line)
        seen.pop("_", None)
        seen.pop("PWD", None)
        seen.pop("SHLVL", None)
        seen.pop("OLDPWD", None)
        self.assertEqual(seen, {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
            "HOME": "/home/someone", "USER": "someone", "SANDSEEK_SANDBOX_CLEAN_ENV": "1",
            "SANDSEEK_DNS": "1.1.1.1 9.9.9.9", "SEARXNG_URL": "http://127.0.0.1:8080",
            "SANDSEEK_SANDBOX_PORT": "9100",
        })


class NotInstalledTests(unittest.TestCase):
    @unittest.skipIf(os.path.exists("/usr/local/bin/container"),
                     "Apple container is installed on this machine")
    def test_every_command_says_so_when_container_is_missing(self):
        for command in ("build", "stop"):
            with self.subTest(command=command):
                done = subprocess.run(["bash", SCRIPT, command], capture_output=True, text=True,
                                      env={"PATH": "/usr/bin:/bin", "HOME": tempfile.gettempdir()},
                                      timeout=30)
                self.assertEqual(done.returncode, 1)
                self.assertIn("Apple container is not installed at /usr/local/bin/container", done.stderr)


if __name__ == "__main__":
    unittest.main()
