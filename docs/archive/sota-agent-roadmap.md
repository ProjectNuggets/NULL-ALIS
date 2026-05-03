---
tags: [prose, prose/docs]
---

# SOTA Agent Roadmap

Status: active planning — source of truth for execution
Date: 2026-04-09 (updated)
Primary input: `docs/sota-agent-feature-map.md`
Long-term vision: `/Users/nova/Downloads/plan.md` (Tracks A-G)
Scope: This roadmap covers the agent-core SOTA program (plan.md Phase 1: Trustworthy Digital Twin Core + execution parity with Claude Code and OpenClaw). Tracks B-G (network, marketplace, inheritance, certificates, agent-as-API) are future phases after this program completes.

## Goal

Drive `nullALIS` to at least parity with `Claude Code` and `OpenClaw` on the combined agent product surface, while preserving:

- Zig runtime core
- multitenant safety
- pod-isolated execution
- API/SSE/CLI-first operation

This roadmap is the execution program for that goal.

It is designed to be:

- phase-based
- sprint-sized
- branch-scoped
- parallel-agent executable where write scopes allow it
- regression-aware

## Planning Rules

1. One branch = one shippable milestone.
2. Every branch must have a clear write set.
3. Shared-core files create serialization pressure:
   - `src/agent/root.zig`
   - `src/gateway.zig`
   - `src/agent/commands.zig`
   - `src/tools/root.zig`
   - `src/session.zig`
   - `src/subagent.zig`
4. Branches touching the same shared-core files should not run in parallel unless one is strictly docs/tests only.
5. Every branch closes with:
   - `zig build test --summary all`
   - targeted behavior checks for the branch goal
6. High-risk branches also close with:
   - `zig build -Doptimize=ReleaseSmall`

## Program Structure

The program is split into 6 phases.

1. Phase 0: Baseline and safety net
2. Phase 1: Agent execution contract
3. Phase 2: Online runtime visibility and tasks
4. Phase 3: Canonical session and context runtime
5. Phase 4: Operator parity and platform capability graph
6. Phase 5: Multi-agent teams and parity closeout

Each phase is made of sprint-sized branches.

## Phase 0: Baseline And Safety Net

Purpose:
- freeze behavior
- define evals
- avoid flying blind while the runtime evolves

### Sprint 0A

Branch:
- `infra/sota-baseline-evals-v1`

Goal:
- create the characterization and eval baseline for the agent core

Primary files:
- `src/agent/root.zig`
- `src/gateway.zig`
- `src/subagent.zig`
- `src/agent/commands.zig`
- `src/status.zig`
- `src/doctor.zig`
- `docs/reports/`

Deliverables:
- baseline turn-loop checks
- baseline SSE event checks
- baseline subagent/task checks
- baseline command behavior checks
- one repeatable spot-check pack for:
  - direct answer
  - tool loop
  - tool failure
  - long-running task
  - compaction pressure

Parallel-safe:
- no

### Sprint 0B

Branch:
- `docs/online-agent-contract-v1`

Goal:
- document the online agent control contract before implementation churn

Primary files:
- `docs/openapi-v1.yaml`
- `docs/agent-lifecycle-spec.md`
- `docs/sota-agent-feature-map.md`
- `docs/sota-agent-roadmap.md`

Deliverables:
- target run-event vocabulary
- target task vocabulary
- target session-control API semantics

Parallel-safe:
- yes, can run with `infra/sota-baseline-evals-v1`

## Phase 1: Agent Execution Contract

Purpose:
- make the core execution model explicit, inspectable, and policy-aware

### Sprint 1A

Branch:
- `feat/tool-metadata-v1`

Goal:
- make tool classes machine-readable

Primary files:
- `src/tools/root.zig`
- `src/tools/shell.zig`
- `src/tools/http_request.zig`
- `src/tools/message.zig`
- `src/tools/spawn.zig`
- `src/tools/delegate.zig`
- `src/tools/schedule.zig`

Add:
- `src/tools/metadata.zig`

Deliverables:
- tool class flags:
  - `read_only`
  - `mutating`
  - `background_safe`
  - `operator_only`
  - `concurrency_safe`
- tool-profile reporting hooks

Parallel-safe:
- no

### Sprint 1B

Branch:
- `feat/execution-modes-v1`

Goal:
- introduce explicit run modes

Primary files:
- `src/agent/root.zig`
- `src/agent/commands.zig`
- `src/agent/prompt.zig`
- `src/capabilities.zig`

Add:
- `src/agent/execution_mode.zig`

Deliverables:
- run modes:
  - `plan`
  - `execute`
  - `review`
  - `background`
- prompt shaping by mode
- mode surfaced in slash commands and runtime state

Depends on:
- `feat/tool-metadata-v1`

Parallel-safe:
- no

### Sprint 1C

Branch:
- `feat/approval-modes-v1`

Goal:
- move approval posture from implicit behavior to structured policy

Primary files:
- `src/security/policy.zig`
- `src/security/sandbox.zig`
- `src/agent/root.zig`
- `src/gateway.zig`
- `src/agent/commands.zig`
- `src/channels/root.zig`

Add:
- `src/security/approval_modes.zig`

Deliverables:
- approval modes aligned to run modes
- structured approval reason codes
- blocked-action explainability

Depends on:
- `feat/tool-metadata-v1`
- `feat/execution-modes-v1`

Parallel-safe:
- no

### Sprint 1D

Branch:
- `feat/agent-reflection-policy-v1`

Goal:
- upgrade the post-tool reflection logic into mode-aware execution behavior

Primary files:
- `src/agent/root.zig`
- `src/agent/prompt.zig`
- `src/agent/dispatcher.zig`

Deliverables:
- mode-specific reflection policy
- failure-class-aware reflection
- no-repeat behavior for blocked calls
- better transient retry guidance

Depends on:
- `feat/execution-modes-v1`
- `feat/approval-modes-v1`

Parallel-safe:
- no

### Sprint 1E

Branch:
- `feat/abort-and-interrupt-v1`

Goal:
- make interruption, steering, cancellation, and queue semantics explicit runtime behavior

Primary files:
- `src/agent/root.zig`
- `src/session.zig`
- `src/subagent.zig`
- `src/gateway.zig`
- `src/tools/spawn.zig`
- `src/tools/delegate.zig`

Add:
- `src/agent/abort.zig`
- `src/tasks/control.zig`

Deliverables:
- interrupt propagation from API/CLI/channel request into active run state
- task cancellation without orphaned runtime state
- explicit queue/interrupt semantics for active sessions

Depends on:
- `feat/execution-modes-v1`

Parallel-safe:
- no

## Phase 2: Online Runtime Visibility And Tasks

Purpose:
- turn the core runtime into an online product with visible execution and durable detached work

### Sprint 2A

Branch:
- `feat/run-events-core-v1`

Goal:
- establish one canonical run-event model

Primary files:
- `src/observability.zig`
- `src/agent/root.zig`
- `src/subagent.zig`
- `src/gateway.zig`

Add:
- `src/agent/run_event_types.zig`
- `src/gateway/run_events.zig`

Deliverables:
- structured event types for:
  - `ready`
  - `reply_start`
  - `progress`
  - `tool_start`
  - `tool_result`
  - `approval_required`
  - `task_update`
  - `subagent_completion`
  - `reasoning_summary`
  - `token`
  - `done`

Depends on:
- Phase 1 complete

Parallel-safe:
- no

### Sprint 2B

Branch:
- `feat/sse-run-events-v1`

Goal:
- expose the new run-event grammar over SSE and replay

Primary files:
- `src/gateway.zig`
- `docs/openapi-v1.yaml`

Deliverables:
- enriched SSE contract
- replay-safe run event framing
- additive compatibility for current clients

Depends on:
- `feat/run-events-core-v1`

Parallel-safe:
- yes, can run with `feat/task-ledger-core-v1` after the shared event types land if no overlap on `src/gateway.zig` is allowed; otherwise sequence it

### Sprint 2C

Branch:
- `feat/task-ledger-core-v1`

Goal:
- create the durable task system

Primary files:
- `src/subagent.zig`
- `src/tools/spawn.zig`
- `src/tools/delegate.zig`
- `src/status.zig`

Add:
- `src/tasks/root.zig`
- `src/tasks/store.zig`
- `src/tasks/types.zig`

Deliverables:
- canonical task types
- durable task store
- status lifecycle:
  - `queued`
  - `running`
  - `succeeded`
  - `failed`
  - `timed_out`
  - `cancelled`
  - `lost`

Depends on:
- Phase 1 complete

Parallel-safe:
- no

### Sprint 2D

Branch:
- `feat/task-delivery-v1`

Goal:
- make detached work results reliably deliverable and replayable

Primary files:
- `src/tasks/root.zig`
- `src/tasks/store.zig`
- `src/subagent.zig`
- `src/gateway.zig`
- `src/channels/dispatch.zig`

Add:
- `src/tasks/delivery.zig`

Deliverables:
- durable completion persistence
- requester delivery fallback
- replay path for missed updates

Depends on:
- `feat/task-ledger-core-v1`
- `feat/run-events-core-v1`

Parallel-safe:
- no

### Sprint 2E

Branch:
- `feat/task-tools-v1`

Goal:
- expose tasks as a first-class operator and agent surface

Primary files:
- `src/tools/root.zig`
- `src/agent/commands.zig`
- `src/status.zig`
- `src/doctor.zig`

Add:
- `src/tools/task_list.zig`
- `src/tools/task_get.zig`
- `src/tools/task_stop.zig`

Deliverables:
- `/tasks` operator view
- task tools for the agent itself
- status and doctor task visibility

Depends on:
- `feat/task-ledger-core-v1`

Parallel-safe:
- yes, can run with `feat/task-delivery-v1` if it avoids editing `src/gateway.zig` and `src/subagent.zig`

### Sprint 2F

Branch:
- `feat/cost-and-usage-runtime-v1`

Goal:
- make token and cost truth first-class operator/runtime surfaces

Primary files:
- `src/agent/root.zig`
- `src/status.zig`
- `src/doctor.zig`
- `src/gateway.zig`

Add:
- `src/usage_runtime.zig`

Deliverables:
- per-turn token accounting
- retry-aware usage and cost accounting
- task cost visibility where possible
- operator-facing usage summaries

Depends on:
- `feat/run-events-core-v1`

Parallel-safe:
- yes, can run with `feat/task-tools-v1` if shared edits to `src/status.zig` and `src/doctor.zig` are coordinated

## Phase 3: Canonical Session And Context Runtime

Purpose:
- make session truth and context assembly explicit, centralized, and explainable

### Sprint 3A

Branch:
- `refactor/session-identity-v1`

Goal:
- centralize session and lane identity

Primary files:
- `src/zaki_session.zig`
- `src/session.zig`
- `src/diagnostics/runtime_truth.zig`
- `src/tools/runtime_info.zig`
- `src/gateway.zig`
- `src/subagent.zig`
- `src/channel_loop.zig`

Deliverables:
- one canonical session identity module
- one lane parser
- reduced duplicate session logic

Depends on:
- Phase 2 stable

Parallel-safe:
- no

### Sprint 3B

Branch:
- `feat/session-controls-v1`

Goal:
- expose real session controls to operators and clients

Primary files:
- `src/agent/commands.zig`
- `src/session.zig`
- `src/gateway.zig`
- `docs/openapi-v1.yaml`

Add:
- `src/session/policy.zig`

Deliverables:
- resume
- compact
- reset
- export
- lane-aware branching semantics

Depends on:
- `refactor/session-identity-v1`

Parallel-safe:
- no

### Sprint 3C

Branch:
- `refactor/context-engine-contract-v1`

Goal:
- turn the current implicit context runtime into an explicit contract

Primary files:
- `src/agent/root.zig`
- `src/agent/context_builder.zig`
- `src/agent/memory_loader.zig`
- `src/agent/compaction.zig`
- `src/memory/root.zig`

Add:
- `src/agent/context_engine.zig`
- `src/agent/context_engine_legacy.zig`

Deliverables:
- lifecycle:
  - `ingest`
  - `assemble`
  - `compact`
  - `after_turn`
  - optional subagent hooks

Depends on:
- `refactor/session-identity-v1`

Parallel-safe:
- no

### Sprint 3D

Branch:
- `feat/context-report-v1`

Goal:
- make context explainable at runtime

Primary files:
- `src/agent/context_report.zig`
- `src/agent/commands.zig`
- `src/status.zig`
- `src/doctor.zig`

Deliverables:
- context report by bucket
- compaction visibility
- memory selection visibility

Depends on:
- `refactor/context-engine-contract-v1`

Parallel-safe:
- yes, can run with `feat/session-controls-v1` after core session identity lands

### Sprint 3E

Branch:
- `feat/transcript-hygiene-and-provenance-v1`

Goal:
- make transcript validation, repair, provenance tagging, and pruning policy explicit

Primary files:
- `src/session.zig`
- `src/agent/root.zig`
- `src/agent/compaction.zig`
- `src/subagent.zig`
- `src/memory/root.zig`

Add:
- `src/session/transcript_hygiene.zig`
- `src/session/provenance.zig`

Deliverables:
- transcript validation and repair
- inter-session and internal-message provenance tagging
- explicit pruning and hygiene rules for long-lived sessions

Depends on:
- `refactor/session-identity-v1`

Parallel-safe:
- no

## Phase 4: Operator Parity And Platform Capability Graph

Purpose:
- reach Claude/OpenClaw parity on operator workflows and extensibility

### Sprint 4A

Branch:
- `feat/operator-workflows-v1`

Goal:
- add first-class operator commands and workflows

Primary files:
- `src/agent/commands.zig`
- `src/status.zig`
- `src/doctor.zig`

Deliverables:
- `/review`
- `/security-review`
- `/permissions`
- improved `/context`
- improved `/tasks`
- improved `/session`

Depends on:
- Phases 1 through 3 complete

Parallel-safe:
- yes, can run with `feat/connectors-core-v1`

### Sprint 4B

Branch:
- `feat/online-agent-api-v1`

Goal:
- formalize the stable online control surface

Primary files:
- `src/gateway.zig`
- `docs/openapi-v1.yaml`

Add:
- `docs/online-agent-api-spec.md`

Deliverables:
- approvals over API
- session controls over API
- task controls over API
- run event contract frozen for app clients

Depends on:
- Phases 1 through 3 complete

Parallel-safe:
- yes, can run with `feat/operator-workflows-v1` if command-only changes avoid `src/gateway.zig`

### Sprint 4C

Branch:
- `feat/connectors-core-v1`

Goal:
- define the connector layer for external APIs and backends

Primary files:
- `src/mcp.zig`
- `src/skills.zig`
- `src/skillforge.zig`
- `src/tools/composio.zig`
- `src/tools/http_request.zig`
- `src/tools/root.zig`

Add:
- `src/connectors/root.zig`
- `src/connectors/manifest.zig`
- `src/connectors/runtime.zig`

Deliverables:
- connector manifests
- capability registration for external integrations
- clean boundary between skills, MCP, and connectors

Depends on:
- Phase 3 complete

Parallel-safe:
- yes, can run with `feat/operator-workflows-v1`

### Sprint 4D

Branch:
- `feat/connector-auth-bindings-v1`

Goal:
- bind connectors cleanly to secret and tenant identity posture

Primary files:
- `src/connectors/root.zig`
- `src/tools/composio.zig`
- `src/security/secrets.zig`
- `src/tenant_runtime_scope.zig`

Add:
- `src/connectors/auth_bindings.zig`

Deliverables:
- per-user connector identity resolution
- safe secret posture for connector execution

Depends on:
- `feat/connectors-core-v1`

Parallel-safe:
- yes, can run with `feat/online-agent-api-v1`

### Sprint 4E

Branch:
- `feat/auth-profile-failover-v1`

Goal:
- make provider auth profile ordering, cooldown, and failover part of the runtime contract

Primary files:
- `src/providers/root.zig`
- `src/providers/reliable.zig`
- `src/config.zig`
- `src/agent/commands.zig`
- `src/status.zig`

Add:
- `src/providers/auth_profiles.zig`
- `src/providers/failover_runtime.zig`

Deliverables:
- auth profile ordering and cooldown tracking
- visible failover reasons
- per-session provider/auth override behavior

Depends on:
- Phase 3 complete

Parallel-safe:
- yes, can run with `feat/connectors-core-v1` if `src/status.zig` and `src/agent/commands.zig` edits are small or serialized

### Sprint 4F

Branch:
- `feat/channel-action-adapters-v1`

Goal:
- adopt the shared message-host plus channel-owned action adapter model

Primary files:
- `src/tools/message.zig`
- `src/channels/root.zig`
- `src/channels/dispatch.zig`
- `src/gateway.zig`

Add:
- `src/channels/action_adapter.zig`

Deliverables:
- shared message-action host
- channel-owned action discovery
- channel-owned action execution
- less channel-specific branching in core runtime surfaces

Depends on:
- `feat/online-agent-api-v1`

Parallel-safe:
- no

## Phase 5: Multi-Agent Teams And Parity Closeout

Purpose:
- make delegation inspectable and close the remaining parity gaps

### Sprint 5A

Branch:
- `feat/team-registry-v1`

Goal:
- introduce named specialist teams

Primary files:
- `src/subagent.zig`
- `src/tools/spawn.zig`
- `src/tools/delegate.zig`
- `src/agent/commands.zig`

Add:
- `src/coordination/root.zig`
- `src/coordination/team.zig`
- `src/coordination/registry.zig`

Deliverables:
- named agents
- team registry
- clear spawn targets

Depends on:
- task runtime complete
- session/runtime truth stable

Parallel-safe:
- no

### Sprint 5B

Branch:
- `feat/delegation-visibility-v1`

Goal:
- make multi-agent behavior explainable

Primary files:
- `src/subagent.zig`
- `src/tasks/root.zig`
- `src/gateway.zig`
- `src/agent/commands.zig`

Add:
- `src/coordination/messages.zig`

Deliverables:
- visible delegation graph
- parent/child run linkage
- task and subagent handoff visibility

Depends on:
- `feat/team-registry-v1`

Parallel-safe:
- no

### Sprint 5C

Branch:
- `ops/sota-parity-evals-v1`

Goal:
- close the remaining parity gaps with targeted evals and fixes

Primary files:
- `src/agent/root.zig`
- `src/gateway.zig`
- `src/agent/commands.zig`
- `src/status.zig`
- `src/doctor.zig`
- `docs/reports/`

Deliverables:
- parity gap report against the feature map
- final polish fixes
- go/no-go decision for “at least on par”

Depends on:
- all prior phases complete

Parallel-safe:
- no

## Parallel Execution Packs

These are the safe multi-agent execution packs.

### Pack A

Can run in parallel:
- `infra/sota-baseline-evals-v1`
- `docs/online-agent-contract-v1`

Why safe:
- docs branch does not mutate runtime code

### Pack B

Can run in parallel after Phase 2 core lands:
- `feat/task-tools-v1`
- `feat/sse-run-events-v1`

Why safe:
- task tools can stay mostly in `src/tools/*`, `src/agent/commands.zig`, `src/status.zig`
- SSE branch is centered on `src/gateway.zig`

Constraint:
- if task tools start editing `src/gateway.zig`, serialize them

### Pack C

Can run in parallel after Phase 3 core lands:
- `feat/context-report-v1`
- `feat/session-controls-v1`

Why safe:
- context report lives mostly in context/status/doctor surfaces
- session controls live mostly in session/commands/API

Constraint:
- shared edits to `src/agent/commands.zig` should be kept small or serialized

### Pack D

Can run in parallel after Phase 4 starts:
- `feat/operator-workflows-v1`
- `feat/connectors-core-v1`
- `feat/auth-profile-failover-v1`

Why safe:
- operator workflows are command/status heavy
- connectors are skills/MCP/tools heavy
- auth failover is providers/runtime heavy

Constraint:
- coordinate shared edits in `src/agent/commands.zig` and `src/status.zig`

### Pack E

Can run in parallel after Phase 4 starts:
- `feat/online-agent-api-v1`
- `feat/cost-and-usage-runtime-v1`

Why safe:
- API branch is gateway/openapi heavy
- usage branch is agent/status/doctor heavy

Constraint:
- avoid overlapping edits in `src/gateway.zig`

## Branch Dependency Graph

Strict order:

1. `infra/sota-baseline-evals-v1`
2. `feat/tool-metadata-v1`
3. `feat/execution-modes-v1`
4. `feat/approval-modes-v1`
5. `feat/agent-reflection-policy-v1`
6. `feat/abort-and-interrupt-v1`
7. `feat/run-events-core-v1`
8. `feat/task-ledger-core-v1`
9. `feat/task-delivery-v1`
10. `feat/cost-and-usage-runtime-v1`
11. `refactor/session-identity-v1`
12. `feat/transcript-hygiene-and-provenance-v1`
13. `refactor/context-engine-contract-v1`
14. `feat/session-controls-v1`
15. `feat/context-report-v1`
16. `feat/operator-workflows-v1`
17. `feat/online-agent-api-v1`
18. `feat/connectors-core-v1`
19. `feat/connector-auth-bindings-v1`
20. `feat/auth-profile-failover-v1`
21. `feat/channel-action-adapters-v1`
22. `feat/team-registry-v1`
23. `feat/delegation-visibility-v1`
24. `ops/sota-parity-evals-v1`

Optional overlap:

- docs and eval work can overlap
- task tools and SSE can overlap after core event types land
- operator workflows, API formalization, and connectors can overlap once session/context/runtime truth is stable

## Phase 6: Streaming, Voice, and Channel Product Polish

Purpose:
- turn existing channel and voice infrastructure into product-grade features
- close streaming UX gap vs OpenClaw

### Sprint 6A

Branch:
- `feat/progressive-streaming-v1`

Goal:
- implement per-channel streaming modes and human pacing

Primary files:
- `src/gateway.zig`
- `src/channels/telegram.zig`
- `src/channels/discord.zig`
- `src/channels/slack.zig`

Add:
- `src/channels/stream_chunker.zig`

Deliverables:
- streaming modes: off, partial, block, progress (per channel config)
- code-fence-safe chunk breaks
- configurable human delay for messaging channels
- message coalescing for rapid inbound

Depends on:
- `feat/run-events-core-v1`

Parallel-safe:
- yes, can run with Phase 4/5 sprints if gateway edits are coordinated

Frontend:
- streaming indicator in app chat
- partial message rendering during block mode

### Sprint 6B

Branch:
- `feat/voice-mode-v1`

Goal:
- promote voice from Telegram-only STT to first-class execution mode

Primary files:
- `src/voice.zig`
- `src/channels/telegram.zig`
- `src/channels/discord.zig`
- `src/agent/root.zig`

Add:
- `src/voice/stt_providers.zig`
- `src/voice/tts_providers.zig`

Deliverables:
- voice mode as explicit execution mode hint
- streaming TTS for long responses
- cross-channel audio handling (Discord, WhatsApp)
- voice-optimized prompt variant

Depends on:
- Phase 1 complete

Parallel-safe:
- yes, isolated write set

Frontend:
- voice input toggle in app
- audio playback for TTS responses

### Sprint 6C

Branch:
- `feat/channel-health-dashboard-v1`

Goal:
- make channel breadth visible and manageable

Primary files:
- `src/channels/dispatch.zig`
- `src/status.zig`
- `src/doctor.zig`
- `src/agent/commands.zig`

Deliverables:
- `/channels` operator command showing per-channel health, connection state, message counts
- channel capability discovery (what actions work where)
- per-channel metrics in Prometheus

Depends on:
- Phase 2 complete

Parallel-safe:
- yes

Frontend:
- channel status panel in settings/admin UI

### Sprint 6D

Branch:
- `feat/security-audit-command-v1`

Goal:
- structured security self-check (parity with OpenClaw's 50+ check audit)

Primary files:
- `src/security/audit.zig`
- `src/security/policy.zig`
- `src/agent/commands.zig`
- `src/doctor.zig`

Add:
- `src/security/audit_checks.zig`

Deliverables:
- `/security-audit` command with check IDs
- categories: tool blast radius, exec approval drift, network exposure, sandbox config, policy drift
- `--json` output for CI
- auto-fixable items where safe

Depends on:
- `feat/approval-modes-v1`

Parallel-safe:
- yes

Frontend:
- security status indicator in admin panel

## UX/UI Requirements Per Sprint

Each sprint that adds user-visible capability needs corresponding frontend work. This matrix defines the minimum frontend deliverable per sprint.

### Phase 0
| Sprint | Backend Feature | Frontend Requirement |
|---|---|---|
| 0A | Baseline evals | None (infra only) |
| 0B | Online agent contract doc | None (docs only) |

### Phase 1
| Sprint | Backend Feature | Frontend Requirement |
|---|---|---|
| 1A | Tool metadata | None (internal metadata) |
| 1B | Execution modes | Mode indicator in chat header (plan/execute/review/background) |
| 1C | Approval modes | Approval prompt card in chat stream, approval history panel |
| 1D | Reflection policy | None (internal behavior) |
| 1E | Abort and interrupt | Cancel/stop button in chat UI, interrupt confirmation |

### Phase 2
| Sprint | Backend Feature | Frontend Requirement |
|---|---|---|
| 2A | Run events core | None (internal event types) |
| 2B | SSE run events | Tool execution cards, progress indicators, reasoning summary collapse |
| 2C | Task ledger core | None (internal store) |
| 2D | Task delivery | Task notification toast, missed-update indicator |
| 2E | Task tools | Task board panel (list, status, stop), task detail view |
| 2F | Cost and usage | Usage panel with per-turn cost, session total, cost chart |

### Phase 3
| Sprint | Backend Feature | Frontend Requirement |
|---|---|---|
| 3A | Session identity | Session picker/switcher, lane indicator |
| 3B | Session controls | Resume/compact/reset/export buttons in session menu |
| 3C | Context engine | None (internal contract) |
| 3D | Context report | Context inspector panel (hot/warm/cold buckets, token budget) |
| 3E | Transcript hygiene | None (internal behavior) |

### Phase 4
| Sprint | Backend Feature | Frontend Requirement |
|---|---|---|
| 4A | Operator workflows | Slash command palette, /review and /security-review panels |
| 4B | Online agent API | API playground / webhook configuration panel |
| 4C | Connectors core | Connector/integration management panel |
| 4D | Connector auth | OAuth flow UI for connector setup |
| 4E | Auth profile failover | Provider status panel showing active/cooldown/failed profiles |
| 4F | Channel action adapters | Channel-specific action buttons in chat (react, thread, poll) |

### Phase 5
| Sprint | Backend Feature | Frontend Requirement |
|---|---|---|
| 5A | Team registry | Agent/team panel showing named specialists |
| 5B | Delegation visibility | Delegation graph view, parent/child task linkage |
| 5C | Parity evals | None (eval/report only) |

### Phase 6
| Sprint | Backend Feature | Frontend Requirement |
|---|---|---|
| 6A | Progressive streaming | Streaming indicator, partial message rendering |
| 6B | Voice mode | Voice input toggle, audio playback |
| 6C | Channel health | Channel status panel |
| 6D | Security audit | Security status indicator |

## Agent-Per-Sprint Execution Guide

Each sprint is owned by one agent. This section defines how to brief each agent.

### Context Packet (Every Agent Reads)

1. `README.md`
2. `docs/sota-agent-feature-map.md`
3. `docs/sota-agent-roadmap.md` (this file)
4. Sprint-specific files listed in the sprint's “Primary files” section
5. `docs/openapi-v1.yaml` (if touching API surface)

### Agent Execution Rules

1. Read the context packet before writing any code.
2. Stay within the sprint's declared write set.
3. Do not silently broaden policy, permissions, or API behavior.
4. Add tests for new behavior and regression cases.
5. Do not edit shared-core files (`src/gateway.zig`, `src/agent/root.zig`, `src/agent/commands.zig`, `src/tools/root.zig`, `src/session.zig`, `src/subagent.zig`) unless the sprint explicitly lists them.
6. If the sprint depends on another sprint, verify the dependency is merged before starting.
7. Run validation before declaring done:
   - `zig build test --summary all`
   - `zig build -Doptimize=ReleaseSmall`
8. Include evidence in PR description.

### Serialization Rules

Sprints that touch shared-core files MUST run serially. The dependency graph above enforces this. The parallel packs define safe overlap windows.

If an agent needs to touch a shared-core file not in its declared write set, it must:
1. Stop and report the dependency.
2. Wait for coordinator approval.
3. Minimize the edit to the smallest possible change.

### Gateway Decomposition (Optional Pre-Work)

Before starting Phase 2 sprints that touch `src/gateway.zig` (15,599 lines), consider extracting:
1. `src/gateway/rate_limiter.zig` — SlidingWindowRateLimiter (self-contained)
2. `src/gateway/idempotency.zig` — IdempotencyStore (self-contained)
3. `src/gateway/tenant.zig` — tenant management functions
4. `src/gateway/broker_proxy.zig` — broker proxy logic
5. `src/gateway/webhook_handlers.zig` — per-channel webhook handling

This would reduce core gateway to ~4,000-5,000 lines and lower merge conflict risk for parallel sprints.

## Definition Of Done For The Program

The roadmap is complete when all of these are true:

1. the agent loop is mode-aware and policy-aware
2. tool approvals and failure reasons are structured and explainable
3. online clients receive a rich run-event stream
4. detached work is durable, inspectable, and stoppable
5. session identity and lane policy are canonical
6. transcript hygiene and provenance are explicit and reliable
7. context assembly is explicit and inspectable
8. operator workflows reach practical parity with Claude Code and OpenClaw
9. connectors, skills, and MCP form one coherent capability graph
10. auth failover and usage truth are operator-visible runtime systems
11. channel message actions are owned by channel adapters, not smeared across core logic
12. multi-agent work is visible and task-backed
13. streaming UX is per-channel configurable and human-paced
14. voice mode works across supported channels
15. security audit is structured and repeatable
16. parity evals say Nullalis is at least on par with both reference products
17. frontend has matching UI for every user-visible backend feature

## Alignment With Long-Term Vision (plan.md)

This roadmap executes plan.md Phase 1 (Trustworthy Digital Twin Core) plus execution-parity features.

After this program completes, the following plan.md tracks become unblocked:

| Track | Depends On | Status |
|---|---|---|
| Track A: Digital Twin Core | This roadmap | **Active — this program** |
| Track B: Agent Network Effect | Phase 1 complete, trust graph, cross-agent APIs | Future |
| Track C: Persona Marketplace | Phase 1 complete, persona package schema | Future |
| Track D: Memory Inheritance | Phase 1 complete, memory export/import (F20) | Future — F20 seeds this |
| Track E: Universal Remote | Connectors (Phase 4), approval modes (Phase 1) | Partially covered |
| Track F: Agent Certificates | Eval harness (Phase 0), benchmark pipeline | Future |
| Track G: Agent-as-API | Online API (Phase 4), session controls (Phase 3) | Partially covered |

## Immediate Next Branch

The highest-leverage next branch is:

- `infra/sota-baseline-evals-v1`

Reason:
- it lowers regression risk for every following branch
- it gives the program a measurable parity baseline
- it forces clarity around what “better” means before deeper core edits begin
