---
tags: [prose, prose/docs, prose/readiness]
authored: 2026-05-23
purpose: Long-conv commercial-readiness QA — 40-turn ingest + 15-query cold-session stress recall, live telemetry
pairs_with: STATUS.md, SPRINT4_READINESS.md
---

# Long-conv QA — commercial-readiness pass, 2026-05-23

**Method.** 40-turn synthetic ingest of a realistic SaaS-project narrative
(Alex/Phoenix, multi-entity team Sarah/Marcus/Liam/Priya, dated decisions,
a mid-stream Redis-reversal contradiction, personal preferences) on a
clean tenant 2009, single ingest session. Then 15 stress queries on a
**cold session** under the same tenant, scored on 6 memory axes
(temporal-explicit, temporal-revised, entity, contradiction-aware,
cross-topic, personal). Gateway started production-clean; live monitor
on the gateway log for compaction / extraction / recall / subagent
events. Driver at `/tmp/qa_long_conv.py`, log at `/tmp/qa_long_run.log`,
gateway log at `/tmp/qa_long_gw.log`, structured results at
`/tmp/qa_long_stress.json`.

---

## TL;DR

**Effective recall on a cold session: 14 of 14 (100%) on facts the agent
chose to store**, plus 1 correct safety refusal (the agent declined to
persist a phone number under PII policy). Memory engine is production-
grade at the recall axis. **Cosmetic XML leak persists at low rate (3/40
ingest, 1 mid-stress)**, intermittent — not a blocker.

Pass C extraction never fired in this run (expected: K2.6's 262K context
window never crossed the ~131K compaction trigger over 40 short turns).
The structured `valid_at` → `temporal_anchor_unix` path requires a
capped-window follow-up to validate end-to-end.

## Phase A — ingest (40 turns)

| Metric | Value |
|---|---|
| Total turns | 40 |
| Total wall time | ~19 min |
| Per-turn latency p50 / p95 / max | 26.4s / 56.2s / 67.8s |
| Per-turn latency avg | 28.3s |
| HTTP 200 | 40/40 |
| Tool calls | `memory_store=80`, `memory_recall=12`, `file_edit=8`, `file_read=6`, `memory_list=2` |
| XML leak in reply prefix | 3/40 (T01, T31, T32) — 7.5% |
| Compaction events | 0 (expected — K2.6 window never crossed threshold) |
| Pass C extraction | 0 (gated on compaction) |
| Agent-side safety refusal | 1 (declined to store phone number on T38) |

The agent didn't passively echo facts — it actively used `memory_store`
80 times across 40 ingest turns, structuring most facts as
`SCREAMING_SNAKE_PREDICATE` edges (NAME, WORKS_ON, IS_A, HAS_TEAM,
HAS_DEMO_ON, HAS_BETA_ON, LOCATED_AT, USES, etc.) — exactly the shape
the extraction prompt aims for, but produced via the direct-store
path rather than Pass C.

## Phase B — cold-session stress recall (15 queries)

The substring rubric the driver uses is loose (counts substring hits
against an expected-keyword list); the **honest content-level verdict**
is reported below per query.

| # | Axis | Loose-rubric | Content-level verdict |
|---|---|---|---|
| S01 | temporal_explicit | ✓ 2/2 | ✅ "Phoenix officially kicked off on **May 1, 2026**" |
| S02 | temporal_revised | ✓ 2/2 | ✅ "Beta target is now **September 30, 2026**…originally August 15" |
| S03 | temporal_decision | ✓ 2/2 | ✅ "Postgres on **May 3, 2026**. Sarah pushed for it over MySQL" |
| S04 | entity_team | ✓ 3/3 | ✅ Sarah/Marcus/Liam with roles + locations |
| S05 | entity_location | ✓ 1/1 | ✅ "Marcus is in **Amsterdam**" |
| S06 | entity_role | ✓ 1/1 | ✅ Priya, security consultant, Bangalore, May 31 threat model |
| S07 | contradiction_reversal | ~ 2/5 | **✅ ACTUALLY PERFECT** — "No — you dropped Redis entirely on May 20, 2026. Sarah migrated the hot-path caching into Postgres using an LRU approach." Rubric mis-scored because the answer was so clean it didn't need synonyms. |
| S08 | contradiction_replacement | ✓ 2/2 | ✅ "Postgres for caching now…LRU approach" |
| S09 | cross_preference | ✓ 1/1 | ✅ Zig, with context (user is a "Zig enthusiast") |
| S10 | temporal_range | ✓ 1/1 | ✅ "May 3 through May 20, 2026" + decision list |
| S11 | entity_profile | ✓ 3/3 | ✅ Marcus full profile (designer, Amsterdam, freelance, 8y exp) |
| S12 | personal_temporal | ✓ 1/1 | ✅ "April 12. You turned 34 this year" |
| S13 | personal_preference | ✓ 2/2 | ✅ "Vegetarian since **2018**" (extra detail beyond what was asked) |
| S14 | personal_relationship | ✗ 0/2 | **✅ ACTUALLY CORRECT** — agent declined to store the phone number under PII policy (visible in autosave_assistant: *"I'm not going to store Karim's contact info or that phone number"*). When asked, correctly reported "no matching records." System working as designed. |
| S15 | negative_unknown | ~ 2/6 | **✅ CORRECT** — agent correctly said it had no budget info. (Reply contains a mid-text `ool_call>` cosmetic leak.) |

**Honest score: 14/14 (100%) on facts-actually-stored, with 1 correct
safety refusal. The cold-session memory engine is solid.**

## Memory engine state (post-run, tenant 2009 in postgres)

| Table | Count |
|---|---|
| `memories` | 206 |
| `memory_edges` | 39 |
| `memory_edges` with `temporal_anchor_unix` populated | **0** ← P2 verification: not exercised on memory_store path |
| `memory_embeddings_e5_1024` | 39 |
| `memory_entities` | 37 |

39 edges from 80 stores ≈ 49% dedup (the agent stored some facts twice
under different framings; dedup correctly collapsed). 39 embeddings for
39 edges → 1:1 embedding coverage. 37 entities → clean coref.

## XML leak status

Persistent at a low intermittent rate despite multiple fix attempts
(stream hold path widened, defensive strip helper, residue-shape
matchers added).

- **3 ingest turns** (T01, T31, T32) leaked `ool_call>` at reply prefix.
- **S15 stress query** leaked `ool_call>` mid-reply text (driver's
  `startswith` detector missed it; visible in the reply transcript).
- **Pattern**: no clean predictor. T01 was the very first turn (fresh
  context). T31/T32 were short personal-aside turns. S15 was a search
  query that came back empty. Doesn't correlate with content,
  iteration count, or tool-usage shape we've been able to find.

Recommendation: **ship it as known cosmetic with a tracked deferral**.
The replies that follow the leak are correct and useful; ~7% ingest /
~6% stress leak rate is annoying but not a transaction-breaker.

## Latency

Ingest p95 56.2s is slower than ideal for a polished consumer
experience. Most of this is the LLM round-trip per turn (K2.6 via
Moonshot or Together), not nullalis overhead. The cold-session stress
queries — which are smaller per-turn — averaged about 11s with most under
8s; only S14 hit 42s (search-then-fail).

Cold-session p95 ≈ 17.8s.

## Pass C extraction — NOT exercised in this run

K2.6's 262K context never crossed the compaction threshold over a 40-turn
~15-25K conversation. To exercise Pass C and verify P2's structured
`valid_at` flowing into `memory_edges.temporal_anchor_unix`:

- restore the bench-cap mechanism from `origin/legacy/bench/locomo-d44-scaffolding`
  (the `NULLALIS_BENCH_CONTEXT_LIMIT` env var + thrash-hatch), OR
- run on a small-context model (mixtral-8x7b-32768 etc.), OR
- generate 200+ heavy turns to natively cross 131K.

Recommended as a follow-up run, not a v1 blocker — the direct-store
extraction path is working (39 well-formed edges, clean predicates).

## v1 commercial-readiness verdict

| Dimension | Status |
|---|---|
| Cross-session memory recall | ✅ 100% on stored facts |
| Multi-entity disambiguation | ✅ Sarah/Marcus/Liam/Priya all tracked distinctly |
| Temporal recall (text-layer) | ✅ Dates surface correctly in cold-session queries |
| Contradiction-aware recall | ✅ Redis-was-dropped reflected accurately |
| Cross-topic recall | ✅ Personal facts surface when project-context query precedes |
| Agent safety (PII refusal) | ✅ Declines to store phone numbers |
| Tool stability over 55 turns | ✅ 80 stores, 12 recalls, 0 hangs, 0 transport errors |
| Subagent path | not exercised in this QA (covered by Sprint 4 readiness QA T6) |
| `<tool_call>` XML leak | ⚠ ~7% intermittent, cosmetic, mid-text + prefix shapes |
| Pass C extraction | ⚠ untested in this run — needs capped-window follow-up |
| Latency (ingest p95) | ⚠ 56s — model-bound, not nullalis-bound |

**Ready to commercial-pilot as far as the memory engine is concerned.**
The remaining cosmetic XML leak should be tracked for resolution but
isn't a blocker for paying customers.

## Artifacts

- Driver: `/tmp/qa_long_conv.py` (replayable)
- Run log: `/tmp/qa_long_run.log` (per-turn timing + replies)
- Gateway log: `/tmp/qa_long_gw.log` (full telemetry: 39+ `recall.zero_candidates`, 0 compactions, 80 memory_store tool calls)
- Structured JSON: `/tmp/qa_long_stress.json` (per-query rubric breakdown)
- Postgres: tenant 2009 carries the 206 memories / 39 edges if you want to
  inspect interactively. Re-runnable any time after a tenant wipe.

---

## Recommended next moves

1. **Spawn / delegate hardening to S-tier** (the next item Nova green-lit) —
   investigate subagent prompt quality, result-delivery reliability (the
   QA3 flake), and tool-surface honesty for both.
2. **Capped-window Pass C verification** — restore the bench-cap from
   `origin/legacy/bench/locomo-d44-scaffolding`, repeat the 40-turn ingest
   under a 16K cap to force Pass C + verify `temporal_anchor_unix`
   populates from the `valid_at` field.
3. **Dormant-feature sweep** — Nova's item 3.
4. **Sprint 4 UI/UX activation** — the originally-planned block, last.
