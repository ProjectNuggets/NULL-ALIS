---
tags: [prose, prose/docs]
---

# SOTA Agent Feature Map

## Goal

Define how `nullALIS` should absorb the best product behavior from `Claude Code` and `OpenClaw` without losing its own advantages:

- Zig-first runtime
- low operational footprint
- tenant-safe online delivery
- strong session and memory continuity
- explicit security posture

The target product is:

> "Claude Code quality execution and coding workflow, with OpenClaw quality online control-plane and always-on session model, delivered through Nullalis."

This document is the feature map, target spec, and implementation ownership plan.

Execution companion:
- `docs/sota-agent-roadmap.md`

## Source Basis

This plan is grounded in the local repos, not marketing copy.

### Claude Code

- `README.md`
- `docs/architecture.md`
- `docs/tools.md`
- `docs/commands.md`
- `docs/subsystems.md`
- `src/main.tsx`
- `src/QueryEngine.ts`
- `src/tools.ts`

### OpenClaw

- `README.md`
- `docs/concepts/architecture.md`
- `docs/concepts/features.md`
- `docs/concepts/session.md`
- `docs/concepts/multi-agent.md`
- `docs/concepts/context-engine.md`
- `docs/plugins/architecture.md`
- `docs/automation/tasks.md`
- `src/index.ts`

### Nullalis

- `README.md`
- `docs/openapi-v1.yaml`
- `docs/zaki-runtime-contract.md`
- `src/main.zig`
- `src/agent/root.zig`
- `src/agent/commands.zig`
- `src/tools/root.zig`
- `src/gateway.zig`
- `src/subagent.zig`
- `src/mcp.zig`
- `src/skills.zig`

## Product Read

### Claude Code is strongest at

- coding-agent workflow density
- execution loop polish
- tool permissions and operator trust
- plan mode, task mode, and sub-agent workflows
- command surface richness
- MCP and skill ergonomics
- IDE/terminal continuity

### OpenClaw is strongest at

- online, always-on agent product shape
- gateway-owned session truth
- multi-channel and multi-agent routing
- background task durability and delivery
- plugin capability model
- context engine architecture
- control plane and remote/app surfaces

### Nullalis is strongest at

- small-footprint Zig runtime (single binary, runs on RPi to cloud)
- clear vtable extension boundaries (`src/tools/root.zig`, `src/memory/root.zig`)
- strong tenant/runtime contract (`src/gateway.zig`, `src/tenant_lock.zig`)
- stable SSE chat delivery (`src/gateway.zig`)
- 19 channel implementations — widest channel coverage of any agent runtime (`src/channels/`)
- 10+ memory storage backends with 9-stage retrieval pipeline (`src/memory/`)
- vector embedding plane with circuit breakers and durable outbox (`src/memory/vector/`)
- semantic response cache (`src/memory/lifecycle/semantic_cache.zig`)
- hardware/IoT tools — I2C, SPI, serial, MaixCam, firmware flashing (`src/tools/i2c.zig`, `src/tools/spi.zig`, `src/hardware.zig`)
- voice/STT/TTS pipeline already shipping for Telegram (`src/voice.zig`)
- browser automation and screenshot tools (`src/tools/browser.zig`, `src/tools/screenshot.zig`)
- image processing tool (`src/tools/image.zig`)
- rollout/canary system with shadow mode (`src/memory/lifecycle/rollout.zig`)
- distributed system patterns: circuit breakers, outbox, tenant leases, supervised restart with backoff
- SkillForge auto-discovery from GitHub/ClaHub/HuggingFace (`src/skillforge.zig`)
- Litestream S3 WAL replication per user (`deploy/k8s/zaki-bot/`)
- OpenClaw migration path built (`src/migration.zig`)
- Prometheus metrics endpoint with ServiceMonitor + PrometheusRule (`/metrics`)
- security: 5 sandbox backends, encrypted secrets, audit logging (`src/security/`)
- durable memory and diagnostics foundations

## Competitive Feature Matrix

| Area | Claude Code | OpenClaw | Nullalis Today | Nullalis Target |
|---|---|---|---|---|
| Core interaction | terminal-native REPL with rich slash commands and execution loop | online gateway plus CLI, chat, web, apps, nodes | online SSE chat plus CLI and 19 channel paths | online-first agent with coding-grade execution UX |
| Session model | conversation/session management, resume, export, compact | gateway-owned routing, DM scopes, daily and idle reset, agent bindings | persistent `main/thread/task/cron` lanes and tenant session keys | one canonical session and lane contract with user-visible controls |
| Tool system | explicit tool registry, permissions, concurrency, presets (40+ tools) | shared core tools plus channel-owned actions (40+ tools) | 42 tool implementations with vtable dispatch and tool profiles | explicit tool metadata, approval classes, safe presets |
| Plan and approval | plan mode, ask-once, per-tool approvals, wildcard rules | strong safety defaults on channel ingress and device trust | policy and 5 sandbox backends exist, but approval UX is thin | first-class execute/plan/review/approve modes |
| Background tasks | dedicated task tools and task records | durable task ledger with notify policies and audit (SQLite) | subagent lifecycle exists, durability improving | task system as a first-class online feature |
| Multi-agent | agent tool, team tools (TeamCreate/Delete), send-message | isolated multi-agent routing and background child sessions | spawn/delegate/subagent exist | named teams, inspectable delegation, task-backed coordination |
| Context and compaction | mature context management in QueryEngine, query snipping | pluggable context engine lifecycle with plugin hooks | strong memory stack, auto-compaction on token pressure, continuity pipeline | explicit context engine contract and better compaction policy |
| Memory | CLAUDE.md files (project/user/team), extracted memories | QMD/Honcho, session JSONL, search-optimized indexing | **10+ backends, 9-stage retrieval, vector plane with circuit breakers, semantic cache** | scoped durable state plus working state with selective recall |
| Transcript hygiene and provenance | mature session/runtime artifacts | strong session repair and inter-session provenance semantics | partial continuity and identity truth, limited transcript hygiene | transcript repair, provenance tagging, and pruning become explicit runtime systems |
| Extensibility | plugins, skills, MCP client and server, bundled plugins | plugins by capability, channels/providers/services, context engine plugins, ClawHub | skills, MCP client, SkillForge auto-discovery, connectors partial | skills + MCP + connectors under one capability graph |
| Online control plane | bridge and remote session handoff, but CLI-first | gateway as product control plane with WebChat and Control UI | SSE API, diagnostics, tenant runtime, Prometheus metrics | online operator surface with run events, approvals, tasks, resume |
| Channel and app UX | not core product focus | 23+ channels, flagship product strength | **19 channels: Telegram, Discord, Slack, WhatsApp, Signal, Matrix, Mattermost, IRC, iMessage, Email, Lark, DingTalk, Line, OneBot, QQ + more** | stable online app/chat experience first, channel parity second |
| Voice and multimodal | voice mode (STT streaming), feature flagged | TTS (ElevenLabs/MS/system), STT, media understanding | **STT via Groq Whisper for Telegram, TTS callback, image processing tool** | voice-first mode, cross-channel audio |
| Hardware and IoT | not applicable | node commands (camera, screen, location, system.run) | **I2C, SPI, serial, MaixCam vision, firmware flashing, hardware_info** | unique edge/embedded differentiator |
| Status and review | `/doctor`, `/status`, `/review`, `/security-review`, `/usage`, `/cost` | `doctor`, `status`, `tasks audit`, `security audit` (50+ checks) | `doctor`, `status`, runtime truth, partial slash commands | operator-grade review, debug, audit, task visibility, and usage truth |
| IDE integration | VS Code, JetBrains bridge, Chrome extension, web bridge | macOS menu bar, iOS/Android nodes, WebChat | CLI and API only | IDE bridge and editor attachment (P2) |
| Streaming UX | React+Ink terminal, rich streaming, thinking replay | block streaming with human delay, per-channel modes, embedded chunker | SSE progress events, reasoning summaries, typing indicators | run-event grammar with tool visibility and approval prompts |
| Cost and usage | per-turn token/cost tracking, `/cost`, `/usage` commands | usage tracking modes (off/tokens/full) | partial usage reporting | per-turn cost, retry-aware, task cost, operator surfaces |
| Security audit | permissions command, tool approval rules | `security audit` with 50+ checks, auto-fix, threat model | policy, audit logging, sandbox detection | structured audit, security review command |

## Nullalis Target Spec

The target is not "copy Claude Code" and not "copy OpenClaw".

The target is:

1. `nullALIS` remains the canonical runtime and control plane.
2. HTTP plus SSE remains the baseline online transport.
3. Session truth remains server-owned.
4. The agent gains Claude-grade execution ergonomics.
5. The online product gains OpenClaw-grade continuity, task durability, and operator surfaces.
6. New features must fit the existing vtable and contract architecture.

### Parity Bar

The end state for this program is stricter than "good enough."

`nullALIS` should be at least on par with `Claude Code` and `OpenClaw` on the combined agent product surface:

- as capable as Claude Code on execution, operator workflow, and coding-agent ergonomics
- as capable as OpenClaw on online continuity, gateway-owned session truth, background work, and control-plane behavior
- better than both on multitenant isolation, deployment posture, and runtime contract clarity

If a proposed change does not move Nullalis toward that parity bar, it is not part of this program.

### P0: Required To Feel Best-In-Class

- explicit execution modes: `plan`, `execute`, `review`, `background`
- structured approval contract for tools and actions
- durable task ledger for spawned and detached work
- inspectable subagent and task board
- structured run-event stream for online clients
- canonical session identity and lane routing
- stronger session controls: resume, compact, export, reset, branch-like task lanes
- context assembly and compaction contract
- richer slash command and operator workflow surface
- stable skills plus MCP plus connector story

### P1: Required To Feel Complete Online

- web task board and task notifications
- approval prompts and run controls over SSE/app surfaces
- session sharing, export, and replay
- team and delegation visibility
- richer message actions across channels
- plugin-like connector ownership model
- interrupt, cancel, and steer semantics that work across API, CLI, and tasks
- transcript hygiene and provenance semantics for long-lived sessions
- auth profile and model failover visibility for real online ops

### P2: Strong Differentiators

- remote bridge or editor attachment
- named specialist teams
- context-engine plugins
- app handoff between surfaces
- richer voice and multimodal execution parity

## What Not To Import Blindly

- Do not import Claude Code's terminal UI architecture.
- Do not import OpenClaw's Node plugin runtime shape.
- Do not replace Nullalis SSE with WebSocket just to match OpenClaw.
- Do not add speculative abstractions with no shipped caller.
- Do not rewrite the agent loop before the feature contracts are explicit.

The right move is to import the product behavior and operator semantics, not the implementation style.

## Agent Core Delta

This section isolates the actual agent-runtime differences, not just product surface differences.

### Loop Shape

**Claude Code**

- conversation-owned `QueryEngine`
- deep tool-loop and retry machinery
- richer run artifacts like retry events, compaction boundaries, tool-use summaries, and cost tracking

**OpenClaw**

- gateway-owned session truth
- embedded agent runner with strong session lifecycle
- run/event model is tightly integrated with the control plane

**Nullalis today**

- real native agent loop in `src/agent/root.zig`
- bounded tool iterations
- provider-native tool calls with XML fallback
- serial or optional parallel tool dispatch
- graceful tool-iteration exhaustion summary

**Delta**

Nullalis already has a real loop. The gap is not "having a loop"; the gap is richer execution semantics, run artifacts, and operator-visible lifecycle.

### Iteration And Retry

**Claude Code**

- mature retry semantics
- explicit retry artifacts
- stronger token/cost accounting around retries

**OpenClaw**

- lifecycle and run management are more operationally explicit
- retries live inside a broader gateway/session model

**Nullalis today**

- provider call retry exists
- context exhaustion recovery exists
- tool iteration exhaustion degrades into text summary

**Delta**

Nullalis needs:

- explicit retry classes
- structured retry events
- cancellation-aware retries
- run replay that shows retries and recoveries cleanly
- auth/profile failover semantics that make retries operationally safe

### Reflection

**Claude Code**

- stronger execution-mode separation between planning, acting, reviewing, and command-scoped behavior

**OpenClaw**

- less "reflection prompt" centered, more lifecycle/policy/system centered

**Nullalis today**

- after tool execution, the loop appends a reflection message telling the model to interpret results, avoid repeating blocked calls, retry transient issues, and be careful with queued delivery claims

**Delta**

This is a good base, but it is still one generic reflection step. Nullalis needs:

- mode-specific reflection policies
- tool-class-aware reflection
- review-mode behavior separate from execute-mode behavior
- better failure-class handling instead of one generic post-tool instruction

### Prompting

**Claude Code**

- tool-specific prompt contributions
- command-driven prompt variants
- memory mechanics and mode-specific prompt shaping

**OpenClaw**

- rich system prompt assembly tied to channel, runtime, sandbox, voice, messaging, and subagent context
- minimal prompt mode for subagents

**Nullalis today**

- strong system prompt builder in `src/agent/prompt.zig`
- workspace identity files, runtime metadata, tools, safety, skills, memory guidance, and channel attachment instructions are already injected

**Delta**

Nullalis prompt quality is better than the repo currently advertises, but it still needs:

- explicit prompt profiles by run mode
- lighter subagent prompt variant
- connector/channel-specific prompt overlays without central prompt bloat
- structured tool metadata feeding the prompt instead of only raw tool schema dumps

### Context Assembly And Compaction

**Claude Code**

- stronger context artifacts and compaction boundaries
- more mature conversation-state handling

**OpenClaw**

- explicit context-engine lifecycle
- compaction and pruning treated as a subsystem

**Nullalis today**

- `context_builder`, `memory_loader`, and `compaction` already form a partial context engine
- auto-compaction, manual compaction, and force-compression exist
- continuity uses `summary_latest/*` and `timeline_summary/*`

**Delta**

Nullalis should extract its implicit system into an explicit context-engine contract:

- `ingest`
- `assemble`
- `compact`
- `after_turn`
- optional subagent hooks

This is one of the highest-leverage upgrades in the repo.

### Session And Task Semantics

**Claude Code**

- session and task workflows are rich for a coding CLI

**OpenClaw**

- strongest session/task model of the three
- task ledger is first-class
- gateway owns session truth

**Nullalis today**

- lanes and session keys are real
- spawned subagents are real
- SSE and completion replay exist
- task product is still incomplete

**Delta**

Nullalis needs a first-class task runtime and a more productized session model to truly match OpenClaw online.

### Abort, Interrupt, And Queue Control

**Claude Code**

- stronger remote-session interruption
- clearer task/session cancel paths
- richer interactive control around active work

**OpenClaw**

- stronger supervisor-style run control
- active run tracking, abort wrapping, and queue semantics are explicit

**Nullalis today**

- queue knobs exist
- stop behavior exists in some paths
- but interruptibility is not yet a first-class runtime contract

**Delta**

Nullalis needs:

- first-class abort propagation from API/CLI/channel request to provider, tools, and subagents
- explicit queue behavior as runtime truth
- steer/kill/cancel semantics that are coherent across sessions and tasks

### Transcript Hygiene And Provenance

**Claude Code**

- stronger conversation artifacting around compaction and retries

**OpenClaw**

- explicit session repair, transcript hygiene, and inter-session provenance semantics

**Nullalis today**

- strong continuity primitives
- but weaker transcript validation, repair, and provenance tagging

**Delta**

Nullalis needs:

- transcript validation and repair
- inter-session and internal-message provenance tagging
- explicit pruning and transcript hygiene policy
- durable distinction between end-user input and system-routed/internal prompts

### Channel Action Architecture

**Claude Code**

- less relevant here

**OpenClaw**

- shared message tool host with channel-owned action adapters is one of its strongest architectural moves

**Nullalis today**

- message and channel actions exist, but the ownership boundary is not yet sharp enough

**Delta**

Nullalis should adopt:

- one shared message-action host
- channel-owned scoped action adapters
- runtime scope passed into action discovery so channel behavior does not leak into core routing logic

### Cost And Usage Truth

**Claude Code**

- materially better usage and cost visibility

**OpenClaw**

- stronger operational status framing, but less centered on coding-agent cost UX

**Nullalis today**

- some usage/runtime reporting exists
- cost is not yet a first-class operator surface

**Delta**

Nullalis needs:

- per-turn token and cost accounting
- retry-aware cost visibility
- task cost visibility
- operator-facing usage surfaces that are actually useful in production

### Why This Matters

The main conclusion is:

- Nullalis did not leave behind the agent core
- Nullalis already has a credible agent core
- the missing pieces are execution semantics, operator visibility, and online productization around that core

That means the path to SOTA is an upgrade program, not a rewrite.

## Feature Implementation Map

Each feature below maps:

- what we want
- where it comes from
- current Nullalis footing
- target Nullalis owners
- implementation notes

### F1. Execution Modes And Approval Contract

**Borrow from**

- Claude Code plan mode, approval rules, tool permission checks
- OpenClaw explicit safety posture on channels and devices

**Why it matters**

Nullalis already has tools, sandboxing, and policy, but not a fully explicit execution contract that an online user can understand and control.

**Current Nullalis owners**

- `src/tools/root.zig`
- `src/agent/root.zig`
- `src/agent/commands.zig`
- `src/security/policy.zig`
- `src/security/sandbox.zig`
- `src/channels/root.zig`

**Add**

- `src/security/approval_modes.zig`
- `src/tools/metadata.zig`
- `src/agent/execution_mode.zig`

**Target behavior**

- every tool declares `read_only`, `mutating`, `background_safe`, `operator_only`, `concurrency_safe`
- every run has an explicit mode: `plan`, `execute`, `review`, `background`
- online clients can see why a tool ran, why it was blocked, and why approval was requested
- approval rules can be persisted without widening capability silently

**Implementation notes**

- keep `Tool` vtable stable; layer metadata beside it instead of mutating every call site first
- move approval decisions out of prompt-only behavior into structured policy
- make slash commands and SSE clients use the same approval engine

### F2. Structured Run Events For Online UX

**Borrow from**

- Claude Code streaming execution and tool visibility
- OpenClaw agent events, control plane, and task delivery

**Why it matters**

Nullalis already has strong SSE groundwork, but the online client needs a richer run model than `status/progress/token/done`.

**Current Nullalis owners**

- `src/gateway.zig`
- `src/observability.zig`
- `src/agent/root.zig`
- `src/subagent.zig`

**Add**

- `src/gateway/run_events.zig`
- `src/agent/run_event_types.zig`

**Target behavior**

- online stream exposes `ready`, `reply_start`, `progress`, `tool_start`, `tool_result`, `approval_required`, `task_update`, `subagent_completion`, `reasoning_summary`, `token`, `done`
- replay path can rebuild the final user-visible execution trail
- app surfaces do not need ad hoc parsing of logs

**Implementation notes**

- keep SSE transport; enrich the event grammar
- observer events should be the internal source of truth
- subagent and task events should reuse the same event schema

### F3. Task Ledger As A First-Class Product Feature

**Borrow from**

- Claude Code task tools and background-task ergonomics
- OpenClaw durable task ledger, notify policy, audit, and lifecycle

**Why it matters**

This is one of the biggest experience gaps between "agent that can spawn work" and "agent product you can trust."

**Current Nullalis owners**

- `src/subagent.zig`
- `src/tools/spawn.zig`
- `src/tools/delegate.zig`
- `src/gateway.zig`
- `src/status.zig`

**Add**

- `src/tasks/root.zig`
- `src/tasks/store.zig`
- `src/tasks/types.zig`
- `src/tasks/delivery.zig`
- `src/tools/task_list.zig`
- `src/tools/task_get.zig`
- `src/tools/task_stop.zig`

**Target behavior**

- all detached or long-running work is recorded as a task
- task states are explicit: `queued`, `running`, `succeeded`, `failed`, `timed_out`, `cancelled`, `lost`
- tasks can be inspected, stopped, replayed, and delivered safely
- slash commands and online app surfaces both expose task state

**Implementation notes**

- keep `delegate` synchronous at first
- make `spawn` the first durable detached executor
- persist output even when live delivery fails

### F4. Canonical Session Identity And Lane Policy

**Borrow from**

- OpenClaw gateway-owned session model and routing scopes
- Claude Code session resume and management ergonomics

**Why it matters**

Nullalis already has `main/thread/task/cron` lanes, but the rules must become one canonical contract and one visible user concept.

**Current Nullalis owners**

- `src/zaki_session.zig`
- `src/session.zig`
- `src/gateway.zig`
- `src/channels/dispatch.zig`
- `src/diagnostics/runtime_truth.zig`
- `src/tools/runtime_info.zig`

**Add**

- `src/session/policy.zig`
- `src/session/export.zig`

**Target behavior**

- one canonical session identity module
- one documented lane policy
- slash commands and API clients can resume, branch, compact, reset, export, and inspect sessions
- background work and webhooks attach to clear requester and child session identities

**Implementation notes**

- centralize lane parsing before adding new session UX
- expose the session contract in the API, not just the CLI

### F5. Context Engine And Better Compaction

**Borrow from**

- OpenClaw context-engine lifecycle
- Claude Code query-engine-grade context management

**Why it matters**

Nullalis memory is strong, but the hot path is still more trim-first than intelligence-first.

**Current Nullalis owners**

- `src/agent/root.zig`
- `src/agent/memory_loader.zig`
- `src/agent/context_builder.zig`
- `src/agent/compaction.zig`
- `src/memory/root.zig`
- `src/memory/lifecycle/summarizer.zig`

**Add**

- `src/agent/context_engine.zig`
- `src/agent/context_engine_legacy.zig`
- later `src/agent/context_engine_retrieval.zig`

**Target behavior**

- clear lifecycle: `ingest`, `assemble`, `compact`, `after_turn`, optional subagent hooks
- current behavior becomes the legacy engine
- compaction decisions are measurable and visible
- memory retrieval and prompt assembly stop being partly implicit

**Implementation notes**

- this should be a contract extraction first, not a semantic rewrite
- first land the interface and wrap current behavior

### F6. Skills, MCP, And Connectors As One Capability Graph

**Borrow from**

- Claude Code skills plus MCP client and server model
- OpenClaw plugin capability ownership

**Why it matters**

Nullalis already has skills, MCP, and tool integrations, but they are not yet one clean extensibility story.

**Current Nullalis owners**

- `src/skills.zig`
- `src/skillforge.zig`
- `src/mcp.zig`
- `src/tools/composio.zig`
- `src/tools/root.zig`

**Add**

- `src/connectors/root.zig`
- `src/connectors/manifest.zig`
- `src/connectors/runtime.zig`
- `src/connectors/auth_bindings.zig`

**Target behavior**

- skills remain prompt/workflow assets
- MCP remains the protocol bridge
- connectors own external API and CLI integration surfaces
- the agent can discover capabilities without every integration becoming a bespoke core feature

**Implementation notes**

- do not force a full plugin runtime in first pass
- use capability registration and manifests before dynamic code loading

### F7. Named Teams And Inspectable Delegation

**Borrow from**

- Claude Code agent/team tools
- OpenClaw isolated agents and deterministic routing

**Why it matters**

Nullalis already has the seed of multi-agent work. The gap is inspectability, specialization, and stable handoff.

**Current Nullalis owners**

- `src/subagent.zig`
- `src/tools/spawn.zig`
- `src/tools/delegate.zig`
- `src/agent/commands.zig`

**Add**

- `src/coordination/root.zig`
- `src/coordination/team.zig`
- `src/coordination/messages.zig`
- `src/coordination/registry.zig`

**Target behavior**

- named specialist agents
- explicit delegation records
- inspectable messages and artifacts between parent and child work
- team execution becomes explainable instead of magical

**Implementation notes**

- land after task ledger basics
- avoid hidden recursive autonomy in the first pass

### F8. Online Operator Surface

**Borrow from**

- OpenClaw control plane and task board model
- Claude Code session, status, and review workflow expectations

**Why it matters**

The end user wants a Claude-like or OpenClaw-like experience online, not just a backend that streams tokens.

**Current Nullalis owners**

- `src/gateway.zig`
- `docs/openapi-v1.yaml`
- `src/status.zig`
- `src/doctor.zig`
- `src/agent/commands.zig`

**Add**

- `docs/online-agent-api-spec.md`
- later app-side contract consumers outside this repo

**Target behavior**

- first-class online controls for approvals, tasks, session resume, export, compact, kill, model switch, and runtime status
- one stable API contract for app clients
- run and task state are app-grade, not debug-grade
- interrupt and steer controls are explicit and reliable

**Implementation notes**

- define the API contract before overbuilding UI-facing backend behavior
- prefer additive endpoints and SSE event expansion over transport churn

### F9. Claude-Grade Operator Commands

**Borrow from**

- Claude Code command density and workflow coverage

**Why it matters**

A powerful agent feels much better when high-frequency workflows are explicit commands rather than hidden prompt incantations.

**Current Nullalis owners**

- `src/agent/commands.zig`
- `src/status.zig`
- `src/doctor.zig`

**Target behavior**

- keep current runtime-oriented commands
- add operator workflows for review, session export, task board, compact, model switch, permissions, and diagnostics
- keep command semantics aligned with online API actions

**Recommended additions**

- `/review`
- `/security-review`
- `/tasks`
- `/permissions`
- `/resume`
- `/compact`
- `/share` or `/export`

**Implementation notes**

- only add commands once the underlying contract exists
- commands should be thin wrappers over structured runtime features

### F10. Safety, Audit, And Explainability

**Borrow from**

- Claude Code permission explainability
- OpenClaw operator audit and route visibility

**Why it matters**

As Nullalis becomes more agentic online, operators need a clean reason for every action, refusal, approval request, and delivery path.

**Current Nullalis owners**

- `src/security/policy.zig`
- `src/security/audit.zig`
- `src/diagnostics/runtime_truth.zig`
- `src/status.zig`
- `src/doctor.zig`
- `src/observability.zig`

**Target behavior**

- every blocked action maps to a structured reason
- audit surfaces show capability, policy, and requester context
- doctor and status expose task pressure, approval posture, and degraded capability state

**Implementation notes**

- explainability should come from structured metadata, not log scraping

### F11. Abort And Interrupt Runtime

**Borrow from**

- Claude Code remote session interruption
- OpenClaw active run tracking and abort wrapping

**Current Nullalis owners**

- `src/agent/root.zig`
- `src/subagent.zig`
- `src/gateway.zig`
- `src/session.zig`
- `src/tools/spawn.zig`
- `src/tools/delegate.zig`

**Add**

- `src/agent/abort.zig`
- `src/tasks/control.zig`

**Target behavior**

- requests can be interrupted cleanly
- tasks can be cancelled without orphaning state
- queue and interrupt semantics are explicit across API, CLI, and channels

### F12. Transcript Hygiene And Provenance

**Borrow from**

- OpenClaw transcript repair and inter-session provenance model

**Current Nullalis owners**

- `src/session.zig`
- `src/agent/root.zig`
- `src/agent/compaction.zig`
- `src/memory/root.zig`
- `src/subagent.zig`

**Add**

- `src/session/transcript_hygiene.zig`
- `src/session/provenance.zig`

**Target behavior**

- transcript validation and repair
- provenance tagging for internal, routed, and user-authored messages
- explicit pruning and transcript hygiene policy

### F13. Auth Profile Failover

**Borrow from**

- OpenClaw auth profile rotation and provider failover semantics

**Current Nullalis owners**

- `src/providers/root.zig`
- `src/providers/reliable.zig`
- `src/config.zig`
- `src/agent/commands.zig`

**Add**

- `src/providers/auth_profiles.zig`
- `src/providers/failover_runtime.zig`

**Target behavior**

- provider auth profile order and cooldown tracking
- visible failover reasons
- per-session provider/auth override behavior

### F14. Cost And Usage Runtime

**Borrow from**

- Claude Code cost tracking and usage visibility

**Current Nullalis owners**

- `src/agent/root.zig`
- `src/status.zig`
- `src/doctor.zig`
- `src/gateway.zig`

**Add**

- `src/usage_runtime.zig`

**Target behavior**

- per-turn cost and token accounting
- retry-aware usage truth
- task cost visibility
- useful operator-facing usage surfaces

### F15. Channel Action Adapters

**Borrow from**

- OpenClaw shared message tool with channel-owned action adapters

**Current Nullalis owners**

- `src/tools/message.zig`
- `src/channels/root.zig`
- `src/channels/dispatch.zig`
- `src/gateway.zig`

**Add**

- `src/channels/action_adapter.zig`

**Target behavior**

- shared message-action host
- channel-owned action discovery and execution
- less channel-specific branching in core runtime code

## Recommended Delivery Order

This is the safest order for implementation.

1. `F1` execution modes and tool metadata
2. `F2` structured run events
3. `F3` durable task ledger
4. `F4` canonical session identity and lane contract
5. `F5` context-engine extraction
6. `F8` online operator API contract
7. `F9` richer operator commands
8. `F11` abort and interrupt runtime
9. `F12` transcript hygiene and provenance
10. `F13` auth profile failover
11. `F14` cost and usage runtime
12. `F15` channel action adapters
13. `F6` capability graph for skills, MCP, connectors
14. `F7` named teams and inspectable delegation
15. `F10` final audit and explainability tightening

## Strategic Constraint

Because Nullalis already runs as an isolated API/CLI runtime inside its own pod and OS boundary, the target should not be "local terminal clone of Claude Code."

The correct strategic posture is:

- remote-first runtime
- server-owned session and task truth
- app, CLI, and channel clients as frontends to one execution core
- connectors and MCP for arbitrary backend reach
- explicit execution contracts because the runtime is long-lived and online

This is a structural advantage over both reference products when executed correctly.

## Success Criteria

Nullalis reaches the intended product shape when all of these are true:

- an online user can see what the agent is doing, not just the final answer
- approvals are explicit and explainable
- background work is durable, inspectable, and stoppable
- session continuity is predictable across chat, tasks, and automation
- skills, MCP, and integrations feel like one coherent platform
- subagents are real, visible collaborators rather than hidden threads
- the product feels as capable as Claude Code for execution, and as online and continuous as OpenClaw
- the agent core itself is no longer meaningfully behind either reference runtime on loop quality, prompting, compaction, reflection, and task/session semantics
- abort, provenance, failover, channel action ownership, and usage truth are no longer hidden gaps versus the reference products

## Features Missing From Original Plan (Added After Deep Repo + Reference Scan)

### F16. Edge/Offline Deployment Mode

**Why it matters**

Nullalis already runs as a single Zig binary with Ollama for local LLM + local embeddings + SQLite storage. No other agent runtime in this class can run fully offline on a Raspberry Pi. This is a genuine differentiator.

**Current Nullalis owners**

- `src/providers/ollama.zig`
- `src/memory/engines/sqlite.zig`
- `src/memory/vector/embeddings_ollama.zig`
- `build.zig` (engine feature flags)

**Target behavior**

- explicit `edge` deployment profile that strips cloud dependencies
- local-first memory, provider, and embedding defaults
- zero external network requirement when configured for edge

### F17. Channel Breadth as Product Surface

**Why it matters**

19 channels is the widest coverage of any agent runtime. Neither Claude Code nor OpenClaw matches this. The roadmap treats channels as infrastructure but should treat them as a product feature.

**Current Nullalis owners**

- `src/channels/` (19 implementations)
- `src/channels/dispatch.zig` (routing, supervised restart, outcome publishing)
- `src/inbound_canonicalizer.zig` (cross-channel identity resolution with TTL cache)

**Missing**

- channel-specific capability discovery (what actions work where)
- cross-channel session continuity (start in Telegram, continue in web)
- channel health dashboard for operators
- per-channel streaming modes (OpenClaw has off/partial/block/progress)

### F18. Voice-First Agent Mode

**Why it matters**

STT+TTS pipeline already works for Telegram. Foundation exists but voice is not yet a first-class execution mode.

**Current Nullalis owners**

- `src/voice.zig` (Groq Whisper STT, TTS callback)
- `src/channels/telegram.zig` (audio message handling)

**Target behavior**

- voice mode as explicit execution mode (not just transcribe→text→synthesize)
- voice across channels (Discord voice, WhatsApp audio, etc.)
- streaming TTS for long responses

### F19. Semantic Cache as Cost Control

**Why it matters**

Already built (`src/memory/lifecycle/semantic_cache.zig`) but not exposed as operator feature.

**Target behavior**

- operator-visible cache hit rate, cost savings, cache policies
- wired into usage/cost runtime (F14) as "avoided cost"
- configurable per-user or per-deployment

### F20. Memory Migration and Portability

**Why it matters**

OpenClaw migration exists (`src/migration.zig`). Memory export/import should be a user-facing feature.

**Target behavior**

- brain portability: export/import memory to new deployment
- snapshot export with provenance metadata (aligns with `plan.md` Track D)
- import from external sources (other assistants, note apps)

### F21. IDE Bridge and Editor Integration

**Borrow from**

- Claude Code: VS Code/JetBrains bridge, Chrome extension, web bridge, teleport between devices
- OpenClaw: macOS menu bar, WebChat, Control UI dashboard

**Why it matters**

Both reference products invest heavily in being where the user works. Nullalis is API-only today.

**Target behavior (P2, not blocking SOTA core)**

- VS Code extension that connects to nullalis gateway
- web dashboard for operator controls (session, tasks, approvals)
- later: Chrome extension, mobile companion

### F22. Progressive Streaming with Human Pacing

**Borrow from**

- OpenClaw: block streaming with `humanDelay` (800-2500ms), `EmbeddedBlockChunker`, per-channel streaming modes
- Claude Code: React+Ink streaming with thinking replay

**Why it matters**

Current SSE streaming works but lacks the polished feel of either reference product.

**Current Nullalis owners**

- `src/gateway.zig` (SSE handler)
- `src/channels/telegram.zig` (100ms chunk delays already exist)

**Target behavior**

- configurable per-channel streaming modes (off/partial/block/progress)
- human-like pacing for messaging channels
- code-fence safety in chunk breaks

### F23. Security Audit Command

**Borrow from**

- OpenClaw: `security audit` with 50+ check IDs, `--deep`, `--fix`, `--json` modes
- Claude Code: `/security-review` command

**Why it matters**

As Nullalis becomes more agentic, a structured security self-check is essential.

**Current Nullalis owners**

- `src/security/policy.zig`
- `src/security/audit.zig`
- `src/doctor.zig`

**Target behavior**

- `/security-audit` command checking: tool blast radius, exec approval drift, network exposure, sandbox config, policy drift
- auto-fixable items
- JSON output for CI integration

### F24. Presence and Typing System

**Borrow from**

- OpenClaw: presence subscription over WebSocket, online/offline status, typing indicators

**Current Nullalis owners**

- `src/channels/telegram.zig` (typing indicators exist)
- `src/channels/discord.zig` (typing state exists)

**Target behavior**

- cross-channel presence aggregation
- typing indicators for all channels that support it
- presence API for app clients

### F25. Decision Journal

**From plan.md suggested features**

**Why it matters**

The agent keeps structured decision records — what was decided, why, which memories were used, what changed. Improves trust and explainability.

**Target behavior**

- structured decision records stored in memory system
- accessible via operator commands
- feeds into audit and trust graph

### F26. Simulation Mode

**From plan.md suggested features**

**Why it matters**

Before action, user can ask "simulate what you'd do this week." Builds trust before autonomy is increased.

**Target behavior**

- dry-run execution mode that shows planned actions without executing
- cost estimation for planned work
- approval checkpoint before transition to real execution

## Claude Code Features Not Yet In Plan

These exist in Claude Code but are not yet addressed in the nullalis roadmap:

1. **Worktree isolation** — git worktree per agent/session (`EnterWorktreeTool`). Useful for parallel coding tasks.
2. **Multi-pass execution** — `/passes` for iterative refinement loops.
3. **Notebook editing** — Jupyter notebook cell editing tool.
4. **REPL tool** — run code in Python/Node REPL.
5. **Session teleport** — transfer session to another device (`/teleport`).
6. **Auto-dream** — background ideation during idle time.
7. **Hooks system** — pre/post tool execution hooks for user customization.
8. **Query snipping** — compress context while preserving semantics.
9. **Feature flag infrastructure** — GrowthBook-based A/B testing and dead-code elimination.
10. **Direct connect / server mode** — persistent Claude Code instances.
11. **Plugin auto-update** — skill and plugin version management.
12. **MCP server mode** — expose nullalis tools to other agents (not just client).
13. **Team memory sync** — shared team knowledge base.

## OpenClaw Features Not Yet In Plan

These exist in OpenClaw but are not yet addressed in the nullalis roadmap:

1. **ACP (Agent Client Protocol)** — external harness support for Codex, Claude Code, Cursor, Copilot. Lets nullalis delegate to other agent runtimes.
2. **Canvas / A2UI** — agent-driven visual workspace with push/reset/eval/snapshot.
3. **Node/device commands** — camera, screen record, location, system.run, system.notify on mobile nodes.
4. **WebChat** — built-in static chat UI over WebSocket.
5. **Control UI** — web dashboard for status/config/tools/sessions.
6. **DM pairing model** — short pairing codes for new DM access (simpler than current approach).
7. **Block streaming with EmbeddedBlockChunker** — sophisticated chunking with code-fence safety.
8. **Standing orders** — persistent recurring instructions.
9. **Message debouncing/coalescing** — rapid message merge for better UX.
10. **Context engine plugins** — pluggable context assembly strategies.
11. **Threat model documentation** — formal threat model atlas.
12. **Bonjour/mDNS discovery** — local device discovery for nodes.

## Decision Rule

When choosing between a Claude Code behavior and an OpenClaw behavior:

- prefer Claude Code for execution UX, tool ergonomics, and operator workflows
- prefer OpenClaw for session ownership, online control plane, task durability, and routing
- prefer Nullalis for runtime contracts, tenant posture, implementation architecture, channel breadth, memory sophistication, and edge deployment

That is the synthesis path that can make Nullalis state-of-the-art without turning it into a clone.
