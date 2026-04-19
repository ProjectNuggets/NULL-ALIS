# Regression-Safe S-Tier Refactor Plan

Status: parked for later execution
Date: 2026-04-08
Scope: architecture consolidation without intended product behavior change

## Goal

Make the repository materially easier to change, reason about, and extend
without introducing new bugs, trust regressions, or drift between runtime
surfaces.

This plan is intentionally not a rewrite. It is a behavior-preserving
consolidation program.

Target outcomes:
- one canonical session/lane identity surface
- one canonical tenant-scoping path
- one canonical runtime-assembly path
- one canonical outbound delivery path
- one canonical continuity artifact policy
- one canonical task snapshot/recovery path
- smaller coordination files with narrower blast radius

## Important Reality

This work is not needed to ship an immediate user-facing feature.

It is needed if we want future changes to stay fast, safe, and predictable.

The value is:
- fewer drift bugs
- lower change cost
- smaller high-risk edit zones
- clearer truth ownership

## Non-Goals

Out of scope for this plan:
- changing product semantics on purpose
- adding new execution-platform complexity
- expanding permissions or policy
- redesigning provider transport
- redesigning the memory model
- deleting proven extension contracts
- broad gateway feature work mixed into refactor PRs

## Locked Invariants

These must remain true during the refactor:

1. `zig build test --summary all` passes after every phase.
2. High-risk phases also compile with `zig build -Doptimize=ReleaseSmall`.
3. Session key semantics remain stable unless explicitly approved later.
4. `summary_latest/*`, `timeline_summary/*`, and `context_anchor_current` keep
   their current lifecycle roles.
5. Postgres remains canonical durable state for tenant production paths.
6. Markdown memory remains a supporting mirror/projection surface.
7. Subagents stay on a reduced tool surface.
8. No secret-handling broadening.
9. No request-path regressions in latency-sensitive paths.
10. Every extracted module lands behind characterization tests before old code
    is deleted.

## Existing Strengths To Preserve

These abstractions are already good and should survive intact:

1. Vtable extension surfaces in `src/providers/root.zig`,
   `src/channels/root.zig`, `src/tools/root.zig`, and
   `src/memory/root.zig`.
2. `src/session.zig` as the owner of hot conversation state.
3. The hot/warm/cold continuity model in `src/agent/commands.zig`,
   `src/agent/memory_loader.zig`, and `docs/agent-lifecycle-spec.md`.
4. Provider composition in `src/providers/runtime_bundle.zig` and
   `src/providers/reliable.zig`.
5. Tool-profile separation in `src/tools/root.zig`.

## Architectural Redundancies To Remove

The refactor should delete or collapse the following duplication:

1. Session/lane/task parsing duplicated across:
   - `src/diagnostics/runtime_truth.zig`
   - `src/tools/runtime_info.zig`
   - `src/subagent.zig`
   - `src/memory/root.zig`
   - `src/gateway.zig`
2. Tenant scoping and scoped user/root resolution duplicated across:
   - `src/tenant_runtime_scope.zig`
   - `src/tools/runtime_info.zig`
   - `src/gateway.zig`
3. Runtime assembly duplicated across:
   - `src/main.zig`
   - `src/channel_loop.zig`
   - `src/gateway.zig`
   - `src/agent/cli.zig`
4. Subagent completion routing duplicated across:
   - `src/channel_loop.zig`
   - `src/gateway.zig`
5. Outbound dispatch logic partially duplicated across:
   - `src/channels/dispatch.zig`
   - `src/gateway.zig`
   - `src/daemon.zig`
   - `src/tools/message.zig`
   - `src/cron.zig`
6. Continuity artifact classification duplicated across:
   - `src/agent/commands.zig`
   - `src/agent/memory_loader.zig`
   - `src/memory/root.zig`
   - `src/tools/memory_timeline.zig`
7. Task snapshot/session reconstruction duplicated across:
   - `src/subagent.zig`
   - `src/diagnostics/runtime_truth.zig`
8. Gateway acting as a cross-subsystem exception hub in:
   - `src/gateway.zig`

## Refactor Method

Every workstream follows the same pattern:

1. Add characterization tests for current behavior.
2. Extract shared logic into one new or expanded module.
3. Migrate callers to the new module.
4. Keep temporary compatibility wrappers for one phase if needed.
5. Delete old helper copies only after all callers are moved.

The order matters. Do not split large files first. First centralize shared
logic, then split orchestration files once the shared logic is no longer
duplicated.

## Validation Gates

Required after every PR:

```bash
zig build test --summary all
```

Required after high-risk PRs:

```bash
zig build -Doptimize=ReleaseSmall
```

Required for phases touching gateway/subagent/session delivery:
- verify existing SSE tests still pass
- verify completion-event replay tests still pass
- verify no request-path teardown/pruning regressions

Required for phases touching continuity:
- verify `summary_latest/*` promotion tests still pass
- verify `session_summary/*` stays off the normal prompt path
- verify `context_anchor_current` remains metadata-only for prompt loading

## Workstreams

### Workstream 0: Behavior Freeze

Purpose:
- establish a safety net before moving any logic

Target files:
- `src/gateway.zig`
- `src/channel_loop.zig`
- `src/subagent.zig`
- `src/tools/runtime_info.zig`
- `src/agent/memory_loader.zig`
- `src/agent/commands.zig`

Deliverables:
- characterization tests for session classification
- characterization tests for tenant scoping
- characterization tests for subagent completion delivery
- characterization tests for continuity artifact selection
- characterization tests for task recovery/session derivation

Exit criteria:
- current behavior is covered by tests, even where the design is imperfect

### Workstream 1: Canonical Session Identity

Purpose:
- make `src/zaki_session.zig` the only place that knows how session keys work

Primary file:
- `src/zaki_session.zig`

Callers to migrate:
- `src/diagnostics/runtime_truth.zig`
- `src/tools/runtime_info.zig`
- `src/subagent.zig`
- `src/memory/root.zig`
- `src/gateway.zig`
- `src/channel_loop.zig`

Expected additions:
- lane classification helpers
- task-id extraction helpers
- main/thread/task/cron predicates
- compatibility helpers for legacy task session reconstruction if required

Exit criteria:
- no local lane/task parsing helpers remain outside `src/zaki_session.zig`

### Workstream 2: Canonical Tenant Scoping

Purpose:
- make one reusable path for scoped user id, numeric user id, workspace root,
  and state-manager access

Primary file:
- `src/tenant_runtime_scope.zig`

Callers to migrate:
- `src/tools/runtime_info.zig`
- `src/gateway.zig`
- `src/main.zig`
- any future diagnostics or status paths

Expected additions:
- scoped user resolution helpers
- scoped numeric user resolution helpers
- scoped tenant workspace/root helpers
- one shared struct for tenant-scoped runtime context

Exit criteria:
- runtime info and gateway do not carry parallel scoping logic

### Workstream 3: Canonical Runtime Assembly

Purpose:
- create one shared builder for provider bundle, tool set, memory runtime,
  observer wiring, and session manager construction

New module:
- `src/runtime_factory.zig`

Callers to migrate:
- `src/main.zig`
- `src/channel_loop.zig`
- `src/gateway.zig`
- `src/agent/cli.zig`

Must preserve:
- tool-profile differences
- observer differences
- tenant vs non-tenant runtime differences
- current memory/session-store wiring behavior

Exit criteria:
- runtime bootstrapping is assembled in one module and consumed by wrappers

### Workstream 4: Canonical Subagent Completion Delivery

Purpose:
- remove duplicate “capture origin -> append assistant message -> persist
  completion event -> deliver or defer” flows

New module:
- `src/delivery/subagent_completion.zig`

Callers to migrate:
- `src/channel_loop.zig`
- `src/gateway.zig`

Must preserve:
- app completion-event SSE behavior
- local fallback delivery behavior
- bus-publish behavior
- completion-event cleanup rules

Exit criteria:
- channel loop and gateway only provide environment-specific hooks
- the shared routing logic exists in one place

### Workstream 5: Canonical Outbound Dispatch

Purpose:
- make `src/channels/dispatch.zig` the sole outbound delivery surface

Primary file:
- `src/channels/dispatch.zig`

Callers to migrate:
- `src/gateway.zig`
- `src/daemon.zig`
- `src/tools/message.zig`
- `src/cron.zig`

Must preserve:
- virtual channel handling
- tenant dispatch context
- stats/metrics side effects
- event-bus semantics

Exit criteria:
- no bespoke outbound delivery path remains outside dispatch and channel impls

### Workstream 6: Canonical Continuity Artifact Policy

Purpose:
- move key classification and lifecycle policy into one executable module

New module:
- `src/agent/continuity.zig`
  or
- `src/memory/lifecycle/continuity.zig`

Callers to migrate:
- `src/agent/commands.zig`
- `src/agent/memory_loader.zig`
- `src/memory/root.zig`
- `src/tools/memory_timeline.zig`

Must preserve:
- `summary_latest/*` promotion rules
- `timeline_summary/*` fallback rules
- `session_summary/*` compatibility-only behavior
- `context_anchor_current` metadata-only treatment

Exit criteria:
- continuity artifact naming and classification are not redefined in multiple
  files

### Workstream 7: Canonical Task Snapshot and Recovery

Purpose:
- unify durable task snapshot interpretation, runtime session derivation,
  and restart recovery

New module:
- `src/task_runtime.zig`
  or
- `src/subagent/task_ledger.zig`

Callers to migrate:
- `src/subagent.zig`
- `src/diagnostics/runtime_truth.zig`

Must preserve:
- queued/running/completed/failed semantics
- requester lane vs runtime task lane separation
- legacy snapshot compatibility
- restart failure marking behavior

Exit criteria:
- task-state recovery and task-truth reporting derive from one source

### Workstream 8: Gateway Decomposition

Purpose:
- split `src/gateway.zig` only after shared logic has been centralized

Likely new modules:
- `src/gateway/tenant_runtime.zig`
- `src/gateway/chat_sse.zig`
- `src/gateway/webhooks.zig`
- `src/gateway/fallback_sync.zig`
- `src/gateway/metrics.zig`

Must not happen before:
- Workstreams 1 through 7 are complete or mostly complete

Exit criteria:
- gateway becomes orchestration and routing, not a product-truth catch-all

## PR Roadmap

This should be executed as small PRs, not one branch-wide change.

### PR 1: Characterization Freeze
- add missing regression tests only
- no behavior changes

### PR 2: Session Identity Extraction
- centralize session/lane helpers in `src/zaki_session.zig`
- migrate callers

### PR 3: Tenant Scope Extraction
- centralize scoped user/root helpers in `src/tenant_runtime_scope.zig`
- migrate runtime info first

### PR 4: Runtime Factory Introduction
- add `src/runtime_factory.zig`
- move one caller first, likely `src/channel_loop.zig`

### PR 5: Runtime Factory Adoption
- migrate `src/main.zig`, `src/agent/cli.zig`, and non-tenant paths

### PR 6: Tenant Runtime Factory Adoption
- migrate gateway tenant runtime assembly to the factory

### PR 7: Subagent Completion Delivery Extraction
- add shared delivery module
- migrate channel loop and gateway

### PR 8: Outbound Dispatch Unification
- route gateway/daemon/message/cron through `src/channels/dispatch.zig`

### PR 9: Continuity Policy Extraction
- centralize continuity helpers and key classification

### PR 10: Task Snapshot Recovery Extraction
- centralize task snapshot parsing and recovery semantics

### PR 11+: Gateway Split
- split by concern only after the above are stable

## Sequence Rules

These are strict:

1. Do not mix behavior changes into extraction PRs.
2. Do not split `src/gateway.zig` before shared helper logic is centralized.
3. Do not alter continuity semantics while extracting continuity helpers.
4. Do not broaden any security-sensitive surface while refactoring.
5. Do not delete compatibility wrappers until all callers are migrated.
6. Do not trust visual code similarity; use characterization tests first.

## Risk Table

### Low Risk
- test additions
- helper extraction with no semantic change
- moving existing string-prefix checks into shared helpers

### Medium Risk
- runtime assembly centralization
- outbound dispatch centralization
- gateway file splitting after extraction

### High Risk
- any change touching:
  - `src/gateway.zig`
  - `src/subagent.zig`
  - `src/session.zig`
  - `src/tools/root.zig`
  - `src/memory/root.zig`
  - `src/zaki_state.zig`

For high-risk PRs:
- require new boundary/failure-mode tests
- prefer one workstream slice only

## Success Criteria

The plan is successful when:

1. Session key semantics are implemented once.
2. Tenant scoping semantics are implemented once.
3. Runtime construction is implemented once.
4. Subagent completion delivery is implemented once.
5. Outbound dispatch uses one canonical path.
6. Continuity artifact policy is implemented once.
7. Task snapshot interpretation is implemented once.
8. `src/gateway.zig` is smaller and less central.
9. Future feature changes touch fewer files.
10. The repo still passes the full test suite without behavior regressions.

## Activation Note

When this plan is resumed later:

1. Re-read:
   - `PROJECT_LEDGER.md`
   - `docs/agent-lifecycle-spec.md`
   - `docs/session-key-policy.md`
   - this plan
2. Re-run:

```bash
zig build test --summary all
zig build -Doptimize=ReleaseSmall
```

3. Start with PR 1 only.

If the repo has materially changed by then, update this document before
starting implementation.
