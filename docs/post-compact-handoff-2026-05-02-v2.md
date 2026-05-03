# Post-Compaction Handoff (2026-05-02 v2 — V1.7 train started)

**Purpose:** survive a compact mid-V1.7. Self-contained context for post-compact me.

## State at compaction

- **Main HEAD:** `3991c79` (V1.7a-5b — surface archived memories on /brain/memory drilldown, closes user-visible 404 noise + advances spec §4.9 valid_history conformance)
- **112+ commits ahead** of original V1.5 ship-ready handoff (`4d9e16f`)
- **V1.5 status:** SHIP-READY (deploy date deprioritized per Nova: ship when correct, not by date)
- **V1.5.5 status:** GREEN — substrate validated (precision 0.92)
- **V1.6 status:** SHIP-COMPLETE — 16/16 commits + cmt9.5 + ship-gate review fixes (`d50f5d1`); V1.6.1 polish landed in V1.7a-4 (cmt9.9 + review fixes a6f54b3 + parallel-review fixes 3524bf9 + all-review-findings-closed 02d40b1)
- **V1.7 status:** 5 of 12 items shipped + V1.7a-5b drilldown bugfix; **sprint reshaped 2026-05-03 per Obsidian-parity research** — V1.7a expanded from 6 → 9 items (added local-graph, orphans, filter-extensions; promoted communities from V1.7b); V1.7b demoted to 4 depth/quality items. **See `docs/v1.7-brain-parity-sprint.md` for the full reshape rationale.**
- **Branch:** `main`
- **Tests:** 5955/5965 PG passed (+35 vs V1.5 baseline; 10 skipped). Only pre-existing `postgres_pool_releases_on_exec_error` baseline failure.

## Trust mandate (do not forget)

Nova's directive: **"this is your son's brain — give it justice."**
1. Ship when correct, not by date
2. Test the foundation before extending it
3. Have a fallback (V1.5.5 chose Path A; V1.6 D2 chose compaction-derived)
4. Wow the user
5. Swiss-watch discipline — atomic commits, P-file bumps on touch, PG smoke tests precede merge
6. **No loose ends** — close partial gaps in V1.7, don't defer to V1.8

Nova said this exact run: *"do we want to close gaps and loose ends? to stay on our Swiss watch discipline? or are they going to be closed fully in 1.7?"* — answer was YES, close everything in V1.7.

Nova also said: *"the parallel agent working on memory has stopped working, all remaining is in our hands"* — V1.7's 8 spec seams are now my territory in addition to my 4 closure items.

## V1.7 PLAN — 12 items in two trains (5-7 days V1.7a + 6-8 days V1.7b)

### V1.7a — foundational ship (must-haves; ships when complete)

| # | Item | Status | Source |
|---|------|--------|--------|
| 1 | Full Gap 3 closure (cmt9.6) | ✅ SHIPPED `032086d` | My closure |
| 2 | graph_expand → memory_recall consumer wire (cmt9.7) | ✅ SHIPPED `df030d3` (+ review fixes `454934e`) | My closure |
| 3 | Brain graph perf swap (JSONB → findEdgesByKeys) (cmt9.8) | ✅ SHIPPED `8171166` (+ review fixes `ab93bd4`: swapped initial listEdgesForUser → findEdgesByKeys for visible-node-scoped scan; renamed cap constant; added sort-tiebreak test; cmt16 backfill docs) | My closure |
| 4 | V1.6.1 polish (WR-02 Unicode lowercase, SE-V17-01 list-scope tool desc, SE-V17-02 pending_conflicts text) (cmt9.9) | ✅ SHIPPED `d8715da` + review fixes `a6f54b3` (Unicode-aware `lowerForEntityKey` covering ASCII + Latin-1 Supplement + Cyrillic + Greek; SQL backfill aligned to PG `lower()`; tool desc + marker text rewrites; 14 unit tests + Zig/SQL convergence PG smoke test) | My closure (V1.6 backlog) |
| 5 | Spec seam 3: `link_type` rich wiring (compose_memory + agent prompt) (cmt9.10) | ✅ SHIPPED `8cd7d35` + drift guards `df48be7` (LinkType enum + extraction predicate mapping + compose_memory optional arg + prompt vocabulary block + brain/memory/{key} top-level field + idempotent column backfill; 7 unit + 1 PG-smoke + 1 drift-guard test) | Spec §5 |
| 6 | Spec seam 8: `/brain/diff?date=` endpoint | ⏳ NEXT | Spec §5 |

### V1.7b — depth/quality (spec completion; ships after V1.7a)

| # | Item | Source |
|---|------|--------|
| 7 | Spec seam 1: per-edge `fact_embedding` plane (`memory_facts_vectors` table) | Spec §5 |
| 8 | Spec seam 2: LLM-judge entity dedupe (0.85 < cosine < 0.95 ambiguous band) | Spec §5 |
| 9 | Spec seam 4: profile materialization (`profiles` table, static vs dynamic) | Spec §5 |
| 10 | Spec seam 5: `/api/v1/users/:id/profile` single-call endpoint | Spec §5 |
| 11 | Spec seam 6: communities (label-propagation + LLM pairwise summary, nightly cron) | Spec §5 |
| 12 | Spec seam 7: `community_id` surfacing on `/brain/graph` | Spec §5 |

## V1.7a-2 (NEXT) — graph_expand → memory_recall consumer

**Goal:** Make agent context become a graph neighborhood instead of a flat top-N list. Heart of "earns the name graphmemory."

**Files to touch:**
- `src/zaki_state.zig` — extend `recallMemories` OR add `recallMemoriesAsGraph(allocator, user_id, query, max_seeds, max_hops, max_nodes_per_hop) → []ScoredNode + []TypedEdge`
- `src/agent/memory_loader.zig::loadContextWithRuntimeDetailed` (or `enrichMessageWithRuntimeDetailed`) — format the neighborhood for the system prompt
- `src/agent/graph_expand.zig` — already shipped (V1.6 cmt10); just consume it
- Plumb real `created_at` for recency scoring (cmt10 INFO closure — was using now-as-now placeholder)

**Approach:**
1. New method `recallMemoriesAsGraph` — runs existing `recallMemories` for top-K seeds (e.g. K=5), passes seed keys to `graph_expand.expandFromSeeds(max_hops=1, max_nodes=20)`, returns the neighborhood
2. Update memory_loader to format the neighborhood:
   ```
   <memory_for_turn>
   <fact key="user_helix" score="0.92">User uses Helix as primary editor</fact>
     <related predicate="REPLACES">User used to use NeoVim (closed-out 2026-04-15)</related>
     <related predicate="USED_FOR">Helix is used for V1.6 brain page polish</related>
   <fact key="...">...</fact>
   </memory_for_turn>
   ```
3. Make graph-expand mode CONFIGURABLE: `max_hops=0` = legacy flat; `=1` = immediate neighbors; `=2` = full graphmemory mode. Default `=1` for ship-safe rollout.
4. Plumb real `created_at` via getMemory or extending recallMemories to return it
5. PG smoke test: insert 3-fact chain via persistExtracted, recallMemoriesAsGraph for query, assert neighborhood + scores

**Estimated:** 1-1.5 days

**Risk:** larger context per turn = higher cost + latency. Mitigation: configurable expansion + V1.5.5 corpus re-run to confirm token budget doesn't blow.

## Branch state — full commit ledger since V1.6 ship-complete

```
032086d  V1.7 cmt9.6 — full Gap 3 closure (memory_store + session-end through persistExtracted)
d50f5d1  V1.6 ship-gate review fixes (WR-01 audit JSON, WR-02 lowercase ASCII alignment)
9d61aca  V1.6 cmt16 (FINAL) — one-shot backfill of memory_edges from JSONB triples
72f1efd  V1.6 cmt15 — /brain/documents adapter (two-tier supermemory)
6475bb3  V1.6 cmt14 (M4) — source attribution writers + drilldown surface
b15f359  V1.6 cmt13 (M3) — /brain/memory/{key} drilldown endpoint
ddb8f4a  V1.6 cmt12 (M2) — /brain/search?q= endpoint
fe89a98  V1.6 cmt11 — memory_archive + memory_demote agent tools + demoteMemoryFromCore
96e1a5c  V1.6 cmt7-10 review fixes (allocator + NUL safety)
c44c908  V1.6 cmt10 — graph-expand retrieval primitive
ad328a9  V1.6 cmt9.5 — Gap 3 partial (session-end facts emit edges to graph)
fad8e8a  V1.6 cmt9 — edge mutation events
b664ae4  V1.6 cmt8 — entity coreference cosine ≥0.95
6f9d98c  V1.6 cmt7 — memory_edges + Gap 2 stable keys
053fc3c  V1.6 cmt6 W-INT-01 fix (resurrect-on-upsert + promoteToCore validity guard)
8544ec1  V1.6 cmt6 PG smoke tests fixed user_id 2 seeded fixture
ed97644  V1.6 cmt6 — Graphiti contradiction judge + bi-temporal close-out
92345cc  docs(handoff): pre-compaction handoff 2026-05-02 — V1.6 cmt5 complete
4d9e16f  ← original V1.5 ship-ready handoff baseline
```

## V1.7 cmt9.6 (just shipped) — what landed

Closes memory pipeline handoff Gap 3 substantially:
- `memory_loader.isExtractedFactKey` — extracted_<hash> rows promote to first-class continuity
- `memory_store` tool — optional subject/predicate/object params; routes through persistExtracted with coref + edge insert + source attribution
- `commands.zig:1313+` durable_fact loop — when fact.hasTriple(): inline durable_fact + edge emission (cmt9.5) + persistExtracted call (cmt9.6 new)
- New `bindMemoryStoreUnifiedContext` binder
- Gateway wires coref via `mem_rt._embedding_provider`

**Deferred (TODO V1.7 follow-up):**
- Judge LLM provider plumb to memory_store + commands.zig session-end. Requires `provider_bundle.primaryModelName()` accessor (doesn't exist). Without judge: triple-write paths get coref + edge + source attribution; just no contradiction detection. NOT a regression vs V1.6 cmt5b.3 baseline — those paths had no judging at all.
- Single-write collapse for session-end (currently durable_fact + extracted_<hash> coexist when content novel). /learn commands need migration to extracted_* keys before durable_fact can retire.

## Critical context (do not forget)

1. **V1.6 SHIP-CLEAN.** `d50f5d1` closed the V1.6 ship-gate WARNs. All 16 V1.6 commits + cmt9.5 ship-ready. V1.7 builds on top.

2. **V1.7 spec lives at** `docs/v1.6-v1.7-spec.md` §5 — 8 seams listed. Parallel agent shipped 3 PROMOTION-RELATED items (episodes, Tier-3, conflict surfacing in `58e064b`/`b4b77d1`/`4e41c2a`) but those AREN'T in the spec's 8 — they're foundation. The 8 spec seams are still all open.

3. **Memory pipeline handoff** lives in `docs/handoff-from-memory-agent.md` (or in conversation history — Nova shared it inline). Three gaps + one bonus suggestion. Status:
   - Gap 1 (memory_edges table) — ✅ DONE V1.6 cmt7
   - Gap 2 (stable node identity) — ✅ DONE V1.6 cmt7
   - Gap 3 (judge on all write paths) — ✅ SUBSTANTIALLY DONE V1.7 cmt9.6 (judge LLM plumb deferred)
   - Bonus: edge mutation events — ✅ DONE V1.6 cmt9

4. **V1.5.5 substrate corpus** at `tests/compaction_corpus/`. Substrate gates: precision ≥0.90, recall ≥0.85. **Re-run if commits change Pass C compaction prompt OR JSON tail format.** V1.7a-2 graph-expand consumer SHOULD re-run if it changes context format meaningfully (extra context bytes per turn could affect token-budget downstream).
   ```bash
   NULLALIS_POSTGRES_TEST_URL=postgresql://zaki:zaki@127.0.0.1:5433/zaki \
     python3 tests/compaction_corpus/score.py
   ```

5. **Provider config** (`~/.nullalis/config.json`): Together AI primary (Kimi K2.5), Groq sidecar, OpenRouter fallback, Ollama local.

6. **Discipline reminders:**
   - Per-commit P-file updates (`internals/P*.md` sha bumps)
   - Atomic commits per item
   - `zig build test -Dengines=all` green before every commit
   - `zig build -Doptimize=ReleaseFast -Dengines=all` for production build
   - PG smoke tests precede merge
   - REVIEW.md every 3-4 commits — same standard as gsd-code-reviewer
   - **No loose ends** — close partial gaps in V1.7

7. **Critical knowledge that's easy to forget:**
   - `categoryToMemoryType(.daily)` returns `"daily"` not `"episodic"`. The MemoryCategory union has: core / daily / conversation / custom. NOT episodic.
   - PG tests need `PGOPTIONS="-c client_min_messages=WARNING"` to avoid NOTICE-as-failure.
   - PG tests need user_id 2 (not 99/77) — fixture seeded.
   - V1.7's `pending_conflicts` is intentionally NOT in BRAIN_HIDDEN_EXACT_KEYS for the agent surface — memory_loader injects it via `isSemanticContinuityKey` (V1.7 Item 3 intent). Hidden from /brain/* via the regular hide list.
   - Tool count assertions in `src/tools/root.zig` (currently 36/40) bump every time a new tool gets added to allTools.

## Files I most often touch

- `src/zaki_state.zig` (~7300 LoC) — schema, all writers/readers, PG smoke tests live at the bottom
- `src/agent/extraction_persist.zig` — atomic-fact extraction pipeline, judge wiring
- `src/agent/graph_expand.zig` — BFS expansion primitive
- `src/agent/memory_loader.zig` — context injection, continuity bucket logic
- `src/agent/commands.zig` — session-end summarizer + durable_fact loop
- `src/memory/root.zig` — types (MemoryEntry, TypedEdge, EntityRow, MemoryEventRow, MemorySource, BrainDocument)
- `src/gateway.zig` — brain endpoints, TenantRuntime.init wiring
- `src/tools/root.zig` — tool registration + tenant-context binders

## Reference docs

1. `docs/v1.6-v1.7-spec.md` — V1.5.5 + V1.6 + V1.7 work order spec
2. `docs/post-compact-handoff-2026-05-02.md` — prior handoff (V1.5.5 → V1.6 cmt5)
3. `REVIEW.md` — V1.6 cmt5a/5b review + V1.7 parallel agent + nullclaw cherry-pick
4. `REVIEW2.md` — integration review (W-INT-01 zombie row + I-INT-02 index)
5. `REVIEW3.md` — V1.6 cmt7-10 review (WARN fixes in 96e1a5c)
6. `REVIEW4.md` — V1.6 ship-gate review (WARN fixes in d50f5d1)
7. **This doc** — V1.7 mid-train handoff
8. References at `/Users/nova/Desktop/nullalis-research/`: `mem0_spec.md`, `graphiti_spec.md`, `supermemory_spec.md`, `nullalis_audit.md`

## Pending on Nova (operational)

1. V1.5/V1.6 deploy — ship when V1.7a + V1.7b complete and S-tier
2. Sentry DSN — post-deploy
3. D-phase staging tests — post-deploy
4. Channel awareness — V1.8 backlog
5. **NEW (V1.8 widening):** Nova's hint — *"durable facts and daily journal can be good source of truth"* — V1.8 widens brain data sources beyond compaction. NOT in V1.7 scope.
6. **NEW:** Nova doing OAuth work in zaki-prod (TypeScript BFF) with another agent. Doesn't touch nullalis surface (already trusts X-User-Id headers from upstream auth). Don't worry about it.

## Sign-off

V1.7 just started, 1 of 12 items shipped, all foundations solid. cmt9.6 closed Gap 3 substantially (judge plumb is the only deferred piece, tracked). Foundation S-tier; V1.7a-2 (graph_expand → memory_recall consumer) is the heart of "earns the name graphmemory." Ready to continue post-compact.

---

*Written 2026-05-02 mid-V1.7. Update inline as items close.*
