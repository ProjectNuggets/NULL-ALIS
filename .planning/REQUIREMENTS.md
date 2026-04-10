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

### P0.5 — Required for "Feels Alive" (Digital Twin Core)

18. [REQ-018] Structured prompt scaffold with composable persona, turn classification, narration rules, and tool-use policy sections
19. [REQ-019] Liveness narration — agent emits real-time user-facing status: what it's doing, which tool it picked, why, what it's waiting on (Claude Code parity)
20. [REQ-020] Task decomposition — agent breaks complex requests into visible sub-steps, shows plan, executes step-by-step with per-step status
21. [REQ-021] Learning loop — agent detects corrections and preferences, stores as durable behavioral facts, applies in future turns
22. [REQ-022] Persona calibration — configurable personality depth and digital-twin warmth via workspace SOUL.md + runtime persona resolver

### P1 — Required for Best-in-Class Product

23. [REQ-023] Progressive streaming with per-channel modes and human pacing
24. [REQ-024] Voice-first agent mode across channels
25. [REQ-025] Channel health dashboard for operators
26. [REQ-026] Security audit command with structured checks
27. [REQ-027] Baseline eval harness with regression detection

### P2 — Differentiators

28. [REQ-028] Edge/offline deployment profile
29. [REQ-029] Memory portability (export/import)
30. [REQ-030] Decision journal
31. [REQ-031] Simulation mode (dry-run execution)

### Closing Remaining Gaps — Explicit Completion Requirements

These items are additive gap-closure requirements. They are intentionally
separated from the original plan so the final SOTA closeout criteria remain
recognizable and auditable.

- [GAP-001] Coding workflow artifacts: every meaningful coding run must produce inspectable artifacts for changed files, diff summary, commands run, tests run, test results, review state, and final patch outcome.
- [GAP-002] Patch safety contract: risky-file detection, dirty-worktree handling, rollback/retry checkpoints, and explicit policy for partial success vs full failure.
- [GAP-003] Host/runtime capability contract: define how hosted app, CLI, desktop app, VS extension, and edge/device runtimes expose capabilities, and how the same agent degrades when tools or connectivity are unavailable.
- [GAP-004] Retry and recovery ledger: retries, backoff, provider/profile failover, resumed runs, interrupted runs, and recovered tasks must be represented as first-class run artifacts.
- [GAP-005] Steering semantics: active work can be redirected without losing task/session provenance, distinct from stop, cancel, and abort.
- [GAP-006] Approval state machine: approval request, pending, approved, denied, expired, overridden, and replayed states must be explicit across API, CLI, and app surfaces.
- [GAP-007] Prompt and policy provenance: each run records the prompt scaffold version, persona/policy source set, capability profile, and model/profile selection used to produce behavior.
- [GAP-008] Memory write and repair policy: define what becomes durable memory, what stays ephemeral, how user corrections override stored beliefs, and how invalid memories are repaired or retired.
- [GAP-009] Multi-agent coordination contract: ownership, write-scope isolation, conflict handling, merge semantics, and parent-child accountability artifacts must be explicit.
- [GAP-010] Cross-surface session handoff: a run can move between app, API, CLI, extension, and later device-hosted surfaces without losing provenance or continuity state.
- [GAP-011] Notification policy: background/task work must have explicit notify-now, notify-later, silent, and acknowledgement-required delivery semantics.
- [GAP-012] SOTA parity eval pack: add explicit eval scenarios for repo edit loops, test failure recovery, approval denial, interrupted runs, reconnect/resume, degraded/offline hosts, and multi-agent coordination.

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
