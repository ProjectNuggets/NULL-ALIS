---
tags: [prose, prose/docs]
---

# nullalis Status Snapshot — 2026-05-19

Cold-readable operational truth source. Updated when waves close, not during.
Last archive: `docs/archive/status-2026-03-06.md`.

## Branch state

- **Branch:** `main` — 37 commits ahead of `origin/main`, not pushed (per Nova's "no push until ready" directive).
- **HEAD:** `3af8f6b8` — docs(extraction): record memory write hygiene audit verdict inline.
- **Build status:** `zig build` clean. `zig build test` exit 0; all warnings are expected mock-provider failure paths from test scenarios.

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

## Current Open Ends

1. **37 commits unpushed.** Pending Nova's "ready to push backup branch" signal.

2. **`searchHint` port — premature.** nullalis has no deferred-tool-discovery surface; model receives full tool catalog every turn. `ToolSpec` is 3 fields. Adding `search_hint` today = dead code. Re-evaluate when V-infinity adopts deferred discovery.

3. **`AskUserQuestion` port — blocked on zaki-prod renderer.** Backend tool ~50 LoC of boilerplate, but the value is the renderer (Telegram inline-keyboards + frontend multi-choice). Without renderer, tool emits JSON as wall of text — worse than asking in prose.

4. **UI autonomy toggle — blocked on zaki-prod.** Default flipped to `.full`; need frontend toggle so users can choose supervised/full without editing `config.json`.

5. **Native connectors (Composio replacement) — multi-day work.** Per-user OAuth/API/CLI wiring. Not started.

6. **Per-cell pod canary deploy — infra work.** zaki-infra side. Not started.

7. **agent turn audit followups** (from `project_agent_turn_audit_followups`):
   - `memory_enrich` 900ms variance — not urgent, keep for post-profiling.
   - `elideUnverifiedHistory` O(N) scan — not urgent.

8. **Lifecycle followups** (from `project_lifecycle_investigation_2026_04_20`):
   - Hygiene startup-only, no background scheduler.
   - `conversation_retention_days = 0` default.
   - Not tonight's latency cause; revisit post-canary.

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
