# DTaaS Evolution Ledger

Status: canonical execution ledger as of `2026-03-16`

## Purpose
This document is now the active source of truth for recovery and execution order.

It replaces the old "future only, deferred until v0.7 completion" stance because current runtime evidence shows we first need to restore stability before expanding the product surface again.

Execution order:
1. `P0` nullalis stability
2. `P1` zaki-prod BFF recovery and restart UX
3. `P3` session behavior and lane policy

## Implementation Status
Changes already landed in this repo on `2026-03-16`:

1. `P0` fast containment is in place.
- `src/channels/dispatch.zig` now emits delivery outcomes only for `source == "heartbeat"`.
- Non-heartbeat proactive/sourced delivery outcomes are suppressed for beta while we continue root-cause work.

2. `P3` beta defaults now align to correctness-first serial behavior.
- `src/user_settings.zig` now maps `assistant_mode=balanced` to:
  - `queue_mode="serial"`
  - `queue_cap=12`
  - `queue_drop="summarize"`
- `deploy/k8s/zaki-bot/05-deployment.yaml` now sets the same serial base defaults for users without saved config.

3. Linux/K8s crash-vs-restart evidence collection is now explicit.
- `deploy/k8s/zaki-bot/collect-runtime-evidence.sh` captures restart counts, last termination state, describe output, and filtered logs.

Changes landed on `2026-03-17`:

4. Memory hygiene conversation pruning now actually catches autosave rows.
- `src/memory/lifecycle/hygiene.zig` now prunes via category listing (`.conversation`) and parses both legacy `conv_*` and runtime `autosave_user_*` / `autosave_assistant_*` timestamp keys.
- Added regression coverage for autosave timestamp parsing and sqlite prune behavior.

5. Session-scoped recall now filters in SQL before result limiting.
- `src/memory/engines/sqlite.zig` now applies `session_id` constraints directly in `fts5Search` and `likeSearch` queries before `LIMIT`.
- This removes a silent failure mode where session-scoped memories were dropped by global top-K rows and appeared "amnesic" under load.
- Added regression tests for both `likeSearch` and `fts5Search` session filtering under limit pressure.

Still pending:
1. permanent P0 ownership/lifetime fix in the delivery path
2. `P1` zaki-prod BFF retry/reconnect implementation in the BFF repo
3. deeper P3 telemetry for slow tool/network attribution

## Current Reality
The current codebase does not have a single problem. It has three different failure classes and they must stay separated in planning:

1. Real nullalis process crashes still exist.
- Recent crash artifacts on this machine show newer failures after the delivery-outcome feedback loop was added.
- The strongest current code-path signal is outbound delivery / delivery outcome handling:
  - `src/channels/dispatch.zig`
  - `src/bus.zig`
  - `src/daemon.zig`

2. Some "stopped conversation" reports are not process crashes.
- Same-session turns are serialized by `Session.mutex` in `src/session.zig`.
- When one turn is slow, later turns wait behind it and the chat feels frozen even if the process is still alive.

3. Some terminal stop events are external termination, not runtime crashes.
- `scripts/gateway-clean.sh` is only a log-filtering wrapper.
- A terminal line like `Terminated: 15` indicates `SIGTERM` from outside the process, not by itself a nullalis segfault/abort.

## Code-Backed Findings

### P0 — nullalis Stability
1. The delivery-outcome path is a fresh risk area.
- `src/channels/dispatch.zig` now emits `DeliveryOutcome` objects for sourced/proactive outbound messages.
- `src/bus.zig` carries those outcomes on a dedicated queue.
- `src/daemon.zig` consumes them in `deliveryOutcomeThread`.

2. The older embedding transport crash is not the whole story anymore.
- That path had already been documented as fixed.
- Current crash evidence points to a different area, so earlier "GO" statements for local stability cannot be treated as current truth.

3. In-flight turns are not durably safe yet.
- `src/session.zig` persists the user+assistant turn only after `agent.turn()` returns.
- If the process dies mid-turn or mid-stream, the interrupted turn is not guaranteed to survive restart.

### P1 — zaki-prod BFF
1. BFF still matters, but it is not the fix for the runtime crash.
2. The correct BFF job is:
- hide pre-stream contention/retry cases,
- normalize retryable failures,
- give users a clean reconnect/retry experience when backend restarts happen.
3. BFF cannot invisibly replay a stream after first SSE bytes have already been forwarded.

### P3 — Session Behavior
1. `src/session.zig` serializes same-session work by design.
2. Before the beta containment pass, the runtime mostly favored strict serial behavior over UX smoothness.
3. That policy preserved message order, but under bursty same-session traffic it could still feel like the assistant "stopped".
4. Current beta-direction changes now move the default user path toward bounded `latest` behavior while keeping the deeper session-policy cleanup in scope.

## Historical Inputs Now Treated As Archived
These documents remain useful as historical evidence, but they are no longer canonical for active decision-making:

1. `docs/v0.7-backlog.md`
- historical sprint ordering reference
- not the active execution order now

2. `docs/reports/2026-03-15-v07-t8/t8-fix-decision-report.md`
- useful for what changed
- no longer current truth after later crash evidence

3. `docs/reports/2026-03-16-lock-wait-stabilization/decision.md`
- useful for lock-wait tuning evidence
- not sufficient as the full runtime stability decision

## Active Recovery Plan

### P0 — Restore nullalis Stability
Goal: eliminate process-kill / crash regressions before more product surface work ships.

Scope:
1. Reproduce the latest crash signature locally from current code.
2. Trace ownership/lifetime through:
- outbound message production,
- outbound dispatch,
- delivery outcome emission,
- delivery outcome consumption.
3. Reduce blast radius fast if needed:
- gate or temporarily disable non-essential delivery-outcome feedback wiring if it is confirmed as the regression source.
4. Add regression coverage for:
- concurrent outbound delivery,
- delivery outcome queue handoff,
- shutdown during active outbound work,
- sourced/proactive messages under load.

Exit criteria:
1. `zig build test --summary all` passes.
2. Release build passes.
3. Repro harness no longer generates a new crash artifact.
4. Gateway survives repeated sourced/proactive outbound stress.

### P1 — Harden zaki-prod BFF Around Runtime Restarts
Goal: make runtime instability or restarts feel recoverable instead of chaotic.

Scope:
1. Preserve pre-stream retry for lock/contention cases.
2. Distinguish:
- pre-stream retryable backend failure,
- mid-stream disconnect,
- exhausted retry budget.
3. Normalize backend restart/interruption into product-safe client behavior:
- clean retryable error before stream start,
- explicit reconnect-required behavior after stream start.

Exit criteria:
1. No raw upstream lock/conflict leaks to product clients.
2. Pre-stream retry behavior is deterministic.
3. Mid-stream failure UX is explicit and test-covered.

### P3 — Simplify Session Behavior
Goal: make user conversations feel continuous under contention without hiding important guarantees.

Scope:
1. Re-evaluate the default main-lane policy for user chat.
2. Decide where `serial` is still correct versus where `latest` or bounded supersede behavior is better.
3. Keep background/proactive work off the user main lane.
4. Add diagnostics that clearly separate:
- model time,
- lock wait,
- queue depth,
- slow tool/network side effects.

Exit criteria:
1. Same-session bursts no longer create silent multi-minute stalls under normal usage.
2. User-visible policy is predictable and documented.
3. Diagnostics clearly show whether a bad experience came from crash, lock, or upstream latency.

## Immediate Next Steps
1. `P0`: reproduce and isolate the current delivery-outcome crash path.
2. `P0`: decide whether to hot-disable that path or patch it directly.
3. `P1`: codify restart-aware SSE failure handling once the runtime failure modes are pinned down.
4. `P3`: revisit main-lane defaults only after crash risk is back under control.

## Longer-Term North-Star
After stability is restored, the broader DTaaS direction still stands:
1. persistent user memory
2. proactive behavior with strict controls
3. cross-channel continuity
4. real tool execution
5. strict tenant isolation and safety
