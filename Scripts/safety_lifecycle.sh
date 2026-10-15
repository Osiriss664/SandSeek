#!/usr/bin/env bash
# SandSeek's safety test, the parts that start and stop the sandbox: a fake
# sandbox on the port, a crash of the lock holder, a stop, and a second starter
# (TUFF's parts D and F, without clicks).
#
#   Scripts/safety_lifecycle.sh [--running]
#
# Without --running it starts its own sandbox first and refuses (exit code 2)
# when a sandbox, lock holder or secret already exists, because it stops and
# restarts the sandbox and must never do that to the app's. --running says the
# sandbox that runs now belongs to the caller (Scripts/full_test.sh passes it
# for the one it started). The run ends with the sandbox stopped.
#
# In this order:
#   1. fake sandbox  stops the sandbox, answers on its port with a program that
#                    sends a plausible but unsigned /health body, and then one
#                    signed with a wrong key; the `sandseek` command must
#                    refuse both with a plain message, print no answer and
#                    send no question; then the sandbox is started again.
#                    `sandseek --server-type llamacpp` checks the sandbox
#                    before it contacts a model server, so no model server is
#                    needed. SKIP when the command is not built.
#   2. second starter  a second `start` while one runs is refused with the busy
#                    message and leaves the first alone.
#   3. crash         `kill -9` on the lock holder (identified by its command
#                    line); the next `start` must remove the left VM and files
#                    and come up with exactly one VM.
#   4. stop          zero sandseek VMs, no secret, port, vm-name or
#                    blocked-addresses file, no lock holder process, nothing
#                    listening on the old port.
#
# Environment (all optional):
#   SKIP_FAKE_SANDBOX=1      skip part 1
#   SKIP_LIFECYCLE=1         skip parts 2 to 4 (the sandbox is then left running)
#   SAFETY_SANDSEEK_BIN      the sandseek command (default .build/debug/sandseek,
#                            else .build/release/sandseek, in the checkout)
#   SAFETY_SANDBOX_SCRIPT    the start/stop script (default Scripts/research_sandbox.sh)
#   SAFETY_SECRET_FOLDER, SAFETY_CONTAINER  as for Scripts/safety_probe.sh
#
# Output: PASS, FAIL, NOTE and SKIP lines and "Result: N pass, M fail" last;
# exit code 0 only with no FAIL. Unattended: no input, no sudo, no clicks.
# Every call has a time limit. The secret is never printed.

set -u
set -f

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PY="${SAFETY_PYTHON:-python3}"
sandbox_sh="${SAFETY_SANDBOX_SCRIPT:-$here/research_sandbox.sh}"
secret_folder="${SAFETY_SECRET_FOLDER:-$HOME/Library/Application Support/SandSeek/sandbox}"
secret_file="$secret_folder/secret"
lock_marker=sandseek-lock-holder

running_given=0
case "${1:-}" in
  "") ;;
  --running) running_given=1 ;;
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
esac

passes=0; fails=0; notes=0; skips=0
pass() { passes=$((passes + 1)); printf '  PASS  %s\n' "$*"; }
fail() { fails=$((fails + 1)); printf '  FAIL  %s\n' "$*"; }
note() { notes=$((notes + 1)); printf '  NOTE  %s\n' "$*"; }
skip() { skips=$((skips + 1)); printf '  SKIP  %s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }
cut_() { local s="$*"; [ ${#s} -gt 240 ] && s="${s:0:240}..."; printf '%s' "$s"; }

CONTAINER="${SAFETY_CONTAINER:-}"
if [ -z "$CONTAINER" ]; then
  if [ -x /usr/local/bin/container ]; then CONTAINER=/usr/local/bin/container; else CONTAINER=container; fi
fi
for tool in "$CONTAINER" "$PY" ps kill awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "needs $tool" >&2; exit 99; }
done

sandseek_bin="${SAFETY_SANDSEEK_BIN:-}"
if [ -z "$sandseek_bin" ]; then
  for candidate in "$here/../.build/debug/sandseek" "$here/../.build/release/sandseek"; do
    if [ -x "$candidate" ]; then sandseek_bin="$candidate"; break; fi
  done
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/sandseek-lifecycle.XXXXXX")" || exit 2
fake_pid=""
finish() {
  trap - EXIT
  if [ -n "$fake_pid" ]; then kill "$fake_pid" 2>/dev/null; wait "$fake_pid" 2>/dev/null; fi
  rm -rf "$work"
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# --- helpers --------------------------------------------------------------------------

# limited SECONDS COMMAND...: no input; ended (with its children) after SECONDS, exit code 124.
limited() {
  local seconds="$1"; shift
  "$PY" -c '
import os, signal, subprocess, sys
process = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL, start_new_session=True)
try:
    sys.exit(process.wait(timeout=float(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    sys.exit(124)
' "$seconds" "$@"
}

sandbox() { limited "$1" /bin/bash "$sandbox_sh" "${@:2}"; }   # sandbox SECONDS ARGS...

sandseek_vms() { limited 60 "$CONTAINER" list --all --quiet 2>/dev/null | grep '^sandseek' || true; }
vm_count() { sandseek_vms | grep -c . || true; }
recorded_name() { head -c 64 "$secret_folder/vm-name" 2>/dev/null | tr -d '\n'; }
recorded_port() { head -c 16 "$secret_folder/port" 2>/dev/null | tr -d '\n'; }
holder_pid() { local pid _rest; read -r pid _rest <"$secret_folder/lock" 2>/dev/null || true; printf '%s' "${pid:-}"; }
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null && [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" != Z ]; }
holder_command_ok() { # PID: a lock holder of this lock file?
  local command
  command="$(ps -ww -o command= -p "$1" 2>/dev/null)" || return 1
  [[ "$command" == *"$lock_marker"*"$secret_folder/lock"* ]]
}
# The bracket keeps grep from finding its own command line.
holders_running() { ps -axww -o command= 2>/dev/null | grep -c "[${lock_marker:0:1}]${lock_marker:1}" || true; }
port_open() { "$PY" -c '
import socket, sys
s = socket.socket(); s.settimeout(2)
sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$1" 2>/dev/null; }

# Starts the sandbox; prints nothing on success. A failure is reported with the
# start script's last lines.
start_sandbox() { # LABEL
  local out rc
  out="$(sandbox 300 start 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$1: start failed with exit code $rc: $(cut_ "$(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')")"
    return 1
  fi
  return 0
}

state_files_left() {
  local left="" f
  for f in secret port vm-name blocked-addresses; do
    [ -e "$secret_folder/$f" ] && left="$left $f"
  done
  printf '%s' "${left# }"
}

# --- the sandbox this run works on ---------------------------------------------------------

printf 'SandSeek safety test: fake sandbox and lifecycle\n'
if [ "$running_given" = 1 ]; then
  name="$(recorded_name)"; port="$(recorded_port)"
  if [ -z "$name" ] || [ -z "$port" ] || ! sandseek_vms | grep -qxF "$name"; then
    echo "no sandbox to work on: --running was given, but no running sandbox is recorded in $secret_folder" >&2
    exit 2
  fi
else
  if [ -n "$(state_files_left)" ] || [ "$(vm_count)" != 0 ] || [ "$(holders_running)" != 0 ]; then
    echo "a sandbox, lock holder or secret exists already (the app's?). This test stops and restarts the sandbox, so it does not run on one it did not start. Stop it first (Scripts/research_sandbox.sh stop), or pass --running if it is yours." >&2
    exit 2
  fi
  head_ "start"
  if start_sandbox "start"; then
    pass "the sandbox started for this test"
  else
    printf '\nCounts: %d notes, %d skipped\nResult: %d pass, %d fail\n' "$notes" "$skips" "$passes" "$fails"
    exit 1
  fi
fi

# --- 1. fake sandbox ------------------------------------------------------------------------------

head_ "a fake sandbox on the sandbox's port"
if [ "${SKIP_FAKE_SANDBOX:-0}" = 1 ]; then
  skip "fake sandbox (SKIP_FAKE_SANDBOX=1)"
elif [ -z "$sandseek_bin" ] || [ ! -x "$sandseek_bin" ]; then
  skip "fake sandbox: the sandseek command is not built (swift build makes .build/debug/sandseek)"
else
  fake_port="$(recorded_port)"
  if [ -z "$fake_port" ]; then
    fail "fake sandbox: no recorded port to put the fake on"
  elif ! sandbox 180 stop >"$work/stop.out" 2>&1; then
    fail "fake sandbox: stopping the sandbox failed: $(cut_ "$(tail -n 2 "$work/stop.out" | tr '\n' ' ')")"
  else
    pass "the sandbox was stopped through its script; the fake takes its port $fake_port"
    # A secret of its own for this test: `stop` deleted the real one, and
    # without a secret file the command stops before it asks anything. The fake
    # does not know it, as a program that took over the port would not.
    "$PY" -c '
import os, sys
path = sys.argv[1]
temporary = path + ".fake"
descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w") as handle:
    handle.write(os.urandom(32).hex())
os.rename(temporary, path)' "$secret_file" 2>/dev/null || fail "fake sandbox: could not write a test secret file"
    for mode in unsigned wrongkey; do
      : >"$work/fake.log"
      "$PY" "$here/safety_fake_sandbox.py" "$fake_port" "$mode" "$work/fake.log" </dev/null >"$work/fake.out" 2>&1 &
      fake_pid=$!
      waited=0
      while ! port_open "$fake_port" && alive "$fake_pid" && [ "$waited" -lt 50 ]; do sleep 0.2; waited=$((waited + 1)); done
      if ! port_open "$fake_port"; then
        fail "fake sandbox ($mode): the fake did not start: $(cut_ "$(tail -n 2 "$work/fake.out" | tr '\n' ' ')")"
      else
        limited 120 "$sandseek_bin" --server-type llamacpp --server http://127.0.0.1:1 \
          --sandbox "http://127.0.0.1:$fake_port" "What is the capital of Australia?" \
          >"$work/cli.out" 2>"$work/cli.err"
        rc=$?
        errors="$(cat "$work/cli.err")"
        if [ "$rc" = 0 ] || [ -s "$work/cli.out" ]; then
          fail "fake sandbox ($mode): the command was NOT stopped by it (exit code $rc, $(wc -c <"$work/cli.out" | tr -d ' ') bytes of output)"
        elif grep -q 'FAKE-SANDBOX' "$work/cli.out" "$work/cli.err"; then
          fail "fake sandbox ($mode): text of the fake reached the output"
        elif grep -qiE 'fatal error|traceback|swift runtime|illegal instruction|segmentation' "$work/cli.err" || [ "$rc" -gt 2 ]; then
          fail "fake sandbox ($mode): the command crashed (exit code $rc) instead of refusing: $(cut_ "$errors")"
        elif ! grep -q '^error:' "$work/cli.err"; then
          fail "fake sandbox ($mode): no plain error message (exit code $rc): $(cut_ "$errors")"
        elif grep -q '^POST' "$work/fake.log"; then
          fail "fake sandbox ($mode): the command sent a request to the fake before it was sure of it: $(tr '\n' ';' <"$work/fake.log")"
        else
          pass "fake sandbox ($mode): refused (exit code $rc), no answer, no question sent; said: $(cut_ "$(grep '^error:' "$work/cli.err" | head -n 1)")"
        fi
      fi
      kill "$fake_pid" 2>/dev/null; wait "$fake_pid" 2>/dev/null; fake_pid=""
    done
    rm -f "$secret_file" "$secret_file.fake"
    note "the sandseek command has no separate health-check option; the app's own check (a fake sandbox while the app is open) stays a click part, see docs/SAFETY_TEST.md"
    note "the command's run needs no model server here: with --server-type llamacpp it checks the sandbox first"
    if start_sandbox "restart after the fake"; then
      n="$(vm_count)"
      if [ "$n" = 1 ]; then pass "the sandbox started again with exactly one VM ($(recorded_name))"; else fail "after the restart $n sandseek VMs exist (1 expected)"; fi
    else
      skip "second starter, crash and stop: the sandbox did not come back"
      SKIP_LIFECYCLE=1
    fi
  fi
fi

if [ "${SKIP_LIFECYCLE:-0}" = 1 ]; then
  head_ "lifecycle"
  skip "second starter, crash and stop (SKIP_LIFECYCLE=1 or no sandbox to work on)"
else
  # --- 2. second starter ---------------------------------------------------------------------------
  head_ "a second starter"
  name_before="$(recorded_name)"; holder_before="$(holder_pid)"
  if [ -z "$name_before" ] || ! sandseek_vms | grep -qxF "$name_before"; then
    fail "second starter: no sandbox runs to start a second one against"
  else
    out="$(sandbox 120 start 2>&1)"; rc=$?
    if [ "$rc" = 75 ] && [[ "$out" == *"Another SandSeek is using the web sandbox"* ]]; then
      pass "a second start was refused with exit code 75 and the busy message"
    else
      fail "a second start gave exit code $rc: $(cut_ "$(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')")"
    fi
    if [ "$(recorded_name)" = "$name_before" ] && [ "$(vm_count)" = 1 ] && alive "$holder_before"; then
      pass "the first sandbox is untouched: same VM, still one VM, same lock holder"
    else
      fail "the second start disturbed the first sandbox (VM $(recorded_name), $(vm_count) VMs, holder alive: $(alive "$holder_before" && echo yes || echo no))"
    fi
    if sandbox 60 status >/dev/null 2>&1; then pass "the first sandbox still answers"; else fail "the first sandbox does not answer after the second start"; fi
  fi

  # --- 3. crash ------------------------------------------------------------------------------------
  head_ "a crash of the lock holder"
  old_name="$(recorded_name)"; old_holder="$(holder_pid)"
  if [ -z "$old_holder" ] || ! alive "$old_holder"; then
    fail "crash: no live lock holder is recorded in $secret_folder/lock"
  elif ! holder_command_ok "$old_holder"; then
    fail "crash: process $old_holder is not the lock holder (its command line does not name $lock_marker and the lock file); not killing it"
  else
    kill -9 "$old_holder" 2>/dev/null
    waited=0
    while alive "$old_holder" && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
    if alive "$old_holder"; then
      fail "crash: the lock holder $old_holder survived kill -9"
    else
      if sandseek_vms | grep -qxF "$old_name"; then
        note "after the crash the VM $old_name is still there, as a crash leaves it"
      else
        note "after the crash the VM $old_name was already gone"
      fi
      if start_sandbox "start after the crash"; then
        new_name="$(recorded_name)"; new_holder="$(holder_pid)"
        [ "$(vm_count)" = 1 ] && pass "after the crash the next start came up with exactly one VM" || fail "after the crash $(vm_count) sandseek VMs exist: $(sandseek_vms | tr '\n' ' ')"
        if [ -n "$new_name" ] && [ "$new_name" != "$old_name" ] && ! sandseek_vms | grep -qxF "$old_name"; then
          pass "the VM the crash left ($old_name) was removed; the new one is $new_name"
        else
          fail "the VM the crash left ($old_name) is still there, or the name did not change (now $new_name)"
        fi
        if [ -n "$new_holder" ] && [ "$new_holder" != "$old_holder" ] && alive "$new_holder" && holder_command_ok "$new_holder"; then
          pass "a new lock holder ($new_holder) runs"
        else
          fail "no new lock holder runs after the restart (recorded: ${new_holder:-none})"
        fi
        if [ -f "$secret_file" ] && [ -n "$(recorded_port)" ] && [ -s "$secret_folder/blocked-addresses" ]; then
          pass "secret, port and address files exist again"
        else
          fail "files are missing after the restart: stale or absent secret, port or blocked-addresses"
        fi
      else
        skip "stop: the sandbox did not come back after the crash"
      fi
    fi
  fi

  # --- 4. stop -------------------------------------------------------------------------------------
  head_ "stop"
  old_port="$(recorded_port)"; old_holder="$(holder_pid)"
  out="$(sandbox 180 stop 2>&1)"; rc=$?
  if [ "$rc" = 0 ]; then pass "stop finished (exit code 0)"; else fail "stop gave exit code $rc: $(cut_ "$(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')")"; fi
  n="$(vm_count)"
  [ "$n" = 0 ] && pass "zero sandseek VMs remain" || fail "$n sandseek VM(s) remain: $(sandseek_vms | tr '\n' ' ')"
  left="$(state_files_left)"
  [ -z "$left" ] && pass "no secret, port, vm-name or blocked-addresses file remains" || fail "files remain after stop: $left"
  if [ "$(holders_running)" = 0 ] && ! alive "$old_holder"; then
    pass "no lock holder process remains"
  else
    fail "a lock holder process remains (${old_holder:-unknown pid}; $(holders_running) with the marker)"
  fi
  if [ -z "$old_port" ]; then
    note "no port was recorded before the stop, so the old port was not looked at"
  elif port_open "$old_port"; then
    fail "something still listens on the old port $old_port"
  else
    pass "nothing listens on the old port $old_port"
  fi
fi

printf '\nCounts: %d notes, %d skipped\n' "$notes" "$skips"
printf 'Result: %d pass, %d fail\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
