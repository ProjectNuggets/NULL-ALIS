---
tags: [prose, prose/docs]
---

# nullalis Status Snapshot — 2026-05-19 (PM update)

Cold-readable operational truth source. Updated when waves close, not during.
Last archive: `docs/archive/status-2026-03-06.md`.

**Active roadmap:** [`docs/ROADMAP.md`](ROADMAP.md). Current sprint: **v1.14.13** (τ-bench baseline + wire what's built).
**Active standards:** [`AGENTS.md`](../AGENTS.md) §14 (Nullalis-grade Swiss-watch).

## Branch state

- **Tag:** `v1.14.12` pushed to `origin`.
- **PR open:** [#72](https://github.com/ProjectNuggets/NULL-ALIS/pull/72) — `release/v1.14.12-memory-audit` → `main`, 50 commits.
- **Build status:** `zig build` clean. `zig build test` exit 0; all warnings are expected mock-provider failure paths from test scenarios.

## 2026-05-19 PM update — file-by-file audit

Three parallel agents audited the codebase scoping by directory. **67 findings total** (9 HIGH, 31 MED, 27 LOW). Per AGENTS.md §14.2 / §14.4, the findings are not "delete candidates" — they are unfinished work. The roadmap (`docs/ROADMAP.md` v1.14.13 + v1.14.14 + v1.14.18) finishes them.

Key clusters identified:
- **Half-finished modules:** `task_planner.zig`, `narration.zig`, `context_engine.zig`, `tools/schema.zig` — built but never wired. v1.14.13 wires them.
- **Config zombies:** Email, Teams, Nostr accept config.json fields with no daemon wiring. v1.14.15/16/17 finishes the channels.
- **False-confidence handlers:** `handleReady` (7 tests, 0 prod callers), `EMPTY_TURN_PLACEHOLDER` (V1.14.4 removed emission, doc still claims behavior). v1.14.13 rewires or strips.
- **Aspirational prompt directive:** F-A2 brain_graph instruction ignored by model (0 calls vs 145). v1.14.13 strips per AGENTS.md §14.7.

## Scope landed in this branch (post-V1.14.4 booth-readiness)

- **V1.14.12 extraction M1–M5 sprint** — per-path WriteOrigin telemetry, predicate cardinality fast-path (judge-skip for high-confidence single-valued predicates), coverage filter (skip re-extraction of agent memory_store keys), legacy direct-write gating + flag.
- **Path A close-out (`d8dc5f8e`)** — deleted gated legacy direct-write callsites in `commands.zig` (session-end) and `compaction.zig` (Pass C). `extraction_legacy_direct_writes` flag removed; `JudgeContext` made optional in `runner.zig`.
- **Path A cleanup (`c9d5eefb`)** — dropped dead `WriteOrigin` variants (`pass_c_compaction_direct`, `session_end_durable_fact`). Enum went 8 → 6 variants. String-stability test updated.
- **Hygiene audit (`3af8f6b8`)** — every memory write path verified CLEAN. Inline marker at `extraction_persist.zig:1650-1672`.
- **Brain query semantics tightening (`8c68bb63`)**.
- **Gateway large-response write completion (`8da64fb8`)**.

## Most Important Reliable Truths

1. **Memory writes go through exactly one funnel — `persistExtracted`.**
   - 3 production callsites (`tools/memory_store.zig:175`, `compaction.zig:470` + `707`, `commands.zig:1452`) each set explicit, distinct `WriteOrigin`.
   - `entity_pipeline` (`daemon.zig:1227`, `tools/wiki_link.zig:115`) is a separate edge-graph layer (`MENTIONS`/`MENTIONED` predicates, `wiki_link` attribution). Distinct schema layer (`memory_edges` table), not a competing fact-write path.
   - No legacy direct-write paths survive Path A.

2. **`WriteOrigin.unknown` is intentional loud-signal — do not rename or repurpose.**
   - `ExtractionContext.write_origin` defaults to `.unknown` per M1 review HIGH#1 fix.
   - A forgotten field on a new callsite surfaces in the telemetry histogram as `.unknown` outlier rather than silently inflating `session_end`.
   - Test `WriteOrigin enum count guards against silent additions` (`extraction_persist.zig:1650`) locks 6 variants.

3. **Pre-M1 metadata backfill is impossible.** All pre-M1 rows carry identical `attribution = "extraction_classifier"` and no `write_origin` metadata. No surviving discriminator distinguishes pre-M1 `memory_store_tool` writes from pre-M1 extraction-batch writes. M1 is the cut line; everything before it is opaque.

4. **Approval drop bug is CLOSED 2026-04-18, re-verified 2026-05-18.**
   - Fix: `approval_continues_turn=true` default at `root.zig:520` + synthetic continuation message in `commands.zig::handleGenericToolApprove` (lines 2762-2853).
   - Regression test at `root.zig:10711` locks the default.

5. **`approval_continues_turn=true` is the production default — do not flip.**
   - Tests that set false at lines 10494, 10540, 10590, 10647 do so only because they lack a live provider. Flipping the production default would re-introduce the 2026-04-18 "approve drops instead of executing" symptom.

6. **Context v2 byte-stable prefix invariant holds.** Phase A/B landed (iter18-iter20). Same prefix hash across consecutive turns. Provider-independent cache hits.

## Current LoCoMo / V-infinity benchmark posture

| Iter | Pass rate | Notes |
|---|---|---|
| iter17 cold | 25/25 | all 12 V-inf categories at 1.00 |
| iter17 polluted | 21/25 | weaknesses in agentic_execution + tool_discipline |
| iter18 phaseA | 23/25 polluted | byte-stable prefix, latency −50% |
| iter19 phaseB | 23/25 polluted | 50% trigger + anti-thrash, multi-turn recovered |
| iter21 cleanup | 22/22 real (3 infra-flake curl timeouts) | dead-code removed |

## Current Open Ends (each maps to a roadmap block)

1. **PR #72 review + merge** — releases v1.14.12 into `main`.

2. **v1.14.13 sprint** — τ-bench Airline baseline + wire orphans (`tools/schema.zig`, `task_planner` + `narration`, `handleReady`, F-A2 strip, BrowserTool honesty, BIRTHDAY contradiction). 5-7 days. See ROADMAP.md.

3. **v1.14.14 ContextEngine migration** — route `root.zig::turn()` through the 4-phase lifecycle. Activates ~1K LoC of correct-but-unused code. 7-10 days.

4. **v1.14.15/16/17 channel finishes** — Email, Teams, Nostr each get one block.

5. **v1.14.18 MED-tier sweep** — close 31 remaining audit findings. QMD export wiring, Composio error sanitizer, CLI honesty, stale-comment sweep.

6. **v1.15.0 τ-bench iteration sprint** — Karpathy loop on execution quality.

7. **v1.16.0 frontend wave** — UI autonomy toggle, AskUserQuestion renderer, mode toggle, brain entity styling. Needs zaki-prod.

8. **v1.17.0 native connectors phase 1** — top 3-5 integrations via OAuth.

9. **v1.18.0 per-cell pod canary** — zaki-infra. 7-day soak gate.

10. **v1.19.0 observability + SRE** — Grafana, alerting, latency budgets.

11. **v2.0.0 commercial launch** — payment + onboarding. Strategy locked with Nova post-cleanup.

12. **V-infinity arc** — 12 pillars, one sprint each, paced by user signal.

## Verification anchors

- **Memory write hygiene:** `src/agent/extraction_persist.zig:1650-1672` — inline audit verdict.
- **WriteOrigin enum:** `src/agent/extraction_persist.zig` (6 variants, string-stability test at L1638).
- **Approval-continues-turn lock:** `src/agent/root.zig:10711-10752` — regression test.
- **Path A simplification:** `src/agent/commands.zig:1434` (session_end no longer judge-gated), `src/agent/compaction.zig:444-485` + `693-720` (Pass A + Pass C extractAtBoundary no longer judge-gated).
- **Extraction context:** `src/agent/extraction/runner.zig:140-149` — `.unknown` default is the loud-signal pattern (M1 review HIGH#1).
- **Internals x-ray:** `internals/P1_{tech,arch,quality,concerns}.md` — code-truth inventory, baseline `87cb435`. Touching code = bump verified-at sha (see `feedback_update_internals_on_touch`).

## Operating reminders (do not re-derive)

- **Restore-first rule:** archaeology before architecture. Don't delete code without counting reference sites (see `feedback_scope_before_delete`).
- **Docs follow code:** code/logs are truth; write canonical docs AFTER waves complete (this doc honors that rule).
- **Cold memory + auditability:** all messages persisted forever. Transcript IS cold tier. Do not add TTL/caps to conversation rows.
- **Commit discipline:** commit at clean stopping points; never stack sessions of uncommitted work.
- **Update internals on touch:** touching code = update matching `internals/P*.md` entry + bump verified-at sha.
