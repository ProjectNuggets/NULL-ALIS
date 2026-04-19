#!/usr/bin/env bash
# autoresearch harness — fixed contract, do not modify during iteration loop
#
# Reads .spike/benchmark.json, runs each prompt against the gateway, grades
# based on tool calls and reply text, writes per-iteration results to stdout
# and a summary line suitable for results.tsv.
#
# Usage:
#   .spike/run.sh                  # run once, print summary + per-prompt detail
#   .spike/run.sh --quiet          # only the summary line
#   .spike/run.sh --one b1_...     # run a single benchmark id
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --one) ONLY="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

URL=$(jq -r '.gateway.url' "$BENCH_FILE")
TOKEN=$(jq -r '.gateway.internal_token' "$BENCH_FILE")
USER_ID=$(jq -r '.gateway.user_id' "$BENCH_FILE")
PREFIX=$(jq -r '.gateway.session_key_prefix' "$BENCH_FILE")
SESSION_KEY="agent:zaki-bot:user:${USER_ID}:main"

COMMIT=$(git rev-parse --short HEAD)
PASS=0
TOTAL=0
TOOL_CALL_SUM=0
LATENCY_SUM=0
CRASHED=0
DETAIL=()

grade_one() {
  local id="$1" prompt="$2" must_tools="$3" must_not="$4" should="$5" weight="$6"
  TOTAL=$((TOTAL+1))
  local outfile="$OUT_DIR/${id}.sse"
  local started
  started=$(date +%s%N)

  curl -sN -X POST "$URL" \
    -H "X-Internal-Token: $TOKEN" \
    -H "X-Zaki-User-Id: $USER_ID" \
    -H "Content-Type: application/json" \
    --max-time 180 \
    -d "$(jq -n --arg m "$prompt" --arg s "$SESSION_KEY" '{message:$m, session_key:$s}')" \
    > "$outfile" 2>&1

  local rc=$?
  local ended
  ended=$(date +%s%N)
  local latency_ms=$(( (ended - started) / 1000000 ))
  LATENCY_SUM=$((LATENCY_SUM + latency_ms))

  if [[ $rc -ne 0 ]] || ! grep -q 'event: done' "$outfile"; then
    CRASHED=$((CRASHED+1))
    DETAIL+=("$id  CRASH  ${latency_ms}ms  (curl rc=$rc)")
    return
  fi

  if grep -q '"type":"error"' "$outfile"; then
    DETAIL+=("$id  FAIL   ${latency_ms}ms  stream-error")
    return
  fi

  # Extract tool calls from progress frames
  local tools_fired
  tools_fired=$(grep -oE '"phase":"tool","state":"start"[^}]*"tool":"[^"]+"' "$outfile" \
    | grep -oE '"tool":"[^"]+"' | sort -u | tr '\n' ',' | sed 's/,$//')
  local tool_count
  tool_count=$(grep -c '"phase":"tool","state":"start"' "$outfile" || true)
  TOOL_CALL_SUM=$((TOOL_CALL_SUM + tool_count))

  # Reconstruct reply by concatenating deltas (skip narration, only final_reply kind)
  local reply
  reply=$(grep -oE '"delta":"[^"]*"' "$outfile" | sed 's/^"delta":"//;s/"$//' | tr -d '\n' | head -c 2000)

  # Grading
  local pass=1
  local reasons=()

  # must_call_any_of
  if [[ -n "$must_tools" && "$must_tools" != "null" ]]; then
    local found=0
    IFS=',' read -ra want <<< "$must_tools"
    for t in "${want[@]}"; do
      if echo "$tools_fired" | grep -q "\"$t\""; then
        found=1
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      pass=0
      reasons+=("no-req-tool(want=$must_tools fired=$tools_fired)")
    fi
  fi

  # must_not_contain_phrases
  if [[ -n "$must_not" && "$must_not" != "null" ]]; then
    local hit_banned=""
    while IFS= read -r phrase; do
      [[ -z "$phrase" ]] && continue
      if echo "$reply" | grep -iqF "$phrase"; then
        hit_banned="$phrase"
        break
      fi
    done <<< "$must_not"
    if [[ -n "$hit_banned" ]]; then
      pass=0
      reasons+=("banned-phrase(\"$hit_banned\")")
    fi
  fi

  # should_contain_any (soft: flag but don't fail if must_call_tool passed)
  if [[ -n "$should" && "$should" != "null" ]]; then
    local found_any=0
    while IFS= read -r phrase; do
      [[ -z "$phrase" ]] && continue
      if echo "$reply" | grep -iqF "$phrase"; then
        found_any=1
        break
      fi
    done <<< "$should"
    if [[ $found_any -eq 0 ]]; then
      reasons+=("weak-reply(missing expected terms)")
      # only downgrade if reply is short/empty
      if [[ ${#reply} -lt 30 ]]; then
        pass=0
      fi
    fi
  fi

  if [[ $pass -eq 1 ]]; then
    PASS=$((PASS+1))
    DETAIL+=("$id  PASS   ${latency_ms}ms  tools=[$tools_fired]")
  else
    DETAIL+=("$id  FAIL   ${latency_ms}ms  tools=[$tools_fired]  reasons=${reasons[*]}  reply_head=${reply:0:120}")
  fi
}

# Drive the loop from jq
IFS=$'\n'
while read -r row; do
  id=$(echo "$row" | jq -r '.id')
  [[ -n "$ONLY" && "$ONLY" != "$id" ]] && continue
  prompt=$(echo "$row" | jq -r '.prompt')
  must_tools=$(echo "$row" | jq -r '.grading.must_call_any_of // [] | join(",")')
  must_not=$(echo "$row" | jq -r '.grading.must_not_contain_phrases // [] | .[]')
  should=$(echo "$row" | jq -r '.grading.should_contain_any // [] | .[]')
  weight=$(echo "$row" | jq -r '.grading.weight // 1.0')
  grade_one "$id" "$prompt" "$must_tools" "$must_not" "$should" "$weight"
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
  echo "pass=$PASS/$TOTAL  pass_rate=$PASS_RATE  mean_tools=$MEAN_TOOLS  mean_latency_ms=$MEAN_LAT  status=$STATUS  crashes=$CRASHED"
  echo "SSE traces: $OUT_DIR"
fi

# TSV row (always last line, tab-separated)
printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$COMMIT" "$PASS_RATE" "$MEAN_TOOLS" "$MEAN_LAT" "$STATUS" "baseline_or_keep"

[[ $CRASHED -gt 0 ]] && exit 1 || exit 0
