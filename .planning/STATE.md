# State — SOTA Agent Program

## Current Phase
Phase 0: Baseline and Safety Net — COMPLETE
Next: Phase 1 (Agent Execution Contract) then Phase 1.5 (Prompt Architecture and Liveness)

## Current Plan
Phase 0 complete. Ready for Phase 1.

## Phase 0 Results
- 00-01: 26 characterization tests added (e0ce57d), 5045/5076 pass, 0 fail
- 00-02: 3 documentation artifacts created (60471d9), no runtime changes

## Decisions Log

### 2026-04-10: Phase 1.5 added — Prompt Architecture and Liveness
- Agent review flagged "feels alive" as the biggest gap vs Claude Code
- Added Phase 1.5 between Phase 1 and Phase 2 with 5 sprints:
  - 1.5A: Prompt scaffold refactor (composable sections)
  - 1.5B: Liveness narration engine (real-time user-facing status)
  - 1.5C: Task decomposition (visible sub-steps for complex requests)
  - 1.5D: Learning loop (correction detection, preference storage)
  - 1.5E: Persona calibration (SOUL.md, warmth/proactivity dimensions)
- Docs tightened per code review: transport-agnostic contracts, token has no type field,
  queued->running is markTaskRunning not Thread.spawn, session fallback is subagent:<id>,
  cron is daemon-driven not gateway chat-stream
- Requirements expanded: REQ-018 through REQ-022 cover P0.5 "feels alive" tier
- Program now 8 phases, 33 sprints, 29 branches in dependency graph

### 2026-04-09: Program bootstrap
- Competitive analysis complete (Claude Code + OpenClaw + nullalis)
- Feature map updated with F1-F15 plus F1.5A-F1.5B
- Roadmap has 33 sprints across 8 phases (0, 1, 1.5, 2-6)
- GSD execution harness adopted for context-isolated sprint execution
- Gateway decomposition recommended before Phase 2 (optional)
- 14 of 28 sprints need frontend UI work

### Architecture Locks
1. Zig runtime core — no language change
2. Postgres canonical state — filesystem is mirror/fallback
3. Per-user cell pods — tenant isolation model stays
4. SSE primary transport — WebSocket only where channel requires it
5. Tool vtable interface — layer metadata beside it, don't mutate every call site
6. Additive API only — no breaking changes

### Known Risks
1. gateway.zig at 15,599 lines — merge conflict risk for parallel sprints
2. 8 sprints touch shared-core files — must serialize
3. Frontend coupling — 14 sprints need UI work to activate features
4. Eval infrastructure quality determines whether "SOTA" is measurable

## Blockers
None currently.

## Cross-Session Memory
- M1 (Kernel UX) complete and merged to main
- M2 (Context Introspection) complete and merged to main
- Build commands: `zig build test --summary all`, `zig build -Doptimize=ReleaseSmall`
- 189,005 lines across 188 .zig files
- 1,500+ inline tests
