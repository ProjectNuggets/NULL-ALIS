# Agent A: Phase 1 — Inbound Unification & Parallel Dispatch

## Preamble (Read Before Every Step)

**Project**: nullalis — Zig 0.15.2 vtable-driven autonomous agent runtime. 205 source files, ~146K LOC, 4,263+ tests.

**Branch**: Work on feature branch from `dogfood-stable`.

**Constraints**: Read `AGENTS.md` at repo root. All changes must pass `zig build test --summary all` with zero leaks. No breaking changes to ZAKI integration API. Follow vtable + factory patterns.

**What you're doing**: Currently there are TWO inbound message processing models:
- **Model A (Polling)**: Telegram, Signal, Matrix call `session_mgr.processMessageWithToolContext()` directly in their polling threads, bypassing the event bus.
- **Model B (Bus)**: Discord, Slack, IRC, Mattermost, iMessage publish to the bus, and a single `inboundDispatcherThread` processes them.

You are unifying all channels onto the bus path, then making the dispatcher parallel.

**Why**: The single dispatcher is a bottleneck (all gateway channel messages serialized). The dual code paths double the maintenance surface. Unifying enables parallel processing which pushes capacity from ~200 to ~1,000+ users per instance.

## Key File References

| File | What | Key Lines |
|------|------|-----------|
| `src/channel_loop.zig` | Polling loops for Telegram/Signal/Matrix | `runTelegramLoop`:433, `runSignalLoop`:546, `runMatrixLoop`:766 |
| `src/channel_loop.zig` | Inline processing (Telegram) | `processTelegramMessages`:343, direct `processMessageWithToolContext` call:387-403 |
| `src/channel_loop.zig` | Inline processing (Signal) | Direct call:610-628 |
| `src/channel_loop.zig` | Inline processing (Matrix) | Direct call:816-832 |
| `src/channel_loop.zig` | ChannelRuntime struct | `event_bus` field:220 |
| `src/daemon.zig` | `inboundDispatcherThread` | Signature:1476, consume loop:1485, processMessage:1517-1521, publish outbound:1551 |
| `src/daemon.zig` | Thread spawning | `daemon.run`:1574, event_bus:1631, inbound spawn:1700 |
| `src/bus.zig` | `BoundedQueue` | Ring buffer:257, mutex:266, capacity:331 |
| `src/bus.zig` | `makeInbound` | Signature:63-70, `makeInboundFull`:90-99 |
| `src/bus.zig` | `InboundMessage` | Struct:15-33 |
| `src/bus.zig` | `OutboundMessage` | Struct:36-57 |
| `src/bus.zig` | `Bus.publishInbound` | Method:343-345 |
| `src/channels/dispatch.zig` | `runOutboundDispatcher` | Signature:163-168, consume loop:169, channel send:196 |
| `src/session.zig` | Session mutex | Per-session lock:38, held for entire turn:197 |
| `src/config_types.zig` | Config defaults | gateway defaults, bus capacity |

## Steps

### Step A1: Add Bus Queue Length Accessors

**Goal**: Expose bus queue depths for diagnostics.

**Files to modify**: `src/bus.zig`

**Actions**:
1. Read `src/bus.zig` lines 250-310. The `BoundedQueue` struct has `len: usize` (line 264) guarded by `mutex` (line 266).
2. Add two public methods to `Bus` (after line 377):
   ```zig
   pub fn inboundLen(self: *Bus) usize {
       self.inbound.mutex.lock();
       defer self.inbound.mutex.unlock();
       return self.inbound.len;
   }

   pub fn outboundLen(self: *Bus) usize {
       self.outbound.mutex.lock();
       defer self.outbound.mutex.unlock();
       return self.outbound.len;
   }
   ```
3. Add tests for both methods (empty queue returns 0, after publish returns 1, after consume returns 0).

**Acceptance**: `zig build test --summary all` passes. New accessor methods work.

---

### Step A2: Add Scale Diagnostics

**Goal**: Extend `/internal/diagnostics` with bus and transport metrics.

**Files to modify**: `src/gateway.zig` — find the diagnostics endpoint handler (search for `/internal/diagnostics`)

**Actions**:
1. Read the existing diagnostics handler in `src/gateway.zig`.
2. Add these fields to the JSON response:
   - `"bus_inbound_len"` — call `event_bus.inboundLen()` (if bus pointer available) or `0`
   - `"bus_outbound_len"` — call `event_bus.outboundLen()` (if bus pointer available) or `0`
   - `"transport"` object with `native_total`, `curl_total`, `fallback_total` from `http_util.transport_stats_snapshot()` (already imported — check existing usage around line 2570-2610)
   - `"runtime_mode": "threaded"`
3. The `GatewayState` struct (line ~340) needs access to the bus pointer. Check if it already has one — if not, add `event_bus: ?*bus_mod.Bus = null` and wire it during init.
4. Add a test verifying the diagnostics JSON contains the new fields.

**Acceptance**: `zig build test --summary all` passes. Diagnostics endpoint returns new fields.

---

### Step A3: Route Telegram Through the Bus

**Goal**: Replace Telegram's inline processing with bus-mediated processing.

**Files to modify**: `src/channel_loop.zig` — `runTelegramLoop` (line 433) and `processTelegramMessages` (line 343)

**Current flow** (channel_loop.zig:387-403):
```
processTelegramMessages() calls:
  session_mgr.processMessageWithToolContext(session_key, msg.content, null, .{
      .channel = "telegram",
      .account_id = tg_ptr.account_id,
      .chat_id = msg.sender,
  })
then sends reply directly via tg_ptr.sendMessageWithReply()
```

**Target flow**:
```
processTelegramMessages() calls:
  event_bus.publishInbound(bus.makeInbound(...))
  // Reply comes back through outbound dispatcher -> channel.send()
```

**Actions**:
1. Read `src/bus.zig` lines 63-89 — `makeInbound()` needs: `allocator, channel, sender_id, chat_id, content, session_key`.
2. Read `src/channel_loop.zig` lines 220-230 — `ChannelRuntime` has `event_bus: ?*bus_mod.Bus` field.
3. In `processTelegramMessages` (line 343), replace the `session_mgr.processMessageWithToolContext()` call and direct reply send with:
   - Construct session_key the same way (check existing code for the format)
   - Call `runtime.event_bus.?.publishInbound(try bus_mod.makeInbound(allocator, "telegram", msg.sender, chat_id_str, msg.content, session_key))`
   - Remove the direct `tg_ptr.sendMessageWithReply()` — replies flow through outbound dispatcher
4. Verify `inboundDispatcherThread` (daemon.zig:1476) handles Telegram messages — when it gets `.channel = "telegram"`, the outbound reply must have the right channel and chat_id.
5. Verify outbound dispatcher (dispatch.zig:163) can find Telegram in the `ChannelRegistry`.
6. **Typing indicators**: Call `tg_ptr.startTyping(chat_id)` before publishing to bus. The channel's `send()` method or outbound dispatcher should stop typing after sending.
7. Handle media/attachments: If `processTelegramMessages` passes media, use `makeInboundFull` (bus.zig:90).
8. Add/update tests.

**Risks**:
- Session key format must match what `inboundDispatcherThread` expects (read daemon.zig:1490-1515).
- `account_id` on `OutboundMessage` must match Telegram's registration so outbound dispatcher finds the right channel instance.

**Acceptance**: Telegram messages flow through the bus. No inline `processMessageWithToolContext` in polling loop. `zig build test --summary all` passes. Manual test: send Telegram message, receive reply.

---

### Step A4: Route Signal Through the Bus

**Goal**: Same as Step A3 but for Signal.

**Files to modify**: `src/channel_loop.zig` — `runSignalLoop` (line 546), inline processing at lines 610-628

**Actions**:
1. Same pattern as Step A3. Replace `session_mgr.processMessageWithToolContext()` with `event_bus.publishInbound()`.
2. Signal passes `conversation_context` (line 610). Store it in `InboundMessage.metadata_json` if needed.
3. Handle typing indicators same way as Telegram.
4. Update tests.

**Acceptance**: Signal messages flow through the bus. `zig build test --summary all` passes.

---

### Step A5: Route Matrix Through the Bus

**Goal**: Same as Steps A3/A4 but for Matrix.

**Files to modify**: `src/channel_loop.zig` — `runMatrixLoop` (line 766), inline processing at lines 816-832

**Actions**:
1. Same pattern. Replace inline processing with bus publish.
2. Matrix is simpler (no conversation_context, no complex media).
3. Update tests.

**Acceptance**: Matrix messages flow through the bus. `zig build test --summary all` passes.

---

### Step A6: Parallel Inbound Dispatcher

**Goal**: Replace single `inboundDispatcherThread` with N workers.

**Files to modify**:
- `src/daemon.zig` — thread spawning (line ~1700)
- `src/config_types.zig` — add config field
- `src/config_parse.zig` — parse new field

**Actions**:
1. Add to gateway config in `src/config_types.zig`:
   ```zig
   inbound_workers: u32 = 4,
   ```
2. Add config parsing in `src/config_parse.zig`.
3. In `daemon.run()` (line ~1700), replace single spawn with a loop:
   ```zig
   const num_workers = @max(1, config.gateway.inbound_workers);
   var inbound_threads: [16]?std.Thread = .{null} ** 16;
   const worker_count = @min(num_workers, 16);
   for (0..worker_count) |i| {
       inbound_threads[i] = std.Thread.spawn(
           .{ .stack_size = 512 * 1024 },
           inboundDispatcherThread,
           .{ allocator, &event_bus, &channel_registry, rt, &state },
       ) catch null;
   }
   ```
4. Update shutdown/join logic to join all worker threads.
5. `BoundedQueue.consume()` is already thread-safe. Multiple consumers each get unique items.
6. Session serialization still works: `Session.mutex` ensures one turn per session. Parallel workers block on session mutex for same session. Different sessions run fully parallel.
7. Add test: concurrent messages for different sessions processed in parallel.

**Acceptance**: N inbound workers running (default 4). Different sessions parallel. Same session serialized. `zig build test --summary all` passes.

---

### Step A7: Increase Bus Capacity

**Goal**: Bump bus queue capacity from 100 to 1024.

**Files to modify**: `src/bus.zig` — `QUEUE_CAPACITY` constant (line ~331)

**Actions**:
1. Change from 100 to 1024.
2. Ring buffer is stack-allocated (`buf: [capacity]T`). `InboundMessage` and `OutboundMessage` contain slices (pointers), not inline data, so 1024 entries is fine.
3. Verify no tests assume capacity=100.

**Acceptance**: Bus capacity is 1024. `zig build test --summary all` passes.

---

### Step A8: Parallel Outbound Dispatcher (Optional)

**Goal**: Add parallel outbound workers if outbound becomes a bottleneck.

**Files to modify**:
- `src/daemon.zig` — outbound dispatcher spawning (line ~1717)
- `src/channels/dispatch.zig` — `runOutboundDispatcher`

**Actions**:
1. Same pattern as Step A6. Spawn N outbound workers consuming from `bus.outbound`.
2. `OpsGuard` (ops_guard.zig:41) has its own mutex — thread-safe for parallel consumers.
3. Default: 2 outbound workers.

**Acceptance**: Parallel outbound dispatch working. `zig build test --summary all` passes.
