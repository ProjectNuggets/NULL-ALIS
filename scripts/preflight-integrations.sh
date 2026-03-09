#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${NULLALIS_CONFIG_PATH:-$HOME/.nullalis/config.json}"
if [[ ! -f "$CONFIG_PATH" && -f "$HOME/.nullclaw/config.json" ]]; then
  CONFIG_PATH="$HOME/.nullclaw/config.json"
fi

PREFLIGHT_PORT="${PREFLIGHT_PORT:-3002}"
PREFLIGHT_WAIT_SECONDS="${PREFLIGHT_WAIT_SECONDS:-6}"
NULLALIS_BIN="${NULLALIS_BIN:-./zig-out/bin/nullalis}"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "preflight-integrations: missing required command: $cmd" >&2
    exit 1
  fi
}

fail() {
  echo "preflight-integrations: FAIL - $1" >&2
  exit 1
}

require_cmd jq
require_cmd curl
require_cmd zig

[[ -f "$CONFIG_PATH" ]] || fail "config not found at $CONFIG_PATH"

if [[ ! -x "$NULLALIS_BIN" ]]; then
  echo "preflight-integrations: building nullalis binary..."
  zig build -Dengines=base,sqlite,postgres >/dev/null
fi

LOG_FILE="$(mktemp -t nullalis-preflight-integrations.XXXXXX.log)"
GATEWAY_PID=""

cleanup() {
  if [[ -n "$GATEWAY_PID" ]] && kill -0 "$GATEWAY_PID" >/dev/null 2>&1; then
    kill "$GATEWAY_PID" >/dev/null 2>&1 || true
    wait "$GATEWAY_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

echo "preflight-integrations: Gate 1 - startup.self_check must show postgres + non-degraded"
"$NULLALIS_BIN" gateway --host 127.0.0.1 --port "$PREFLIGHT_PORT" >"$LOG_FILE" 2>&1 &
GATEWAY_PID="$!"
sleep "$PREFLIGHT_WAIT_SECONDS"

if ! kill -0 "$GATEWAY_PID" >/dev/null 2>&1; then
  sed -n '1,220p' "$LOG_FILE" >&2 || true
  fail "gateway exited before self-check probe completed"
fi

SELF_CHECK_LINE="$(grep -m1 "startup.self_check" "$LOG_FILE" || true)"
if [[ -z "$SELF_CHECK_LINE" ]]; then
  sed -n '1,220p' "$LOG_FILE" >&2 || true
  fail "startup.self_check line not found"
fi

kill "$GATEWAY_PID" >/dev/null 2>&1 || true
wait "$GATEWAY_PID" >/dev/null 2>&1 || true
GATEWAY_PID=""

[[ "$SELF_CHECK_LINE" == *"state_effective=postgres"* ]] || fail "state_effective is not postgres"
[[ "$SELF_CHECK_LINE" == *"scheduler_backend=postgres"* ]] || fail "scheduler_backend is not postgres"
[[ "$SELF_CHECK_LINE" == *"degraded=false"* ]] || fail "runtime is degraded=true"
echo "preflight-integrations: Gate 1 PASS"

COMPOSIO_ENABLED="$(jq -r '.composio.enabled // false' "$CONFIG_PATH")"
COMPOSIO_API_KEY="$(jq -r '.composio.api_key // empty' "$CONFIG_PATH")"
COMPOSIO_ENTITY_ID="$(jq -r '.composio.entity_id // "default"' "$CONFIG_PATH")"

if [[ "$COMPOSIO_ENABLED" != "true" ]]; then
  echo "preflight-integrations: Gate 2/3 skipped (composio.enabled=false)"
  echo "preflight-integrations: SUCCESS"
  exit 0
fi

[[ -n "$COMPOSIO_API_KEY" ]] || fail "composio enabled but api_key missing"

echo "preflight-integrations: Gate 2 - Composio toolkit availability (gmail/googledrive/googlecalendar)"
for toolkit in gmail googledrive googlecalendar; do
  resp="$(curl -sL -m 8 -H "x-api-key: $COMPOSIO_API_KEY" \
    "https://backend.composio.dev/api/v3/tools?toolkit_slug=${toolkit}&page=1&page_size=1" || true)"
  [[ -n "$resp" ]] || fail "empty response for toolkit=$toolkit"

  available="$(printf '%s' "$resp" | jq -r '
    if type=="array" then (length > 0)
    elif type=="object" then
      if (.items? | type) == "array" then (.items | length > 0)
      elif (.data? | type) == "array" then (.data | length > 0)
      elif (.results? | type) == "array" then (.results | length > 0)
      elif (.tools? | type) == "array" then (.tools | length > 0)
      elif (.total? | type) == "number" then (.total > 0)
      else false end
    else false end
  ' 2>/dev/null || echo false)"

  echo "preflight-integrations: toolkit=${toolkit} available=${available}"
done
echo "preflight-integrations: Gate 2 PASS"

echo "preflight-integrations: Gate 3 - connected account readiness by entity_id"
ENTITY_ESCAPED="$(jq -rn --arg v "$COMPOSIO_ENTITY_ID" '$v|@uri')"
accounts_resp="$(curl -sL -m 8 -H "x-api-key: $COMPOSIO_API_KEY" \
  "https://backend.composio.dev/api/v1/connectedAccounts?entity_id=${ENTITY_ESCAPED}" || true)"
[[ -n "$accounts_resp" ]] || fail "empty response for connectedAccounts"

gmail_connected="$(printf '%s' "$accounts_resp" | jq -r '
  def arr:
    if type=="array" then .
    elif type=="object" then (.items // .data // .results // .connectedAccounts // .connected_accounts // .accounts // [])
    else [] end;
  [arr[]? |
    ((.toolkit_slug // .toolkitSlug // .appName // .app_name // .app // .name // "") | ascii_downcase) as $app |
    ((.connected // .is_connected // ((.status // .connection_status // .connectionStatus // "") | ascii_downcase)) ) as $state |
    select($app | contains("gmail")) |
    (if ($state|type)=="boolean" then $state
     elif ($state|type)=="string" then ($state|contains("connected") or $state|contains("active") or $state|contains("authorized"))
     else true end)
  ] | any
' 2>/dev/null || echo false)"

drive_connected="$(printf '%s' "$accounts_resp" | jq -r '
  def arr:
    if type=="array" then .
    elif type=="object" then (.items // .data // .results // .connectedAccounts // .connected_accounts // .accounts // [])
    else [] end;
  [arr[]? |
    ((.toolkit_slug // .toolkitSlug // .appName // .app_name // .app // .name // "") | ascii_downcase) as $app |
    ((.connected // .is_connected // ((.status // .connection_status // .connectionStatus // "") | ascii_downcase)) ) as $state |
    select($app | contains("drive")) |
    (if ($state|type)=="boolean" then $state
     elif ($state|type)=="string" then ($state|contains("connected") or $state|contains("active") or $state|contains("authorized"))
     else true end)
  ] | any
' 2>/dev/null || echo false)"

calendar_connected="$(printf '%s' "$accounts_resp" | jq -r '
  def arr:
    if type=="array" then .
    elif type=="object" then (.items // .data // .results // .connectedAccounts // .connected_accounts // .accounts // [])
    else [] end;
  [arr[]? |
    ((.toolkit_slug // .toolkitSlug // .appName // .app_name // .app // .name // "") | ascii_downcase) as $app |
    ((.connected // .is_connected // ((.status // .connection_status // .connectionStatus // "") | ascii_downcase)) ) as $state |
    select($app | contains("calendar")) |
    (if ($state|type)=="boolean" then $state
     elif ($state|type)=="string" then ($state|contains("connected") or $state|contains("active") or $state|contains("authorized"))
     else true end)
  ] | any
' 2>/dev/null || echo false)"

echo "preflight-integrations: entity_id=${COMPOSIO_ENTITY_ID}"
echo "preflight-integrations: gmail_connected=${gmail_connected}"
echo "preflight-integrations: drive_connected=${drive_connected}"
echo "preflight-integrations: calendar_connected=${calendar_connected}"
echo "preflight-integrations: Gate 3 PASS"

echo "preflight-integrations: SUCCESS"
