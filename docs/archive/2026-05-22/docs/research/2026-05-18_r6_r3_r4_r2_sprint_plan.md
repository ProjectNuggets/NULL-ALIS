# Next sprint plan — R6 + R3 + R4 + R2

**Date:** 2026-05-18
**Goal:** Lift the weakest LoCoMo cohort (Cat 3 temporal/inference, currently 56-77%) toward 80%+ while pushing Cat 2 multi-hop and Cat 4 open-domain above publishable baselines. Reach SOTA before burning the next full battery.

**Bench discipline:** 60-question Cat 3 focused slice after each lever lands. Full 10×199 battery ONLY when high-confidence SOTA is achievable — no half-confident burn.

---

## Weakest cohort identification

| Cat | This run V1.14.9 (clean conv-43) | Publishable 2026-05-09 | Pattern |
|---|---|---|---|
| Cat 1 single-hop | 87.1% | 91.2% | parity / minor |
| Cat 2 multi-hop | 92.3% | 93.6% | parity |
| **Cat 3 temporal/inference** | **64.3%** | **75.3%** | **−11pp consistent gap** |
| Cat 4 open-domain | 91.6% | 90.3% | at-or-above |

Cat 3 = 96 questions total across the 10 LoCoMo conversations:
- conv-26: 13, conv-30: 0, conv-41: 8, conv-42: 11, conv-43: 14, conv-44: 7, conv-47: 13, conv-48: 10, conv-49: 13, conv-50: 7

A 60-question focused slice picks ~6-7 Cat 3 questions per contributing conv. The whole 96-Q Cat 3 corpus runs in ~20-30 min — cheaper than the 4-12 hr full battery.

### Why Cat 3 fails (diagnosis from V1.14.9 conv-43 run)

5/5 Cat 3 failures clustered on **"world-knowledge-bridged inference"**: the answer requires combining what's in memory with general knowledge to NAME a specific brand/title/org:

- qa_8: "Which outdoor gear company likely signed John?" → GT "Under Armour". Agent: declined ("not mentioned"). The LoCoMo conversation mentioned John's outdoor gear deal but never named the brand. To answer, the model needs world knowledge that Under Armour is a major basketball outdoor-gear sponsor.
- qa_19: "Charity org John might want to work with?" → GT "Good Sports". Same pattern — needs knowledge that Good Sports partners with Nike/Gatorade/Under Armour.
- qa_66: "Star Wars book Tim might enjoy?" → GT "Star Wars: Jedi Apprentice". Needs Star Wars literature knowledge + Tim's reading patterns.

The F-A1 calibrated-honesty prompt is well-tuned for memory-only inference but DECLINES rather than propose-with-hedge on world-knowledge bridges.

---

## R6 — Web-search escalation (prompt-only, half day)

### Goal
Lift Cat 3 from ~64% to ~75-80% by letting the agent escalate to `web_search` after memory is exhausted AND the question requires naming a specific entity.

### Design

**Escalation order in F-A1 prompt (`src/agent/prompt.zig` ~line 846):**
```
1. memory_recall (semantic search over canonical memories)
2. brain_graph local_graph (entity-centric subgraph)
3. (NEW) If 1+2 returned nothing AND the question asks for a SPECIFIC
   NAMED ENTITY (brand, title, organization, person not in memory) →
   web_search ONCE with HEDGED reply prefix:
   "Based on common knowledge (not from our conversations): {answer}.
    I'd verify before relying on this."
4. Only after 1+2(+3) all empty → calibrated-honesty exit
```

**Required guards in the prompt:**
- ONE web_search per turn maximum (prompt instruction, not code-enforced)
- Reply MUST start with "Based on common knowledge (not from our conversations):" — forces disclosure
- web_search is for ENTITY NAMING, not for retrieving conversation facts. Reply must NOT use web_search results to override what memory says about the user.

### Implementation
- `src/agent/prompt.zig` lines 836-860 (F-A1 section): insert new step 3 between the current escalation and exit
- No code change. Pure prompt edit. ~30 LOC of prompt text.

### Risks + mitigations
| Risk | Mitigation |
|---|---|
| Agent hallucinates and passes off as web fact | Required "Based on common knowledge" disclosure prefix — clear caller signal |
| Bench fairness — LoCoMo expects memory-only | Disclosed clearly in bench results; LongMemEval explicitly allows web; if a publisher rejects, we publish 2 numbers (with/without R6) |
| Latency per call (2-5s) | One-per-turn cap; web_search only fires when memory exhausted (~5-10% of turns) |
| Provider cost (extra search API calls) | Brave Search API key already configured (`brave_api_key` in config); web_search costs cents per 1K queries |

### Expected lift
- **Cat 3: +10-15pp** (the targeted cohort)
- **Cat 2: +2-3pp** (some multi-hop questions benefit from world-knowledge bridging)
- **Cat 4: +2-3pp** (open-domain naming questions)
- Other cats: flat
- **Overall projected: +2-4pp**

### Acceptance gate
60-question Cat 3 slice → Cat 3 ≥ 75% (up from baseline ~64%). If not, revert + investigate.

---

## R3 — Graph traversal at retrieval (HippoRAG PPR, 1-2 days)

### Goal
Lift Cat 2 (multi-hop, 92.3%) and Cat 4 (open-domain, 91.6%) by surfacing multi-hop graph paths at query time. HippoRAG (NeurIPS 2024) reports +20% on multi-hop QA from Personalized PageRank over the KG at retrieval.

### Why it helps

Vector search matches messages by semantic similarity to the query. Multi-hop questions need a CHAIN of facts that no single message contains:
- "When did John move to Seattle?" — facts are spread across (1) "John signed Nike deal" and (2) "John had a game in Seattle on July 18 2023". Vector search of "John move Seattle" returns either, not both.
- PPR rooted at [John, Seattle] entities walks both directions in the graph, surfaces the linking edge directly.

### Algorithm (4 phases)

**Phase 1 — Seed entity extraction (~10-20ms)**
- Parse user query for entity mentions
- For each candidate entity word/phrase: query `memory_entities` table for matches (case-insensitive name match OR embedding cosine ≥ 0.85)
- Output: `[]EntityKey` (1-5 seeds typical)
- Edge cases: if 0 seeds matched, skip PPR entirely (fall back to vector-only)

**Phase 2 — Personalized PageRank over `memory_edges` (~50-100ms)**

Postgres recursive CTE rooted at seed entities, walking the edge graph:

```sql
WITH RECURSIVE ppr_walk AS (
  -- Iteration 0: seed entities at weight 1.0
  SELECT entity_key, 1.0::float AS weight, 0 AS depth
  FROM unnest($1::text[]) AS entity_key  -- seed entity keys

  UNION ALL

  -- Iterations 1..5: propagate weight along edges with 0.85 damping
  SELECT me.target_key, ppr_walk.weight * 0.85, ppr_walk.depth + 1
  FROM zaki_bot.memory_edges me
  JOIN ppr_walk ON me.source_key = ppr_walk.entity_key
  WHERE ppr_walk.depth < 5
    AND me.is_latest
    AND me.user_id = $2
)
SELECT
  entity_key,
  SUM(weight) AS pagerank_score,
  MIN(depth) AS min_hops
FROM ppr_walk
GROUP BY entity_key
ORDER BY pagerank_score DESC
LIMIT $3;  -- top-N, default 20
```

Damping factor 0.85 is PageRank standard. Depth limit 5 catches up-to-5-hop neighborhoods (sufficient per HippoRAG paper).

**Phase 3 — Hybrid rerank with vector results (~5ms)**

We already do vector retrieval. Merge:
- Vector path returns `[(memory_key, similarity_score)]`
- PPR path returns `[(entity_key, pagerank_score)]`
- For each PPR entity, look up its backing memory keys via a JOIN to `memory_edges` (the `fact` field is on the edge; the memory_keys for source/target events are in the edge's `episodes` array)
- Final score: `0.6 × normalize(vector_score) + 0.4 × normalize(pagerank_score)`
- Weights tunable; start with 0.6/0.4 per HippoRAG recommendation

**Phase 4 — Inject into memory_for_turn slot**

The existing `loadTurnMemorySlotOpts` already produces fenced content for the prompt. Just append top-K (K=10) PPR-derived facts to it. Format identical to current retrieval — no prompt change.

### Implementation breakdown

| Component | Files | LOC |
|---|---|---|
| `extractSeedEntities(query, mem_rt) []EntityKey` | new `src/memory/retrieval/graph_traversal.zig` | ~80 |
| `runPagerank(state_mgr, user_id, seeds, k)` — recursive CTE wrapper | same | ~100 |
| `mergeWithVector(ppr, vector)` — hybrid rerank | same | ~60 |
| `loadTurnMemorySlotOpts` integration | `src/agent/memory_loader.zig` | ~40 |
| Unit tests (synthetic graph, known PPR result) | `src/memory/retrieval/graph_traversal.zig` (tests) | ~120 |
| `graph_traversal.metrics` telemetry log (R3 symmetric to R1) | inline | ~20 |
| Feature flag `agent.r3_graph_traversal_enabled` (default true after bench validation) | `config_types.zig` | ~5 |
| **Total** | | **~425 LOC** |

### Validation
- Unit: synthetic 5-entity graph with known PPR weights → assert top-3 match expected
- Integration: spin up local gateway with R3 enabled, hit chat endpoint with a multi-hop question, log `graph_traversal.metrics`, verify >0 PPR results surfaced
- Bench: 60-Q Cat 2-focused slice (Cat 2 is the headline target for R3 — Cat 3 lifts from R6, Cat 2 lifts from R3)

### Risks + mitigations
| Risk | Mitigation |
|---|---|
| Cold-start latency on first PPR call after gateway startup (postgres CTE plan caching) | First call ~200ms; warm calls <100ms. Acceptable. |
| Recursive CTE depth = 5 not enough for very long causal chains | If P95 hops > 4 in production, bump to 7; postgres handles deeper just slower |
| Empty graph (new user) → PPR returns nothing → no regression | Yes — falls through to vector-only retrieval same as today |
| Entity NER quality on free-text queries | Start with case-insensitive substring match + embedding cosine. R3.5 future: tiny NER model |
| Feature flag default — what if R3 regresses some questions? | Default `false`; flip to `true` after Cat 2 ≥ 92% on focused bench |

### Expected lift
- **Cat 2: +5-8pp** (multi-hop is the headline target)
- **Cat 4: +3-5pp** (open-domain "what does X include" benefits from graph neighborhoods)
- **Cat 3: +1-2pp** (some Cat 3 questions need adjacent facts)
- **Overall projected: +3-5pp**

### Acceptance gate
Cat 2 ≥ 92% on focused slice (current ~92.3% in clean V1.14.9 conv-43; +5pp would put it at 97%+).

---

## R4 — BM25 + entity-overlap fusion (1 day)

### Goal
Lift retrieval quality across all cats by combining semantic vectors (existing) with BM25 keyword match + entity-overlap boost. Mem0's 2026 update report shows +3-5pp from this single change.

### Why it helps

- **BM25** catches exact-keyword matches that embeddings miss ("Vault" might not similarity-match "vault" in a different context; BM25 always hits)
- **Entity overlap boost** prioritizes memories that mention the SAME entities as the query — high-precision signal

### Algorithm

**Phase 1 — Schema**
```sql
ALTER TABLE memories ADD COLUMN content_tsv tsvector
  GENERATED ALWAYS AS (to_tsvector('english', content)) STORED;
CREATE INDEX idx_memories_content_tsv ON memories USING GIN(content_tsv);
```

**Phase 2 — BM25 search**
```sql
SELECT key,
       ts_rank_cd(content_tsv, query) AS bm25_score
FROM memories, plainto_tsquery('english', $1) query
WHERE user_id = $2 AND is_latest AND content_tsv @@ query
ORDER BY bm25_score DESC
LIMIT 20;
```

**Phase 3 — Entity-overlap scoring**
```sql
SELECT key,
       count(DISTINCT entity_key) AS overlap_count
FROM memory_entity_links
WHERE user_id = $1 AND entity_key = ANY($2::text[])
GROUP BY key
ORDER BY overlap_count DESC
LIMIT 20;
```
(Assumes `memory_entity_links` table exists; if not, derive from `memory_edges` source/target keys.)

**Phase 4 — Reciprocal Rank Fusion (RRF)**

RRF is the standard fusion algorithm for multi-signal retrieval. Each result list contributes:
```
score(doc) = sum over all lists L of: 1 / (k + rank_L(doc))
```
with `k=60` (standard). Higher score = higher final rank.

For us: vector list + bm25 list + entity-overlap list → fused list.

### Implementation breakdown

| Component | Files | LOC |
|---|---|---|
| Schema migration (tsvector column + GIN index) | `src/migrations/` new file | ~20 |
| `bm25Search(state_mgr, user_id, query, k)` | new `src/memory/retrieval/bm25.zig` | ~80 |
| `entityOverlapSearch(state_mgr, user_id, query_entities, k)` | new `src/memory/retrieval/entity_overlap.zig` | ~70 |
| `reciprocalRankFusion(vector, bm25, overlap)` | new `src/memory/retrieval/fusion.zig` | ~50 |
| Integration in `loadTurnMemorySlotOpts` | `src/agent/memory_loader.zig` | ~30 |
| Unit tests | inline | ~100 |
| `retrieval.fusion.metrics` telemetry | inline | ~20 |
| Feature flag `agent.r4_fusion_enabled` | `config_types.zig` | ~5 |
| **Total** | | **~375 LOC** |

### Risks + mitigations
| Risk | Mitigation |
|---|---|
| tsvector ALTER on large existing tables takes locks | `STORED` generated column lazy-fills on next write; can backfill async |
| BM25 misranks on conversational text (no document boundaries) | RRF lets vector + entity-overlap balance BM25's quirks |
| Adds 100ms latency per query | Three SQL queries can fire in parallel via Thread.Pool (already adopted in V1.14.9) |
| Feature flag default — what if RRF regresses? | Default `false`; flip after acceptance bench |

### Expected lift
- **Cat 1 (single-hop): +2-3pp** (exact name recall improves)
- **Cat 2 (multi-hop): +2pp** (entity overlap helps)
- **Cat 4 (open-domain): +3-5pp** (long-tail "what X does Y" queries)
- **Overall projected: +3-5pp**

### Acceptance gate
Cat 1 ≥ 90% AND Cat 4 ≥ 93% on focused slice.

---

## R2 — Bi-temporal polish (deferred, but planned)

### Honest verdict: NOT WORTH IT for LoCoMo

R2's CORE invalidation cascade is ALREADY shipping:
- 253 of 1,010 edges (25%) are cascade-closed via `invalid_at` + `is_latest=FALSE`
- 308 contradictions_applied events fired tonight
- Read queries default `WHERE is_latest` so stale facts don't surface

The REMAINING work:
1. `superseded_by_edge_id` column (temporal trail visualization)
2. `as_of TIMESTAMPTZ` time-travel queries (point-in-time graph snapshot)

**Neither lifts LoCoMo.** LoCoMo Cat 3 ("temporal/inference") tests events-at-times ("When did X go to Seattle?") which `valid_at` + `temporal_anchor_unix` already handle. It does NOT test knowledge-evolution-over-time which is what R2 polish enables.

**Where R2 polish DOES pay:**
- LongMemEval temporal cohort (real lift expected)
- "Show me what I told you yesterday" UX
- Audit / debugging
- Memory-rewind product feature

### Plan if/when we do it (~1-2 days)

**Phase 1 — Schema (30 min)**
```sql
ALTER TABLE memory_edges
  ADD COLUMN superseded_by_edge_id BIGINT NULL REFERENCES memory_edges(id);
CREATE INDEX idx_edges_superseded_by ON memory_edges(superseded_by_edge_id)
  WHERE superseded_by_edge_id IS NOT NULL;
```

**Phase 2 — Write path (~3 hr)**
- Modify `setMemoryInvalidation` signature to accept optional `superseded_by_edge_id`
- Update contradiction-judge call site in `extraction_persist.persistExtracted` to pass the new edge's id when invalidating an old one
- Thread the new edge id from the INSERT RETURNING clause

**Phase 3 — Read path (~4 hr)**
- New: `getEdgeAsOf(user_id, source, predicate, ts)` — query point-in-time
- New: `getEdgeHistory(edge_id)` — traverse supersession chain forward
- New: `getCurrentEdgeFor(loser_edge_id)` — traverse chain to current
- Tests covering: (a) single supersession, (b) chain of 3+ supersessions, (c) parallel histories for different predicates on same subject

**Effort:** 1-2 days. **LoCoMo lift: 0pp.** LongMemEval lift: TBD (significant per literature).

**Recommend:** defer to the R5 LongMemEval sprint. Bundle the polish with the bench harness that will actually measure it.

---

## Sprint sequencing — recommended order

### Day 1 — R6 web-search escalation (prompt-only, half day)
- Edit F-A1 prompt with the escalation step
- Smoke-test via hand-prompt: ask a Cat 3-style question, verify agent escalates web_search appropriately
- Run 60-Q Cat 3 focused bench
- ACCEPTANCE: Cat 3 ≥ 75%

### Day 2 — R4 BM25 fusion (faster than R3, lower risk)
- Schema migration + BM25 + RRF + entity-overlap fusion
- Run 60-Q Cat 1+4 focused bench
- ACCEPTANCE: Cat 1 ≥ 90% AND Cat 4 ≥ 93%

### Day 3-4 — R3 graph traversal (PPR)
- graph_traversal.zig + integration + tests + telemetry
- Run 60-Q Cat 2 focused bench (Cat 2 is the headline target)
- ACCEPTANCE: Cat 2 ≥ 92%

### Day 5 — Full 10×199 battery (only after Day 1-4 all green)
- **HIGH CONFIDENCE SOTA TARGET: 92-95% overall**
- This is the publishable headline

### Sprint+1 — R5 LongMemEval bench surface
- Bundle R2 polish here (supersession + as_of) — both deliver on LongMemEval
- Publish second headline

---

## Bench discipline (per Nova directive)

| Rule | Reason |
|---|---|
| 60-Q focused slice per lever | ~20-30 min per cycle vs 4-12 hr full battery; tight feedback loop |
| Don't run full battery until R6 + R4 + R3 all green on focused bench | No half-confident burn; SOTA confidence required |
| Each lever has explicit acceptance gate | Easy to know "did this work" without ambiguity |
| Disclose web-search usage if/when publishing | Honesty over headline-grade |
| Run gates BEFORE merging each lever | One regression at a time, easy to bisect |

## What to commit now (this plan + nothing else)

- This doc — `docs/research/2026-05-18_r6_r3_r4_r2_sprint_plan.md`
- No code changes pending Nova's hand-prompt testing first
- Branch state: `main`, 16 commits ahead of origin, NOT pushed

## What Nova does next

1. Start the local gateway (`./zig-out/bin/nullalis gateway --host 127.0.0.1 --port 3000` with env vars; or use `nullalis chat` for direct CLI agent)
2. Hand-prompt the agent — explore Cat 3-style questions and current memory behavior
3. Signal greenlight when ready for the V1.14.10 + R6 + R4 + R3 sprint to start
