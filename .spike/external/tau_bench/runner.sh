#!/usr/bin/env bash
# tau-bench Airline harness for nullalis.
#
# Mirrors the LoCoMo external runner shape: install the upstream benchmark into
# an ignored local cache, run Airline tasks through the nullalis gateway, write
# per-run artifacts under runs/<timestamp>, and optionally append one summary row
# to .spike/results.tsv.
#
# Usage:
#   .spike/external/tau_bench/runner.sh --smoke
#   .spike/external/tau_bench/runner.sh --append-results --label iter22-tau-airline-baseline
#   .spike/external/tau_bench/runner.sh --tasks 0,1,2 --max-steps 12
#
# Environment:
#   PYTHON                 Python 3.11+ interpreter (default: python3.11)
#   TAU_BENCH_REPO         Existing sierra-research/tau-bench checkout
#   NULLALIS_CHAT_URL      Full gateway SSE URL (default: .spike/benchmark.json)
#   GATEWAY_TOKEN          Internal gateway token (default: .spike/benchmark.json)
#   TAU_USER_ID_BASE       Gateway user id base (default: .spike/benchmark.json)
#   TAU_INCREMENT_USER_IDS Set 1 to use base+task_id users when provisioned
#   TAU_USER_MODEL_PROVIDER default groq
#   TAU_USER_MODEL         default llama-3.3-70b-versatile
#   GROQ_API_KEY           Optional; adapter also reads ~/.nullalis/config.json

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$BASE_DIR/../../.." && pwd)"
BENCH_FILE="$ROOT_DIR/.spike/benchmark.json"
UPSTREAM_DIR="${TAU_BENCH_REPO:-$BASE_DIR/.cache/tau-bench}"
VENV_DIR="$BASE_DIR/.venv"

if [[ -z "${PYTHON:-}" ]]; then
  if command -v python3.11 >/dev/null 2>&1; then
    PYTHON="$(command -v python3.11)"
  elif [[ -x /opt/homebrew/bin/python3.11 ]]; then
    PYTHON="/opt/homebrew/bin/python3.11"
  else
    PYTHON="$(command -v python3)"
  fi
fi

"$PYTHON" - <<'PY'
import sys
if sys.version_info < (3, 10):
    raise SystemExit("tau-bench requires Python 3.10+; set PYTHON to python3.11 or newer")
PY

if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
  if [[ -n "${TAU_BENCH_REPO:-}" ]]; then
    echo "ERROR: TAU_BENCH_REPO does not point to a git checkout: $TAU_BENCH_REPO" >&2
    exit 2
  fi
  mkdir -p "$(dirname "$UPSTREAM_DIR")"
  git clone --depth 1 https://github.com/sierra-research/tau-bench.git "$UPSTREAM_DIR"
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$PYTHON" -m venv "$VENV_DIR"
fi

if ! "$VENV_DIR/bin/python" -c 'import tau_bench, requests' >/dev/null 2>&1; then
  "$VENV_DIR/bin/python" -m pip install --upgrade pip
  "$VENV_DIR/bin/python" -m pip install -e "$UPSTREAM_DIR" requests
fi

if [[ -f "$BENCH_FILE" ]]; then
  export NULLALIS_CHAT_URL="${NULLALIS_CHAT_URL:-$(jq -r '.gateway.url' "$BENCH_FILE")}"
  export GATEWAY_TOKEN="${GATEWAY_TOKEN:-$(jq -r '.gateway.internal_token' "$BENCH_FILE")}"
  export TAU_USER_ID_BASE="${TAU_USER_ID_BASE:-$(jq -r '.gateway.user_id' "$BENCH_FILE")}"
fi

export TAU_USER_ID_BASE="${TAU_USER_ID_BASE:-1}"
export TAU_INCREMENT_USER_IDS="${TAU_INCREMENT_USER_IDS:-0}"
export TAU_USER_MODEL_PROVIDER="${TAU_USER_MODEL_PROVIDER:-groq}"
export TAU_USER_MODEL="${TAU_USER_MODEL:-llama-3.3-70b-versatile}"
export PYTHONPATH="$BASE_DIR/adapter${PYTHONPATH:+:$PYTHONPATH}"

cd "$ROOT_DIR"
exec "$VENV_DIR/bin/python" "$BASE_DIR/adapter/nullalis_agent.py" "$@"
