#!/usr/bin/env bash
# Runs NVIDIA garak against TUFF's local OpenAI-compatible server.
# Mac-only test tool. Not part of the product. Read Scripts/garak/README.md
# before the first run.
#
# Settings can be overridden from the environment, for example:
#   GARAK_PROMPT_CAP=16 GARAK_SPEC=probes.encoding Scripts/garak/run_garak.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

GARAK_VERSION="${GARAK_VERSION:-0.17.0}"
GARAK_PYTHON="${GARAK_PYTHON:-python3}"
GARAK_VENV="${GARAK_VENV:-$HOME/Developer/garak-venv}"
GARAK_REPORT_DIR="${GARAK_REPORT_DIR:-$HOME/Developer/garak-reports}"
GARAK_CONFIG="${GARAK_CONFIG:-$SCRIPT_DIR/garak-tuff.yaml}"
TUFF_PORT="${TUFF_PORT:-8080}"
TUFF_MODEL="${TUFF_MODEL:-qwen3.6-35b-a3b}"
GARAK_SPEC="${GARAK_SPEC:-probes.latentinjection,-probes.latentinjection.LatentWhois,-probes.latentinjection.LatentJailbreak,probes.encoding.InjectBase64,probes.encoding.InjectHex,probes.encoding.InjectROT13,probes.encoding.InjectUnicodeTagChars,probes.badchars}"
GARAK_GENERATIONS="${GARAK_GENERATIONS:-1}"
GARAK_PROMPT_CAP="${GARAK_PROMPT_CAP:-8}"

case "$TUFF_PORT" in
  ''|*[!0-9]*) echo "TUFF_PORT must be a number, got '$TUFF_PORT'." >&2; exit 1 ;;
esac
case "$GARAK_PROMPT_CAP" in
  ''|*[!0-9]*) echo "GARAK_PROMPT_CAP must be a number, got '$GARAK_PROMPT_CAP'." >&2; exit 1 ;;
esac
case "$GARAK_GENERATIONS" in
  ''|*[!0-9]*) echo "GARAK_GENERATIONS must be a number, got '$GARAK_GENERATIONS'." >&2; exit 1 ;;
esac

BASE_URL="http://127.0.0.1:${TUFF_PORT}"

if [ ! -x "$GARAK_VENV/bin/python" ]; then
  if ! "$GARAK_PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    echo "garak needs Python 3.11 or newer, and '$GARAK_PYTHON' is missing or older." >&2
    echo "Install one with: brew install python@3.12" >&2
    echo "Then run again with: GARAK_PYTHON=\$(brew --prefix python@3.12)/bin/python3.12 $0" >&2
    exit 1
  fi
  echo "Creating virtual environment in $GARAK_VENV"
  mkdir -p "$(dirname "$GARAK_VENV")"
  "$GARAK_PYTHON" -m venv "$GARAK_VENV"
fi

INSTALLED="$({ "$GARAK_VENV/bin/python" -m pip show garak 2>/dev/null || true; } | sed -n 's/^Version: //p')"
if [ "$INSTALLED" != "$GARAK_VERSION" ]; then
  echo "Installing garak==$GARAK_VERSION (installed: ${INSTALLED:-none})"
  "$GARAK_VENV/bin/python" -m pip install --upgrade pip
  "$GARAK_VENV/bin/python" -m pip install "garak==$GARAK_VERSION"
fi

echo "Checking that TUFF answers on $BASE_URL/v1/models"
if ! MODELS="$(curl -fsS --max-time 10 "$BASE_URL/v1/models")"; then
  echo "TUFF did not answer on $BASE_URL/v1/models." >&2
  echo "Quit the TUFF app, then start TUFFServer alone:" >&2
  echo "  swift run -c release TUFFServer --models-root ~/Developer/TUFF/scratch" >&2
  exit 1
fi
case "$MODELS" in
  *"\"$TUFF_MODEL\""*) ;;
  *) echo "The server does not list the model '$TUFF_MODEL'. It lists:" >&2
     echo "$MODELS" >&2
     echo "Set TUFF_MODEL to one of those ids." >&2
     exit 1 ;;
esac

mkdir -p "$GARAK_REPORT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/garak-tuff.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
RUN_CONFIG="$WORK_DIR/garak-tuff.yaml"
sed -e "s#http://127.0.0.1:8080/v1/#${BASE_URL}/v1/#" -e "s#soft_probe_prompt_cap: [0-9]*#soft_probe_prompt_cap: ${GARAK_PROMPT_CAP}#" "$GARAK_CONFIG" > "$RUN_CONFIG"

export OPENAICOMPATIBLE_API_KEY="${OPENAICOMPATIBLE_API_KEY:-not-needed}"

echo "Probes: $GARAK_SPEC"
echo "Generations per prompt: $GARAK_GENERATIONS"
echo "Prompts per probe class: up to $GARAK_PROMPT_CAP"
echo "Reports: $GARAK_REPORT_DIR (prefix run-$STAMP)"

"$GARAK_VENV/bin/python" -m garak \
  --target_type openai.OpenAICompatible \
  --target_name "$TUFF_MODEL" \
  --config "$RUN_CONFIG" \
  --spec "$GARAK_SPEC" \
  --generations "$GARAK_GENERATIONS" \
  --report_prefix "$GARAK_REPORT_DIR/run-$STAMP"

echo "Done. Report files:"
ls -1 "$GARAK_REPORT_DIR"/run-"$STAMP"*
