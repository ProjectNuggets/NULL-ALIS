#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${NULLALIS_CONFIG_PATH:-$HOME/.nullalis/config.json}"
PREFLIGHT_PORT="${PREFLIGHT_PORT:-3001}"
PREFLIGHT_WAIT_SECONDS="${PREFLIGHT_WAIT_SECONDS:-6}"
PSQL_BIN="${PSQL_BIN:-psql}"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "preflight: missing required command: $cmd" >&2
    exit 1
  fi
}

fail() {
  echo "preflight: FAIL - $1" >&2
  exit 1
}

parse_postgres_host_port() {
  local conn="$1"
  local rest authority authority_no_user

  rest="${conn#*://}"
  authority="${rest%%/*}"
  authority_no_user="${authority##*@}"

  if [[ "$authority_no_user" =~ ^\[(.*)\](:([0-9]+))?$ ]]; then
    PG_HOST="${BASH_REMATCH[1]}"
    PG_PORT="${BASH_REMATCH[3]:-5432}"
    return
  fi

  PG_HOST="${authority_no_user%%:*}"
  if [[ "$authority_no_user" == *:* ]]; then
    PG_PORT="${authority_no_user##*:}"
  else
    PG_PORT="5432"
  fi
}

require_cmd jq
require_cmd zig

if ! command -v "$PSQL_BIN" >/dev/null 2>&1; then
  if [[ "$PSQL_BIN" == "psql" && -x "/opt/homebrew/opt/libpq/bin/psql" ]]; then
    PSQL_BIN="/opt/homebrew/opt/libpq/bin/psql"
  else
    fail "missing required command: psql"
  fi
fi

if [[ ! -f "$CONFIG_PATH" && "$CONFIG_PATH" == "$HOME/.nullalis/config.json" && -f "$HOME/.nullclaw/config.json" ]]; then
  CONFIG_PATH="$HOME/.nullclaw/config.json"
fi
[[ -f "$CONFIG_PATH" ]] || fail "config not found at $CONFIG_PATH"

echo "preflight: Gate 1 - state.backend must be postgres"
STATE_BACKEND="$(jq -r '.state.backend // empty' "$CONFIG_PATH")"
[[ -n "$STATE_BACKEND" ]] || fail "state.backend missing in $CONFIG_PATH"
[[ "$STATE_BACKEND" == "postgres" ]] || fail "state.backend is '$STATE_BACKEND' (expected 'postgres')"
echo "preflight: Gate 1 PASS"

echo "preflight: Gate 2 - connection string must target localhost:5432"
CONNECTION_STRING="$(jq -r '.state.postgres.connection_string // empty' "$CONFIG_PATH")"
[[ -n "$CONNECTION_STRING" ]] || fail "state.postgres.connection_string missing"
parse_postgres_host_port "$CONNECTION_STRING"

if [[ "$PG_HOST" != "127.0.0.1" && "$PG_HOST" != "localhost" ]]; then
  fail "connection host '$PG_HOST' not allowed for dev preflight (expected localhost/127.0.0.1)"
fi
if [[ "$PG_PORT" != "5432" ]]; then
  fail "connection port '$PG_PORT' is not allowed for dev preflight (expected 5432)"
fi
echo "preflight: Gate 2 PASS (host=$PG_HOST port=$PG_PORT)"

echo "preflight: Gate 3 - postgres connectivity"
"$PSQL_BIN" "$CONNECTION_STRING" -c "SELECT 1;" >/dev/null
echo "preflight: Gate 3 PASS"

echo "preflight: Gate 4 - release build with postgres engine"
zig build -Doptimize=ReleaseSmall -Dengines=base,sqlite,postgres >/dev/null
echo "preflight: Gate 4 PASS"

echo "preflight: Gate 5 - runtime must not fallback to file state"
LOG_FILE="$(mktemp -t nullalis-preflight.XXXXXX.log)"
GATEWAY_PID=""

cleanup() {
  if [[ -n "$GATEWAY_PID" ]] && kill -0 "$GATEWAY_PID" >/dev/null 2>&1; then
    kill "$GATEWAY_PID" >/dev/null 2>&1 || true
    wait "$GATEWAY_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

./zig-out/bin/nullalis gateway --host 127.0.0.1 --port "$PREFLIGHT_PORT" >"$LOG_FILE" 2>&1 &
GATEWAY_PID="$!"

sleep "$PREFLIGHT_WAIT_SECONDS"

if ! kill -0 "$GATEWAY_PID" >/dev/null 2>&1; then
  sed -n '1,200p' "$LOG_FILE" >&2 || true
  fail "gateway exited before preflight probe completed"
fi

kill "$GATEWAY_PID" >/dev/null 2>&1 || true
wait "$GATEWAY_PID" >/dev/null 2>&1 || true
GATEWAY_PID=""

if grep -Eiq "PostgresNotEnabled|falling back to file state" "$LOG_FILE"; then
  sed -n '1,200p' "$LOG_FILE" >&2 || true
  fail "runtime log shows postgres-disabled or file fallback"
fi
echo "preflight: Gate 5 PASS"

STATE_SCHEMA="$(jq -r '.state.postgres.schema // "public"' "$CONFIG_PATH")"
echo "preflight: schema=$STATE_SCHEMA"
echo "preflight: SUCCESS - all 5 gates passed"
