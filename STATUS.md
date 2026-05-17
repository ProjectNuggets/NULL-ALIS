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
| **V1.14.8** | Unified boundary extraction at `src/agent/extraction/` (schema + prompts + parser + runner). All 4 boundaries (Pass A, Pass C, session-end, force-compress) flow through one `extractAtBoundary`. `slot_intent` → working_memory.promote synchronously. Pass A extract-only (hydration skipped). | **Shipped + scored** |
| V1.14.7 | Per-turn extraction deletion. F-A1 calibrated-honesty regression fix. Layer 4 graph-empty bug fixed. | Shipped + verified |
| V1.14.6 | F-CB1 cache breakpoints, F-PA2 drop-from-middle Pass A, S-tier prompt rewrite. | Shipped, headline result |

---

## Bench standings

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

## V1.14.8 graph-density validation status

**WIRE: CONFIRMED LIVE.** Two `boundary.complete` events fired during the conv-26 run:
- `session=agent:zaki-bot:user:9999:main` (smoke session, 3 msgs) — entities=0 edges=0 hydration_present=true ✓
- `session=agent:zaki-bot:user:2000:task:locomo_s0_bf6704` (2-session sub-batch, 11 msgs) — entities=0 edges=0 hydration_present=**false** ⚠

**DENSITY: UNVALIDATED.** Both observed fires returned 0 entities/0 edges. Could be legitimate (tiny windows had no extractable facts) or a real wire issue. The main conv-26 long-session (19 sessions, 6 hrs of conversation) hadn't gone idle by the 30-min default TTL during the run window. **F3 (in progress on `feat/v1148-validate-and-graph-density`)** sets TTL to 60s and validates the wire on a real populated session.

---

## What changed today (2026-05-10)

| Commit | Change | Branch |
|---|---|---|
| `67def0b9` | Doc sweep: 27 historical docs archived; STATUS.md hydrated | main |
| `d4be7e2b` | F1 scorer fix: skip GT-empty rows | feat/v1148 |
| `82c3e2f6` | F6 silence `public.zaki_users` log noise (~200 lines/run before; one line after) | feat/v1148 |

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
