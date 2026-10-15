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


def address_helpers():
    """The script's functions for the Mac's own addresses (valid_ipv4 to
    write_blocked_addresses)."""
    start = TEXT.index("# --- The Mac's own addresses")
    end = TEXT.index("# Apple's `container`, where")
    return TEXT[start:end]


def addresses(snippet, stdin=""):
    # `set -f` as in the script, which splits words without file name expansion.
    return subprocess.run(
        ["bash", "-c", "set -euo pipefail\nset -f\nnl=$'\\n'\n" + address_helpers() + snippet],
        input=stdin, capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"}, timeout=30)


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


# What macOS prints for the Mac's interfaces (documentation addresses).
IFCONFIG = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\toptions=1203<RXCSUM,TXCSUM,TXSTATUS,SW_TIMESTAMP>
\tinet 127.0.0.1 netmask 0xff000000
\tinet6 ::1 prefixlen 128
\tinet6 fe80::1%lo0 prefixlen 64 scopeid 0x1
\tnd6 options=201<PERFORMNUD,DAD>
gif0: flags=8010<POINTOPOINT,MULTICAST> mtu 1280
stf0: flags=0<> mtu 1280
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tether aa:bb:cc:dd:ee:ff
\tinet6 fe80::1c2b:3d4e:5f60:7182%en0 prefixlen 64 secured scopeid 0xc
\tinet 203.0.113.9 netmask 0xffffff00 broadcast 203.0.113.255
\tinet6 2001:DB8:1234:5678:AAAA:bbbb:cccc:dddd prefixlen 64 autoconf secured
\tinet6 2001:db8:1234:5678:aaaa:bbbb:cccc:dddd prefixlen 64 autoconf temporary
\tnd6 options=201<PERFORMNUD,DAD>
\tmedia: autoselect
\tstatus: active
bridge100: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
\tinet6 fe80::abcd:1234:5678:9abc%utun0 prefixlen 64 scopeid 0x10
\tinet 10.8.0.2 --> 10.8.0.1 netmask 0xffffff00
"""


class MacAddressTests(unittest.TestCase):
    def check(self, function, text):
        """Whether the script's `function` accepts `text` (passed as an argument)."""
        return subprocess.run(
            ["bash", "-c", "set -euo pipefail\nset -f\n" + address_helpers() + function + ' "$1"',
             "bash", text],
            capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"}).returncode == 0

    def test_ipv4_must_be_a_plain_dotted_quad(self):
        for text in ("0.0.0.0", "10.0.0.1", "127.0.0.1", "198.41.0.4", "255.255.255.255", "8.8.8.8"):
            with self.subTest(text=text):
                self.assertTrue(self.check("valid_ipv4", text))
        for text in ("", "1.2.3", "1.2.3.4.5", "01.2.3.4", "1.2.3.04", "1.2.3.256", "1.2.3.-1",
                     " 1.2.3.4", "1.2.3.4 ", "1.2.3.4/24", "1.2.3.4;", "::1", "0x7f.0.0.1",
                     "1.2.3.\u0664", "1..3.4", ".1.2.3.4", "1.2.3.4\n", "a.b.c.d", "1.2.3.1000",
                     "1.2.3.4,5.6.7.8"):
            with self.subTest(text=text):
                self.assertFalse(self.check("valid_ipv4", text))

    def check_ipv6(self, text):
        return self.check("valid_ipv6", text)

    def test_ipv6_must_be_plain_hexadecimal_with_at_most_one_double_colon(self):
        for text in ("::1", "::", "fe80::1", "fe80::1c2b:3d4e:5f60:7182", "2001:db8::7",
                     "2001:DB8:1234:5678:AAAA:bbbb:cccc:dddd", "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7::",
                     "::2:3:4:5:6:7:8", "1::8", "2606:2800:220:1:248:1893:25c8:1946"):
            with self.subTest(text=text):
                self.assertTrue(self.check_ipv6(text))
        for text in ("", ":", ":::", "1", "1:2", "fe80::1%en0", "fe80::1%", "::ffff:1.2.3.4",
                     "[::1]", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1::2::3", ":1:2:3:4:5:6:7",
                     "1:2:3:4:5:6:7:", "1:::2", "12345::1", "g::1", "::1 ", " ::1", "::1;", "::1/64",
                     "1:2:3:4:5:6:7:8::", "::1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7:8:", ":1::2", "1::2:",
                     "\u0661::1", "0x1::1", "1.2.3.4"):
            with self.subTest(text=text):
                self.assertFalse(self.check_ipv6(text))

    def test_ifconfig_output_gives_every_address_once_without_zone_ids(self):
        done = addresses("collect_mac_addresses", IFCONFIG)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stderr, "")
        # Loopback and link-local addresses are included; the repeated
        # temporary IPv6 address is the same address in lower case.
        self.assertEqual(done.stdout.split(), [
            "127.0.0.1", "::1", "fe80::1", "fe80::1c2b:3d4e:5f60:7182", "203.0.113.9",
            "2001:db8:1234:5678:aaaa:bbbb:cccc:dddd", "192.168.64.1",
            "fe80::abcd:1234:5678:9abc", "10.8.0.2"])

    def test_only_inet_lines_count(self):
        text = ("\tether 1.2.3.4\n\tnetmask 5.6.7.8\n\tbroadcast 9.9.9.9\n"
                "\tinet 192.0.2.1 netmask 0xff broadcast 9.9.9.9\n inet6 2001:db8::1 prefixlen 64\n"
                "\tinet\n\tinet6\ninet 192.0.2.2\n")
        done = addresses("collect_mac_addresses", text)
        self.assertEqual(done.stdout.split(), ["192.0.2.1", "2001:db8::1", "192.0.2.2"])
        self.assertEqual(done.stderr, "")

    def test_anything_that_does_not_pass_is_left_out_and_reported(self):
        text = ("\tinet 1.2.3\n\tinet 01.2.3.4\n\tinet 8.8.8.8;touch\n"
                "\tinet6 ::ffff:1.2.3.4\n\tinet6 $(id)\n\tinet 192.0.2.1\n")
        done = addresses("collect_mac_addresses", text)
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.split(), ["192.0.2.1"])
        self.assertEqual(done.stderr.count("ignoring an interface address that is not valid"), 5)

    def test_a_long_bad_address_is_cut_in_the_message(self):
        done = addresses("collect_mac_addresses", "\tinet " + "9" * 500 + "\n")
        self.assertEqual(done.stdout, "")
        self.assertLess(len(done.stderr), 200)

    def test_the_list_is_the_macs_addresses_plus_the_test_address(self):
        with tempfile.TemporaryDirectory() as folder:
            program = (
                f'secret_folder="{folder}"; blocked_file="{folder}/blocked-addresses"\n'
                'test_address=198.41.0.4\n'
                'ifconfig_bin="$FAKE"\n'
                "write_blocked_addresses\ncat \"$blocked_file\"\nls -a \"$secret_folder\"\n")
            fake = os.path.join(folder, "fake-ifconfig")
            with open(fake, "w") as handle:
                handle.write("#!/bin/sh\ncat <<'EOF'\n" + IFCONFIG + "EOF\n")
            os.chmod(fake, 0o755)
            done = subprocess.run(
                ["bash", "-c", "set -euo pipefail\nset -f\nnl=$'\\n'\n" + address_helpers() + program],
                capture_output=True, text=True, env={"PATH": "/usr/bin:/bin", "FAKE": fake})
            self.assertEqual(done.returncode, 0, done.stderr)
            lines = done.stdout.split("\n")
            self.assertEqual(lines[:10], [
                "127.0.0.1", "::1", "fe80::1", "fe80::1c2b:3d4e:5f60:7182", "203.0.113.9",
                "2001:db8:1234:5678:aaaa:bbbb:cccc:dddd", "192.168.64.1",
                "fe80::abcd:1234:5678:9abc", "10.8.0.2", "198.41.0.4"])
            self.assertEqual(os.stat(os.path.join(folder, "blocked-addresses")).st_mode & 0o777, 0o600)
            # No temporary file is left behind.
            self.assertEqual(sorted(n for n in os.listdir(folder) if n.startswith(".")), [])

    def test_the_test_address_is_not_added_twice(self):
        with tempfile.TemporaryDirectory() as folder:
            fake = os.path.join(folder, "fake-ifconfig")
            with open(fake, "w") as handle:
                handle.write("#!/bin/sh\necho '\tinet 198.41.0.4 netmask 0xff'\n")
            os.chmod(fake, 0o755)
            program = (f'secret_folder="{folder}"; blocked_file="{folder}/b"; test_address=198.41.0.4\n'
                       f'ifconfig_bin="{fake}"\nwrite_blocked_addresses\ncat "$blocked_file"\n')
            done = subprocess.run(
                ["bash", "-c", "set -euo pipefail\nset -f\nnl=$'\\n'\n" + address_helpers() + program],
                capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"})
            self.assertEqual(done.stdout, "198.41.0.4\n")

    def test_the_script_uses_the_system_ifconfig_and_hands_the_list_over_by_file(self):
        self.assertIn("ifconfig_bin=/sbin/ifconfig\n", TEXT)
        self.assertIn('blocked_file="$secret_folder/blocked-addresses"', TEXT)
        code = "\n".join(code_lines())
        # Never through PATH, never in an option or an environment variable.
        self.assertNotRegex(code, r"(^|[;|(]\s*)ifconfig\s")
        self.assertNotIn("BLOCKED_ADDRESSES", code)
        run_options = code[code.index("run_options=("):code.index("for server in $dns_servers")]
        self.assertNotIn("blocked", run_options)


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
