# v0.1 Final Sweep — 2026-03-09

## Scope

Final pass on `v0.1` for runtime stability, stress behavior, subagent execution, turn-origin wiring, and SOTA DTaaS open ends.

Reference product direction: `/Users/nova/Downloads/plan.md`.

## What was validated

1. Full test suite:
   - `zig build test --summary all`
   - Result: `4430/4434` passed, `4` skipped
2. Build path:
   - `zig build -Dengines=base,sqlite,postgres`
   - Result: success
3. Integration preflight:
   - `./scripts/preflight-integrations.sh`
   - Result:
     - Gate 1 PASS (`state_effective=postgres`, `scheduler_backend=postgres`, `degraded=false`)
     - Gate 2 PASS (Composio toolkits for `gmail`, `googledrive`, `googlecalendar` available)
     - Gate 3 PASS (entity-scoped connected-account readiness probe runs)
4. Stress probes:
   - CLI runtime command fanout: `80` requests, parallel `8`
   - Provider chat fanout: `12` requests, parallel `4`
   - Gateway ops endpoints soak: `/health`, `/ready`, `/metrics` (`300` total requests)
   - Authenticated chat stream soak (`/api/v1/chat/stream`) with prompt forcing `runtime_info` tool use:
     - `8` requests, all completed with SSE `done`
     - no `Bus error`, `segmentation fault`, or panic observed

## Implemented in this sweep

### 1) Subagent delivery routing fix

Problem:
- `/subagents spawn ...` in command path forced origin channel to `"agent"`.
- In channel deployments (Telegram/Slack/etc.), that can prevent completion messages from returning to the originating channel.

Fix:
- `spawnSubagentTask` now inherits current turn channel/chat when available via message turn context.
- Fallback remains deterministic (`agent` channel + current session key).

File:
- `src/agent/commands.zig`

Regression tests added:
- `spawnSubagentTask routes to current turn channel and chat`
- `spawnSubagentTask falls back to agent channel and current session key`

## Current state summary

### Stable now

- Runtime starts healthy with Postgres effective backend.
- Scheduler path and heartbeat path run without reproducing prior TLS/native abort in this sweep.
- `runtime_info` tool works in chat stream path under repeated calls.
- Background tool policy is active (background turns blocked from shell/spawn/delegate/composio connect).
- Composio readiness visibility is exposed in runtime surfaces (`runtime_info` + `/runtime`).

### Open ends / not fully closed

1. Startup log noise:
   - repeated Postgres `NOTICE ... already exists` remains high.
   - Not breaking correctness, but hurts operator UX and startup readability.
2. Turn origins reserved but unwired:
   - `wake`
   - `proactive`
   - Defined in runtime origin enum but not assigned by active execution paths.
3. Subagent product limitations (by design in v0.1):
   - tasks are non-interruptible while running
   - no interactive tool loop inside subagent thread; completion-only worker path
   - `/steer` creates a new task, it does not modify a running task
4. Multi-node ownership lock behavior:
   - same-user concurrent chat-stream requests can return `409 ownership_lock_conflict`.
   - Correct safety behavior, but needs explicit operator UX handling/retry messaging in clients.

## Origin wiring status

Defined in `TurnOrigin`:
- `user`, `heartbeat`, `scheduler`, `wake`, `proactive`

Wired in runtime:
- `user`: normal message turns
- `heartbeat`: heartbeat job turns
- `scheduler`: non-heartbeat scheduled jobs

Defined but not wired:
- `wake`
- `proactive`

Reference:
- `docs/v0.2-origin-roadmap.md`

## SOTA DTaaS gap assessment (pragmatic)

Already in place:
- durable runtime and tenant model
- composable tool architecture (vtables)
- Composio path for Gmail/Drive/Calendar
- MCP server ingestion for external tool APIs

Still required for DTaaS-grade evolution:
1. Agent-to-agent (A2A) trust graph:
   - explicit consent, scoped grants, signed envelopes, revocation, audit
2. Snapshot-based memory inheritance productization:
   - export/import UX + provenance controls
3. Strong proactive orchestration by origin:
   - wire `wake` and `proactive` with distinct policy and observability
4. Operator/client UX for conflicts and async flows:
   - ownership-lock UX, subagent lifecycle visibility, and deterministic retries

## API readiness answer

The runtime is API-extensible, but not “arbitrary API with zero structure.”

What is ready:
- built-in tools
- Composio actions
- MCP server tools (stdio JSON-RPC)

What is not ready as a default:
- unconstrained arbitrary external API execution without a tool adapter/MCP server and policy constraints.

