# V1.6 Commits 7-10 Code Review

**Reviewed:** 2026-05-02
**Depth:** deep (cross-file, including memory ownership analysis)
**Reviewer:** Claude Opus 4.7
**Scope:** commits `6f9d98c` (cmt7), `b664ae4` (cmt8), `fad8e8a` (cmt9), `c44c908` (cmt10)
**Out of scope:** V1.5.5 substrate prompt, fidelity corpus harness

---

## Commit 7 (`6f9d98c`) — materialized memory_edges + Gap 2 stable keys

**Verdict:** clean on the schema/ON CONFLICT side; one allocator concern in passing.

### [INFO] cascade UPDATE is not atomic with the parent memory close-out
**File:** `src/zaki_state.zig:3269-3320` (setMemoryInvalidation, original cmt7 shape)
**Issue:** `setMemoryInvalidation` issues two separate `execParams` (memories UPDATE then memory_edges UPDATE) without an explicit `BEGIN`/`COMMIT`. If the second statement fails, or the process dies between them, memories close while edges remain `is_latest=TRUE` — leaking edges from a closed-out node.
**Fix:** wrap in `BEGIN ... COMMIT` or note the inconsistency window in the contract. Pre-existing pattern in this file (also true of `upsertMemoryWithMetadata` callers), so not a regression introduced by cmt7 — but cmt7 made the surface bigger.

### Schema/ON CONFLICT correctness — verified
- Partial unique index `idx_edges_triple ... WHERE is_latest` is correctly targeted by `ON CONFLICT (user_id, source_key, predicate, target_key) WHERE is_latest` in `upsertMemoryEdge` (PG 9.5+ requires the predicate match exactly — it does).
- Partial indexes `idx_edges_source` / `idx_edges_target` (`WHERE is_latest`) are correctly hit by `countEdgesForSource` and `listEdgesForUser` (both filter `AND is_latest`).
- Cascade `WHERE source_key = $2 OR target_key = $2 AND is_latest`: operator precedence is correct in PG (AND binds tighter than OR, but the parens around `(source_key = $2 OR target_key = $2)` make it unambiguous — they're present in the SQL string).
- Resurrect-on-upsert semantics: an old `is_latest=FALSE` row sits unbothered by the partial index, and a fresh insert creates a new `is_latest=TRUE` row. Correct interaction with W-INT-01.

### Gap 2 collision risk — acceptable, scoped per-user
**File:** `src/agent/extraction_persist.zig:281-302` (deriveExtractionKey)
The 64-bit truncated SHA-256 collision space is shared **only** within a single user's namespace because the `memories.key` UNIQUE is `(user_id, key)`. Two users can have identical `extracted_<hex>` keys without conflict. Birthday probability of a same-user collision at 1M facts is ~2.7e-8 — acceptable. Multi-tenant scaling does **not** compound the risk because tenancy is in the index. ✓

### Test coverage gaps (worth a future test, not blocking)
- No test for the resurrect path on `memory_edges`: insert triple → cascade-close → re-insert same triple. Should produce a NEW `is_latest=TRUE` row alongside the closed one. The current cmt7 test stops at the cascade.
- No test for an extraction whose `m.object` exceeds the 256-byte `lower_buf` in `deriveEntityKey` — falls through to the un-lowered path silently (`Helix` and `helix` would then map to different keys for long object strings). Defensive but surprising; see commit 8 below for upgrade.

---

## Commit 8 (`b664ae4`) — entity coreference (cosine ≥0.95)

**Verdict:** functionally correct; one real allocator-mismatch bug, one race window worth noting.

### [WARN] `upsertEntity` returns `self.allocator`-owned memory through a caller-allocator parameter
**File:** `src/zaki_state.zig:3552-3585` (upsertEntity)
```zig
pub fn upsertEntity(
    self: *Self,
    allocator: std.mem.Allocator,   // <-- caller's allocator
    user_id: i64, name: []const u8, embedding: []const f32,
) ![]u8 {
    ...
    const id = try self.randomHexId(self.allocator, 16);   // self.allocator
    errdefer self.allocator.free(id);
    ...
    if (c.PQntuples(result) == 0) return id;               // returns self.allocator-owned mem
    const returned_id = try dupeResultValue(allocator, result, 0, 0);  // caller's allocator
    self.allocator.free(id);
    return returned_id;
}
```
**Issue:** The early-return path on line `if (c.PQntuples(result) == 0) return id;` returns `id` which was allocated with `self.allocator`. The caller will free it with the `allocator` parameter (per the function's contract — the test at line 6736-6824 does exactly that). When `mgr.allocator != caller's allocator` (likely in production where the gateway threads a per-tenant arena into recall/expand calls), this is a free-with-wrong-allocator. With `GeneralPurposeAllocator` in safe modes, this surfaces as a debug-allocator assertion or silent corruption depending on which allocator catches it.

**Fix:**
```zig
const id = try self.randomHexId(allocator, 16);   // use caller's allocator
errdefer allocator.free(id);
...
if (c.PQntuples(result) == 0) return id;
const returned_id = try dupeResultValue(allocator, result, 0, 0);
allocator.free(id);
return returned_id;
```
Or document that the function requires caller's allocator == manager's allocator.

The smoke test masks this because `std.testing.allocator` is used for both — needs a test where they differ.

### [INFO] `extraction_coref_embed` cascade has no race in current call graph
**Files:** `src/gateway.zig:1521-1538`, `src/session.zig:184-188,400-408`, `src/agent/root.zig:372-377`
The pointer is set once in `TenantRuntime.init` (single-threaded init) and read per-turn from `agent.extraction_coref_embed` after `buildSessionAgent` copies it. Per-turn agents are not shared across turns. The provider lifetime is owned by `mem_rt`, which outlives all derived agents in a TenantRuntime — confirmed by the existing pattern for `extraction_state_mgr`.

No race. The only failure mode is "TenantRuntime gets re-initialized while a turn is in flight" which isn't a code path that exists today.

### [INFO] `findEntityByCosine` — 1024-d vector formatting allocates O(N) per call
**File:** `src/zaki_state.zig:3479-3488` (and twin in upsertEntity)
A 1024-d embedding formatted as `"[v1,v2,...,v1024]"` with 6-decimal precision is ~10KB of text allocated, formatted, then duped again as a `[*:0]const u8`. Per-fact, embedded once per write — bounded. Not perf-flaggable for V1.6 scope (per review charter), but if Pass C scales to 100s of facts per session, this becomes the per-fact dominant allocation. Worth a note for later.

### [INFO] cosine threshold boundary not tested
The smoke test uses orthogonal embeddings (sim=0.0) and identical embeddings (sim=1.0). The 0.95 boundary is never exercised. A cmt where Pass C generates entities with cosine 0.94 vs 0.95 would benefit from a unit test that synthesizes embeddings at exactly that boundary (mathematically — vector at angle `arccos(0.94)` from a reference). Not required, but missing.

### Schema integrity — clean
- `findEntityByCosine` uses pgvector `<=>` (cosine distance) and converts to similarity via `1 - <=>`. The ORDER BY uses `<=>` directly — guaranteed to use `idx_entities_vec` (ivfflat). ✓
- `upsertEntity`'s `ON CONFLICT (user_id, name_lower)` correctly handles the trivial case-only variance ("Helix" vs "helix") even when cosine is unavailable.
- `EntityRow.deinit` matches the allocations in `findEntityByCosine`. ✓

---

## Commit 9 (`fad8e8a`) — edge mutation events

**Verdict:** clean; the cascade-RETURNING pattern is implemented correctly.

### Cascade RETURNING / per-row emission — verified
**File:** `src/zaki_state.zig:3314-3344`
- `cascade_result` survives the per-row loop because `defer c.PQclear(cascade_result)` fires at function exit, not at the end of the UPDATE statement. ✓
- Each `dupeResultValue catch continue` has its `defer ... free` properly bound to the loop-iteration scope. Zig fires defers on `continue`, so partial-failure rows leak nothing. ✓
- `insertEdgeEvent` failure mid-loop is logged + iteration continues. The cascade UPDATE is already committed (separate execParams), so closed edges stay closed; the missing event row degrades to "history starts here" as documented.
- No "row leak" from RETURNING on transaction failure because each `execParams` is its own implicit transaction in libpq. If the UPDATE fails, RETURNING returns nothing and the loop runs zero iterations.

### Edge-event `insertEdgeEvent` JSON construction — safe
**File:** `src/zaki_state.zig:3433-3493`
- `jsonString` (defined at `src/zaki_state.zig:5376-5392`) escapes `\\`, `\"`, `\n`, `\r`, `\t`. Adequate for predicate/key strings which come from the LLM extraction. Other control chars (0x00-0x1F minus the named ones) would technically need escaping for strict JSON, but PG's `::jsonb` cast is lenient and these chars don't appear in extraction output. Not a v1 finding.
- `event_type` is constructed as `edge_<op>` from a static `op` parameter ("added"/"closed") — no injection surface. ✓

### Test coverage gap — cascade no-op not covered
**Concern from prompt:** "edge_closed events on a memory that has NO edges — cascade no-op produces zero events."
**Status:** not tested. The cmt9 test always has 2 edges before the cascade. The codepath where `c.PQntuples(cascade_result) == 0` is exercised by the cmt7 test (which closes a memory and the test predates RETURNING) but cmt9's specific zero-event-emission path is implicit — covered by the loop bound, not asserted. Worth one extra `try mgr.upsertMemoryWithMetadata(... no edges); try mgr.setMemoryInvalidation(...); assert COUNT(*) WHERE event_type='edge_closed' = 0`.

---

## Commit 10 (`c44c908`) — graph-expand retrieval primitive

**Verdict:** mostly clean; one real PG-injection concern with NUL bytes, one design-limit on the hub cap, one note on the recency math being a no-op.

### [WARN] `findEdgesByKeys` array literal silently truncates on NUL byte in a key
**File:** `src/zaki_state.zig:3585-3602`
The PG TEXT[] literal is built into `arr_buf`, then duped via `allocator.dupeZ(u8, arr_buf.items)`. `dupeZ` is fine with embedded NULs in the source (it copies bytes + appends sentinel), but the resulting `[*:0]const u8` is passed to libpq as a C string. **libpq stops at the first NUL**, so an embedded NUL in any key truncates the array literal mid-element, producing malformed SQL or — worse — a syntactically valid but semantically wrong query (e.g., truncating to `{"node_a"` would return a parse error; truncating to `{"node_a","b` mid-element produces a parse error from PG).

In practice, all current callers pass hex-derived keys, so this is **latent**. But `findEdgesByKeys` is a new public surface that the prompt notes "passed by workflow as primary scoping mechanism" — a future caller threading user input (e.g., a `/brain/expand` query param) could trip it.

**Fix:** validate keys at the entry of `findEdgesByKeys`:
```zig
for (keys) |k| {
    if (std.mem.indexOfScalar(u8, k, 0) != null) return error.InvalidKey;
}
```
Or document the precondition.

Multi-byte UTF-8 and `{`, `}`, `,`: all safe inside double-quoted PG array elements — only `\` and `"` need escaping, and both are handled. ✓

### [INFO] hub-cap drops the wrong edges in a pathological frontier
**File:** `src/agent/graph_expand.zig:198-217`
The cap is checked per-edge against `admitted` (count of new nodes admitted). Edges sorted by weight DESC. If the top-`max_nodes_per_hop` edges all point at already-discovered nodes (cycle from frontier back to seed), the cap exhausts on edges that admit zero new nodes, and the lower-weight edges that DO bridge to new nodes get skipped.

Concretely:
```
Frontier = {B}. Edges from B (sorted by weight DESC):
  B → A  (weight 0.99)  <- A is a seed, already discovered
  B → C  (weight 0.50)  <- C is new
With max_nodes_per_hop=1: admitted starts at 0, first edge B→A adds nothing
(both endpoints already in node_hops), admitted stays 0. Second edge B→C
admits C. Works.
```
But:
```
With max_nodes_per_hop=1 and 20 already-seen high-weight neighbors first:
  All 20 edges checked, admitted stays 0 the whole time, last edge admits C.
Works for small cap, but...
```
Actual problem: the cap check `if (admitted >= config.max_nodes_per_hop) continue;` means once you hit the cap you stop discovering, even if remaining edges go to cheaper-but-unseen nodes. This **is** the documented "drops weakest beyond cap" semantic — but the prompt's concern is correct: the cap can drop bridges to NEW nodes in favor of edges to already-discovered nodes (the already-discovered ones don't consume cap budget, but do consume the iteration order). 

In dense graphs this is benign (many bridges). In sparse-with-hub graphs, low-weight bridges may get dropped. Worth flagging in the algorithm doc; not a correctness bug.

### [INFO] `recencyDecay(now, now)` always returns 1.0 — recency component is constant
**File:** `src/agent/graph_expand.zig:241-242,251`
```zig
const recency = importance.recencyDecay(now, now);
...
const score = 0.4 * recency + 0.3 * centrality + 0.3 * hop_decay;
```
`recencyDecay(now, now)` is `exp(0)` = 1.0 unconditionally. The 0.4 weight is dead — every node gets +0.4 added. Documented as an approximation ("Caller can re-score with real created_at if they care") — fine for the primitive — but means the `recency_half_life_days: f64 = 30.0` field in `ExpandConfig` is dead config (never read). Either delete the field, or follow through with the secondary `getMemory` round trip in a future commit.

`@max(0, now - created_at)` in `recencyDecay` (importance.zig:50) prevents underflow on future-dated `created_at`. ✓

### BFS cycle termination — verified
**File:** `src/agent/graph_expand.zig:148-225`
The `node_hops.contains(cand)` check on every candidate guarantees a node is added to `next_frontier` at most once per BFS run. A cycle A→B→A produces:
- Hop 0: seed A, frontier=[A]
- Hop 1: edge A→B, B is new (added), edge A→A (if exists) skipped. next_frontier=[B]. frontier ← [B].
- Hop 2: edges B→A (A in node_hops, skipped), B→C if it exists. next_frontier=[C] or empty.

No infinite loop. ✓

### Frontier ownership / lifetime — verified
**File:** `src/agent/graph_expand.zig:181-225`
- Initial frontier appends raw `seed_keys[i]` slices (caller-owned, outlive the function).
- After hop 1, `frontier.clearRetainingCapacity()` then re-appends from `next_frontier.items`. Each item there is `owned_cand` — a dupe owned by `node_hops` (the put with that key). The map's defer at function exit frees them all.
- `next_frontier.deinit(allocator)` only frees the list backing array, not the items. Items survive in `node_hops`. ✓
- `frontier.deinit(allocator)` (top-level defer) is safe: items are aliases to either caller memory or node_hops memory, never owned by frontier itself. ✓

### Edge ownership in `all_edges` — verified
Edges fetched via `findEdgesByKeys` are immediately moved into `all_edges` (`try all_edges.append(allocator, e);`), and the local `hop_edges` slice is freed (only the backing slice — items moved). The returned `GraphNeighborhood.edges` takes ownership via `toOwnedSlice`. `deinit` calls `e.deinit(allocator)` for each. ✓

### Test coverage gap — cycle in graph
The cmt10 test uses a 3-node chain. A cycle (A→B→A or A→B→C→A) would explicitly verify the cycle-termination property. Worth one additional test.

### Test coverage gap — failed `findEdgesByKeys` mid-expansion
The "fetch fail on a hop → break + return what we have" failure mode is documented but not unit-tested. Hard to test without injecting a fault into the manager — defer.

---

## Cross-commit observations

### Allocator hygiene drift
The `upsertEntity` finding above is symptomatic of a broader pattern in `zaki_state.zig`: some functions allocate with `self.allocator` and return to a caller using a passed-in `allocator`. Same shape exists in `randomHexId` callsites at lines 1940, 2273, 2574, 2714 — all of those are returns into local-scope frees, so they're fine. cmt8's `upsertEntity` is the first one that returns the allocation across the boundary. Spot-check the rest of `zaki_state.zig` for similar shapes before they multiply.

### The cmt9 `extraction_coref_embed` plumbing is consistent with `extraction_state_mgr`
TenantRuntime → SessionManager → Agent (via buildSessionAgent copy) — same plumbing pattern, same lifetime guarantees. The pointer is stable because EmbeddingProvider is heap-allocated by `createEmbeddingProvider` (per the test at `src/memory/vector/embeddings.zig:852`). No dangling-vtable concern. ✓

### Out-of-scope but adjacent
- The deferred Gateway brain-graph swap from `buildBrainTypedEdges` (JSONB scan) to `listEdgesForUser` (table read) — cmt7/cmt8 ship the read surface but not the swap. Worth one acceptance test that compares output of the two paths on the same data, for the eventual swap commit. Otherwise the swap is a step into the dark.
- Gap 3 unification (durable_fact loop + memory_store routing) is explicitly deferred to cmt9.5. The Gap 2 stable keys + cmt7 ON CONFLICT path mean that when Gap 3 lands, the bypass-judge writers will land on the same key as Pass C — convergence is built in. ✓

---

## Summary by commit

| commit | severity | finding count |
|--------|----------|---------------|
| cmt7   | INFO     | 1 (cascade non-atomicity, pre-existing pattern) |
| cmt8   | WARN     | 1 (upsertEntity allocator mismatch); INFO: 3 |
| cmt9   | clean    | (1 test gap noted) |
| cmt10  | WARN     | 1 (NUL byte in key truncates array literal); INFO: 2 |

**Action items (in priority order):**
1. **cmt8 WARN**: Fix `upsertEntity` to use the caller's allocator throughout, or document the precondition. Add a test where mgr.allocator and caller's allocator differ.
2. **cmt10 WARN**: Validate keys for embedded NUL bytes at `findEdgesByKeys` entry, or document the precondition.
3. **cmt10 INFO**: Either remove `recency_half_life_days` from `ExpandConfig` or wire a real per-node `created_at` lookup. Currently dead config.
4. (deferred) cmt7 atomicity: wrap `setMemoryInvalidation`'s two UPDATEs in `BEGIN`/`COMMIT` when convenient.

Nothing here blocks the V1.6 train.
