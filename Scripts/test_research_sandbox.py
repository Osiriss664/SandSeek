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
import time
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


class SelfTestPortTests(unittest.TestCase):
    def test_the_blocked_address_is_tried_on_a_port_a_root_server_accepts(self):
        # Port 80 might be reset even without the firewall rule; TCP port 53 is
        # open on the root server, so only the rule can make it fail at once.
        self.assertIn("socket.create_connection((sys.argv[1], 53), timeout=4)", TEXT)
        self.assertNotIn("socket.create_connection((sys.argv[1], 80)", TEXT)


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


class OneSandSeekAtATimeTests(unittest.TestCase):
    """`start` and `stop` with a fake `container`: the lock, the random port,
    the VM's name and the removal of leftovers (docs/SECURITY.md)."""

    UNSIGNED = '{"error": {"message": "not signed", "code": "unauthorized"}}'
    BUSY = "Another SandSeek is using the web sandbox. Close it first, or press Stop in it."

    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.home, True)
        self.addCleanup(self.end_lock_holders)
        self.bin = os.path.join(self.home, "bin")
        os.mkdir(self.bin)
        self.calls = os.path.join(self.home, "calls")
        self.vms = os.path.join(self.home, "vms")
        open(self.calls, "w").close()
        open(self.vms, "w").close()
        self.folder = os.path.join(self.home, "Library", "Application Support", "SandSeek", "sandbox")
        # `run` adds its --name to the list, stop and delete take a name out.
        self.write_stub("container", '''#!/bin/bash
echo "$*" >> "$FAKE_CALLS"
vms="$(dirname "$0")/../vms"
case "$1" in
  run)
    [[ -z "${FAKE_RUN_EXIT:-}" ]] || exit "$FAKE_RUN_EXIT"
    previous=""
    for word in "$@"; do
      [[ "$previous" != --name ]] || echo "$word" >> "$vms"
      previous="$word"
    done ;;
  stop|delete)
    grep -vxF "$2" "$vms" > "$vms.new" || true
    mv "$vms.new" "$vms" ;;
  list) cat "$vms" ;;
  logs) ;;
esac
exit 0
''')
        self.write_stub("curl", "#!/bin/bash\nprintf '%s\\n%s' '" + self.UNSIGNED + "' 401\n")
        self.write_stub("ifconfig", "#!/bin/bash\necho '\tinet 127.0.0.1 netmask 0xff000000'\n")
        with open(SCRIPT, encoding="utf-8") as handle:
            text = handle.read()
        text = text.replace("container_bin=/usr/local/bin/container",
                            f'container_bin="{self.bin}/container"', 1)
        text = text.replace("ifconfig_bin=/sbin/ifconfig", f'ifconfig_bin="{self.bin}/ifconfig"', 1)
        start = text.index("require_container() {")
        end = text.index("\n}\n", start) + 3
        text = text[:start] + "require_container() {\n  :\n}\n" + text[end:]
        text = re.sub(r"\bcurl (-s)", lambda match: f"{self.bin}/curl {match.group(1)}", text)
        self.script = os.path.join(self.home, "research_sandbox.sh")
        with open(self.script, "w", encoding="utf-8") as handle:
            handle.write(text)

    def write_stub(self, name, text):
        path = os.path.join(self.bin, name)
        with open(path, "w") as handle:
            handle.write(text)
        os.chmod(path, 0o755)

    def run_script(self, *args, **extra):
        env = {"PATH": self.bin + os.pathsep + os.environ["PATH"], "HOME": self.home,
               "SANDSEEK_SANDBOX_CLEAN_ENV": "1", "FAKE_CALLS": self.calls, **extra}
        return subprocess.run(["bash", self.script, *args], env=env, capture_output=True,
                              text=True, timeout=60, stdin=subprocess.DEVNULL)

    def lines(self, path):
        with open(path) as handle:
            return handle.read().splitlines()

    def in_folder(self, name):
        return os.path.join(self.folder, name)

    def holder_pid(self):
        return int(self.lines(self.in_folder("lock"))[0].split()[0])

    def end_lock_holders(self):
        try:
            os.kill(self.holder_pid(), 15)
        except (OSError, ValueError, IndexError):
            pass

    def ended(self, pid):
        """True when process `pid` is gone (or only a zombie), within 5 seconds."""
        for _ in range(50):
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True,
                                   text=True).stdout.strip()
            if not state or state.startswith("Z"):
                return True
            time.sleep(0.1)
        return False

    def started(self, **extra):
        done = self.run_script("start", **extra)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done

    def test_a_start_records_a_free_port_and_a_new_name(self):
        self.started()
        port_file = self.in_folder("port")
        self.assertEqual(os.stat(port_file).st_mode & 0o777, 0o600)
        text = self.lines(port_file)
        self.assertEqual(len(text), 1)
        self.assertRegex(text[0], r"^[0-9]{4,5}$")
        port = int(text[0])
        self.assertTrue(1024 <= port <= 65535)
        name_file = self.in_folder("vm-name")
        self.assertEqual(os.stat(name_file).st_mode & 0o777, 0o600)
        name = self.lines(name_file)[0]
        self.assertRegex(name, r"^sandseek-sandbox-[0-9a-f]{8}$")
        run = next(c for c in self.lines(self.calls) if c.startswith("run "))
        self.assertIn(f"--name {name} ", run)
        # Only the Mac's side is the picked port; inside the VM it stays 9100.
        self.assertIn(f"--publish 127.0.0.1:{port}:9100", run)
        self.assertEqual(self.lines(self.vms), [name])

    def test_the_port_is_picked_again_at_each_start(self):
        ports = set()
        for _ in range(3):
            self.started()
            ports.add(self.lines(self.in_folder("port"))[0])
            done = self.run_script("stop")
            self.assertEqual(done.returncode, 0, done.stderr)
        self.assertGreater(len(ports), 1)

    def test_a_fixed_port_overrides_the_free_one(self):
        self.started(SANDSEEK_SANDBOX_PORT="45678")
        self.assertEqual(self.lines(self.in_folder("port")), ["45678"])
        self.assertIn("--publish 127.0.0.1:45678:9100",
                      next(c for c in self.lines(self.calls) if c.startswith("run ")))

    def test_status_finds_the_recorded_port(self):
        self.started()
        done = self.run_script("status")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("127.0.0.1:" + self.lines(self.in_folder("port"))[0], done.stdout)
        # Not like the file says (digits only, 1024 to 65535): nothing is found.
        # One final line break, or none, is fine; a second one is not (the app
        # and verify_sandbox_signature.py read it the same way).
        for good in ("45678\n", "45678"):
            with open(self.in_folder("port"), "w") as handle:
                handle.write(good)
            os.chmod(self.in_folder("port"), 0o600)
            self.assertEqual(self.run_script("status").returncode, 0, repr(good))
        for bad in ("80", "99999", "1234 ", "12a45", "", "45678\n", "\n45678"):
            with open(self.in_folder("port"), "w") as handle:
                handle.write(bad + "\n")
            os.chmod(self.in_folder("port"), 0o600)
            self.assertEqual(self.run_script("status").returncode, 1, repr(bad))
        with open(self.in_folder("port"), "w") as handle:
            handle.write("45678\n")
        os.chmod(self.in_folder("port"), 0o644)
        self.assertEqual(self.run_script("status").returncode, 1)

    def test_a_fixed_port_below_1024_or_above_65535_is_refused(self):
        for bad in ("80", "1023", "10", "65536", "99999", "0", "abc", "1e4", "-1234"):
            done = self.run_script("start", SANDSEEK_SANDBOX_PORT=bad)
            self.assertEqual(done.returncode, 2, bad)
            self.assertIn("from 1024 to 65535", done.stderr)
            self.assertEqual(self.lines(self.vms), [], bad)
            self.assertFalse(os.path.exists(self.in_folder("secret")), bad)
        self.started(SANDSEEK_SANDBOX_PORT="1024")
        self.assertEqual(self.lines(self.in_folder("port")), ["1024"])

    def test_a_name_file_with_two_line_breaks_is_not_used(self):
        self.started()
        name = self.lines(self.in_folder("vm-name"))[0]
        with open(self.in_folder("vm-name"), "w") as handle:
            handle.write(name + "\n\n")
        os.chmod(self.in_folder("vm-name"), 0o600)
        # The record is not used: `stop` falls back to the plain 0.1.0 name and
        # leaves the VM named in the file alone. (The holder is made older than
        # 5 seconds, so this is not taken for a start in progress.)
        holder = self.holder_pid()
        with open(self.in_folder("lock"), "w") as handle:
            handle.write(f"{holder} {int(time.time()) - 60}\n")
        self.assertEqual(self.run_script("stop").returncode, 0)
        self.assertEqual(self.lines(self.vms), [name])

    def test_a_second_start_fails_and_leaves_the_first_alone(self):
        self.started()
        name = self.lines(self.in_folder("vm-name"))[0]
        port = self.lines(self.in_folder("port"))[0]
        secret = self.lines(self.in_folder("secret"))
        before = len(self.lines(self.calls))
        done = self.run_script("start")
        self.assertEqual(done.returncode, 75)
        self.assertIn(self.BUSY, done.stderr)
        # Nothing was stopped, deleted or run, and no file was touched.
        self.assertEqual([c for c in self.lines(self.calls)[before:] if c.split()[0] in ("stop", "delete", "run")], [])
        self.assertEqual(self.lines(self.vms), [name])
        self.assertEqual(self.lines(self.in_folder("vm-name")), [name])
        self.assertEqual(self.lines(self.in_folder("port")), [port])
        self.assertEqual(self.lines(self.in_folder("secret")), secret)

    def test_the_lock_holds_a_pid_and_a_start_time(self):
        self.started()
        pid, stamp = self.lines(self.in_folder("lock"))[0].split()
        os.kill(int(pid), 0)
        self.assertLess(abs(int(stamp) - time.time()), 60)

    def test_stop_lets_go_of_the_lock(self):
        self.started()
        pid = self.holder_pid()
        done = self.run_script("stop")
        self.assertEqual(done.returncode, 0, done.stderr)
        for name in ("secret", "port", "vm-name", "blocked-addresses"):
            self.assertFalse(os.path.exists(self.in_folder(name)), name)
        self.assertEqual(self.lines(self.vms), [])
        self.assertTrue(self.ended(pid))
        self.started()

    def test_stop_removes_only_the_vm_that_was_started(self):
        self.started()
        name = self.lines(self.in_folder("vm-name"))[0]
        with open(self.vms, "a") as handle:
            handle.write("sandseek-sandbox-0123abcd\n")
        self.assertEqual(self.run_script("stop").returncode, 0)
        self.assertEqual(self.lines(self.vms), ["sandseek-sandbox-0123abcd"])
        stops = [c for c in self.lines(self.calls) if c.startswith(("stop ", "delete "))]
        self.assertEqual(stops, [f"stop {name}", f"delete {name}"])

    def test_a_lock_whose_process_is_gone_is_taken_over(self):
        os.makedirs(self.folder, mode=0o700)
        dead = subprocess.Popen(["true"])
        dead.wait()
        with open(self.in_folder("lock"), "w") as handle:
            handle.write(f"{dead.pid} 1\n")
        self.started()
        self.assertEqual(self.holder_pid() != dead.pid, True)
        os.kill(self.holder_pid(), 0)

    def test_leftovers_with_the_prefix_are_removed_at_the_next_start(self):
        os.makedirs(self.folder, mode=0o700)
        for name in ("secret", "port", "vm-name", "blocked-addresses"):
            with open(self.in_folder(name), "w") as handle:
                handle.write("old\n")
        with open(self.vms, "w") as handle:
            handle.write("sandseek-sandbox\nsandseek-sandbox-0123abcd\nother\n"
                         "sandseek-sandbox-debug\nsandseek-sandbox-0123ABCD\n")
        self.started()
        removed = [c for c in self.lines(self.calls) if c.startswith("stop ")]
        self.assertEqual(removed, ["stop sandseek-sandbox", "stop sandseek-sandbox-0123abcd"])
        deleted = [c for c in self.lines(self.calls) if c.startswith("delete ")]
        self.assertEqual(deleted, ["delete sandseek-sandbox", "delete sandseek-sandbox-0123abcd"])
        name = self.lines(self.in_folder("vm-name"))[0]
        self.assertEqual(self.lines(self.vms), ["other", "sandseek-sandbox-debug",
                                                "sandseek-sandbox-0123ABCD", name])
        self.assertEqual(len(self.lines(self.in_folder("secret"))[0]), 64)
        self.assertNotEqual(self.lines(self.in_folder("port")), ["old"])
        self.assertNotIn("old", self.lines(self.in_folder("blocked-addresses")))

    def test_nothing_is_removed_before_the_lock_is_ours(self):
        self.started()
        with open(self.vms, "a") as handle:
            handle.write("sandseek-sandbox-0123abcd\n")
        before = len(self.lines(self.calls))
        self.assertEqual(self.run_script("start").returncode, 75)
        self.assertNotIn("sandseek-sandbox-0123abcd",
                         " ".join(self.lines(self.calls)[before:]))
        self.assertIn("sandseek-sandbox-0123abcd", self.lines(self.vms))

    def test_a_holder_whose_vm_is_gone_is_taken_over_after_the_grace_time(self):
        self.started()
        old = self.holder_pid()
        # The VM is gone and the holder is old; a younger holder is left alone.
        open(self.vms, "w").close()
        self.assertEqual(self.run_script("start").returncode, 75)
        with open(self.in_folder("lock"), "w") as handle:
            handle.write(f"{old} {int(time.time()) - 1000}\n")
        self.started()
        self.assertNotEqual(self.holder_pid(), old)
        self.assertEqual(len(self.lines(self.vms)), 1)
        self.assertTrue(self.ended(old))

    def test_the_apps_own_running_sandbox_can_be_replaced_in_one_start(self):
        # The app makes a fresh VM for the next question with this setting, the
        # pid of the holder it recorded; any other start is still refused.
        self.started()
        first = self.lines(self.in_folder("vm-name"))[0]
        old = self.holder_pid()
        self.assertEqual(self.run_script("start").returncode, 75)
        self.started(SANDSEEK_SANDBOX_REPLACE=str(old))
        second = self.lines(self.in_folder("vm-name"))[0]
        self.assertNotEqual(first, second)
        self.assertEqual(self.lines(self.vms), [second])
        self.assertTrue(self.ended(old))
        self.assertNotEqual(self.holder_pid(), old)

    def test_a_replace_for_another_holder_is_refused(self):
        # A second app copy adopted this VM; its record names another pid (or
        # an old one). Its replace must not end this holder or its VM.
        self.started()
        name = self.lines(self.in_folder("vm-name"))[0]
        holder = self.holder_pid()
        for wrong in ("1", str(holder + 1), "0" + str(holder), str(holder) + "0", "abc", " "):
            before = len(self.lines(self.calls))
            done = self.run_script("start", SANDSEEK_SANDBOX_REPLACE=wrong)
            self.assertEqual(done.returncode, 75, wrong)
            self.assertIn(self.BUSY, done.stderr)
            self.assertEqual([c for c in self.lines(self.calls)[before:]
                              if c.split()[0] in ("stop", "delete", "run")], [], wrong)
            self.assertEqual(self.lines(self.vms), [name], wrong)
            self.assertEqual(self.holder_pid(), holder, wrong)
            os.kill(holder, 0)

    def test_a_replace_for_a_holder_that_is_no_lock_holder_is_refused(self):
        # The lock file names a live process that is not the script's holder:
        # it is never signalled, even when REPLACE names it.
        self.started()
        holder = self.holder_pid()
        sleeper = subprocess.Popen(["sleep", "30"])
        self.addCleanup(sleeper.kill)
        self.addCleanup(sleeper.wait)
        with open(self.in_folder("lock"), "w") as handle:
            handle.write(f"{sleeper.pid} {int(time.time())}\n")
        done = self.run_script("start", SANDSEEK_SANDBOX_REPLACE=str(sleeper.pid))
        # The real holder keeps the flock, so the start is busy either way.
        self.assertEqual(done.returncode, 75)
        self.assertIsNone(sleeper.poll())
        os.kill(holder, 0)

    def test_a_killed_start_leaves_a_holder_that_the_next_replace_ends(self):
        # The app's 180 s limit kills the script; its EXIT trap never runs and
        # the detached holder stays. The app records that pid and the next
        # start (REPLACE=<pid>) takes over and cleans up.
        self.started()
        holder = self.holder_pid()
        done = self.run_script("start")
        self.assertEqual(done.returncode, 75)
        self.started(SANDSEEK_SANDBOX_REPLACE=str(holder))
        self.assertTrue(self.ended(holder))
        self.assertEqual(len(self.lines(self.vms)), 1)

    def test_a_probe_that_holds_the_lock_for_an_instant_does_not_refuse_a_start(self):
        import fcntl
        os.makedirs(self.folder, mode=0o700)
        descriptor = os.open(self.in_folder("lock"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_SH)
        timer = __import__("threading").Timer(0.25, lambda: os.close(descriptor))
        timer.start()
        self.addCleanup(timer.join)
        self.started()

    def test_a_shared_lock_does_not_stop_the_holder_from_excluding_others(self):
        # The app probes with a shared lock; the holder's exclusive one must
        # still keep every other taker out.
        import fcntl
        self.started()
        descriptor = os.open(self.in_folder("lock"), os.O_RDONLY)
        self.addCleanup(os.close, descriptor)
        with self.assertRaises(OSError):
            fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
        with self.assertRaises(OSError):
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_stop_leaves_a_start_that_has_just_begun_alone(self):
        # A holder under 5 seconds old whose VM is not recorded yet is a start
        # in progress (`stop` does not take the lock).
        self.started()
        holder = self.holder_pid()
        os.remove(self.in_folder("vm-name"))
        with open(self.in_folder("lock"), "w") as handle:
            handle.write(f"{holder} {int(time.time())}\n")
        done = self.run_script("stop")
        self.assertEqual(done.returncode, 75)
        self.assertIn("starting the web sandbox", done.stderr)
        os.kill(holder, 0)
        self.assertTrue(os.path.exists(self.in_folder("secret")))
        # Older than that, or with the VM recorded, it is stopped.
        with open(self.in_folder("lock"), "w") as handle:
            handle.write(f"{holder} {int(time.time()) - 60}\n")
        self.assertEqual(self.run_script("stop").returncode, 0)
        self.assertTrue(self.ended(holder))

    def test_a_failed_start_lets_go_of_the_lock(self):
        done = self.run_script("start", FAKE_RUN_EXIT="1")
        self.assertEqual(done.returncode, 1)
        for name in ("secret", "port", "vm-name", "blocked-addresses"):
            self.assertFalse(os.path.exists(self.in_folder(name)), name)
        self.assertTrue(self.ended(self.holder_pid()))
        self.started()


class MacPythonTests(unittest.TestCase):
    """The Mac-side scripts run with /usr/bin/python3, which is 3.9: `X | None`
    and `list[str]` in annotations need `from __future__ import annotations`
    there (the server inside the VM runs 3.12 and does not)."""

    FOLDER = os.path.dirname(os.path.abspath(__file__))
    BUILTIN_GENERICS = {"list", "dict", "tuple", "set", "frozenset", "type"}

    def annotations(self, tree):
        import ast
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                arguments = node.args
                every = arguments.posonlyargs + arguments.args + arguments.kwonlyargs
                every += [a for a in (arguments.vararg, arguments.kwarg) if a]
                for argument in every:
                    if argument.annotation:
                        yield argument.annotation
                if node.returns:
                    yield node.returns
            elif isinstance(node, ast.AnnAssign):
                yield node.annotation

    def test_new_style_annotations_come_with_the_future_import(self):
        import ast
        import glob
        checked = 0
        for path in sorted(glob.glob(os.path.join(self.FOLDER, "*.py"))):
            with open(path, encoding="utf-8") as handle:
                tree = ast.parse(handle.read())
            future = any(isinstance(node, ast.ImportFrom) and node.module == "__future__"
                         and any(alias.name == "annotations" for alias in node.names)
                         for node in tree.body)
            new_style = []
            for annotation in self.annotations(tree):
                for part in ast.walk(annotation):
                    if isinstance(part, ast.BinOp) and isinstance(part.op, ast.BitOr):
                        new_style.append(part.lineno)
                    elif (isinstance(part, ast.Subscript) and isinstance(part.value, ast.Name)
                          and part.value.id in self.BUILTIN_GENERICS):
                        new_style.append(part.lineno)
            checked += 1
            with self.subTest(script=os.path.basename(path)):
                self.assertTrue(future or not new_style,
                                f"line(s) {new_style[:3]} need `from __future__ import annotations`")
        self.assertGreater(checked, 5)


class RecordedPortStrictnessTests(unittest.TestCase):
    """verify_sandbox_signature.recorded_port reads the port file as the app
    and the script do: yours, mode 0600 exactly, one line break at most."""

    def setUp(self):
        import importlib
        import sys
        folder = os.path.dirname(os.path.abspath(__file__))
        if folder not in sys.path:
            sys.path.insert(0, folder)
        self.signing = importlib.import_module("verify_sandbox_signature")
        self.folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.folder, True)
        self.secret = os.path.join(self.folder, "secret")
        self.port = os.path.join(self.folder, "port")

    def write(self, text, mode=0o600):
        with open(self.port, "w") as handle:
            handle.write(text)
        os.chmod(self.port, mode)

    def test_only_mode_0600_is_accepted(self):
        for mode, expected in ((0o600, 49152), (0o400, None), (0o640, None), (0o644, None),
                               (0o660, None), (0o700, None), (0o200, None)):
            self.write("49152\n", mode)
            self.assertEqual(self.signing.recorded_port(self.secret), expected, oct(mode))

    def test_at_most_one_line_break_and_a_port_from_1024(self):
        for text, expected in (("49152", 49152), ("49152\n", 49152), ("49152\n\n", None),
                               ("\n49152", None), ("1023\n", None), ("1024\n", 1024),
                               ("65535\n", 65535), ("65536\n", None), ("4915a\n", None), ("", None)):
            self.write(text)
            self.assertEqual(self.signing.recorded_port(self.secret), expected, repr(text))

    def test_a_fixed_port_follows_the_same_range(self):
        saved = os.environ.get("SANDSEEK_SANDBOX_PORT")
        self.addCleanup(lambda: os.environ.pop("SANDSEEK_SANDBOX_PORT", None) if saved is None
                        else os.environ.__setitem__("SANDSEEK_SANDBOX_PORT", saved))
        for text, expected in (("9555", 9555), ("1024", 1024), ("1023", None), ("80", None),
                               ("65536", None), ("12 3", None)):
            os.environ["SANDSEEK_SANDBOX_PORT"] = text
            self.assertEqual(self.signing.sandbox_port(self.secret), expected, text)


if __name__ == "__main__":
    unittest.main()
