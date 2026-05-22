#!/usr/bin/env bash
# ROADMAP v1.14.18 Step 10 (B8) — quarterly test-reference coverage audit.
#
# Static-analysis pass: enumerate every `pub fn` in src/, match each name
# against the test corpus, emit the set of untested production surfaces.
# Documented in `.spike/coverage/README.md` — read it before extending.
#
# One-off cadence; not a CI gate.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TS="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT="$ROOT/.spike/coverage/$TS"
mkdir -p "$OUT"

cd "$ROOT"

# 1) Every `pub fn` in src/, recorded as `file:line\tfn_name`.
#    Grabs `pub fn <name>(` and `pub inline fn <name>(`. Drops `_` (anon).
#    Excludes tests (`*_test.zig`) and the test corpus block by design —
#    we want production surfaces, not test helpers.
pub_fns="$OUT/pub_fns.txt"
> "$pub_fns"
find src -type f -name '*.zig' ! -name '*_test.zig' -print0 \
  | xargs -0 grep -EnH 'pub (inline )?fn [A-Za-z_][A-Za-z0-9_]*\(' \
  | sed -E 's#^(.*):([0-9]+):.*pub (inline )?fn ([A-Za-z_][A-Za-z0-9_]*)\(.*$#\1:\2\t\4#' \
  | grep -v -E '\t_$' \
  | sort -u \
  > "$pub_fns"

total_pub_fns=$(wc -l < "$pub_fns" | tr -d ' ')

# 2) Pull the set of unique function names. Some names recur across
#    files (different impls with the same name); we de-dup the names
#    for the test-corpus lookup but keep the file:line listing intact.
fn_names="$OUT/_fn_names.tmp"
cut -f2 "$pub_fns" | sort -u > "$fn_names"

# 3) Build the test corpus — `test "..."` blocks anywhere + every file
#    under tests/. We grep names against the corpus as literal tokens.
test_corpus="$OUT/_test_corpus.tmp"
{
  # In-source test blocks (the bulk).
  find src -type f -name '*.zig' -print0 \
    | xargs -0 grep -E 'test "[^"]+"|^test \{' || true
  # Standalone tests under tests/.
  find tests -type f -name '*.zig' -print0 2>/dev/null \
    | xargs -0 cat 2>/dev/null || true
} > "$test_corpus"

# 4) For each name, check whether the corpus mentions it as a word.
#    The word-boundary check avoids matching inside longer identifiers.
tested="$OUT/tested_pub_fns.txt"
untested="$OUT/untested_pub_fns.txt"
> "$tested"
> "$untested"

while IFS= read -r name; do
  [ -z "$name" ] && continue
  # `\b<name>\b` against the corpus. -m1 stops at first hit per file.
  if grep -qE "\\b${name}\\b" "$test_corpus"; then
    echo "$name" >> "$tested"
  else
    echo "$name" >> "$untested"
  fi
done < "$fn_names"

tested_count=$(wc -l < "$tested" | tr -d ' ')
untested_count=$(wc -l < "$untested" | tr -d ' ')
total_unique_names=$(wc -l < "$fn_names" | tr -d ' ')

# 5) Top-10 untested-per-file concentration. Join untested names back
#    against pub_fns so we get file paths, then count.
top_file="$OUT/_top_concentration.tmp"
join -t $'\t' -1 2 -2 1 \
  <(sort -t $'\t' -k2,2 "$pub_fns") \
  <(sort "$untested") \
  | cut -f2 \
  | sed -E 's/:[0-9]+$//' \
  | sort \
  | uniq -c \
  | sort -rn \
  | head -10 \
  > "$top_file"

# 6) Summary report.
summary="$OUT/summary.txt"
{
  echo "ROADMAP v1.14.18 Step 10 (B8) — test-reference coverage audit"
  echo "Timestamp: $TS (UTC)"
  echo "Branch:    $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  echo "HEAD:      $(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo
  echo "Totals"
  echo "  pub fn declarations (file:line):  $total_pub_fns"
  echo "  unique pub fn names:              $total_unique_names"
  echo "  tested (at least one ref):        $tested_count"
  echo "  untested (zero refs):             $untested_count"
  if [ "$total_unique_names" -gt 0 ]; then
    pct=$(awk -v a="$tested_count" -v b="$total_unique_names" 'BEGIN{printf("%.1f", 100*a/b)}')
    echo "  tested-by-name rate:              ${pct}%"
  fi
  echo
  echo "Top-10 files by untested pub-fn count"
  echo "  (count   file)"
  sed -E 's/^[[:space:]]+/  /' "$top_file"
  echo
  echo "Methodology + limitations: see .spike/coverage/README.md"
} > "$summary"

# Cleanup temp files.
rm -f "$fn_names" "$test_corpus" "$top_file"

echo "Coverage audit written to: $OUT"
echo
cat "$summary"
