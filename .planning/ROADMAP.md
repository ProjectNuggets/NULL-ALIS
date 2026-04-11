# Roadmap — SOTA Agent Program

## Milestone: v1.0-sota

### Phase 0: Baseline and Safety Net ✅ COMPLETE
- [x] Phase directory created
- [x] 00-01: Baseline evals and characterization tests (e0ce57d)
- [x] 00-02: Online agent contract documentation (60471d9)

### Phase 1: Agent Execution Contract
- [ ] 01-01: Tool metadata (src/tools/metadata.zig)
- [ ] 01-02: Execution modes (src/agent/execution_mode.zig)
- [ ] 01-03: Approval modes (src/security/approval_modes.zig)
- [ ] 01-04: Agent reflection policy
- [ ] 01-05: Abort and interrupt (src/agent/abort.zig)

### Phase 1.5: Prompt Architecture and Liveness
**Goal:** Add "feels alive" layer — composable prompt scaffold, real-time liveness narration, task decomposition, learning loop, and persona calibration
**Plans:** 5 plans

Plans:
- [x] 01.5-01-PLAN.md — Prompt scaffold refactor: composable section builders, PromptSections struct, TurnClass enum
- [x] 01.5-02-PLAN.md — Liveness narration engine: NarrationObserver, narration_frame events, semantic labels
- [x] 01.5-03-PLAN.md — Task decomposition: TaskPlan XML parser, step state machine, prompt instructions
- [x] 01.5-04-PLAN.md — Learning loop: correction/preference detection, durable_fact storage, /learn command
- [ ] 01.5-05-PLAN.md — Persona calibration: SOUL.md front-matter parsing, PersonaProfile, /persona command

### Phase 2: Online Runtime Visibility and Tasks
**Goal:** Structured run-event stream for online clients, durable task ledger with lifecycle management, task tools for LLM inspection/control, and per-turn cost/token accounting
**Plans:** 6 plans

Plans:
- [ ] 02-01-PLAN.md — Run event types: RunEventType enum (8 variants), RunEvent tagged union, toSseFrame serializer
- [ ] 02-02-PLAN.md — SSE run events: RunEventObserver wrapping Observer for SSE delivery, gateway wiring
- [ ] 02-03-PLAN.md — Task ledger core: TaskStatus (7 states), TaskEntry, TaskLedger with state machine
- [ ] 02-04-PLAN.md — Task delivery: TaskDelivery bridging ledger transitions to observer events
- [ ] 02-05-PLAN.md — Task tools: task_list, task_get, task_stop LLM-callable tools
- [ ] 02-06-PLAN.md — Cost and usage runtime: UsageRuntime, per-turn recording, session aggregation

### Phase 02.1: Streaming, Voice, and Channel Polish (INSERTED)

**Goal:** Progressive streaming with live SSE delivery, voice-first agent mode across channels, operator channel health dashboard, and structured security audit command — making ZAKI narrate itself like Claude Code
**Requirements:** [REQ-023, REQ-024, REQ-025, REQ-026]
**Depends on:** Phase 2
**Plans:** 4/4 plans complete

Plans:
- [x] 02.1-01-PLAN.md — Progressive streaming: PacedFrameSink decorator, delivery mode resolution, live SSE path in gateway
- [x] 02.1-02-PLAN.md — Health + security core modules: channel_health.zig aggregation, security_review.zig checks and scoring
- [x] 02.1-03-PLAN.md — Voice-first mode: VoiceMode module, voice narration types, cross-channel audio capability
- [x] 02.1-04-PLAN.md — Wire commands + endpoints: /health, /security-review, /voice slash commands, gateway API endpoints

### Phase 3: Canonical Session and Context Runtime
**Goal:** Canonical session identity with typed lane routing, session lifecycle controls (resume/reset), context engine with explicit 4-phase lifecycle, and transcript hygiene with provenance tagging
**Requirements:** [REQ-007, REQ-008, REQ-009, REQ-017]
**Depends on:** Phase 2
**Plans:** 4 plans

Plans:
- [ ] 03-01-PLAN.md — Session identity: SessionIdentity struct, SessionLane enum, parseSessionKey/formatSessionKey, session module barrel
- [ ] 03-02-PLAN.md — Session controls: /reset and /resume commands, per-user session limit, listUserSessions
- [ ] 03-03-PLAN.md — Context engine: ContextEngine with ingest/assemble/compact/afterTurn lifecycle, TurnContextResult
- [ ] 03-04-PLAN.md — Transcript hygiene: ProvenanceTag, stripInternalMarkers, sanitizeForExport, clean export formatting

### Phase 4: Operator Parity and Platform Capability Graph
- [ ] 04-01: Operator workflows (/review, /security-review, /tasks, /permissions)
- [ ] 04-02: Online agent API formalization
- [ ] 04-03: Connectors core (src/connectors/)
- [ ] 04-04: Connector auth bindings
- [ ] 04-05: Auth profile failover (src/providers/auth_profiles.zig)
- [ ] 04-06: Channel action adapters (src/channels/action_adapter.zig)

### Phase 5: Multi-Agent Teams and Parity Closeout
- [ ] 05-01: Team registry (src/coordination/)
- [ ] 05-02: Delegation visibility
- [ ] 05-03: SOTA parity evals

### Phase 6: Streaming, Voice, and Channel Polish
- [ ] 06-01: Progressive streaming with human pacing
- [ ] 06-02: Voice-first agent mode
- [ ] 06-03: Channel health dashboard
- [ ] 06-04: Security audit command

### Phase 7: Closing Remaining Gaps
- [ ] 07-01: Coding workflow artifacts and patch outcome ledger
- [ ] 07-02: Patch safety and rollback contract
- [ ] 07-03: Host/runtime capability and degraded-mode contract
- [ ] 07-04: Retry, recovery, and failover provenance
- [ ] 07-05: Steering semantics across API, CLI, app, and tasks
- [ ] 07-06: Approval state machine and replay semantics
- [ ] 07-07: Prompt, policy, and model provenance
- [ ] 07-08: Memory write/repair policy
- [ ] 07-09: Multi-agent coordination contract
- [ ] 07-10: Cross-surface session handoff
- [ ] 07-11: Notification policy for background and task work
- [ ] 07-12: Final SOTA parity eval pack
