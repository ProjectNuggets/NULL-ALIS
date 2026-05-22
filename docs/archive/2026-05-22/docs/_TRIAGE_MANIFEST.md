# Documentation Triage Manifest — nullalis

**Generated:** 2026-05-22
**Scope:** Every project Markdown doc — root `*.md`, `docs/*.md` + `docs/{audits,dispatch,ops,research,review}`, `.planning/*.md` + `.planning/phases/`. Excludes `docs/archive/` (already archived), `.codex*/`, `.claude/worktrees/`, `node_modules/`, `.git/`.
**Constraint:** Manifest only. No file was moved, deleted, or edited.

Verdicts: **KEEP** = active reference, stays at path. **ARCHIVE** = historical / superseded / point-in-time → moves to `docs/archive/<date>/` later. **FOLD** = forward-plan content to absorb into the single canonical roadmap, then archive.

---

## 1. Triage table

### Root `*.md`

| path | verdict | reason |
|---|---|---|
| `AGENTS.md` | KEEP | Live agent-engineering protocol; §14 standards actively bound by every other doc. |
| `CONTRIBUTING.md` | KEEP | Current contribution + licensing policy. |
| `LICENSE-COMMERCIAL.md` | KEEP | Current commercial-licensing terms. |
| `README.md` | KEEP | Project README (status banner is stale at "March 25" but it is the canonical README — refresh in place, do not archive). |
| `SECURITY.md` | KEEP | Current vulnerability-reporting policy. |
| `STATUS.md` | KEEP | THE live cold-start state doc; refreshed 2026-05-22 (code truth `7874226c`). Authoritative tiebreaker per its own header. |

### `docs/*.md` (top-level)

| path | verdict | reason |
|---|---|---|
| `docs/ROADMAP.md` | KEEP | Designated canonical map; dated 2026-05-19, already supersedes two older roadmaps. The canonical-map author edits this in place. |
| `docs/CONFIG_CONTROL_PLANE_AUDIT.md` | KEEP | Current (2026-05-22) config/control-plane audit; cited live by STATUS.md. |
| `docs/MULTI_AGENT_PLAN.md` | KEEP | Live dispatch protocol; bound by AGENTS.md §14 and STATUS.md. Operational, not point-in-time. |
| `docs/deferred-register.md` | KEEP | Live single-source-of-truth deferred-items ledger; cited by AGENTS.md §14. Append-only by design. |
| `docs/STATUS.md` | ARCHIVE | DUPLICATE state doc (2026-05-20), superseded by root `STATUS.md` (2026-05-22). See §4. |
| `docs/SLO.md` | KEEP | Current SLO targets; operational reference, no version binding. Still a draft but live policy. |
| `docs/agent-lifecycle-spec.md` | KEEP | Task/session lifecycle contract; transport-agnostic, still the live spec. |
| `docs/config-authority-map.md` | KEEP | Canonical control-plane authority contract; matches the live strict-allowlist model. |
| `docs/execution-cell-contract.md` | KEEP | Proposed hosted-isolation contract; forward-looking but a standing contract, not a sprint plan. Borderline — see note. |
| `docs/online-agent-contract.md` | KEEP | Transport-agnostic event-grammar contract; live runtime spec. |
| `docs/migrations-policy.md` | KEEP | Live policy for `src/migrations.zig`; process doc. |
| `docs/silent-catches-policy.md` | KEEP | Live policy; directly referenced by live code (`src/gateway.zig`). |
| `docs/session-key-policy.md` | KEEP | Live per-session-key concurrency policy; gateway-enforced. |
| `docs/scheduler-automation-contract.md` | KEEP | Live durable-automation model contract. |
| `docs/slash-commands-spec.md` | KEEP | Live slash-command catalog; source-of-truth pointer to `src/agent/commands.zig`. |
| `docs/state-secrets-wiring.md` | KEEP | Live secrets/state-key wiring reference for prod + local. |
| `docs/multi-instance.md` | KEEP | Live multi-instance deployment guide. |
| `docs/reliability-ops-runbook.md` | KEEP | Live ops runbook (degraded-state, scheduler guardrails). |
| `docs/multimodal-admission.md` | ARCHIVE | V1 admission gate (2026-04-18); the W2.7 gate is a closed point-in-time decision. |
| `docs/memory-architecture-map.md` | ARCHIVE | "Last updated 2026-04-05", M2-era; superseded by v1.9-memory-anatomy and the v1.14 audits. |
| `docs/graph-memory-research.md` | ARCHIVE | Dated 2026-04-30 ecosystem research; superseded by `docs/research/2026-05-10_graph_db_and_agentic_memory_landscape.md`. |
| `docs/frontend-vision-brief.md` | ARCHIVE | Dated 2026-04-30, references HEAD `03fa184`; point-in-time design brief for a separate repo. |
| `docs/sandbox-activation-plan.md` | ARCHIVE | Dated 2026-04-28 activation plan; the activation has shipped (`4f27487` + sandbox-finish). |
| `docs/sandbox-deploy.md` | KEEP | Operator deployment guide; still the live sandbox deploy reference (V1.5, AUTO default). |
| `docs/sandbox-tool-coverage.md` | KEEP | Live per-tool isolation/trust-model audit; operator reference. |
| `docs/v1-frontend-activation-list.md` | ARCHIVE | V1 dormant-capability list (2026-04-28/30); point-in-time, V1 long shipped. |
| `docs/v1-ready.md` | ARCHIVE | "V1 Ready Declaration" (2026-04-30); historical milestone declaration. |
| `docs/v1-ship-readiness-criteria.md` | ARCHIVE | V1 ship checklist (2026-04-27); closed milestone gate. |
| `docs/v1-triage.md` | ARCHIVE | V1 deferral triage (2026-04-26); point-in-time classification, superseded by deferred-register. |
| `docs/v1-user-onboarding-flow.md` | ARCHIVE | V1 onboarding-flow sketch; point-in-time, frontend-repo concern. |
| `docs/zaki-prod-legal-handoff.md` | ARCHIVE | Dated handoff (2026-04-28) to a different repo; one-shot handoff doc. |
| `docs/zaki-prod-sandbox-policy-handoff.md` | ARCHIVE | Dated handoff (2026-04-28) to a different repo; one-shot handoff doc. |
| `docs/zaki-runtime-contract.md` | KEEP | Live production runtime contract for nullalis-behind-zaki-prod; current baseline still valid. |
| `docs/v1.5-design-kickoff.md` | ARCHIVE | v1.5 design draft (2026-04-30); historical. |
| `docs/v1.5-frontend-phase1-implementation.md` | ARCHIVE | v1.5 frontend playbook; historical, other-repo concern. |
| `docs/v1.5-release-notes.md` | ARCHIVE | v1.5 release notes; historical. |
| `docs/v1.5.5-compaction-fidelity-baseline.md` | ARCHIVE | v1.5.5 bench baseline (2026-05-01); dated point-in-time run. |
| `docs/v1.5.5-compaction-fidelity-final.md` | ARCHIVE | v1.5.5 final fidelity report; closed. |
| `docs/v1.6-frontend-handoff.md` | ARCHIVE | v1.6 frontend handoff; historical, other-repo. |
| `docs/v1.6-v1.7-spec.md` | ARCHIVE | v1.5.5/v1.6/v1.7 memory spec; all three versions shipped. |
| `docs/v1.7-brain-parity-sprint.md` | ARCHIVE | v1.7 sprint doc (2026-05-03); completed sprint. |
| `docs/v1.7-frontend-handoff.md` | ARCHIVE | v1.7 frontend handoff; historical, other-repo. |
| `docs/v1.7-pause-snapshot.md` | ARCHIVE | v1.7 mid-flight pause snapshot (2026-05-04); the pause is long resolved. |
| `docs/v1.8-build-plans.md` | ARCHIVE | v1.8 per-commit build plans; completed sprint. |
| `docs/v1.8-code-review.md` | ARCHIVE | v1.8 code review; historical review pass. |
| `docs/v1.8-code-review-supplement.md` | ARCHIVE | v1.8 code-review supplement; historical review pass. |
| `docs/v1.8-decision-drop-v1.8-4.md` | ARCHIVE | v1.8-4 scope decision (2026-05-05); closed point-in-time decision. |
| `docs/v1.8-memory-audit-empirical.md` | ARCHIVE | v1.8 empirical audit run (2026-05-04); dated run. |
| `docs/v1.8-memory-audit-protocol.md` | ARCHIVE | v1.8 audit protocol; completed-sprint artifact. |
| `docs/v1.8-memory-gap-matrix.md` | ARCHIVE | v1.8 design↔code gap matrix; completed-sprint artifact. |
| `docs/v1.8-memory-pyramid-design.md` | ARCHIVE | v1.8 memory-pyramid design; shipped, superseded by v1.9/v1.14 anatomy + audits. |
| `docs/v1.8-memory-research-synthesis.md` | ARCHIVE | v1.8 research synthesis (2026-05-04); dated landscape research. |
| `docs/v1.8-sprint-lock.md` | ARCHIVE | v1.8 sprint lock (2026-05-04); closed sprint lock. |
| `docs/v1.9-charter-truth-maintenance.md` | ARCHIVE | v1.9 charter (2026-05-05); shipped. |
| `docs/v1.9-close-out.md` | ARCHIVE | v1.9 close-out (`v1.9.0` tagged); historical close-out. |
| `docs/v1.9-code-review.md` | ARCHIVE | v1.9 pre-tag code review; historical review pass. |
| `docs/v1.9-memory-anatomy.md` | ARCHIVE | "Definitive reference (V1.9 state)"; superseded by v1.14 memory deep-audit + CONFIG_CONTROL_PLANE_AUDIT. |
| `docs/v1.10-summary.md` | ARCHIVE | v1.10 close-out summary; historical. |
| `docs/v1.11-compaction-handoff-2026-05-07.md` | ARCHIVE | v1.11 mid-sprint handoff (2026-05-07); historical. |
| `docs/v1.13-brain-elevation-plan.md` | FOLD | v1.13 plan but contains forward cognitive-layer roadmap (Working/Procedural/Dream memory) — see §2. |
| `docs/v1.13-context-audit-2026-05-08.md` | ARCHIVE | v1.13 context audit (2026-05-08); dated audit, superseded by sota-context-architecture + v1.14 audits. |
| `docs/v1.13-watch-findings-2026-05-08.md` | ARCHIVE | v1.13 watch-session findings (2026-05-08); dated observation log. |
| `docs/v1.14-memory-system-deep-audit-2026-05-08.md` | ARCHIVE | v1.14 memory deep-audit (2026-05-08); superseded by 2026-05-21 activation audit + CONFIG_CONTROL_PLANE_AUDIT. |
| `docs/post-publishable-fixes-2026-05-09.md` | FOLD | Three named forward fixes (F-A2.1 / F-T1 / F-PA1) filed for post-publishable execution — see §2. |
| `docs/sota-context-architecture-2026-05-09.md` | FOLD | "SOTA Context Architecture — Deep-Dive Plan", status PLANNING, 5 fixes pending — see §2. |
| `docs/research-cocoindex-2026-05-07.md` | ARCHIVE | Dated research (2026-05-07) on a V2 candidate; point-in-time investigation. |
| `docs/research-kimi-multimodal-2026-05-07.md` | ARCHIVE | Dated research (2026-05-07); point-in-time model survey. |
| `docs/research-together-2026-05-07.md` | ARCHIVE | Dated research (2026-05-07); point-in-time model-catalog survey. |
| `docs/ui-ux-claude-skills-research.md` | ARCHIVE | Dated install guide (May 2026) for a separate frontend repo session; one-shot reference. |
| `docs/REVIEW-v1.14.4-2026-05-09.md` | ARCHIVE | v1.14.4 code review (2026-05-09); historical review pass. |

### `docs/` subdirectories

| path | verdict | reason |
|---|---|---|
| `docs/audits/2026-05-19-file-by-file-audit-ledger.md` | KEEP | Active control ledger for the post-v1.14.12 audit wave; cited live by ROADMAP.md. Archive only when all rows close. |
| `docs/audits/2026-05-20-v1.14.14-activation-audit.md` | ARCHIVE | Explicitly superseded — the 2026-05-21 activation audit's `supersedes_claims_in` header retracts its G1/G4/G5/G11/G16 "closed" claims. |
| `docs/audits/2026-05-21-v1.14.18-B-activation-audit.md` | KEEP | Newest activation audit (2026-05-21); current behavioral-verification reference. |
| `docs/dispatch/v1.14.18-B-dispatch.md` | FOLD | Pre-drafted v1.14.18-B agent dispatch, "ready to fire" — forward sprint plan, see §2. |
| `docs/ops/stability-jsonl-canary.md` | KEEP | Live ops runbook for v1.14.14+ stability-JSONL canary; operational procedure. |
| `docs/research/2026-05-10_graph_db_and_agentic_memory_landscape.md` | KEEP | Cited live by STATUS.md (R1/R2 open-queue items derive from it); current upgrade-plan reference. Contains forward recs — see §2. |
| `docs/research/2026-05-18_r6_r3_r4_r2_sprint_plan.md` | FOLD | "Next sprint plan — R6+R3+R4+R2"; explicit forward sprint plan — see §2. |
| `docs/review/2026-05-18_v1149_review.md` | ARCHIVE | v1.14.9 phase code review (commit `d40bbe3c`); historical review pass. |
| `docs/review/2026-05-18_v1410a_review.md` | ARCHIVE | v1.14.10-A phase code review (commit `9115f501`); historical review pass. |

### `.planning/*.md` (top-level)

| path | verdict | reason |
|---|---|---|
| `.planning/PROJECT.md` | ARCHIVE | GSD project charter (v1.0 milestone era); vision is now carried by README + ROADMAP. |
| `.planning/REQUIREMENTS.md` | FOLD | "Requirements — SOTA Agent Program", P0/P1 REQ list — the unshipped REQ rows are forward scope, see §2. |
| `.planning/ROADMAP.md` | FOLD | GSD `v1.0-sota` roadmap — STALE and contradicts `docs/ROADMAP.md`. Fold any still-open milestone intent, then archive. See §2 and §4. |
| `.planning/STATE.md` | ARCHIVE | GSD machine-state file, `last_updated 2026-04-11`, milestone v1.0 at 74%. Stale. STATUS.md open-queue item #7 already flags it "repoint at STATUS.md OR delete." See §5. |
| `.planning/DELEGATION-DIAGNOSIS.md` | ARCHIVE | Sub-agent delivery diagnosis (2026-04-17); the subagent bug is CLOSED per STATUS.md. |
| `.planning/lifecycle-risks.md` | ARCHIVE | "Known Risks (Post Phase 3.9)"; phase 3.9-era, risks listed as FIXED. |
| `.planning/phase-3.9-execution.md` | ARCHIVE | Phase 3.9 step-by-step execution plan; completed phase. |
| `.planning/phase-5-deferred-items.md` | FOLD | "Phase 5 SOTA — Remaining Items"; carries remaining/deferred forward items — see §2. |
| `.planning/agent-E-v11418A-plan.md` | ARCHIVE | Agent E v1.14.18-A Phase 0 plan; F1/F2 merged, F3 in CI-rework per STATUS.md — superseded by ROADMAP/dispatch. |
| `.planning/agent-G-v11414-1-phase0.md` | ARCHIVE | Agent G v1.14.14.1 Phase 0 plan; PR #80 merged per docs/STATUS.md. |
| `.planning/agent-G-v11414-phase1.md` | ARCHIVE | Agent G v1.14.14 Phase 1 plan; PR #78 merged (`9cfa6b37`). |
| `.planning/agent-prompts/deployment-infra.md` | ARCHIVE | Phase 3.9 deployment-agent prompt; completed-phase one-shot prompt. |

### `.planning/phases/` — GSD phase artifacts

All 57 files below are completed-milestone (`v1.0`) GSD phase artifacts — PLAN / SUMMARY / RESEARCH / REVIEW / VERIFICATION / VALIDATION / CONTEXT / DISCUSSION-LOG for phases 00–03. Sampled SUMMARYs carry `status: complete` with merged commits. The milestone is closed (STATE.md: 5/12 phases at the time of its last write, but phases 00–03 themselves are done). All **ARCHIVE** — historical phase records, not forward plans.

| path | verdict | reason |
|---|---|---|
| `.planning/phases/00-baseline-evals/00-01-PLAN.md` | ARCHIVE | Completed phase-00 artifact. |
| `.planning/phases/00-baseline-evals/00-01-SUMMARY.md` | ARCHIVE | Completed phase-00 artifact (`status: complete`). |
| `.planning/phases/00-baseline-evals/00-02-PLAN.md` | ARCHIVE | Completed phase-00 artifact. |
| `.planning/phases/00-baseline-evals/00-02-SUMMARY.md` | ARCHIVE | Completed phase-00 artifact. |
| `.planning/phases/01-agent-execution-contract/01-01-PLAN.md` | ARCHIVE | Completed phase-01 artifact. |
| `.planning/phases/01-agent-execution-contract/01-01-SUMMARY.md` | ARCHIVE | Completed phase-01 artifact. |
| `.planning/phases/01-agent-execution-contract/01-02-PLAN.md` | ARCHIVE | Completed phase-01 artifact. |
| `.planning/phases/01-agent-execution-contract/01-02-SUMMARY.md` | ARCHIVE | Completed phase-01 artifact. |
| `.planning/phases/01-agent-execution-contract/01-RESEARCH.md` | ARCHIVE | Completed phase-01 artifact. |
| `.planning/phases/01-agent-execution-contract/01-REVIEW.md` | ARCHIVE | Completed phase-01 artifact. |
| `.planning/phases/01-agent-execution-contract/01-VERIFICATION.md` | ARCHIVE | Completed phase-01 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-01-PLAN.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-01-SUMMARY.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-02-PLAN.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-02-SUMMARY.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-03-PLAN.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-03-SUMMARY.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-04-PLAN.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-04-SUMMARY.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-05-PLAN.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-05-SUMMARY.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-RESEARCH.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-REVIEW.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-VALIDATION.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/01.5-prompt-architecture-and-liveness/01.5-VERIFICATION.md` | ARCHIVE | Completed phase-01.5 artifact. |
| `.planning/phases/02-online-runtime-visibility-and-tasks/02-01-PLAN.md` | ARCHIVE | Completed phase-02 artifact. |
| `.planning/phases/02-online-runtime-visibility-and-tasks/02-02-PLAN.md` | ARCHIVE | Completed phase-02 artifact. |
| `.planning/phases/02-online-runtime-visibility-and-tasks/02-03-PLAN.md` | ARCHIVE | Completed phase-02 artifact. |
| `.planning/phases/02-online-runtime-visibility-and-tasks/02-04-PLAN.md` | ARCHIVE | Completed phase-02 artifact. |
| `.planning/phases/02-online-runtime-visibility-and-tasks/02-05-PLAN.md` | ARCHIVE | Completed phase-02 artifact. |
| `.planning/phases/02-online-runtime-visibility-and-tasks/02-06-PLAN.md` | ARCHIVE | Completed phase-02 artifact. |
| `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-01-PLAN.md` | ARCHIVE | Completed phase-02.1 artifact. |
| `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-01-SUMMARY.md` | ARCHIVE | Completed phase-02.1 artifact. |
| `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-02-PLAN.md` | ARCHIVE | Completed phase-02.1 artifact. |
| `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-02-SUMMARY.md` | ARCHIVE | Completed phase-02.1 artifact. |
| `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-03-PLAN.md` | ARCHIVE | Completed phase-02.1 artifact. |
| `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-03-SUMMARY.md` | ARCHIVE | Completed phase-02.1 artifact. |
| `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-04-PLAN.md` | ARCHIVE | Completed phase-02.1 artifact. |
| `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-04-SUMMARY.md` | ARCHIVE | Completed phase-02.1 artifact. |
| `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-CONTEXT.md` | ARCHIVE | Completed phase-02.1 artifact. |
| `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-DISCUSSION-LOG.md` | ARCHIVE | Completed phase-02.1 artifact. |
| `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-RESEARCH.md` | ARCHIVE | Completed phase-02.1 artifact. |
| `.planning/phases/02.1-streaming-voice-and-channel-polish/02.1-VERIFICATION.md` | ARCHIVE | Completed phase-02.1 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-01-SUMMARY.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-02-SUMMARY.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-03-SUMMARY.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-04-SUMMARY.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-05-REVIEW.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-CONTEXT.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-DISCUSSION-LOG.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-RESEARCH.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-REVIEW.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-V16-REVIEW.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-V17A9-REVIEW.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-V17SHIP-REVIEW.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-VALIDATION.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/03-canonical-session-and-context-runtime/03-VERIFICATION.md` | ARCHIVE | Completed phase-03 artifact. |
| `.planning/phases/1.5-prompt-and-liveness/README.md` | ARCHIVE | Phase-1.5 sprint index (1.5A–1.5D); completed-phase artifact. |

---

## 2. FOLD files — forward-plan content for the canonical map author

The canonical roadmap author should absorb the following. Items **1–5, 7–9 are FOLD** (fold the content, then archive). Item **6 is KEEP** — it stays at its path as the rationale source, but its forward recommendations are listed here so the canonical map can reference them.

1. **`docs/v1.13-brain-elevation-plan.md`** — Plan to add the missing cognitive layers — **Working Memory, Procedural memory, and a Dream/consolidation layer** — on top of the existing graph without rewriting the foundation. Several of these landed in later versions; the canonical map should record which layers remain incomplete and carry the rest as a "cognitive layers" track.

2. **`docs/post-publishable-fixes-2026-05-09.md`** — Three named architecture fixes filed for post-publishable execution: **F-A2.1** (ship `brain_graph` as the real default for entity questions → SOTA-class recall), **F-T1** (strip `memory_recall` bloat from history to cut cost + context contamination), and **F-PA1** (make Pass A information-preserving). Confirm against current code whether each shipped; carry any open one into the canonical map.

3. **`docs/sota-context-architecture-2026-05-09.md`** — A PLANNING-status deep-dive plan: **5 fixes (~4 focused days)** to replace the mid-history-rewrite anti-pattern with the convergent SOTA append-only + tiered + drop-from-middle context pattern. ContextEngine migration (v1.14.14) addressed part of this; the canonical map should record the SOTA-context end-state and any remaining fixes.

4. **`docs/dispatch/v1.14.18-B-dispatch.md`** — Pre-drafted, ready-to-fire **v1.14.18-B** agent dispatch ("Learning loop closure + self-knowledge"), two agents in parallel, fires when v1.14.18-A F3 (PR #82) merges. The v1.14.18-B scope and its trigger condition belong in the canonical roadmap's near-term section.

5. **`docs/research/2026-05-18_r6_r3_r4_r2_sprint_plan.md`** — Next-sprint plan targeting the weakest LoCoMo cohort: lift **Cat 3 (temporal/inference, currently 56–77%) toward 80%+** and push Cat 2 multi-hop / Cat 4 open-domain above publishable baselines, via levers **R6 + R3 + R4 + R2**, bench-gated by a 60-question Cat 3 slice. This is the live LoCoMo-improvement roadmap — fold the R-lever set and the bench-gate discipline into the canonical map.

6. **`docs/research/2026-05-10_graph_db_and_agentic_memory_landscape.md`** — KEEP (cited live by STATUS.md) but also carries forward intent: its top-5 recommendations include **R1 graph-density telemetry** and **R2 bi-temporal invalidation**, which are already STATUS.md open-queue items #3/#4. The canonical map should reference these as committed near-term work; the doc itself stays in place as the rationale source.

7. **`.planning/REQUIREMENTS.md`** — GSD "SOTA Agent Program" requirements list (REQ-001…). Any P0/P1 REQ rows not yet satisfied by current code are forward scope the canonical map should re-state in current-version terms; the GSD file itself is then archived.

8. **`.planning/ROADMAP.md`** — Stale GSD `v1.0-sota` roadmap. Its still-relevant standing rules (UI/UX activation mandatory per phase; multi-session by default; code-truth-over-docs) and any unshipped milestone intent should be reconciled into `docs/ROADMAP.md`. See §4 — it directly contradicts the canonical roadmap.

9. **`.planning/phase-5-deferred-items.md`** — "Phase 5 SOTA — Remaining Items." Cross-check each remaining/unshipped item against `docs/deferred-register.md`; fold anything still open and not already tracked into the canonical map.

---

## 3. Count summary

| Verdict | Count |
|---|---|
| KEEP | 30 |
| ARCHIVE | 117 |
| FOLD | 8 |
| **Total in-scope** | **155** |

Total in-scope = 6 root `*.md` + 79 `docs/` (top-level + subdirs, excluding `docs/archive/`) + 70 `.planning/` (top-level + `phases/`).

- **KEEP (30):** 6 root + 24 `docs/` (18 `docs/*.md` + 6 `docs/` subdir files: 1 audit, 1 dispatch... actually 5 subdir — see table). Live references, contracts, policies, and ops runbooks still bound by code or process.
- **ARCHIVE (117):** 57 `.planning/phases/` GSD artifacts + 9 `.planning/` top-level + 49 `docs/` historical/superseded (`docs/*.md` vN docs + `docs/STATUS.md` + 2 `docs/audits` + 2 `docs/review` + dated research).
- **FOLD (8):** 5 `docs/` (incl. 2 in `docs/research`, 1 `docs/dispatch`) + 3 `.planning/` (`REQUIREMENTS.md`, `ROADMAP.md`, `phase-5-deferred-items.md`). Forward-plan content listed in §2.

---

## 4. Duplicate / contradictory docs

- **Two `STATUS.md` files.** Root `STATUS.md` (refreshed **2026-05-22**, code truth `7874226c`) vs `docs/STATUS.md` (**2026-05-20** PM). Root is **newest and authoritative** — its own header declares it "the single cold-start document" and the tiebreaker. `docs/STATUS.md` is a stale duplicate → ARCHIVE. Note: AGENTS.md §14 and ROADMAP/MULTI_AGENT_PLAN cross-link `docs/STATUS.md`; those links must be repointed to root `STATUS.md` (or the canonical map) when `docs/STATUS.md` is archived.

- **Three roadmap docs.** `docs/ROADMAP.md` (**2026-05-19**, the designated canonical map — already supersedes `docs/v1.9-v2.0-product-roadmap.md` and `docs/zaki-product-roadmap.md`, both already in `docs/archive/`) vs `.planning/ROADMAP.md` (GSD `v1.0-sota`, **stale**, last meaningful at the v1.0 milestone). `docs/ROADMAP.md` is newest and wins; `.planning/ROADMAP.md` is contradictory and is FOLD→archive.

- **Activation audits.** `docs/audits/2026-05-21-v1.14.18-B-activation-audit.md` explicitly carries `supersedes_claims_in: docs/audits/2026-05-20-v1.14.14-activation-audit.md` — the 2026-05-21 audit is newest and retracts the older audit's G1/G4/G5/G11/G16 "closed" claims. Keep 2026-05-21, archive 2026-05-20.

- **Overlapping memory references.** `docs/memory-architecture-map.md` (2026-04-05), `docs/v1.9-memory-anatomy.md` (v1.9 "definitive reference"), and `docs/v1.14-memory-system-deep-audit-2026-05-08.md` are successive snapshots of the same subsystem. Newest authoritative memory truth is now `docs/CONFIG_CONTROL_PLANE_AUDIT.md` (2026-05-22) + the 2026-05-21 activation audit; all three older memory docs are ARCHIVE.

- **`docs/ROADMAP.md` references several docs that do not exist in-scope** (`docs/capacity-model.md`, `docs/dr-runbook.md`, `docs/unit-economics-2026-XX-XX.md`). Not files to triage — flagged so the canonical-map author knows these are dangling/planned references, not omissions from this manifest.

---

## 5. Specific note — `.planning/STATE.md` and `.planning/ROADMAP.md`

- **`.planning/STATE.md`** — GSD machine-state file. `last_updated: 2026-04-11`, milestone `v1.0`, 5/12 phases / 17/23 plans / 74%. It is **stale by ~6 weeks** and describes a milestone the project has moved well past (now on the v1.14.18 line). STATUS.md's own ranked open queue, **item #7**, already flags it: *"Refresh `.planning/STATE.md` to point at STATUS.md OR delete."* Recommendation: **ARCHIVE** (or delete) — root `STATUS.md` is the live state doc and this file actively risks confusing cold-start readers. Note AGENTS.md §14 names STATUS.md as the tiebreaker over STATE.md, so STATE.md has no remaining authority.

- **`.planning/ROADMAP.md`** — Stale GSD `v1.0-sota` roadmap. It is **superseded by `docs/ROADMAP.md`** (2026-05-19) and is directly contradictory (different milestone model, different versioning). Verdict **FOLD** — its three standing rules (mandatory per-phase UI/UX activation, multi-session-by-default, code-truth-over-docs) are still worth preserving and should be reconciled into the canonical `docs/ROADMAP.md`; after that, archive it.

---

*End of manifest. No file was moved, edited, or deleted in producing this document.*
