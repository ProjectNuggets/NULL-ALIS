# Branch Board: agent-sota-execution-board

Status: active execution
Owner: agent/runtime
Last updated: 2026-04-03

## Purpose

Drive `nullalis` from a strong runtime into a best-in-class agent without rewrite theater.

This board assumes:

1. per-user cell pods are now real and working
2. `nullalis` keeps its current Zig runtime/tool core
3. the main gap is coherence, UX, context, memory, tasks, and policy metadata
4. each milestone lands on its own branch and closes cleanly before the next one starts

## Operating Rules

1. One branch = one milestone.
2. Use `main` as the base for every branch unless a branch explicitly stacks on another.
3. Do not mix milestone work on one branch.
4. Every branch must end with:
   - `zig build test --summary all`
   - at least one behavior-level eval or spot-check for the milestone
   - a short review report
   - an explicit go/no-go decision
5. Keep the cell hardening track running in parallel; it can block merges if substrate truth regresses.

## Cross-Cutting Eval Track

Every milestone should improve the agent measurably, not just structurally.

Track at least one relevant eval or real-session spot-check for each branch:

1. prompt consistency and contradiction drift
2. tool-choice quality
3. context quality and budget usage
4. memory recall relevance
5. task completion and artifact quality
6. UX quality:
   - fast first visible output
   - progress on long-running turns
   - concise result-first replies

## Global Design Stance

### Keep

1. [src/agent/root.zig](/Users/nova/Desktop/nullalis/src/agent/root.zig) as the core turn loop
2. [src/tools/root.zig](/Users/nova/Desktop/nullalis/src/tools/root.zig) as the tool substrate
3. [src/agent/commands.zig](/Users/nova/Desktop/nullalis/src/agent/commands.zig) as the operator/command seed
4. [src/agent/memory_loader.zig](/Users/nova/Desktop/nullalis/src/agent/memory_loader.zig) and [src/agent/compaction.zig](/Users/nova/Desktop/nullalis/src/agent/compaction.zig) as the continuity base
5. [src/tools/spawn.zig](/Users/nova/Desktop/nullalis/src/tools/spawn.zig), [src/tools/delegate.zig](/Users/nova/Desktop/nullalis/src/tools/delegate.zig), and [src/subagent.zig](/Users/nova/Desktop/nullalis/src/subagent.zig) as async/subagent seeds
6. [src/tools/schedule.zig](/Users/nova/Desktop/nullalis/src/tools/schedule.zig) as timed job truth

### Evolve

1. prompt ownership
2. context assembly
3. memory packaging
4. execution UX
5. operator introspection

### Add

1. context builder/cache/report
2. memory scopes/index/selective recall
3. task/artifact system
4. approval modes and tool metadata
5. connector manifests and executors

### Rewire

1. prompt policy into one canonical layer
2. async execution into task-backed flows
3. memory from text preamble to explicit state sections
4. UX from “wait, then wall of text” to fast progress and result-first delivery

## Branch Sequence

### C0. Cell Hardening

- Branch: `ops/cell-hardening-v1`
- Runs in parallel with the agent milestones below.

#### Goal

Keep the per-user cell substrate boring, trustworthy, and measurable while the agent improves on top of it.

#### Evolve

1. [src/gateway.zig](/Users/nova/Desktop/nullalis/src/gateway.zig)
2. [src/controller.zig](/Users/nova/Desktop/nullalis/src/controller.zig)
3. [src/cell_k8s_api.zig](/Users/nova/Desktop/nullalis/src/cell_k8s_api.zig)
4. [src/cell_spec.zig](/Users/nova/Desktop/nullalis/src/cell_spec.zig)
5. [deploy/k8s/zaki-bot/02-configmap.yaml](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/02-configmap.yaml)
6. [deploy/k8s/zaki-bot/05-deployment.yaml](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/05-deployment.yaml)
7. [deploy/k8s/zaki-bot/18-controller-deployment.yaml](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/18-controller-deployment.yaml)
8. [deploy/k8s/zaki-bot/smoke.sh](/Users/nova/Desktop/nullalis/deploy/k8s/zaki-bot/smoke.sh)

#### Acceptance

1. cell creation, warm routing, drain/undrain, and restart recovery hold in canary
2. no broker/cell split-brain
3. PgBouncer path remains healthy under test load
4. no routing identity regressions

#### Stop / Review Gate

1. canary cycle is boring
2. no cross-user routing/storage issues
3. runtime tests are green

### M1. Kernel UX

- Branch: `feat/kernel-ux-v1`
- Status: complete for now, app follow-up continues outside this repo

#### Goal

Make the agent crisp, responsive, and pleasant to use without flattening personality.

#### Evolve

1. [src/agent/prompt.zig](/Users/nova/Desktop/nullalis/src/agent/prompt.zig)
2. [src/capabilities.zig](/Users/nova/Desktop/nullalis/src/capabilities.zig)
3. [src/daemon.zig](/Users/nova/Desktop/nullalis/src/daemon.zig)
4. [src/tools/root.zig](/Users/nova/Desktop/nullalis/src/tools/root.zig)
5. [src/agent/root.zig](/Users/nova/Desktop/nullalis/src/agent/root.zig)
6. [src/agent/commands.zig](/Users/nova/Desktop/nullalis/src/agent/commands.zig)
7. [src/workspace_templates/AGENTS.md](/Users/nova/Desktop/nullalis/src/workspace_templates/AGENTS.md)
8. high-impact tool descriptions under [src/tools](/Users/nova/Desktop/nullalis/src/tools)

#### Rewire

1. `prompt.zig` becomes the canonical operational contract
2. `capabilities.zig` becomes summary-only
3. `daemon.zig` owns wake-only rules
4. `AGENTS.md` becomes local norms, not a second policy engine
5. final reply behavior becomes result-first and compact by default

#### Add

1. explicit precedence rule in the prompt
2. turn-mode hint: `chat`, `execute`, `wake`, `repair`, `operator`
3. compact blessed-path tool matrix
4. progress/UX guidance for:
   - fast first output
   - short progress updates
   - plan before risky multi-step work
   - artifacts/links over giant pasted output

#### Acceptance

1. no contradiction between prompt, capabilities, daemon, tool policy, and workspace template
2. agent chooses `schedule` vs `cron_*`, `spawn` vs `schedule`, and `delegate` vs direct handling more reliably
3. default replies are concise and result-first
4. long-running turns expose progress instead of going silent

#### Stop / Review Gate

1. `zig build test --summary all`
2. prompt contradiction review
3. UX spot-check on long and short turns

### M2. Context Introspection

- Branch: `feat/context-introspection-v1`
- Status: in progress

#### Goal

Engineer context as a real runtime surface instead of implicit prompt glue.

#### Current Baseline

1. current turns already enrich memory via the retrieval pipeline in [src/agent/memory_loader.zig](/Users/nova/Desktop/nullalis/src/agent/memory_loader.zig) and [src/memory/retrieval/engine.zig](/Users/nova/Desktop/nullalis/src/memory/retrieval/engine.zig)
2. recall quality today comes from:
   - scoped session recall plus global durable facts
   - `summary_latest/*` and `context_anchor_current` priority injection
   - hybrid retrieval when rollout allows it
   - temporal decay and optional MMR/LLM reranking
3. M2 should expose and structure this stack before trying to replace it

#### Evolve

1. [src/agent/root.zig](/Users/nova/Desktop/nullalis/src/agent/root.zig)
2. [src/agent/context_tokens.zig](/Users/nova/Desktop/nullalis/src/agent/context_tokens.zig)
3. [src/agent/compaction.zig](/Users/nova/Desktop/nullalis/src/agent/compaction.zig)
4. [src/agent/memory_loader.zig](/Users/nova/Desktop/nullalis/src/agent/memory_loader.zig)
5. [src/agent/commands.zig](/Users/nova/Desktop/nullalis/src/agent/commands.zig)

#### Add

1. `src/agent/context_builder.zig`
2. `src/agent/context_cache.zig`
3. `src/agent/context_report.zig`

#### Rewire

1. `turn()` calls a dedicated context builder
2. context is split into explicit buckets:
   - runtime/system truth
   - workspace identity/personality
   - memory
   - recent conversation
   - active task/runtime state
3. `/context` becomes a first-class inspection surface backed by real context state

#### Acceptance

1. context can be explained and inspected
2. prompt rebuild churn is reduced
3. context sections are explicit and budget-aware

#### Stop / Review Gate

1. context report reviewed on real sessions
2. no unexplained token-budget regressions
3. tests green

### M3. State Memory

- Branch: `feat/state-memory-v1`

#### Goal

Upgrade memory from “recalled text” into scoped durable state plus working state.

#### Evolve

1. [src/agent/memory_loader.zig](/Users/nova/Desktop/nullalis/src/agent/memory_loader.zig)
2. [src/agent/compaction.zig](/Users/nova/Desktop/nullalis/src/agent/compaction.zig)
3. [src/memory/root.zig](/Users/nova/Desktop/nullalis/src/memory/root.zig)
4. retrieval code under [src/memory](/Users/nova/Desktop/nullalis/src/memory)
5. [src/agent/commands.zig](/Users/nova/Desktop/nullalis/src/agent/commands.zig)

#### Add

1. `src/memory/index.zig`
2. `src/memory/types.zig`
3. `src/memory/selective_recall.zig`
4. `src/memory/workspace_memdir.zig`
5. `src/memory/scopes.zig`

#### Rewire

1. `MEMORY.md` becomes the index, not the whole memory body
2. working buffer and continuity state become explicit
3. memory becomes a dedicated context section, not just a preamble string
4. working-state primitives are pulled out of raw history so later event-ledger/state work has a clear home

#### Acceptance

1. memory is clearly scoped by user/project/cell
2. selective recall improves relevance and lowers context waste
3. working-state continuity survives compaction and interruption better

#### Stop / Review Gate

1. recall quality spot-check on real workflows
2. no regression in durable truth behavior
3. tests green

### M4. Execution Engine

- Branch: `feat/execution-engine-v1`

#### Goal

Turn async/background work into a first-class task and artifact engine.

#### Evolve

1. [src/tools/spawn.zig](/Users/nova/Desktop/nullalis/src/tools/spawn.zig)
2. [src/tools/delegate.zig](/Users/nova/Desktop/nullalis/src/tools/delegate.zig)
3. [src/subagent.zig](/Users/nova/Desktop/nullalis/src/subagent.zig)
4. [src/tools/schedule.zig](/Users/nova/Desktop/nullalis/src/tools/schedule.zig)
5. [src/agent/root.zig](/Users/nova/Desktop/nullalis/src/agent/root.zig)
6. [src/agent/commands.zig](/Users/nova/Desktop/nullalis/src/agent/commands.zig)

#### Add

1. `src/tasks/root.zig`
2. `src/tasks/types.zig`
3. `src/tasks/store.zig`
4. `src/tasks/artifacts.zig`
5. `src/tasks/executors/shell.zig`
6. `src/tasks/executors/agent.zig`
7. `src/tasks/executors/workflow.zig`
8. `src/tasks/executors/monitor.zig`
9. `src/tools/task_create.zig`
10. `src/tools/task_get.zig`
11. `src/tools/task_list.zig`
12. `src/tools/task_output.zig`
13. `src/tools/task_stop.zig`

#### Rewire

1. `spawn` becomes task-backed
2. `delegate` and `subagent` become executor paths inside the task system
3. `schedule` stays timed truth and can trigger tasks when appropriate
4. artifacts become first-class outputs

#### Acceptance

1. background work has lifecycle, output, and artifacts
2. tasks are inspectable and stoppable
3. `schedule` and `task` semantics stay separate and clear

#### Stop / Review Gate

1. prove one real long-running task flow end to end
2. no ambiguity between task and scheduler ownership
3. tests green

### M5. Policy Capability

- Branch: `feat/policy-capability-v1`

#### Goal

Make autonomy explainable through explicit approval modes and tool metadata.

#### Evolve

1. [src/security/policy.zig](/Users/nova/Desktop/nullalis/src/security/policy.zig)
2. [src/tools/root.zig](/Users/nova/Desktop/nullalis/src/tools/root.zig)
3. [src/tools/shell.zig](/Users/nova/Desktop/nullalis/src/tools/shell.zig)
4. [src/agent/root.zig](/Users/nova/Desktop/nullalis/src/agent/root.zig)
5. [src/agent/commands.zig](/Users/nova/Desktop/nullalis/src/agent/commands.zig)

#### Add

1. `src/security/approval_modes.zig`
2. `src/tools/metadata.zig`

#### Rewire

1. tool capability becomes machine-readable
2. approval posture moves from inferred behavior to explicit modes
3. background safety and concurrency hints become structured instead of prompt-only

#### Acceptance

1. user and operator can explain why the agent asked, acted, or refused
2. tool classes are explicit:
   - read-only
   - mutating
   - background-safe
   - operator-only
   - concurrency-safe

#### Stop / Review Gate

1. destructive-path review before merge
2. no silent capability widening
3. tests green

### M6. Expansion

- Branch: `feat/expansion-v1`

#### Goal

Expand breadth cleanly through connectors, skills, and MCP without turning the core into chaos.

#### Evolve

1. [src/tools/http_request.zig](/Users/nova/Desktop/nullalis/src/tools/http_request.zig)
2. [src/tools/shell.zig](/Users/nova/Desktop/nullalis/src/tools/shell.zig)
3. [src/skills.zig](/Users/nova/Desktop/nullalis/src/skills.zig)
4. [src/skillforge.zig](/Users/nova/Desktop/nullalis/src/skillforge.zig)
5. [src/mcp.zig](/Users/nova/Desktop/nullalis/src/mcp.zig)
6. [src/tools/composio.zig](/Users/nova/Desktop/nullalis/src/tools/composio.zig)
7. [src/tools/delegate.zig](/Users/nova/Desktop/nullalis/src/tools/delegate.zig)
8. [src/subagent.zig](/Users/nova/Desktop/nullalis/src/subagent.zig)

#### Add

1. `src/connectors/root.zig`
2. `src/connectors/manifest.zig`
3. `src/connectors/api.zig`
4. `src/connectors/cli.zig`
5. `src/connectors/auth_bindings.zig`
6. later, if needed:
   - `src/coordination/root.zig`
   - `src/coordination/team.zig`
   - `src/coordination/messages.zig`
   - `src/coordination/registry.zig`

#### Rewire

1. API and CLI breadth moves from raw improvisation to connector contracts
2. skills, connectors, MCP, and subagents become a cleaner capability graph
3. optional managed integration gateways can be supported as connector backends, not core truth

#### Acceptance

1. one API connector works end to end
2. one CLI connector works end to end
3. skills remain first-class and do not get bypassed by connector sprawl
4. no secret leakage in connector execution

#### Stop / Review Gate

1. verify credential handling and secret posture before serious rollout
2. prove at least one clean connector reuse case
3. tests green

### M7. Multi-Agent Teams

- Branch: `feat/multi-agent-teams-v1`

#### Goal

Turn subagents from a seed feature into clear, inspectable specialist teams.

#### Evolve

1. [src/subagent.zig](/Users/nova/Desktop/nullalis/src/subagent.zig)
2. [src/tools/spawn.zig](/Users/nova/Desktop/nullalis/src/tools/spawn.zig)
3. [src/tools/delegate.zig](/Users/nova/Desktop/nullalis/src/tools/delegate.zig)
4. [src/tasks](/Users/nova/Desktop/nullalis/src/tasks) once M4 lands

#### Add

1. `src/coordination/root.zig`
2. `src/coordination/team.zig`
3. `src/coordination/messages.zig`
4. `src/coordination/registry.zig`

#### Acceptance

1. named agents exist
2. delegation is inspectable
3. task and artifact handoff between agents is clear

#### Stop / Review Gate

1. no opaque “subagent magic”
2. delegation policy reviewed before merge
3. tests green

### M8. Sync Surfaces

- Branch: `feat/sync-surfaces-v1`

#### Goal

Define what follows the user, what stays local to a cell, and what may become shared.

#### Evolve

1. memory and runtime surfaces touched by M2 and M3
2. cell-runtime surfaces touched by C0

#### Add

1. `src/sync/settings_sync.zig`
2. `src/sync/memory_sync.zig`
3. later `src/sync/team_memory_sync.zig`

#### Acceptance

1. user settings sync rules are explicit
2. memory sync rules are explicit by scope
3. execution state remains cell-local unless explicitly exported

#### Stop / Review Gate

1. review against pod architecture before rollout
2. no execution-state bleed across cells
3. tests green

### M9. B2B Control Plane

- Branch: `feat/b2b-control-plane-v1`

#### Goal

Scale the personal cell model into org and team orchestration after the core agent is strong.

#### Add Later

1. `nulltickets`
2. `nullboiler`

#### Acceptance

1. org-scale work queues and policy do not pollute the personal-agent kernel
2. the cell model stays intact

#### Stop / Review Gate

1. do not start until M4 through M8 are stable enough to support it

## Recommended Start Order

1. `feat/kernel-ux-v1`
2. `feat/context-introspection-v1`
3. `feat/state-memory-v1`
4. `feat/execution-engine-v1`
5. `feat/policy-capability-v1`
6. `feat/expansion-v1`
7. `feat/multi-agent-teams-v1`
8. `feat/sync-surfaces-v1`
9. `feat/b2b-control-plane-v1`

Parallel:

1. `ops/cell-hardening-v1`

## Definition of “Done” Per Branch

Each branch is done only when all are true:

1. scope stayed within the milestone
2. tests are green
3. at least one behavior eval or real-session spot-check was recorded
4. acceptance checks are satisfied
5. a short review report exists
6. the next branch can start without re-deciding architecture
