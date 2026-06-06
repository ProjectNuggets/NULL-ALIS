#!/usr/bin/env bash
# scripts/local-e2e-agent-browser.sh
#
# LOCAL end-to-end test of the AGENT-BROWSER lane at the TOOL layer.
#
# Proves the agent-side browser_* tools (not just the raw HTTP client) drive a
# real session end to end:
#
#   browser_new_session -> browser_navigate -> browser_snapshot(@eN) -> browser_close_session
#         |                      |                    |                        |
#         +----------------------+--------------------+------------------------+
#                                v
#                  live orchestrator (services/browser-orchestrator)
#                                v
#                  real k3d worker pod (ns=browser)
#
# What it does:
#   1. Ensures the k3d cluster + worker namespace exist (runs the setup script
#      if `kubectl -n browser get pods` fails).
#   2. Starts the Go orchestrator in the background with a generated master key,
#      bound to :8080, and waits for /healthz.
#   3. Runs the env-gated Zig tool-layer test
#      ("live: browser_* tools drive a session end to end").
#   4. Tears down the orchestrator and checks no per-session worker pod leaked.
#
# Self-contained + prints a clear PASS/FAIL. Exits non-zero on failure.
set -uo pipefail

NS=browser
ORCH_URL="http://localhost:8080"
ORCH_LOG=/tmp/orch_e2e.log
TEST_FILTER="live: browser_* tools"

# Resolve repo root from this script's location so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ORCH_PID=""
RESULT="FAIL"

log()  { printf '[e2e] %s\n' "$*"; }
fail() { printf '\n[e2e] FAIL: %s\n' "$*" >&2; }

cleanup() {
  # Stop the orchestrator we started (if any).
  # `go run` execs a separate compiled binary (the actual :8080 listener), so
  # killing the `go run` parent alone leaks the listener. Kill the parent AND
  # the real listener bound to :8080.
  if [[ -n "$ORCH_PID" ]] && kill -0 "$ORCH_PID" 2>/dev/null; then
    log "stopping orchestrator (go-run pid=$ORCH_PID)"
    kill "$ORCH_PID" 2>/dev/null || true
    wait "$ORCH_PID" 2>/dev/null || true
  fi
  # Kill the compiled orchestrator child holding :8080 (started by this run).
  local lpid
  lpid="$(lsof -nP -tiTCP:8080 -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$lpid" ]]; then
    log "reaping orchestrator listener on :8080 (pid=$lpid)"
    kill $lpid 2>/dev/null || true
  fi
  # Give the listener a moment to release the port.
  for _ in $(seq 1 10); do
    lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1 || break
    sleep 1
  done

  # Leak check: only the persistent worker (browser-worker-0) may remain.
  # Any other browser-worker-* pod is a per-session pod. browser_close_session
  # issues an async DELETE, so a just-closed pod may still be Terminating —
  # poll for it to disappear before declaring a leak.
  log "checking for leaked session pods..."
  local leaked=""
  for _ in $(seq 1 15); do
    leaked="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null \
      | awk '{print $1}' \
      | grep -E '^browser-worker-' \
      | grep -v -E '^browser-worker-0$' || true)"
    [[ -z "$leaked" ]] && break
    sleep 1
  done
  if [[ -n "$leaked" ]]; then
    fail "leaked session pod(s) after run:"
    printf '%s\n' "$leaked" >&2
    RESULT="FAIL"
  else
    log "no leaked session pods (only persistent browser-worker-0 remains)"
  fi

  echo
  if [[ "$RESULT" == "PASS" ]]; then
    echo "============================================================"
    echo "  PASS: browser_* tools -> orchestrator -> pod -> @eN  (e2e)"
    echo "============================================================"
    exit 0
  else
    echo "============================================================"
    echo "  FAIL: agent-browser tool-layer e2e did not pass"
    echo "  orchestrator log: $ORCH_LOG"
    echo "============================================================"
    exit 1
  fi
}
trap cleanup EXIT

# --- 1. Ensure cluster + worker namespace ------------------------------------
log "ensuring k3d cluster + worker namespace..."
if ! kubectl -n "$NS" get pods >/dev/null 2>&1; then
  log "namespace '$NS' not reachable — running scripts/browser-worker-setup.sh"
  "$SCRIPT_DIR/browser-worker-setup.sh"
fi
kubectl -n "$NS" get pods >/dev/null 2>&1 || { fail "k3d namespace '$NS' still unreachable"; exit 1; }
log "cluster ready:"
kubectl -n "$NS" get pods

# --- 2. Free port 8080 + start orchestrator ----------------------------------
if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
  fail "port 8080 already in use — stop the existing listener and re-run"
  lsof -nP -iTCP:8080 -sTCP:LISTEN >&2 || true
  exit 1
fi

log "starting orchestrator (background)..."
(
  cd "$REPO_ROOT/services/browser-orchestrator" \
    && AGENT_BROWSER_STATE_MASTER_KEY="$(openssl rand -hex 32)" \
       GOTOOLCHAIN=local go run .
) >"$ORCH_LOG" 2>&1 &
ORCH_PID=$!
log "orchestrator pid=$ORCH_PID (log: $ORCH_LOG)"

# --- wait for /healthz -------------------------------------------------------
log "waiting for $ORCH_URL/healthz ..."
healthy=""
for i in $(seq 1 30); do
  if ! kill -0 "$ORCH_PID" 2>/dev/null; then
    fail "orchestrator exited during startup:"
    tail -20 "$ORCH_LOG" >&2 || true
    exit 1
  fi
  if curl -sS -m 3 "$ORCH_URL/healthz" 2>/dev/null | grep -q .; then
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

# --- 3. Run the env-gated live tool-layer test -------------------------------
log "running tool-layer live test: \"$TEST_FILTER\""
if NULLALIS_BROWSER_LIVE_TEST=1 "${ZIG:-zig}" build test \
     -Dtest-filter="$TEST_FILTER" \
     --build-file "$REPO_ROOT/build.zig"; then
  log "tool-layer live test PASSED"
  RESULT="PASS"
else
  fail "tool-layer live test FAILED (exit=$?)"
  RESULT="FAIL"
fi

# cleanup() runs on EXIT (orchestrator teardown + leak check + PASS/FAIL banner)
