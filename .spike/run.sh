#!/usr/bin/env bash
# autoresearch harness — fixed contract, do not modify during iteration loop
#
# Reads .spike/benchmark.json, runs each benchmark against the gateway, grades
# based on tool calls and reply text, writes per-iteration results to stdout
# and a summary line suitable for results.tsv.
#
# Benchmarks support two shapes:
#
#   Single-turn (legacy):
#     { "id": "b1", "category": "...", "prompt": "...", "grading": { ... } }
#
#   Multi-turn:
#     { "id": "b16", "category": "...", "turns": [
#         { "prompt": "...", "grading": { ... } },
#         { "prompt": "...", "grading": { ... } }
#       ] }
#     All turns share the same session_key — the agent sees turn 1 history
#     when responding to turn 2. Benchmark passes iff EVERY turn passes.
#
# Usage:
#   .spike/run.sh                  # run once, print per-benchmark + per-category summary
#   .spike/run.sh --quiet          # only the summary line
#   .spike/run.sh --one b1_...     # run a single benchmark id
#   .spike/run.sh --polluted       # reuse :main session (exercise accumulated pollution)
#
# Output contract:
#   Last stdout line: TSV row for results.tsv:
#     commit\tpass_rate\tmean_tool_calls\tmean_latency_ms\tstatus\tdescription
#   Exit code: 0 if all benchmarks returned (even if they failed grading),
#              1 if a benchmark crashed (SSE error / gateway unreachable).

set -uo pipefail

cd "$(dirname "$0")/.."
BENCH_FILE=".spike/benchmark.json"
OUT_DIR=".spike/runs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"

QUIET=0
ONLY=""
POLLUTED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --one) ONLY="$2"; shift 2 ;;
    --polluted) POLLUTED=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

URL=$(jq -r '.gateway.url' "$BENCH_FILE")
TOKEN=$(jq -r '.gateway.internal_token' "$BENCH_FILE")
USER_ID=$(jq -r '.gateway.user_id' "$BENCH_FILE")
PREFIX=$(jq -r '.gateway.session_key_prefix' "$BENCH_FILE")
SESSION_SUFFIX=$(date +%s)

COMMIT=$(git rev-parse --short HEAD)
PASS=0
TOTAL=0
TOOL_CALL_SUM=0
LATENCY_SUM=0
CRASHED=0
DETAIL=()

# Per-category tallies — parallel arrays (bash 3.2 compat, macOS default).
# CAT_NAMES[i] <-> CAT_PASSES[i] <-> CAT_TOTALS[i]
CAT_NAMES=()
CAT_PASSES=()
CAT_TOTALS=()

cat_index() {
  local target="$1" i=0
  while [[ $i -lt ${#CAT_NAMES[@]} ]]; do
    if [[ "${CAT_NAMES[$i]}" == "$target" ]]; then
      echo "$i"
      return
    fi
    i=$((i+1))
  done
  echo "-1"
}

cat_bump_total() {
  local cat="$1" idx
  idx=$(cat_index "$cat")
  if [[ "$idx" == "-1" ]]; then
    CAT_NAMES+=("$cat")
    CAT_PASSES+=(0)
    CAT_TOTALS+=(1)
  else
    CAT_TOTALS[$idx]=$(( ${CAT_TOTALS[$idx]} + 1 ))
  fi
}

cat_bump_pass() {
  local cat="$1" idx
  idx=$(cat_index "$cat")
  [[ "$idx" == "-1" ]] && return
  CAT_PASSES[$idx]=$(( ${CAT_PASSES[$idx]} + 1 ))
}

# Runs one turn against the gateway. Populates:
#   REPLY_TEXT, TOOLS_FIRED, TOOL_COUNT, LATENCY_MS, TURN_OK (0/1), TURN_REASON
run_single_turn() {
  local outfile="$1" session_key="$2" prompt="$3"
  local started
  started=$(date +%s%N)

  curl -sN -X POST "$URL" \
    -H "X-Internal-Token: $TOKEN" \
    -H "X-Zaki-User-Id: $USER_ID" \
    -H "Content-Type: application/json" \
    --max-time 180 \
    -d "$(jq -n --arg m "$prompt" --arg s "$session_key" '{message:$m, session_key:$s}')" \
    > "$outfile" 2>&1

  local rc=$?
  local ended
  ended=$(date +%s%N)
  LATENCY_MS=$(( (ended - started) / 1000000 ))

  if [[ $rc -ne 0 ]] || ! grep -q 'event: done' "$outfile"; then
    TURN_OK=0
    TURN_REASON="CRASH (curl rc=$rc)"
    REPLY_TEXT=""
    TOOLS_FIRED=""
    TOOL_COUNT=0
    return
  fi

  if grep -q '"type":"error"' "$outfile"; then
    TURN_OK=0
    TURN_REASON="stream-error"
    REPLY_TEXT=""
    TOOLS_FIRED=""
    TOOL_COUNT=0
    return
  fi

  TOOLS_FIRED=$(grep -oE '"phase":"tool"[^}]*"tool":"[^"]+"' "$outfile" \
    | grep -oE '"tool":"[^"]+"' | sort -u | tr '\n' ',' | sed 's/,$//')
  TOOL_COUNT=$(grep -oE '"phase":"tool"[^}]*"tool":"[^"]+"' "$outfile" | wc -l | tr -d ' ')
  REPLY_TEXT=$(grep -oE '"delta":"[^"]*"' "$outfile" | sed 's/^"delta":"//;s/"$//' | tr -d '\n' | head -c 2000)
  TURN_OK=1
  TURN_REASON=""
}

# Grade a single turn against its grading block. Populates TURN_OK + TURN_REASON.
grade_turn() {
  local must_tools="$1" must_not="$2" should="$3"

  if [[ $TURN_OK -eq 0 ]]; then
    # Crash / stream-error already recorded
    return
  fi

  local pass=1
  local reasons=()

  if [[ -n "$must_tools" && "$must_tools" != "null" ]]; then
    local found=0
    IFS=',' read -ra want <<< "$must_tools"
    for t in "${want[@]}"; do
      if echo "$TOOLS_FIRED" | grep -q "\"$t\""; then
        found=1
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      pass=0
      reasons+=("no-req-tool(want=$must_tools fired=$TOOLS_FIRED)")
    fi
  fi

  if [[ -n "$must_not" && "$must_not" != "null" ]]; then
    local hit_banned=""
    while IFS= read -r phrase; do
      [[ -z "$phrase" ]] && continue
      if echo "$REPLY_TEXT" | grep -iqF "$phrase"; then
        hit_banned="$phrase"
        break
      fi
    done <<< "$must_not"
    if [[ -n "$hit_banned" ]]; then
      pass=0
      reasons+=("banned-phrase(\"$hit_banned\")")
    fi
  fi

  if [[ -n "$should" && "$should" != "null" ]]; then
    local found_any=0
    while IFS= read -r phrase; do
      [[ -z "$phrase" ]] && continue
      if echo "$REPLY_TEXT" | grep -iqF "$phrase"; then
        found_any=1
        break
      fi
    done <<< "$should"
    if [[ $found_any -eq 0 ]]; then
      reasons+=("weak-reply(missing expected terms)")
      if [[ ${#REPLY_TEXT} -lt 30 ]]; then
        pass=0
      fi
    fi
  fi

  if [[ $pass -eq 1 ]]; then
    TURN_OK=1
    TURN_REASON=""
  else
    TURN_OK=0
    TURN_REASON="${reasons[*]}"
  fi
}

# Run one benchmark (single-turn or multi-turn). Updates global tallies.
grade_benchmark() {
  local id="$1" category="$2" is_multi="$3" turns_json="$4"

  TOTAL=$((TOTAL+1))
  cat_bump_total "$category"

  local session_key
  if [[ $POLLUTED -eq 1 ]]; then
    session_key="agent:zaki-bot:user:${USER_ID}:main"
  else
    session_key="agent:zaki-bot:user:${USER_ID}:thread:bench-${id}-${SESSION_SUFFIX}"
  fi

  local turn_idx=0
  local turn_count
  turn_count=$(echo "$turns_json" | jq 'length')
  local bench_pass=1
  local bench_latency=0
  local bench_tool_count=0
  local first_tools=""
  local first_reason=""

  while read -r turn_spec; do
    local outfile="$OUT_DIR/${id}_t${turn_idx}.sse"
    local prompt must_tools must_not should
    prompt=$(echo "$turn_spec" | jq -r '.prompt')
    must_tools=$(echo "$turn_spec" | jq -r '.grading.must_call_any_of // [] | join(",")')
    must_not=$(echo "$turn_spec" | jq -r '.grading.must_not_contain_phrases // [] | .[]')
    should=$(echo "$turn_spec" | jq -r '.grading.should_contain_any // [] | .[]')

    run_single_turn "$outfile" "$session_key" "$prompt"
    bench_latency=$((bench_latency + LATENCY_MS))
    bench_tool_count=$((bench_tool_count + TOOL_COUNT))

    if [[ -z "$first_tools" ]]; then first_tools="$TOOLS_FIRED"; fi

    if [[ $TURN_OK -eq 0 ]] && [[ -z "${TURN_REASON:-}" || "$TURN_REASON" == CRASH* || "$TURN_REASON" == stream-error* ]]; then
      # Hard failure (no response) — short-circuit the benchmark
      bench_pass=0
      first_reason="$TURN_REASON"
      if [[ "$TURN_REASON" == CRASH* ]]; then
        CRASHED=$((CRASHED+1))
      fi
      break
    fi

    grade_turn "$must_tools" "$must_not" "$should"
    if [[ $TURN_OK -eq 0 ]]; then
      bench_pass=0
      if [[ -z "$first_reason" ]]; then
        first_reason="t${turn_idx}:${TURN_REASON}"
      fi
    fi

    turn_idx=$((turn_idx + 1))
  done < <(echo "$turns_json" | jq -c '.[]')

  LATENCY_SUM=$((LATENCY_SUM + bench_latency))
  TOOL_CALL_SUM=$((TOOL_CALL_SUM + bench_tool_count))

  local multi_tag=""
  [[ "$is_multi" == "1" ]] && multi_tag=" (${turn_count}t)"

  if [[ $bench_pass -eq 1 ]]; then
    PASS=$((PASS+1))
    cat_bump_pass "$category"
    DETAIL+=("$id  PASS${multi_tag}  ${bench_latency}ms  [$category]  tools=[$first_tools]")
  else
    DETAIL+=("$id  FAIL${multi_tag}  ${bench_latency}ms  [$category]  tools=[$first_tools]  reasons=$first_reason")
  fi
}

# Drive the loop from jq
IFS=$'\n'
while read -r row; do
  id=$(echo "$row" | jq -r '.id')
  [[ -n "$ONLY" && "$ONLY" != "$id" ]] && continue
  category=$(echo "$row" | jq -r '.category // "uncategorized"')

  # Detect shape: has "turns" array (multi) vs "prompt"+"grading" (single)
  local_turns=$(echo "$row" | jq -c 'if .turns then .turns else [{prompt:.prompt, grading:.grading}] end')
  local_is_multi=$(echo "$row" | jq -r 'if .turns then "1" else "0" end')

  grade_benchmark "$id" "$category" "$local_is_multi" "$local_turns"
done < <(jq -c '.benchmarks[]' "$BENCH_FILE")
unset IFS

# Summary
if [[ $TOTAL -eq 0 ]]; then
  echo "no benchmarks ran (filter=$ONLY)" >&2
  exit 2
fi

PASS_RATE=$(awk -v p="$PASS" -v t="$TOTAL" 'BEGIN{printf "%.3f", p/t}')
MEAN_TOOLS=$(awk -v s="$TOOL_CALL_SUM" -v t="$TOTAL" 'BEGIN{printf "%.2f", s/t}')
MEAN_LAT=$(awk -v s="$LATENCY_SUM" -v t="$TOTAL" 'BEGIN{printf "%.0f", s/t}')
STATUS="graded"
[[ $CRASHED -gt 0 ]] && STATUS="partial-crash"

if [[ $QUIET -eq 0 ]]; then
  echo "=== autoresearch batch @ $COMMIT  $(date '+%H:%M:%S') ==="
  for line in "${DETAIL[@]}"; do echo "  $line"; done
  echo ""
  echo "=== per-category ==="
  # Sort by category name for stable output
  paste <(printf "%s\n" "${CAT_NAMES[@]}") \
        <(printf "%s\n" "${CAT_PASSES[@]}") \
        <(printf "%s\n" "${CAT_TOTALS[@]}") \
    | sort \
    | while IFS=$'\t' read -r cat p t; do
        rate=$(awk -v p="$p" -v t="$t" 'BEGIN{printf "%.2f", p/t}')
        printf "  %-28s %d/%d  (%s)\n" "$cat" "$p" "$t" "$rate"
      done
  echo ""
  echo "pass=$PASS/$TOTAL  pass_rate=$PASS_RATE  mean_tools=$MEAN_TOOLS  mean_latency_ms=$MEAN_LAT  status=$STATUS  crashes=$CRASHED"
  echo "SSE traces: $OUT_DIR"
fi

printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$COMMIT" "$PASS_RATE" "$MEAN_TOOLS" "$MEAN_LAT" "$STATUS" "baseline_or_keep"

[[ $CRASHED -gt 0 ]] && exit 1 || exit 0
