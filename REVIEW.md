---
phase: v1.6-commits-2-3-4
reviewed: 2026-05-01
reviewer: Claude (self-review, same bar as gsd-code-reviewer)
scope_commits:
  - 4471cd0 V1.6 commit 2 — schema migration (14 cols + memory_entities + 7 indexes)
  - f043a00 V1.6 commit 3 — lemmatized BM25 + lazy backfill
  - 4d21bd8 V1.6 commit 4 — importance scoring (M1) wired into /brain/graph
files_reviewed:
  - src/zaki_state.zig (schema migration block + upsert paths + recallMemories)
  - src/memory/text_norm.zig (lemmatizeForBm25)
  - src/memory/importance.zig (computeImportance + recencyDecay + edgeCountNormalized)
  - src/gateway.zig (importance wiring in handleBrainGraph)
findings:
  critical: 0
  warning: 0
  info: 3
status: ship
---

# V1.6 Commits 2-4 Review — Pre-Commit-5 Gate

**Reviewed:** 2026-05-01
**Bar:** S-tier — same standard the FE agent's GSD review pass applied to Phase-1.

## Summary

Three commits laying the schema and recall foundation for atomic-fact extraction (which lands in commit 5). The structure is clean, test coverage is appropriate, and live verification on Nova's dev DB confirms the contract surfaces work.

**Critical: 0. Warning: 0. Info-level: 3 — all are documented trade-offs or forward-action notes, none blocking commit 5.**

Verdict: **ship.** Proceed to commit 5.

---

## What was reviewed

### 1. Schema migration (`4471cd0`)

- 14 ALTER ADD COLUMN IF NOT EXISTS — all idempotent, instant metadata-only on populated tables
- 5 new partial indexes (subject, object_key, parent, is_latest, lemmatized GIN)
- New `memory_entities` table with VECTOR(1024) hardcoded to match production e5_1024 model
- 2 new entity-table indexes (user, ivfflat vector)
- PG smoke test verifies all 16 columns + all 7 indexes + memory_entities round-trip

**Audit:**
- ✅ All migrations are online-safe (no NOT NULL on unpopulated columns)
- ✅ GIN index on `to_tsvector('simple', lemmatized)` matches the query expression exactly (so Postgres uses the index)
- ✅ memory_entities FK to users.user_id with ON DELETE CASCADE
- ✅ Composite uniqueness on (user_id, name_lower) for cosine-coreference dedup
- ✅ VECTOR(1024) trade-off documented in source comment (not just commit message)

### 2. Lemmatized BM25 (`f043a00`)

- New `src/memory/text_norm.zig::lemmatizeForBm25` (~115 lines + 6 tests)
- Wired into `upsertMemory` and `upsertMemoryWithMetadata` at write time
- Lazy backfill SQL (`UPDATE ... lower(content) WHERE lemmatized IS NULL`) runs on every migrate; idempotent
- `recallMemories` SQL switched to 3-signal score: key ILIKE (2.0) + lemmatized BM25 (1.0) + content ILIKE (0.5)

**Audit:**
- ✅ Memory ownership: `lemmatize → ` returns owned slice, caller frees via defer. Cross-checked at both call sites.
- ✅ Empty-query guard via `length($N) > 0` short-circuits BOTH the SELECT score column AND the WHERE clause
- ✅ Parameter numbering correct in both branches (with-session uses $5; no-session uses $4 for lemma_q since session_id absent)
- ✅ Backward compat preserved — substring queries ("pista" → "pistachios") still work via content ILIKE fallback (postgres_test passes)
- ✅ UTF-8 byte-perfect Arabic preservation tested
- ✅ Negation words ("not", "no") preserved (not in stopword list — semantic-meaningful)

### 3. Importance scoring (`4d21bd8`)

- New `src/memory/importance.zig` pure-function module (~100 lines + 4 tests)
- Formula: `0.5 * recency_decay(half_life=30d) + 0.5 * edge_count_normalized(scale=8)`
- /brain/graph computes per-node importance after edges build, includes in node JSON
- Live verification: 10-node sample on Nova's user_id=1 returns importance values 0.45-0.60

**Audit:**
- ✅ Formula bounded [0, 1] per tests
- ✅ Recency decay handles future timestamps (clock-skew tolerance)
- ✅ Edge-count saturation prevents hubs from saturating to 1.0 too fast (n/(n+8))
- ✅ degree HashMap uses borrowed n.key strings — keys persist for handler duration
- ✅ Recomputed per request — formula can evolve without backfill

---

## Info-level findings (none blocking)

### IN-1: degree HashMap getOrPut OOM swallowed via `catch continue`

**File:** `src/gateway.zig` (handleBrainGraph importance computation)

```zig
const a_entry = degree.getOrPut(allocator, e.source) catch continue;
```

Allocator failure during degree counting silently undercounts the node's degree. Practical risk is near-zero (we just allocated the node array bigger than this hashmap), but for hardening parity with V1.5.1's "no silent failures on memory write paths," consider a `log.warn` on getOrPut failures in handler paths.

**Severity:** info. Not a memory write path; brain/graph rendering with one slightly-undersized degree count is harmless.

### IN-2: Stopword list is English-only

**File:** `src/memory/text_norm.zig::STOPWORDS`

42 common English stopwords. Arabic, Chinese, French, etc. content keeps all words. Trade-off:
- More recall on non-English content (every word indexed)
- Less precision (high-frequency non-English stopwords pollute results)

For Nova's bilingual usage (en + ar), this is acceptable today — Postgres's `to_tsvector('simple', ...)` does no language-specific stopword removal anyway. V1.7 candidate: language-detected stopword sets if measured value supports it.

**Severity:** info. Documented trade-off; recall over precision is the right V1 default.

### IN-3: importance edge-degree counter doesn't yet count typed atomic-fact edges

**File:** `src/gateway.zig` (handleBrainGraph importance computation)

The degree counter iterates `session_edges`, `semantic_edges`, `ref_edges` — the three edge types that exist as of V1.6 commit 4. V1.6 commit 5 will introduce typed atomic-fact edges (subject/predicate/object_key relations). Without updating the degree counter, those typed edges won't contribute to importance scores → memories connected only via typed edges would have lower importance than they should.

**Action item for commit 5:** when typed-edge surface is added to /brain/graph, also extend the degree counter in the same edit. Don't ship commit 5 without this.

**Severity:** info → forward-action. Not a current bug; only matters once commit 5 introduces the edge type.

---

## What stays untouched (still at parity)

- V1.5.1 hygiene filter (BRAIN_USER_KEY_FILTER + BRAIN_HIDDEN_PREFIXES) — drift-proof comptime derivation continues working
- V1.5.5 compaction Pass C prompt — substrate gates still pass (commit 5 will extend it carefully)
- Silent-catch fixes (S4.1-S4.5) — verified no regressions
- bumpMemoryAccess + access_count — left intact (importance formula deliberately doesn't use access_count yet per IN-2 in importance.zig)

---

## Acceptance gates

- All commits build clean (Debug + ReleaseFast verified per commit)
- PG smoke tests added for new SQL surfaces (schema migration test + 6 lemmatize unit tests + 4 importance unit tests)
- Live verification via curl on user_id=1 dev DB confirms the contract surfaces emit expected fields
- 5701/5711 tests pass; +0 net failures introduced (the 1 exit-1 is pre-existing `postgres_pool_releases_on_exec_error` logged-errors test, unchanged since baseline)

---

## Verdict

**Ship. Proceed to V1.6 commit 5** — extend compaction Pass C prompt to emit JSON `extracted_memories[]` alongside prose, with the V1.5.5 corpus re-run as the validation gate (substrate fidelity must hold post-prompt-change).

Acknowledged forward-action: when commit 5 adds typed atomic-fact edges to /brain/graph, **the importance degree counter in src/gateway.zig must be extended in the same commit** (per IN-3).

— signed by the backend, V1.6 commits 2-4 self-review, 2026-05-01.
