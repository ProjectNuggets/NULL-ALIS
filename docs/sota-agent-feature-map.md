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

- small-footprint Zig runtime
- clear vtable extension boundaries
- strong tenant/runtime contract
- stable SSE chat delivery
- durable memory and diagnostics foundations
- security and multitenant posture

## Competitive Feature Matrix

| Area | Claude Code | OpenClaw | Nullalis Today | Nullalis Target |
|---|---|---|---|---|
| Core interaction | terminal-native REPL with rich slash commands and execution loop | online gateway plus CLI, chat, web, apps, nodes | online SSE chat plus CLI and channel paths | online-first agent with coding-grade execution UX |
| Session model | conversation/session management, resume, export, compact | gateway-owned routing, DM scopes, daily and idle reset, agent bindings | persistent `main/thread/task/cron` lanes and tenant session keys | one canonical session and lane contract with user-visible controls |
| Tool system | explicit tool registry, permissions, concurrency, presets | shared core tools plus channel-owned actions | broad tool registry and tool profiles | explicit tool metadata, approval classes, safe presets |
| Plan and approval | plan mode, ask-once, per-tool approvals, rules | strong safety defaults on channel ingress and device trust | policy and sandbox exist, but approval UX is thin | first-class execute/plan/review/approve modes |
| Background tasks | dedicated task tools and task records | durable task ledger with notify policies and audit | subagent lifecycle exists, durability improving | task system as a first-class online feature |
| Multi-agent | agent tool, team tools, send-message tools | isolated multi-agent routing and background child sessions | spawn/delegate/subagent exist | named teams, inspectable delegation, task-backed coordination |
| Context and compaction | mature context management in query engine | pluggable context engine lifecycle | strong memory stack, trim-first hot-path compaction | explicit context engine contract and better compaction policy |
| Transcript hygiene and provenance | mature session/runtime artifacts | strong session repair and inter-session provenance semantics | partial continuity and identity truth, but limited transcript hygiene | transcript repair, provenance tagging, and pruning become explicit runtime systems |
| Extensibility | plugins, skills, MCP client and server | plugins by capability, channels/providers/services, context engine plugins | skills and MCP client exist, connectors are partial | skills + MCP + connectors under one capability graph |
| Online control plane | bridge and remote session handoff, but CLI-first | gateway as product control plane | SSE API, diagnostics, tenant runtime | online operator surface with run events, approvals, tasks, resume |
| Channel and app UX | not core product focus | flagship product strength | Telegram and app path exist, more channels exist in code | stable online app/chat experience first, channel parity second |
| Status and review | `/doctor`, `/status`, `/review`, `/security-review`, `/usage` | `doctor`, `status`, `tasks audit`, routing diagnostics | `doctor`, `status`, runtime truth, partial slash commands | operator-grade review, debug, audit, task visibility, and usage truth |

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

## Closing Remaining Gaps

This section is additive gap-closure scope. It is intentionally separate from
the original target spec so the final SOTA bar is explicit.

- Coding workflow artifacts must be first-class: changed files, diff summary, commands run, tests run, test results, review state, and patch outcome.
- Patch safety must be a runtime contract: risky paths, dirty worktree policy, rollback/retry checkpoints, and partial-success handling.
- Nullalis needs a host/runtime capability contract, not just online APIs: hosted, CLI, desktop, VS extension, and edge/device runtimes must share one agent model with graceful degradation.
- Retry, recovery, failover, interruption, and resumed-run behavior must appear as structured run artifacts rather than hidden implementation details.
- Steering semantics must be explicit and separate from stop, cancel, and abort semantics.
- Approval must be modeled as a full state machine, not just a yes/no gate.
- Prompt scaffold, policy set, persona source, and model/profile choice must be captured as provenance for every run.
- Memory needs an explicit write, correction, and repair policy so durable behavior improves without silent drift.
- Multi-agent work needs an explicit coordination contract for ownership, write-scope isolation, merge/conflict handling, and accountability.
- Cross-surface handoff must preserve continuity and provenance across app, API, CLI, extension, and later edge/device surfaces.
- Background work needs an explicit notification policy.
- SOTA claims require a final parity eval pack that exercises real coding workflows, interruption, approval loops, reconnect/resume, degraded hosts, and multi-agent coordination.

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

### F1.5A. Liveness Narration — "Feels Alive"

**Borrow from**

- Claude Code real-time status narration: always showing what tool is running, why, and what it's waiting on
- Claude Code task decomposition: breaking complex work into visible sub-steps

**Why it matters**

This is the single biggest UX gap between nullalis and Claude Code. An agent that goes silent during work feels broken. An agent that narrates feels alive and trustworthy. This is the difference between a tool and a digital twin.

**Current Nullalis owners**

- `src/agent/prompt.zig` — system prompt has one line about "send short progress updates"
- `src/observability.zig` — observer emits `tool_call_start`, `tool_call`, `turn_stage` internally
- `src/gateway.zig` — SSE `progress` events exist but only carry generic "thinking" labels

**Add**

- `src/agent/narration.zig` — narration engine that converts observer events into user-facing status
- `src/agent/task_planner.zig` — task decomposition: detect complex requests, emit step plan, track per-step progress

**Target behavior**

- agent always states what it's about to do before doing it ("Using web_search to find..."), names the tool, explains why, reports the result
- complex requests trigger visible plan: "I'll do this in 3 steps: 1. Look up... 2. Compare... 3. Write..."
- each step emits progress events and completion markers
- narration verbosity is configurable: quiet / normal / verbose (via `/verbose`)
- background/subagent work suppresses narration to avoid noise
- typing indicators on channels reflect real activity

**Implementation notes**

- wire observer events to a narration layer that produces user-facing text
- narration output feeds SSE `progress` events (existing transport) and channel typing indicators
- prompt instructions teach the model when to decompose vs when to just execute
- plan revision: if a step fails, agent re-emits revised plan

### F1.5B. Prompt Architecture And Persona

**Borrow from**

- Claude Code structured prompt assembly with tool-specific contributions
- OpenClaw rich system prompt tied to channel, runtime, and subagent context

**Why it matters**

The system prompt is the agent's soul. A monolithic prompt builder limits composability and makes mode-specific behavior fragile. A configurable persona is required for the digital-twin feel.

**Current Nullalis owners**

- `src/agent/prompt.zig` — monolithic `buildSystemPrompt` with inline section strings

**Add**

- `src/agent/prompt_sections.zig` — composable named sections
- `src/agent/learning.zig` — correction detector, preference extractor, durable behavioral facts

**Target behavior**

- prompt is assembled from composable sections: identity, persona, turn_classification, narration_rules, tool_policy, safety, workspace, memory, datetime, runtime
- persona reads from workspace `SOUL.md` with runtime defaults and per-config overrides
- persona dimensions: warmth, proactivity, verbosity, formality
- agent detects corrections ("no, I meant...", "don't do that", "always use...") and stores as durable behavioral preferences
- behavioral preferences are injected into future prompts automatically
- lighter subagent prompt variant excludes persona/narration sections

**Implementation notes**

- keep `buildSystemPrompt` as the assembly entry point, refactor internals to section registry
- learning loop writes to memory with `behavioral_preference/` key prefix
- newer corrections supersede older ones on the same topic
- persona default: "attentive digital twin" — warm, moderately proactive, concise, informal

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
2. `F1.5A` liveness narration and task decomposition
3. `F1.5B` prompt architecture and persona
4. `F2` structured run events
5. `F3` durable task ledger
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

- the agent feels alive: always narrating what it's doing, which tool it picked, why, and what it's waiting on
- complex requests are decomposed into visible sub-steps with per-step status
- the agent learns from corrections and applies them in future turns without being told twice
- the persona feels like a digital twin, not a generic chatbot
- an online user can see what the agent is doing, not just the final answer
- approvals are explicit and explainable
- background work is durable, inspectable, and stoppable
- session continuity is predictable across chat, tasks, and automation
- skills, MCP, and integrations feel like one coherent platform
- subagents are real, visible collaborators rather than hidden threads
- the product feels as capable as Claude Code for execution, and as online and continuous as OpenClaw
- the agent core itself is no longer meaningfully behind either reference runtime on loop quality, prompting, compaction, reflection, and task/session semantics
- abort, provenance, failover, channel action ownership, and usage truth are no longer hidden gaps versus the reference products

## Decision Rule

When choosing between a Claude Code behavior and an OpenClaw behavior:

- prefer Claude Code for execution UX, tool ergonomics, and operator workflows
- prefer OpenClaw for session ownership, online control plane, task durability, and routing
- prefer Nullalis for runtime contracts, tenant posture, and implementation architecture

That is the synthesis path that can make Nullalis state-of-the-art without turning it into a clone.
