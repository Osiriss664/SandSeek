#!/usr/bin/env bash
# One command for every SandSeek check that needs no clicking.
#
#   Scripts/full_test.sh [--quick] [--no-sandbox] [--thorough]
#                        [--server URL] [--api-key-file FILE]
#                        [--start-server TUFFSERVER [--models FOLDER]]
#                        [--injection-base-url URL] [--time-limit MINUTES]
#                        [--take-over-sandbox]
#
# Run it in the background (nohup or a background job) when a caller cuts
# commands after a few minutes; poll for the last line FULL_TEST_REPORT=<path>.
#
# It builds, runs the unit tests, packages the app, starts the web sandbox in
# its Apple container VM, checks it, asks one real research question if a model
# server answers, and stops everything again. Every step has a time limit and a
# log. The result is a table (report.md), the same as JSON (report.json) and a
# one-screen summary. The last line printed is FULL_TEST_REPORT=<path of
# report.json>. Exit 0 only when no step FAILED.
#
# Unattended: no child reads standard input (all get /dev/null), nothing asks
# for sudo, and the run never starts the container service's kernel setup
# dialog (if `container system start` cannot finish without input, the step
# fails with a note). No clicks, no AppleScript, no accessibility automation.
#
#   --quick          skip packaging when build/SandSeek.app exists and skip the
#                    image build when the sandbox image exists
#   --no-sandbox     only build and unit tests (steps 1 to 3)
#   --thorough       also ask one Thorough question (longer limit; --max-steps 30
#                    --min-pages 6 --search-results 8). The Quick question uses the
#                    CLI defaults, which equal the app's Quick preset.
#   --server URL     model server for step 6 (default $SANDSEEK_MODEL_SERVER or
#                    http://127.0.0.1:8080). Without an answering server, step 6
#                    and 7 are SKIP; this script never starts a model server on
#                    its own unless --start-server is given.
#   --api-key-file F key file of a model server that asks for a key (passed to
#                    sandseek; its content is masked in every log and report)
#   --start-server P starts TUFFServer (P is TUFFServer, tuff or TUFF.app) on
#                    127.0.0.1 and a free port, the way the app does (fixed
#                    argument list, clean environment, no shell), waits for it,
#                    uses it for step 6, and stops it, by its process id only,
#                    at the end, after a failure, on Ctrl-C and on time-out
#                    It refuses to start when a model server already answers
#                    (here or on 127.0.0.1:8080) or a TUFFServer or llama-server
#                    process runs: one model at a time on a 16 GB Mac.
#   --models F       absolute, existing models folder for --start-server
#                    (TUFFServer --models-root); a usage error without it
#   --take-over-sandbox
#                    by default the run FAILS step 5 when a sandbox is already
#                    running (the app's: secret file, listener on the port or a
#                    sandseek-sandbox container); this flag stops it
#                    (`research_sandbox.sh stop`) before the start and again at
#                    the end. Without the flag the run never stops a sandbox it
#                    did not start itself
#   --injection-base-url URL
#                    public URL of Sandbox/fixtures/injection for step 7
#   --time-limit M   limit of the whole run in minutes (default 60); when it is
#                    reached the cleanup runs and the run fails (exit 124)
#
# Expected run time on an M-series Mac: debug build 1 to 5 min, swift test 1 to
# 5 min, Python tests under 1 min, packaging (release build) 3 to 8 min, image
# build 3 to 15 min (first time), sandbox start 10 to 30 s, selftest and checks
# 1 to 3 min, a Quick question 1 to 5 min, a Thorough one 5 to 20 min, stop 10
# s. About 15 to 35 min in all with an empty cache, 5 to 15 min with --quick.
#
# Exit codes: 0 no step failed, 1 a step failed, 124 whole-run time limit,
# 130 Ctrl-C (INT), 143 TERM. Usage errors exit 2 and print no report line.
# Every exit except a usage error prints FULL_TEST_REPORT=<path> as last line.
#
# For the tests in Scripts/test_full_test.py the commands can be replaced:
# SANDSEEK_FULL_TEST_FAKE=1 skips the macOS check, FT_SWIFT, FT_CONTAINER,
# FT_CODESIGN, FT_CURL, FT_GIT, FT_PGREP and FT_SECRET_FOLDER name other programs and
# folders, and FULL_TEST_TIME_LIMIT_SECONDS replaces --time-limit.

set -u

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$script_directory/.." && pwd)"
helpers="$script_directory/full_test_helpers.py"
PY="${FT_PYTHON:-python3}"

quick=0 no_sandbox=0 thorough=0
model_server="${SANDSEEK_MODEL_SERVER:-http://127.0.0.1:8080}"
api_key_file="${SANDSEEK_API_KEY_FILE:-}"
take_over=0 start_server="" models_folder="" injection_base="${FT_INJECTION_BASE_URL:-}"
time_limit_minutes=60

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' | head -n 80; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) quick=1 ;;
    --no-sandbox) no_sandbox=1 ;;
    --thorough) thorough=1 ;;
    --take-over-sandbox) take_over=1 ;;
    --server) model_server="${2:?--server needs a URL}"; shift ;;
    --api-key-file) api_key_file="${2:?--api-key-file needs a path}"; shift ;;
    --start-server) start_server="${2:?--start-server needs a path}"; shift ;;
    --models) models_folder="${2:?--models needs a folder}"; shift ;;
    --injection-base-url) injection_base="${2:?needs a URL}"; shift ;;
    --time-limit) time_limit_minutes="${2:?--time-limit needs minutes}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
if [[ -n "$models_folder" ]]; then
  [[ -n "$start_server" ]] || { echo "--models needs --start-server" >&2; exit 2; }
  [[ "$models_folder" == /* && -d "$models_folder" ]] || { echo "--models must be an absolute, existing folder: $models_folder" >&2; exit 2; }
fi
[[ "$time_limit_minutes" =~ ^[0-9]+$ ]] || { echo "--time-limit must be a number of minutes" >&2; exit 2; }
total_limit="${FULL_TEST_TIME_LIMIT_SECONDS:-$((time_limit_minutes * 60))}"

SWIFT="${FT_SWIFT:-swift}"
CONTAINER="${FT_CONTAINER:-/usr/local/bin/container}"
CODESIGN="${FT_CODESIGN:-codesign}"
CURL="${FT_CURL:-curl}"
GIT="${FT_GIT:-git}"
PGREP="${FT_PGREP:-pgrep}"
SANDBOX_SH="$ROOT/Scripts/research_sandbox.sh"
# The sandbox's port on the Mac. SANDSEEK_SANDBOX_PORT fixes it; otherwise
# `start` picks a free one, and it is read from the sandbox folder after the
# start (empty until then).
PORT="${SANDSEEK_SANDBOX_PORT:-}"
secret_folder="${FT_SECRET_FOLDER:-$HOME/Library/Application Support/SandSeek/sandbox}"
secret_file="$secret_folder/secret"
app="$ROOT/build/SandSeek.app"
sandseek_bin="${FT_SANDSEEK_BIN:-$ROOT/.build/debug/sandseek}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
RUN="$ROOT/build/full-test/$stamp"
n=1
while [[ -e "$RUN" ]]; do RUN="$ROOT/build/full-test/$stamp-$n"; n=$((n + 1)); done
mkdir -p "$RUN/logs" || exit 2
: > "$RUN/results.tsv"
FT_NOTE_FILE="$RUN/note.txt"
FT_MASK_FILES="$secret_file${api_key_file:+:$api_key_file}"
export ROOT RUN PORT SWIFT CONTAINER CODESIGN CURL GIT SANDBOX_SH FT_NOTE_FILE FT_MASK_FILES \
       app sandseek_bin secret_file secret_folder PY

CHILD="" ABORT="" ABORT_CODE=0 CUR_ID="" CUR_NAME="" CUR_START=0
CLEANED=0 SANDBOX_TOUCHED=0 BUILDER_TOUCHED=0 CTL_RC=0 CTL_OUT="" SANDBOX_UP=0 SERVER_PID="" SERVER_PATH="" WATCHDOG=""
SERVER_URL="$model_server"

clean_field() { printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300; }

record() { # id name result seconds note log
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(clean_field "$5")" "${6:-}" >> "$RUN/results.tsv"
  printf '  %-5s %s %s%s\n' "$3" "$1" "$2" "${5:+  ($(clean_field "$5" | cut -c1-80))}" >&2
}

skip() { record "$1" "$2" SKIP 0 "$3"; }

# step ID NAME LIMIT_SECONDS COMMAND [NOTE_COMMAND]
# COMMAND runs in `bash -c` with stdin from /dev/null, output in the step's
# log. NOTE_COMMAND runs afterwards with $LOG set; its output is the note of a
# PASS. The command may write a note to $FT_NOTE_FILE.
step() {
  local id="$1" name="$2" limit="$3" command="$4" notecmd="${5:-}" log rc note
  log="$RUN/logs/$id.log"
  CUR_ID="$id" CUR_NAME="$name" CUR_START=$SECONDS
  : > "$FT_NOTE_FILE"
  "$PY" "$helpers" run "$log" "$limit" /bin/bash -c "set -eo pipefail; $command" &
  CHILD=$!
  wait "$CHILD"; rc=$?
  CHILD=""
  note="$(cat "$FT_NOTE_FILE" 2>/dev/null)"
  if [[ $rc -eq 0 ]]; then
    if [[ -n "$notecmd" ]]; then
      note="$(LOG="$log" /bin/bash -c "$notecmd" 2>/dev/null </dev/null | head -n 3 | tr '\n' ' ')${note:+ $note}"
    fi
    record "$id" "$name" PASS $((SECONDS - CUR_START)) "$note" "$log"
  elif [[ $rc -eq 124 ]]; then
    record "$id" "$name" FAIL $((SECONDS - CUR_START)) "time limit of ${limit} s reached" "$log"
  else
    record "$id" "$name" FAIL $((SECONDS - CUR_START)) "exit code $rc${note:+; $note}" "$log"
  fi
  CUR_ID=""
  return $rc
}

# ctl NAME LIMIT PROGRAM [ARGS...]: one short call with a time limit; the output
# goes to logs/NAME.log and into CTL_OUT, the status into CTL_RC.
ctl() {
  local log="$RUN/logs/$1.log" limit="$2"
  shift 2
  "$PY" "$helpers" run "$log" "$limit" "$@" &
  CHILD=$!; wait "$CHILD"; CTL_RC=$?; CHILD=""
  CTL_OUT="$(cat "$log" 2>/dev/null || true)"
  return 0
}

failed_any() { grep -q "$(printf '\tFAIL\t')" "$RUN/results.tsv"; }

# ---- model server we started ------------------------------------------------

stop_model_server() {
  [[ -n "$SERVER_PID" ]] || return 0
  # Only our own process: the pid we recorded, and only while it still runs
  # the program we started.
  if kill -0 "$SERVER_PID" 2>/dev/null \
     && ps -p "$SERVER_PID" -o command= 2>/dev/null | grep -qF -- "$SERVER_PATH"; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    local waited=0
    while kill -0 "$SERVER_PID" 2>/dev/null && (( waited < 20 )); do sleep 0.5; waited=$((waited + 1)); done
    kill -0 "$SERVER_PID" 2>/dev/null && kill -KILL "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}

resolve_server_path() {
  local pick="${1%/}" name
  name="$(basename -- "$pick")"
  case "$name" in
    *.app|*.App) printf '%s' "$pick/Contents/Resources/bin/TUFFServer" ;;
    tuff) printf '%s' "$(dirname -- "$pick")/TUFFServer" ;;
    TUFFServer) printf '%s' "$pick" ;;
    *) return 1 ;;
  esac
}

start_model_server() { # records step 6.0
  local begin=$SECONDS port home tmp args wait_limit="${FT_SERVER_WAIT:-180}" code
  # One model at a time on a 16 GB Mac: never start a second server.
  local busy="" url
  for url in "$model_server" "http://127.0.0.1:8080"; do
    code="$("$PY" "$helpers" http-code "${url%/}/tuff/v1/status")"
    if [[ "$code" != 000 ]]; then busy="a model server already answers at $url"; break; fi
  done
  if [[ -z "$busy" ]]; then
    local program
    for program in TUFFServer llama-server; do
      if "$PGREP" -x "$program" >/dev/null 2>&1 </dev/null; then busy="a $program process is already running"; break; fi
    done
  fi
  if [[ -n "$busy" ]]; then
    record 6.0 "start model server" FAIL 0 "$busy; not starting a second one (16 GB Mac: one model at a time). Stop it or use --server."
    return 1
  fi
  SERVER_PATH="$(resolve_server_path "$start_server")" && [[ "$SERVER_PATH" == /* && -x "$SERVER_PATH" ]] || {
    record 6.0 "start model server" FAIL 0 "not a runnable TUFFServer, tuff or TUFF.app with a full path: $start_server"
    SERVER_PATH=""; return 1; }
  port="$("$PY" "$helpers" free-port)"
  home="$("$PY" "$helpers" home)"
  tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"; tmp="${tmp:-/tmp/}"
  args=(--port "$port")
  if [[ -n "$models_folder" ]]; then args+=(--models-root "$models_folder"); fi
  # The app's launch plan: no shell, 127.0.0.1, an environment with PATH, HOME
  # and TMPDIR only.
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$home" TMPDIR="$tmp" \
      "$SERVER_PATH" "${args[@]}" </dev/null >"$RUN/logs/6.0.log" 2>&1 &
  SERVER_PID=$!
  while (( SECONDS - begin < wait_limit )); do
    code="$("$PY" "$helpers" http-code "http://127.0.0.1:$port/tuff/v1/status")"
    if [[ "$code" == 200 ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
      SERVER_URL="http://127.0.0.1:$port"
      record 6.0 "start model server" PASS $((SECONDS - begin)) "answering on port $port (pid $SERVER_PID)" "$RUN/logs/6.0.log"
      return 0
    fi
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 1
  done
  record 6.0 "start model server" FAIL $((SECONDS - begin)) "no answer from the started server within ${wait_limit} s" "$RUN/logs/6.0.log"
  stop_model_server
  return 1
}

# ---- cleanup (step 8, and the trap) -------------------------------------------

do_cleanup() { # id name
  local id="$1" name="$2" begin=$SECONDS problems="" count touched=0
  # Nothing may interrupt this: a signal now would leave the VM and the secret.
  trap '' INT TERM USR1
  export FT_RUN_IMMUNE=1
  stop_model_server
  if [[ $SANDBOX_TOUCHED -eq 1 || $BUILDER_TOUCHED -eq 1 ]]; then touched=1; fi
  if [[ $SANDBOX_TOUCHED -eq 1 ]]; then
    "$PY" "$helpers" run "$RUN/logs/$id-stop.log" 180 /bin/bash "$SANDBOX_SH" stop &
    CHILD=$!; wait "$CHILD"; CHILD=""
    # A second attempt that cannot hurt: the VM and the secret must be gone.
    if [[ -x "$CONTAINER" ]]; then
      ctl "$id-list" 30 "$CONTAINER" list --all --quiet
      count="$(printf '%s\n' "$CTL_OUT" | grep -c sandseek || true)"
      if [[ "${count:-0}" -gt 0 ]]; then
        # Every VM named sandseek-sandbox or sandseek-sandbox-<8 hex digits>.
        for leftover in $(printf '%s\n' "$CTL_OUT" | grep -E '^sandseek-sandbox(-[0-9a-f]{8})?$' || true); do
          ctl "$id-force-stop" 30 "$CONTAINER" stop "$leftover"
          ctl "$id-force-delete" 30 "$CONTAINER" delete "$leftover"
        done
        ctl "$id-list2" 30 "$CONTAINER" list --all --quiet
        count="$(printf '%s\n' "$CTL_OUT" | grep -c sandseek || true)"
        [[ "${count:-0}" -eq 0 ]] || problems="$problems $count sandseek container(s) left;"
      fi
    fi
    [[ ! -e "$secret_file" ]] || problems="$problems secret file left in the sandbox folder;"
    if [[ -n "$PORT" ]] && "$PY" "$helpers" listening "$PORT"; then problems="$problems something still listens on port $PORT;"; fi
  fi
  if [[ $BUILDER_TOUCHED -eq 1 && -x "$CONTAINER" ]]; then
    # The image build starts Apple's builder VM; a build that ran into its time
    # limit leaves it running.
    ctl "$id-builder-stop" 60 "$CONTAINER" builder stop
    ctl "$id-builder-status" 30 "$CONTAINER" builder status --quiet
    if [[ $CTL_RC -eq 0 && -n "$(printf '%s' "$CTL_OUT" | tr -d '[:space:]')" ]]; then
      problems="$problems the builder VM is still running;"
    fi
  fi
  if [[ -n "$problems" ]]; then
    record "$id" "$name" FAIL $((SECONDS - begin)) "$problems" "$RUN/logs/$id-stop.log"
  elif [[ $touched -eq 1 ]]; then
    record "$id" "$name" PASS $((SECONDS - begin)) "no container, builder, secret or listener left" "$RUN/logs/$id-stop.log"
  else
    skip "$id" "$name" "the sandbox was never started"
  fi
  CLEANED=1
}

# ---- finish -------------------------------------------------------------------

finish() {
  local code=$? overall=PASS
  trap '' INT TERM USR1
  trap - EXIT
  [[ -z "$WATCHDOG" ]] || { pkill -P "$WATCHDOG" 2>/dev/null; kill "$WATCHDOG" 2>/dev/null; }
  if [[ -n "$CHILD" ]]; then kill -TERM "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; CHILD=""; fi
  if [[ -n "$CUR_ID" ]]; then
    record "$CUR_ID" "$CUR_NAME" FAIL $((SECONDS - CUR_START)) "${ABORT:-stopped}" "$RUN/logs/$CUR_ID.log"
    CUR_ID=""
  fi
  # Mask while the secret file still exists; a killed step never ran its trap.
  "$PY" "$helpers" mask-files "$RUN"/answer-*.txt "$RUN"/logs/*.progress 2>/dev/null || true
  [[ $CLEANED -eq 1 ]] || do_cleanup 9 "cleanup after abort"
  if [[ -n "$ABORT" ]] || failed_any; then overall=FAIL; fi
  "$PY" "$helpers" report "$RUN" "$overall" "$ABORT"
  echo "FULL_TEST_REPORT=$RUN/report.json"
  if [[ -n "$ABORT" ]]; then exit "$ABORT_CODE"; fi
  [[ $overall == PASS ]] && exit 0
  exit 1
}
trap finish EXIT
trap 'ABORT="interrupted"; ABORT_CODE=130; exit 130' INT
trap 'ABORT="terminated"; ABORT_CODE=143; exit 143' TERM
trap 'ABORT="whole-run time limit of ${total_limit} s reached"; ABORT_CODE=124; exit 124' USR1
( sleep "$total_limit"; kill -USR1 $$ 2>/dev/null ) </dev/null >/dev/null 2>&1 &
WATCHDOG=$!

echo "SandSeek full test, run folder $RUN" >&2

# ---- 1. preconditions ----------------------------------------------------------
begin=$SECONDS; notes=""; bad=""
if [[ "${SANDSEEK_FULL_TEST_FAKE:-}" != 1 && "$(uname -s)" != Darwin ]]; then bad="$bad not macOS;"; fi
command -v "$SWIFT" >/dev/null 2>&1 || bad="$bad no swift;"
command -v "$PY" >/dev/null 2>&1 || bad="$bad no python3;"
if [[ $no_sandbox -eq 0 && ! -x "$CONTAINER" ]]; then bad="$bad $CONTAINER missing;"; fi
dirty="$("$GIT" -C "$ROOT" status --porcelain 2>/dev/null </dev/null | wc -l | tr -d ' ')"
if [[ "${dirty:-0}" -gt 0 ]]; then notes="warning: $dirty uncommitted change(s) in the tree"; fi
if [[ -n "$bad" ]]; then record 1 preconditions FAIL $((SECONDS - begin)) "$bad $notes"
else record 1 preconditions PASS $((SECONDS - begin)) "$notes"; fi

# ---- 2. swift --------------------------------------------------------------------
step 2.1 "swift build" 1800 'cd "$ROOT" && "$SWIFT" build' || true
step 2.2 "swift test" 1800 'cd "$ROOT" && "$SWIFT" test' \
  'grep -Eo "Executed [0-9]+ tests?|Test run with [0-9]+ tests?" "$LOG" | tail -2' || true

# ---- 3. python and shell ----------------------------------------------------------
step 3.1 "sandbox unit tests" 600 \
  'cd "$ROOT/Sandbox" && "$PY" -m unittest test_server
   for f in test_*.py; do [ "$f" = test_server.py ] || "$PY" -m unittest "${f%.py}"; done' \
  'grep -E "^Ran [0-9]+ tests?" "$LOG" | tr "\n" ";"' || true
step 3.2 "research script tests" 600 'cd "$ROOT" && "$PY" Scripts/test_research_sandbox.py' \
  'grep -E "^Ran [0-9]+ tests?" "$LOG"' || true
step 3.3 "bash -n on scripts" 60 \
  'cd "$ROOT"; for f in Scripts/*.sh; do /bin/bash -n "$f" && echo "ok $f"; done' \
  'grep -c "^ok " "$LOG" | sed "s/$/ scripts/"' || true

if [[ $no_sandbox -eq 1 ]]; then
  for pair in "4|package and sign app" "5|sandbox" "6|research question" "7|injection check"; do
    skip "${pair%%|*}" "${pair#*|}" "--no-sandbox"
  done
  do_cleanup 8 "stop and leftovers"
  exit 0
fi

# ---- 4. package ---------------------------------------------------------------------
if [[ $quick -eq 1 && -d "$app" ]]; then
  skip 4.1 "package app" "--quick and build/SandSeek.app exists"
else
  step 4.1 "package app" 2400 'cd "$ROOT" && /bin/bash Scripts/package_app.sh' || true
fi
if [[ -d "$app" ]]; then
  step 4.2 "codesign verify" 120 '"$CODESIGN" --verify --deep --strict "$app"' || true
  step 4.3 "icon in Info.plist" 60 \
    '"$PY" - "$app" <<PYEOF
import os, plistlib, sys
app = sys.argv[1]
with open(os.path.join(app, "Contents", "Info.plist"), "rb") as handle:
    icon = plistlib.load(handle).get("CFBundleIconFile")
assert icon, "CFBundleIconFile is missing"
resources = os.path.join(app, "Contents", "Resources")
assert any(os.path.isfile(os.path.join(resources, icon + ext)) for ext in ("", ".icns")), "icon file " + icon + " is missing"
print("icon", icon)
PYEOF' || true
else
  skip 4.2 "codesign verify" "no app bundle"
  skip 4.3 "icon in Info.plist" "no app bundle"
fi

# ---- 5. sandbox ---------------------------------------------------------------------
sandbox_ready=0
skip_sandbox_steps() { # reason, ids...
  local why="$1" sid; shift
  for sid in "$@"; do skip "$sid" "sandbox step" "$why"; done
}
if [[ ! -x "$CONTAINER" ]]; then
  skip_sandbox_steps "no container program at $CONTAINER" 5.0 5.1 5.2 5.3 5.4 5.5 5.6 5.7
else
  # Never take over a sandbox the app started.
  conflict=""
  if [[ $take_over -eq 0 ]]; then
    if [[ -e "$secret_file" ]]; then conflict="the secret file exists"
    elif [[ -n "$PORT" ]] && "$PY" "$helpers" listening "$PORT"; then conflict="something listens on port $PORT"
    else
      ctl 5.0-existing 30 "$CONTAINER" list --all --quiet
      if printf '%s\n' "$CTL_OUT" | grep -q sandseek-sandbox; then conflict="a sandseek-sandbox container exists"; fi
    fi
  fi
  if [[ -n "$conflict" ]]; then
    record 5.0 "sandbox already running" FAIL 0 "A sandbox is already running (the app's?) ($conflict). Press Stop everything in SandSeek first, or pass --take-over-sandbox."
    skip_sandbox_steps "a sandbox is already running" 5.1 5.2 5.3 5.4 5.5 5.6 5.7
  else
  # The service must run; starting it must not wait for a person.
  if step 5.0 "container service" 180 \
    '"$CONTAINER" system status >/dev/null 2>&1 || "$CONTAINER" system start
     "$CONTAINER" system status >/dev/null 2>&1 || { echo "the container service is not running and could not be started without input; run: container system start" > "$FT_NOTE_FILE"; exit 1; }'; then
    # Is Apple's builder VM idle now? Then a build that gets cut off by its
    # time limit leaves it behind, and cleanup stops it (like research_sandbox.sh).
    builder_idle=0
    ctl 5.0-builder 30 "$CONTAINER" builder status --quiet
    if [[ $CTL_RC -eq 0 && -z "$(printf '%s' "$CTL_OUT" | tr -d '[:space:]')" ]]; then builder_idle=1; fi
    image_present=0
    if [[ $quick -eq 1 ]]; then
      ctl 5.1-image 30 "$CONTAINER" image list
      if printf '%s\n' "$CTL_OUT" | grep -q sandseek-sandbox; then image_present=1; fi
    fi
    if [[ $image_present -eq 1 ]]; then
      ctl 5.1-inspect 30 "$CONTAINER" image inspect sandseek-sandbox
      stale="$("$PY" "$helpers" image-age "$RUN/logs/5.1-inspect.log" "$ROOT/Sandbox" 2>/dev/null || true)"
      skip 5.1 "sandbox image build" "--quick and the image exists${stale:+; $stale}"
    else
      [[ $builder_idle -eq 0 ]] || BUILDER_TOUCHED=1
      step 5.1 "sandbox image build" 2700 '/bin/bash "$SANDBOX_SH" build' || true
    fi
    SANDBOX_TOUCHED=1   # the check passed and the start is attempted now
    if [[ $take_over -eq 1 ]]; then
      # The sandbox that is running (the app's, or another run's) holds the
      # lock, and `start` would stop at once with exit code 75. Stop it first,
      # as asked. Whatever this says, the start below decides.
      ctl 5.2-take-over 180 /bin/bash "$SANDBOX_SH" stop
    fi
    start_rc=0
    step 5.2 "sandbox start" 300 '/bin/bash "$SANDBOX_SH" start' || start_rc=$?
    if [[ $start_rc -ne 0 && $start_rc -ne 124 && $take_over -eq 0 ]]; then
      # `start` failed on its own (busy, exit code 75, or before it took the
      # lock) and cleaned up after itself. Whatever runs now is not ours: the
      # cleanup must not stop it. (A start cut off by its time limit leaves its
      # lock holder behind, so that case stays ours.)
      SANDBOX_TOUCHED=0
    fi
    if [[ $start_rc -eq 0 ]]; then
      sandbox_ready=1
      # The port `start` picked (digits only, 1024 to 65535), recorded beside the
      # secret: one final line break at most, like the app reads it.
      if [[ -z "$PORT" ]]; then
        nl=$'\n'
        PORT="$(head -c 64 "$secret_folder/port" 2>/dev/null; printf x)"
        PORT="${PORT%x}"
        PORT="${PORT%"$nl"}"
        if [[ "$PORT" =~ ^[0-9]{4,5}$ ]] && (( 10#$PORT >= 1024 && 10#$PORT <= 65535 )); then
          PORT=$((10#$PORT))
          export PORT
        else
          PORT=""
          sandbox_ready=0
          echo "the sandbox started but recorded no usable port in $secret_folder/port" > "$FT_NOTE_FILE"
        fi
      fi
    fi
  else
    skip_sandbox_steps "container service not running" 5.1 5.2
  fi
  if [[ $sandbox_ready -eq 1 ]]; then
    step 5.3 "sandbox status" 60 '/bin/bash "$SANDBOX_SH" status' || true
    step 5.4 "sandbox selftest" 900 \
      'out="$(/bin/bash "$SANDBOX_SH" selftest 2>&1)" && rc=0 || rc=$?
       printf "%s\n" "$out"
       [ "$rc" -eq 0 ]
       if printf "%s\n" "$out" | grep -qE "^[[:space:]]*FAIL"; then exit 1; fi
       ok="$(printf "%s\n" "$out" | grep -cE "^[[:space:]]*(ok|PASS)" || true)"
       [ "${ok:-0}" -gt 0 ]
       echo "$ok checks passed" > "$FT_NOTE_FILE"' || true
    step 5.5 "unsigned request gives 401" 60 \
      'code="$("$CURL" -s --noproxy "*" -o /dev/null -w "%{http_code}" --max-time 15 "http://127.0.0.1:$PORT/health" </dev/null)"
       echo "HTTP $code"; [ "$code" = 401 ]' || true
    step 5.6 "signed answer verifies" 60 '"$PY" "$ROOT/Scripts/verify_sandbox_signature.py" "$secret_file" "$PORT"' || true
    step 5.7 "address checks" 900 \
      '"$PY" "$ROOT/Scripts/research_address_check.py" --label full-test --sandbox "http://127.0.0.1:$PORT" --secret-file "$secret_file" --output "$RUN/address-check.txt"' || true
  else
    skip_sandbox_steps "the sandbox did not start" 5.3 5.4 5.5 5.6 5.7
  fi
  fi
fi

# ---- 6. research question --------------------------------------------------------------
model_up=0
if [[ -n "$start_server" ]]; then
  if [[ $sandbox_ready -eq 1 ]] && start_model_server; then model_up=1; fi
  [[ $sandbox_ready -eq 1 ]] || skip 6.0 "start model server" "the sandbox is not running"
elif [[ "$("$PY" "$helpers" http-code "$SERVER_URL/tuff/v1/status")" != 000 ]]; then
  model_up=1
fi

research_args() { # mode
  local args=(--server "$SERVER_URL" --sandbox "http://127.0.0.1:$PORT")
  if [[ -n "$api_key_file" ]]; then args+=(--api-key-file "$api_key_file"); fi
  # Quick: the CLI defaults, which equal the app's Quick preset (8 steps, 3 pages,
  # 5 results). Thorough: the app's Thorough preset.
  if [[ "$1" == thorough ]]; then args+=(--max-steps 30 --min-pages 6 --search-results 8); fi
  printf '%s\n' "${args[@]}"
}

ask() { # id name limit mode question expected_regex
  local id="$1" name="$2" limit="$3" mode="$4" question="$5" expect="$6" args=() line
  while IFS= read -r line; do args+=("$line"); done < <(research_args "$mode")
  export FT_Q="$question" FT_EXPECT="$expect" FT_ARGS_FILE="$RUN/args-$id.txt"
  printf '%s\n' "${args[@]}" > "$FT_ARGS_FILE"
  step "$id" "$name" "$limit" \
    'args=(); while IFS= read -r l; do args+=("$l"); done < "$FT_ARGS_FILE"
     out="$RUN/answer-'"$id"'.txt"; prog="$RUN/logs/'"$id"'.progress"
     # The model server key and the sandbox secret must not stay in these files.
     trap '"'"'for f in "$out" "$prog"; do [ -f "$f" ] && "$PY" "$ROOT/Scripts/full_test_helpers.py" mask < "$f" > "$f.m" && mv "$f.m" "$f"; done'"'"' EXIT
     "$sandseek_bin" "$FT_Q" "${args[@]}" > "$out" 2> "$prog" || { tail -n 20 "$prog"; exit 1; }
     cat "$out"
     while IFS= read -r rx; do
       [ -n "$rx" ] || continue
       grep -qiE "$rx" "$out" || { echo "answer does not match: $rx" > "$FT_NOTE_FILE"; exit 1; }
     done <<EXPECT_EOF
$FT_EXPECT
EXPECT_EOF
     grep -qE "^[[:space:]]*(\[1\]|1[.)])" "$out" || { echo "no numbered source in the answer" > "$FT_NOTE_FILE"; exit 1; }' || true
}

if [[ $sandbox_ready -ne 1 ]]; then
  skip 6.1 "quick question" "the sandbox is not running"
  [[ $thorough -eq 0 ]] || skip 6.2 "thorough question" "the sandbox is not running"
elif [[ $model_up -ne 1 ]]; then
  skip 6.1 "quick question" "${start_server:+see step 6.0: }no model server answers at $SERVER_URL (use --start-server or --server)"
  [[ $thorough -eq 0 ]] || skip 6.2 "thorough question" "no model server answers at $SERVER_URL"
else
  ask 6.1 "quick question" 900 quick "What is the capital of Australia?" "Canberra"
  if [[ $thorough -eq 1 ]]; then
    ask 6.2 "thorough question" 2400 thorough \
      "Compare the population and the area of Iceland and Ireland, with sources." "Iceland
Ireland"
  fi
fi

# ---- 7. injection check -------------------------------------------------------------------
if [[ $sandbox_ready -ne 1 ]]; then skip 7 "injection check" "the sandbox is not running"
elif [[ $model_up -ne 1 ]]; then skip 7 "injection check" "it needs a model server, and none answers"
elif [[ -z "$injection_base" ]]; then skip 7 "injection check" "it needs --injection-base-url, a public URL of the fixtures (the sandbox only fetches public addresses)"
else
  export FT_INJ_BASE="$injection_base" FT_SERVER_URL="$SERVER_URL" FT_KEY="$api_key_file"
  step 7 "injection check" 2400 \
    '"$PY" "$ROOT/Scripts/research_injection_check.py" --base-url "$FT_INJ_BASE" --research-bin "$sandseek_bin" --server "$FT_SERVER_URL" --sandbox "http://127.0.0.1:$PORT" ${FT_KEY:+--api-key-file "$FT_KEY"}' || true
fi

# ---- 8. stop and leftovers (9 is the same code in the trap) ---------------------------------------
do_cleanup 8 "stop and leftovers"
exit 0
