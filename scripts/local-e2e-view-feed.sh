#!/usr/bin/env bash
# scripts/local-e2e-view-feed.sh
#
# E2E check: orchestrator GET /v1/sessions/{id}/frame returns a valid PNG frame.
#
# What it does:
#   1. Starts the Go orchestrator on :8080 (or reuses one already running).
#   2. Opens a new browser session against the live worker pod.
#   3. Navigates to https://example.com via the orchestrator exec API.
#   4. Calls GET /v1/sessions/{id}/frame and asserts:
#        - HTTP 200
#        - JSON field "frame" is non-empty (base64 length > 100)
#        - JSON field "url" contains "example.com"
#   5. Prints PASS/FAIL and the observed frame length + url.
#
# The full browser_frame-over-SSE path (gateway → observer → SSE stream) is
# exercised in the Zaki repo's integration tests against this contract.
#
# Self-contained. Exits 0 on PASS, non-zero on FAIL.
set -uo pipefail

NS=browser
ORCH_URL="http://localhost:8080"
ORCH_LOG=/tmp/orch_view_feed_e2e.log

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ORCH_PID=""
ORCH_OWNED=false   # did WE start it, or was it already up?
SESSION_ID=""
RESULT="FAIL"

log()  { printf '[view-feed-e2e] %s\n' "$*"; }
fail() { printf '\n[view-feed-e2e] FAIL: %s\n' "$*" >&2; }

cleanup() {
  # Close the browser session we opened (best-effort).
  if [[ -n "$SESSION_ID" ]]; then
    log "closing session $SESSION_ID"
    curl -sS -m 10 -X DELETE "$ORCH_URL/v1/sessions/$SESSION_ID" >/dev/null 2>&1 || true
  fi

  # Stop the orchestrator only if we started it.
  if [[ "$ORCH_OWNED" == "true" ]]; then
    if [[ -n "$ORCH_PID" ]] && kill -0 "$ORCH_PID" 2>/dev/null; then
      log "stopping orchestrator (go-run pid=$ORCH_PID)"
      kill "$ORCH_PID" 2>/dev/null || true
      wait "$ORCH_PID" 2>/dev/null || true
    fi
    local lpid
    lpid="$(lsof -nP -tiTCP:8080 -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "$lpid" ]]; then
      log "reaping orchestrator listener on :8080 (pid=$lpid)"
      kill $lpid 2>/dev/null || true
    fi
    for _ in $(seq 1 10); do
      lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1 || break
      sleep 1
    done
  fi

  echo
  if [[ "$RESULT" == "PASS" ]]; then
    echo "============================================================"
    echo "  PASS: orchestrator GET /frame → non-empty PNG + url  (e2e)"
    echo "============================================================"
    exit 0
  else
    echo "============================================================"
    echo "  FAIL: view-feed e2e did not pass"
    [[ -f "$ORCH_LOG" ]] && echo "  orchestrator log: $ORCH_LOG"
    echo "============================================================"
    exit 1
  fi
}
trap cleanup EXIT

# --- 0. Ensure jq is available -----------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  fail "jq not found — install jq and re-run"
  exit 1
fi

# --- 1. Ensure k3d cluster + worker namespace ---------------------------------
log "checking k3d cluster + worker namespace..."
if ! kubectl -n "$NS" get pods >/dev/null 2>&1; then
  log "namespace '$NS' not reachable — running scripts/browser-worker-setup.sh"
  "$SCRIPT_DIR/browser-worker-setup.sh"
fi
kubectl -n "$NS" get pods >/dev/null 2>&1 || { fail "k3d namespace '$NS' still unreachable"; exit 1; }
log "cluster ok ($(kubectl -n "$NS" get pods --no-headers | wc -l | tr -d ' ') pod(s) in ns=$NS)"

# --- 2. Start orchestrator if not already running ----------------------------
if curl -sS -m 3 "$ORCH_URL/healthz" >/dev/null 2>&1; then
  log "orchestrator already running at $ORCH_URL"
  ORCH_OWNED=false
else
  log "starting orchestrator (background)..."
  (
    cd "$REPO_ROOT/services/browser-orchestrator" \
      && AGENT_BROWSER_STATE_MASTER_KEY="$(openssl rand -hex 32)" \
         GOTOOLCHAIN=local go run .
  ) >"$ORCH_LOG" 2>&1 &
  ORCH_PID=$!
  ORCH_OWNED=true
  log "orchestrator pid=$ORCH_PID (log: $ORCH_LOG)"

  log "waiting for $ORCH_URL/healthz ..."
  healthy=""
  for i in $(seq 1 30); do
    if ! kill -0 "$ORCH_PID" 2>/dev/null; then
      fail "orchestrator exited during startup:"
      tail -20 "$ORCH_LOG" >&2 || true
      exit 1
    fi
    if curl -sS -m 3 "$ORCH_URL/healthz" >/dev/null 2>&1; then
      healthy="yes"
      break
    fi
    sleep 1
  done
  if [[ -z "$healthy" ]]; then
    fail "orchestrator did not become healthy within 30s"
    tail -20 "$ORCH_LOG" >&2 || true
    exit 1
  fi
  log "healthz: $(curl -sS -m 3 "$ORCH_URL/healthz")"
fi

# --- 3. Open a browser session -----------------------------------------------
log "opening browser session (user_id=e2e-view-feed)..."
SESSION_RESP="$(curl -sS -m 15 -X POST "$ORCH_URL/v1/sessions" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"e2e-view-feed","auth_profile":""}' 2>&1)"
log "session response: $SESSION_RESP"

SESSION_ID="$(printf '%s' "$SESSION_RESP" | jq -r '.session_id // .id // empty')"
if [[ -z "$SESSION_ID" ]]; then
  fail "could not create session — response: $SESSION_RESP"
  exit 1
fi
log "session id: $SESSION_ID"

# --- 4. Navigate to example.com ----------------------------------------------
log "navigating to https://example.com ..."
NAV_RESP="$(curl -sS -m 30 -X POST "$ORCH_URL/v1/sessions/$SESSION_ID/exec" \
  -H "Content-Type: application/json" \
  -d '{"args":["navigate","https://example.com"]}' 2>&1)"
log "navigate response: $NAV_RESP"

NAV_EXIT="$(printf '%s' "$NAV_RESP" | jq -r '.exit_code // "?"')"
if [[ "$NAV_EXIT" != "0" ]]; then
  fail "navigate exit_code=$NAV_EXIT — response: $NAV_RESP"
  exit 1
fi
log "navigate ok (exit_code=$NAV_EXIT)"

# --- 5. GET /v1/sessions/{id}/frame and assert -------------------------------
log "calling GET $ORCH_URL/v1/sessions/$SESSION_ID/frame ..."
FRAME_RESP="$(curl -sS -m 30 \
  -w '\n__HTTP_STATUS__%{http_code}' \
  "$ORCH_URL/v1/sessions/$SESSION_ID/frame" 2>&1)"

HTTP_STATUS="$(printf '%s' "$FRAME_RESP" | grep '__HTTP_STATUS__' | sed 's/__HTTP_STATUS__//')"
FRAME_BODY="$(printf '%s' "$FRAME_RESP" | grep -v '__HTTP_STATUS__')"

log "HTTP status: $HTTP_STATUS"

if [[ "$HTTP_STATUS" != "200" ]]; then
  fail "expected HTTP 200, got $HTTP_STATUS — body: $FRAME_BODY"
  exit 1
fi

FRAME_VALUE="$(printf '%s' "$FRAME_BODY" | jq -r '.frame // empty')"
FRAME_URL="$(printf '%s' "$FRAME_BODY" | jq -r '.url // empty')"
FRAME_TITLE="$(printf '%s' "$FRAME_BODY" | jq -r '.title // empty')"

FRAME_LEN="${#FRAME_VALUE}"
log "frame base64 length : $FRAME_LEN"
log "frame url           : $FRAME_URL"
log "frame title         : $FRAME_TITLE"

PASS=true

if [[ "$FRAME_LEN" -lt 100 ]]; then
  fail "frame base64 length $FRAME_LEN < 100 — expected a real PNG"
  PASS=false
fi

if ! printf '%s' "$FRAME_URL" | grep -qi "example.com"; then
  fail "frame url '$FRAME_URL' does not contain 'example.com'"
  PASS=false
fi

if [[ "$PASS" == "true" ]]; then
  log "ASSERT frame length > 100        : PASS (length=$FRAME_LEN)"
  log "ASSERT url contains example.com  : PASS (url=$FRAME_URL)"
  RESULT="PASS"
else
  RESULT="FAIL"
fi
