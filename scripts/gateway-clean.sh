#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

HOST="127.0.0.1"
PORT="3000"
PROFILE="ops"
RAW=0
REPLACE=0

usage() {
  cat <<'EOF'
Usage: scripts/gateway-clean.sh [--host HOST] [--port PORT] [--profile ops|debug] [--raw] [--replace]

Profiles:
  ops    High-signal runtime lines only (default)
  debug  Keep all runtime lines except noisy Postgres NOTICE spam
  raw    No filtering (same as launching gateway directly)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --raw)
      RAW=1
      shift
      ;;
    --replace)
      REPLACE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$REPLACE" -eq 1 ]]; then
  if command -v lsof >/dev/null 2>&1; then
    found=0
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      if [[ "$cmd" == *"nullalis gateway"* ]]; then
        found=1
        echo "gateway-clean: stopping existing gateway pid=$pid on :$PORT" >&2
        kill "$pid" 2>/dev/null || true
      fi
    done < <(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
    if [[ "$found" -eq 1 ]]; then
      sleep 0.5
    fi
  else
    echo "gateway-clean: --replace requested but lsof not found; skipping pre-stop" >&2
  fi
fi

if [[ "$RAW" -eq 1 ]]; then
  exec ./zig-out/bin/nullalis gateway --host "$HOST" --port "$PORT"
fi

# Reduce PostgreSQL migration NOTICE chatter.
if [[ -n "${PGOPTIONS:-}" ]]; then
  export PGOPTIONS="$PGOPTIONS -c client_min_messages=warning"
else
  export PGOPTIONS="-c client_min_messages=warning"
fi

if [[ "$PROFILE" == "debug" ]]; then
  exec ./zig-out/bin/nullalis gateway --host "$HOST" --port "$PORT" 2>&1 \
    | awk '!/^NOTICE:[[:space:]]/ { print; fflush(); }'
fi

if [[ "$PROFILE" != "ops" ]]; then
  echo "Invalid --profile: $PROFILE (expected ops|debug)" >&2
  exit 2
fi

exec ./zig-out/bin/nullalis gateway --host "$HOST" --port "$PORT" 2>&1 \
  | awk '
      BEGIN {
        keep = "nullalis gateway runtime started|Gateway listening|Gateway pairing code|startup\\.self_check|gateway running in degraded state|^warning\\(|^error\\(|info\\(gateway\\): chat\\.stream\\.complete|info\\(session\\): message\\.process|info\\(agent\\): turn\\.stage stage=(memory_enrich|turn_compaction|build_provider_messages|parse_provider_response|tool_reflection|finalize_no_tools|memory_lifecycle_summarizer)|^info: llm\\.(request|response)|^info: tool\\.(start|call)|info\\(memory\\): memory plan resolved|info\\(agent\\): memory\\.lifecycle_summarizer";
      }
      !/^NOTICE:[[:space:]]/ && $0 ~ keep {
        print;
        fflush();
      }
    '
