# P4 Tier Gate + P16 Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate low-scoring RRF candidates from the fallback bucket via an env-var-controlled score threshold, surface the count through SelectionStats + the trace event, then verify build/tests/bench pass.

**Architecture:** A single `readTierGateMinScore()` env-var reader returns a `f64` threshold (0.0 = off). In `loadContextWithRuntimeDetailed`, before each fallback-bucket append of an RRF candidate that already carries `final_score`, the gate check `cand.final_score < threshold` filters the candidate and increments `stats.tier_gated_count`. The semantic bucket (continuity-family keys) is never gated — it gets its content from a different criteria than RRF score. `bucketSummary` in `context_engine.zig` gains a `gated:N` field so the trace event's `status` string is self-documenting.

**Tech Stack:** Zig 0.15.2, `std.posix.getenv`, `std.fmt.parseFloat`, `std.fmt.allocPrint` — all already used in the same file.

**Branch:** `feat/memory-intelligence-sprint` — DO NOT commit to main.

**Build command:** `zig build -Dchannels=cli`
**Test command:** `zig build test -Dchannels=cli`

---

### File Map

| File | Change |
|------|--------|
| `src/agent/memory_loader.zig` | Add `tier_gated_count` field to `SelectionStats`; add `readTierGateMinScore()` near other env-var readers (line ~1383); insert gate check at the fallback-append site in `loadContextWithRuntimeDetailed` (line ~818); add 2 inline tests |
| `src/agent/context_engine.zig` | Extend `bucketSummary` format string to include `,gated:{d}` |

---

### Task 14: SelectionStats field + env-var reader

**Files:**
- Modify: `src/agent/memory_loader.zig:95-96` (after `fallback_bucket_bytes`)
- Modify: `src/agent/memory_loader.zig:1386` (after `readEntityOverlapEnabled`)

- [ ] **Step 1: Write the failing test for the env-var reader**

Add at the bottom of `src/agent/memory_loader.zig` (inside the test block, before the final `}`):

```zig
test "tier gate: readTierGateMinScore returns 0.0 when env var absent" {
    // Gate is OFF by default; callers treat 0.0 as "disabled".
    // This test assumes NULLALIS_TIER_GATE_MIN_SCORE is not set in the test env.
    const score = readTierGateMinScore();
    try std.testing.expectEqual(@as(f64, 0.0), score);
}

test "tier gate: SelectionStats.tier_gated_count initialises to zero" {
    const s = SelectionStats{};
    try std.testing.expectEqual(@as(usize, 0), s.tier_gated_count);
}
```

- [ ] **Step 2: Run to confirm both tests fail (symbol not found)**

```
zig build test -Dchannels=cli 2>&1 | grep "tier_gate\|tier gate"
```

Expected: compile error `no function named 'readTierGateMinScore'` and `no field 'tier_gated_count'`.

- [ ] **Step 3: Add `tier_gated_count` to `SelectionStats`**

In `src/agent/memory_loader.zig`, find the struct (line ~79) and add the field after `fallback_bucket_bytes`:

```zig
    fallback_bucket_bytes: usize = 0,
    /// P4 — candidates blocked by the tier gate (score below NULLALIS_TIER_GATE_MIN_SCORE).
    /// 0 when gate is disabled (default) or no candidates were filtered.
    tier_gated_count: usize = 0,
    context_bytes: usize = 0,
```

- [ ] **Step 4: Add `readTierGateMinScore()` near the other env-var readers**

In `src/agent/memory_loader.zig`, find the comment `// ── P1: Entity Overlap Callback` (line ~1380) and insert the P4 block immediately **before** it:

```zig
// ── P4: Tier Gate ───────────────────────────────────────────────────────────

/// Minimum RRF `final_score` for fallback-bucket candidates.
/// 0.0 (default) disables the gate entirely.
/// Set NULLALIS_TIER_GATE_MIN_SCORE=0.10 to filter low-confidence hits.
/// Only applies to the runtime (hybrid) path; keyword-only path is unaffected.
fn readTierGateMinScore() f64 {
    const val = std.posix.getenv("NULLALIS_TIER_GATE_MIN_SCORE") orelse return 0.0;
    const parsed = std.fmt.parseFloat(f64, val) catch return 0.0;
    return if (parsed >= 0.0) parsed else 0.0;
}

```

- [ ] **Step 5: Run tests — both new tests must pass**

```
zig build test -Dchannels=cli 2>&1 | grep -E "tier gate|FAIL|OK" | head -20
```

Expected: both `tier gate` tests PASS; zero compile errors; the 2 pre-existing telegram/onboarding failures are the only failures (unrelated to this sprint).

- [ ] **Step 6: Commit**

```bash
git add src/agent/memory_loader.zig
git commit -m "feat(memory): P4 tier gate — SelectionStats.tier_gated_count + readTierGateMinScore"
```

---

### Task 15: Gate logic in fallback path + bucketSummary update

**Files:**
- Modify: `src/agent/memory_loader.zig:816-822` (fallback-bucket else branch in `loadContextWithRuntimeDetailed`)
- Modify: `src/agent/context_engine.zig:1079-1088` (`bucketSummary` format string)

- [ ] **Step 1: Write a failing test for bucketSummary gated field**

Add to the existing test block in `src/agent/context_engine.zig` (after the last `bucketSummary`-related test, or create a new one at the bottom of the `// Tests` section):

```zig
test "bucketSummary includes gated field" {
    const allocator = std.testing.allocator;
    const stats = memory_loader.SelectionStats{
        .available = true,
        .continuity_bucket_entries = 1,
        .semantic_bucket_entries = 3,
        .fallback_bucket_entries = 2,
        .graph_recall_neighbor_count = 4,
        .tier_gated_count = 5,
    };
    const s = try bucketSummary(allocator, stats);
    defer allocator.free(s);
    try std.testing.expectEqualStrings(
        "continuity:1,semantic:3,fallback:2,graph:4,gated:5",
        s,
    );
}
```

- [ ] **Step 2: Run to confirm the test fails**

```
zig build test -Dchannels=cli 2>&1 | grep "bucketSummary includes gated"
```

Expected: FAIL — the format string currently omits `gated`.

- [ ] **Step 3: Update `bucketSummary` in context_engine.zig**

Find `bucketSummary` at line ~1078 and replace the body:

```zig
fn bucketSummary(allocator: std.mem.Allocator, stats: memory_loader.SelectionStats) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "continuity:{d},semantic:{d},fallback:{d},graph:{d},gated:{d}",
        .{
            stats.continuity_bucket_entries,
            stats.semantic_bucket_entries,
            stats.fallback_bucket_entries,
            stats.graph_recall_neighbor_count,
            stats.tier_gated_count,
        },
    );
}
```

- [ ] **Step 4: Run test — bucketSummary test must pass**

```
zig build test -Dchannels=cli 2>&1 | grep "bucketSummary includes gated"
```

Expected: PASS.

- [ ] **Step 5: Insert the gate check in `loadContextWithRuntimeDetailed`**

In `src/agent/memory_loader.zig`, find `loadContextWithRuntimeDetailed` (line ~661). At the very top of the function body, after `var stats = SelectionStats{ .available = true };`, add:

```zig
    // P4: tier gate — read once per call; 0.0 means disabled.
    const tier_gate_min_score = readTierGateMinScore();
```

Then find the fallback-bucket `else` branch (line ~816):

```zig
        } else {
            const estimated_bytes = @min(cand.snippet.len, FALLBACK_ENTRY_MAX_BYTES) + cand.key.len + 8;
            if (!canAppendToBucket(buf.items.len, fallback_bytes, stats.fallback_bucket_entries, SEARCH_FALLBACK_BUCKET_MAX_BYTES, SEARCH_FALLBACK_BUCKET_MAX_ENTRIES, estimated_bytes)) continue;
            try appendBucketEntry(allocator, &buf, &wrote_header, cand.key, cand.snippet, FALLBACK_ENTRY_MAX_BYTES, &fallback_bytes);
            stats.fallback_bucket_entries += 1;
            stats.fallback_bucket_bytes = fallback_bytes;
            stats.global_fallback_count += 1;
        }
```

Replace with:

```zig
        } else {
            const estimated_bytes = @min(cand.snippet.len, FALLBACK_ENTRY_MAX_BYTES) + cand.key.len + 8;
            if (!canAppendToBucket(buf.items.len, fallback_bytes, stats.fallback_bucket_entries, SEARCH_FALLBACK_BUCKET_MAX_BYTES, SEARCH_FALLBACK_BUCKET_MAX_ENTRIES, estimated_bytes)) continue;
            // P4: tier gate — skip low-confidence RRF hits from the fallback bucket.
            // Semantic bucket (isSemanticContinuityKey path above) is never gated.
            if (tier_gate_min_score > 0.0 and cand.final_score < tier_gate_min_score) {
                stats.tier_gated_count += 1;
                continue;
            }
            try appendBucketEntry(allocator, &buf, &wrote_header, cand.key, cand.snippet, FALLBACK_ENTRY_MAX_BYTES, &fallback_bytes);
            stats.fallback_bucket_entries += 1;
            stats.fallback_bucket_bytes = fallback_bytes;
            stats.global_fallback_count += 1;
        }
```

- [ ] **Step 6: Build — must be clean**

```
zig build -Dchannels=cli 2>&1
```

Expected: no output (zero errors, zero warnings).

- [ ] **Step 7: Run full tests — pre-existing 2 failures only**

```
zig build test -Dchannels=cli 2>&1 | tail -8
```

Expected output pattern:
```
Build Summary: 12/14 steps succeeded; 1 failed; 637x/644x tests passed; 73 skipped; 2 failed
```
The only 2 failures must be the pre-existing `handleApiRoute GET onboarding ...` telegram webhook tests in `gateway.zig`. Zero new failures.

- [ ] **Step 8: Commit**

```bash
git add src/agent/memory_loader.zig src/agent/context_engine.zig
git commit -m "feat(memory): P4 tier gate — gate fallback bucket by RRF score; surface in bucketSummary"
```

---

### Task 16: Verification — trace API check + LoCoMo bench queue

**Files:**
- No code changes — pure verification.

- [ ] **Step 1: Verify the trace event status string format**

Run the existing tests and grep for the `bucketSummary` output format:

```
zig build test -Dchannels=cli 2>&1 | grep -E "bucketSummary|FAIL|tier"
```

Expected: `bucketSummary includes gated` → PASS. Confirms the trace event `status` field now carries `gated:N` for every memory_retrieval event.

- [ ] **Step 2: Verify tier gate is off by default (no env var)**

Confirm `readTierGateMinScore` test passes and the returned value is 0.0:

```
zig build test -Dchannels=cli 2>&1 | grep "tier gate"
```

Expected: both `tier gate` tests PASS.

- [ ] **Step 3: Push branch and update PR**

```bash
git push origin feat/memory-intelligence-sprint
gh pr comment 104 --body "P4 tier gate + P16 verification complete. readTierGateMinScore (NULLALIS_TIER_GATE_MIN_SCORE, default 0.0=off) gates fallback-bucket RRF candidates below threshold. Semantic bucket untouched. bucketSummary gains gated:N field. All sprint changes committed."
```

- [ ] **Step 4: Queue LoCoMo smoke bench**

Run a 5-question smoke to verify no quality regression with gate disabled (default):

```bash
cd /Users/nova/Desktop/nullalis
python .spike/external/locomo_runner/run_bench.py --sample 0 --max-sessions 3 --max-qa 5
```

Expected: passes at ≥ current baseline (no regression — gate is off by default so no behaviour change).

- [ ] **Step 5: (Optional) Queue gate-enabled bench for quality comparison**

```bash
NULLALIS_TIER_GATE_MIN_SCORE=0.10 python .spike/external/locomo_runner/run_bench.py --sample 0 --max-sessions 3 --max-qa 5
```

Compare accuracy delta. If score improves or holds, the gate setting is production-viable.

---

## Self-Review

### 1. Spec coverage
- ✅ Stats fields — `tier_gated_count` added to `SelectionStats`
- ✅ applyTierGate logic — predicate `cand.final_score < tier_gate_min_score` in fallback path
- ✅ Semantic bucket NOT trimmed — gate only in `else` branch; `isSemanticContinuityKey` path is untouched
- ✅ Env var — `NULLALIS_TIER_GATE_MIN_SCORE` via `readTierGateMinScore()`
- ✅ Trace event surfaced — `bucketSummary` gains `gated:N` field
- ✅ Verification — build + test + bench queue

### 2. Placeholder scan
No TBDs, no "handle edge cases" phrases, no "similar to" references. Every code block is complete.

### 3. Type consistency
- `tier_gated_count: usize` used consistently across both files
- `readTierGateMinScore() f64` — return type consistent with `tier_gate_min_score` local variable declaration (`const tier_gate_min_score = readTierGateMinScore()`)
- `bucketSummary` argument type unchanged (`memory_loader.SelectionStats`) — the new field is accessed as `stats.tier_gated_count`
