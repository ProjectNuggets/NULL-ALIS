# Archive — historical context, not active reference

This directory holds documents superseded by current state. Don't trip on these — they describe past decisions, completed sprints, parked work. Live docs are at `docs/` top level.

## Layout

### `archive/sprints/`
Completed sprints (S1, S2, S3, S4, S5, S6, S7, S8, S10, S14, S15) with their close-out artifacts (review docs, deferred-item ledger entries). The DoD is met; work is shipped. Reference for "how did we close X?" or "what shipped in sprint N?"

Special suffixes:
- `-PARKED.md` (S11, S12, S13) — parked with explicit unpark triggers; not yet executed. See `docs/deferred-register.md` for active status.
- `-MIXED.md` (S16) — partially shipped, partially deferred per item.

D-items (closed-out deferred work):
- `d1-turn-outcome.md` — Sprint D1 TurnOutcome refactor (shipped)
- `d8-secret-vault.md` — Sprint D8 secret vault API (shipped)

### `archive/audits/`
Completed audit deliverables from Sprint 14 (S14.3 DPA posture, S14.4 allocator, S14.5 thread-safety, S14.6 Zig upgrade plan, S14.10 license). One-shot audits with ship dates; not living documents.

### `archive/wave-plans/`
Pre-V1 wave-based planning artifacts. The wave methodology evolved into the closure-checklist + sprint pattern. Kept for traceability.

### `archive/cross-repo/`
Sprint-era zaki-prod companion handoff prompts (PRs #9-#11 era). Closed sprints. Reference for "what was the BFF contract back then?"

### `archive/sessions/`
Self-contained session prompts from the multi-session sprint pattern (Sprint 1 spike runner, D11 DB integration, zaki-prod companion). All sessions completed; PRs merged.

### `archive/releases/`
Historical release-posture freezes: v0.1 declaration (2026-03-18), v0.1 public posture (2026-03-25), v1.1 next-steps plan. Superseded by V1 ship-readiness criteria + V1 triage.

### Top-level files in `archive/`
Older strategy/planning docs from earlier project phases (v0.2, v0.7, plan-v02, v1-productization-plan, etc.). Pre-dates or pre-shipped relative to the current v1 baseline.

## When to consult archive

- Reading commit messages that reference an archived sprint name
- Auditing a decision history ("why did we deprecate X?")
- Onboarding a new contributor showing project evolution

## When NOT to consult archive

- Looking for current state → use `docs/` top-level
- Looking for active deferred work → use `docs/deferred-register.md`
- Looking for V1 ship status → use `docs/v1-ship-readiness-criteria.md`
- Looking for current architecture decisions → use `docs/v1-triage.md` and the various `*-contract.md` files at `docs/` top level

## What stays at `docs/` top level (not archived)

Living documents — updated as state changes:
- `CLOSURE_CHECKLIST.md` (root, not in docs/) — sprint accounting
- `deferred-register.md` — open follow-up items with status
- `v1-ship-readiness-criteria.md` — three-track close gate
- `v1-triage.md` — V1-must / V1-nice / V1.5-defer per item
- `v1-user-onboarding-flow.md` — onboarding spec
- `post-compact-handoff-2026-04-28.md` — current pre/post-compact session bridge
- `slash-commands-spec.md` — slash command catalog + UX spec
- `SLO.md` — service level objectives
- `migrations-policy.md` — schema migration policy
- `agent-lifecycle-spec.md` — agent lifecycle reference
- `memory-architecture-map.md` — memory architecture reference
- `silent-catches-policy.md` — error handling policy
- Various `*-contract.md` and `*-spec.md` — interface contracts (live)

Archive periodically: when a doc's described work is complete and the doc no longer drives any active decision, move it here and update this index.
