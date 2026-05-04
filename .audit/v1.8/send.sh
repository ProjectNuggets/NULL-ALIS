#!/usr/bin/env bash
# V1.8 audit — send a prompt to the gateway, capture SSE response, write per-turn artifacts.
#
# Usage:
#   ./send.sh T1 "My name is Nova." [session_suffix]
#
# Writes:
#   .audit/v1.8/runs/<RUN_ID>/T1.sse        — raw SSE stream
#   .audit/v1.8/runs/<RUN_ID>/T1.reply      — extracted assistant text
#   .audit/v1.8/runs/<RUN_ID>/T1.snap.json  — PG snapshot AFTER the turn
#
# Caller responsibility: invoke `snapshot.sh > T0.snap.json` before T1 to establish baseline.

set -euo pipefail

TAG="${1:?need tag like T1}"
PROMPT="${2:?need prompt text}"
SESSION_SUFFIX="${3:-main}"

USER_ID="${AUDIT_USER_ID:-7777}"
URL="http://127.0.0.1:3000/api/v1/chat/stream"
INTERNAL_TOKEN="40ae970fce1815c0d076fdff8ac24c02b1a45bc905d909cd"
SESSION_KEY="agent:zaki-bot:user:${USER_ID}:${SESSION_SUFFIX}"

# Resolve run dir (created by harness driver, exported as RUN_DIR)
RUN_DIR="${RUN_DIR:-/Users/nova/Desktop/nullalis/.audit/v1.8/runs/manual}"
mkdir -p "$RUN_DIR"

SSE="$RUN_DIR/${TAG}.sse"
REPLY="$RUN_DIR/${TAG}.reply"
SNAP="$RUN_DIR/${TAG}.snap.json"
META="$RUN_DIR/${TAG}.meta"

START_TS=$(date -u +%s)
echo "session_key=$SESSION_KEY" > "$META"
echo "prompt_chars=${#PROMPT}" >> "$META"
echo "start_ts=$START_TS" >> "$META"

# Stream the SSE response
curl -sN -X POST "$URL" \
  -H "Content-Type: application/json" \
  -H "X-Zaki-User-Id: $USER_ID" \
  -H "X-Internal-Token: $INTERNAL_TOKEN" \
  -d "$(jq -n --arg m "$PROMPT" --arg s "$SESSION_KEY" '{message:$m, session_key:$s}')" \
  > "$SSE" 2>&1 || echo "curl rc=$?" >> "$META"

END_TS=$(date -u +%s)
echo "end_ts=$END_TS" >> "$META"
echo "duration_s=$((END_TS - START_TS))" >> "$META"

# Extract assistant reply text from SSE chunks (data: lines for chat.delta type events)
# Be conservative: just dump all data: payloads + let the reader parse.
grep "^data:" "$SSE" | sed 's/^data: //' > "$REPLY" 2>/dev/null || true

# Snapshot PG state AFTER turn
AUDIT_USER_ID=$USER_ID /Users/nova/Desktop/nullalis/.audit/v1.8/snapshot.sh > "$SNAP"

# Print one-line summary
ED_BEFORE_NEW=$(jq '.counts.edges_active' "$SNAP")
MEM_NEW=$(jq '.counts.memories_live' "$SNAP")
MSG_NEW=$(jq '.counts.messages' "$SNAP")
echo "$TAG  duration=${END_TS}-${START_TS}s  msgs=$MSG_NEW  memories=$MEM_NEW  edges=$ED_BEFORE_NEW  → $RUN_DIR/${TAG}.*"
