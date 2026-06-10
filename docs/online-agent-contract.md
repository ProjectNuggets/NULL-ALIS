---
tags: [prose, prose/docs]
---

# Agent Runtime Event Contract

> Transport-agnostic event grammar for the nullalis agent runtime.
> Applies to: SSE (gateway), daemon loops, desktop app, embedded runtimes.
> Contract baseline: 2026-04-09 (Phase 00-02). Revised 2026-05-28
> for production-readiness gates.

## Scope

This contract defines the **event vocabulary** emitted by the agent runtime
during a turn, regardless of transport. The SSE gateway
(`/api/v1/chat/stream`) is one transport binding. Desktop apps, VS
extensions, CLI, and embedded deployments bind these same events to their
own transport.

Transport-specific details (HTTP status codes, SSE framing) are in Section 6.

Production-readiness rule: this document must describe both the current
wire truth and the launch gates. A capability listed as deferred is not
automatically acceptable for commercial V1; anything that affects
session lifecycle, approvals, memory, browser control, artifacts,
privacy, or user-visible history must either be implemented and tested
or hidden from the product surface.

Canonical runtime sources:
- Structured run events: [src/agent/run_event_types.zig](../src/agent/run_event_types.zig)
- Observer → SSE bridge: [src/gateway_run_events.zig](../src/gateway_run_events.zig)
- Observer event union: [src/observability.zig](../src/observability.zig)
- Approval gating + preflight: [src/agent/root.zig](../src/agent/root.zig)
- Slash-command handler for `/approve`: [src/agent/commands.zig](../src/agent/commands.zig)

## 1. Current Events

Events emitted by the agent runtime during a turn. All listed events are
implemented in the current runtime. The `type` field in the JSON payload
mirrors the SSE `event:` line (except for `token`, which omits `type`).

### 1.1 Core turn events

| Event Name | Type Field | When Emitted | Terminal |
|---|---|---|---|
| `status` | `statusResponse` | Start of processing; status updates | No |
| `progress` | `progress` | Phase transitions, tool dispatch, keepalives | No |
| `reasoning_summary` | `reasoning_summary` | After reasoning/thinking phase (when reasoning mode is on) | No |
| `tool_start` | `tool_start` | A tool invocation is about to run | No |
| `tool_result` | `tool_result` | A tool invocation has finished (success or failure) | No |
| `approval_required` | `approval_required` | A supervised mutating tool needs user approval before running | No |
| `task_update` | `task_update` | A subagent task changes state | No |
| `reply_start` | `reply_start` | Signals the start of the final reply token stream | No |
| `token` | *(none)* | Each chunk of the final reply text | No |
| `error` | `error` | Any error condition (always followed by `done`) | No |
| `done` | `done` | Turn complete | **Yes** |

**Note**: `token` events do **not** carry a `type` field. Dispatch tokens on
the SSE `event:` line.

### 1.2 Conditional events (transport/context-dependent)

| Event Name | Type Field | When Emitted | Transport |
|---|---|---|---|
| `ready` | `ready` | After tenant ownership lock acquisition | SSE gateway (tenant mode only) |
| `subagent_completion` | `subagent_completion` | Pending subagent results flushed to a reconnecting client or arriving asynchronously | SSE gateway (reconnect path) |

`ready` and `subagent_completion` are **not** part of the standard per-turn
event sequence.

### 1.3 Payload fields

Field names below match the wire schema produced by
`run_event_types.toSseFrame`. Optional fields are omitted when null.

#### `ready`
- `session_key` (string) — tenant session key after ownership lock.

#### `reply_start`
- `stream_kind` (string) — e.g. `final_reply`.
- `delivery_mode` (string) — `live` or `buffered_replay`.
- `live` (bool) — true if tokens are streamed in real time.

#### `progress`
- `phase` (string) — high-level phase name (e.g. `thinking`, `dispatch_tools`, `compose`, `finalize`).
- `state` (string) — `start`, `update`, `done`, or `error`.
- `label` (string) — short human-readable label.
- `tool` (string, optional) — tool name when the progress frame is tool-scoped.
- `iteration` (uint, optional) — tool-iteration counter.
- `duration_ms` (uint, optional) — elapsed ms for the covered span.
- `tool_use_id` (string, optional) — correlates with the `tool_start`/`tool_result` pair for the same call.
- `task_id` (string, optional) — subagent task identifier.
- `group_id` (string, optional) — narration group identifier.
- `heartbeat` (bool, optional) — true for keepalive frames (omitted when false).
- `command` (string, optional) — safe summary of the shell command (mutating exec only).
- `files` (array of string, optional) — safe list of file targets.
- `run_id` (string, optional) — turn-level correlation id (see Section 1.4).

#### `reasoning_summary`
- `summary` (string) — short narration string.
- `phase` (string, optional) — phase label (`thinking`, `tool`, etc.).
- `tool` (string, optional) — tool name when the summary is tool-scoped.
- `iteration` (uint, optional).
- `run_id` (string, optional).

#### `tool_start`
- `tool` (string) — tool name (metadata-registry identifier).
- `tool_use_id` (string, optional) — tool-level correlation id; matches the
  corresponding `tool_result` for the same call.
- `input_preview` (string, optional) — short, redacted preview of structured input.
- `command` (string, optional) — safe summary of the shell command (mutating exec only).
- `files` (array of string, optional) — safe file targets for the tool.
- `activity_label` (string, optional) — client-facing phrase like “Running command”.
- `run_id` (string, optional).

#### `tool_result`
- `tool` (string) — tool name.
- `success` (bool) — true on successful completion.
- `duration_ms` (uint) — execution time in ms.
- `tool_use_id` (string, optional) — matches the preceding `tool_start`.
- `output_preview` (string, optional) — truncated preview of tool output.
  Server truncates to a 256-byte cap; when applied, `output_truncated` is set.
- `output_truncated` (bool, optional) — true when `output_preview` was cut.
- `result_summary` (string, optional) — short human-readable outcome.
- `command` (string, optional) — safe summary of the shell command.
- `files` (array of string, optional).
- `exit_code` (int, optional) — process exit code for exec-style tools.
- `run_id` (string, optional).

#### `approval_required`
- `tool` (string) — the tool that is pending approval.
- `reason` (string) — short machine code. The runtime emits
  `supervised_mutating_requires_approval` for the first-time gate.
- `risk_level` (string) — tool risk tier (`low`, `medium`, `high`, `critical`).
- `approval_id` (string, optional) — canonical stable pending-approval id
  (`apr-<u64>`). Clients pin approval cards to this id when present.
- `id` (uint, optional) — legacy numeric id, included for debug/display
  and slash-command compatibility. Do not use as the primary UI key.
- `tool_call_id` (string, optional) — provider tool-call correlation id.
- `created_at` (int, optional) — Unix epoch seconds for the pending slot.
- `expires_at` (int or null, optional) — null in V1 unless a future TTL is active.
- `run_id` (string, optional).

#### `task_update`
- `task_id` (string).
- `status` (string) — e.g. `queued`, `running`, `completed`, `failed`.
- `description` (string, optional).
- `progress_pct` (uint, optional) — 0–100.
- `run_id` (string, optional).

#### `done`
- `session_id` (string, optional).
- `message_id` (int, optional).
- `usage_tokens` (uint, optional) — tokens consumed in the turn
  (input + output).
- `input_tokens` (uint, optional) — input tokens consumed in the turn.
- `output_tokens` (uint, optional) — output tokens consumed in the turn.
- `cost_usd` (number, optional) — provider-reported cost for the turn.
  Only present when the runtime has real cost data (`cost_available`
  semantics — see the usage endpoint); absence means "cost unknown",
  never "free".
- `run_id` (string, optional).

Since WO-03 (2026-06-10) the runtime emits `usage_tokens`,
`input_tokens`, `output_tokens`, and `cost_usd` as **per-turn deltas**
computed from before/after UsageRuntime snapshots (the same mechanism
as `turn_weight`/`session_weight`). They are omitted on paths without a
usage runtime (file-tenant / CLI fallback).

### 1.4 Correlation IDs: `run_id` vs `tool_use_id`

- `run_id` is **turn-level**: a single value identifies all events produced
  by one agent run / turn. It is optional on the wire. Clients that want to
  group events by turn (e.g. for multi-turn streaming UIs) should use
  `run_id` when present.
- `tool_use_id` is **tool-level**: it identifies a single tool invocation.
  A `tool_start` and its matching `tool_result` carry the same
  `tool_use_id`. Progress frames scoped to that call may also carry it.

Both ids are opaque strings. Clients must treat unknown or missing ids as
absence of correlation, not as an error.

### 1.5 Event ordering invariants

1. Every turn **must** end with exactly one `done` event.
2. `reply_start` always precedes any `token` events for a given reply.
3. `error` events are always followed by a `done` event (error is not
   terminal on its own).
4. `status` is typically the first event emitted in a turn.
5. `progress` events can appear at any point during processing (including
   as keepalives).
6. `reasoning_summary` appears after thinking/tool phases, before the final
   reply.
7. A `tool_start` for a given `tool_use_id` precedes its `tool_result`.
8. When an `approval_required` is emitted, the underlying tool does **not**
   run until the operator resolves it via `/approve` (see Section 2).
9. `approval_required` is a waiting checkpoint, not an executed tool
   failure. New runtimes do not emit a failed `tool_result` for that
   checkpoint; clients should render the approval event as blocked/pending.

## 2. Approval Behavior

Supervised mutating tools gate their execution through a generic,
single-slot approval queue except for the narrow local editable artifact
exception: `artifact_create` and `artifact_update` are auto-approved in
supervised mode because they only write authenticated, editable canvas
state. Public sharing (`artifact_share`), rendered file generation
(`produce_document`), shell, filesystem writes, browser/session tools,
integrations, unknown/MCP tools, and other mutating tools remain approval
gated by their metadata. The runtime exposes ONE canonical model; the REST
surface (`POST /api/v1/users/{user_id}/sessions/{session_key}/approve`)
and the operator slash command (`/approve allow-once | deny`) both resolve
the same slot.

### Runtime semantics (as implemented)

- **Emission.** When a tool preflight produces the verdict
  `approval_required`, the runtime emits an `approval_required` event with
  `reason = "supervised_mutating_requires_approval"` and the tool's
  `risk_level`. New frames also carry the canonical `approval_id`, numeric
  `id`, `tool_call_id`, `created_at`, and `expires_at` fields that match
  session detail. The underlying tool call does not execute and is held as
  a pending approval owned by the session. This event is not paired with a
  failed `tool_result`; provider transcript hygiene still receives an
  internal blocked result, but stream clients should treat the visible state
  as waiting for approval.
- **Artifact local-edit exception.** In supervised mode,
  `artifact_create` and `artifact_update` resolve to `auto_approve` and
  execute immediately. They should increment
  `approval_decision_total{result="auto_approved"}` through the same
  approval policy path. `artifact_share` remains approval-gated because it
  mints a public URL.
- **Resolution via REST.** The FE calls
  `POST /api/v1/users/{user_id}/sessions/{session_key}/approve` with body
  `{"approved": bool, "approval_id": "apr-<u64>"}`. `approved: true`
  routes to `/approve allow-once`; `approved: false` to `/approve deny`.
- **Resolution via slash command.** Same code path with operator-typed
  `/approve allow-once` or `/approve deny`.
- **`allow-always` is not persistent in v1.** `/approve allow-always` is
  accepted as a synonym for `allow-once`: the pending tool runs exactly
  once, and a follow-up note indicates that a persistent generic allowlist
  is not implemented. There is no durable per-tool auto-approve store.
  See `docs/deferred-register.md` D2 for the planned run-scoped allowlist.
- **One pending approval at a time.** If another tool call reaches the
  approval gate while one approval is already pending, preflight blocks the
  new call with reason `approval_already_pending` and does **not** emit a
  second `approval_required` event. The operator must resolve the existing
  one first. The collision is rejected at the agent layer
  (`error.PendingToolApprovalAlreadyExists`) — the slot is never silently
  overwritten.
- **Denial.** `/approve deny` clears the pending approval without running
  the tool. The agent loop sees a blocked preflight and composes a refusal
  reply.
- **Scope.** The queue is per agent/session — there is no cross-session
  approval broadcast and no durable persisted approval history in v1.

### Sprint 2 (2026-05-28) — stable approval id + stale-card guard

Each pending approval carries an **`approval_id`** of the form
`apr-<u64>` (the u64 is the legacy per-agent counter, kept embedded for
slash-command compatibility — new clients pin to the string form).

The pending-approval card on the session detail surfaces:

```json
{
  "approval_id": "apr-7",
  "id": 7,
  "tool": "shell",
  "tool_call_id": "call_abc-123",
  "reason": "supervised_mutating_requires_approval",
  "risk_level": "medium",
  "created_at": 1779988800,
  "expires_at": null
}
```

`tool_call_id` is the provider's correlation id for the tool call that
triggered the approval. The FE binds it to the matching `tool_use` SSE
event so the approval card visually attaches to the tool invocation
that's waiting. Null when the provider did not supply one.

`created_at` is Unix epoch seconds — UI uses it for the "waiting Ns"
countdown. `expires_at` is null in V1; the schema slot is committed
ahead of the V1.x TTL sweep so the UI can render a countdown without
another schema bump.

**Stale-card guard.** When the FE supplies `approval_id` in the
request body, the gateway verifies it against the agent's CURRENT
pending. If the card the user is approving has been replaced by a new
one (or already cleared), the request yields **`409 Conflict`** with
`{"error": "approval_id_mismatch", "hint": ...}` — refresh the session
detail before retrying. When `approval_id` is omitted (pre-Sprint-2
clients), the gateway addresses whatever is currently pending without
verification.

### Client guidance

- Pin to `approval_id` when rendering the card; echo it back on resolve
  to defend against the collision case.
- Treat `409 approval_id_mismatch` as "refresh + re-render"; do NOT
  silently retry without a UI prompt.
- Treat `reason = approval_already_pending` (surfaced in tool error
  output) as a collision signal; the operator must resolve the earlier
  pending before the new tool call can proceed.
- Do NOT assume the legacy numeric `id` is stable beyond an Agent
  lifetime — pin to `approval_id`, which is durable for the lifetime of
  the pending approval.

### Legacy `/exec` flow (Gate 3) — operator-only, NOT surfaced here

A separate pre-registry approval gate exists for the operator-typed
`/exec <cmd>` slash command (commands.zig: `pending_exec_command` +
`pending_exec_id`). This gate is documented at `/policy` Gate 3 and is
explicitly NOT routed through `ApprovalPolicy.forTool`. The HTTP
`POST .../approve` route does NOT address Gate 3 — it's only reachable
from chat slash commands typed by operators. End-user UIs should not
expose this path; it stays as a chat-only operator surface.

## 2a. Operator Slash-Command Surface

Direct operator controls are exposed as **chat slash commands** in the
current runtime. Production UI controls should use the REST parity that
exists today:

- `POST /api/v1/users/{user_id}/sessions/{session_key}/approve`
- `POST /api/v1/users/{user_id}/sessions/{session_key}/mode`
- `POST /api/v1/users/{user_id}/sessions/{session_key}/cancel` *(2026-05-28)*

`approve` and `mode` go through the slash-command implementation, so
[src/agent/commands.zig](../src/agent/commands.zig) remains the single
behavioral truth. `cancel` writes directly to the session agent's
atomic `CancellationToken` (see
[src/agent/abort.zig](../src/agent/abort.zig) and the cooperative
cancellation check in [src/agent/root.zig](../src/agent/root.zig)) so
it does not block on the in-flight turn's session mutex.

Active-turn cancel — semantics:

- The agent loop polls `cancellation_token.isCancelled()` between
  iterations. On cancel it emits an internal `turn_cancelled`
  ObserverEvent that the SSE bridge translates to
  `event: system_notice` with `kind: "turn_cancelled"`, severity
  `info`, and `detail: "user_request"`. The canonical `turn_complete`
  event still fires, so the stream still reaches the terminal `done`
  frame and clients see a clean SSE termination.
- **Cancel takes effect at iteration boundaries, not mid-tool.** If a
  cancel arrives while the agent is mid-tool (a 30s shell command, an
  LLM stream waiting on the provider, or a tool that itself blocks),
  the flag is set immediately but the in-flight tool runs to its
  natural completion before the loop re-checks. The user-facing
  Stop chip may feel laggy when a long-running tool is in flight;
  surface "Stopping…" while the cancel is pending rather than claiming
  the turn already terminated.
- The agent's return text is `[Cancelled]` (or
  `[Cancelled: last tool was <name>]` when a tool was mid-flight),
  delivered through the normal `token` chunks before `done`.
- Idempotent: repeated cancels land the same atomic store. Cancel
  against an idle session is safe — the agent resets the token at the
  start of every turn, so a stale cancel cannot silently cancel a
  future user message. The response payload includes
  `was_active: true|false` so the FE can communicate the difference.

Active-turn resume / replay:

- Backend-owned resume is **not implemented** and is intentionally not
  planned for V1. There is no `POST /api/v1/chat/resume`.
- Reconnect/replay is handled by reconnecting to
  `POST /api/v1/chat/stream` for new turns and reading the bounded
  in-process trace store via
  `GET /api/v1/users/{user_id}/traces/{run_id}` for historical events
  (see §7 for the storage and field-subset contract).

Execution posture:

- `/mode` (no arg) — reports the current execution mode.
- `/mode plan|review|execute|background` — switches execution mode.
- `/plan`, `/review`, `/execute` — direct aliases. In `plan` and `review`
  modes, mutating tools are blocked and only read-only tools may run.
  `execute` applies the current security policy (allowlists, approval
  gate, workspace scope). Switching posture does not mutate stored
  config; it applies to the active session only.

Permission and approval inspection:

- `/permissions` (alias `/perm`) — **read-only** snapshot of the
  session's permission, approval, and execution posture. Emits current
  execution mode, security policy, pairing state, and any pending
  approval. Does not mutate config, pending approvals, or any runtime
  state.
- `/approve allow-once|deny` — resolves the single pending tool
  approval. `allow-always` is accepted as a synonym for `allow-once`;
  see Section 2 for why a persistent generic allowlist is not
  implemented.

Usage and cost:

- `/usage [off|tokens|full|cost]` — toggles per-turn usage reporting.
- `/cost` — **read-only** token/cost snapshot. Reports `last_turn_usage`
  and session `total_tokens`; surfaces session cost when provider
  pricing is wired, otherwise explicitly reports
  `Cost estimate unavailable`. Does not mutate usage mode or counters.

Context pressure:

- `GET /api/v1/users/{user_id}/sessions/{session_key}/context` is the
  canonical live context meter. It reports backend-calculated
  `pressure_percent` / `context_pressure_percent` from the active
  provider-bound context window, not from cumulative lifetime usage.
- Compatibility aliases (`tokens_used`, `token_count`, `token_limit`,
  `context_window_used_pct`) refer to the live context estimate/window
  and must not be treated as cost or lifetime metering.
- The report includes estimator metadata, usable input budget, reserve,
  provider usage from the last turn, cache telemetry, last-turn delta,
  and top contributors. Cache telemetry is diagnostic only; cached
  prompt tokens still occupy provider-visible context and are not
  subtracted from pressure.
- The report may include `prompt_shape`, a sanitized diagnostic object for the
  last provider-bound request. It contains bucket sizes, counts, and hashes
  only, including system prompt buckets, tool schema size, history-by-role
  bytes, assistant reasoning bytes, XML/tool history bytes, multimodal payload
  estimates, cache-key presence, provider usage/preflight truth beside the
  shape, the selected provider-bound tool surface, and optional `prompt_blocks`
  entries with sanitized names, buckets, byte counts, token estimates, and
  hashes. Tool-surface diagnostics report whether native schemas, the full XML
  catalog, the compact XML fallback protocol, or the prose catalog were present,
  plus the largest native tool schemas by sanitized name, bytes, and hash. It
  must not include raw prompt, user, tool, or reasoning text and must not be used
  as a second pressure meter.
- If there is no live session manager or no active session, the response
  is an unavailable envelope such as
  `{"active":false,"live":false,"code":"session_manager_unavailable"}`
  or `{"active":false,"live":false,"code":"no_active_session"}` and
  contains no pressure value.

Bounded tool output:

- The runtime keeps the hybrid Kimi/tool path for V1: providers may
  return native tool calls, Nullalis may parse XML fallback calls, and
  history remains XML-based. Per-turn diagnostics classify this as
  `native_tool_calls`, `xml_fallback`, `mixed`, or `no_tools`.
- Provider-capable turns use a provider-native tool schema surface plus a
  compact XML fallback protocol. They must not duplicate the full prose catalog,
  full XML catalog, and native schema payload in the same request. Providers
  without reliable native tools use the full XML catalog path.
- Kimi/Moonshot stays on `native_with_xml_fallback` for V1. Promotion to
  `native_minimal` requires live success data showing reliable native tool-call
  compliance for schedule/cron, memory, approval-gated, and multi-tool turns.
- `schedule action=list` and `cron_list` are bounded by default
  (`limit=25`, max `limit=100`, `offset` supported). They return
  `total_count`, `shown_count`, `limit`, `offset`, `next_offset`, and
  `partial:true` when more rows exist. Full schedule data remains
  available through paginated list calls or exact job detail lookup; the
  model must not infer it saw rows that were omitted.

Current limitations to close or explicitly hide before production:

- **Active-turn resume.** The runtime exposes idempotent cancel (above)
  but NOT resume. Clients reconnect to `POST /api/v1/chat/stream` for
  new turns and to `GET /api/v1/users/{user_id}/traces/{run_id}` for
  in-process trace history. Permanent-history UX must wait for
  durable trace storage (Section 7 caveats).
- **Durable trace SHARES.** Sprint 3 (2026-05-28, prod-readiness)
  landed PG-backed persistence for share RECORDS: the share URL +
  sanitized snapshot of the events at share-create time survive
  gateway restart. The snapshot is moment-in-time (frozen at the
  click — future sanitizer rule changes do not retroactively apply).
  Schema lives at `migrations/0003_trace_shares.sql`; the runtime
  wiring is in `TraceShareStore.initWithPersistence`.
- **Durable trace EVENTS storage.** The WP4.1 trace store is in-process only;
  events are not persisted across restarts (Section 7).
- **Persistent generic allowlist.** `/approve allow-always` does not
  create durable state; there is no per-tool auto-approve ledger.
- **Multi-slot approval queue.** At most one approval may be pending
  per session (Section 2).
- **Live subagent interruption.** Running subagent tasks cannot be
  interrupted mid-flight. Only queued tasks can be cancelled via the
  REST `/stop` endpoint or the `task_stop` tool.
- **Planner artifacts.** Persisted plan objects, plan ids, and plan
  inspection APIs are **not** implemented. `/plan` only switches
  execution posture.
- **Budget enforcement.** `cost_usd` is recorded when the model is
  priced (WP5.1), but no hard/soft budget gate exists.
- **`cost_update` SSE event.** Per-turn cost is exposed via `/usage`
  and `/cost`; there is no streaming `cost_update` frame (Section 8).
- **Full REST parity for slash commands.** `/approve` and `/mode` have
  session-scoped REST routes. Other operator commands remain
  slash-command-only unless the product surface requires them.
- **MCP runtime metadata registry.** MCP-provided tools are not yet
  surfaced through the runtime's tool-metadata registry.

## 3. Replay Contract

A client that connects mid-stream or reconnects can reconstruct the run
state:

1. **Buffered replay**: when `delivery_mode` is `buffered_replay`, the
   runtime replays the complete response as token chunks. `live` is
   `false`.
2. **Live streaming**: when `delivery_mode` is `live`, tokens are emitted
   in real time. `live` is `true`.
3. **Event ID ordering**: `seq` on token events provides ordering. Clients
   should buffer and sort by `seq` on replay.
4. **Terminal detection**: the `done` event is the only terminal event.
   Clients must not close the connection until `done` is received.

## 4. Backward Compatibility Rules

1. **Additive only.** New event types may be added. Existing event types
   will not be removed or renamed.
2. **Payload extension.** New optional fields may be added to existing
   event payloads. Existing fields will not be removed or change type.
3. **Ordering preserved.** The ordering invariants above are permanent.
   `done` is always terminal.
4. **Unknown events.** Clients must ignore event types they do not
   recognize (forward compatibility).
5. **Type field.** Most events carry a `type` field in their JSON payload.
   `token` events do not — dispatch on the SSE `event:` line for tokens.
6. **Optional id fields.** `run_id` and `tool_use_id` may be absent on any
   event. Clients must tolerate missing ids without error.

## 5. Error Codes

Current error codes emitted via the `error` event:

| Code | Meaning | Notes |
|---|---|---|
| `rate_limited` | Too many requests in sliding window | Gateway transport |
| `gateway_draining` | Gateway is shutting down | Gateway transport |
| `ownership_lock_conflict` | User active on another node (tenant mode) | Gateway transport |
| `invalid_session_key` | Session key format invalid or wrong user | Gateway transport |
| `tenant_config_missing` | Tenant runtime not available | Gateway transport |
| `execution_delegated` | Broker mode, cannot execute locally | Gateway transport |
| `chat_failed` | Agent execution failed | All transports |
| `broker_proxy_failed` | Broker proxy request failed | Gateway transport |

## 6. SSE Transport Binding

When events are delivered over Server-Sent Events
(`/api/v1/chat/stream`):

```
event: <event_name>\n
data: <json_payload>\n
\n
```

- Token chunk size: **96 bytes** (`SSE_TOKEN_CHUNK_SIZE` in
  `src/gateway.zig`).
- Keepalive: `progress` event with phase `thinking` and `heartbeat: true`
  emitted periodically.
- HTTP status codes: 200 (success), 400 (bad request), 401 (unauthorized),
  409 (ownership conflict), 429 (rate limited), 503 (draining).

## 7. Known Caveats

The runtime is implementation-accurate as of 2026-04-17, with the
following intentional gaps:

- **Transport helper frames may omit `run_id`.** Some helper/finalize
  frames emitted directly by the gateway or by non-run-scoped paths do not
  thread a `run_id` through. Clients must not require `run_id` on every
  frame.
- **`turn_complete` finalize progress may omit `run_id`.** The synthetic
  `progress { phase: "finalize", state: "done" }` frame emitted on
  turn-complete does not currently carry `run_id`. This is a known
  shortcoming — clients should rely on the preceding run-scoped events for
  correlation.
- **In-process trace store only (WP4.1 / WP4.2).** The runtime retains
  recent per-run events in a bounded in-memory store
  (`src/run_trace_store.zig`). Two read-only endpoints expose this:
  `GET /api/v1/users/{user_id}/traces` lists retained run ids, and
  `GET /api/v1/users/{user_id}/traces/{run_id}` returns a sanitized
  event timeline for a single run (same public field subset as the SSE
  run events, no raw tool payloads). Missing tenant runtime returns
  `{"traces": []}` for the collection and `404` for a specific run —
  the endpoint never materializes a runtime on demand. Storage is
  bounded (default 64 runs × 256 events/run with LRU-style eviction);
  **durable trace storage is still deferred** — events are not written
  to disk or a database and do not survive a pod restart.
- **No persistent approval allowlist.** `/approve allow-always` is
  accepted but is not stored durably in v1 (see Section 2).
- **Task query + queued-only stop REST API.** Task state is visible via
  `task_update` events on the SSE stream and via two read-only REST
  endpoints: `GET /api/v1/users/{user_id}/tasks` and
  `GET /api/v1/users/{user_id}/tasks/{task_id}`. Both return snapshots
  of the canonical task ledger. Task **cancellation** is also exposed
  over REST via
  `POST /api/v1/users/{user_id}/tasks/{task_id}/stop` (WP2.5), which
  routes through `SubagentManager.cancelQueued` — the same source of
  truth used by the `task_stop` agent tool and the `/subagents kill`
  slash command. Cancellation is **queued-only**: a queued task can be
  transitioned to `cancelled`, but a task that has already started
  running cannot be interrupted in v0.1. The REST endpoint returns
  `409 Conflict` for running or already-terminal tasks and
  `404 Not Found` when no task or tenant runtime exists. Live
  interruption of a running subagent is **out of scope**. Task
  **creation** remains **not** exposed over REST — new tasks still flow
  exclusively through the agent tool surface (`spawn`) and the operator
  slash commands. If no tenant runtime exists for the user yet (no
  agent work has happened), the list endpoint returns `{"tasks": []}`
  rather than 404, and the stop endpoint returns 404 without
  materializing a runtime on demand.
- **Read-only usage summary API.** Cumulative token usage and per-model
  breakdown are exposed via `GET /api/v1/users/{user_id}/usage`
  (WP2.3). The response matches the `UsageSummary` schema in
  `docs/openapi-v1.yaml` and is a snapshot of the per-user
  `UsageRuntime`. If no tenant runtime exists yet the endpoint returns
  a zero summary with `turn_count: 0`, `models: []`, and
  `cost_available: false` rather than 404. The endpoint never
  instantiates a tenant runtime on demand. The interactive `/usage` and
  `/cost` slash commands (see §2a) remain available and report against
  the same underlying state.
  **Provider pricing (WP5.1).** The runtime now consults a small,
  in-process static pricing table (`src/providers/pricing.zig`) when
  recording per-turn usage. When the turn's model is priced, the
  recorded `cost_usd` is real and `cost_available` flips to `true`
  once any non-zero cost accumulates; when the model is unknown, cost
  is left at `0.0` and `cost_available` stays `false` — the runtime
  does not fabricate a $0.00 price for unknown models. Persistent
  usage ledgers, budget enforcement, and the `cost_update` SSE event
  (see §8) are still deferred beyond v0.1.

## 8. Future / Deferred Event Candidates

Events previously scoped to future sprints. These are **not** implemented
and **not** on the wire today:

| Event Name | Purpose | Status |
|---|---|---|
| `context_snapshot` | Context window state after processing | deferred |
| `cost_update` | Per-turn token usage and cost | deferred |

Clients must not rely on either of these.

## 9. Source References

- Structured run-event types: [src/agent/run_event_types.zig](../src/agent/run_event_types.zig)
- Observer → SSE bridge: [src/gateway_run_events.zig](../src/gateway_run_events.zig)
- Observer event union: [src/observability.zig](../src/observability.zig)
- Approval preflight & pending queue: [src/agent/root.zig](../src/agent/root.zig)
- `/approve` slash-command handler: [src/agent/commands.zig](../src/agent/commands.zig)
- SSE chat stream handler: [src/gateway.zig](../src/gateway.zig) `/api/v1/chat/stream`
- Idempotency store: [src/gateway.zig](../src/gateway.zig) (`IdempotencyStore`)
