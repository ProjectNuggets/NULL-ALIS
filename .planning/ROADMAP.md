# Roadmap — SOTA Agent Program

## Milestone: v1.0-sota

### Rules
1. **UI/UX activation is mandatory** — every phase ends with a ZAKI-Prod frontend prompt that unlocks the code for users. A phase is NOT complete until the feature is user-visible.
2. **Multi-session by default** — no `:main` hardcode. Every session line supports multiple conversations.
3. **Code truth over docs** — if docs and code disagree, code wins. Update docs to match.

### Session Lines
| Line | Key Pattern | Purpose |
|------|------------|---------|
| App | `agent:zaki-bot:user:{id}:thread:{uuid}` | User conversations (many per user) |
| Channels | `telegram:{chatId}`, `discord:{guildId}:{userId}`, etc. | Channel-bound conversations |
| Tasks | `agent:zaki-bot:user:{id}:task:{taskId}` | Background work sessions |
| Cron | `agent:zaki-bot:user:{id}:cron:{jobId}` | Scheduled job sessions |

---

### Phase 0: Baseline and Safety Net ✅ COMPLETE
- [x] 00-01: Baseline evals and characterization tests (e0ce57d)
- [x] 00-02: Online agent contract documentation (60471d9)

### Phase 1: Agent Execution Contract ✅ COMPLETE
**Goal:** Structured tool metadata, execution modes, approval policies, cooperative cancellation
**Requirements:** REQ-001, REQ-002, REQ-003, REQ-010
**Tests:** 5076 passing
**Review:** 6 findings (1 critical, 3 warning, 2 info) — all fixed (de4d7a3)
- [x] 01-01: Tool metadata with ToolFlags packed struct (src/tools/metadata.zig)
- [x] 01-02: Execution modes — plan/execute/review/background (src/agent/execution_mode.zig)
- [x] 01-03: Approval modes — auto_approve/confirm_once/deny (src/security/approval_modes.zig)
- [x] 01-04: Agent reflection policy with informative block messages
- [x] 01-05: Abort and interrupt with CancellationToken (src/agent/abort.zig)

### Phase 1.5: Prompt Architecture and Liveness ✅ COMPLETE
**Goal:** "Feels alive" layer — composable prompts, narration, task decomposition, learning, persona
**Requirements:** REQ-018, REQ-019, REQ-020, REQ-021, REQ-022
**Tests:** 5185 passing (89 new tests)
**Review:** 8 findings (1 critical, 4 warning, 3 info) — all fixed (de4d7a3)
- [x] 01.5-01: Prompt scaffold — 5 section builders, PromptSections, TurnClass enum
- [x] 01.5-02: Narration engine — NarrationObserver, narration_frame events, 12 stage labels
- [x] 01.5-03: Task decomposition — TaskPlan XML parser, step state machine, plan_step events
- [x] 01.5-04: Learning loop — correction detection, durable_fact storage, /learn command
- [x] 01.5-05: Persona calibration — SOUL.md parsing, PersonaProfile, /persona command

### Phase 2: Online Runtime Visibility and Tasks ✅ COMPLETE
**Goal:** Structured run-event stream, durable task ledger, task tools, usage/cost accounting
**Requirements:** REQ-004, REQ-005, REQ-006, REQ-015
**Tests:** 5263 passing (69 new tests)
- [x] 02-01: Run event types — RunEventType enum (8 variants), RunEvent tagged union, toSseFrame
- [x] 02-02: SSE run events — RunEventObserver with FrameSink, 6 event type translations
- [x] 02-03: Task ledger — TaskStatus (7 states), TaskEntry, TaskLedger, sweepLost, MAX_TASKS=256
- [x] 02-04: Task delivery — TaskDelivery wrapping ledger + observer, task_update events
- [x] 02-05: Task tools — task_list, task_get, task_stop with Tool vtable
- [x] 02-06: Usage runtime — UsageRuntime, per-turn recording, ring buffer, /usage command

### Phase 02.1: Streaming, Voice, and Channel Polish ✅ COMPLETE
**Goal:** Progressive streaming, voice-first mode, channel health, security audit (Phase 6 pulled forward for UX impact)
**Requirements:** REQ-023, REQ-024, REQ-025, REQ-026
**Depends on:** Phase 2
**Tests:** 5329 passing (66 new tests)
**Review:** 9 findings (1 critical, 5 warning, 3 info) — all fixed
- [x] 02.1-01: Progressive streaming — PacedFrameSink, delivery mode resolution, gateway wiring
- [x] 02.1-02: Channel health + security review — aggregation module, 8-check vtable, scoring
- [x] 02.1-03: Voice mode — VoiceMode STT+TTS composition, channel audio capabilities
- [x] 02.1-04: Command + API wiring — /health, /security-review, /voice, API endpoints
- [x] **UI activation**: ZAKI-Prod prompt delivered (covers Phases 1–02.1 narration, streaming, tools, health, security)

### Phase 3: Canonical Session and Context Runtime ⏳ NEXT
**Goal:** Multi-session identity, session controls, context engine, transcript provenance
**Requirements:** REQ-007, REQ-008, REQ-009, REQ-017
**Depends on:** Phase 02.1
- [x] 03-01: Session identity refactor — thread:{uuid} replaces :main, session metadata
- [x] 03-02: Session controls — resume, compact, reset, export
- [x] 03-03: Context engine contract (src/agent/context_engine.zig)
- [x] 03-04: Context report — user-visible context transparency
- [ ] 03-05: Transcript hygiene and provenance tagging
- [ ] 03-06: **UI activation** — multi-thread sidebar, session controls, context panels

### Phase 4: Operator Parity and Platform Capability Graph
**Goal:** Operator commands, connectors, capability graph, auth failover, channel adapters
**Requirements:** REQ-011, REQ-012, REQ-014, REQ-016
**Depends on:** Phase 3
- [ ] 04-01: Operator workflows (/review, /tasks, /permissions)
- [ ] 04-02: Online agent API formalization
- [ ] 04-03: Connectors core (src/connectors/)
- [ ] 04-04: Connector auth bindings
- [ ] 04-05: Auth profile failover (src/providers/auth_profiles.zig)
- [ ] 04-06: Channel action adapters (src/channels/action_adapter.zig)
- [ ] 04-07: **UI activation** — operator dashboard, connector marketplace, auth status

### Phase 5: Multi-Agent Teams and Parity Closeout
**Goal:** Named teams, delegation visibility, SOTA parity validation
**Requirements:** REQ-013, REQ-027
**Depends on:** Phase 4
- [ ] 05-01: Team registry (src/coordination/)
- [ ] 05-02: Delegation visibility
- [ ] 05-03: SOTA parity evals (REQ-027)
- [ ] 05-04: **UI activation** — team panel, delegation tree, eval results

### ~~Phase 6: Streaming, Voice, and Channel Polish~~ — SUPERSEDED by Phase 02.1

### Phase 7: Closing Remaining Gaps
**Goal:** Complete all GAP-001 through GAP-012 closure requirements
**Requirements:** GAP-001 to GAP-012
**Depends on:** Phase 5
- [ ] 07-01: Coding workflow artifacts and patch outcome ledger (GAP-001)
- [ ] 07-02: Patch safety and rollback contract (GAP-002)
- [ ] 07-03: Host/runtime capability and degraded-mode contract (GAP-003)
- [ ] 07-04: Retry, recovery, and failover provenance (GAP-004)
- [ ] 07-05: Steering semantics across API, CLI, app, and tasks (GAP-005)
- [ ] 07-06: Approval state machine and replay semantics (GAP-006)
- [ ] 07-07: Prompt, policy, and model provenance (GAP-007)
- [ ] 07-08: Memory write/repair policy (GAP-008)
- [ ] 07-09: Multi-agent coordination contract (GAP-009)
- [ ] 07-10: Cross-surface session handoff (GAP-010)
- [ ] 07-11: Notification policy for background and task work (GAP-011)
- [ ] 07-12: Final SOTA parity eval pack (GAP-012)
- [ ] 07-13: **UI activation** — run inspector, diff viewer, approval workflow UI, notification center
