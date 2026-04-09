# Requirements — SOTA Agent Program

## V1 (This Program)

### P0 — Required for SOTA Parity

1. [REQ-001] Explicit execution modes: plan, execute, review, background
2. [REQ-002] Structured tool metadata: read_only, mutating, background_safe, operator_only, concurrency_safe
3. [REQ-003] Approval contract for tools and actions with explainable reasons
4. [REQ-004] Structured run-event stream for online clients (ready, reply_start, progress, tool_start, tool_result, approval_required, task_update, done)
5. [REQ-005] Durable task ledger for spawned and detached work (queued, running, succeeded, failed, timed_out, cancelled, lost)
6. [REQ-006] Task inspection, stop, and output retrieval tools
7. [REQ-007] Canonical session identity and lane routing module
8. [REQ-008] Session controls: resume, compact, reset, export
9. [REQ-009] Context engine with explicit lifecycle: ingest, assemble, compact, after_turn
10. [REQ-010] Abort and interrupt propagation from API/CLI/channel to active work
11. [REQ-011] Richer operator commands: /review, /security-review, /tasks, /permissions
12. [REQ-012] Connectors + MCP + skills under one capability graph
13. [REQ-013] Named multi-agent teams with inspectable delegation
14. [REQ-014] Auth profile failover with cooldown and visibility
15. [REQ-015] Per-turn cost and token accounting with operator surfaces
16. [REQ-016] Channel action adapters (shared host, channel-owned actions)
17. [REQ-017] Transcript hygiene and provenance tagging

### P1 — Required for Best-in-Class Product

18. [REQ-018] Progressive streaming with per-channel modes and human pacing
19. [REQ-019] Voice-first agent mode across channels
20. [REQ-020] Channel health dashboard for operators
21. [REQ-021] Security audit command with structured checks
22. [REQ-022] Baseline eval harness with regression detection

### P2 — Differentiators

23. [REQ-023] Edge/offline deployment profile
24. [REQ-024] Memory portability (export/import)
25. [REQ-025] Decision journal
26. [REQ-026] Simulation mode (dry-run execution)

## V2 (Future — plan.md Tracks B-G)

- Agent network effect (cross-agent APIs)
- Persona marketplace
- Memory inheritance
- Agent certificates
- Agent-as-API

## Out of Scope (This Program)

- IDE bridge / editor integration (P2 differentiator, post-program)
- Canvas / visual workspace (requires major frontend)
- ACP protocol (external harness delegation)
- Rewrite of any existing working subsystem
- WebSocket replacement of SSE transport
