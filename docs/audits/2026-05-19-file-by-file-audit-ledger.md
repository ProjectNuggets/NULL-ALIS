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
| B1 | MED | AGENTS repository map named missing `src/skillforge.zig`. | Fixed in docs by naming `src/skills.zig`; verify before commit. | v1.14.13 Step 0.5 | E | OPEN |
| B2 | MED | Bench harness lacks TTFT p50/p95 columns despite SLO target. | `.spike/results.tsv` header has no `p50_ttft_ms` / `p95_ttft_ms`; `.spike/run.sh` only reports mean latency. | v1.14.13 Step 7 | D | CLOSED 015dc461 |
| B13 | MED | Test MaxRSS budget currently exceeds AGENTS target. | `zig build test --summary all` on 2026-05-19 reports MaxRSS 61M; AGENTS budget is <50 MB. | v1.14.13 Step 8 | A/D/E as assigned | OPEN |
| F-A2 | MED | `brain_graph` prompt directive is known ignored by bench and still emitted. | `src/agent/prompt.zig:854-859` | v1.14.13 Step 4 | E | OPEN |
| HND-READY | MED | `handleReady` has tests but no production route caller. | `src/gateway.zig:2849`; references at test lines only. | v1.14.13 Step 5 | E | OPEN |
| EMPTY-TURN | MED | `EMPTY_TURN_PLACEHOLDER` remnants still exist after structured tool-only turn work. | `src/gateway.zig:57`; stale docs/comments in `src/observability.zig:87` and related refs. | v1.14.13 Step 5 | E | OPEN |
| BROWSER-HONESTY | MED | Browser tool advertises unimplemented `screenshot`, `click`, `type`, `scroll`. | `src/tools/browser.zig:13-20` plus failure branches. | v1.14.13 Step 5 | E | OPEN |
| BIRTHDAY-DOC | LOW | `predicateToSlotType` docs say BIRTHDAY does not promote, code promotes it to temporal. | `src/agent/extraction_persist.zig:1105-1143` | v1.14.13 Step 5 | E | OPEN |
| IDENTITY-ORPHAN | LOW | `src/identity.zig` needs keep/document/delete disposition. | File exists; roadmap requires Nova decision. | v1.14.13 Step 6 | E | OPEN |
| SCHEMA-WIRE | HIGH | `src/tools/schema.zig` exists but provider serialization does not call `cleanSchemaForProvider`. | `rg cleanSchemaForProvider src/providers` returns no provider usage. | v1.14.13 Step 2 | F | OPEN |
| TASK-PLANNER-WIRE | HIGH | `<task_plan>` directive exists, parser module is only reexported, not used in turn loop. | `src/agent/root.zig:5396-5399`; no runtime parse call. | v1.14.13 Step 3 | F | OPEN |
| NARRATION-WIRE | MED | `NarrationObserver` exists with tests but is not wired to channel/front-end rendering. | `src/agent/narration.zig`; only reexport in `root.zig`. | v1.14.13 Step 3 | F | OPEN |
| CONTEXT-ENGINE | HIGH | `ContextEngine` phases exist but production turn loop is still inline. | `src/agent/context_engine.zig`; roadmap migration needed. | v1.14.14 | G | OPEN |
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
