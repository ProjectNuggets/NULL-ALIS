---
phase: V1.6 ship-gate review (cmt7-16 + cmt9.5)
reviewed: 2026-05-02T22:00:00Z
depth: deep
files_reviewed: 11
files_reviewed_list:
  - src/zaki_state.zig
  - src/agent/extraction_persist.zig
  - src/agent/graph_expand.zig
  - src/agent/commands.zig
  - src/memory/lifecycle/summarizer.zig
  - src/memory/root.zig
  - src/tools/memory_archive.zig
  - src/tools/memory_demote.zig
  - src/tools/root.zig
  - src/gateway.zig
  - src/agent/compaction.zig
findings:
  critical: 0
  warning: 2
  info: 3
  total: 5
status: issues_found
---

# V1.6 Ship-Gate Review: cmt7-16 + cmt9.5

**Reviewed:** 2026-05-02
**Depth:** deep (cross-commit, allocator-traced, SQL-audited)
**Files Reviewed:** 11
**Status:** SHIP-READY with 2 follow-up WARNs (neither blocking)

## Summary

Cross-commit interactions all check out. Backfill cmt16 is correctly cascade-respecting (skips memories where `valid_to` is in the past, so closed-out edges cannot be resurrected via re-migration). cmt15 `/brain/documents` and cmt14 source-attribution coexist cleanly on the `memories` table — different SET clauses, no SQL collision. cmt9.5 session-end edges share `entity_<hash>` keys with cmt7 extraction edges (identical SHA-256 over `lower(object)`, first 8 bytes hex → 16 chars, prefixed `entity_`). cmt12 `/brain/search` overshoot is bounded (limit pre-capped at 100 before `*2` → max 200, no overflow). cmt11 demote properly clears V1.7 immortality (`UPDATE ... WHERE memory_type='core'` lets subsequent upserts edit; `setMemoryInvalidation` cascades to edges per cmt6/cmt7).

Two real WARN findings (one a JSON-injection in audit payload, one a cross-locale lowercasing mismatch). Three INFO observations. No CRITICAL.

Hygiene contract verified end-to-end: `BRAIN_HIDDEN_PREFIXES` lists `timeline_summary/`, `session_summary/`, `summary_latest/`. cmt15 `/brain/documents` intentionally surfaces these as documents; cmt12 `/brain/search` and cmt13 `/brain/memory/{key}` both gate on `isBrainVisibleKey` and 404 on those keys. **No cross-leak.**

Allocator hygiene (per-iteration `errdefer` chains in `listEdgesForUser`, `findEdgesByKeys`, `listEventsForMemoryKey`, `listBrainDocumentSummaries`): all transfer ownership to the `out: ArrayListUnmanaged(...)` via `try out.append(...)`; outer `errdefer` walks `out.items` and frees each. Per-iteration `errdefer` correctly fires only if append fails for that row. No double-free. `graph_expand.expandFromSeeds` BFS: `node_hops` owns the key strings; `frontier`/`next_frontier` only borrow pointers; `hop_edges` slice freed via `allocator.free` while ownership of TypedEdge structs (with their internal string ptrs) moves to `all_edges`. Clean.

bindStateMgrTenant follows the exact vtable-discriminated pattern as bindMemoryTools — same race-freedom guarantee.

## Warnings

### WR-01: Audit payload JSON injection in `demoteMemoryFromCore`

**File:** `src/zaki_state.zig:3417` (cmt11, line range from commit `fe89a98`)

**Issue:** The audit-event payload constructed for `event_type='demote'` raw-interpolates `key` and `target_category_str` into a JSON literal:
```zig
const payload = std.fmt.allocPrint(
    self.allocator,
    "{{\"key\":\"{s}\",\"from\":\"core\",\"to\":\"{s}\"}}",
    .{ key, target_category_str },
) catch return true;
```

If `key` contains `"` or `\` or a control character, the resulting string is malformed JSON. Cast to `payload_z::jsonb` then fails. The catch-return-true makes the failure silent (audit best-effort), but the audit row is silently lost. `target_category_str` is bounded by tool validation to "daily"/"conversation"/"episodic" — safe. `key` is agent-controlled. Today's keys are agent-generated (`extracted_<hex>`, `durable_fact/<text>`, `entity_<hex>`) and unlikely to contain `"` — but `memory_demote` is a public agent tool and the agent could in principle pass any string.

Compare with `insertEdgeEvent` (cmt9, src/zaki_state.zig:3805) which correctly uses the file-local `jsonString()` helper for every interpolated field. **demoteMemoryFromCore is the lone offender.**

**Fix:**
```zig
const key_json = try jsonString(self.allocator, key);
defer self.allocator.free(key_json);
const tgt_json = try jsonString(self.allocator, target_category_str);
defer self.allocator.free(tgt_json);
const payload = std.fmt.allocPrint(
    self.allocator,
    "{{\"key\":{s},\"from\":\"core\",\"to\":{s}}}",
    .{ key_json, tgt_json },
) catch return true;
```
(Note the removed `\"...\"` wrapping — `jsonString` returns the value already quoted.)

---

### WR-02: ASCII-only lowercasing in `deriveEntityKey` / `deriveSessionEndEntityKey` mismatches PG `lower()` on non-ASCII

**File:** `src/agent/extraction_persist.zig:718`, `src/agent/commands.zig:156`, `src/zaki_state.zig:1217-1219` (cmt7/cmt9.5/cmt16 backfill SQL)

**Issue:** Both Zig helpers use `std.ascii.toLower` which leaves non-ASCII bytes unchanged. The cmt16 backfill SQL uses PostgreSQL's `lower(metadata->>'object')` which is locale-aware and does lowercase Unicode (e.g., `'CAFÉ'` → `'café'`).

Concrete divergence: an extracted object `"CAFÉ"` (with U+00C9 É):
- Zig path: hashes `"CAFÉ"` (É unchanged) → entity_<hash_A>
- SQL backfill path: hashes `lower('CAFÉ')` = `'café'` → entity_<hash_B>

Result: backfill creates a different entity node than the live extraction path would. Two surface-form variants of the same entity end up as two graph nodes that should be one.

Probability is low because the dual-output extraction prompt typically emits canonical lowercase objects (Pass C JSON-tail discipline), but the surface is unbounded — any non-ASCII uppercase character in `metadata.object` triggers the divergence.

**Fix (smallest change):** Either (a) lowercase via Unicode-aware Zig (use `std.unicode.utf8Decode` + ICU, or a small uppercase-ASCII-letter-only mapping that matches PG's behavior for ASCII-only inputs), or (b) keep PG `lower()` semantics by using the SQL-side hash everywhere — but that's a bigger refactor. For V1.6 ship: document the constraint that `metadata.object` should already be lowercased by the extractor prompt; add a Zig-side debug assert in dev builds.

A practical compromise: pre-canonicalize the object string at extraction time (`lower()` it before feeding into the hash AND before sending to the LLM as the canonical entity name), so both paths see the same bytes.

## Info

### IN-01: cmt16 backfill is run on every `migrate()` call (idempotent, but worth noting)

**File:** `src/zaki_state.zig:1213-1232`

The backfill INSERT lives in the `statements` array of `migrate()`. Each `migrate()` call replays the full SQL list. The `ON CONFLICT (user_id, source_key, predicate, target_key) WHERE is_latest DO NOTHING` makes the re-run a no-op for already-backfilled triples, and the WHERE clause skips memories whose `valid_to` is in the past — so archived memories cannot resurrect their close-out-cascaded edges.

The only theoretical resurrection risk: a memory that's currently active but whose edges were closed for a non-archival reason. As of cmt6/cmt7/cmt9, the only path to `is_latest=false` on an edge is via `setMemoryInvalidation` cascade — which fires when the *memory* is invalidated. So "active memory with closed edges" is not a current state that exists. **No bug today.** Just worth flagging if a future commit adds a different edge close-out path.

### IN-02: cmt12-15 gateway endpoints have no PG smoke tests at the gateway level

**File:** `src/gateway.zig` (cmt12 handleBrainSearch, cmt13 handleBrainMemoryDetail, cmt14 source field, cmt15 handleBrainDocuments)

These four endpoints rely entirely on the underlying state_mgr methods being unit-tested. The JSON serialization paths (escape correctness, edge cases like NULL session_id, empty result sets, payload_json passthrough) are not directly covered. Recommend at least a smoke test per endpoint that exercises the serialization with a representative non-empty result set, especially for `/brain/memory/{key}` which has the most response surface (memory + source + edges + events).

For ship: **acceptable** because the underlying state_mgr methods are PG-smoke-tested individually and the serialization uses the same `appendJsonString` / `json_util` helpers proven correct elsewhere. Track for V1.6.1.

### IN-03: cmt15 `BrainDocument.summary_count` is `usize` parsed via `parseInt(usize, count_str, 10) catch 0`

**File:** `src/zaki_state.zig:3680`

`COUNT(*)` from PG returns BIGINT; if the count somehow exceeds `usize` capacity (unrealistic — would require >9 quintillion summaries) the parse silently falls back to 0. Same fallback applies if PG returns an unexpected non-numeric for any reason. **No bug realistically possible**; noted only because the silent-zero pattern repeats in several cmt15-introduced parses (`ts`, `count`). Low-risk since data path is server-controlled.

## Per-Commit Verdict

| Commit | Verdict | Notes |
|--------|---------|-------|
| 6f9d98c cmt7 | PASS | edges table + Gap 2 stable keys clean |
| b664ae4 cmt8 | PASS | cosine coref + EntityRow allocator hygiene clean |
| fad8e8a cmt9 | PASS | edge events use jsonString() correctly |
| ad328a9 cmt9.5 | PASS | session-end entity hash is byte-identical to cmt7 / cmt8 / cmt16 backfill (subject to WR-02 ASCII caveat) |
| c44c908 cmt10 | PASS | BFS frontier ownership traced, no double-free; per-iteration errdefer correct |
| 96e1a5c review fixes | PASS | WARN-1 (allocator) + WARN-2 (NUL) closed |
| fe89a98 cmt11 | WR-01 | demote audit payload JSON injection (non-fatal but loses audit row) |
| ddb8f4a cmt12 | PASS | overshoot bounded; isBrainVisibleKey filter consistent |
| b15f359 cmt13 | PASS | hygiene check up front; defer-cleanup chains correct on edges/events |
| 6475bb3 cmt14 | PASS | source attribution coexists with cmt15 query (different SET clauses) |
| 72f1efd cmt15 | PASS | `session_id IS NOT NULL` in both CTEs prevents NULL-join bug; surfaces hidden-prefix keys intentionally without cross-leak |
| 9d61aca cmt16 | PASS | created_at NOT NULL by schema; cascade-respecting; idempotent (subject to IN-01 + WR-02) |

## Cross-Commit Interactions Verified

1. **cmt16 backfill × cmt6 W-INT-01 cascade:** WHERE `valid_to IS NULL OR valid_to > now()` correctly excludes closed-out memories. Re-migration cannot resurrect closed edges.
2. **cmt15 documents × cmt14 source-attribution:** Both new SQL paths use independent SET-clause / SELECT-column sets on `memories`. No collision.
3. **cmt9.5 session-end × cmt7 extraction entity keys:** Byte-identical SHA-256-over-lower(object)[0..8 bytes hex] → `entity_<16hex>`. Confirmed equal under ASCII (subject to WR-02 caveat).
4. **cmt12 search overshoot × cmt6 MEMORIES_VALIDITY_FILTER:** `recallMemories` already applies the SQL-level validity filter; overshoot then post-filters via `isBrainVisibleKey`. Bounded by `limit ≤ 100 → fetch_limit ≤ 200`. No integer overflow.
5. **cmt11 demote × V1.7 immortality CASE-guard:** UPDATE removes `memory_type='core'` predicate; subsequent upserts pass through the V1.7 promote-to-core CASE without firing (current type is no longer `core`). Edits flow freely. Audit lands (modulo WR-01).
6. **cmt15 hygiene × cmt12/cmt13 hygiene:** Three endpoints share `BRAIN_HIDDEN_PREFIXES` source-of-truth in `memory/root.zig`. cmt15 intentionally bypasses for documents view; cmt12/cmt13 enforce. No silent leak via direct URL access.

---

**Ship recommendation:** **GO**. WR-01 and WR-02 are non-blocking — both fail safely (silent audit drop, near-zero-probability hash mismatch on non-ASCII uppercase). File a V1.6.1 ticket for both. Two INFO items are observability-only.

_Reviewed: 2026-05-02_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: deep_
