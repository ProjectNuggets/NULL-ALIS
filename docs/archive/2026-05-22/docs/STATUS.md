---
tags: [prose, prose/docs]
---

# nullalis Status Snapshot — 2026-05-20 (PM update — post v1.14.14.1 + v1.14.18-A F1/F2)

Cold-readable operational truth source. Updated when waves close, not during.
Last archive: `docs/archive/status-2026-03-06.md`.

**Active roadmap:** [`docs/ROADMAP.md`](ROADMAP.md). Latest tag: **v1.14.14**. Active sprint: **v1.14.18-A** — Findings 1 + 2 MERGED, Finding 3 (GOAL-LOOP) in CI-rework on PR #82.
**Active standards:** [`AGENTS.md`](../AGENTS.md) §14 (Nullalis-grade Swiss-watch) + §14.10 (Post-sprint Activation Audit Discipline).
**Dispatch:** [`docs/MULTI_AGENT_PLAN.md`](MULTI_AGENT_PLAN.md) — which agent owns which sub-task.

## Branch state (post v1.14.18-A Finding 1 + 2 land)

- **Tag:** `v1.14.14` at `9cfa6b37` (ContextEngine 4-phase migration + stability-JSONL drift CI gate).
- **Main HEAD:** `a64aa262` carrying all merged work below.
- **Recently merged PRs (2026-05-20 wave):**
  - **#78** v1.14.14 ContextEngine migration (Agent G) — merged `9cfa6b37`
  - **#79** discipline-install: v1.14.14 activation audit + v1.14.18-B/v1.14.19 ROADMAP + AGENTS.md §14.10 — merged `400008a5`
  - **#80** v1.14.14.1 context-engineering polish (5 findings: WM-importance drop + tail-surface + compact aggregate + sentinel resolve + canary runbook) — merged `01c3a99c`
  - **#81** v1.14.18-A Finding 2 — TOOL-DESC-AUDIT (52 tools to ToolDescription struct + comptime lint) — merged `40716334`
  - **#83** v1.14.18-A Finding 1 — MODE-UNIFICATION (delete preset machinery + bump max_tool_iter 25→500 + §14.5 orphan cleanup) — merged `95f82aa3`
  - **#84** chore(fmt): zig fmt src/ — clean 11 pre-existing fmt issues — merged `a64aa262`
- **In-flight PR:** **#82** v1.14.18-A Finding 3 — GOAL-LOOP + procedural memory activation — BLOCKED on §14.10 audit catches (3 rounds of half-wires; coordinator-corrected dispatch + memory-ownership fix in progress).
- **Build status:** `zig build` clean. Canonical-profile test exit 0 on main. Per-finding bench gate paused per §14.10 until v1.14.18-A + v1.14.18-B + v1.14.19 all land (real behavioral attribution).
- **MaxRSS:** 62M (Agent E B13 deferred remediation; tracked in `docs/deferred-register.md`).

## 2026-05-20 sprint state — what's now live on main

**Behavioral additions on production code path:**
- 52 agent-facing tools migrated to structured `ToolDescription` (Agent E F2) with comptime lint enforcing 4 of 5 quality rules on every build (Rule 5 rendered-length deferred)
- `max_tool_iterations` default 25 → 500 (Agent E F1) — adaptive exits are the real guardrails; cap is safety valve only
- `assistant_mode` → `reasoning_effort` mapping (fast→low, balanced→medium, deep→high); user-set `reasoning_effort` wins
- WM `importance` dropped from composite eviction formula (Agent G v1.14.14.1 F1) — eviction now discriminates via `recency × slot_type_weight` only. Per-source calibration deferred to v1.14.18-B as the SOTA option-(a) path.

**Visibility / diagnostic additions:**
- `prefix.tail` hash exposed through `AssembleResult` + JSONL (Agent G v1.14.14.1 F2). `.spike/run.sh` jq drift detection covers BOTH cache halves.
- `compact_ms_main_site_only` honestly renamed (Agent G v1.14.14.1 F3); option-(a) full aggregation deferred to v1.14.14.2.
- `docs/ops/stability-jsonl-canary.md` runbook landed for prod deployment (operator action).

**Hygiene completed:**
- `CompactResult.messages_before/after` sentinel fields removed (Agent G v1.14.14.1 F4)
- 11-file `zig fmt src/` cleanup (PR #84)
- Pre-existing fmt debt cleared

**Process discipline installed:**
- AGENTS.md §14.10 — Post-sprint Activation Audit Discipline binding on all future sprints
- `docs/audits/2026-05-20-v1.14.14-activation-audit.md` — inaugural execution; 19 latent-value gaps G1-G19 classified
- ROADMAP v1.14.18-B + v1.14.19 blocks pre-scoped (no more "Nova flagged the gap" moments)

**§14.10 effectiveness this sprint:** caught 3 issues on PR #82 pre-merge (design-vs-implementation gap on Agent E F2, §14.5 orphan structs on F1, reflection-loop-not-wired on F3 — twice). Each catch is a round-trip pre-merge instead of a regression post-merge.

## Current open ends (2026-05-20)

1. **PR #82 (F3 GOAL-LOOP) BLOCKED** — coordinator-corrected dispatch in progress (memory-ownership bug in original dispatch + missing buildReflectionPrompt injection + missing prompt.zig Goal Pursuit Protocol section). Three §14.10 catches; canonical-CI gate failing on double-free.
2. **v1.14.18-B dispatch** ready to fire when PR #82 lands. 5 findings scoped: G3 narration-as-context + G5 reflection-store + G7 bench-self-knowledge + G16 WM-cross-session + G19 daemon-prompt-honesty.
3. **v1.14.19 sleep cycle** ready post-v1.14.18-B. 5 findings scoped: SC1 skill-consolidation + SC2 negative-examples + SC3 memory-dedup + SC4 community-recompute-scheduler + SC5 sleep-cycle-observability.
4. **Bench gate paid** post-v1.14.18-A + v1.14.18-B + v1.14.19 (per §14.10 — no bench until real behavioral attribution available).

## 2026-05-19 PM update — file-by-file audit

Three parallel agents audited the codebase scoping by directory. **67 findings total** (9 HIGH, 31 MED, 27 LOW). Per AGENTS.md §14.2 / §14.4, the findings are not "delete candidates" — they are unfinished work. The roadmap (`docs/ROADMAP.md` v1.14.13 + v1.14.14 + v1.14.18) finishes them.

Control ledger: [`docs/audits/2026-05-19-file-by-file-audit-ledger.md`](audits/2026-05-19-file-by-file-audit-ledger.md). Treat the 67-count summary as intake until every row has a commit reference or deferral rationale.

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
