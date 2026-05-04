#!/usr/bin/env bash
# V1.8 memory audit — PG snapshot harness.
# Emits a single JSON document capturing all memory-layer state for user_id=$AUDIT_USER_ID.
# Diff successive snapshots to compute "what fired this turn."
#
# Usage:
#   AUDIT_USER_ID=7777 ./snapshot.sh > snap_T0.json
#   ... send prompt ...
#   AUDIT_USER_ID=7777 ./snapshot.sh > snap_T1.json
#   diff snap_T0.json snap_T1.json  # what fired

set -euo pipefail
USER_ID="${AUDIT_USER_ID:-7777}"
PSQL="/opt/homebrew/opt/libpq/bin/psql"
URL="postgresql://zaki:zaki@127.0.0.1:5433/zaki"

run_q() {
  $PSQL "$URL" -At -F$'\t' -c "$1" 2>/dev/null
}

# Build JSON via jq from per-query results
jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg user "$USER_ID" \
  --arg messages_count "$(run_q "SELECT COUNT(*) FROM zaki_bot.messages WHERE user_id = $USER_ID;")" \
  --arg memories_live "$(run_q "SELECT COUNT(*) FROM zaki_bot.memories WHERE user_id = $USER_ID AND (valid_to IS NULL OR valid_to > EXTRACT(EPOCH FROM NOW())::bigint);")" \
  --arg memories_archived "$(run_q "SELECT COUNT(*) FROM zaki_bot.memories WHERE user_id = $USER_ID AND valid_to IS NOT NULL AND valid_to <= EXTRACT(EPOCH FROM NOW())::bigint;")" \
  --arg entities "$(run_q "SELECT COUNT(*) FROM zaki_bot.memory_entities WHERE user_id = $USER_ID;")" \
  --arg edges_active "$(run_q "SELECT COUNT(*) FROM zaki_bot.memory_edges WHERE user_id = $USER_ID AND is_latest;")" \
  --arg edges_total "$(run_q "SELECT COUNT(*) FROM zaki_bot.memory_edges WHERE user_id = $USER_ID;")" \
  --arg communities "$(run_q "SELECT COUNT(*) FROM zaki_bot.memory_communities WHERE user_id = $USER_ID;")" \
  --arg events "$(run_q "SELECT COUNT(*) FROM zaki_bot.memory_events WHERE user_id = $USER_ID;")" \
  --arg by_category "$(run_q "SELECT json_object_agg(memory_type, count) FROM (SELECT memory_type, COUNT(*) AS count FROM zaki_bot.memories WHERE user_id = $USER_ID GROUP BY memory_type) sub;" | tr -d '\n')" \
  --arg by_attribution "$(run_q "SELECT json_object_agg(source, count) FROM (SELECT COALESCE(metadata->>'attribution', 'none') AS source, COUNT(*) AS count FROM zaki_bot.memories WHERE user_id = $USER_ID GROUP BY source) sub;" | tr -d '\n')" \
  --arg by_predicate "$(run_q "SELECT json_object_agg(predicate, count) FROM (SELECT predicate, COUNT(*) AS count FROM zaki_bot.memory_edges WHERE user_id = $USER_ID AND is_latest GROUP BY predicate) sub;" | tr -d '\n')" \
  --arg by_edge_attribution "$(run_q "SELECT json_object_agg(attribution, count) FROM (SELECT COALESCE(attribution, 'none') AS attribution, COUNT(*) AS count FROM zaki_bot.memory_edges WHERE user_id = $USER_ID AND is_latest GROUP BY attribution) sub;" | tr -d '\n')" \
  --arg recent_memories "$(run_q "SELECT json_agg(row_to_json(t)) FROM (SELECT key, LEFT(content, 100) AS content_head, memory_type, valid_to, metadata->>'attribution' AS source, EXTRACT(EPOCH FROM created_at)::bigint AS created_at FROM zaki_bot.memories WHERE user_id = $USER_ID ORDER BY created_at DESC LIMIT 8) t;" | tr -d '\n')" \
  --arg recent_edges "$(run_q "SELECT json_agg(row_to_json(t)) FROM (SELECT source_key, target_key, predicate, attribution, weight, valid_from FROM zaki_bot.memory_edges WHERE user_id = $USER_ID AND is_latest ORDER BY id DESC LIMIT 8) t;" | tr -d '\n')" \
  --arg recent_messages "$(run_q "SELECT json_agg(row_to_json(t)) FROM (SELECT role, LEFT(content, 80) AS preview, EXTRACT(EPOCH FROM created_at)::bigint AS created_at, session_id FROM zaki_bot.messages WHERE user_id = $USER_ID ORDER BY created_at DESC LIMIT 4) t;" | tr -d '\n')" \
  '{
    ts: $ts,
    user_id: ($user|tonumber),
    counts: {
      messages: ($messages_count|tonumber),
      memories_live: ($memories_live|tonumber),
      memories_archived: ($memories_archived|tonumber),
      entities: ($entities|tonumber),
      edges_active: ($edges_active|tonumber),
      edges_total: ($edges_total|tonumber),
      communities: ($communities|tonumber),
      events: ($events|tonumber)
    },
    by_category: (try ($by_category|fromjson) catch null),
    by_attribution: (try ($by_attribution|fromjson) catch null),
    by_predicate: (try ($by_predicate|fromjson) catch null),
    by_edge_attribution: (try ($by_edge_attribution|fromjson) catch null),
    recent_memories: (try ($recent_memories|fromjson) catch null),
    recent_edges: (try ($recent_edges|fromjson) catch null),
    recent_messages: (try ($recent_messages|fromjson) catch null)
  }'
