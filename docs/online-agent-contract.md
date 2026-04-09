# Online Agent Control Contract

> Target SSE event grammar for the nullalis agent runtime.
> Contract baseline: 2026-04-09 (Phase 00-02).

## 1. Current SSE Events (Stable)

Events emitted today by `src/gateway.zig` over `/api/v1/chat/stream`:

| Event Name | Type Field | Payload Fields | When Emitted | Terminal |
|---|---|---|---|---|
| `status` | `statusResponse` | `content` | Start of processing; status updates | No |
| `progress` | `progress` | `phase`, `state`, `label`, `tool?`, `iteration?`, `duration_ms?` | Tool execution, thinking phase, keepalive | No |
| `reasoning_summary` | `reasoning_summary` | `summary`, `phase?`, `tool?`, `iteration?` | After reasoning/thinking phase when reasoning mode is on | No |
| `reply_start` | `reply_start` | `stream_kind`, `delivery_mode`, `live` | Signals start of final reply token stream | No |
| `ready` | `ready` | `session_key` | Session initialized, ready to stream | No |
| `token` | *(implicit)* | `delta`, `content`, `seq`, `stream_kind`, `live` | Each chunk of the final reply text | No |
| `error` | `error` | `code`, `message`, `retry_after_ms?`, `owner_instance_id?`, `lease_until_s?` | Any error condition | No (always followed by `done`) |
| `subagent_completion` | `subagent_completion` | `event_id`, `session_key`, `content` | Subagent task completes and result is routed | No |
| `done` | `done` | `session_id?`, `message_id?` | Turn complete | **Yes** |

### Event Ordering Invariants

1. Every stream **must** end with exactly one `done` event.
2. `reply_start` always precedes any `token` events for a given reply.
3. `error` events are always followed by a `done` event (error is not terminal by itself).
4. `status` is typically the first event emitted.
5. `progress` events can appear at any point during processing (including as keepalives).
6. `reasoning_summary` appears after thinking/tool phases, before the final reply.

## 2. Target SSE Events (Planned)

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

### Replay Contract

A client that connects mid-stream or reconnects can reconstruct the run state:

1. **Buffered replay**: When `delivery_mode` is `"buffered_replay"`, the gateway replays the complete response as token chunks. `live` is `false`.
2. **Live streaming**: When `delivery_mode` is `"live"`, tokens are emitted in real-time. `live` is `true`.
3. **Session continuity**: The `session_key` in the `ready` event identifies the session lane. The client uses this to resume.
4. **Event ID ordering**: `seq` on token events provides ordering. Clients should buffer and sort by `seq` on replay.
5. **Terminal detection**: The `done` event is the only terminal event. Clients must not close the connection until `done` is received.

### Backward Compatibility Rules

1. **Additive only**: New event types may be added. Existing event types will not be removed or renamed.
2. **Payload extension**: New optional fields may be added to existing event payloads. Existing fields will not be removed or change type.
3. **Ordering preserved**: The ordering invariants above are permanent. `done` is always terminal.
4. **Unknown events**: Clients must ignore event types they do not recognize (forward compatibility).
5. **Type field**: All events carry a `type` field in their JSON payload. Clients should dispatch on `type`, not on the SSE `event:` line.

## 3. SSE Frame Format Reference

All frames follow the Server-Sent Events spec:

```
event: <event_name>\n
data: <json_payload>\n
\n
```

The keepalive frame is a `progress` event with phase `"thinking"`:
```
event: progress
data: {"type":"progress","phase":"thinking","state":"update","label":"Still working on the reply"}
```

Token chunk size: **96 bytes** (`SSE_TOKEN_CHUNK_SIZE` in `src/gateway.zig`).

## 4. Error Codes

Current error codes emitted via `sseErrorFrame`:

| Code | Meaning | HTTP Status |
|---|---|---|
| `rate_limited` | Too many requests in sliding window | 429 |
| `gateway_draining` | Gateway is shutting down | 503 |
| `ownership_lock_conflict` | User active on another node (tenant mode) | 409 |
| `invalid_session_key` | Session key format invalid or wrong user | 400 |
| `tenant_config_missing` | Tenant runtime not available | 400 |
| `execution_delegated` | Broker mode, cannot execute locally | 400 |
| `chat_failed` | Agent execution failed | 500 |
| `broker_proxy_failed` | Broker proxy request failed | 502 |

## 5. Source References

- SSE frame functions: `src/gateway.zig` lines 7187-7844
- Chat stream handler: `src/gateway.zig` `/api/v1/chat/stream` endpoint
- Rate limiter: `src/gateway.zig` `SlidingWindowRateLimiter` (line 128)
- Subagent completion routing: `src/subagent.zig` `SubagentManager.completeTask`
- Idempotency store: `src/gateway.zig` `IdempotencyStore` (line 258)
- Characterization tests: `src/gateway.zig` baseline tests at end of file
