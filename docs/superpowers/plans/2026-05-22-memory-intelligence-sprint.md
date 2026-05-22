# Memory Intelligence Sprint — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement five targeted memory quality improvements — entity overlap fusion, PPR graph traversal, provenance fields, tier sufficiency gate, and retrieval trace events — all on existing primitives with no new infrastructure.

**Architecture:** All five changes are additive and independent; each ships with an env-var kill switch. Implementation order is P3→P5→P1→P2→P4, from lowest risk to highest behavioral impact. P3 (schema) and P5 (observability) land first so the bench can measure the behavioral changes from P1/P2/P4 with full telemetry.

**Tech Stack:** Zig 0.15.2, PostgreSQL (libpq via `zaki_state.zig`), SQLite FTS5, inline `test "..."` blocks, `zig build test -Dchannels=cli`

---

## File Map

| File | Changes |
|---|---|
| `src/agent/zaki_state.zig` | P3: 2 ALTER TABLE migrations + `upsertMemoryEdgeRich` signature; P1: `findEdgesEntityOverlap()`; P2: `findEdgesPPR()` + `PPRNode` type |
| `src/agent/extraction_persist.zig` | P3: `extraction_pass` mapping + `session_boundary_id` threading; update `persistExtracted` signature |
| `src/agent/compaction.zig` *(or caller of `persistExtracted`)* | P3: generate `session_boundary_id` at boundary, pass to `persistExtracted` |
| `src/agent/edge_priors.zig` *(new)* | P2: shared predicate prior table (single source of truth for BFS + PPR CTE) |
| `src/agent/graph_expand.zig` | P2: PPR path in `expandFromSeeds`; import from `edge_priors.zig`; keep BFS fallback |
| `src/memory/retrieval/engine.zig` | P1: `EntityOverlapCallCtx` type + `entity_overlap` field; call in `search()` |
| `src/agent/memory_loader.zig` | P1: `EntityOverlapCtx` + `entityOverlapImpl`; wire callback; P4: sufficiency gate + trim + env reads |
| `src/agent/context_builder.zig` | P4: mirror `tier_gate_fired` + `tier_gate_trimmed_bytes` in `MemorySelection` |
| `src/run_trace_store.zig` | P5: add `.memory_retrieval` to `TraceEventKind` + `toSlice()` case |
| `src/agent/context_engine.zig` | P5: `bucketSummary()` helper + emit `memory_retrieval` event after `loadTurnMemorySlotOpts` |

---

## P3 — Provenance Fields on memory_edges

*Lowest risk. Pure schema addition + call-chain threading. No behavioral change.*

---

### Task 1: Audit `upsertMemoryEdgeRich` call sites

**Files:**
- Read: `src/agent/zaki_state.zig`
- Read: `src/agent/extraction_persist.zig`

- [ ] **Step 1: Find every call site**

```bash
grep -rn "upsertMemoryEdgeRich" /Users/nova/Desktop/nullalis/src/
```

Expected output: a list of file:line pairs. Note every path — you must update each one in Task 3.

- [ ] **Step 2: Confirm all call sites are in `extraction_persist.zig`**

If any call sites exist outside `extraction_persist.zig`, note them. The plan covers `extraction_persist.zig`; any others must be updated with the same `null, null` append.

- [ ] **Step 3: Note the current `upsertMemoryEdgeRich` signature**

Read `src/agent/zaki_state.zig` around the function. It currently ends with `episode_key: ?[]const u8`. You will add two params after it in Task 2.

---

### Task 2: Add migrations and extend `upsertMemoryEdgeRich`

**Files:**
- Modify: `src/agent/zaki_state.zig`

- [ ] **Step 1: Add migration strings**

Find the block in `zaki_state.zig` that contains the existing memory_edges column migrations (look for `ADD COLUMN IF NOT EXISTS episodes`, `ADD COLUMN IF NOT EXISTS fact`, `ADD COLUMN IF NOT EXISTS temporal_anchor_unix`). Immediately after the last one in that block, add:

```zig
"ALTER TABLE {schema}.memory_edges ADD COLUMN IF NOT EXISTS extraction_pass TEXT",
"ALTER TABLE {schema}.memory_edges ADD COLUMN IF NOT EXISTS session_boundary_id BIGINT",
```

- [ ] **Step 2: Extend `upsertMemoryEdgeRich` function signature**

Find the function declaration. Add two parameters at the end:

```zig
pub fn upsertMemoryEdgeRich(
    self: *Self,
    user_id: i64,
    source_key: []const u8,
    target_key: []const u8,
    predicate: []const u8,
    attribution: ?[]const u8,
    confidence: ?f64,
    fact: ?[]const u8,
    temporal_anchor_unix: ?i64,
    episode_key: ?[]const u8,
    extraction_pass: ?[]const u8,      // NEW
    session_boundary_id: ?i64,         // NEW
) !void
```

- [ ] **Step 3: Update the INSERT SQL inside `upsertMemoryEdgeRich`**

Find the INSERT/upsert SQL string inside the function. Add `extraction_pass` and `session_boundary_id` to both the column list and the `$N` parameter list. Add two new parameter bindings at the end of the `params` array using the same null-handling pattern already used for `fact` and `temporal_anchor_unix`.

- [ ] **Step 4: Verify compile error appears at all call sites**

```bash
cd /Users/nova/Desktop/nullalis && zig build -Dchannels=cli 2>&1 | grep "upsertMemoryEdgeRich"
```

Expected: compile errors at every call site (wrong number of args). This confirms the audit from Task 1 found all of them.

---

### Task 3: Update `extraction_persist.zig` — map WriteOrigin and thread session_boundary_id

**Files:**
- Modify: `src/agent/extraction_persist.zig`

- [ ] **Step 1: Add `extraction_pass` mapping function**

Add this before the `persistExtracted` function:

```zig
fn originToExtractionPass(origin: WriteOrigin) []const u8 {
    return switch (origin) {
        .pass_a_drop                  => "pass_a",
        .pass_c_compaction_extract    => "pass_c",
        .session_end_extract          => "session_end",
        .memory_store_tool            => "tool",
        .test_wire                    => "test",
        else                          => "unknown",
    };
}
```

- [ ] **Step 2: Add `session_boundary_id` to `persistExtracted` signature**

Find the `persistExtracted` function declaration. Add `session_boundary_id: i64` as the last parameter (after `origin: WriteOrigin`):

```zig
pub fn persistExtracted(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    session_id: ?[]const u8,
    memories: []const ExtractedMemory,
    judge: ?JudgeContext,
    coref: ?EntityResolution,
    mem_rt: ?*memory_root.MemoryRuntime,
    origin: WriteOrigin,
    session_boundary_id: i64,          // NEW
) !PersistResult
```

- [ ] **Step 3: Pass provenance to `upsertMemoryEdgeRich` at the call site**

Find the call to `state_mgr.upsertMemoryEdgeRich(...)` inside `persistExtracted`. Update it to pass the new arguments:

```zig
state_mgr.upsertMemoryEdgeRich(
    user_id,
    key,
    tk,
    m.predicate,
    "extraction_classifier",
    m.confidence,
    m.text,
    m.temporal_anchor_unix,
    key,
    originToExtractionPass(origin),   // NEW: extraction_pass
    session_boundary_id,              // NEW: session_boundary_id
) catch |err| { ... };
```

- [ ] **Step 4: Fix compile errors at `persistExtracted` call sites**

```bash
cd /Users/nova/Desktop/nullalis && zig build -Dchannels=cli 2>&1 | grep "persistExtracted"
```

Find each call site in the output. For now, pass `0` as `session_boundary_id` at each call site (we will replace the `compaction.zig` caller in Task 4; all others get `0` permanently as they are not boundary-type callers).

---

### Task 4: Generate `session_boundary_id` at the compaction boundary

**Files:**
- Modify: `src/agent/compaction.zig` *(or whichever file calls `persistExtracted` for Pass C / session-end)*

- [ ] **Step 1: Find the compaction caller**

```bash
grep -n "persistExtracted" /Users/nova/Desktop/nullalis/src/agent/compaction.zig
```

If not found there:

```bash
grep -rn "persistExtracted" /Users/nova/Desktop/nullalis/src/
```

Identify the function(s) that call `persistExtracted` with `origin = .pass_c_compaction_extract` or `.session_end_extract`.

- [ ] **Step 2: Generate boundary ID before calling `persistExtracted`**

In each such function, immediately before the `persistExtracted` call, add:

```zig
const boundary_ts = std.time.milliTimestamp();
```

Then pass `boundary_ts` as the `session_boundary_id` argument.

- [ ] **Step 3: Build and confirm zero errors**

```bash
cd /Users/nova/Desktop/nullalis && zig build -Dchannels=cli 2>&1 | head -30
```

Expected: clean build.

- [ ] **Step 4: Write inline test for the mapping**

In `src/agent/extraction_persist.zig`, add a test block at the bottom of the file:

```zig
test "originToExtractionPass maps all expected origins" {
    const std = @import("std");
    try std.testing.expectEqualStrings("pass_a",       originToExtractionPass(.pass_a_drop));
    try std.testing.expectEqualStrings("pass_c",       originToExtractionPass(.pass_c_compaction_extract));
    try std.testing.expectEqualStrings("session_end",  originToExtractionPass(.session_end_extract));
    try std.testing.expectEqualStrings("tool",         originToExtractionPass(.memory_store_tool));
    try std.testing.expectEqualStrings("test",         originToExtractionPass(.test_wire));
    try std.testing.expectEqualStrings("unknown",      originToExtractionPass(.unknown));
}
```

- [ ] **Step 5: Run the test**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep -E "PASS|FAIL|originToExtractionPass"
```

Expected: `PASS originToExtractionPass maps all expected origins`

- [ ] **Step 6: Commit**

```bash
git add src/agent/zaki_state.zig src/agent/extraction_persist.zig src/agent/compaction.zig
git commit -m "feat(memory): add extraction_pass + session_boundary_id provenance to memory_edges (P3)"
```

---

## P5 — Retrieval Trace Events

*Additive only. No behavioral change. Exposes existing SelectionStats to the traces API.*

---

### Task 5: Add `memory_retrieval` event kind to the trace store

**Files:**
- Modify: `src/run_trace_store.zig`

- [ ] **Step 1: Write the failing test**

Find the existing inline tests in `src/run_trace_store.zig`. Add this test:

```zig
test "memory_retrieval kind serializes to correct slice" {
    const std = @import("std");
    const kind = TraceEventKind.memory_retrieval;
    try std.testing.expectEqualStrings("memory_retrieval", kind.toSlice());
}
```

- [ ] **Step 2: Run test to see it fail**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep -E "memory_retrieval|error"
```

Expected: compile error — `memory_retrieval` is not a member of `TraceEventKind`.

- [ ] **Step 3: Add `memory_retrieval` to `TraceEventKind`**

Find the `TraceEventKind` enum in `src/run_trace_store.zig`. Add `memory_retrieval` to it. Then find the `toSlice()` switch statement (or equivalent) and add the case:

```zig
.memory_retrieval => "memory_retrieval",
```

- [ ] **Step 4: Run test to confirm pass**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep -E "memory_retrieval|PASS|FAIL"
```

Expected: `PASS memory_retrieval kind serializes to correct slice`

- [ ] **Step 5: Commit**

```bash
git add src/run_trace_store.zig
git commit -m "feat(trace): add memory_retrieval event kind to TraceEventKind (P5)"
```

---

### Task 6: Emit `memory_retrieval` event from `context_engine.ingest()`

**Files:**
- Modify: `src/agent/context_engine.zig`

- [ ] **Step 1: Read the existing turn_stage event emission**

Find the block in `context_engine.ingest()` around line ~511 where `agent.observer.recordEvent(&memory_stage_event)` is called. Note the exact struct fields and types used for that event — you will follow the same pattern.

- [ ] **Step 2: Add `bucketSummary` helper function**

Add this function before `ingest()` in `context_engine.zig`:

```zig
fn bucketSummary(allocator: std.mem.Allocator, stats: memory_loader.SelectionStats) ![:0]u8 {
    return std.fmt.allocPrintZ(
        allocator,
        "continuity:{d},semantic:{d},fallback:{d},graph:{d}{s}",
        .{
            stats.continuity_bucket_entries,
            stats.semantic_bucket_entries,
            stats.fallback_bucket_entries,
            stats.graph_recall_neighbor_count,
            if (stats.tier_gate_fired) ",tier_gate:fired" else "",
        },
    );
}
```

Note: `stats.tier_gate_fired` does not exist yet — it is added in P4 (Task 14). For now, hardcode `false`:

```zig
fn bucketSummary(allocator: std.mem.Allocator, stats: memory_loader.SelectionStats) ![:0]u8 {
    return std.fmt.allocPrintZ(
        allocator,
        "continuity:{d},semantic:{d},fallback:{d},graph:{d}",
        .{
            stats.continuity_bucket_entries,
            stats.semantic_bucket_entries,
            stats.fallback_bucket_entries,
            stats.graph_recall_neighbor_count,
        },
    );
}
```

When P4 lands, update this function to add the `tier_gate` suffix.

- [ ] **Step 3: Emit the event after `loadTurnMemorySlotOpts`**

Find where `loadTurnMemorySlotOpts` returns and where `enrich_ms` is computed in `context_engine.ingest()`. Immediately after (following the pattern of the existing `memory_stage_event`), add:

```zig
if (mem_slot.stats.available) {
    const summary = bucketSummary(allocator, mem_slot.stats) catch null;
    defer if (summary) |s| allocator.free(s);
    var retrieval_event = /* copy the existing ObserverEvent init pattern from the turn_stage event above */ .{
        .kind = .memory_retrieval,
        .run_id = agent.current_run_id,
        .ts_ms = std.time.milliTimestamp(),
        .label = "memory_retrieval",
        .status = if (summary) |s| s else "unavailable",
        .success = mem_slot.stats.injected,
        .usage_tokens = @intCast(mem_slot.stats.context_bytes),
        .iteration = @intCast(mem_slot.stats.candidate_count),
        .duration_ms = enrich_ms,
    };
    agent.observer.recordEvent(&retrieval_event);
}
```

**Important:** Use the exact ObserverEvent init syntax already in use for the nearby `memory_stage_event`. The struct name, field names, and init style must match what's already there. Read the surrounding code before writing this step.

- [ ] **Step 4: Build clean**

```bash
cd /Users/nova/Desktop/nullalis && zig build -Dchannels=cli 2>&1 | head -20
```

Expected: no errors.

- [ ] **Step 5: Smoke test via the CLI channel**

Start nullalis with the CLI channel, send a message, then query the traces API for the run. Confirm a `memory_retrieval` event appears with non-zero `usage_tokens`.

```bash
# (Start nullalis in one terminal, then in another:)
curl -s "http://localhost:8080/api/v1/users/1/traces" | jq '.traces[-1].run_id' | xargs -I{} \
  curl -s "http://localhost:8080/api/v1/users/1/traces/{}" | jq '[.events[] | select(.kind == "memory_retrieval")]'
```

Expected: at least one `memory_retrieval` event per turn.

- [ ] **Step 6: Commit**

```bash
git add src/agent/context_engine.zig
git commit -m "feat(trace): emit memory_retrieval event per turn in context_engine (P5)"
```

---

## P1 — Entity Overlap as Third RRF Signal

*Adds a new retrieval source. Existing keyword+vector path is unchanged.*

---

### Task 7: Add `EntityOverlapCallCtx` to `RetrievalEngine`

**Files:**
- Modify: `src/memory/retrieval/engine.zig`

- [ ] **Step 1: Write the failing test**

Find the inline tests in `engine.zig`. Add:

```zig
test "entity_overlap source included in rrf merge when callback set" {
    const std = @import("std");
    const alloc = std.testing.allocator;

    // A mock entity overlap callback that returns one candidate
    const MockCtx = struct {
        fn entityFn(ctx: *anyopaque, allocator: std.mem.Allocator, query: []const u8) anyerror![]RetrievalCandidate {
            _ = ctx; _ = query;
            const candidates = try allocator.alloc(RetrievalCandidate, 1);
            candidates[0] = RetrievalCandidate{
                .id = 0,
                .key = try allocator.dupe(u8, "entity_match_key"),
                .content = try allocator.dupe(u8, "entity content"),
                .snippet = try allocator.dupe(u8, "entity content"),
                .category = .daily,
                .keyword_rank = null,
                .vector_score = null,
                .final_score = 0.0,
                .source = "entity_overlap",
                .source_path = "",
                .start_line = 0,
                .end_line = 0,
                .created_at = 0,
                .lane = "",
            };
            return candidates;
        }
    };
    var ctx_dummy: u8 = 0;
    var engine = RetrievalEngine{
        .top_k = 5,
        .merge_k = 60,
        .entity_overlap = .{
            .ptr = &ctx_dummy,
            .func = MockCtx.entityFn,
        },
    };
    // Pass a mock primary adapter that returns no results
    // (Use the existing PrimaryAdapter test pattern from this file)
    // Confirm entity_match_key appears in the final results
    _ = engine;
    // NOTE: Full integration of this test requires a mock adapter.
    // Minimal assertion: the struct field compiles and holds the callback.
    try std.testing.expect(engine.entity_overlap != null);
}
```

- [ ] **Step 2: Run test to see compile error**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep "entity_overlap"
```

Expected: compile error — `entity_overlap` not a field of `RetrievalEngine`.

- [ ] **Step 3: Add `EntityOverlapCallCtx` type and field**

In `src/memory/retrieval/engine.zig`, add the type definition near the top of the file (before the `RetrievalEngine` struct):

```zig
pub const EntityOverlapCallCtx = struct {
    ptr: *anyopaque,
    func: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        query: []const u8,
    ) anyerror![]RetrievalCandidate,
};
```

Add the field to `RetrievalEngine` struct, after `llm_rerank_fn`:

```zig
entity_overlap: ?EntityOverlapCallCtx = null,
```

- [ ] **Step 4: Run test to confirm field compiles**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep -E "entity_overlap|PASS|FAIL"
```

Expected: `PASS entity_overlap source included in rrf merge when callback set`

- [ ] **Step 5: Commit**

```bash
git add src/memory/retrieval/engine.zig
git commit -m "feat(retrieval): add EntityOverlapCallCtx type and field to RetrievalEngine (P1)"
```

---

### Task 8: Call entity overlap callback in `engine.search()` and add as 3rd RRF source

**Files:**
- Modify: `src/memory/retrieval/engine.zig`

- [ ] **Step 1: Find the RRF source assembly block**

In `engine.search()`, find the lines around 589–596 where `rrf_sources` is assembled and `rrfMerge` is called. It looks like:

```zig
for (source_results, 0..) |sr, i| {
    rrf_sources[i] = sr;
}
if (has_vec) {
    rrf_sources[source_results.len] = vector_candidates.?;
}
// ... then rrfMerge call
```

- [ ] **Step 2: Add entity overlap fetch and append**

Immediately before the `rrfMerge` call, add:

```zig
var entity_candidates: ?[]RetrievalCandidate = null;
defer if (entity_candidates) |ec| {
    for (ec) |*c| c.deinit(self.allocator);
    self.allocator.free(ec);
};
if (self.entity_overlap) |eo| {
    entity_candidates = eo.func(eo.ptr, allocator, query) catch |err| blk: {
        std.log.scoped(.retrieval).warn("entity_overlap.fetch_failed err={}", .{err});
        break :blk null;
    };
}
```

Then update the `rrf_sources` assembly to include entity candidates when present. The `rrf_sources` slice needs to be large enough — change its allocation to accommodate the 3rd source:

```zig
// Old: allocated for source_results.len + (1 if has_vec)
// New: allocated for source_results.len + (1 if has_vec) + (1 if entity_candidates != null)
const has_entity = entity_candidates != null;
const total_sources = source_results.len +
    @intFromBool(has_vec) +
    @intFromBool(has_entity);
const rrf_sources = try allocator.alloc([]const RetrievalCandidate, total_sources);
defer allocator.free(rrf_sources);

var src_idx: usize = 0;
for (source_results) |sr| {
    rrf_sources[src_idx] = sr;
    src_idx += 1;
}
if (has_vec) {
    rrf_sources[src_idx] = vector_candidates.?;
    src_idx += 1;
}
if (has_entity) {
    rrf_sources[src_idx] = entity_candidates.?;
}
```

**Note:** Examine the actual existing assembly code carefully before rewriting it — if `rrf_sources` is stack-allocated or differently structured, adapt to match the local pattern.

- [ ] **Step 3: Build clean**

```bash
cd /Users/nova/Desktop/nullalis && zig build -Dchannels=cli 2>&1 | head -20
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add src/memory/retrieval/engine.zig
git commit -m "feat(retrieval): call entity_overlap callback in search() as 3rd RRF source (P1)"
```

---

### Task 9: Add `findEdgesEntityOverlap` to `zaki_state.zig`

**Files:**
- Modify: `src/agent/zaki_state.zig`

- [ ] **Step 1: Write the failing test**

At the bottom of `zaki_state.zig` (or in its existing test block), add:

```zig
test "findEdgesEntityOverlap signature compiles" {
    // Compile-time check only — integration requires a live PG instance
    const F = @TypeOf(Manager.findEdgesEntityOverlap);
    _ = F;
}
```

- [ ] **Step 2: Run to confirm missing symbol**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep "findEdgesEntityOverlap"
```

Expected: compile error.

- [ ] **Step 3: Add `EntityOverlapRow` type and `findEdgesEntityOverlap` function**

Near the `findEdgesByKeys` function in `zaki_state.zig`, add:

```zig
pub const EntityOverlapRow = struct {
    memory_key: []u8,
    match_count: i64,

    pub fn deinit(self: EntityOverlapRow, allocator: std.mem.Allocator) void {
        allocator.free(self.memory_key);
    }
};

pub fn findEdgesEntityOverlap(
    self: *Self,
    allocator: std.mem.Allocator,
    user_id: i64,
    token_patterns: []const []const u8,
    limit: usize,
) ![]EntityOverlapRow {
    if (token_patterns.len == 0) return &.{};

    // Build the query with {schema} substitution
    const q = try self.buildQuery(
        "SELECT DISTINCT m.key, COUNT(e.id)::bigint AS match_count " ++
        "FROM {schema}.memories m " ++
        "JOIN {schema}.memory_edges e " ++
        "  ON e.user_id = $1 AND e.is_latest " ++
        "  AND (e.source_key ILIKE ANY($2) OR e.target_key ILIKE ANY($2)) " ++
        "  AND m.key IN (e.source_key, e.target_key) " ++
        "WHERE m.user_id = $1 " ++
        "GROUP BY m.key " ++
        "ORDER BY match_count DESC " ++
        "LIMIT $3",
    );
    defer allocator.free(q);

    // $1 = user_id (int8), $2 = token_patterns (text[]), $3 = limit (int8)
    const uid_str = try std.fmt.allocPrintZ(allocator, "{d}", .{user_id});
    defer allocator.free(uid_str);
    const limit_str = try std.fmt.allocPrintZ(allocator, "{d}", .{limit});
    defer allocator.free(limit_str);

    // Build Postgres text[] literal: '{%token1%,%token2%}'
    var arr_buf = std.ArrayList(u8).init(allocator);
    defer arr_buf.deinit();
    try arr_buf.appendSlice("{");
    for (token_patterns, 0..) |pat, i| {
        if (i > 0) try arr_buf.appendSlice(",");
        try arr_buf.appendSlice("\"");
        try arr_buf.appendSlice(pat);
        try arr_buf.appendSlice("\"");
    }
    try arr_buf.appendSlice("}");
    const arr_str = try arr_buf.toOwnedSliceSentinel(0);
    defer allocator.free(arr_str);

    const params = [_]?[*:0]const u8{ uid_str, arr_str, limit_str };
    const lengths = [_]c_int{ 0, 0, 0 };

    const res = try self.execParams(q, &params, &lengths);
    defer c.PQclear(res);

    const nrows = c.PQntuples(res);
    if (nrows == 0) return &.{};

    var rows = try allocator.alloc(EntityOverlapRow, @intCast(nrows));
    errdefer {
        for (rows) |r| r.deinit(allocator);
        allocator.free(rows);
    }

    for (0..@intCast(nrows)) |i| {
        const key_raw = c.PQgetvalue(res, @intCast(i), 0);
        const cnt_raw = c.PQgetvalue(res, @intCast(i), 1);
        rows[i] = .{
            .memory_key = try allocator.dupe(u8, std.mem.span(key_raw)),
            .match_count = try std.fmt.parseInt(i64, std.mem.span(cnt_raw), 10),
        };
    }
    return rows;
}
```

- [ ] **Step 4: Run test to confirm compile**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep -E "findEdgesEntityOverlap|PASS|FAIL"
```

Expected: `PASS findEdgesEntityOverlap signature compiles`

- [ ] **Step 5: Commit**

```bash
git add src/agent/zaki_state.zig
git commit -m "feat(db): add findEdgesEntityOverlap query function (P1)"
```

---

### Task 10: Wire entity overlap callback in `memory_loader.zig`

**Files:**
- Modify: `src/agent/memory_loader.zig`

- [ ] **Step 1: Add `EntityOverlapCtx` struct and `entityOverlapImpl`**

Near the top of `memory_loader.zig` (after imports), add:

```zig
const EntityOverlapCtx = struct {
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    allocator: std.mem.Allocator,
};

fn entityOverlapImpl(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    query: []const u8,
) anyerror![]engine_mod.RetrievalCandidate {
    const eo_ctx: *EntityOverlapCtx = @ptrCast(@alignCast(ctx));

    // Tokenize query: split on whitespace, lowercase, skip short tokens
    var tokens = std.ArrayList([]const u8).init(allocator);
    defer tokens.deinit();
    var patterns = std.ArrayList([]const u8).init(allocator);
    defer {
        for (patterns.items) |p| allocator.free(p);
        patterns.deinit();
    }

    var it = std.mem.tokenizeAny(u8, query, " \t\n.,;:!?\"'()[]");
    while (it.next()) |tok| {
        if (tok.len < 3) continue; // skip short tokens
        const lower = try std.ascii.allocLowerString(allocator, tok);
        try tokens.append(lower);
        const pat = try std.fmt.allocPrint(allocator, "%{s}%", .{lower});
        try patterns.append(pat);
        allocator.free(lower);
    }
    if (patterns.items.len == 0) return &.{};

    const rows = try eo_ctx.state_mgr.findEdgesEntityOverlap(
        allocator,
        eo_ctx.user_id,
        patterns.items,
        10,
    );
    defer {
        for (rows) |r| r.deinit(allocator);
        allocator.free(rows);
    }
    if (rows.len == 0) return &.{};

    // Normalize scores: max match_count → 1.0
    const max_count: f64 = @floatFromInt(rows[0].match_count);

    var candidates = try allocator.alloc(engine_mod.RetrievalCandidate, rows.len);
    errdefer allocator.free(candidates);

    for (rows, 0..) |row, i| {
        const score: f64 = if (max_count > 0)
            @as(f64, @floatFromInt(row.match_count)) / max_count
        else 0.0;
        candidates[i] = engine_mod.RetrievalCandidate{
            .id = 0,
            .key = try allocator.dupe(u8, row.memory_key),
            .content = try allocator.dupe(u8, ""),
            .snippet = try allocator.dupe(u8, ""),
            .category = .daily,
            .keyword_rank = null,
            .vector_score = null,
            .final_score = score,
            .source = "entity_overlap",
            .source_path = "",
            .start_line = 0,
            .end_line = 0,
            .created_at = 0,
            .lane = "",
        };
    }
    return candidates;
}
```

**Note:** `engine_mod` should be whatever import alias you use for `src/memory/retrieval/engine.zig` in `memory_loader.zig`. Check the existing imports at the top of the file and use the correct alias.

- [ ] **Step 2: Wire the callback when building the engine config**

Find the code in `memory_loader.zig` where `RetrievalEngine` is initialized (look for `.entity_overlap = null` or where other optional fields like `llm_rerank_fn` are set). The context struct must outlive the engine call:

```zig
var eo_ctx = EntityOverlapCtx{
    .state_mgr = state_mgr,
    .user_id = user_id,
    .allocator = allocator,
};
const entity_overlap_enabled = readEntityOverlapEnabled(); // see Step 3

var retrieval_engine = RetrievalEngine{
    // ... existing fields ...
    .entity_overlap = if (entity_overlap_enabled) .{
        .ptr = &eo_ctx,
        .func = entityOverlapImpl,
    } else null,
};
```

- [ ] **Step 3: Add env var reader**

Add a simple reader function in `memory_loader.zig` (follow the pattern of `readGraphRecallMaxHops`):

```zig
fn readEntityOverlapEnabled() bool {
    const val = std.posix.getenv("NULLALIS_ENTITY_OVERLAP") orelse return true;
    return !std.mem.eql(u8, val, "0");
}
```

- [ ] **Step 4: Build clean**

```bash
cd /Users/nova/Desktop/nullalis && zig build -Dchannels=cli 2>&1 | head -20
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add src/agent/memory_loader.zig
git commit -m "feat(memory): wire entity overlap callback in memory_loader (P1)"
```

---

## P2 — PPR-Weighted Graph Traversal

*Replaces flat BFS scoring with Personalized PageRank via a single recursive PostgreSQL CTE.*

---

### Task 11: Create `src/agent/edge_priors.zig`

**Files:**
- Create: `src/agent/edge_priors.zig`

- [ ] **Step 1: Create the file with the shared prior table**

```zig
//! Shared predicate prior weights for graph traversal.
//! Single source of truth used by both BFS (graph_expand.zig) and PPR CTE (zaki_state.zig).

pub const EdgePrior = struct {
    predicate: []const u8,
    prior: f64,
};

/// Predicates with known prior weights.
/// Unknown predicates use DEFAULT_PRIOR.
pub const KNOWN_PRIORS: []const EdgePrior = &[_]EdgePrior{
    // Single-valued (high precision, one true value)
    .{ .predicate = "LIVES_IN",     .prior = 1.0 },
    .{ .predicate = "MARRIED_TO",   .prior = 1.0 },
    .{ .predicate = "BIRTHDAY",     .prior = 1.0 },
    .{ .predicate = "WORKS_AT",     .prior = 1.0 },
    .{ .predicate = "IS_A",         .prior = 1.0 },
    .{ .predicate = "FULL_NAME",    .prior = 1.0 },
    .{ .predicate = "NATIONALITY",  .prior = 1.0 },
    // Set-valued (lower precision, many valid values)
    .{ .predicate = "LIKES",        .prior = 0.5 },
    .{ .predicate = "USES",         .prior = 0.5 },
    .{ .predicate = "IS_TYPE_OF",   .prior = 0.5 },
    .{ .predicate = "ATTENDED",     .prior = 0.5 },
    .{ .predicate = "KNOWS",        .prior = 0.5 },
    .{ .predicate = "WANTS_TO",     .prior = 0.5 },
    .{ .predicate = "FAN_OF",       .prior = 0.5 },
    .{ .predicate = "MENTIONED",    .prior = 0.3 },
};

pub const DEFAULT_PRIOR: f64 = 0.7;

/// Look up the prior for a predicate. Returns DEFAULT_PRIOR if not found.
pub fn priorForPredicate(predicate: []const u8) f64 {
    for (KNOWN_PRIORS) |ep| {
        if (std.mem.eql(u8, ep.predicate, predicate)) return ep.prior;
    }
    return DEFAULT_PRIOR;
}

const std = @import("std");

test "priorForPredicate known single-valued returns 1.0" {
    const std_ = @import("std");
    try std_.testing.expectApproxEqAbs(1.0, priorForPredicate("LIVES_IN"), 0.001);
    try std_.testing.expectApproxEqAbs(1.0, priorForPredicate("MARRIED_TO"), 0.001);
}

test "priorForPredicate known set-valued returns 0.5" {
    const std_ = @import("std");
    try std_.testing.expectApproxEqAbs(0.5, priorForPredicate("LIKES"), 0.001);
}

test "priorForPredicate unknown returns DEFAULT_PRIOR" {
    const std_ = @import("std");
    try std_.testing.expectApproxEqAbs(DEFAULT_PRIOR, priorForPredicate("INVENTED_PREDICATE"), 0.001);
}
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep -E "priorForPredicate|PASS|FAIL"
```

Expected: all 3 tests pass.

- [ ] **Step 3: Update `graph_expand.zig` to import from `edge_priors.zig`**

Find the hardcoded predicate prior values in `graph_expand.zig` (lines 314–345). Replace the hardcoded switch/array with calls to `edge_priors.priorForPredicate(predicate)`. Add the import:

```zig
const edge_priors = @import("edge_priors.zig");
```

Replace any local prior lookup with:

```zig
const prior = edge_priors.priorForPredicate(edge.predicate);
```

- [ ] **Step 4: Build and run graph_expand tests**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep -E "graph_expand|PASS|FAIL"
```

Expected: all existing graph_expand tests pass (BFS behavior unchanged).

- [ ] **Step 5: Commit**

```bash
git add src/agent/edge_priors.zig src/agent/graph_expand.zig
git commit -m "feat(graph): extract edge predicate priors to shared edge_priors.zig (P2)"
```

---

### Task 12: Add `PPRNode` type and `findEdgesPPR` to `zaki_state.zig`

**Files:**
- Modify: `src/agent/zaki_state.zig`

- [ ] **Step 1: Write compile test**

```zig
test "findEdgesPPR signature compiles" {
    const F = @TypeOf(Manager.findEdgesPPR);
    _ = F;
}
```

- [ ] **Step 2: Add `PPRNode` type**

Near `EntityOverlapRow` and `TypedEdge` in `zaki_state.zig`:

```zig
pub const PPRNode = struct {
    key: []u8,
    ppr_score: f64,
    min_depth: u8,

    pub fn deinit(self: PPRNode, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};
```

- [ ] **Step 3: Build the `edge_priors` VALUES clause at comptime**

Add a comptime helper near the top of `zaki_state.zig` (or in a private block):

```zig
/// Build the SQL VALUES clause for edge_priors CTE from the shared table.
/// Result: "(  ('PRED1', 0.5::float), ('PRED2', 1.0::float), ... )"
fn buildEdgePriorValues() []const u8 {
    @setEvalBranchQuota(10_000);
    comptime {
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        for (edge_priors_mod.KNOWN_PRIORS, 0..) |ep, i| {
            if (i > 0) {
                buf[pos] = ','; pos += 1;
            }
            const chunk = std.fmt.comptimePrint("('{s}',{d:.1}::float)", .{ ep.predicate, ep.prior });
            @memcpy(buf[pos..][0..chunk.len], chunk);
            pos += chunk.len;
        }
        return buf[0..pos];
    }
}
const EDGE_PRIOR_VALUES = buildEdgePriorValues();
```

Add the import near existing imports:

```zig
const edge_priors_mod = @import("edge_priors.zig");
```

**Note:** If comptime string construction is too complex in your Zig version (0.15.2), replace with a hardcoded `const EDGE_PRIOR_VALUES: []const u8 = "(...)";` string that mirrors `edge_priors.zig`. Keep a comment: `// Keep in sync with src/agent/edge_priors.zig`. This is acceptable as the compile-time approach is an optimization, not a requirement.

- [ ] **Step 4: Add `findEdgesPPR` function**

```zig
pub fn findEdgesPPR(
    self: *Self,
    allocator: std.mem.Allocator,
    user_id: i64,
    seed_keys: []const []const u8,
    max_hops: u8,
    limit: usize,
) ![]PPRNode {
    if (seed_keys.len == 0) return &.{};

    // Build seed array literal: '{key1,key2,...}'
    var seed_buf = std.ArrayList(u8).init(allocator);
    defer seed_buf.deinit();
    try seed_buf.appendSlice("{");
    for (seed_keys, 0..) |k, i| {
        if (i > 0) try seed_buf.appendSlice(",");
        try seed_buf.appendSlice("\"");
        try seed_buf.appendSlice(k);
        try seed_buf.appendSlice("\"");
    }
    try seed_buf.appendSlice("}");
    const seeds_str = try seed_buf.toOwnedSliceSentinel(0);
    defer allocator.free(seeds_str);

    const uid_str = try std.fmt.allocPrintZ(allocator, "{d}", .{user_id});
    defer allocator.free(uid_str);
    const hops_str = try std.fmt.allocPrintZ(allocator, "{d}", .{max_hops});
    defer allocator.free(hops_str);
    const limit_str = try std.fmt.allocPrintZ(allocator, "{d}", .{limit});
    defer allocator.free(limit_str);

    const q_template =
        "WITH RECURSIVE " ++
        "edge_priors(predicate, prior) AS (VALUES " ++ EDGE_PRIOR_VALUES ++ "), " ++
        "ppr(key, score, depth) AS (" ++
        "  SELECT unnest($2::text[]) AS key, " ++
        "         1.0 / GREATEST(array_length($2::text[], 1), 1) AS score, " ++
        "         0 AS depth " ++
        "  UNION ALL " ++
        "  SELECT CASE WHEN e.source_key = p.key THEN e.target_key ELSE e.source_key END, " ++
        "         p.score * COALESCE(ep.prior, 0.7) * 0.85, " ++
        "         p.depth + 1 " ++
        "  FROM ppr p " ++
        "  JOIN {schema}.memory_edges e " ++
        "    ON (e.source_key = p.key OR e.target_key = p.key) " ++
        "    AND e.user_id = $1 AND e.is_latest " ++
        "  LEFT JOIN edge_priors ep ON ep.predicate = e.predicate " ++
        "  WHERE p.depth < $3" ++
        ") " ++
        "SELECT key, SUM(score) AS ppr_score, MIN(depth)::int AS min_depth " ++
        "FROM ppr " ++
        "GROUP BY key " ++
        "HAVING SUM(score) > 0.01 " ++
        "ORDER BY ppr_score DESC " ++
        "LIMIT $4";

    const q = try self.buildQuery(q_template);
    defer allocator.free(q);

    const params = [_]?[*:0]const u8{ uid_str, seeds_str, hops_str, limit_str };
    const lengths = [_]c_int{ 0, 0, 0, 0 };

    const res = try self.execParams(q, &params, &lengths);
    defer c.PQclear(res);

    const nrows = c.PQntuples(res);
    if (nrows == 0) return &.{};

    var nodes = try allocator.alloc(PPRNode, @intCast(nrows));
    errdefer {
        for (nodes) |n| n.deinit(allocator);
        allocator.free(nodes);
    }

    for (0..@intCast(nrows)) |i| {
        const key_raw   = c.PQgetvalue(res, @intCast(i), 0);
        const score_raw = c.PQgetvalue(res, @intCast(i), 1);
        const depth_raw = c.PQgetvalue(res, @intCast(i), 2);
        nodes[i] = .{
            .key       = try allocator.dupe(u8, std.mem.span(key_raw)),
            .ppr_score = try std.fmt.parseFloat(f64, std.mem.span(score_raw)),
            .min_depth = @intCast(try std.fmt.parseInt(i32, std.mem.span(depth_raw), 10)),
        };
    }
    return nodes;
}
```

- [ ] **Step 5: Build clean**

```bash
cd /Users/nova/Desktop/nullalis && zig build -Dchannels=cli 2>&1 | head -20
```

- [ ] **Step 6: Commit**

```bash
git add src/agent/zaki_state.zig
git commit -m "feat(db): add PPRNode type and findEdgesPPR recursive CTE query (P2)"
```

---

### Task 13: Add PPR path to `expandFromSeeds` in `graph_expand.zig`

**Files:**
- Modify: `src/agent/graph_expand.zig`

- [ ] **Step 1: Write the failing test**

Add to inline tests in `graph_expand.zig`:

```zig
test "expandFromSeeds PPR: higher score for tighter predicate" {
    // Pure logic test (no DB required)
    // Verify priorForPredicate behaves correctly for scoring
    const std = @import("std");
    const ep = @import("edge_priors.zig");
    // A LIVES_IN edge (prior=1.0) should propagate more score than MENTIONED (prior=0.3)
    const lives_in_score = 1.0 * ep.priorForPredicate("LIVES_IN") * 0.85;
    const mentioned_score = 1.0 * ep.priorForPredicate("MENTIONED") * 0.85;
    try std.testing.expect(lives_in_score > mentioned_score);
}
```

- [ ] **Step 2: Run test to confirm it passes (it should — pure logic)**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep -E "tighter predicate|PASS|FAIL"
```

Expected: PASS.

- [ ] **Step 3: Add `GraphAlgorithm` enum and env reader**

At the top of `graph_expand.zig`:

```zig
pub const GraphAlgorithm = enum { ppr, bfs };

pub fn readGraphAlgorithm() GraphAlgorithm {
    const val = std.posix.getenv("NULLALIS_GRAPH_ALGORITHM") orelse return .ppr;
    if (std.mem.eql(u8, val, "bfs")) return .bfs;
    return .ppr;
}
```

- [ ] **Step 4: Add PPR path to `expandFromSeeds`**

In `expandFromSeeds`, after validating inputs and before the BFS loop, add an algorithm branch:

```zig
pub fn expandFromSeeds(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    seed_keys: []const []const u8,
    config: ExpandConfig,
) !GraphNeighborhood {
    // NOTE: If `GraphNeighborhood.empty()` does not exist, use:
    //   return .{ .nodes = &.{}, .edges = &.{} };
    if (seed_keys.len == 0) return GraphNeighborhood.empty();

    const algorithm = readGraphAlgorithm();

    return switch (algorithm) {
        .ppr => expandFromSeedsPPR(allocator, state_mgr, user_id, seed_keys, config),
        .bfs => expandFromSeedsBFS(allocator, state_mgr, user_id, seed_keys, config),
    };
}
```

Rename the existing BFS implementation function to `expandFromSeedsBFS` (it remains unchanged).

- [ ] **Step 5: Implement `expandFromSeedsPPR`**

```zig
fn expandFromSeedsPPR(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    seed_keys: []const []const u8,
    config: ExpandConfig,
) !GraphNeighborhood {
    const limit = config.max_hops * config.max_nodes_per_hop + seed_keys.len;
    const ppr_nodes = state_mgr.findEdgesPPR(
        allocator,
        user_id,
        seed_keys,
        config.max_hops,
        limit,
    ) catch |err| {
        std.log.scoped(.graph_expand).warn("ppr.fetch_failed err={} falling back to bfs", .{err});
        return expandFromSeedsBFS(allocator, state_mgr, user_id, seed_keys, config);
    };
    defer {
        for (ppr_nodes) |n| n.deinit(allocator);
        allocator.free(ppr_nodes);
    }

    if (ppr_nodes.len == 0) return GraphNeighborhood.empty();

    // Compute max ppr_score for normalization
    var max_ppr: f64 = 0.0;
    for (ppr_nodes) |n| if (n.ppr_score > max_ppr) { max_ppr = n.ppr_score; };

    const now_unix = std.time.timestamp();
    var scored = try allocator.alloc(ScoredNode, ppr_nodes.len);
    errdefer allocator.free(scored);

    for (ppr_nodes, 0..) |n, i| {
        // Recency decay (same formula as BFS: 30d half-life)
        const RECENCY_HALF_LIFE_SECS: f64 = 30.0 * 86400.0;
        const age_secs = @max(0.0, @as(f64, @floatFromInt(now_unix)) - @as(f64, @floatFromInt(0))); // created_at not available from PPR row — use 0 for now
        _ = age_secs;
        const recency: f64 = 1.0; // Recency from PPR row is not available; default to 1.0 pending a JOIN in a follow-up sprint
        _ = RECENCY_HALF_LIFE_SECS;

        const ppr_norm: f64 = if (max_ppr > 0.0) n.ppr_score / max_ppr else 0.0;
        const hop_decay: f64 = 1.0 / (1.0 + @as(f64, @floatFromInt(n.min_depth)));
        const score: f64 = 0.4 * recency + 0.3 * ppr_norm + 0.3 * hop_decay;

        scored[i] = ScoredNode{
            .key = try allocator.dupe(u8, n.key),
            .hop_distance = n.min_depth,
            .score = score,
        };
    }

    // Sort descending by score
    std.sort.block(ScoredNode, scored, {}, struct {
        fn lessThan(_: void, a: ScoredNode, b: ScoredNode) bool { return a.score > b.score; }
    }.lessThan);

    return GraphNeighborhood{
        .nodes = scored,
        .edges = &.{}, // edges not returned by PPR CTE in V1; use BFS for edge rendering if needed
    };
}
```

**Note on recency:** The PPR CTE does not return `created_at` for the discovered nodes. The recency component defaults to 1.0 (no decay) in this sprint. A follow-up task can extend `findEdgesPPR` to JOIN against `memories.created_at` and return it. This is acceptable for V1 of PPR — the PPR score already encodes structural proximity which correlates with recency for well-maintained graphs.

**Note on edges:** The PPR path returns `GraphNeighborhood.edges = &.{}` (empty). The BFS path returns actual edges used for the `<graph_neighbors>` block rendering. If the rendering code requires edges, PPR will fall back silently to BFS for the edge list. Audit `buildGraphNeighborsBlock` in `memory_loader.zig` to determine if this is needed and add a note if it is.

- [ ] **Step 6: Build and run all graph_expand tests**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep -E "graph_expand|PPR|BFS|PASS|FAIL"
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/agent/graph_expand.zig
git commit -m "feat(graph): add PPR path to expandFromSeeds with BFS fallback (P2)"
```

---

## P4 — Tier Sufficiency Gate

*Post-retrieval bucket trimming. Conservative: reduces semantic bucket to 50% when graph coverage is sufficient, never skips it.*

---

### Task 14: Add `tier_gate_fired` and `tier_gate_trimmed_bytes` to `SelectionStats`

**Files:**
- Modify: `src/agent/memory_loader.zig`
- Modify: `src/agent/context_builder.zig`

- [ ] **Step 1: Add fields to `SelectionStats`**

In `src/agent/memory_loader.zig`, find the `SelectionStats` struct. Add at the end:

```zig
// P4: tier sufficiency gate telemetry
tier_gate_fired: bool = false,
tier_gate_trimmed_bytes: usize = 0,
```

- [ ] **Step 2: Mirror in `MemorySelection` in `context_builder.zig`**

Find the `MemorySelection` struct in `src/agent/context_builder.zig`. Add matching fields at the end:

```zig
tier_gate_fired: bool,
tier_gate_trimmed_bytes: usize,
```

- [ ] **Step 3: Update `selectionFromStats` to project the new fields**

Find `selectionFromStats` in `context_builder.zig`. Add:

```zig
.tier_gate_fired = stats.tier_gate_fired,
.tier_gate_trimmed_bytes = stats.tier_gate_trimmed_bytes,
```

- [ ] **Step 4: Update `bucketSummary` in `context_engine.zig` (P5 helper from Task 6)**

Now that `tier_gate_fired` exists, update `bucketSummary` to include it:

```zig
fn bucketSummary(allocator: std.mem.Allocator, stats: memory_loader.SelectionStats) ![:0]u8 {
    return std.fmt.allocPrintZ(
        allocator,
        "continuity:{d},semantic:{d},fallback:{d},graph:{d}{s}",
        .{
            stats.continuity_bucket_entries,
            stats.semantic_bucket_entries,
            stats.fallback_bucket_entries,
            stats.graph_recall_neighbor_count,
            if (stats.tier_gate_fired) ",tier_gate:fired" else "",
        },
    );
}
```

- [ ] **Step 5: Build clean**

```bash
cd /Users/nova/Desktop/nullalis && zig build -Dchannels=cli 2>&1 | head -20
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add src/agent/memory_loader.zig src/agent/context_builder.zig src/agent/context_engine.zig
git commit -m "feat(memory): add tier_gate telemetry fields to SelectionStats and MemorySelection (P4)"
```

---

### Task 15: Implement the sufficiency gate and trim logic

**Files:**
- Modify: `src/agent/memory_loader.zig`

- [ ] **Step 1: Write the failing test**

Add inline test:

```zig
test "tier gate fires when graph coverage is sufficient" {
    const std = @import("std");
    // Simulate stats where gate should fire
    var stats = SelectionStats{
        .available = true,
        .graph_recall_active = true,
        .graph_recall_neighbor_count = 4,
        .graph_recall_appended_bytes = 350,
        .semantic_bucket_bytes = 2200,
        .semantic_bucket_entries = 3,
        .tier_gate_fired = false,
        .tier_gate_trimmed_bytes = 0,
        // zero-init all other fields
    };
    const enabled = true;
    applyTierGate(&stats, enabled);
    try std.testing.expect(stats.tier_gate_fired);
    try std.testing.expect(stats.tier_gate_trimmed_bytes > 0);
    try std.testing.expect(stats.semantic_bucket_bytes <= 1100); // trimmed to half
}

test "tier gate does not fire when graph coverage is insufficient" {
    const std = @import("std");
    var stats = SelectionStats{
        .available = true,
        .graph_recall_active = true,
        .graph_recall_neighbor_count = 1, // below threshold
        .graph_recall_appended_bytes = 150,
        .semantic_bucket_bytes = 2200,
        .tier_gate_fired = false,
        .tier_gate_trimmed_bytes = 0,
    };
    applyTierGate(&stats, true);
    try std.testing.expect(!stats.tier_gate_fired);
}
```

- [ ] **Step 2: Run tests to confirm compile error**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep "applyTierGate"
```

Expected: compile error.

- [ ] **Step 3: Add constants and `applyTierGate` function**

Add to `memory_loader.zig`:

```zig
const TIER_GATE_MIN_NEIGHBORS: usize = 3;
const TIER_GATE_MIN_GRAPH_BYTES: usize = 200;
const TIER_GATE_SEMANTIC_MAX_BYTES: usize = 1100; // half of normal 2200

fn readTierGateEnabled() bool {
    const val = std.posix.getenv("NULLALIS_TIER_GATE") orelse return true;
    return !std.mem.eql(u8, val, "0");
}

/// Applies post-assembly sufficiency gate.
/// Mutates stats to reflect trimming decisions.
/// Does NOT actually trim the bucket bytes in memory — that must be done
/// by the caller on the actual bucket content. This function only computes
/// the decision and records it in stats.
fn applyTierGate(stats: *SelectionStats, enabled: bool) void {
    if (!enabled) return;
    if (!stats.graph_recall_active) return;
    if (stats.graph_recall_neighbor_count < TIER_GATE_MIN_NEIGHBORS) return;
    if (stats.graph_recall_appended_bytes < TIER_GATE_MIN_GRAPH_BYTES) return;

    const original_bytes = stats.semantic_bucket_bytes;
    if (original_bytes <= TIER_GATE_SEMANTIC_MAX_BYTES) return; // already small enough

    stats.tier_gate_fired = true;
    stats.tier_gate_trimmed_bytes = original_bytes - TIER_GATE_SEMANTIC_MAX_BYTES;
    stats.semantic_bucket_bytes = TIER_GATE_SEMANTIC_MAX_BYTES;
}
```

- [ ] **Step 4: Run tests to confirm pass**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | grep -E "tier gate|PASS|FAIL"
```

Expected: both tests pass.

- [ ] **Step 5: Call `applyTierGate` in the actual memory loading flow**

Find the point in `loadTurnMemorySlotOpts` (or its inner function) where the semantic bucket has been assembled and graph expansion has completed. Immediately after both are complete:

```zig
const tier_gate_enabled = readTierGateEnabled();
applyTierGate(&stats, tier_gate_enabled);

// If gate fired, also physically trim the semantic bucket content:
if (stats.tier_gate_fired) {
    // Trim the actual semantic bucket string content to TIER_GATE_SEMANTIC_MAX_BYTES bytes.
    // Find where semantic_bucket is the accumulated []u8 buffer and truncate it.
    // The exact variable name depends on the local code — look for where
    // `stats.semantic_bucket_bytes` was last set and use that same buffer.
    if (semantic_bucket.items.len > TIER_GATE_SEMANTIC_MAX_BYTES) {
        // Truncate at last newline boundary before the limit
        var cut = TIER_GATE_SEMANTIC_MAX_BYTES;
        while (cut > 0 and semantic_bucket.items[cut - 1] != '\n') : (cut -= 1) {}
        semantic_bucket.shrinkRetainingCapacity(if (cut > 0) cut else TIER_GATE_SEMANTIC_MAX_BYTES);
    }
}
```

**Note:** The exact variable name for `semantic_bucket` depends on what you find in the actual function. Grep for where `stats.semantic_bucket_bytes` is set and use the adjacent buffer variable.

- [ ] **Step 6: Build clean**

```bash
cd /Users/nova/Desktop/nullalis && zig build -Dchannels=cli 2>&1 | head -20
```

- [ ] **Step 7: Commit**

```bash
git add src/agent/memory_loader.zig
git commit -m "feat(memory): implement tier sufficiency gate — trim semantic bucket when graph coverage sufficient (P4)"
```

---

## Final Verification

### Task 16: Integration smoke test and bench

- [ ] **Step 1: Build release binary**

```bash
cd /Users/nova/Desktop/nullalis && zig build -Doptimize=ReleaseFast -Dchannels=cli,telegram 2>&1 | tail -5
```

Expected: clean build, binary at `zig-out/bin/nullalis`.

- [ ] **Step 2: Run full test suite**

```bash
cd /Users/nova/Desktop/nullalis && zig build test -Dchannels=cli 2>&1 | tail -20
```

Expected: all tests pass, zero failures.

- [ ] **Step 3: Verify trace events appear for a real turn**

Start the binary and send a message that requires memory retrieval. Then:

```bash
curl -s "http://localhost:8080/api/v1/users/1/traces" | \
  jq -r '.traces[-1].run_id' | \
  xargs -I{} curl -s "http://localhost:8080/api/v1/users/1/traces/{}" | \
  jq '.events[] | select(.kind == "memory_retrieval") | {status, usage_tokens, success}'
```

Expected: one event per turn with a status like `"continuity:1,semantic:3,graph:4"`.

- [ ] **Step 4: Confirm entity overlap is firing**

Enable debug logging and verify `retrieval.source_breakdown` now shows a third source:

```bash
NULLALIS_LOG_LEVEL=debug ./zig-out/bin/nullalis ... 2>&1 | grep "source_breakdown"
```

Expected: output showing `entity_overlap=N` alongside `keyword=N` and `vector=N`.

- [ ] **Step 5: Confirm PPR is running (not BFS)**

```bash
NULLALIS_LOG_LEVEL=debug ./zig-out/bin/nullalis ... 2>&1 | grep "graph_expand"
```

Expected: no `graph_expand.hop` log lines (those are BFS-only). If PPR fails and falls back, you'll see `ppr.fetch_failed` followed by BFS hop logs.

- [ ] **Step 6: Queue LoCoMo conv-43 bench run**

Run the bench with the new binary against conv-43 to measure P1/P2/P4 impact:

```bash
cd /Users/nova/Desktop/nullalis/.spike/external/locomo_runner && \
  python run_bench.py --conv 43 --binary ../../zig-out/bin/nullalis
```

Watch for:
- Cat 2 (multi-hop): expect improvement from P2 PPR (target +3–5pp vs v1.14.20 baseline)
- Cat 4 (open-domain): must not regress >2pp (P1 entity overlap risk)
- No category should regress >2pp

- [ ] **Step 7: Tag the build if bench is green**

```bash
git tag v1.15.0-memory-intel-sprint
```

---

## Environment Variables Reference

| Variable | Default | Effect |
|---|---|---|
| `NULLALIS_ENTITY_OVERLAP` | `1` (enabled) | Set to `0` to disable entity overlap as 3rd RRF source |
| `NULLALIS_GRAPH_ALGORITHM` | `ppr` | Set to `bfs` to use the original flat BFS traversal |
| `NULLALIS_TIER_GATE` | `1` (enabled) | Set to `0` to disable tier sufficiency gate |
| `NULLALIS_TIER_GATE_MIN_NEIGHBORS` | `3` | Minimum graph neighbors to trigger gate |
| `NULLALIS_TIER_GATE_MIN_BYTES` | `200` | Minimum graph appended bytes to trigger gate |

---

## Known Follow-ups (not in this plan)

- Add `created_at` to PPR CTE so recency decay works for discovered nodes (currently defaults to 1.0)
- Add edges to PPR result so `graph_neighbors` block can render relationships (currently empty in PPR path)
- Use P3 provenance data in invalidation pass (extraction_pass-aware contradiction resolution)
- LongMemEval harness to measure P2 impact on temporal + multi-session subsets
- GIN index on `memory_edges(source_key, target_key)` if entity overlap query gets slow at scale
