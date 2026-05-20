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
#     commit\tpass_rate\tmean_tool_calls\tmean_latency_ms\tp50_ttft_ms\tp95_ttft_ms\tstatus\tdescription
#   Exit code: 0 if all benchmarks returned (even if they failed grading),
#              1 if a benchmark crashed (SSE error / gateway unreachable).
#
# p95 TTFT <= 4.0s is the SLO bench gate for every subsequent block.

set -uo pipefail

cd "$(dirname "$0")/.."
BENCH_FILE=".spike/benchmark.json"
OUT_DIR=".spike/runs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"

# v1.14.14 Phase 5 — activate the stability JSONL diagnostic shipped by Phase 4
# (commit e0d377ac, src/agent/context_engine.zig::writeStabilityJsonl). Each
# turn against the gateway during this bench run writes one JSONL line with
# the four phase durations + the assembled stable_prefix_hash + session.
#
# Bench-default-on; prod-default-off (§14.6 honest config). The production
# gateway has NULLALIS_STABILITY_JSON_PATH unset → zero file growth, zero I/O
# overhead. Operators can also pre-set this env var to override the in-harness
# default (e.g., to redirect to a shared collection path during CI runs).
#
# Consumed by the drift-detection block at the END of this script — it reads
# the JSONL and fails the bench run if any session_key shows >1 distinct
# stable_prefix_hash across its turns.
export NULLALIS_STABILITY_JSON_PATH="${NULLALIS_STABILITY_JSON_PATH:-$OUT_DIR/stability.jsonl}"

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
TTFT_VALUES=()

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
#   REPLY_TEXT, TOOLS_FIRED, TOOL_COUNT, LATENCY_MS, TTFT_MS,
#   TURN_OK (0/1), TURN_REASON
run_single_turn() {
  local outfile="$1" session_key="$2" prompt="$3"
  local started events_file
  started=$(date +%s%N)
  events_file="${outfile}.events.tsv"
  : > "$events_file"

  curl -sN -X POST "$URL" \
    -H "X-Internal-Token: $TOKEN" \
    -H "X-Zaki-User-Id: $USER_ID" \
    -H "Content-Type: application/json" \
    --max-time 180 \
    -d "$(jq -n --arg m "$prompt" --arg s "$session_key" '{message:$m, session_key:$s}')" \
    2>&1 \
    | while IFS= read -r line; do
        printf "%s\t%s\n" "$(date +%s%N)" "$line" >> "$events_file"
        printf "%s\n" "$line"
      done > "$outfile"

  local rc=${PIPESTATUS[0]}
  local ended
  ended=$(date +%s%N)
  LATENCY_MS=$(( (ended - started) / 1000000 ))
  local first_token_ns
  first_token_ns=$(awk -F '\t' '
    $2 ~ /^data:/ &&
    $2 ~ /"delta":"[^"]+/ &&
    ($2 !~ /"stream_kind":/ || $2 ~ /"stream_kind":"final_reply"/) {
      print $1
      exit
    }
  ' "$events_file")
  if [[ -n "$first_token_ns" ]]; then
    TTFT_MS=$(( (first_token_ns - started) / 1000000 ))
  else
    TTFT_MS=0
  fi

  if [[ $rc -ne 0 ]] || ! grep -q 'event: done' "$outfile"; then
    TURN_OK=0
    TURN_REASON="CRASH (curl rc=$rc)"
    REPLY_TEXT=""
    TOOLS_FIRED=""
    TOOL_COUNT=0
    TTFT_MS=0
    return
  fi

  if grep -q '"type":"error"' "$outfile"; then
    TURN_OK=0
    TURN_REASON="stream-error"
    REPLY_TEXT=""
    TOOLS_FIRED=""
    TOOL_COUNT=0
    TTFT_MS=0
    return
  fi

  # v1.14.18 — match v1.14.13 NarrationObserver SSE shapes: tool_start / tool_done
  # alongside legacy "phase":"tool". Before this fix, the parser ONLY matched the
  # plain "phase":"tool" form and missed tool_start/tool_done events emitted by
  # Agent F's wiring → V-inf b1/b2/b9 (proactive_research) reported fired="" even
  # while gateway logs showed web_search firing. TOOL_COUNT uses the narrower
  # tool_start-only pattern to avoid double-counting (start + done would 2x).
  TOOLS_FIRED=$(grep -oE '"phase":"tool(_start|_done)?"[^}]*"tool":"[^"]+"' "$outfile" \
    | grep -oE '"tool":"[^"]+"' | sort -u | tr '\n' ',' | sed 's/,$//')
  TOOL_COUNT=$(grep -oE '"phase":"tool(_start)?"[^}]*"tool":"[^"]+"' "$outfile" | wc -l | tr -d ' ')
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
    if [[ $TTFT_MS -gt 0 ]]; then
      TTFT_VALUES+=("$TTFT_MS")
    fi

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

percentile_ms() {
  local pct="$1"
  shift
  if [[ $# -eq 0 ]]; then
    echo "na"
    return
  fi
  printf "%s\n" "$@" | sort -n | awk -v pct="$pct" '
    NF { values[++n] = $1 }
    END {
      if (n == 0) {
        print "na"
        exit
      }
      idx = int(pct * n)
      if (idx < pct * n) idx++
      if (idx < 1) idx = 1
      if (idx > n) idx = n
      printf "%.0f", values[idx]
    }
  '
}

PASS_RATE=$(awk -v p="$PASS" -v t="$TOTAL" 'BEGIN{printf "%.3f", p/t}')
MEAN_TOOLS=$(awk -v s="$TOOL_CALL_SUM" -v t="$TOTAL" 'BEGIN{printf "%.2f", s/t}')
MEAN_LAT=$(awk -v s="$LATENCY_SUM" -v t="$TOTAL" 'BEGIN{printf "%.0f", s/t}')
P50_TTFT=$(percentile_ms 0.50 "${TTFT_VALUES[@]}")
P95_TTFT=$(percentile_ms 0.95 "${TTFT_VALUES[@]}")
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
  echo "pass=$PASS/$TOTAL  pass_rate=$PASS_RATE  mean_tools=$MEAN_TOOLS  mean_latency_ms=$MEAN_LAT  p50_ttft_ms=$P50_TTFT  p95_ttft_ms=$P95_TTFT  status=$STATUS  crashes=$CRASHED"
  echo "SSE traces: $OUT_DIR"
fi

# v1.14.14 Phase 5 — per-session prefix-stability CI assertion.
# Activates the stability.jsonl diagnostic from Phase 4. Catches the silent
# prefix-drift regression class: a prompt-construction change that increases
# latency/cost by 1.5-3x via collapsed KV-cache hits but leaves agent answers
# byte-identical. Invisible to LoCoMo/V-inf/τ-bench but lethal to production.
#
# Triggered only when NULLALIS_STABILITY_JSON_PATH was set during the bench
# run. If the JSONL file is missing or empty, skip (back-compat with runs
# before stability emission landed).
#
# Fails the bench (non-zero exit) if any single session_key shows >1 distinct
# stable_prefix_hash across its turns. Hash drift mid-session = the bug.
if [[ -n "${NULLALIS_STABILITY_JSON_PATH:-}" && -s "$NULLALIS_STABILITY_JSON_PATH" ]]; then
  drift_sessions=$(jq -s 'group_by(.session) | map({
      session: .[0].session,
      hashes: ([.[].stable_prefix_hash] | unique),
      turns: length
    }) | map(select(.turns > 1 and (.hashes | length) > 1))' \
    "$NULLALIS_STABILITY_JSON_PATH" 2>/dev/null)
  if [[ -n "$drift_sessions" && "$drift_sessions" != "[]" ]]; then
    echo "STABILITY_DRIFT_DETECTED — sessions with multiple prefix hashes:" >&2
    echo "$drift_sessions" >&2
    echo "Cause: a prompt construction change drifted the stable prefix mid-session." >&2
    echo "Effect: KV-cache misses on every turn after the first → 1.5-3x latency + cost." >&2
    echo "Fix: identify the prompt section that varies turn-to-turn; move to volatile half." >&2
    exit 2
  fi
fi

printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$COMMIT" "$PASS_RATE" "$MEAN_TOOLS" "$MEAN_LAT" "$P50_TTFT" "$P95_TTFT" "$STATUS" "baseline_or_keep"

[[ $CRASHED -gt 0 ]] && exit 1 || exit 0
