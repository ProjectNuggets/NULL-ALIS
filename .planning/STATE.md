# State — SOTA Agent Program

## Current Phase
Phase 02.1: Live Agent Narration Stream (INSERTED after Phase 2)
Status: Not planned yet

## Current Plan
Pending — run /gsd-plan-phase 02.1

## Roadmap Evolution
- Phase 02.1 inserted after Phase 2: Live Agent Narration Stream (URGENT) — stream model reasoning tokens to frontend in real-time during tool-use turns

## Phase 0 Results
- 00-01: 26 characterization tests added (e0ce57d), 5045/5076 pass, 0 fail
- 00-02: 3 documentation artifacts created (60471d9), no runtime changes

## Decisions Log

### 2026-04-10: Phase 2 complete — Online Runtime Visibility and Tasks
- 02-01: RunEventType enum (8 variants), RunEvent tagged union, toSseFrame SSE serializer (REQ-004)
- 02-02: RunEventObserver with FrameSink, translates 6 ObserverEvent types to RunEvent SSE frames
- 02-03: TaskLedger with 7-state machine (queued/running/succeeded/failed/timed_out/cancelled/lost), sweepLost, MAX_TASKS=256 (REQ-005)
- 02-04: TaskDelivery wraps Ledger+Observer, emits task_update ObserverEvent on every state transition; detail truncated to 256 chars (T-02-09)
- 02-05: task_list, task_get, task_stop tools with Tool vtable (REQ-006)
- 02-06: UsageRuntime per-turn recording, session aggregation, ring buffer (MAX_TURNS_TRACKED=1024), /usage wired (REQ-015)
- New ObserverEvent variant: task_update (task_id, status, description) — switch arms in Log/File/Otel observers
- gateway_run_events.zig placed as sibling to gateway.zig (Zig prevents gateway.zig + gateway/ coexistence)
- 69 new tests; 5232/5263 total pass; ReleaseSmall build confirmed

### 2026-04-10: Phase 1.5 Plan 05 complete — Persona calibration
- Warmth/Proactivity named enums + PersonaProfile struct in prompt.zig (REQ-022)
- resolvePersona: O(n) YAML-like front-matter scan, graceful defaults, no allocation
- resolvePersonaFromFile: bounded SOUL.md read (BOOTSTRAP_MAX_CHARS = 20,000)
- buildPersonaSection: ## Persona Calibration header with warmth/proactivity/voice/twin_mode instructions
- Persona section injected before turn classification and safety (T-1.5-10)
- /persona slash command: displays current profile from SOUL.md
- 11 new tests (prompt.zig inline); 5154/5185 total pass; ReleaseSmall build confirmed
- Commits: af072e2 (prompt.zig), fb4eff5 (commands.zig + root.zig wiring)

### 2026-04-10: Phase 1.5 Plan 04 complete — Learning loop
- LearningSignal enum + LearnedFact struct in learning.zig (REQ-021)
- detectLearningSignals: case-insensitive heuristic matching, std.EnumSet deduplication
- factKey: FNV-1a 64-bit hash → durable_fact/behavior/{x:0>16} deterministic key
- extractFactFromMessage: copy for explicit signals; null for implicit-only
- MAX_FACTS_PER_SESSION = 100 (T-1.5-08 DoS mitigation)
- /learn slash command: list filters durable_fact/behavior/ prefix; forget removes by key
- learning module re-exported from agent/root.zig
- 20 new tests (19 inline + 1 reexport); 5143/5174 pass total; ReleaseSmall build confirmed
- Commits: 747ffaa (learning.zig), 38eda4d (commands.zig + root.zig wiring)

### 2026-04-10: Phase 1.5 Plan 03 complete — Task decomposition runtime
- TaskPlan/TaskStep types with step state machine (pending/running/done/failed) in task_planner.zig (REQ-020)
- parseTaskPlan: bounded XML scan (same pattern as dispatcher.zig), null-safe, never panics (T-1.5-05)
- extractTextAndPlan: zero-allocation splitter separating response text from <task_plan> block
- emitStepEvent: narration_frame plan_step events via Observer vtable (wires into Plan 02 narration bus)
- buildTaskDecompositionSection: system prompt instructions with <task_plan> XML format and 4 rules
- Section inserted between turn classification and safety in buildSystemPrompt
- 14 new tests; 5123/5154 pass total; ReleaseSmall build confirmed
- Commits: f03e10a (task_planner.zig), 41e68bf (prompt.zig + root.zig wiring)

### 2026-04-10: Phase 1.5 Plan 02 complete — Liveness narration engine
- NarrationObserver wraps any Observer, translates tool_call_start and turn_stage events into NarrationFrame structs (REQ-019)
- narration_frame variant added to ObserverEvent; NarrationFrameType enum in observability.zig (avoids circular import)
- 12 stage label mappings matching VerboseObserver; dual delivery: callback + event bus
- Safety comment at self.history.append enforces T-1.5-03: narration frames never enter LLM history
- 9 new tests; 5109/5140 pass total; ReleaseSmall build confirmed
- Commits: 568e5a0 (observability + narration.zig), fa8244c (root.zig wiring)

### 2026-04-10: Phase 1.5 Plan 01 complete — Composable prompt scaffold
- buildSystemPrompt decomposed into 5 independent section builders
- PromptSections struct with optional persona/narration/tool_use/learned_facts (REQ-018)
- TurnClass enum (chat/execute/wake/repair/operator) extracted from safety section
- 12 new inline tests; all 5131 tests pass; ReleaseSmall build confirmed
- Commits: 91f5d07 (prompt.zig), 8cf63d5 (root.zig)

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
- 189,005 lines across 188 .zig files (+ narration.zig in 01.5-02, task_planner.zig in 01.5-03, learning.zig in 01.5-04)
- 1,500+ inline tests (5154/5185 passing after 01.5-05)
- Last session stopped at: Completed 01.5-05-PLAN.md (2026-04-10T11:32:37Z)
