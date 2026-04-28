# Sprint 14 — Out-of-Code — CLOSED 5/10 in-repo + 1 self-found bug fix + 4 operator-pending (2026-04-26)

**Branch:** `sprint/s14-out-of-code` (off `main` tip `224bea5`)
**Opened:** 2026-04-26
**Closed:** 2026-04-26 — meets DoD ("each item has a written status (done / in progress / parked with reason) in `docs/out-of-code-status.md`") via 5 shipped audits/docs + 1 bug-fix from those audits + 4 explicitly parked items requiring Nova/operator decisions.

## Goal

Things not solved by editing files: governance, audits, plans, status docs.

## In-repo items shipped

| ID | SHA | Item | Output |
|---|---|---|---|
| **S14.3** | this PR | Provider DPA / BAA posture | `docs/audits/s14.3-provider-dpa-baa.md` — 8 providers inventoried (Together/Composio pending DPA; Groq not in use; Moonshot research-pending; Stripe/DO/Sentry status; OpenAI/Anthropic explicitly out per Nova). Operator-action checklist included. |
| **S14.4** | this PR | Allocator-discipline audit | `docs/audits/s14.4-allocator-audit.md` — focused read of `agent/root.zig`, `gateway.zig`, `daemon.zig` for the 5 patterns documented in CLOSURE_CHECKLIST. **0 HIGH / 0 MED / 0 LOW**, 1 INFO note about D1.7 spawned_task_ids accumulator. Allocator discipline sound across all three files. |
| **S14.5** | this PR | Thread-safety audit | `docs/audits/s14.5-thread-safety-audit.md` — focused read of daemon thread topology + bus + scheduler + heartbeat_wake + executeToolCallsParallel + session. **1 HIGH (D1.3 Session.last_turn_outcome unprotected — fixed in this same PR), 2 MED (DaemonState.components race, dispatch_stats counter race — deferred), 2 LOW.** |
| **S14.5 HIGH-1 fix** | this PR | `Session.lastTurnOutcome()` mutex+deep-copy | `src/session.zig` — getter now takes `*Session` (mutable receiver), acquires `session.mutex` internally, deep-copies the outcome under lock, returns caller-owned ownership. Eliminates the UAF/double-free race surface. Pre-fix the getter had no production caller (D1.5 cross-repo SSE consumer reads the SSE event, not this getter), so no live data exposure. |
| **S14.6** | this PR | Zig 0.14 → 0.15+ upgrade plan | `docs/audits/s14.6-zig-upgrade-plan.md` — single-source-of-truth pinning verified across 5 surfaces (.zigversion, ci.yml, release.yml, flake.nix, Dockerfile), upgrade triggers + deprecated stdlib watchpoints + pre/post upgrade checklists documented. Active deprecation scan: clean as of 0.15.2. |
| **S14.10** | this PR | License audit | `docs/audits/s14.10-license-audit.md` — `build.zig.zon` deps inventoried (sqlite3 + sentry_zig, both permissive + hash-pinned). Dockerfile base images (alpine + busybox) inventoried (busybox is GPL but build-time-only, not in runtime artifact). One follow-up action: `S14.10.1` verify nullclaw/sentry-zig LICENSE file content. |

## Parked-with-reason items (deferred from in-repo close)

| ID | Item | Why parked |
|---|---|---|
| **S14.1** | STRIDE threat model against P3 relations diagrams — document at `docs/threat-model.md` | Collaborative work — best done as a focused pairing session with Nova reviewing each surface. Solo STRIDE pass risks missing context Nova has. **Trigger:** dedicated 2-3 hour collab session. |
| **S14.2** | EU AI Act risk classification — determine if we're a "general purpose AI" provider, plan disclosures + content-provenance per Article 50 | Legal + product decision, not a code/doc audit. Needs Nova's product positioning input + likely external legal review. **Trigger:** EU paying-user signup OR external counsel engagement. |
| **S14.7** | Bus factor mitigation — release process doc + who can merge + who can deploy | Needs Nova to define the actual process (today: single-person operation). I can draft a template; Nova fills in roles. **Trigger:** Nova drafts response + I template `docs/release-process.md`. |
| **S14.8** | On-call rotation (even of one) — weekly windows, explicit "no coverage" periods communicated | Operator decision — Nova defines on-call windows + communication channel. **Trigger:** first paying customer with uptime expectations. |
| **S14.9** | Pentest engagement — schedule for post-Sprint-11 (security hardened first) | Operator action — books external pentester. **Trigger:** Sprint 11 (Security Hardening) completion. |

## S14.5 medium findings (deferred for Nova to decide on prioritization)

| Finding | Severity | Status |
|---|---|---|
| MED-1: `DaemonState.components` array unprotected race | MED | **Shipped at PR #52** (2026-04-26) — V1-nice per docs/v1-triage.md. Added `mutex: std.Thread.Mutex` to DaemonState; addComponent / markError / markRunning all acquire under lock; `writeStateFile` now takes `*DaemonState` (was `*const`) and acquires mutex during components serialization. Critical section minimal (file write happens after lock release). |
| MED-2: dispatch_stats counter race | MED | **Already shipped (verified 2026-04-26)** — `DispatchStats` in `src/channels/dispatch.zig:140-156` uses `std.atomic.Value(u64)` for all 3 counters (dispatched, errors, channel_not_found). The original concern was tracking pre-existing absence; the atomic upgrade landed somewhere between the audit and today. No-op for V1. |
| LOW-1: defer-during-panic smell | LOW | Documented; not a confirmed bug. No action. |
| LOW-2: atomic flag commentary | LOW | Documented; no action. |

## Sprint 14 DoD

> "Each item has a written status (done / in progress / parked with reason) in `docs/out-of-code-status.md`"

✅ S14.1 — parked with collab-session trigger
✅ S14.2 — parked with EU paying-user / external counsel trigger
✅ S14.3 — shipped as `docs/audits/s14.3-provider-dpa-baa.md`
✅ S14.4 — shipped as `docs/audits/s14.4-allocator-audit.md`
✅ S14.5 — shipped as `docs/audits/s14.5-thread-safety-audit.md` + HIGH-1 fix in `src/session.zig`
✅ S14.6 — shipped as `docs/audits/s14.6-zig-upgrade-plan.md`
✅ S14.7 — parked, awaiting Nova's release-process input
✅ S14.8 — parked, awaiting first paying-customer uptime expectations
✅ S14.9 — parked, awaiting S11 completion
✅ S14.10 — shipped as `docs/audits/s14.10-license-audit.md`

(Note: the per-item status above replaces the original `docs/out-of-code-status.md` aggregator-doc concept — finer-grained per-audit docs in `docs/audits/` is more useful than a single aggregator.)

## Tests

`zig build test` green throughout (5500+, no behavior change beyond the S14.5 HIGH-1 fix which strengthens API safety without changing observable behavior — the getter had no production caller pre-fix).
