#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

HOST="127.0.0.1"
PORT="3000"
PROFILE="ops"
RAW=0
REPLACE=0
DAEMON=0
STATUS=0
STOP=0
WAIT_READY=0
WAIT_SECONDS="${NULLALIS_GATEWAY_WAIT_SECONDS:-30}"
RUNTIME_DIR="${NULLALIS_RUNTIME_DIR:-.nullalis-runtime}"
PID_FILE=""
LOG_FILE=""

usage() {
  cat <<'EOF'
Usage: scripts/gateway-clean.sh [--host HOST] [--port PORT] [--profile ops|debug] [--raw] [--replace]
                                [--daemon|--background] [--wait-ready] [--status] [--stop]
                                [--runtime-dir DIR] [--pid-file FILE] [--log-file FILE]

Profiles:
  ops    High-signal runtime lines only (default)
  debug  Keep all runtime lines except noisy Postgres NOTICE spam
  raw    No filtering (same as launching gateway directly)

Process modes:
  daemon Start gateway in the background with stable PID/log files.
  status Report whether the recorded gateway PID is running.
  stop   Stop the recorded gateway PID and any nullalis gateway on the selected port.
EOF
}

default_pid_file() {
  printf '%s/gateway-%s.pid' "$RUNTIME_DIR" "$PORT"
}

default_log_file() {
  printf '%s/gateway-%s.log' "$RUNTIME_DIR" "$PORT"
}

pid_is_gateway() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  local cmd
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$cmd" == *"nullalis gateway"* ]]
}

stop_pid_if_gateway() {
  local pid="$1"
  if ! pid_is_gateway "$pid"; then
    return 1
  fi
  echo "gateway-clean: stopping gateway pid=$pid" >&2
  kill "$pid" 2>/dev/null || true
  local i=0
  while kill -0 "$pid" >/dev/null 2>&1 && [[ "$i" -lt 40 ]]; do
    sleep 0.25
    i=$((i + 1))
  done
  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "gateway-clean: gateway pid=$pid did not exit after 10s; sending SIGKILL" >&2
    kill -9 "$pid" 2>/dev/null || true
  fi
  return 0
}

stop_existing_gateways_on_port() {
  if [[ -n "$PID_FILE" && -f "$PID_FILE" ]]; then
    local recorded_pid
    recorded_pid="$(tr -d ' \t\r\n' < "$PID_FILE" 2>/dev/null || true)"
    if stop_pid_if_gateway "$recorded_pid"; then
      rm -f "$PID_FILE"
    fi
  fi
  if command -v lsof >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      stop_pid_if_gateway "$pid" || true
    done < <(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
  fi
  return 0
}

diagnostics_ready() {
  local body="$1"
  local state_ok scheduler_ok degraded_ok lock_ok
  state_ok=1
  scheduler_ok=1
  degraded_ok=1
  lock_ok=1

  if grep -Eq '"state_effective"[[:space:]]*:[[:space:]]*"postgres"|"state_backend_effective"[[:space:]]*:[[:space:]]*"postgres"' <<<"$body"; then
    state_ok=0
  fi
  if grep -Eq '"scheduler_backend"[[:space:]]*:[[:space:]]*"postgres"' <<<"$body"; then
    scheduler_ok=0
  fi
  if grep -Eq '"degraded"[[:space:]]*:[[:space:]]*false' <<<"$body"; then
    degraded_ok=0
  fi
  if grep -Eq '"tenant_lock_backend"[[:space:]]*:[[:space:]]*"postgres_lease"' <<<"$body"; then
    lock_ok=0
  fi

  [[ "$state_ok" -eq 0 && "$scheduler_ok" -eq 0 && "$degraded_ok" -eq 0 && "$lock_ok" -eq 0 ]]
}

self_check_log_ready() {
  [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]] || return 1
  local line
  line="$(grep -E "startup\.self_check" "$LOG_FILE" | tail -1 || true)"
  [[ "$line" == *"state_effective=postgres"* ]] || return 1
  [[ "$line" == *"scheduler_backend=postgres"* ]] || return 1
  [[ "$line" == *"degraded=false"* ]] || return 1
  [[ "$line" == *"tenant_lock_backend=postgres_lease"* ]] || return 1
}

wait_ready() {
  local deadline now body
  deadline=$((SECONDS + WAIT_SECONDS))
  while [[ "$SECONDS" -le "$deadline" ]]; do
    if ! gateway_running; then
      echo "gateway-clean: gateway exited before readiness" >&2
      tail_gateway_log
      return 1
    fi
    if command -v curl >/dev/null 2>&1; then
      body="$(curl -fsS --max-time 2 "http://${HOST}:${PORT}/internal/diagnostics" 2>/dev/null || true)"
      if [[ -n "$body" ]] && diagnostics_ready "$body"; then
        echo "gateway-clean: ready host=$HOST port=$PORT backend=postgres scheduler=postgres degraded=false"
        return 0
      fi
    fi
    if self_check_log_ready; then
      echo "gateway-clean: ready host=$HOST port=$PORT backend=postgres scheduler=postgres degraded=false"
      return 0
    fi
    sleep 0.5
  done
  echo "gateway-clean: readiness timed out after ${WAIT_SECONDS}s" >&2
  tail_gateway_log
  return 1
}

tail_gateway_log() {
  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    echo "gateway-clean: last log lines from $LOG_FILE" >&2
    tail -80 "$LOG_FILE" >&2 || true
  fi
}

gateway_running() {
  if [[ -n "$PID_FILE" && -f "$PID_FILE" ]]; then
    local pid
    pid="$(tr -d ' \t\r\n' < "$PID_FILE" 2>/dev/null || true)"
    if pid_is_gateway "$pid"; then
      return 0
    fi
  fi
  if command -v lsof >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      if pid_is_gateway "$pid"; then
        return 0
      fi
    done < <(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
  fi
  return 1
}

start_gateway_daemon() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$PID_FILE" "$LOG_FILE" "$HOST" "$PORT" <<'PY'
import subprocess
import sys

pid_file, log_file, host, port = sys.argv[1:]
log = open(log_file, "ab", buffering=0)
proc = subprocess.Popen(
    ["./zig-out/bin/nullalis", "gateway", "--host", host, "--port", port],
    stdin=subprocess.DEVNULL,
    stdout=log,
    stderr=subprocess.STDOUT,
    start_new_session=True,
    close_fds=True,
)
with open(pid_file, "w", encoding="utf-8") as f:
    f.write(f"{proc.pid}\n")
print(proc.pid)
PY
    return
  fi

  nohup ./zig-out/bin/nullalis gateway --host "$HOST" --port "$PORT" >"$LOG_FILE" 2>&1 < /dev/null &
  local gateway_pid="$!"
  echo "$gateway_pid" >"$PID_FILE"
  printf '%s\n' "$gateway_pid"
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
    --daemon|--background)
      DAEMON=1
      shift
      ;;
    --wait-ready)
      WAIT_READY=1
      shift
      ;;
    --wait-seconds)
      WAIT_SECONDS="${2:-}"
      shift 2
      ;;
    --status)
      STATUS=1
      shift
      ;;
    --stop)
      STOP=1
      shift
      ;;
    --runtime-dir)
      RUNTIME_DIR="${2:-}"
      shift 2
      ;;
    --pid-file)
      PID_FILE="${2:-}"
      shift 2
      ;;
    --log-file)
      LOG_FILE="${2:-}"
      shift 2
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

if [[ -z "$RUNTIME_DIR" || -z "$WAIT_SECONDS" ]]; then
  echo "gateway-clean: runtime dir and wait seconds must be non-empty" >&2
  exit 2
fi
if ! [[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "gateway-clean: --wait-seconds must be an integer" >&2
  exit 2
fi
if [[ -z "$PID_FILE" ]]; then
  PID_FILE="$(default_pid_file)"
fi
if [[ -z "$LOG_FILE" ]]; then
  LOG_FILE="$(default_log_file)"
fi

if [[ "$STATUS" -eq 1 ]]; then
  if gateway_running; then
    if [[ -f "$PID_FILE" ]]; then
      echo "gateway-clean: running pid=$(tr -d ' \t\r\n' < "$PID_FILE") host=$HOST port=$PORT"
    else
      echo "gateway-clean: running host=$HOST port=$PORT"
    fi
    if [[ "$WAIT_READY" -eq 1 ]]; then
      wait_ready
    fi
    exit 0
  fi
  echo "gateway-clean: stopped host=$HOST port=$PORT"
  exit 1
fi

if [[ "$STOP" -eq 1 ]]; then
  stop_existing_gateways_on_port || true
  rm -f "$PID_FILE"
  exit 0
fi

if [[ "$REPLACE" -eq 1 ]]; then
  stop_existing_gateways_on_port || true
  sleep 0.5
elif [[ "$DAEMON" -eq 1 ]] && gateway_running; then
  echo "gateway-clean: gateway already running on :$PORT; use --replace to restart" >&2
  exit 1
fi

if [[ "$RAW" -eq 1 ]]; then
  if [[ "$WAIT_READY" -eq 1 || "$DAEMON" -eq 1 ]]; then
    echo "gateway-clean: --raw cannot be combined with --daemon or --wait-ready" >&2
    exit 2
  fi
  exec ./zig-out/bin/nullalis gateway --host "$HOST" --port "$PORT"
fi

# Reduce PostgreSQL migration NOTICE chatter.
if [[ -n "${PGOPTIONS:-}" ]]; then
  export PGOPTIONS="$PGOPTIONS -c client_min_messages=warning"
else
  export PGOPTIONS="-c client_min_messages=warning"
fi

if [[ "$DAEMON" -eq 1 ]]; then
  mkdir -p "$(dirname "$PID_FILE")" "$(dirname "$LOG_FILE")"
  : >"$LOG_FILE"
  gateway_pid="$(start_gateway_daemon)"
  sleep 0.25
  if ! pid_is_gateway "$gateway_pid"; then
    echo "gateway-clean: gateway failed to stay running pid=$gateway_pid" >&2
    tail_gateway_log
    rm -f "$PID_FILE"
    exit 1
  fi
  echo "gateway-clean: started pid=$gateway_pid host=$HOST port=$PORT log=$LOG_FILE"
  if [[ "$WAIT_READY" -eq 1 ]]; then
    wait_ready
  fi
  exit 0
fi

if [[ "$WAIT_READY" -eq 1 ]]; then
  echo "gateway-clean: --wait-ready requires --daemon or --status" >&2
  exit 2
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
        keep = "nullalis gateway runtime started|Gateway listening|Gateway pairing code|startup\\.self_check|gateway running in degraded state|^warning\\(|^error\\(|info\\(gateway\\): chat\\.stream\\.complete|info\\(session\\): message\\.process|info\\(agent\\): turn\\.stage stage=(memory_enrich|turn_compaction|build_provider_messages|parse_provider_response|tool_reflection|llm_first_token|llm_first_token_upper_bound|finalize_no_tools|memory_lifecycle_summarizer)|info\\(agent\\): turn\\.profile|^info: llm\\.(request|response)|^info: tool\\.(start|call)|info\\(memory\\): memory plan resolved|info\\(agent\\): memory\\.lifecycle_summarizer";
      }
      !/^NOTICE:[[:space:]]/ && $0 ~ keep {
        print;
        fflush();
      }
    '
