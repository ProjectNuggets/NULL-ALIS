# Agent Runtime Event Contract

> Transport-agnostic event grammar for the nullalis agent runtime.
> Applies to: SSE (gateway), daemon loops, desktop app, embedded runtimes.
> Contract baseline: 2026-04-09 (Phase 00-02). Revised 2026-04-09.

## Scope

This contract defines the **event vocabulary** emitted by the agent runtime
during a turn, regardless of transport. The SSE gateway (`src/gateway.zig`)
is one transport binding. Desktop apps, VS extensions, CLI, and embedded
deployments bind these same events to their own transport.

Transport-specific details (HTTP status codes, SSE framing) are in Section 6.

## 1. Current Events

Events emitted by the agent runtime during a turn:

### Core turn events (all transports)

| Event Name | Type Field | Payload Fields | When Emitted | Terminal |
|---|---|---|---|---|
| `status` | `statusResponse` | `content` | Start of processing; status updates | No |
| `progress` | `progress` | `phase`, `state`, `label`, `tool?`, `iteration?`, `duration_ms?` | Tool execution, thinking phase, keepalive | No |
| `reasoning_summary` | `reasoning_summary` | `summary`, `phase?`, `tool?`, `iteration?` | After reasoning/thinking phase when reasoning mode is on | No |
| `reply_start` | `reply_start` | `stream_kind`, `delivery_mode`, `live` | Signals start of final reply token stream | No |
| `token` | *(none)* | `delta`, `content`, `seq`, `stream_kind`, `live` | Each chunk of the final reply text | No |
| `error` | `error` | `code`, `message`, `retry_after_ms?`, `owner_instance_id?`, `lease_until_s?` | Any error condition | No (always followed by `done`) |
| `done` | `done` | `session_id?`, `message_id?` | Turn complete | **Yes** |

**Note**: `token` events do **not** carry a `type` field. All other events do.

### Conditional events (transport/context-dependent)

| Event Name | Type Field | Payload Fields | When Emitted | Transport |
|---|---|---|---|---|
| `ready` | `ready` | `session_key` | Tenant session initialized after ownership lock | SSE gateway (tenant mode only) |
| `subagent_completion` | `subagent_completion` | `event_id`, `session_key`, `content` | Pending subagent results flushed to reconnecting client | SSE gateway (reconnect path) |

**Note**: `ready` and `subagent_completion` are **not** part of the standard
per-turn event sequence. They appear in specific gateway paths: `ready` after
tenant ownership lock acquisition, `subagent_completion` when pending results
exist at stream connect time or arrive asynchronously during a stream.

### Event Ordering Invariants

1. Every turn **must** end with exactly one `done` event.
2. `reply_start` always precedes any `token` events for a given reply.
3. `error` events are always followed by a `done` event (error is not terminal by itself).
4. `status` is typically the first event emitted in a turn.
5. `progress` events can appear at any point during processing (including as keepalives).
6. `reasoning_summary` appears after thinking/tool phases, before the final reply.

## 2. Target Events (Planned)

Events to be added by the SOTA program (Phases 1-6):

| Event Name | Type Field | Payload Schema | When Emitted | Terminal | Sprint |
|---|---|---|---|---|---|
| `tool_start` | `tool_start` | `tool_name`, `tool_id`, `input_preview?`, `iteration` | Tool execution begins | No | 2A |
| `tool_result` | `tool_result` | `tool_id`, `status: "success"\|"error"`, `output_preview?`, `duration_ms` | Tool execution completes | No | 2A |
| `approval_required` | `approval_required` | `tool_name`, `tool_id`, `input`, `risk_level`, `timeout_secs` | Tool requires operator approval before execution | No | 3A |
| `approval_response` | `approval_response` | `tool_id`, `approved: bool`, `responder?` | Operator approves/denies tool | No | 3A |
| `task_update` | `task_update` | `task_id`, `status`, `label`, `progress_pct?`, `result_preview?` | Subagent task state changes | No | 2B |
| `context_snapshot` | `context_snapshot` | `tokens_used`, `tokens_max`, `history_len`, `compacted` | Context window state after processing | No | 4A |
| `cost_update` | `cost_update` | `input_tokens`, `output_tokens`, `cost_usd`, `cumulative_cost_usd` | Token usage for the turn | No | 4B |

## 3. Replay Contract

A client that connects mid-stream or reconnects can reconstruct the run state:

1. **Buffered replay**: When `delivery_mode` is `"buffered_replay"`, the runtime replays the complete response as token chunks. `live` is `false`.
2. **Live streaming**: When `delivery_mode` is `"live"`, tokens are emitted in real-time. `live` is `true`.
3. **Event ID ordering**: `seq` on token events provides ordering. Clients should buffer and sort by `seq` on replay.
4. **Terminal detection**: The `done` event is the only terminal event. Clients must not close the connection until `done` is received.

## 4. Backward Compatibility Rules

1. **Additive only**: New event types may be added. Existing event types will not be removed or renamed.
2. **Payload extension**: New optional fields may be added to existing event payloads. Existing fields will not be removed or change type.
3. **Ordering preserved**: The ordering invariants above are permanent. `done` is always terminal.
4. **Unknown events**: Clients must ignore event types they do not recognize (forward compatibility).
5. **Type field**: Most events carry a `type` field in their JSON payload. `token` events do not — dispatch on the SSE `event:` line for tokens.

## 5. Error Codes

Current error codes emitted via the error event:

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

When events are delivered over Server-Sent Events (`/api/v1/chat/stream`):

```
event: <event_name>\n
data: <json_payload>\n
\n
```

- Token chunk size: **96 bytes** (`SSE_TOKEN_CHUNK_SIZE` in `src/gateway.zig`)
- Keepalive: `progress` event with phase `"thinking"` emitted periodically
- HTTP status codes: 200 (success), 400 (bad request), 401 (unauthorized), 409 (ownership conflict), 429 (rate limited), 503 (draining)

## 7. Source References

- SSE frame functions: `src/gateway.zig` lines 7187-7844
- Chat stream handler: `src/gateway.zig` `/api/v1/chat/stream` endpoint
- Rate limiter: `src/gateway.zig` `SlidingWindowRateLimiter` (line 128)
- Subagent completion routing: `src/subagent.zig` `SubagentManager.completeTask`
- Idempotency store: `src/gateway.zig` `IdempotencyStore` (line 258)
- Characterization tests: `src/gateway.zig` baseline tests at end of file
