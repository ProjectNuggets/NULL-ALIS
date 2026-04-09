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

### Phase 2: Online Runtime Visibility and Tasks
- [ ] 02-01: Run events core (src/agent/run_event_types.zig)
- [ ] 02-02: SSE run events (src/gateway/run_events.zig)
- [ ] 02-03: Task ledger core (src/tasks/)
- [ ] 02-04: Task delivery (src/tasks/delivery.zig)
- [ ] 02-05: Task tools (src/tools/task_list.zig, task_get.zig, task_stop.zig)
- [ ] 02-06: Cost and usage runtime (src/usage_runtime.zig)

### Phase 3: Canonical Session and Context Runtime
- [ ] 03-01: Session identity refactor (src/session/)
- [ ] 03-02: Session controls (resume, compact, reset, export)
- [ ] 03-03: Context engine contract (src/agent/context_engine.zig)
- [ ] 03-04: Context report
- [ ] 03-05: Transcript hygiene and provenance

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
