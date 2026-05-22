# Memory Intelligence Sprint — Design Spec

**Date:** 2026-05-22  
**Status:** Approved for implementation  
**Scope:** Five targeted changes to the nullALIS memory system, all building on existing primitives

---

## Background

This sprint translates the OpenViking "filesystem paradigm" concepts into nullALIS's existing primitives. The core insight from research: OpenViking's value is not in its filesystem metaphor but in three underlying mechanisms — tiered demand loading, principled graph traversal, and provenance at write time. nullALIS already has the right data structures; what's missing is the wiring.

Research basis for each change is cited inline. All five changes are grounded in 2024–2026 benchmarks; none is speculative.

---

## Changes at a Glance

| ID | Name | Expected impact | Effort | Disables via |
|---|---|---|---|---|
| P1 | Entity overlap as 3rd RRF signal | +3–5pp retrieval quality | 1 day | `NULLALIS_ENTITY_OVERLAP=0` |
| P2 | PPR-weighted graph traversal | +20% multi-hop (Cat 2) | 2 days | `NULLALIS_GRAPH_ALGORITHM=bfs` |
| P3 | Provenance fields on memory_edges | Sharper invalidation; trajectory-quality | 1 day | Additive (never breaks reads) |
| P4 | Tier sufficiency gate | Prevents context pollution | 1 day | `NULLALIS_TIER_GATE=0` |
| P5 | Retrieval trace events | Operator debugging surface | 0.5 days | Always-on, low cost |

---

## P1 — Entity Overlap as Third RRF Signal

### Motivation

Mem0's 2026 update added entity matching (subject/object tokens from stored edges) as a third retrieval signal alongside dense vector and BM25. Result: **+29.6pp on temporal reasoning, +23.1pp on multi-hop**. True Memory Pro's 56-configuration ablation showed that varying embedder/reranker combinations produces only 3.2pp spread, but adding a third retrieval signal consistently outperforms two-signal systems. The mechanism: entity names that appear explicitly in the query have high recall precision when matched against stored edge subjects/objects.

nullALIS already has `memory_edges` with `source_key` (entity name) and `target_key` (entity name) columns. The FTS5 and vector pipeline already feeds `rrfMerge`, which already handles N sources. The missing piece is the third source.

### Design

**New component: `EntityOverlapFn` callback on `RetrievalEngine`**

Following the existing `llm_rerank_fn` pattern, add an optional context-pointer callback to the engine. The callback receives the query string, performs entity matching against `memory_edges`, and returns `[]RetrievalCandidate` — one candidate per matching memory key, scored by match count.

```zig
// In src/memory/retrieval/engine.zig

pub const EntityOverlapCallCtx = struct {
    ptr: *anyopaque,
    func: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        query: []const u8,
    ) anyerror![]RetrievalCandidate,
};

// Added to RetrievalEngine struct:
entity_overlap: ?EntityOverlapCallCtx = null,
```

Inside `engine.search()`, after assembling keyword and vector sources (current line ~589–594), check `self.entity_overlap` and if set, call it and append the result to `rrf_sources` before `rrfMerge`.

**Callback implementation: `entityOverlapImpl` in `src/agent/memory_loader.zig`**

The callback is wired in memory_loader (which already has `state_mgr` and `user_id`). The implementation:

1. Tokenize the query string into tokens (split on whitespace/punctuation, lowercase, strip stopwords)
2. Query `memory_edges` for rows where `source_key` or `target_key` contains any query token:
   ```sql
   SELECT DISTINCT m.key, COUNT(e.id) AS match_count
   FROM {schema}.memories m
   JOIN {schema}.memory_edges e
     ON (e.source_key ILIKE ANY($2) OR e.target_key ILIKE ANY($2))
     AND e.is_latest AND e.user_id = $1
   WHERE m.user_id = $1
   GROUP BY m.key
   ORDER BY match_count DESC
   LIMIT 10
   ```
   Where `$2` is an array of `'%token%'` patterns for each token.
3. Convert results to `[]RetrievalCandidate` with `final_score = match_count / max_match_count` (normalized), `source = "entity_overlap"`, `keyword_rank = null`, `vector_score = null`.

**RRF effect:** Entity overlap candidates enter `rrfMerge` as a third source. Keys that appear across all three sources (keyword + vector + entity) receive the highest composite RRF score. Entity-only matches receive lower scores but are not discarded — this correctly handles cases where FTS5 misses an entity name (e.g., proper nouns with unusual casing).

### File changes

| File | Change |
|---|---|
| `src/memory/retrieval/engine.zig` | Add `EntityOverlapCallCtx` type + `entity_overlap` field to struct; call in search() before rrfMerge |
| `src/agent/memory_loader.zig` | Add `EntityOverlapCtx` struct; implement `entityOverlapImpl`; wire callback when building engine config |
| `src/agent/zaki_state.zig` | Add `findEdgesEntityOverlap(user_id, token_patterns, limit)` query function |
| `src/memory/retrieval/engine_test.zig` (inline) | Add test: 3-source RRF produces correct fusion; entity-only candidate scored below dual-match |

### Performance note on ILIKE

The entity overlap query uses `ILIKE ANY($2)` on `source_key` / `target_key`. These are not indexed for pattern search. For typical user graphs (hundreds to low thousands of edges per user) this is acceptable (< 5ms). If edge counts grow into tens of thousands, a `GIN` index on `to_tsvector(source_key || ' ' || target_key)` can replace ILIKE with `@@` full-text matching. Not required for this sprint.

### Rollout

Disabled via `NULLALIS_ENTITY_OVERLAP=0` env var (checked in memory_loader when wiring the callback). Default: enabled.

---

## P2 — PPR-Weighted Graph Traversal

### Motivation

nullALIS's `graph_expand.zig` uses flat BFS scoring: `0.4 × recency + 0.3 × centrality + 0.3 × hop_decay`. This treats all edges as equally informative regardless of predicate type. A `LIVES_IN` edge (single-valued, high precision) and a `MENTIONED_IN_PASSING` edge receive the same structural weight. HippoRAG (NeurIPS 2024) proved Personalized PageRank over a knowledge graph delivers **+20% on multi-hop QA** by propagating seed relevance through typed edge weights. LiCoMemory (+26.6% multi-session) uses the same principle. This directly addresses LoCoMo Cat 2 (multi-hop), which is nullALIS's known gap at 92.3% (vs 93.6% publishable average).

The existing `edge_predicate_priors` table in `graph_expand.zig` (lines 314–345) already encodes exactly the weights PPR needs: single-valued predicates (1.0), set-valued (0.5), unknown (0.7). The substrate is right; the traversal algorithm isn't.

### Design

**New DB function: `findEdgesPPR` in `src/agent/zaki_state.zig`**

Replaces the per-hop `findEdgesByKeys` calls with a single recursive CTE:

```sql
WITH RECURSIVE
edge_priors(predicate, prior) AS (
  VALUES
    ('LIVES_IN', 1.0::float), ('MARRIED_TO', 1.0), ('BIRTHDAY', 1.0),
    ('WORKS_AT', 1.0), ('IS_A', 1.0),
    ('LIKES', 0.5::float), ('USES', 0.5), ('IS_TYPE_OF', 0.5),
    ('ATTENDED', 0.5), ('KNOWS', 0.5)
),
ppr(key, score, depth) AS (
  -- Base: seed nodes at equal weight
  SELECT
    unnest($2::text[]) AS key,
    1.0 / GREATEST(array_length($2::text[], 1), 1) AS score,
    0 AS depth
  UNION ALL
  -- Propagate through edges, weighted by predicate prior and damping
  SELECT
    CASE WHEN e.source_key = p.key THEN e.target_key ELSE e.source_key END,
    p.score * COALESCE(ep.prior, 0.7) * 0.85,
    p.depth + 1
  FROM ppr p
  JOIN {schema}.memory_edges e
    ON (e.source_key = p.key OR e.target_key = p.key)
    AND e.user_id = $1
    AND e.is_latest
  LEFT JOIN edge_priors ep ON ep.predicate = e.predicate
  WHERE p.depth < $3
)
SELECT key, SUM(score) AS ppr_score, MIN(depth) AS min_depth
FROM ppr
GROUP BY key
HAVING SUM(score) > 0.01
ORDER BY ppr_score DESC
LIMIT $4
```

Parameters: `$1` = user_id, `$2` = seed_keys array, `$3` = max_hops, `$4` = limit (max_nodes_per_hop × max_hops + seed_count).

**Updated `expandFromSeeds` in `src/agent/graph_expand.zig`**

When the algorithm is PPR (default), replace the BFS loop (lines 162–256) with:

1. Call `state_mgr.findEdgesPPR(allocator, user_id, seed_keys, config.max_hops, limit)`
2. Receive `[]PPRNode { key, ppr_score, min_depth }` 
3. Compute composite score per node: `0.4 × recency_decay(created_at) + 0.3 × ppr_score_normalized + 0.3 × hop_decay(min_depth)`
   - `recency_decay`: same formula as today (30d half-life)
   - `ppr_score_normalized`: `ppr_score / max(ppr_scores)` across all returned nodes
   - `hop_decay`: `1.0 / (1.0 + min_depth)` (same as current BFS)
4. Build `GraphNeighborhood` from scored nodes + the edges returned by the CTE (stored alongside for context rendering)

The BFS fallback path remains for `NULLALIS_GRAPH_ALGORITHM=bfs`. The algorithm selection is read once at startup via env var and stored in a module-level constant.

**Edge predicate prior table**

The priors currently hardcoded in `graph_expand.zig:314–345` are moved to a shared constant in `src/agent/edge_priors.zig` (new file, ~30 lines). Both `graph_expand.zig` (for BFS scoring) and `zaki_state.zig` (for PPR CTE string generation) import from this shared constant. The CTE's `edge_priors` VALUES clause is generated at comptime from this table to ensure a single source of truth — predicate weights can never diverge between the BFS and PPR paths.

### File changes

| File | Change |
|---|---|
| `src/agent/zaki_state.zig` | Add `findEdgesPPR()` function with recursive CTE; add `PPRNode` return type |
| `src/agent/graph_expand.zig` | Add `PPRResult` type; replace BFS loop with PPR path; keep BFS as fallback; extract predicate priors to shared constant |
| `src/memory/retrieval/engine.zig` | No change |
| `src/agent/memory_loader.zig` | Pass `NULLALIS_GRAPH_ALGORITHM` env flag to `expandFromSeeds` via `ExpandConfig` |

### Rollout

`NULLALIS_GRAPH_ALGORITHM=ppr` (default) or `=bfs` (fallback). Read once at startup. No per-turn overhead.

---

## P3 — Provenance Fields on memory_edges

### Motivation

ExpeL (+7.8pp on Gaia2) and Trajectory-Informed Memory Generation (+14.3–28.5pp on scenario completion) both prove that trajectory improves agent quality — but through **storing provenance on edges at write time**, not through UI visualization. The mechanism: when the invalidation pass (Pass C) knows which extraction boundary created an edge, it can apply stronger confidence to contradictions from the same boundary type vs cross-session contradictions. A `MARRIED_TO` edge from Pass C (compaction of recent conversation) contradicting one from `pass_a` (passive extraction six months ago) should be invalidated with high confidence. Today, all edges carry `attribution = "extraction_classifier"` — every contradiction is treated identically.

Additionally, `episodes TEXT[]` already stores the source memory key, but extraction pass type is not recorded anywhere. Two new columns close this gap at near-zero cost.

### Design

**Schema migration (2 new columns)**

```sql
ALTER TABLE {schema}.memory_edges
  ADD COLUMN IF NOT EXISTS extraction_pass TEXT;

ALTER TABLE {schema}.memory_edges
  ADD COLUMN IF NOT EXISTS session_boundary_id BIGINT;
```

Added to the migration sequence in `src/agent/zaki_state.zig` alongside existing `episodes`, `fact`, `temporal_anchor_unix` migrations (current pattern: lines ~1648–1650). Existing rows will have `NULL` in both columns — safe, reads handle NULL gracefully already.

**Populate at write time**

`persistExtracted` in `src/agent/extraction_persist.zig` already receives `origin: WriteOrigin`. Map it to a text value and pass to `upsertMemoryEdgeRich`:

```zig
const extraction_pass: []const u8 = switch (origin) {
    .pass_a_drop           => "pass_a",
    .pass_c_compaction_extract => "pass_c",
    .session_end_extract   => "session_end",
    .memory_store_tool     => "tool",
    .test_wire             => "test",
    else                   => "unknown",
};
```

`session_boundary_id`: generated as a monotonic ID at the boundary call site (a Unix timestamp in milliseconds is sufficient — unique per boundary within a session). Threaded through the same call chain as `origin`.

**`upsertMemoryEdgeRich` signature extension**

Add two parameters at the end (optional, keeping existing call sites valid by defaulting to null):

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
    extraction_pass: ?[]const u8,     // NEW
    session_boundary_id: ?i64,        // NEW
) !void
```

**Call-site audit required:** Before implementing, grep all call sites for `upsertMemoryEdgeRich` across the entire codebase. Every call site must append `null, null`. Missing any call site will produce a Zig compile error (wrong arg count), so the compiler enforces completeness — but the audit should be done upfront to understand the scope. Expected: all call sites are in `extraction_persist.zig`; verify none exist in test files or other agent modules.

**`session_boundary_id` generation:** Generated as `std.time.milliTimestamp()` at the compaction/boundary call site (the function in `compaction.zig` that calls `persistExtracted`). This value is constant for all edges written in the same boundary event — pass it as a `i64` parameter alongside `origin`. Unix ms timestamps are globally unique per boundary within a user's history at practical compaction rates.

**Invalidation pass benefit**

The Pass C invalidation judge can now query: `WHERE extraction_pass = 'pass_c' AND session_boundary_id = $current_boundary` to find all edges written in the current extraction pass. If a contradiction exists between a new `pass_c` edge and an old `pass_a` edge for the same (subject, predicate), the `pass_c` edge wins with high confidence. This is not implemented in this sprint but the schema enables it.

### File changes

| File | Change |
|---|---|
| `src/agent/zaki_state.zig` | Add 2 `ALTER TABLE` migrations; update `upsertMemoryEdgeRich` signature + INSERT |
| `src/agent/extraction_persist.zig` | Map `origin` to `extraction_pass` text; thread `session_boundary_id`; update call site |
| `src/agent/compaction.zig` (or boundary caller) | Generate `session_boundary_id` (timestamp ms) at boundary and thread to `persistExtracted` |

---

## P4 — Tier Sufficiency Gate

### Motivation

"Lost in the middle" degradation is proven across all 18 frontier models (Chroma 2025 study): accuracy drops continuously as context fills, starting from the first token. ENGRAM achieved +15pp over full-context retrieval using ~1% of the tokens by loading only what's sufficient for the query. The mechanism is not query-time speed — it's context quality. More retrieved memories is strictly worse than fewer right memories.

nullALIS's current flow always injects up to 2200 bytes of semantic bucket results regardless of whether the graph layer has already provided sufficient coverage. When `graph_recall_neighbor_count >= 3` and the graph appended meaningful bytes, the semantic bucket is redundant noise — it tells the LLM things it can already infer from the graph neighbors.

### Design

**Post-assembly bucket trim in `src/agent/memory_loader.zig`**

After the graph neighbors block is built (current line ~1015) and before the identity/communities blocks are appended, evaluate the sufficiency condition:

```zig
const graph_sufficient =
    stats.graph_recall_active and
    stats.graph_recall_neighbor_count >= TIER_GATE_MIN_NEIGHBORS and
    stats.graph_recall_appended_bytes >= TIER_GATE_MIN_BYTES;

if (graph_sufficient and tier_gate_enabled) {
    // Trim semantic bucket to half capacity
    semantic_bucket = trimBucketToBytes(
        semantic_bucket,
        SEMANTIC_BUCKET_MAX_BYTES / 2,  // 1100 bytes instead of 2200
    );
    stats.tier_gate_fired = true;
    stats.semantic_bucket_bytes = semantic_bucket.len;
}
```

Constants (configurable via env vars):
- `TIER_GATE_MIN_NEIGHBORS = 3` — graph must have found at least 3 neighbor nodes
- `TIER_GATE_MIN_BYTES = 200` — graph content must be non-trivial
- `SEMANTIC_BUCKET_MAX_BYTES / 2 = 1100` — trim to half when gate fires

**Conservative design decision:** The gate trims (reduces to 50%) rather than skips the semantic bucket. This ensures the FTS5 path still contributes if the graph nodes happen to be topically adjacent but not directly responsive. A future sprint can tune toward full skip once the LoCoMo bench confirms the trim is safe.

**Telemetry:** Add `tier_gate_fired: bool` and `tier_gate_trimmed_bytes: usize` to `SelectionStats` and `MemorySelection` for observability via P5.

### File changes

| File | Change |
|---|---|
| `src/agent/memory_loader.zig` | Add sufficiency check + trim after graph block; add env var reader `readTierGateEnabled()`; add 2 telemetry fields to stats |
| `src/agent/context_builder.zig` | Mirror new `tier_gate_fired` + `tier_gate_trimmed_bytes` in `MemorySelection` |

### Rollout

`NULLALIS_TIER_GATE=1` (default enabled) or `=0` (disabled). Tuning constants also env-overridable (`NULLALIS_TIER_GATE_MIN_NEIGHBORS`, `NULLALIS_TIER_GATE_MIN_BYTES`).

---

## P5 — Retrieval Trace Events

### Motivation

This is a DX feature, not a quality improvement. The research is clear: showing a retrieval trace to users or operators does not directly improve agent memory quality. However, operators debugging a recall failure (wrong memory retrieved, context pollution, graph expansion not firing) currently have no structured signal — they must read raw logs and parse `source_breakdown` info lines. The `/api/v1/users/{user_id}/traces/{run_id}` endpoint already exposes turn-level events; adding a `memory_retrieval` event kind makes the existing endpoint useful for memory debugging with zero new infrastructure.

### Design

**New `TraceEventKind`: `.memory_retrieval`**

```zig
// In src/run_trace_store.zig, TraceEventKind enum:
memory_retrieval,
```

**Emit in `context_engine.ingest()`**

After `loadTurnMemorySlotOpts` returns (current line ~447), and before recording the turn stage event:

```zig
if (mem_slot.stats.available) {
    var evt = ObserverEvent{
        .kind = .memory_retrieval,
        .run_id = agent.current_run_id,
        .ts_ms = std.time.milliTimestamp(),
        .label   = "memory_retrieval",
        .status  = bucketSummary(mem_slot.stats), // "continuity:N,semantic:N,graph:N"
        .success = mem_slot.stats.injected,
        .usage_tokens = @intCast(mem_slot.stats.context_bytes),
        .iteration    = @intCast(mem_slot.stats.candidate_count),
        .duration_ms  = enrich_ms,
    };
    agent.observer.recordEvent(&evt);
}
```

`bucketSummary` is a small helper that formats the SelectionStats bucket breakdown as a compact string (e.g., `"continuity:2,semantic:3,graph:4,tier_gate:fired"`). This fits in the existing `status` field (MAX_FIELD_LEN=256 bytes).

**Serialization in `gateway.zig`**

`serializeTraceEventJson` already emits `kind`, `ts_ms`, `status`, `success`, `usage_tokens`, `iteration`, `duration_ms` for all event kinds. The `memory_retrieval` event kind uses all of these — no new JSON fields needed.

**What operators get**

A `GET /api/v1/users/{user_id}/traces/{run_id}` response now includes, for each turn:
```json
{
  "kind": "memory_retrieval",
  "ts_ms": 1748000000000,
  "status": "continuity:1,semantic:3,graph:4,tier_gate:fired",
  "success": true,
  "usage_tokens": 1840,
  "iteration": 8,
  "duration_ms": 43
}
```

Combined with the surrounding `llm_request` / `tool_call` events, this gives a complete turn reconstruction: what memories loaded → what the LLM was asked → what tools ran.

**P3 + P5 synergy:** Once P3 provenance fields are populated, a follow-on query against `/brain/graph` can show which `extraction_pass` created each node visible in a trace — closing the loop on trajectory observability at zero additional implementation cost.

### File changes

| File | Change |
|---|---|
| `src/run_trace_store.zig` | Add `.memory_retrieval` to `TraceEventKind` enum; add `toSlice()` case |
| `src/agent/context_engine.zig` | Emit `memory_retrieval` event after `loadTurnMemorySlotOpts`; add `bucketSummary()` helper |
| `src/gateway.zig` | No change needed (existing serialization covers all fields used) |

---

## Complete File Change Map

```
src/
  memory/
    retrieval/
      engine.zig              P1: EntityOverlapCallCtx type; entity_overlap field; call in search()
      rrf.zig                 No change (already handles N sources)
  agent/
    graph_expand.zig          P2: PPRResult type; PPR path in expandFromSeeds; BFS fallback
    memory_loader.zig         P1: entityOverlapImpl + wiring; P4: sufficiency gate + env reader
    extraction_persist.zig    P3: extraction_pass mapping; session_boundary_id threading; updated call
    context_builder.zig       P4: mirror new stats fields in MemorySelection
    context_engine.zig        P5: emit memory_retrieval event; bucketSummary helper
    zaki_state.zig            P1: findEdgesEntityOverlap(); P2: findEdgesPPR() + PPRNode type;
                              P3: 2 migrations + updated upsertMemoryEdgeRich signature
  run_trace_store.zig         P5: memory_retrieval kind + toSlice() case
```

---

## Test Plan

### P1 — Entity overlap
- Unit test: `entityOverlapImpl` with a mock state_mgr returns correct candidates for a query containing a known entity name
- Unit test: 3-source RRF produces higher score for a key appearing in all three sources vs two
- Integration: turn with an explicit entity name in query produces higher memory rank for that entity's edges vs baseline keyword search alone

### P2 — PPR
- Unit test: `findEdgesPPR` with synthetic edges returns higher scores for tightly-connected seeds vs loosely-connected
- Unit test: single-valued predicate edges (prior=1.0) propagate higher PPR score than set-valued (prior=0.5)
- Unit test: `expandFromSeeds` with PPR algorithm produces `GraphNeighborhood` with correct hop distances
- Regression: existing graph_expand.zig tests must pass with BFS fallback path

### P3 — Provenance
- Unit test: `persistExtracted` with `origin = .pass_c_compaction_extract` writes `extraction_pass = "pass_c"` to the edge
- Integration: after a compaction boundary, querying `memory_edges WHERE extraction_pass = 'pass_c'` returns the expected edges
- Migration safety: schema upgrade on a database with existing edges leaves `extraction_pass = NULL` for old rows (no data loss)

### P4 — Sufficiency gate
- Unit test: `buildMemorySlot` with graph_recall_neighbor_count=4 and graph_recall_appended_bytes=400 fires the gate and reduces semantic_bucket_bytes by ~50%
- Unit test: gate does NOT fire when graph_recall_neighbor_count=1 (below threshold)
- Integration: `tier_gate_fired=true` appears in SelectionStats on a turn where graph expansion returned ≥3 neighbors

### P5 — Trace events
- Unit test: after a turn, `run_trace_store.snapshotRun()` contains exactly one `memory_retrieval` event per turn
- Unit test: `bucketSummary` formats SelectionStats correctly, including `tier_gate:fired` when P4 gate triggers
- Integration: `GET /api/v1/users/{user_id}/traces/{run_id}` response includes `memory_retrieval` events interleaved with `llm_request` events in chronological order

---

## Rollout Order

Implement in dependency order:

1. **P3 first** — schema migration, no behavioral change, enables accurate telemetry from day one
2. **P5** — adds observability before behavioral changes land; operators can monitor from this point
3. **P1** — entity overlap; adds signal, no existing signal is removed
4. **P2** — PPR replaces BFS; most significant behavioral change, should be bench-validated
5. **P4** — sufficiency gate; trim is conservative; validate with bench before enabling in production

Each change ships independently. P3 and P5 are zero-risk. P1, P2, P4 each have env-var kill switches.

---

## Bench Validation

Run LoCoMo conv-43 after each behavioral change (P1, P2, P4) with the patched scorer. Expected movements:

| Change | Expected | Watch for |
|---|---|---|
| P1 entity overlap | +1–3pp Cat 2 (multi-hop), flat Cat 1/4 | Any Cat 4 regression from entity false positives |
| P2 PPR | +3–5pp Cat 2, flat others | Cat 3 (temporal) regression if PPR over-propagates on dense entity graphs |
| P4 tier gate | Flat or +1pp Cat 4, no Cat 1/2 regression | Any Cat 1 regression if gate fires on low-graph-quality turns |

Acceptance: no change regresses any category by >2pp vs v1.14.20 baseline.

---

## What This Sprint Does Not Include

- **Recursive BM25 scoring on `memory_edges`**: separate from entity overlap; deferred
- **Cross-encoder reranking (L7 upgrade)**: valid but requires a new sidecar model — separate sprint
- **LongMemEval harness**: needed before the next major bench push — separate sprint
- **Invalidation pass using provenance** (using P3 data): enabled by P3 but implemented separately
- **Visualization UI**: no evidence this improves agent quality; no frontend to host it
