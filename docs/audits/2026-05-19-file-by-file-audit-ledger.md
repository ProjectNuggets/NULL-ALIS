---
tags: [prose, prose/docs, prose/audit]
authored: 2026-05-19
purpose: active control ledger for post-v1.14.12 audit findings
binds_to: docs/ROADMAP.md + docs/MULTI_AGENT_PLAN.md + AGENTS.md §14
---

# 2026-05-19 Audit Ledger

This is the control ledger for the post-v1.14.12 audit wave. It makes the
roadmap dispatchable, but it does not make the code fixed. A row is closed only
when the closing commit or deferral entry is recorded here.

## Ledger Rules

- `VERIFIED` means the current tree contains code/doc evidence for the row.
- `INTAKE` means the prior audit rollup named the issue, but this ledger still
  needs the original per-file evidence imported.
- `CLOSED` requires a commit hash.
- `DEFERRED` requires a `docs/deferred-register.md` entry and rationale.
- No roadmap block may be tagged while it has `OPEN` rows assigned to it.

## Rollup

| Source | Count | Ledger status |
|---|---:|---|
| Memory audit | 13 | Closed by v1.14.12 / PR #72, tracked by commit history |
| Architecture audit | 10 | Mapped below where code evidence was verified |
| File-by-file audit | 67 | Intake rollup exists; complete per-finding source import still required |
| Blind spots | 13 | B1-B12 from roadmap plus B13 MaxRSS budget breach |

The earlier docs claimed "102 items mapped" as a closure signal. The corrected
meaning is narrower: the items are roadmap-mapped, not code-closed.

## Verified Open Rows

| ID | Severity | Finding | Evidence at HEAD | Target block | Owner | Status |
|---|---|---|---|---|---|---|
| V8 | HIGH | Sandbox can still run unsandboxed when backend resolves to `none` and `fail_open_on_dev=true`. | `src/tools/tool_sandbox_v1.zig:162-168` | v1.14.13 Step 0 | A | CLOSED 4dec8711 |
| B1 | MED | AGENTS repository map named missing `src/skillforge.zig`. | AGENTS.md §4 now names `src/skills.zig` only; archived predecessor removed from active protocol. | v1.14.13 Step 0.5 | E | CLOSED a2e5140b |
| B2 | MED | Bench harness lacks TTFT p50/p95 columns despite SLO target. | `.spike/results.tsv` header has no `p50_ttft_ms` / `p95_ttft_ms`; `.spike/run.sh` only reports mean latency. | v1.14.13 Step 7 | D | CLOSED 015dc461 |
| B13 | MED | Test MaxRSS budget currently exceeds AGENTS target. | Measured baseline 2026-05-19 on agent/E-v1.14.13: main test binary MaxRSS 62M (6045 passed / 67 skipped); two satellites within budget (5M, 2M). Overage entirely in the monolithic root.zig test binary. Cheap fix blocked on per-test allocator instrumentation; data-driven remediation deferred. See `docs/deferred-register.md` row B13 for root-cause hypothesis + 4-step remediation path. | v1.14.13 Step 8 | A/D/E as assigned | CLOSED b51cb4a5 (deferred — measured baseline + remediation path documented) |
| F-A2 | MED | `brain_graph` prompt directive is known ignored by bench and still emitted. | Directive stripped from `src/agent/prompt.zig`; comment block at the prior location names the deferred-register entry. F-A2.1 router parked in `docs/deferred-register.md` (v1.14.13 section). | v1.14.13 Step 4 | E | CLOSED e59c645b |
| GOAL-LOOP | HIGH | Goal-loop reflection (ReAct-style with session-wide tool accumulation + goal-status calibrated outcome_quality) missing from agent turn cycle. | New `src/agent/goal_loop.zig` module (GoalStatus enum, GoalState struct, parseReflection, buildReflectionPrompt, buildSkillTraceContext). Agent struct extensions (session_total_tool_count, session_tool_names, active_goal_state) + defer accumulation. Capture gate rewritten to use session-wide counter (fixes production 0-row bug from per-turn tracking). outcome_quality now maps goal_status to calibrated values (met→0.9, stuck→0.3, max_iterations→0.4, in_progress→0.5), providing first per-source signal for memory eviction (vs purely heuristic formula). | v1.14.18-A | E | CLOSED 4e67d69a |
| G5 | MED | v1.14.18-B REFLECTION-STORE — per-iteration reflection trail not persisted; `skill_executions.assumptions_made` shipped a literal `[]`, so cross-session learning had no trace data. | New `src/agent/reflection.zig` (ReflectionTrail + serialize); `root.zig` accumulates the trail per turn, `commands.zig` session-end passes it through `procedural_memory.captureSession` → `insertSkillExecution`. Code on `agent/E-v1.14.18-B` (PR #87, `e0d549c8`); per-turn free-leak fixed as a follow-up commit. | v1.14.18-B | E | OPEN — code present; canonical CI gate UNRUN, promotion+reflection integration test (Fix C) pending |
| G7 | MED | v1.14.18-B BENCH-SELF-KNOWLEDGE — agent had no awareness of its own measured weak axes. | New `src/agent/bench_self.zig` (`readKnownWeakness` reads `.spike/results.tsv` → `<known_weakness>` block); wired into the volatile-prompt recall stack via `context_engine.zig` + `prompt.zig`. Code on `agent/E-v1.14.18-B` (PR #87, `e0d549c8`); CI-failing test fixed as a follow-up commit (hermetic `tmpDir`). | v1.14.18-B | E | OPEN — code present; canonical CI gate UNRUN |
| HND-READY | MED | `handleReady` has tests but no production route caller. | `/ready` route at `src/gateway.zig:17962` rewired to call `handleReady` (canonical implementation; 7 existing tests at 23492+ cover it). | v1.14.13 Step 5 | E | CLOSED c385af1b |
| EMPTY-TURN | MED | `EMPTY_TURN_PLACEHOLDER` remnants still exist after structured tool-only turn work. | `pub const EMPTY_TURN_PLACEHOLDER` deleted from `src/gateway.zig:57`; in-file archaeology comments at 8588/8610/8615/9755/24876 updated to drop dead symbol name; `src/observability.zig:87` stale doc corrected. Comment-only refs in `src/agent/root.zig` + `src/session.zig` left untouched (Agent F owns root.zig; both files retain historical context that grep can find via the new wording). | v1.14.13 Step 5 | E | CLOSED c385af1b |
| BROWSER-HONESTY | MED | Browser tool advertises unimplemented `screenshot`, `click`, `type`, `scroll`. | `src/tools/browser.zig` tool_description, params enum, and dispatch reduced to `open`/`read`. 3 tests rewritten to validate the honest catalog (BROWSER-HONESTY tag in test names). | v1.14.13 Step 5 | E | CLOSED c385af1b |
| BIRTHDAY-DOC | LOW | `predicateToSlotType` docs say BIRTHDAY does not promote, code promotes it to temporal. | Docstring corrected — BIRTHDAY now documented as the temporal-cluster exception (countdown surface rationale); code unchanged. | v1.14.13 Step 5 | E | CLOSED c385af1b |
| IDENTITY-ORPHAN | LOW | `src/identity.zig` needs keep/document/delete disposition. | Outcome A applied (keep + document) per ROADMAP default. Top-of-file comment block in `src/identity.zig` names the deferred-register entry and the V-infinity persona-pillar gating. Module reachable only via the re-export at `src/root.zig:75` (left intact). | v1.14.13 Step 6 | E | CLOSED 1ca6e104 |
| SCHEMA-WIRE | HIGH | `src/tools/schema.zig` exists but provider serialization does not call `cleanSchemaForProvider`. | `rg cleanSchemaForProvider src/providers` returns no provider usage. | v1.14.13 Step 2 | F | CLOSED 8a94fcc7 |
| TASK-PLANNER-WIRE | HIGH | `<task_plan>` directive exists, parser module is only reexported, not used in turn loop. | `src/agent/root.zig:5396-5399`; no runtime parse call. | v1.14.13 Step 3 | F | CLOSED 6cb4f9d5 |
| NARRATION-WIRE | MED | `NarrationObserver` exists with tests but is not wired to channel/front-end rendering. | `src/agent/narration.zig`; only reexport in `root.zig`. | v1.14.13 Step 3 | F | CLOSED 6cb4f9d5 |
| CONTEXT-ENGINE | HIGH | `ContextEngine` phases exist but production turn loop is still inline. | `src/agent/context_engine.zig`; roadmap migration needed. | v1.14.14 | G | CLOSED (Phase 1 INGEST: faf1ba56; Phase 2 ASSEMBLE: ee96ca40; Phase 3 COMPACT: 6ebf6645; Phase 4 AFTERTURN: e0d377ac; Phase 5 bench assertion: 3298f64f; self-review pass: 843ca622 — fmt + unused import + JSONL write race + defer-contract honesty) |
| COMPACT-SENTINEL-RESOLVE | LOW | `CompactResult.messages_before/after` synthesized as sentinel `0` in the Phase 4 defer; production discarded the return so it was inert, but it was still a §14.6 honest-surface violation. | `src/agent/context_engine.zig` CompactResult struct + afterTurn body; root.zig:2870 sentinel. | v1.14.14.1 Finding 4 | G | CLOSED 4e8cb7ee — option (b): removed fields; agent.last_turn_context (via recordAutoCompaction/recordForceCompression) is the source of truth |
| PREFIX-TAIL-SURFACE | LOW | Phase 2 surfaced `stable_prefix_hash` but stopped there. The kept-history tail hash existed only as an env-gated log line; AssembleResult + JSONL + the Phase 5 drift assertion didn't see it. | `src/agent/context_engine.zig` AssembleResult, StabilityRecord, assemble body; `.spike/run.sh` drift block. | v1.14.14.1 Finding 2 | G | CLOSED a9ca41f6 — tail_hash/tail_bytes now flow through AssembleResult + JSONL; Phase 5 jq assertion covers both halves; either drifting mid-session fails the bench |
| COMPACT-MS-AGGREGATE | LOW | Phase 4's `compact_ms` only measured the main-flow auto-compaction site (root.zig:3064); the other 10 compact callsites contributed nothing. JSONL key implied per-turn total but reported a partial number. | `src/agent/context_engine.zig` PhaseDurations + StabilityRecord + writeStabilityJsonl. | v1.14.14.1 Finding 3 | G | CLOSED fda8499b — option (b) honesty rename: StabilityRecord + JSONL key now `compact_ms_main_site_only`. Full aggregation (option a) deferred to v1.14.14.2 when Agent E's root.zig lock releases; 11-site inventory documented at PhaseDurations |
| WM-IMPORTANCE-CALIBRATION | HIGH | Production postmortem: 350 working_memory slots across 95 sessions all averaged importance ≈ 0.99 across every slot_type. The composite eviction formula `importance × recency × slot_type_weight` (both Zig + SQL surfaces) collapsed to recency × type_w because the LLM extractor's `m.confidence` saturated. Eviction across same-type same-recency slots was arbitrary. | `src/agent/working_memory.zig:93` compositePriority + `src/zaki_state.zig:7660` SQL ORDER BY + extraction prompt + persist-time default. | v1.14.14.1 Finding 1 | G | CLOSED 48329ee8 — option (b): dropped importance multiplier from both Zig and SQL formulas. Importance column STAYS in schema (zero migration); v1.14.18-B re-enables once a per-source signal-strength column lands on ExtractedMemory. Alternatives (a, c, d–l) surveyed and rejected — full audit in PR review record. |
| EMAIL-ZOMBIE | HIGH | Email config/channel code exists but daemon/channel loop start path is not wired. | `src/config_types.zig:684`, `src/channels/email.zig`; channel loop imports only Telegram plus legacy surfaces. | v1.14.15 | B | OPEN |
| TEAMS-ZOMBIE | HIGH | Teams config/channel code exists but full inbound/outbound daemon/gateway path is incomplete. | `src/channels/teams.zig`, config primary helpers. | v1.14.16 | B | OPEN |
| NOSTR-ZOMBIE | HIGH | Nostr config/channel code exists but daemon/channel loop start path is not wired. | `src/channels/nostr.zig`, config primary helpers. | v1.14.17 | B | OPEN |
| QMD-WIRE | MED | QMD session export/prune needs invocation or config removal. | `docs/ROADMAP.md` v1.14.18 Step 1, code surface named there. | v1.14.18 | E | INTAKE |
| COMPOSIO-SANITIZER | MED | Composio error sanitizer needs execution-path wiring to avoid token leaks. | `docs/ROADMAP.md` v1.14.18 Step 2. | v1.14.18 | E | INTAKE |
| CLI-HONESTY | MED | Registered CLI commands must ship behavior or be removed. | `docs/ROADMAP.md` v1.14.18 Step 3. | v1.14.18 | E | INTAKE |
| CHUNKER-DECISION | LOW | Vector chunker orphan needs keep/delete/defer decision. | `docs/ROADMAP.md` v1.14.18 Step 5. | v1.14.18 | E | INTAKE |
| HYBRID-MERGE-DECISION | LOW | Legacy hybrid merge needs keep/delete/defer decision. | `docs/ROADMAP.md` v1.14.18 Step 6. | v1.14.18 | E | INTAKE |
| V4 | HIGH | Subagent ledger bridge remains optional. | `src/subagent.zig:134` uses `?*tasks_mod.TaskDelivery`. | v1.14.18 / v1.17.5 | C | OPEN |
| V6 | MED | Legacy `state.zig` deprecation/migration path needs explicit handling. | `docs/ROADMAP.md` v1.14.18 Step 8. | v1.14.18 | E | INTAKE |
| V7 | MED | Markdown mirror should be opt-in, not default architecture. | `docs/ROADMAP.md` v1.14.18 Step 9. | v1.14.18 | E | INTAKE |
| B8 | MED | Coverage audit is missing. | No `.spike/coverage/<ts>/` active report. | v1.14.18 | J | OPEN |
| V3 | HIGH | Approval state is in-memory/cache-first, not durable source of truth. | `src/agent/root.zig` pending approval state; roadmap migration required. | v1.17.5 | C | OPEN |
| V5 | HIGH | Durable run event log/replay package is missing. | `src/runtime/events/` does not exist. | v1.17.5 | C | OPEN |
| B9 | MED | GDPR purge lacks E2E coverage for approvals/run_events once those tables land. | Roadmap Step 4. | v1.17.5 | C | OPEN |
| B5 | HIGH | Platform-wide load test/capacity envelope missing. | Existing Telegram webhook stress is narrower than required. | v1.18.0 | J | OPEN |
| B12 | MED | Capacity model doc missing. | `docs/capacity-model.md` does not exist. | v1.18.0 | J | OPEN |
| B4 | HIGH | Disaster recovery restore drill/runbook missing. | `docs/dr-runbook.md` does not exist. | v1.18.5 | J | OPEN |
| B6 | MED | Long-tenant recall benchmark missing. | No synthetic 5-year / 50K-row result artifact. | v1.19.0 | J | OPEN |
| B7 | MED | OTEL observer exists but collector deployment is not documented/wired. | `OtelObserver.fromEnv` exists; collector ops doc/env wiring missing. | v1.19.0 | J | OPEN |
| H1 | HIGH | Authorization model split between capability metadata and flat allowlist. | `src/security/policy.zig:71` plus callers of `default_allowed_commands`. | v1.19.5 | A | OPEN |
| V9 | HIGH | Fallback session keys can still propagate into canonical paths. | `src/session/root.zig:70-74`, `src/daemon.zig:1418-1419`. | v1.19.5 | A | OPEN |
| B3 | MED | Unit economics baseline missing before pricing decision. | No `docs/unit-economics-*.md`. | v1.19.7 | J | OPEN |
| B11 | HIGH | Frontend XSS/agent-content contract test missing across zaki-prod boundary. | Cross-repo; nullalis doc tracks dependency. | v2.0.0 | I/Nova | OPEN |
| V10 | MED | Runtime emits zaki_app-specific frontend-shaped events. | `docs/ROADMAP.md` v2.1.0 names `gateway_run_events.zig` surface. | v2.1.0 | H/I | INTAKE |
| B10 | LOW | Local-first/on-prem deployment story missing. | No dedicated make target/config preset doc. | V-infinity | TBD | OPEN |

## Missing Source Import

The original 67-row file-by-file audit is not present as a per-finding
document in the active docs tree. Before v1.14.18 can tag, import the original
rows into this ledger or replace the 67-count claim with the verified rows
above. Until that happens, the count is useful for prioritization but not for
closure accounting.

## Closure Template

When closing a row, replace `Status` with:

`CLOSED <commit>` — for code/doc fixes.

`DEFERRED <deferred-register id>` — for parked work with rationale and ETA.

`OBSOLETE <commit>` — only after archaeology shows the original intent is dead
and the commit explains the successor or feature-kill rationale.
