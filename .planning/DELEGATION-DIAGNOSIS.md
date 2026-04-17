# Sub-agent Result Delivery — Diagnosis

**Date:** 2026-04-17
**Theme:** 3 (Smooth the Core — sub-agents)
**Author:** Claude (grounded in current code)

## Symptom (user report)

> "spawning a sub-agent is not returning results"

## Evidence — what the code actually does

### Tool surface
Two distinct tools, different semantics, one rough shared contract.

| Tool | What it does | Return semantics |
|------|--------------|------------------|
| `delegate` (`tools/delegate.zig`) | Single-turn LLM call to a named named agent config with a different provider/model. Synchronous. | Returns response inline as a tool_result in the SAME turn. Already works. |
| `spawn` (`tools/spawn.zig`) | Queues a background sub-agent task via `SubagentManager`. Async. | Returns task_id immediately. Promises "Results will be delivered as system messages." **This is the broken path.** |

The user's bug is about `spawn`, not `delegate`.

### Trace of a `spawn` call in tenant (production) mode

1. **Parent agent emits `spawn(task="…")` tool call**
   - `tools/spawn.zig:55` — `manager.spawn(...)` returns a task_id
   - Parent gets `"Subagent 'X' spawned with task_id=N state=queued. Results will be delivered as system messages."` as the synchronous tool_result

2. **Background thread executes the sub-agent** (`subagent.zig:608 subagentThreadFn`)
   - Runs full agent loop against configured model
   - Completes, sets `owned_result` or `owned_err`

3. **Finalization dispatch** (`subagent.zig:553-591`)
   ```zig
   if (self.bus) |b| {
       b.publishInbound(msg) catch ...;
   } else if (self.completion_delivery) |delivery| {
       delivery(self.completion_delivery_ctx, request_session_key, content) catch ...;
   }
   ```
   — **This is the bug site.** Two delivery mechanisms, mutually exclusive via `else if`.

4. **Tenant runtime wiring** (`gateway.zig:1272-1373`)
   - `SubagentManager.init(alloc, &cfg, event_bus, .{})` — passes the event bus. (`bus` is now non-null.)
   - Later: `mgr.attachCompletionDelivery(@ptrCast(router), appendSubagentCompletionToGatewaySession)` — attaches the direct callback too.
   - **Result: both fields are set. Because `else if`, only `bus.publishInbound` fires.** The completion callback is dead code in tenant mode.

5. **Who consumes the bus inbound queue?**
   - `grep consumeInbound /Users/nova/Desktop/nullalis/src` returns:
     - `daemon.zig:1850` — the inbound dispatcher loop inside `daemon.run()`
     - Many `tests` in `channels/*` and `gateway.zig:17386,17404` (test block only)
   - In tenant mode (`role = .user_cell`), `main.zig:510` calls `gateway.runWithRole(...)` — **NOT `daemon.run(...)`**.
   - Therefore the bus inbound queue has **no consumer** in tenant mode.
   - **The subagent result is published to a queue nobody reads.** It sits there until eviction or shutdown. Parent never sees it.

### Verification that completion_delivery is the semantically correct tenant path

`appendSubagentCompletionToGatewaySession` at `gateway.zig:354-427`:
1. Calls `session_mgr.appendAssistantMessage(session_key, content)` — adds the subagent result to the **parent's conversation history** as an assistant message.
2. Calls `session_mgr.saveCompletionEvent(...)` — persists the event.
3. For `zaki_app` channel: `app_event_subscribers.publish(...)` — pushes as SSE event to any live app client so the user sees it **in real time**.
4. For external channels (Telegram etc.): routes via `bus.publishOutbound` or `dispatchSubagentCompletionLocally`.

This is exactly what "result returned to parent" means. The callback exists, is wired, and is correct. It just isn't being invoked.

### Why tests pass

`subagent.zig:1416` — the only e2e spawn test — uses the **bus path** explicitly (`waitForInboundMessage(&bus, 250)`). It does not exercise `completion_delivery`. So the broken production path has zero test coverage.

## Root cause

One line of branching logic:

```zig
if (self.bus) |b| { … } else if (self.completion_delivery) |delivery| { … }
```

`else if` is wrong here. When both are set (tenant mode), the caller has explicitly attached a direct delivery callback. The callback is the more specific, more semantic delivery path. The bus publish is a broadcast to a queue whose consumer doesn't exist.

## The fix — minimum, surgical

Flip precedence in `subagent.zig:553-591`:

```zig
if (self.completion_delivery) |delivery| {
    // Direct callback — tenant mode, SessionManager-aware, SSE-aware.
    delivery(…);
} else if (self.bus) |b| {
    // Shared/daemon mode — relies on daemon.run() inbound dispatcher.
    b.publishInbound(…);
}
```

Plus: rename `completion_delivery` → clear name that reflects intent (e.g., `direct_delivery`). Add a log line recording which path fired (aids future debugging). Keep both code paths — shared mode still needs bus.

## What this does NOT fix

1. **No structured result envelope yet.** The parent gets a string `"[Subagent 'X' completed]\n<result>"` appended as an assistant message. For reasoning over it, the parent treats it as prose, not a typed record. **Phase 2 cross-agent needs a typed envelope** (`request_id`, `scope`, `status`, `citations`, `visibility_level` per plan.md §5). This is the "extra hour of design" I asked for.
2. **No timeout on the parent side.** Spawn returns immediately; parent has no way to say "wait up to 30s for result then proceed". The current model is fire-and-forget with eventual delivery. Fine for async work; insufficient for "ask and wait briefly" patterns.
3. **No cancellation propagation.** If the parent session ends before the sub-agent completes, the sub-agent keeps running and writes back to a dead session. Should cancel.

Items 1-3 become the structured contract work — not blocking the bug fix, but needed for the template.

## Proposed sequence

1. **Ship the fix (commit 1).** Flip the precedence. Add the missing integration test (tenant-mode completion_delivery path). ~30 LOC change, ~40 LOC test.

2. **Design the envelope (commit 2).** Introduce `SubagentCompletion` struct matching plan.md §5 envelope shape. Keep the string content for backward compat but attach structured metadata. Envelope reused by Phase 2 cross-agent later.

3. **Close timeout + cancellation (commit 3).** Parent can optionally `spawn_and_wait(task, timeout_ms)`. Session teardown cancels in-flight subagents.

4. **Documentation (commit 4).** `src/agent/DELEGATION.md` — one page, what the contracts are, when to use `delegate` vs `spawn`, how results flow.

Total estimate: 1-1.5 days for commits 1-3, half day for #4.

## Files touched (surgical list)

- `src/subagent.zig` — precedence flip, rename field, logging
- `src/subagent.zig` — new test for completion_delivery path
- `src/agent/DELEGATION.md` — new, doc

Commits 2-3 will touch additional files; that's the extra hour of design I'll share before coding.

## One-line summary

Sub-agent results in tenant (production) mode publish to a bus queue with no consumer. Flipping `if/else if` precedence in `subagent.zig:553` routes them through the already-wired direct callback that appends to the parent's session and pushes an SSE event. Bug was untested, not undiscoverable.
