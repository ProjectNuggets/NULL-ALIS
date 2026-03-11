# Runtime Budget Tightening Plan (v0.2 Discussion Draft)

## Goal
Reduce long-turn latency and perceived stream stalls without breaking correctness, autonomy safety, or tool reliability.

Primary outcomes:
- bounded foreground turn time
- explicit per-origin execution budgets
- no silent multi-minute waits without user-visible progress
- deterministic timeout behavior across provider + tool + scheduler paths

## Current Root Cause Summary
- `/api/v1/chat/stream` is synchronous: `done` is emitted only after `processMessage(...)` returns.
- Agent tool loop can run many iterations (`max_tool_iterations`), each with expensive provider/tool calls.
- Provider calls can be retried and each call can have large timeout windows.
- There is no hard end-to-end turn deadline at the session layer.

## Scope
In scope:
- foreground and background runtime budgets
- provider/tool timeout propagation from one shared deadline
- progress heartbeat while waiting
- diagnostics for budget hits and queue wait time

Out of scope:
- model quality tuning
- changing business logic of individual tools
- policy broadening (auth/connect in background remains unchanged)

## Step-by-Step Plan

### Step 1: Add a single TurnBudget contract
Create `TurnBudget` with:
- `started_at_ms`
- `deadline_ms`
- `max_iterations`
- `origin`
- helpers: `remaining_ms()`, `expired()`, `next_provider_timeout_secs()`

Target files:
- `src/tools/root.zig` (turn context extension)
- `src/session.zig` (budget creation at request entry)
- `src/agent/root.zig` (loop checks)

Exit criteria:
- every turn has one canonical budget object
- budget visible in turn context for tools/providers

### Step 2: Enforce hard wall-clock deadline in agent loop
Before each iteration and before each provider/tool call:
- if `budget.expired()` => return deterministic timeout response
- include machine-readable timeout reason in observer event + diagnostics

Target files:
- `src/agent/root.zig`
- `src/observability.zig`

Exit criteria:
- no turn can run past configured wall-clock deadline
- timeout exit path always returns final reply (no hanging stream)

### Step 3: Propagate remaining timeout to provider calls
Replace static provider timeout usage with budget-derived timeout:
- `timeout_secs = min(configured_timeout_secs, budget.remaining_ms()/1000 with floor)`
- if remaining budget too small => fail fast before call

Target files:
- `src/agent/root.zig`
- provider request wiring (`src/providers/root.zig`, provider impls as needed)

Exit criteria:
- provider calls consume remaining turn budget, never exceed it

### Step 4: Add per-origin budget profiles
Define profiles:
- `user` (interactive): moderate deadline, lower max iterations
- `scheduler`/`heartbeat`/`wake`/`proactive`: stricter deadlines and iteration caps

Target files:
- `src/config_types.zig` (budget profile config)
- `src/config_parse.zig` / `src/config.zig` (load + defaults)
- `src/session.zig` / `src/daemon.zig` (origin-specific budget selection)

Exit criteria:
- origin determines budget deterministically
- defaults are safe and conservative

### Step 5: Add progress heartbeat for long waits
When no progress event was emitted for N seconds during active turn:
- emit lightweight `progress` heartbeat event (`phase=thinking,state=update,label=Still working`)
- do not leak tool args/results

Target files:
- `src/gateway.zig` (SSE progress observer)

Exit criteria:
- user sees liveness during long model/tool waits
- SSE contract remains additive and backward-compatible

### Step 6: Add queue-wait telemetry and user hinting
Capture:
- session lock wait duration
- turn runtime duration
- timeout reason (`provider_wait`, `tool_wait`, `budget_exhausted`)

Expose via:
- `/internal/diagnostics`
- optional `runtime_info.ops`

Target files:
- `src/session.zig`
- `src/diagnostics/runtime_truth.zig`
- `src/tools/runtime_info.zig`

Exit criteria:
- operator can distinguish queueing vs compute vs timeout

### Step 7: Tune defaults and keep compatibility
Proposed default direction (final values to validate):
- reduce foreground `max_tool_iterations`
- reduce per-provider timeout ceiling
- keep retries bounded for foreground, slightly stricter in background

Target files:
- `src/config_types.zig`
- docs/runbook updates

Exit criteria:
- no API break
- no policy regressions

### Step 8: Regression gates and rollout
Required checks:
- `zig build test --summary all`
- `zig build -Dengines=base,sqlite,postgres`
- e2e stream tests verify `done` always arrives (success or timeout)
- soak test with mixed foreground + scheduler load

Rollout order:
1. TurnBudget contract
2. Agent deadline enforcement
3. Provider timeout propagation
4. Origin profiles
5. Progress heartbeat
6. Telemetry + default tuning

## Acceptance Criteria
- No multi-minute silent foreground turns without progress.
- Foreground requests either complete or return bounded-time timeout response.
- Background turns remain conservative and policy-safe.
- Benchmark runs complete with explicit elapsed time, not stalled sessions.

## Notes for Discussion
- Budget values should be environment-specific (dev/staging/prod profiles).
- Keep benchmark timeout policy independent from runtime budgets; benchmark should observe runtime behavior, not mask it.
