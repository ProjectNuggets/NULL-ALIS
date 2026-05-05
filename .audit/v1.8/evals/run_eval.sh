#!/usr/bin/env bash
# V1.8-6 adversarial eval runner.
#
# Drives the 5 corpora in .audit/v1.8/evals/prompt_corpus/ against a running
# gateway, snapshots PG state pre/post each corpus, evaluates assertions
# from expected.json, and computes per-corpus + overall F1.
#
# Usage:
#   ./run_eval.sh                 # run all 5 corpora
#   ./run_eval.sh --quick         # skip long_context_pass_c (slowest)
#   ./run_eval.sh --corpus <name> # run only one corpus
#   ./run_eval.sh --baseline      # tag results as baseline-<sha>-...
#
# Assumptions:
#   - Gateway running at 127.0.0.1:3000
#   - User 7777 provisioned (see .audit/v1.8/runs/*/FINDINGS.md)
#   - Postgres reachable at 127.0.0.1:5433/zaki schema zaki_bot
#   - jq + curl + /opt/homebrew/opt/libpq/bin/psql available

set -uo pipefail
# Note: not -e because we want to keep going on assertion failures (those are F1 misses)

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVALS="$BASE"
CORPORA_DIR="$EVALS/prompt_corpus"
EXPECTED="$EVALS/expected.json"
RESULTS_DIR="$EVALS/results"
SEND="$EVALS/../send.sh"
SNAP="$EVALS/../snapshot.sh"
PSQL="/opt/homebrew/opt/libpq/bin/psql"
PG="postgresql://zaki:zaki@127.0.0.1:5433/zaki"
USER_ID=7777
CONFIG_PATH="/Users/nova/.nullalis/config.json"
CONFIG_BACKUP="$CONFIG_PATH.eval-backup"

mkdir -p "$RESULTS_DIR"

# Parse args
ONLY_CORPUS=""
QUICK=false
BASELINE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=true ;;
    --baseline) BASELINE=true ;;
    --corpus) shift; ONLY_CORPUS="$1" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# Resolve sha tag for results
SHA=$(git -C "$EVALS/../../.." rev-parse --short HEAD)
TS=$(date -u +%Y%m%d-%H%M%S)
TAG_PREFIX="${BASELINE:+baseline-}"
RUN_TAG="${TAG_PREFIX}${SHA}-${TS}"

echo "=== V1.8-6 eval run ==="
echo "sha=$SHA tag=$RUN_TAG quick=$QUICK only=$ONLY_CORPUS"
echo ""

# Sanity checks
curl -s -o /dev/null -w "gateway_health=%{http_code}\n" http://127.0.0.1:3000/api/v1/health || { echo "gateway DOWN"; exit 3; }
$PSQL "$PG" -At -c "SELECT 1" >/dev/null || { echo "PG DOWN"; exit 3; }

# Helper: query int via psql
pg_int() {
  local q="$1"
  $PSQL "$PG" -At -c "$q" 2>/dev/null | head -1
}

# Helper: query JSON via psql (returns single value)
pg_jsonl() {
  local q="$1"
  $PSQL "$PG" -At -c "$q" 2>/dev/null
}

# Compute embedding coverage for non-bookkeeping memories
embedding_coverage_pct() {
  local total
  local with_vec
  total=$(pg_int "SELECT COUNT(*) FROM zaki_bot.memories WHERE user_id=$USER_ID AND key NOT LIKE 'autosave_%'")
  if [ "$total" -le 0 ]; then echo "100"; return; fi
  with_vec=$(pg_int "SELECT COUNT(*) FROM zaki_bot.memories m WHERE m.user_id=$USER_ID AND m.key NOT LIKE 'autosave_%' AND EXISTS (SELECT 1 FROM zaki_bot.memory_embeddings_e5_1024 e WHERE e.user_id=$USER_ID AND e.key=m.key)")
  echo $(( with_vec * 100 / total ))
}

# Helper: count event_type entries for user
event_count() {
  pg_int "SELECT COUNT(*) FROM zaki_bot.memory_events WHERE user_id=$USER_ID AND event_type='$1'"
}

# Helper: count entities matching name_lower
entity_count_lower() {
  pg_int "SELECT COUNT(*) FROM zaki_bot.memory_entities WHERE user_id=$USER_ID AND LOWER(name) LIKE '%$1%'"
}

# Helper: count active edges with predicate
edge_count_predicate_active() {
  pg_int "SELECT COUNT(*) FROM zaki_bot.memory_edges WHERE user_id=$USER_ID AND predicate='$1' AND is_latest=true"
}

# Helper: count edges with is_latest=false
edge_count_closed() {
  pg_int "SELECT COUNT(*) FROM zaki_bot.memory_edges WHERE user_id=$USER_ID AND is_latest=false"
}

# Helper: count compaction_summary keys
compaction_summary_count() {
  pg_int "SELECT COUNT(*) FROM zaki_bot.memories WHERE user_id=$USER_ID AND key LIKE 'compaction_summary/%'"
}

# Drive ONE corpus: returns (passed, total) via stdout
run_corpus() {
  local corpus="$1"
  local file="$CORPORA_DIR/${corpus}.txt"
  if [ ! -f "$file" ]; then echo "MISSING $file" >&2; echo "0 1"; return; fi

  local cfg
  cfg=$(jq -c ".corpora.\"$corpus\"" "$EXPECTED")
  if [ "$cfg" = "null" ]; then echo "no expected for $corpus" >&2; echo "0 1"; return; fi

  local lane override
  lane=$(echo "$cfg" | jq -r '.session_suffix')
  override=$(echo "$cfg" | jq -r '.expect_token_limit_override')
  local session="thread:eval-${lane}-${TS}"

  # Toggle config if Pass C corpus
  local config_changed=false
  if [ "$override" = "true" ]; then
    cp "$CONFIG_PATH" "$CONFIG_BACKUP"
    python3 -c "import json; c=json.load(open('$CONFIG_PATH')); c.setdefault('agent',{})['token_limit']=8000; json.dump(c, open('$CONFIG_PATH','w'), indent=2)"
    config_changed=true
    echo "  [config] token_limit=8000 set, restarting gateway..."
    pkill -f "nullalis gateway" 2>/dev/null; sleep 2
    nohup /Users/nova/Desktop/nullalis/zig-out/bin/nullalis gateway --host 127.0.0.1 --port 3000 > /tmp/eval-gateway-${corpus}.log 2>&1 &
    sleep 5
  fi

  echo "  [$corpus] lane=$session"

  # Pre-snapshot deltas
  local pre_msgs pre_mems pre_ents pre_edges_active pre_edges_closed pre_compaction
  pre_msgs=$(pg_int "SELECT COUNT(*) FROM zaki_bot.messages WHERE user_id=$USER_ID")
  pre_mems=$(pg_int "SELECT COUNT(*) FROM zaki_bot.memories WHERE user_id=$USER_ID")
  pre_ents=$(pg_int "SELECT COUNT(*) FROM zaki_bot.memory_entities WHERE user_id=$USER_ID")
  pre_edges_active=$(pg_int "SELECT COUNT(*) FROM zaki_bot.memory_edges WHERE user_id=$USER_ID AND is_latest=true")
  pre_edges_closed=$(pg_int "SELECT COUNT(*) FROM zaki_bot.memory_edges WHERE user_id=$USER_ID AND is_latest=false")
  pre_compaction=$(compaction_summary_count)
  local pre_upsert pre_edge_added pre_supersede pre_judge_resolve pre_compose pre_episode pre_demote
  pre_upsert=$(event_count upsert)
  pre_edge_added=$(event_count edge_added)
  pre_supersede=$(event_count supersede)
  pre_judge_resolve=$(event_count judge_resolve)
  pre_compose=$(event_count compose)
  pre_episode=$(event_count episode)
  pre_demote=$(event_count demote)

  # Send each prompt
  local i=0
  local turn_run_dir="$RESULTS_DIR/${RUN_TAG}-${corpus}"
  mkdir -p "$turn_run_dir"
  while IFS= read -r prompt || [ -n "$prompt" ]; do
    [ -z "$prompt" ] && continue
    i=$((i+1))
    RUN_DIR="$turn_run_dir" "$SEND" "T$i" "$prompt" "$session" >/dev/null 2>&1
    if ! pgrep -f "nullalis gateway" > /dev/null; then
      echo "  [$corpus] FATAL: gateway died at T$i" >&2
      break
    fi
  done < "$file"
  echo "  [$corpus] sent $i prompts"

  # Restore config if changed
  if [ "$config_changed" = "true" ]; then
    cp "$CONFIG_BACKUP" "$CONFIG_PATH"
    pkill -f "nullalis gateway" 2>/dev/null; sleep 2
    nohup /Users/nova/Desktop/nullalis/zig-out/bin/nullalis gateway --host 127.0.0.1 --port 3000 > /tmp/eval-gateway-restore.log 2>&1 &
    sleep 5
    echo "  [config] restored"
  fi

  # Post-snapshot
  local post_msgs post_mems post_ents post_edges_active post_edges_closed post_compaction
  post_msgs=$(pg_int "SELECT COUNT(*) FROM zaki_bot.messages WHERE user_id=$USER_ID")
  post_mems=$(pg_int "SELECT COUNT(*) FROM zaki_bot.memories WHERE user_id=$USER_ID")
  post_ents=$(pg_int "SELECT COUNT(*) FROM zaki_bot.memory_entities WHERE user_id=$USER_ID")
  post_edges_active=$(pg_int "SELECT COUNT(*) FROM zaki_bot.memory_edges WHERE user_id=$USER_ID AND is_latest=true")
  post_edges_closed=$(pg_int "SELECT COUNT(*) FROM zaki_bot.memory_edges WHERE user_id=$USER_ID AND is_latest=false")
  post_compaction=$(compaction_summary_count)
  local post_upsert post_edge_added post_supersede post_judge_resolve post_compose post_episode post_demote
  post_upsert=$(event_count upsert)
  post_edge_added=$(event_count edge_added)
  post_supersede=$(event_count supersede)
  post_judge_resolve=$(event_count judge_resolve)
  post_compose=$(event_count compose)
  post_episode=$(event_count episode)
  post_demote=$(event_count demote)

  # Compute deltas
  local d_msgs=$((post_msgs - pre_msgs))
  local d_mems=$((post_mems - pre_mems))
  local d_ents=$((post_ents - pre_ents))
  local d_edges_active=$((post_edges_active - pre_edges_active))
  local d_edges_closed=$((post_edges_closed - pre_edges_closed))
  local d_compaction=$((post_compaction - pre_compaction))

  # Run assertions
  local passed=0 total=0
  local v=""
  local results_jq=()
  # Bash 3.2 — no assoc arrays. Use jq-on-the-fly lookups.
  asserts_get() {
    local k="$1"
    echo "$cfg" | jq -r ".asserts.\"$k\" // empty"
  }

  check() {
    local name="$1" actual="$2" op="$3" target="$4"
    total=$((total+1))
    local pass=false
    case "$op" in
      ge) [ "$actual" -ge "$target" ] && pass=true ;;
      le) [ "$actual" -le "$target" ] && pass=true ;;
      eq) [ "$actual" -eq "$target" ] && pass=true ;;
    esac
    if [ "$pass" = true ]; then passed=$((passed+1)); fi
    echo "    $name: actual=$actual op=$op target=$target → $([ "$pass" = true ] && echo PASS || echo FAIL)"
    results_jq+=("{\"name\":\"$name\",\"actual\":$actual,\"op\":\"$op\",\"target\":$target,\"pass\":$pass}")
  }

  # Standard delta asserts
  v=$(asserts_get messages_delta_at_least); [ -n "$v" ] && check messages_delta "$d_msgs" ge "$v"
  v=$(asserts_get memories_delta_at_least); [ -n "$v" ] && check memories_delta "$d_mems" ge "$v"
  v=$(asserts_get entities_delta_at_least); [ -n "$v" ] && check entities_delta "$d_ents" ge "$v"
  v=$(asserts_get edges_delta_at_least); [ -n "$v" ] && check edges_delta "$d_edges_active" ge "$v"
  v=$(asserts_get edges_with_is_latest_false_after_at_least); [ -n "$v" ] && check closed_edges_delta "$d_edges_closed" ge "$v"
  v=$(asserts_get memories_with_key_prefix_compaction_summary_at_least); [ -n "$v" ] && check compaction_summary_keys "$d_compaction" ge "$v"

  # Embedding coverage
  v=$(asserts_get embedding_coverage_pct_at_least)
  if [ -n "$v" ]; then
    local cov; cov=$(embedding_coverage_pct)
    check embedding_coverage_pct "$cov" ge "$v"
  fi

  # Entity by name
  for entkey in entities_with_name_eli_vance_at_least entities_with_name_aurora_robotics_at_least entities_with_name_helix_at_least; do
    v=$(asserts_get "$entkey")
    if [ -n "$v" ]; then
      local needle=${entkey#entities_with_name_}; needle=${needle%_at_least}
      needle=$(echo "$needle" | tr '_' ' ')
      local cnt; cnt=$(entity_count_lower "$needle")
      check "$entkey" "$cnt" ge "$v"
    fi
  done

  # Edge predicate active. Strip "edges_with_predicate_" prefix and known suffixes.
  for edgekey in edges_with_predicate_PREFERS_after_at_least edges_with_predicate_WORKS_AT_after_at_least edges_with_predicate_PREFERS_is_latest_true_after_at_least; do
    v=$(asserts_get "$edgekey")
    if [ -n "$v" ]; then
      local pred=${edgekey#edges_with_predicate_}
      pred=${pred%_after_at_least}
      pred=${pred%_is_latest_true}
      local cnt; cnt=$(edge_count_predicate_active "$pred")
      check "$edgekey" "$cnt" ge "$v"
    fi
  done

  # event_type_deltas — use the explicit pre_/post_ vars (Bash 3.2 has no assoc arrays)
  for etkey in upsert_at_least edge_added_at_least supersede_at_least judge_resolve_at_least compose_at_least episode_at_least demote_at_least; do
    local etval; etval=$(echo "$cfg" | jq -r ".asserts.event_type_deltas.\"$etkey\" // empty")
    [ -z "$etval" ] && continue
    local et=${etkey%_at_least}
    local pre_var="pre_$et"
    local post_var="post_$et"
    local d=$(( ${!post_var} - ${!pre_var} ))
    check "event_${et}_delta" "$d" ge "$etval"
  done

  # specific_entities_present_min_count
  local list_min; list_min=$(echo "$cfg" | jq -r '.asserts.specific_entities_present_min_count // 0')
  if [ "$list_min" -gt 0 ]; then
    local matched=0
    while IFS= read -r needle; do
      local cnt; cnt=$(entity_count_lower "$needle")
      [ "$cnt" -gt 0 ] && matched=$((matched+1))
    done < <(echo "$cfg" | jq -r '.asserts.specific_entities_present_at_least[]?')
    check specific_entities_matched "$matched" ge "$list_min"
  fi

  # Write per-corpus result JSON
  local corpus_result="$RESULTS_DIR/${RUN_TAG}-${corpus}.json"
  {
    echo "{"
    echo "  \"corpus\": \"$corpus\","
    echo "  \"sha\": \"$SHA\","
    echo "  \"ts\": \"$TS\","
    echo "  \"deltas\": {"
    echo "    \"messages\": $d_msgs,"
    echo "    \"memories\": $d_mems,"
    echo "    \"entities\": $d_ents,"
    echo "    \"edges_active\": $d_edges_active,"
    echo "    \"edges_closed\": $d_edges_closed,"
    echo "    \"compaction_summary\": $d_compaction"
    echo "  },"
    echo "  \"event_deltas\": {"
    echo "    \"upsert\": $((post_upsert - pre_upsert)),"
    echo "    \"edge_added\": $((post_edge_added - pre_edge_added)),"
    echo "    \"supersede\": $((post_supersede - pre_supersede)),"
    echo "    \"judge_resolve\": $((post_judge_resolve - pre_judge_resolve)),"
    echo "    \"compose\": $((post_compose - pre_compose)),"
    echo "    \"episode\": $((post_episode - pre_episode)),"
    echo "    \"demote\": $((post_demote - pre_demote))"
    echo "  },"
    echo "  \"asserts\": ["
    local IFS=,
    echo "    ${results_jq[*]}"
    echo "  ],"
    echo "  \"f1\": $(awk "BEGIN { printf \"%.3f\", $passed / $total }"),"
    echo "  \"passed\": $passed,"
    echo "  \"total\": $total"
    echo "}"
  } > "$corpus_result"

  echo "  [$corpus] F1=$passed/$total → $corpus_result"
  echo ""
  echo "$passed $total"
}

# Main loop
TOTAL_PASS=0
TOTAL_ASRT=0
SUMMARY="$RESULTS_DIR/${RUN_TAG}-summary.txt"
{
  echo "V1.8-6 eval run summary"
  echo "tag=$RUN_TAG sha=$SHA started=$TS"
  echo ""
  printf "%-25s %10s %10s\n" "corpus" "passed" "total"
  printf "%-25s %10s %10s\n" "----" "----" "----"
} > "$SUMMARY"

CORPORA="identity_writes preference_changes multi_entity relational_queries long_context_pass_c"
[ "$QUICK" = true ] && CORPORA="identity_writes preference_changes multi_entity relational_queries"
[ -n "$ONLY_CORPUS" ] && CORPORA="$ONLY_CORPUS"

for corpus in $CORPORA; do
  echo "=== running $corpus ==="
  out=$(run_corpus "$corpus" 2>&1)
  echo "$out"
  # last echoed line is "passed total"
  read p t <<< "$(echo "$out" | tail -1)"
  TOTAL_PASS=$((TOTAL_PASS + p))
  TOTAL_ASRT=$((TOTAL_ASRT + t))
  printf "%-25s %10d %10d\n" "$corpus" "$p" "$t" >> "$SUMMARY"
done

OVERALL_F1=$(awk "BEGIN { printf \"%.3f\", $TOTAL_PASS / ($TOTAL_ASRT == 0 ? 1 : $TOTAL_ASRT) }")
{
  echo ""
  printf "%-25s %10d %10d\n" "TOTAL" "$TOTAL_PASS" "$TOTAL_ASRT"
  echo ""
  echo "overall F1 = $OVERALL_F1"
} >> "$SUMMARY"

echo ""
echo "=== SUMMARY ==="
cat "$SUMMARY"
echo ""
echo "results dir: $RESULTS_DIR"
