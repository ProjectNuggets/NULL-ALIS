# PROJECT LEDGER

## Mission
- Build the best-in-class digital twin / second-brain agent system.
- Win the trusted Digital Twin Core before expanding into broader platform or network complexity.
- Optimize for product usefulness, system coherence, technical simplicity, trustworthy state, and fast execution without recklessness.

## Current Product Truth
- The primary wedge is one persistent per-user digital twin, not a general agent platform.
- The core user promise is continuity across app and Telegram, durable memory, bounded proactive behavior, and useful execution.
- The gateway is the control plane; the product is the assistant and its working loop.
- Postgres is canonical production state.
- The filesystem workspace remains first-class product surface.
- Markdown memory remains live and synchronized as a mirror/projection surface, not the canonical source of truth.
- TrustMesh / multi-agent delegation network is phase 2, same-tenant first, explicit-trust only.

## Current Architecture Truth
- `src/gateway.zig` is the main control plane: internal API surface, tenant runtime cache, integration routing, and a growing exception hub.
- `src/zaki_state.zig` is the canonical tenant-state authority for config, secrets, onboarding, heartbeat, jobs, channel bindings, leases, and tenant memory rows.
- `src/session.zig` and `src/agent/root.zig` own the active conversation loop, hot in-memory session state, turn execution, and shutdown/eviction behavior.
- `src/memory/root.zig` defines the memory contract; `src/memory/engines/zaki_dual.zig` wraps canonical Postgres memory with markdown mirror behavior for tenant Postgres mode.
- `src/agent/memory_loader.zig` builds warm memory injection; `src/agent/commands.zig` writes continuity artifacts.
- `src/inbound_canonicalizer.zig` maps inbound channel identities into canonical user/session lanes.
- `src/tools/root.zig`, `src/providers/root.zig`, and `src/channels/root.zig` provide coherent vtable-based extension surfaces.
- `spawn` is currently in-memory detached work; `delegate` is synchronous single-turn specialist completion.

## Locked Invariants
- Postgres is the canonical durable state for tenant production paths.
- The filesystem workspace remains first-class and must not be treated as disposable.
- Markdown memory must remain live and synchronized with canonical memory as a mirror/projection layer.
- Cross-channel behavior must preserve one coherent same-user truth; no accidental state forks by channel.
- Session lane semantics remain explicit and distinct: `main`, `thread`, `task`, `cron`.
- `summary_latest/*` is the canonical current continuity object; `timeline_summary/*` is append-only historical continuity.
- Debug/audit artifacts must not become default prompt memory.
- Secret mutation requires confirmation, backend authority, and no plaintext reveal after save.
- Explicit consent is the default for cross-agent access.
- Memory inheritance starts as read-only curated snapshots, not live shared memory.
- Read-only and approval-first behavior is preferred for sensitive or destructive actions.
- TrustMesh stays phase 2 until the Digital Twin Core is trustworthy and operationally smooth.

## What Works
- Per-user tenant runtime model is real and already valuable.
- Canonical identity mapping and session-lane routing are in place.
- The memory model already has strong primitives: hot session history, warm continuity artifacts, cold recall/audit surfaces.
- Runtime truth tooling already exists: status, doctor, runtime_info, diagnostics.
- Product settings already map to runtime behavior via a relatively clean normalization path.
- Proactive rails already exist with dedupe, rate, cooldown, and burst controls.
- The vtable architecture is coherent and still the right extension backbone.
- Existing `delegate` and `spawn` tools give us enough primitives for a thin execution layer without building a new engine first.

## What Is Fragile
- `src/gateway.zig` is carrying too much product truth and too many special cases.
- Secret handling behavior does not fully match the locked product trust model.
- Continuity lifecycle ownership is split across compaction, seed, eviction, and shutdown.
- Runtime pruning still happens on the request path.
- Markdown mirror sync is useful but still operationally noisy and potentially amplifying work.
- Detached subagent work is not yet durable or reliably inspectable.
- Telegram has accumulated several special-case delivery and state paths.
- Documentation authority is still split across plans, boards, ledgers, and reports.
- Execution flow is not yet surfaced simply enough for the founder to see task, owner, status, and result without reading code.

## Top Risks
- Secret read/write behavior can violate trust if plaintext readback or unconfirmed mutation survives.
- Weak or low-signal continuity summaries can become canonical memory.
- Request-path runtime pruning can add hidden latency and teardown cost to unrelated turns.
- `zaki_dual` read-time markdown sync can create performance and merge-drift pressure.
- Gateway monolith risk can slow all high-leverage changes.
- Detached task execution is not yet durable, so `spawn` can feel unreliable.
- Fallback and mirror behavior can create stale-state confusion if not explicitly surfaced.
- Cross-channel truth can still feel inconsistent if diagnostics and user-visible behavior drift.
- The repo is at risk of expanding into delegation/platform work before core trust is locked.
- Parallel work can drift without one canonical project anchor.

## Active Priorities
- Restore control over project truth with one canonical ledger and clearer operating assumptions.
- Simplify the execution model using patterns worth copying from Claude Code and OpenClaw.
- Make the existing digital twin value feel smoother before expanding capability surface.
- Keep task breakdown, delegation, memory, and status explicit instead of implicit.
- Reuse existing primitives before adding new layers or durability machinery.

## In Progress
- Establish `PROJECT_LEDGER.md` as the single anchor file for future prompts and execution framing.
- Re-baseline next execution work around simplification and reference patterns from Claude Code and OpenClaw.

## Deferred
- Broad task-engine / detached-work expansion beyond current seeds.
- TrustMesh / multi-agent network execution.
- Memory inheritance product surfaces beyond curated snapshot-based read-only behavior.
- Full trust-core hardening bundle can follow once the execution loop is simpler and more visible.
- Broad platformization, marketplace, or public agent API work.
- Grand refactors or gateway decomposition without immediate product leverage.

## Recent Decisions
- Use `PROJECT_LEDGER.md` as the canonical prompt anchor in-repo.
- Keep Digital Twin Core first; TrustMesh remains phase 2.
- Keep Postgres canonical with filesystem workspace and markdown mirror as first-class supporting surfaces.
- Favor control, consolidation, and simplification over new feature breadth.
- Learn from Claude Code and OpenClaw for next-step execution patterns.
- It is acceptable to postpone heavier complexity and durability for now.
- If we improve execution next, it should be a thin layer on top of existing primitives, not a new subsystem.

## Known Debt
- `src/gateway.zig` is too large and too central.
- Secret API contract needs hardening.
- Continuity artifact roles need simplification and clearer ownership.
- Runtime pruning belongs off the request path.
- `zaki_dual` needs a cleaner sync/watermark strategy over time.
- Detached task truth needs durability and inspection before it can be relied on.
- Doc authority and branch-history sprawl need continued discipline.
- More real workflow evals are needed to validate smoothness, not just correctness.
- Execution status and builder workflow are too implicit today.

## Next Recommended Step
- Execute `execution-simplification-v1`: build one thin top-level execution loop that can break work into explicit tasks, route bounded subtasks through existing `delegate`/`spawn` primitives, and make task/status/result visible without adding a new orchestration platform.

## Open Questions
- Does any internal consumer still depend on raw secret readback today?
- Should `session_summary/*` remain only as compatibility/audit artifact or be removed from the normal lifecycle entirely?
- What maintenance path should own tenant runtime pruning long-term?
- What is the minimum operator-facing truth surface needed to make fallback/degraded state obvious?
- What is the smallest visible execution surface that gives founder control without introducing a full task engine?
