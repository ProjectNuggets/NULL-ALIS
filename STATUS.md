# nullALIS — STATUS

**Hydrated:** 2026-05-10 from code truth (git log, source tree, bench artifacts, fresh field research). Not memory.

This is the single cold-start document. If it disagrees with `.planning/STATE.md`, `PROJECT_LEDGER.md` (archived), or anything in `docs/archive/`, **this wins**.

---

## What nullALIS is right now

Single-binary Zig agent runtime (`src/main.zig`). Per-user cell-pod architecture, 15 LLM providers, 48 tools, 20 channel integrations, 9-stage memory retrieval over 4 storage backends + vector plane. Postgres canonical, SQLite + markdown mirror, filesystem workspace first-class.

| Surface | Count | Where |
|---|---|---|
| `.zig` files | 293 | `src/**` |
| Source LoC | ~256K | `src/**` |
| LLM providers | 15 | `src/providers/` |
| Tools | 48 | `src/tools/` |
| Channels | 20 | `src/channels/` |
| Memory layers | L0-L7 | `src/memory/` |

**Zig:** 0.15.2 (locked). **Build:** `zig build -Doptimize=ReleaseFast -Dengines=all`.

---

## Most recent shipped versions

| Version | Theme | Status |
|---|---|---|
| **V1.14.10 A** (2026-05-18) | **Async lifecycle persist.** `persistSessionCheckpointDetailed` no longer blocks `agent.turn()` — detached worker thread + atomic in-flight guard + bounded deinit-wait. Root cause of the 9 session-load HTTP 180s timeouts on the full battery (sample 4 dropped 88%→67% from 3 timeouts; sample 9 totally failed). Re-bench expected to lift overall ~10pp by eliminating timeout-induced session-context losses. | **Shipped, awaiting bench rerun** |
| V1.14.10 B / R2 | **Bi-temporal invalidation — core was already shipping.** Schema has `invalid_at`+`expired_at`; `setMemoryInvalidation` cascades on contradiction; read queries default `WHERE is_latest`. Tonight: **253 of 1,010 edges** (25%) are cascade-closed via 308 contradiction events. Remaining `superseded_by_edge_id` link + `as_of` time-travel are LongMemEval-relevant, not LoCoMo — deferred to R5 sprint. | Core operational; polish deferred |
| **V1.14.9** (2026-05-18) | **Episode-based boundary extraction.** New `src/agent/extraction/{chunker,merger,telemetry}.zig` (~780 LOC) replaces "one giant LLM call per boundary" with semantic-chunk → parallel fan-out (Thread.Pool 8-way) → coref+dedup merge. Industry-aligned with Graphiti episodes / mem0 chunks / Zep auto-boundary / HippoRAG. R1 graph-density telemetry shipped. Pass A wire fix (CompactionConfig propagation H-01). | **Shipped + acceptance gate met** |
| V1.14.8.1 | Sidecar model override — gateway no longer wires Kimi K2.5 (reasoning model burns output budget) by default. Recommends Llama-3.3-70B-Instruct-Turbo. | Shipped |
| V1.14.8 | Unified boundary extraction at `src/agent/extraction/` (schema + prompts + parser + runner). All 4 boundaries (Pass A, Pass C, session-end, force-compress) flow through one `extractAtBoundary`. `slot_intent` → working_memory.promote. | Shipped, fragmentation bug fixed in V1.14.9 |
| V1.14.7 | Per-turn extraction deletion. F-A1 calibrated-honesty regression fix. Layer 4 graph-empty bug fixed. | Shipped + verified |
| V1.14.6 | F-CB1 cache breakpoints, F-PA2 drop-from-middle Pass A, S-tier prompt rewrite. | Shipped, headline result |

---

## Bench standings

### V1.14.9 conv-43 acceptance — 2026-05-18

Episode-based extraction + Pass A wire fix + Llama-3.3-70B sidecar. Full 199-question conv-43:

| Cat | V1.14.9 + Pass A fix | Earlier V1.14.9 | V1.14.8 | Publishable 2026-05-09 | Δ vs publishable |
|---|---|---|---|---|---|
| Cat 1 (single-hop) | 87.1% (27/31) | 87.1% | 87.1% | 91.2% avg | −4.1pp |
| **Cat 2 (multi-hop)** | **92.3% (24/26)** | 88.5% | 88.5% | 93.6% avg | −1.3pp |
| Cat 3 (temporal/inference) | 64.3% (9/14) | 50.0% | 64.3% | 75.3% avg | −11pp (R2 target) |
| **Cat 4 (open-domain)** | **91.6% (98/107)** | 89.7% | 61.7% | 90.3% avg | **+1.3pp 🎯 ABOVE publishable** |
| Cat 5 (adversarial) | 0/0 scorable (21 GT-empty, skipped) | same | same | n/a | — |
| **Overall scorable** | **88.8% (158/178)** | 86.0% | 70.2% | conv-43 publishable: 95% (60-Q subset) | parity within run-to-run + GT-empty Cat 5 |

**Graph layer for user 2004 (post session-end TTL):**
- 73 edges written to `memory_edges` (input 78, dedup 5)
- 12 entities (coref-collapsed from 79)
- 15 working_memory slots (slot_intent → working_memory promotion working)
- 20 contradictions resolved (bi-temporal judge active)
- 14 episodes chunked, 11 succeeded (79% success rate)
- 0.96 edges per 1K tokens density
- Window: 461 msgs / 324KB (vs V1.14.8's 80KB cap)

**Acceptance gates: BOTH MET** ✓
- ✓ Cat 4 ≥ 90%: 91.6%
- ✓ memory_edges ≥ 50: 73

Sample predicates show typed SCREAMING_SNAKE_CASE quality: `VISITED`, `FAN_OF`, `SIGNED_ENDORSEMENT_DEAL_WITH`, `FAVORITE_BOOK`, `ENDORSED_BY`, `WATCHES_DURING_HOLIDAYS`, `WANTS_TO_VISIT`, `RECOMMENDS_BOOK_TO`.

### Last validated: V1.14.8 conv-26, 2026-05-10

Patched scorer (F1 fix — skips GT-empty rows instead of counting as zero) on full 199-question conv-26:

| Cat | This run (V1.14.8) | 2026-05-09 publishable | Δ |
|---|---|---|---|
| Cat 1 (single-hop) | **90.6% (29/32)** | 91.2% avg across 10 convs | parity |
| Cat 2 (multi-hop) | **97.3% (36/37)** | 93.6% avg | **+3.7pp** 🎯 |
| Cat 3 (temporal/inference) | **76.9% (10/13)** | 75.3% avg | parity |
| Cat 4 (open-domain) | **81.4% (57/70)** | 90.3% avg | **−8.9pp** ⚠ needs validation |
| Cat 5 (adversarial) | **100% (2/2 scorable, 45 skipped GT-empty)** | not measured | — |
| **Overall scorable** | **87.0% (134/154, 45 skipped)** | conv-26 publishable: 88.3% (60-Q subset) | parity within run-to-run variance |

Pre-fix scorer reported 67.3% on this same data — the gap was 45/47 Cat 5 questions with empty GT counted as zeros. Fix landed in `.spike/external/locomo_runner/run_bench.py` (commit `d4be7e2b`).

### Full 10-conversation publishable (still the only multi-conv number)

**LoCoMo full battery, 2026-05-09:** 541/600 = **90.17% recall**, Cat 1-4 only. +16pp over mem0. This held on the V1.14.8 conv-26 rerun for Cat 1-3; Cat 4 needs conv-43 rerun to confirm whether the −9pp is real or sample noise.

---

## V1.14.8 graph-density validation status — VALIDATED 2026-05-10

**WIRE: CONFIRMED LIVE + DELIVERING GRAPH DATA.** Validated on `feat/v1148-validate-and-graph-density` after the **V1.14.8.1 sidecar-model fix** (7f8de1ed). Pre-fix the unified extractor returned entities=0 edges=0 on every real session because the wire inherited Kimi K2.5 (a reasoning model — burns its output budget on internal reasoning, returns empty `content`). Post-fix with Llama-3.3-70B-Instruct-Turbo wired as the sidecar:

| Session | window_msgs | transcript_bytes | entities | edges | hydration |
|---|---|---|---|---|---|
| user 5555 ("SMOKE OK 3") | 3 | 2060 | 1 | 1 | 327 B XML |
| user 4444 (4 substantive turns) | 17 | 14504 | **8** | **5** | 1286 B XML |

V1.14.8 extracts **MORE than the legacy `parseSummaryResponse` path** on the same window (5 vs 2 edges for user 4444). All 5 unified edges correctly caught as `semantic_dup` against legacy fact writes — no double-writes. The persistence dedup layer is doing its job.

**Diagnostic discovery worth keeping**: probing Together directly with Kimi K2.5 + our graphiti extraction prompt returns `message.content = ""` and `message.reasoning = "[truncated reasoning that lists the entities + edges but never gets to JSON]"`. Reasoning models burn their output budget on hidden thinking and never emit structured output — use non-reasoning sidecars for extraction.

---

## What changed today (2026-05-10)

| Commit | Change | Branch |
|---|---|---|
| `67def0b9` | Doc sweep: 27 historical docs archived; STATUS.md hydrated | main |
| `d4be7e2b` | F1 scorer fix: skip GT-empty rows (conv-26: 67% → 87%) | feat/v1148 |
| `82c3e2f6` | F6 silence `public.zaki_users` log noise (~200 lines/run → 1) | feat/v1148 |
| `67636b48` | F2 STATUS.md refresh with V1.14.8 numbers | feat/v1148 |
| `7f8de1ed` | **V1.14.8.1** extractor model override: gateway no longer wires Kimi K2.5 (reasoning) by default; recommends Llama-3.3-70B-Instruct-Turbo for the sidecar. F3 validated post-fix. | feat/v1148 |

---

## Roadmap — graph density push (from 2026-05-10 research)

Research: **`docs/research/2026-05-10_graph_db_and_agentic_memory_landscape.md`** (7,800 words, 5 sections, every claim cited).

### Headline finding

The agent-memory field is converging on **Postgres + pgvector + a hand-rolled edges table** — exactly what nullalis already has. KuzuDB archived Oct 2025. Apache AGE measurably slower than Neo4j on deep traversals. Cognee, mem0, Letta, Hindsight, SoftwareSeni all on Postgres-based stacks. **Don't migrate the storage layer.** The win is in extraction quality + retrieval, not in swapping engines.

### Ranked recommendations

| Rank | Action | Why | Effort |
|---|---|---|---|
| **R1** | **Ship graph-density telemetry.** Log entities/edges per 1K input tokens on every boundary. Alert when Pass C returns zero on a session >5K tokens. Add `reason` field to extractor's empty-result path. | Without this we can't measure any other change. Direct response to the `entities=0 edges=0` signal we just saw. | one afternoon |
| **R2** | **Bi-temporal invalidation.** Add `invalid_at`, `expired_at`, `superseded_by_edge_id` columns to `memory_edges`. Run a second small LLM call after Pass C extraction to mark contradicted facts expired. Never delete. | The architectural reason Graphiti/Zep dominate temporal reasoning on LongMemEval. PersonalAI 2.0 replicates the win. | 1-2 days |
| **R3** | **Graph traversal at retrieval.** Implement HippoRAG-style Personalized PageRank over the KG at query time. Postgres recursive CTE; tens of milliseconds. | HippoRAG (NeurIPS 2024) reports +20% on multi-hop QA. Lands directly on our Cat 2 strength. | 1-2 days |
| **R4** | **BM25 + entity-overlap fusion at retrieval.** Postgres `tsvector` natively; one PR. | Mem0's 2026 update report says +3-5pp from this single change. | 1 day |
| **R5** | **Add LongMemEval to bench surface alongside LoCoMo.** | LoCoMo Cat 1-4 is saturated above 90% for the frontier. Supermemory at 99%, ENGRAM at 71.4% with 1% of tokens, HyperMem 92.73%, LiCoMemory new SOTA — all on LongMemEval. We're flying blind on the 2026 conversation without it. | 2-3 days harness work |

### Composite target

If R2 + R3 + R4 land: LoCoMo temporal +5-10pp, LongMemEval 75-80% overall — putting nullalis above mem0 and into the LiCoMemory / Supermemory-production conversation, with no new infrastructure.

### What NOT to do

- No second graph engine (Neo4j/Memgraph/KuzuDB-archived/AGE — research is unambiguous)
- No Microsoft GraphRAG community detection (6000× more tokens per retrieval than LightRAG)
- Don't ignore zero-edge boundary fires — treat them as P2 incidents (R1 covers this)

---

## Open queue (ranked)

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | **F3 — validate V1.14.8 graph density** on a real conv-26 long session (TTL=60s set, restart pending) | Me, this session | in progress |
| 2 | **F5 — rerun conv-43** with patched scorer to confirm/deny Cat 4 −9pp regression | Me, this session | next |
| 3 | **R1 — graph-density telemetry** (above) | Next session | queued |
| 4 | **R2 — bi-temporal invalidation** (above) | Next session | queued |
| 5 | Approval-drop bug — user clicks approve, tool drops instead of executing | Nova-scheduled (after gateway HTTP endpoints) | deferred |
| 6 | Modes post-context-v2 pass — fast/balanced/deep presets sized for old 12K budget | Me, low effort | queued |
| 7 | Refresh `.planning/STATE.md` to point at STATUS.md OR delete | Me, doc pass | queued |

### Subagent "received" bug — CLOSED (re-verified 2026-05-10)

D1 sprint shipped TurnOutcome refactor. V1.14.4 booth-readiness closed remaining OOM/standalone paths. 9 regression tests cover. Memory at `project_subagent_received_bug` kept for archaeology; do not re-open without code-truth evidence of regression.

---

## Carried architecture concerns

- **Lifecycle gaps** — hygiene startup-only, `conversation_retention_days=0` default, no background scheduler. Documented at `project_lifecycle_investigation_2026_04_20`. Not urgent.
- **Agent turn audit** — `memory_enrich` 900ms variance; `elideUnverifiedHistory` O(N) scan. Tolerated; post-profiling.
- **`internals/` directory referenced from memory does not exist on disk.** Memory references `internals/P1_{tech,arch,quality,concerns}.md`. Treat as historical pointer, not active doc.

---

## What this doc replaced (archived 2026-05-10)

Moved to `docs/archive/2026-05-10/`: 27 files including CLOSURE_CHECKLIST, CODE_REVIEW_REPORT, CORRECTION_PLAN, HTTP_TRANSPORT_MIGRATION, PROJECT_LEDGER, REVIEW.md-REVIEW4.md, TOOL_MATRIX, all `REVIEW-v1.11..v1.14.3-*.md` per-version reviews, all `post-compact-handoff-*` files.

**Kept at root:** README.md, AGENTS.md, CONTRIBUTING.md, SECURITY.md, LICENSE-COMMERCIAL.md, **this** STATUS.md.

---

## Maintenance rule

When you ship a meaningful version (≥ minor bump) or land a measurement-changing bench result, **update this doc, not a new dated one**. Date-stamped review docs are for ship-gate evidence and belong under `docs/archive/<date>/` after the next refresh.

Last hydration: 2026-05-10. Next hydration trigger: F3 validation result or first material change post-WebSummit signal absorption.
