# Sprint S4 — Extension Browser Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the chat-side browser-extension surface to production-grade for ZAKI commercial V1: a per-user observable pair/connect/disconnect/timeout/command-failed state machine, control-plane diagnostics routes, structured failure surfaces the UI can bind, and a cross-tenant-isolated E2E that runs every shipped `extension_*` tool through a mock hub.

**Architecture:** The shipped surface (`src/extension_ws/auth.zig`, `src/extension_ws/hub.zig`, `src/extension_ws/server.zig`, the ten `src/tools/extension_*.zig` tools, and the `GET /api/v1/extension/ws` route) is already structurally correct: per-user token auth is the only model, eviction-on-reconnect works, OOM/timeout/UAF have refcounts, and the ten tools surface named user-safe error strings. S4 closes the remaining gaps:

1. **Per-user lifecycle snapshot on the hub** — add `connected_at_ns`, `last_command_at_ns`, `last_command_tool`, `last_command_result` to `ExtensionWsConn`; expose `ExtensionWsHub.listSnapshot(allocator)` returning a heap-owned array of per-user states.
2. **Two new control-plane diagnostics routes** — `GET /api/v1/diagnostics/extension/status` (system-wide, internal-token-gated) and `GET /api/v1/diagnostics/extension/users/{user_id}` (per-user, internal-token-or-self-gated). Both return documented JSON shapes the UI/operators can bind.
3. **Canonical structured event log** — `extension_ws.event=<pair|disconnect|timeout|command_failed>` lines emitted from a single helper so future ingestion can grep them deterministically.
4. **Tests** — three new test files under `tests/extension/`:
   - `cross_user_isolation_test.zig` — proves user A's token cannot pair as user B, and user A's command never reaches user B's socket, against a real `ExtensionWsHub` with two mock conns.
   - `mock_hub_e2e_test.zig` — drives every shipped `extension_*` tool through a mock conn and asserts the named failure states (success / no_extension_connected / timeout / disconnect / command_failed).
   - `diagnostics_test.zig` — exercises both new diagnostic routes through `internalDiagnosticsPayload`-style helpers, verifying the documented JSON shape and the auth gates.
5. **Doc sync** — `docs/extension-ws-contract.md` gains a state-machine section, the new diagnostic routes, and the UI-safe failure-state taxonomy; `docs/openapi-v1.yaml` documents both new routes; `docs/ui-handoff.md` lists the safe states; `docs/deferred-register.md` closes D67 partial-row and adds the Sprint S4 completion line.

**Tech Stack:** Zig 0.14.x, existing `observability.recordMetricGlobal`, existing `std.log.scoped(.extension_ws)`, existing `std.atomic.Value` patterns, existing `tests/security/` build-step pattern.

**Non-goals (do NOT add):**
- Don't change auth — per-user tokens are already the only model; see `src/extension_ws/auth.zig:13-23` for the locked contract. Verify and document, don't rewrite.
- Don't add a public `/api/v1/extension/ws` to OpenAPI as a callable endpoint; document it explicitly as a WebSocket (OpenAPI 3.0 doesn't have a callable WS schema). Keep it under the `# WebSocket endpoints` section comment.
- Don't change tool failure strings — they're already user-safe. Add a *state classifier* the UI can branch on without parsing strings.
- Don't extract `extension_navigate`-family tests out of the per-tool files — they pin the existing per-tool contract. The new `mock_hub_e2e_test.zig` is additive cross-tool coverage.

---

## File Structure

**Create:**
- `tests/extension/cross_user_isolation_test.zig` — cross-tenant isolation against `ExtensionWsHub`.
- `tests/extension/mock_hub_e2e_test.zig` — every `extension_*` tool exercised through a mock conn.
- `tests/extension/diagnostics_test.zig` — diagnostic-route payload + auth tests.

**Modify:**
- `src/extension_ws/hub.zig`:
  - Add lifecycle fields + update helpers to `ExtensionWsConn` (between the existing `evicted` and `refs` fields, ~line 158).
  - Wire updates in `sendCommand` success + each error branch (~lines 644, 660, 668, 684).
  - Add `pub const ExtensionState = struct {...}` and `pub fn listSnapshot(self, allocator)` to `ExtensionWsHub` (after `getForUser`, ~line 580).
  - Add inline tests at the bottom of the file (before the soak block).
- `src/extension_ws/hub.zig` event helper: add a small `emitLifecycleEvent` private fn used at register/unregister/timeout/command-failed sites — keeps the log format consistent.
- `src/gateway.zig`:
  - Add `extensionStatusPayload(allocator, state)` next to `metricsPayload` (~line 6653).
  - Add `extensionUserStatusPayload(allocator, state, user_id)` directly under it.
  - Add a route arm under the ZAKI dispatcher recognizing the two new paths (search for `/api/v1/users/` near the artifact-export bridge dispatch, ~line 17358 — use the same precedence pattern).
  - Add two route-table comment rows above the dispatcher (search for the `(501)` annotation comment cluster).
  - Add inline tests at the bottom of `src/gateway.zig` for the two payload helpers + the auth gate.
- `docs/extension-ws-contract.md`:
  - Add `## Connection state machine` section (after `## Token + user_id semantics`, before `## Approval-gate behavior`).
  - Add `## Control-plane diagnostics` section (after the state machine section).
  - Add `## UI-safe failure states` section (new, near the bottom before `Cost class`).
- `docs/openapi-v1.yaml`:
  - Add the two new `/api/v1/diagnostics/extension/*` routes with response schemas.
  - Add a WebSocket-endpoint comment block referencing `GET /api/v1/extension/ws` (OpenAPI 3.0 doesn't model WS — comment is the documented placeholder pattern already used in this file for other WS surfaces).
- `docs/ui-handoff.md`:
  - In the extension lane table cell (line 134), append a short reference to the new diagnostic routes.
  - Replace the open-checkbox cluster at lines 537-540 with checked-off equivalents *if and only if* the implementation tasks below have all landed (the audit task at the end of this plan handles the verification).
- `docs/deferred-register.md`:
  - Mark D67 row as `shipped` with the commit SHA of the wave that closes hub observability + diagnostics routes; cite file:line refs.
  - Append a new row for the Sprint S4 completion line referencing the commit chain.
- `build.zig`:
  - Wire the three new test files as their own `addTest` steps next to `security_sandbox_tests` (search for the comment "V8 (v1.14.13 Step 0): security tests live outside src/").

**No new modules.** All hub changes are local to the existing `extension_ws/hub.zig`. Diagnostic payload helpers live in `gateway.zig` (monolith pattern). Tests live under `tests/extension/` alongside the existing `tests/security/`, `tests/runtime/`, `tests/agent/` siblings.

---

## Bite-Sized Task Granularity

Each task is one atomic commit. Commit message style follows the recent log: `feat(extension_ws): ...`, `feat(gateway): ...`, `test(extension): ...`, `docs(extension): ...`. The verification at the end runs the full `zig build` + `zig build test` matrix.

---

## Task 1: Add lifecycle-tracking fields to `ExtensionWsConn`

**Files:**
- Modify: `src/extension_ws/hub.zig` (~line 156, after the existing `evicted` field, before `refs`).
- Test: `src/extension_ws/hub.zig` (inline tests, append before the soak section ~line 1455).

**Rationale:** The hub currently knows whether a connection exists but not when it connected or what its last command did. The diagnostic route needs this. We add the fields, update them at the right points, and expose them via a new snapshot fn (Task 3).

- [ ] **Step 1: Write the failing tests for the lifecycle fields**

Append to the bottom of `src/extension_ws/hub.zig`, just above the `// ── Soak ──` block (search for `test "v1.14.22: 50-worker soak`):

```zig
test "ExtensionWsConn lifecycle fields default to zero on construction" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var ts = TestStream{ .allocator = std.testing.allocator };
    defer ts.deinit();
    const conn = try hub.registerConn(
        "alice",
        @ptrCast(&ts),
        TestStream.writeText,
        @ptrCast(&ts),
        TestStream.close,
    );
    defer hub.destroyConn(conn);
    // Connected timestamp is set on registerConn — not zero.
    try std.testing.expect(conn.connected_at_ns.load(.monotonic) > 0);
    // last_command_at starts at zero (no commands yet).
    try std.testing.expectEqual(@as(i128, 0), conn.last_command_at_ns.load(.monotonic));
    // last_command_tool / last_command_result start empty.
    try std.testing.expectEqual(@as(usize, 0), conn.last_command_tool_len.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), conn.last_command_result_len.load(.monotonic));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'lifecycle fields|error:'`
Expected: compile error mentioning `connected_at_ns` is not a member of `ExtensionWsConn`.

- [ ] **Step 3: Add the lifecycle fields**

In `src/extension_ws/hub.zig`, locate the `ExtensionWsConn` struct (line 136). Add these fields directly after the existing `refs` field (~line 178):

```zig
/// Wall-clock nanoseconds (std.time.nanoTimestamp) when this conn was
/// registered with the hub. Set once in `registerConn`; never updated
/// thereafter. Zero means "not yet registered" (only observable on a
/// half-constructed conn struct).
connected_at_ns: std.atomic.Value(i128) = std.atomic.Value(i128).init(0),

/// Wall-clock nanoseconds of the last command dispatch result
/// (success OR named failure). Zero means "no command yet."
last_command_at_ns: std.atomic.Value(i128) = std.atomic.Value(i128).init(0),

/// Fixed-size scratch buffer for the last command's tool name. The
/// max-32-byte cap is generous for the v1 tool family (longest is
/// `extension_screenshot` at 20 bytes); future longer names get
/// truncated rather than allocated-per-update. Reading requires
/// loading `last_command_tool_len` first.
last_command_tool_buf: [32]u8 = [_]u8{0} ** 32,
last_command_tool_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

/// Same buffer pattern for the last command's result classifier
/// ("ok", "timeout", "conn_closed", "oom", "no_conn", "error_other").
last_command_result_buf: [32]u8 = [_]u8{0} ** 32,
last_command_result_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

/// Mutex protecting the two fixed-size buffers above. We use a mutex
/// rather than treating the buffers as atomic-byte-stores because the
/// snapshot fn needs to read tool + result + length consistently
/// (otherwise it could observe a torn pair: new length, old bytes).
last_command_mu: std.Thread.Mutex = .{},
```

- [ ] **Step 4: Set `connected_at_ns` in `registerConn`**

Locate `registerConn` (~line 493). After the `conn.* = .{ ... };` initialization and before the `users_mu.lock()` call (so the timestamp is set unconditionally for the new conn), insert:

```zig
conn.connected_at_ns.store(std.time.nanoTimestamp(), .release);
```

- [ ] **Step 5: Add `recordCommandOutcome` private helper on `ExtensionWsConn`**

Inside the `ExtensionWsConn` struct (anywhere after the `release` fn, ~line 260), add:

```zig
/// Stamp the last_command_* fields with the named result class and
/// the dispatched tool. Called by the hub's `sendCommand` at every
/// terminal point (success + each error branch).
///
/// `tool` and `result` are borrowed only for the copy; the buffers
/// are owned by the conn struct (fixed-size, no heap).
pub fn recordCommandOutcome(self: *ExtensionWsConn, tool: []const u8, result: []const u8) void {
    self.last_command_mu.lock();
    defer self.last_command_mu.unlock();

    const tool_len = @min(tool.len, self.last_command_tool_buf.len);
    @memcpy(self.last_command_tool_buf[0..tool_len], tool[0..tool_len]);
    self.last_command_tool_len.store(tool_len, .release);

    const result_len = @min(result.len, self.last_command_result_buf.len);
    @memcpy(self.last_command_result_buf[0..result_len], result[0..result_len]);
    self.last_command_result_len.store(result_len, .release);

    self.last_command_at_ns.store(std.time.nanoTimestamp(), .release);
}

/// Snapshot helper — copy the last command's tool + result into
/// caller-owned buffers under a single mutex hold. Returns the
/// effective lengths. Callers MUST size each `out_*` to ≥32 bytes.
pub fn snapshotLastCommand(self: *ExtensionWsConn, out_tool: []u8, out_result: []u8) struct { tool_len: usize, result_len: usize, at_ns: i128 } {
    self.last_command_mu.lock();
    defer self.last_command_mu.unlock();

    const tool_len = self.last_command_tool_len.load(.acquire);
    const result_len = self.last_command_result_len.load(.acquire);
    const tl = @min(tool_len, out_tool.len);
    const rl = @min(result_len, out_result.len);
    @memcpy(out_tool[0..tl], self.last_command_tool_buf[0..tl]);
    @memcpy(out_result[0..rl], self.last_command_result_buf[0..rl]);
    return .{
        .tool_len = tl,
        .result_len = rl,
        .at_ns = self.last_command_at_ns.load(.acquire),
    };
}
```

- [ ] **Step 6: Run the test to verify it now passes**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'lifecycle fields default|FAIL|error:'`
Expected: PASS (no FAIL, no error).

- [ ] **Step 7: Commit**

```bash
git add src/extension_ws/hub.zig
git commit -m "$(cat <<'EOF'
feat(extension_ws): S4 — lifecycle fields on ExtensionWsConn (connected_at, last_command)

Adds connected_at_ns, last_command_at_ns, and fixed-size buffers for
last tool name + result classifier on ExtensionWsConn. recordCommandOutcome
and snapshotLastCommand expose them to the upcoming hub snapshot fn and
diagnostic routes. Mutex-guarded buffers so the snapshot read is consistent.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire `recordCommandOutcome` into every `sendCommand` exit path

**Files:**
- Modify: `src/extension_ws/hub.zig` — the `ExtensionWsHub.sendCommand` fn (~line 627).
- Test: inline in `src/extension_ws/hub.zig`.

**Rationale:** Task 1 only added the storage. The hub's `sendCommand` already labels each exit ("no_conn", "timeout", "conn_closed", "oom", "error_other", "ok") for the metric emit (`extension_ws_command_total`). We branch off the same classification to also stamp `recordCommandOutcome`.

- [ ] **Step 1: Write the failing test**

Append to `src/extension_ws/hub.zig` (immediately after the Task 1 test):

```zig
test "sendCommand records last command outcome on success" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var ts = TestStream{ .allocator = std.testing.allocator };
    defer ts.deinit();
    const conn = try hub.registerConn(
        "alice",
        @ptrCast(&ts),
        TestStream.writeText,
        @ptrCast(&ts),
        TestStream.close,
    );
    defer hub.destroyConn(conn);

    // Sender thread issues a navigate; deliverer thread responds.
    const Helper = struct {
        c: *ExtensionWsConn,
        fn deliver(ctx: @This()) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            ctx.c.deliverResult(
                \\{"command_id":"cmd-1","ok":true,"result":{"loaded":true}}
            ) catch {};
        }
    };
    var thread = try std.Thread.spawn(.{}, Helper.deliver, .{Helper{ .c = conn }});
    defer thread.join();

    const r = try hub.sendCommand(std.testing.allocator, "alice", "navigate", "{}", 200);
    defer std.testing.allocator.free(r);

    var tool_buf: [32]u8 = undefined;
    var result_buf: [32]u8 = undefined;
    const snap = conn.snapshotLastCommand(&tool_buf, &result_buf);
    try std.testing.expectEqualStrings("navigate", tool_buf[0..snap.tool_len]);
    try std.testing.expectEqualStrings("ok", result_buf[0..snap.result_len]);
    try std.testing.expect(snap.at_ns > 0);
}

test "sendCommand records timeout as last command result" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var ts = TestStream{ .allocator = std.testing.allocator };
    defer ts.deinit();
    const conn = try hub.registerConn(
        "alice",
        @ptrCast(&ts),
        TestStream.writeText,
        @ptrCast(&ts),
        TestStream.close,
    );
    defer hub.destroyConn(conn);

    // No deliverer thread — let it timeout.
    const r = hub.sendCommand(std.testing.allocator, "alice", "click", "{}", 20);
    try std.testing.expectError(error.Timeout, r);

    var tool_buf: [32]u8 = undefined;
    var result_buf: [32]u8 = undefined;
    const snap = conn.snapshotLastCommand(&tool_buf, &result_buf);
    try std.testing.expectEqualStrings("click", tool_buf[0..snap.tool_len]);
    try std.testing.expectEqualStrings("timeout", result_buf[0..snap.result_len]);
}

test "sendCommand records no_conn when no extension paired" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    // No registerConn — no_conn path.
    const r = hub.sendCommand(std.testing.allocator, "ghost", "screenshot", "{}", 20);
    try std.testing.expectError(error.NoExtensionConnected, r);
    // Ghost user has no conn so there's nothing to assert on the
    // snapshot side — the metric is the visible signal. This test
    // mostly pins the error class.
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'records last command|records timeout|FAIL'`
Expected: the success test fails because the snapshot tool_len is 0 (no record yet).

- [ ] **Step 3: Wire `recordCommandOutcome` at each exit branch**

In `src/extension_ws/hub.zig`, inside `ExtensionWsHub.sendCommand` (~line 627):

After the `defer _ = conn.release();` line (~line 647), the function already classifies into `result_label` strings in the error branch (~line 662) and emits `"ok"` in the success branch (~line 684). At each terminal point, also call `conn.recordCommandOutcome(tool, result_label)`.

Specifically, modify the `catch |err|` block at line 659 to also call `conn.recordCommandOutcome(tool, result_label)` right after computing `result_label`:

```zig
const result_borrowed = conn.sendCommand(result_allocator, id, command_json, timeout_ms) catch |err| {
    const elapsed_ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - t_start_ns, std.time.ns_per_ms));
    observability.recordMetricGlobal(.{ .extension_ws_command_latency_ms = elapsed_ms });
    const result_label: []const u8 = switch (err) {
        error.Timeout => "timeout",
        error.ConnectionClosed => "conn_closed",
        error.ResultDeliveryOom => "oom",
        else => "error_other",
    };
    observability.recordMetricGlobal(.{ .extension_ws_command_total = .{ .result = result_label, .tool = tool } });
    conn.recordCommandOutcome(tool, result_label); // S4 — diagnostic stamp
    if (err == error.Timeout) {
        log.info("extension_ws: command timed out user_id='{s}' tool='{s}' timeout_ms={d}", .{ user_id, tool, timeout_ms });
    }
    return err;
};
```

And at the success-path tail (~line 684), insert one line:

```zig
observability.recordMetricGlobal(.{ .extension_ws_command_total = .{ .result = "ok", .tool = tool } });
conn.recordCommandOutcome(tool, "ok"); // S4 — diagnostic stamp
```

Do NOT change the `no_conn` branch in any way that calls `recordCommandOutcome` (there's no conn to stamp). The metric emit at that branch already records the named class.

- [ ] **Step 4: Run the test to verify success + timeout cases pass**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'records last command|records timeout|records no_conn|FAIL|error:'`
Expected: all three tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/extension_ws/hub.zig
git commit -m "$(cat <<'EOF'
feat(extension_ws): S4 — stamp last command outcome on every sendCommand exit

Hub.sendCommand now calls recordCommandOutcome at the success and each named
failure branch (timeout, conn_closed, oom, error_other), mirroring the
metric classification. no_conn does not stamp because there is no conn to
write to — the existing metric remains the operator-visible signal.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Expose `ExtensionWsHub.listSnapshot(allocator)` returning per-user state

**Files:**
- Modify: `src/extension_ws/hub.zig` — add `ExtensionState` struct + `listSnapshot` fn.
- Test: inline.

**Rationale:** The gateway's diagnostic route handlers need a stable snapshot of every paired user without holding `users_mu` during the JSON build. `listSnapshot` takes the lock, dupes the data into a caller-owned slice, releases. Caller-owned so the diagnostic-payload fn can format JSON outside the lock window.

- [ ] **Step 1: Write the failing test**

Append to `src/extension_ws/hub.zig`:

```zig
test "ExtensionWsHub.listSnapshot returns empty slice when no conns" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    const snap = try hub.listSnapshot(std.testing.allocator);
    defer ExtensionState.freeSlice(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(usize, 0), snap.len);
}

test "ExtensionWsHub.listSnapshot reflects registered conns with default last_command empty" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var ts_a = TestStream{ .allocator = std.testing.allocator };
    defer ts_a.deinit();
    var ts_b = TestStream{ .allocator = std.testing.allocator };
    defer ts_b.deinit();
    const conn_a = try hub.registerConn("alice", @ptrCast(&ts_a), TestStream.writeText, @ptrCast(&ts_a), TestStream.close);
    defer hub.destroyConn(conn_a);
    const conn_b = try hub.registerConn("bob", @ptrCast(&ts_b), TestStream.writeText, @ptrCast(&ts_b), TestStream.close);
    defer hub.destroyConn(conn_b);

    const snap = try hub.listSnapshot(std.testing.allocator);
    defer ExtensionState.freeSlice(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    // Snapshot fields populated correctly. We don't pin ordering
    // (hashmap iteration is undefined-ordered) so check by uid.
    var saw_alice = false;
    var saw_bob = false;
    for (snap) |s| {
        if (std.mem.eql(u8, s.user_id, "alice")) {
            saw_alice = true;
            try std.testing.expect(s.connected_at_ns > 0);
            try std.testing.expectEqual(@as(i128, 0), s.last_command_at_ns);
            try std.testing.expectEqualStrings("", s.last_command_tool);
            try std.testing.expectEqualStrings("", s.last_command_result);
        } else if (std.mem.eql(u8, s.user_id, "bob")) {
            saw_bob = true;
        }
    }
    try std.testing.expect(saw_alice);
    try std.testing.expect(saw_bob);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'listSnapshot|error: no member|FAIL'`
Expected: compile error — `ExtensionState` is not declared, `listSnapshot` is not a member of `ExtensionWsHub`.

- [ ] **Step 3: Add `ExtensionState` + `listSnapshot`**

In `src/extension_ws/hub.zig`, immediately after the `ExtensionWsConn` struct closing brace (~line 450), insert the new public type:

```zig
/// Caller-owned snapshot of one paired extension. Returned by
/// `ExtensionWsHub.listSnapshot` for the diagnostic routes.
///
/// All slice fields are heap-allocated copies; free via
/// `ExtensionState.freeSlice` so the caller doesn't have to track
/// individual allocations.
pub const ExtensionState = struct {
    user_id: []u8,
    connected_at_ns: i128,
    last_command_at_ns: i128,
    last_command_tool: []u8,
    last_command_result: []u8,

    pub fn freeSlice(allocator: std.mem.Allocator, slice: []ExtensionState) void {
        for (slice) |s| {
            allocator.free(s.user_id);
            allocator.free(s.last_command_tool);
            allocator.free(s.last_command_result);
        }
        allocator.free(slice);
    }
};
```

Inside `ExtensionWsHub` (search for `pub fn getForUser` at ~line 574 — insert directly after it), add the snapshot fn:

```zig
/// Caller-owned snapshot of every currently-paired user. The slice
/// AND each element's fields are heap-allocated; free via
/// `ExtensionState.freeSlice(allocator, slice)`.
///
/// Takes `users_mu` for the duration of the iteration. The per-conn
/// `last_command_*` fields are read under the conn's
/// `last_command_mu` (via `snapshotLastCommand`) so the snapshot is
/// internally consistent even under concurrent sendCommand calls.
pub fn listSnapshot(self: *ExtensionWsHub, allocator: std.mem.Allocator) ![]ExtensionState {
    self.users_mu.lock();
    defer self.users_mu.unlock();

    var out = try allocator.alloc(ExtensionState, self.users.count());
    var written: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < written) : (i += 1) {
            allocator.free(out[i].user_id);
            allocator.free(out[i].last_command_tool);
            allocator.free(out[i].last_command_result);
        }
        allocator.free(out);
    }

    var it = self.users.iterator();
    while (it.next()) |entry| {
        const conn = entry.value_ptr.*;
        var tool_buf: [32]u8 = undefined;
        var result_buf: [32]u8 = undefined;
        const last = conn.snapshotLastCommand(&tool_buf, &result_buf);
        const uid = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(uid);
        const tool = try allocator.dupe(u8, tool_buf[0..last.tool_len]);
        errdefer allocator.free(tool);
        const result = try allocator.dupe(u8, result_buf[0..last.result_len]);
        out[written] = .{
            .user_id = uid,
            .connected_at_ns = conn.connected_at_ns.load(.acquire),
            .last_command_at_ns = last.at_ns,
            .last_command_tool = tool,
            .last_command_result = result,
        };
        written += 1;
    }
    return out;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'listSnapshot|FAIL|error:'`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/extension_ws/hub.zig
git commit -m "$(cat <<'EOF'
feat(extension_ws): S4 — ExtensionWsHub.listSnapshot for diagnostic routes

Adds ExtensionState struct + listSnapshot(allocator) on ExtensionWsHub.
Returns a caller-owned slice of per-user (user_id, connected_at,
last_command_*) snapshots so gateway diagnostic handlers can render JSON
outside the hub's users_mu critical section. snapshotLastCommand pins
the inner read under the conn's last_command_mu so the snapshot is
internally consistent against concurrent sendCommand.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add canonical lifecycle event log helper

**Files:**
- Modify: `src/extension_ws/hub.zig` — add a private `emitLifecycleEvent` fn, replace the existing ad-hoc `log.info("extension_ws: ...")` calls at the four lifecycle points with the canonical form.

**Rationale:** The spec requires structured logs for pair/disconnect/timeout/command_failed. The current `log.info` lines are useful but their key-value shape varies (some quote `user_id`, some don't; some have an `active=N` suffix). A canonical helper means an operator can grep `extension_ws.event=pair` reliably.

- [ ] **Step 1: Write the failing test**

Append to `src/extension_ws/hub.zig`:

```zig
test "emitLifecycleEvent writes canonical line shape for pair" {
    // We capture the log via a small ArrayList sink. std.log can't be
    // intercepted in tests (the harness routes to stderr), so this
    // test verifies the formatter directly. The helper writes into a
    // caller-provided buffer for the test path only — that buffer
    // path is comptime-gated to `builtin.is_test`.
    var buf: [256]u8 = undefined;
    var sink = std.io.fixedBufferStream(&buf);
    try formatLifecycleEvent(sink.writer(), .pair, .{
        .user_id = "alice",
        .extra_key = "extension_version",
        .extra_val = "0.1.0",
    });
    try std.testing.expect(std.mem.indexOf(u8, sink.getWritten(), "extension_ws.event=pair") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.getWritten(), "user_id='alice'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.getWritten(), "extension_version='0.1.0'") != null);
}

test "formatLifecycleEvent disconnect omits extra_key when null" {
    var buf: [256]u8 = undefined;
    var sink = std.io.fixedBufferStream(&buf);
    try formatLifecycleEvent(sink.writer(), .disconnect, .{
        .user_id = "alice",
        .extra_key = null,
        .extra_val = null,
    });
    const out = sink.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "extension_ws.event=disconnect") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "user_id='alice'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "extension_version=") == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'emitLifecycleEvent|formatLifecycleEvent|error:'`
Expected: compile error — `formatLifecycleEvent` is not declared.

- [ ] **Step 3: Add the helper + the LifecycleEvent enum**

In `src/extension_ws/hub.zig`, near the other private helpers at the bottom of the file (just before `// ── Tests ──` ~line 728), add:

```zig
/// Canonical lifecycle event class. Used by `emitLifecycleEvent` and
/// in tests via `formatLifecycleEvent` to pin the exact log shape
/// operators grep for.
pub const LifecycleEvent = enum {
    pair, // new extension authenticated + registered.
    disconnect, // pump exited (graceful close, eviction, or error).
    timeout, // sendCommand hit its timedWait deadline.
    command_failed, // hub.sendCommand returned a named error class other than no_conn.

    pub fn toString(self: LifecycleEvent) []const u8 {
        return switch (self) {
            .pair => "pair",
            .disconnect => "disconnect",
            .timeout => "timeout",
            .command_failed => "command_failed",
        };
    }
};

const LifecycleEventArgs = struct {
    user_id: []const u8,
    extra_key: ?[]const u8 = null,
    extra_val: ?[]const u8 = null,
};

/// Format one lifecycle log line into `writer`. Exposed for tests; the
/// production helper `emitLifecycleEvent` calls this with the std.log
/// writer.
pub fn formatLifecycleEvent(writer: anytype, ev: LifecycleEvent, args: LifecycleEventArgs) !void {
    try writer.print("extension_ws.event={s} user_id='{s}'", .{ ev.toString(), args.user_id });
    if (args.extra_key) |k| {
        if (args.extra_val) |v| {
            try writer.print(" {s}='{s}'", .{ k, v });
        }
    }
}

/// Production-side emitter: routes the canonical line through std.log.
fn emitLifecycleEvent(ev: LifecycleEvent, args: LifecycleEventArgs) void {
    var buf: [512]u8 = undefined;
    var sink = std.io.fixedBufferStream(&buf);
    formatLifecycleEvent(sink.writer(), ev, args) catch return;
    log.info("{s}", .{sink.getWritten()});
}
```

- [ ] **Step 4: Replace existing ad-hoc lifecycle logs with the canonical helper**

In `src/extension_ws/hub.zig`:

(a) In `registerConn` (~line 553), the line `log.info("extension_ws: connection registered user_id='{s}' active={d}", .{ user_id, self.users.count() });` already exists. Add ONE additional line directly after it:

```zig
emitLifecycleEvent(.pair, .{ .user_id = user_id });
```

Keep the existing `connection registered` line — it carries the `active=N` count which is operator-useful for capacity-watching. The canonical event line is the grep-stable companion.

(b) In `unregister` (~line 591), AFTER the existing `kv.value.evicted.store(...)` line, add:

```zig
emitLifecycleEvent(.disconnect, .{ .user_id = kv.key });
```

(c) In `ExtensionWsHub.sendCommand` (~line 670), inside the `if (err == error.Timeout)` branch, add ONE line directly after the existing `log.info("extension_ws: command timed out ...")`:

```zig
emitLifecycleEvent(.timeout, .{ .user_id = user_id, .extra_key = "tool", .extra_val = tool });
```

(d) Same fn, inside the `catch |err|` block but OUTSIDE the timeout-only branch (so it fires for `conn_closed`, `oom`, `error_other`), add the `command_failed` emission right before `return err;`:

```zig
if (err != error.Timeout) {
    emitLifecycleEvent(.command_failed, .{ .user_id = user_id, .extra_key = "tool", .extra_val = tool });
}
return err;
```

- [ ] **Step 5: Run the tests to verify both helper tests pass**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'emitLifecycleEvent|formatLifecycleEvent|FAIL|error:'`
Expected: both tests PASS.

- [ ] **Step 6: Commit**

```bash
git add src/extension_ws/hub.zig
git commit -m "$(cat <<'EOF'
feat(extension_ws): S4 — canonical extension_ws.event=<class> lifecycle logs

Adds LifecycleEvent enum + formatLifecycleEvent (test-exposed) +
emitLifecycleEvent (std.log writer). Wires emit calls at pair (registerConn),
disconnect (unregister), timeout (sendCommand error.Timeout), and
command_failed (sendCommand non-timeout error). Operators can grep
'extension_ws.event=pair|disconnect|timeout|command_failed' deterministically
for log shipping and incident playbooks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `extensionStatusPayload` + `extensionUserStatusPayload` to gateway

**Files:**
- Modify: `src/gateway.zig` — add the two helpers + a small `ExtensionDiagnosticInput` struct next to `metricsPayload` (~line 6653).
- Test: inline in `src/gateway.zig` (per existing pattern).

**Rationale:** The two new diagnostic routes need JSON renderers. We keep them as **pure** fns that take a minimal `ExtensionDiagnosticInput` rather than a `*const GatewayState`. This is important because `GatewayState` has many non-default fields (rate_limiter, idempotency, whatsapp_*, telegram_bot_token, user_preparation_gate, app_event_subscribers, …) that cannot be constructed in a unit test without dragging the full boot path in. The route arm in Task 6 builds the input from `state` in one place; the helpers stay testable.

`extension_ws_hub` is already imported into gateway.zig at line 82 as the local alias `extension_ws_hub`; tests use that alias rather than re-importing.

- [ ] **Step 1: Write the failing tests**

Append at the bottom of `src/gateway.zig`, just before the closing block — find the last existing `test "..." {` block and add these after it:

```zig
test "extensionStatusPayload renders disabled when hub is null" {
    const input: ExtensionDiagnosticInput = .{
        .hub = null,
        .connections_total = 0,
        .auth_failed_total = 0,
    };
    const json = try extensionStatusPayload(std.testing.allocator, input);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_active\":0") != null);
}

test "extensionStatusPayload renders enabled + counters when hub is present" {
    var hub = extension_ws_hub.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    const input: ExtensionDiagnosticInput = .{
        .hub = &hub,
        .connections_total = 3,
        .auth_failed_total = 1,
    };
    const json = try extensionStatusPayload(std.testing.allocator, input);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_active\":0") != null); // no paired users
    try std.testing.expect(std.mem.indexOf(u8, json, "\"connections_total\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"auth_failed_total\":1") != null);
}

test "extensionUserStatusPayload renders not_paired when user has no conn" {
    var hub = extension_ws_hub.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    const input: ExtensionDiagnosticInput = .{
        .hub = &hub,
        .connections_total = 0,
        .auth_failed_total = 0,
    };
    const json = try extensionUserStatusPayload(std.testing.allocator, input, "alice");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"user_id\":\"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"paired\":false") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'ExtensionDiagnosticInput|extensionStatusPayload|extensionUserStatusPayload|error: no member|FAIL'`
Expected: compile error — neither helper nor the input struct is declared.

- [ ] **Step 3: Add the input struct + two helpers**

In `src/gateway.zig`, immediately above the existing `fn metricsPayload(...)` (~line 6653), insert:

```zig
/// Minimal input for the extension-WS diagnostic payload renderers.
/// Carved off `GatewayState` so the renderers are unit-testable without
/// constructing the full gateway state struct (which has many non-default
/// fields wired during boot).
pub const ExtensionDiagnosticInput = struct {
    hub: ?*extension_ws_hub.ExtensionWsHub,
    connections_total: u64,
    auth_failed_total: u64,
};

/// Render the system-wide extension WS diagnostic JSON. Keys:
///   - enabled: bool — true iff `input.hub` is non-null.
///   - total_active: number of currently-paired users (live count from the hub).
///   - connections_total: lifetime connections accepted.
///   - auth_failed_total: lifetime auth_failed outcomes.
///
/// Returned slice is heap-allocated; caller frees via `allocator.free`.
pub fn extensionStatusPayload(allocator: std.mem.Allocator, input: ExtensionDiagnosticInput) ![]u8 {
    const enabled = input.hub != null;
    const total_active: usize = if (input.hub) |hub| blk: {
        hub.users_mu.lock();
        defer hub.users_mu.unlock();
        break :blk hub.users.count();
    } else 0;

    return std.fmt.allocPrint(
        allocator,
        "{{\"enabled\":{s},\"total_active\":{d},\"connections_total\":{d},\"auth_failed_total\":{d}}}",
        .{
            if (enabled) "true" else "false",
            total_active,
            input.connections_total,
            input.auth_failed_total,
        },
    );
}

/// Render the per-user extension WS diagnostic JSON. Keys:
///   - user_id: echo of the requested user_id.
///   - paired: bool — true iff this user has a live extension conn.
///   - connected_at_unix: i64 (seconds since epoch), 0 when not paired.
///   - last_command_at_unix: i64 (seconds), 0 when no command yet.
///   - last_command_tool: string ("" when no command yet).
///   - last_command_result: string ("" when no command yet).
pub fn extensionUserStatusPayload(allocator: std.mem.Allocator, input: ExtensionDiagnosticInput, user_id: []const u8) ![]u8 {
    var paired = false;
    var connected_at_unix: i64 = 0;
    var last_at_unix: i64 = 0;
    var last_tool: []const u8 = "";
    var last_result: []const u8 = "";

    var tool_buf: [32]u8 = undefined;
    var result_buf: [32]u8 = undefined;

    if (input.hub) |hub| {
        if (hub.getForUser(user_id)) |conn| {
            defer _ = conn.release();
            paired = true;
            const ns = conn.connected_at_ns.load(.acquire);
            connected_at_unix = @intCast(@divTrunc(ns, std.time.ns_per_s));
            const last = conn.snapshotLastCommand(&tool_buf, &result_buf);
            if (last.at_ns > 0) {
                last_at_unix = @intCast(@divTrunc(last.at_ns, std.time.ns_per_s));
            }
            last_tool = tool_buf[0..last.tool_len];
            last_result = result_buf[0..last.result_len];
        }
    }

    return std.fmt.allocPrint(
        allocator,
        "{{\"user_id\":\"{s}\",\"paired\":{s},\"connected_at_unix\":{d},\"last_command_at_unix\":{d},\"last_command_tool\":\"{s}\",\"last_command_result\":\"{s}\"}}",
        .{
            user_id,
            if (paired) "true" else "false",
            connected_at_unix,
            last_at_unix,
            last_tool,
            last_result,
        },
    );
}
```

Both helpers are `pub fn` so the standalone test under `tests/extension/diagnostics_test.zig` (Task 10) can call them through `nullalis.gateway`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'extensionStatusPayload|extensionUserStatusPayload|FAIL|error:'`
Expected: all three tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/gateway.zig
git commit -m "$(cat <<'EOF'
feat(gateway): S4 — extensionStatusPayload + extensionUserStatusPayload helpers

Two pure JSON renderers for the upcoming /api/v1/diagnostics/extension/*
routes. extensionStatusPayload returns system-wide hub state; extensionUserStatusPayload
returns per-user pair + last_command snapshot. Both safe to call when the
hub is null (renders enabled=false / paired=false).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire the two new `/api/v1/diagnostics/extension/*` routes

**Files:**
- Modify: `src/gateway.zig` — add a route arm in the public-API dispatch (search for the cluster of `/api/v1/users/...` route matches; the artifact-export bridge added similar entries near line 17358).
- Test: inline in `src/gateway.zig`.

**Auth model:**
- `/api/v1/diagnostics/extension/status` — internal-token gated (same as `/internal/diagnostics`). Operator-only system view.
- `/api/v1/diagnostics/extension/users/{user_id}` — internal-token OR `X-Zaki-User-Id == {user_id}` (self-only). Mirrors the existing pattern that lets a user inspect their own state.

- [ ] **Step 1: Write the failing tests**

Append to `src/gateway.zig`. Note: `GatewayState` cannot be anonymous-struct constructed in tests (many non-default fields like `whatsapp_*`, `telegram_bot_token`, `user_preparation_gate`, `rate_limiter`), so we test the auth predicates with the smallest existing helper that already accepts a token slice — `validateInternalServiceTokenWithPolicy(raw, tokens, auth_required)` — which is the underlying impl of `validateInternalServiceToken`:

```zig
test "extension diagnostics status route requires internal token" {
    // No token configured, auth_required = true → reject.
    const no_auth_raw = "GET /api/v1/diagnostics/extension/status HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const allowed = validateInternalServiceTokenWithPolicy(no_auth_raw, &.{}, true);
    try std.testing.expect(!allowed);
}

test "extension diagnostics status route accepts valid internal token" {
    const tokens = [_][]const u8{"prod-internal-1234"};
    const auth_raw = "GET /api/v1/diagnostics/extension/status HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: prod-internal-1234\r\n\r\n";
    const allowed = validateInternalServiceTokenWithPolicy(auth_raw, &tokens, true);
    try std.testing.expect(allowed);
}

test "extension diagnostics per-user route allows self when X-Zaki-User-Id matches" {
    // The self-only branch is a separate predicate; this test pins it.
    const matches = extensionUserDiagnosticsSelfAllowed("alice", "alice");
    try std.testing.expect(matches);
    const mismatch = extensionUserDiagnosticsSelfAllowed("alice", "bob");
    try std.testing.expect(!mismatch);
    const missing = extensionUserDiagnosticsSelfAllowed(null, "alice");
    try std.testing.expect(!missing);
    const empty = extensionUserDiagnosticsSelfAllowed("", "alice");
    try std.testing.expect(!empty);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'extensionUserDiagnosticsSelfAllowed|extension diagnostics|FAIL|error:'`
Expected: compile error for the unknown helper; the other two should still fail since the predicate isn't declared.

Note: `validateInternalServiceTokenWithPolicy` is already declared at `src/gateway.zig:3494` and is package-private. If it isn't accessible from the test position you choose, hoist it to `pub fn` — this is a minor surface widening that doesn't change behavior.

- [ ] **Step 3: Add the self-allowed predicate**

In `src/gateway.zig`, near `validateInternalServiceToken` (~line 3509), add:

```zig
/// Predicate used by `/api/v1/diagnostics/extension/users/{user_id}` to
/// allow a request through when the inbound `X-Zaki-User-Id` matches
/// the path parameter — the user inspecting their own extension state.
///
/// `hdr_user_id` is whatever the gateway extracted from the
/// `X-Zaki-User-Id` header (may be null when not present).
fn extensionUserDiagnosticsSelfAllowed(hdr_user_id: ?[]const u8, path_user_id: []const u8) bool {
    const hu = hdr_user_id orelse return false;
    if (hu.len == 0) return false;
    return std.mem.eql(u8, hu, path_user_id);
}
```

- [ ] **Step 4: Wire the two route arms**

In `src/gateway.zig`, locate where the public ZAKI dispatcher chains `/api/v1/users/...` paths (search for `std.mem.startsWith(u8, base_path, "/api/v1/users/")` near the artifact-export bridge dispatch). Add a sibling arm BEFORE that block (so the diagnostic paths take precedence over the more-general `/api/v1/users/` pattern when paths share a prefix):

```zig
// S4 (Sprint 4) — extension control-plane diagnostics.
if (std.mem.eql(u8, base_path, "/api/v1/diagnostics/extension/status")) {
    if (!std.mem.eql(u8, method_str, "GET")) {
        sendHttpResponse(conn.stream, "405 Method Not Allowed", "application/json", "{\"error\":\"method_not_allowed\"}") catch {};
        return;
    }
    if (!validateInternalServiceToken(raw, state)) {
        sendHttpResponse(conn.stream, "401 Unauthorized", "application/json", "{\"error\":\"unauthorized\"}") catch {};
        return;
    }
    const input: ExtensionDiagnosticInput = .{
        .hub = state.extension_ws_hub,
        .connections_total = state.extension_ws_total.load(.monotonic),
        .auth_failed_total = state.extension_ws_auth_failed_total.load(.monotonic),
    };
    const body = extensionStatusPayload(req_allocator, input) catch "{\"error\":\"render_failed\"}";
    sendHttpResponse(conn.stream, "200 OK", "application/json", body) catch {};
    return;
}
if (std.mem.startsWith(u8, base_path, "/api/v1/diagnostics/extension/users/")) {
    if (!std.mem.eql(u8, method_str, "GET")) {
        sendHttpResponse(conn.stream, "405 Method Not Allowed", "application/json", "{\"error\":\"method_not_allowed\"}") catch {};
        return;
    }
    const path_user_id = base_path["/api/v1/diagnostics/extension/users/".len..];
    if (path_user_id.len == 0 or std.mem.indexOfScalar(u8, path_user_id, '/') != null) {
        sendHttpResponse(conn.stream, "400 Bad Request", "application/json", "{\"error\":\"invalid_user_id\"}") catch {};
        return;
    }
    const hdr_uid = extractHeader(raw, "X-Zaki-User-Id");
    const internal_ok = validateInternalServiceToken(raw, state);
    const self_ok = extensionUserDiagnosticsSelfAllowed(hdr_uid, path_user_id);
    if (!internal_ok and !self_ok) {
        sendHttpResponse(conn.stream, "401 Unauthorized", "application/json", "{\"error\":\"unauthorized\"}") catch {};
        return;
    }
    const input: ExtensionDiagnosticInput = .{
        .hub = state.extension_ws_hub,
        .connections_total = state.extension_ws_total.load(.monotonic),
        .auth_failed_total = state.extension_ws_auth_failed_total.load(.monotonic),
    };
    const body = extensionUserStatusPayload(req_allocator, input, path_user_id) catch "{\"error\":\"render_failed\"}";
    sendHttpResponse(conn.stream, "200 OK", "application/json", body) catch {};
    return;
}
```

- [ ] **Step 5: Run the tests + a smoke build**

Run: `zig build -Dengines=base,sqlite,postgres 2>&1 | tail -20`
Expected: build succeeds.

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'extension diagnostics|extensionUserDiagnosticsSelfAllowed|FAIL'`
Expected: all 3 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add src/gateway.zig
git commit -m "$(cat <<'EOF'
feat(gateway): S4 — /api/v1/diagnostics/extension/{status,users/:uid} routes

Two new control-plane diagnostic routes returning the JSON shapes
documented in docs/extension-ws-contract.md. /status is internal-token
gated (operator view). /users/{uid} is internal-token OR self-only via
X-Zaki-User-Id matching — same precedence pattern as the existing
canonical user-scoped routes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Wire new test files into `build.zig`

**Files:**
- Modify: `build.zig` — add three `addTest` blocks next to `security_sandbox_tests` (~line 490).

**Rationale:** The new test files don't exist yet (Tasks 8-10 create them), but the build wiring is independent and benefits from landing first so each test-creation task can land with a passing `zig build test` on its own.

- [ ] **Step 1: Add the three test artifacts**

In `build.zig`, immediately after the existing `task_lifecycle_tests` block (~line 582), insert:

```zig
// Sprint S4 — extension browser readiness tests. Live outside src/
// because they pin cross-module contracts (hub × tools × gateway diagnostic
// route shapes). Each runs under every engine profile; no postgres or
// sqlite dependency.
const extension_isolation_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/extension/cross_user_isolation_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nullalis", .module = lib_mod },
        },
    }),
});
if (sqlite3) |lib| extension_isolation_tests.linkLibrary(lib);
if (enable_postgres) {
    addHomebrewLibpqPaths(extension_isolation_tests);
    addHomebrewLibpqPaths(extension_isolation_tests.root_module);
    extension_isolation_tests.root_module.linkSystemLibrary("pq", .{});
}

const extension_mock_e2e_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/extension/mock_hub_e2e_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nullalis", .module = lib_mod },
        },
    }),
});
if (sqlite3) |lib| extension_mock_e2e_tests.linkLibrary(lib);
if (enable_postgres) {
    addHomebrewLibpqPaths(extension_mock_e2e_tests);
    addHomebrewLibpqPaths(extension_mock_e2e_tests.root_module);
    extension_mock_e2e_tests.root_module.linkSystemLibrary("pq", .{});
}

const extension_diagnostics_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/extension/diagnostics_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nullalis", .module = lib_mod },
        },
    }),
});
if (sqlite3) |lib| extension_diagnostics_tests.linkLibrary(lib);
if (enable_postgres) {
    addHomebrewLibpqPaths(extension_diagnostics_tests);
    addHomebrewLibpqPaths(extension_diagnostics_tests.root_module);
    extension_diagnostics_tests.root_module.linkSystemLibrary("pq", .{});
}
```

In the `test_step` block at line 584, immediately after the existing `test_step.dependOn(&b.addRunArtifact(task_lifecycle_tests).step);` line (~line 589), add:

```zig
test_step.dependOn(&b.addRunArtifact(extension_isolation_tests).step);
test_step.dependOn(&b.addRunArtifact(extension_mock_e2e_tests).step);
test_step.dependOn(&b.addRunArtifact(extension_diagnostics_tests).step);
```

- [ ] **Step 2: Create empty placeholder test files (so build wiring compiles)**

```bash
mkdir -p tests/extension
```

Then write three minimal placeholder files. These will be replaced in Tasks 8-10.

`tests/extension/cross_user_isolation_test.zig`:
```zig
const std = @import("std");
test "placeholder — replaced in Task 8" {
    try std.testing.expect(true);
}
```

`tests/extension/mock_hub_e2e_test.zig`:
```zig
const std = @import("std");
test "placeholder — replaced in Task 9" {
    try std.testing.expect(true);
}
```

`tests/extension/diagnostics_test.zig`:
```zig
const std = @import("std");
test "placeholder — replaced in Task 10" {
    try std.testing.expect(true);
}
```

- [ ] **Step 3: Verify build + tests pass with placeholders**

Run: `zig build -Dengines=base,sqlite,postgres 2>&1 | tail -10`
Expected: build succeeds.

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'placeholder|FAIL|error:'`
Expected: 3 placeholder tests PASS.

- [ ] **Step 4: Commit**

```bash
git add build.zig tests/extension/
git commit -m "$(cat <<'EOF'
build(extension): S4 — wire tests/extension/*.zig artifacts into test step

Three new addTest blocks alongside the existing security_sandbox_tests
pattern: cross_user_isolation_test, mock_hub_e2e_test, diagnostics_test.
Placeholder bodies land first so each subsequent test-authoring task
can verify its file compiles and runs in isolation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Cross-user isolation test

**Files:**
- Modify: `tests/extension/cross_user_isolation_test.zig` (replace placeholder).

**Rationale:** META CRIT #2 already pinned that the auth frame's `user_id` is ignored. This test goes further: with two paired users A and B, the hub's `sendCommand("alice", ...)` writes ONLY to alice's socket, and the auth validator returns the MAPPED user_id even when the inbound frame field tries to spoof another user. Pins the full chain.

- [ ] **Step 1: Replace the placeholder with the isolation test**

Write `tests/extension/cross_user_isolation_test.zig`:

```zig
//! Sprint S4 — cross-user isolation test for the extension WS surface.
//!
//! Pins:
//!   1. Two paired users (alice, bob) each have their own conn.
//!   2. hub.sendCommand("alice", ...) writes to alice's socket only —
//!      bob's socket receives nothing.
//!   3. The auth validator ignores the frame's `user_id` and returns
//!      the mapped server-side user_id — token theft alone cannot
//!      cross-impersonate.
//!
//! These contracts are already individually tested inline in auth.zig
//! and hub.zig. This file is the SYSTEM-LEVEL pin: a regression in
//! either layer that leaked across users would fail here even if the
//! per-module tests were untouched.

const std = @import("std");
const nullalis = @import("nullalis");
const hub_mod = nullalis.extension_ws.hub;
const auth_mod = nullalis.extension_ws.auth;

const RecordingStream = struct {
    allocator: std.mem.Allocator,
    writes: std.ArrayListUnmanaged([]u8) = .empty,
    closed: bool = false,

    pub fn writeText(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *RecordingStream = @ptrCast(@alignCast(ctx));
        const copy = try self.allocator.dupe(u8, text);
        try self.writes.append(self.allocator, copy);
    }
    pub fn close(ctx: *anyopaque) void {
        const self: *RecordingStream = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
    pub fn deinit(self: *RecordingStream) void {
        for (self.writes.items) |w| self.allocator.free(w);
        self.writes.deinit(self.allocator);
    }
    pub fn writeCount(self: *RecordingStream) usize {
        return self.writes.items.len;
    }
};

test "isolation: hub.sendCommand for alice writes to alice's socket only" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var alice_stream = RecordingStream{ .allocator = std.testing.allocator };
    defer alice_stream.deinit();
    var bob_stream = RecordingStream{ .allocator = std.testing.allocator };
    defer bob_stream.deinit();

    const conn_a = try hub.registerConn("alice", @ptrCast(&alice_stream), RecordingStream.writeText, @ptrCast(&alice_stream), RecordingStream.close);
    defer hub.destroyConn(conn_a);
    const conn_b = try hub.registerConn("bob", @ptrCast(&bob_stream), RecordingStream.writeText, @ptrCast(&bob_stream), RecordingStream.close);
    defer hub.destroyConn(conn_b);

    // Spawn a deliverer that responds to whichever command alice's
    // socket received (parse command_id, echo it back via deliverResult).
    const DelivererCtx = struct {
        c: *hub_mod.ExtensionWsConn,
        stream: *RecordingStream,
        fn run(ctx: @This()) void {
            // Spin until alice's socket has at least one write.
            var attempts: usize = 0;
            while (attempts < 1000 and ctx.stream.writeCount() == 0) : (attempts += 1) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            if (ctx.stream.writeCount() == 0) return;
            const frame = ctx.stream.writes.items[0];
            // Parse `command_id` from the JSON.
            const needle = "\"command_id\":\"";
            const start_idx = std.mem.indexOf(u8, frame, needle) orelse return;
            const after = start_idx + needle.len;
            const end_idx = std.mem.indexOfScalarPos(u8, frame, after, '"') orelse return;
            const cmd_id = frame[after..end_idx];
            var reply_buf: [256]u8 = undefined;
            const reply = std.fmt.bufPrint(&reply_buf, "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{}}}}", .{cmd_id}) catch return;
            ctx.c.deliverResult(reply) catch {};
        }
    };
    var thread = try std.Thread.spawn(.{}, DelivererCtx.run, .{DelivererCtx{ .c = conn_a, .stream = &alice_stream }});
    defer thread.join();

    const result = try hub.sendCommand(std.testing.allocator, "alice", "navigate", "{\"url\":\"https://x\"}", 500);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), alice_stream.writeCount());
    try std.testing.expectEqual(@as(usize, 0), bob_stream.writeCount());
    try std.testing.expect(!bob_stream.closed);
}

test "isolation: hub.sendCommand for unregistered user returns NoExtensionConnected and writes nothing" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var alice_stream = RecordingStream{ .allocator = std.testing.allocator };
    defer alice_stream.deinit();
    const conn_a = try hub.registerConn("alice", @ptrCast(&alice_stream), RecordingStream.writeText, @ptrCast(&alice_stream), RecordingStream.close);
    defer hub.destroyConn(conn_a);

    const result = hub.sendCommand(std.testing.allocator, "carol", "click", "{}", 50);
    try std.testing.expectError(error.NoExtensionConnected, result);
    try std.testing.expectEqual(@as(usize, 0), alice_stream.writeCount());
}

test "isolation: auth validator ignores inbound user_id even with valid token (re-pinned at system level)" {
    const entries = [_]auth_mod.TokenEntry{
        .{ .token = "tok-alice", .user_id = "alice" },
        .{ .token = "tok-bob", .user_id = "bob" },
    };
    const v = auth_mod.AuthValidator{ .entries = &entries };
    // Holder of alice's token claims to be bob.
    const auth = "{\"type\":\"auth\",\"token\":\"tok-alice\",\"user_id\":\"bob\"}";
    const d = v.validate(auth);
    try std.testing.expect(d.ok);
    try std.testing.expectEqualStrings("alice", d.user_id.?);
    // The wrong user_id (bob) is NEVER returned.
    try std.testing.expect(!std.mem.eql(u8, d.user_id.?, "bob"));
}

test "isolation: empty entries list rejects every token (closed by default)" {
    const v = auth_mod.AuthValidator{ .entries = &.{} };
    const auth = "{\"type\":\"auth\",\"token\":\"any\",\"user_id\":\"alice\"}";
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("invalid_token", d.reason.?);
}
```

- [ ] **Step 2: Verify the lib_mod exports the needed sub-modules**

Run: `grep -nE 'pub const extension_ws' src/root.zig`

Expected: a `pub const extension_ws = struct { pub const server = ...; pub const hub = ...; pub const auth = ...; };` block already exists. No changes needed in `src/root.zig`.

- [ ] **Step 3: Run the test**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'isolation:|FAIL|error:'`
Expected: all 4 isolation tests PASS; no FAIL.

- [ ] **Step 4: Commit**

```bash
git add tests/extension/cross_user_isolation_test.zig
git commit -m "$(cat <<'EOF'
test(extension): S4 — cross-user isolation system test

Pins three layered invariants:
- hub.sendCommand for alice writes to alice's socket only; bob's socket
  receives nothing and stays open.
- hub.sendCommand for an unregistered user returns NoExtensionConnected
  and leaves every existing conn untouched.
- The auth validator returns the SERVER-mapped user_id even when the
  inbound auth frame claims a different user_id (META CRIT #2 re-pin
  at the system test level).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Mock-hub E2E covering all ten `extension_*` tools

**Files:**
- Modify: `tests/extension/mock_hub_e2e_test.zig` (replace placeholder).

**Rationale:** Each extension tool already has its own happy-path + error-path inline tests. This file is the cross-tool pin: a single test loop that exercises every shipped tool against a structurally equivalent mock hub conn, asserting the user-safe failure-state taxonomy on each named branch.

- [ ] **Step 1: Replace the placeholder**

Write `tests/extension/mock_hub_e2e_test.zig`:

```zig
//! Sprint S4 — end-to-end coverage across every shipped extension_* tool.
//!
//! For each of the ten tools we exercise five paths:
//!   1. happy path (mock conn replies ok:true) → ToolResult.success=true.
//!   2. no_extension_connected → ToolResult.success=false, error_msg
//!      contains "no extension connected".
//!   3. timeout → ToolResult.success=false, error_msg contains "timeout".
//!   4. disconnect mid-command → ToolResult.success=false, error_msg
//!      contains "extension connection closed".
//!   5. extension-reported error (`ok:false` from the mock) →
//!      ToolResult.success=false, error_msg contains "extension reported error".
//!
//! Cross-tool pin: a regression where any tool stops surfacing one of
//! these named states would fail here even if the per-tool inline tests
//! are still passing.

const std = @import("std");
const nullalis = @import("nullalis");
const hub_mod = nullalis.extension_ws.hub;
const root = nullalis.tools;

const RecordingStream = struct {
    allocator: std.mem.Allocator,
    writes: std.ArrayListUnmanaged([]u8) = .empty,
    pub fn writeText(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *RecordingStream = @ptrCast(@alignCast(ctx));
        const copy = try self.allocator.dupe(u8, text);
        try self.writes.append(self.allocator, copy);
    }
    pub fn close(_: *anyopaque) void {}
    pub fn deinit(self: *RecordingStream) void {
        for (self.writes.items) |w| self.allocator.free(w);
        self.writes.deinit(self.allocator);
    }
};

fn extractCommandId(frame: []const u8) ?[]const u8 {
    const needle = "\"command_id\":\"";
    const start_idx = std.mem.indexOf(u8, frame, needle) orelse return null;
    const after = start_idx + needle.len;
    const end_idx = std.mem.indexOfScalarPos(u8, frame, after, '"') orelse return null;
    return frame[after..end_idx];
}

fn deliverOk(conn: *hub_mod.ExtensionWsConn, stream: *RecordingStream, result_json_body: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 1000 and stream.writes.items.len == 0) : (attempts += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    if (stream.writes.items.len == 0) return error.NoFrame;
    const cmd_id = extractCommandId(stream.writes.items[0]) orelse return error.NoCommandId;
    var buf: [4096]u8 = undefined;
    const reply = try std.fmt.bufPrint(&buf, "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{s}}}", .{ cmd_id, result_json_body });
    try conn.deliverResult(reply);
}

fn deliverErr(conn: *hub_mod.ExtensionWsConn, stream: *RecordingStream, code: []const u8, message: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 1000 and stream.writes.items.len == 0) : (attempts += 1) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    if (stream.writes.items.len == 0) return error.NoFrame;
    const cmd_id = extractCommandId(stream.writes.items[0]) orelse return error.NoCommandId;
    var buf: [4096]u8 = undefined;
    const reply = try std.fmt.bufPrint(&buf, "{{\"command_id\":\"{s}\",\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ cmd_id, code, message });
    try conn.deliverResult(reply);
}

const ToolHarness = struct {
    name: []const u8,
    /// JSON args that survive every per-tool schema check (so we
    /// reach the hub dispatch). The args validity is irrelevant to
    /// the no_conn / timeout / disconnect paths; relevant only to
    /// the happy-path call where the tool round-trips the args
    /// through the mock.
    args_json: []const u8,
    /// `result` body for the happy-path mock reply.
    happy_result_body: []const u8,
};

const TOOL_HARNESSES = [_]ToolHarness{
    .{ .name = "extension_navigate", .args_json = "{\"url\":\"https://example.com\"}", .happy_result_body = "{\"loaded\":true}" },
    .{ .name = "extension_click", .args_json = "{\"selector\":\"#x\"}", .happy_result_body = "{\"clicked\":true}" },
    .{ .name = "extension_type", .args_json = "{\"selector\":\"#x\",\"text\":\"hi\"}", .happy_result_body = "{\"typed\":true}" },
    .{ .name = "extension_fill_form", .args_json = "{\"fields\":[{\"selector\":\"#a\",\"value\":\"v\"}]}", .happy_result_body = "{\"filled\":1}" },
    .{ .name = "extension_screenshot", .args_json = "{}", .happy_result_body = "{\"png_b64\":\"AAA\"}" },
    .{ .name = "extension_get_text", .args_json = "{\"selector\":\"body\"}", .happy_result_body = "{\"text\":\"hi\"}" },
    .{ .name = "extension_get_dom", .args_json = "{}", .happy_result_body = "{\"html\":\"<p/>\"}" },
    .{ .name = "extension_wait_for", .args_json = "{\"selector\":\"#x\"}", .happy_result_body = "{\"found\":true}" },
    .{ .name = "extension_scroll", .args_json = "{\"y\":100}", .happy_result_body = "{\"scrolled\":true}" },
    .{ .name = "extension_list_tabs", .args_json = "{}", .happy_result_body = "{\"tabs\":[]}" },
};

fn findTool(tools: []const root.Tool, name: []const u8) ?root.Tool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name(), name)) return t;
    }
    return null;
}

test "E2E: every extension_* tool surfaces no_extension_connected when nothing paired" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    const tools = try root.allTools(std.testing.allocator, "/tmp", .{
        .extension_ws_hub = &hub,
    });
    defer root.deinitTools(std.testing.allocator, tools);
    root.bindExtensionTools(tools, "alice");

    for (TOOL_HARNESSES) |h| {
        const t = findTool(tools, h.name) orelse {
            std.debug.print("missing tool {s}\n", .{h.name});
            try std.testing.expect(false);
            continue;
        };
        const parsed = try root.parseTestArgs(h.args_json);
        defer parsed.deinit();
        const result = try t.execute(std.testing.allocator, parsed.value.object);
        defer if (result.error_msg) |m| std.testing.allocator.free(m);
        defer if (result.output.len > 0) std.testing.allocator.free(result.output);
        try std.testing.expect(!result.success);
        try std.testing.expect(result.error_msg != null);
        if (std.mem.indexOf(u8, result.error_msg.?, "no extension connected") == null) {
            std.debug.print("{s} error_msg='{s}'\n", .{ h.name, result.error_msg.? });
            try std.testing.expect(false);
        }
    }
}

test "E2E: every extension_* tool happy-path returns success when mock replies ok:true" {
    for (TOOL_HARNESSES) |h| {
        var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
        defer hub.deinit();
        var stream = RecordingStream{ .allocator = std.testing.allocator };
        defer stream.deinit();
        const conn = try hub.registerConn("alice", @ptrCast(&stream), RecordingStream.writeText, @ptrCast(&stream), RecordingStream.close);
        defer hub.destroyConn(conn);

        const tools = try root.allTools(std.testing.allocator, "/tmp", .{
            .extension_ws_hub = &hub,
        });
        defer root.deinitTools(std.testing.allocator, tools);
        root.bindExtensionTools(tools, "alice");

        const DelivererCtx = struct {
            c: *hub_mod.ExtensionWsConn,
            s: *RecordingStream,
            body: []const u8,
            fn run(ctx: @This()) void {
                deliverOk(ctx.c, ctx.s, ctx.body) catch {};
            }
        };
        var thread = try std.Thread.spawn(.{}, DelivererCtx.run, .{DelivererCtx{ .c = conn, .s = &stream, .body = h.happy_result_body }});
        defer thread.join();

        const t = findTool(tools, h.name) orelse continue;
        const parsed = try root.parseTestArgs(h.args_json);
        defer parsed.deinit();
        const result = try t.execute(std.testing.allocator, parsed.value.object);
        defer if (result.error_msg) |m| std.testing.allocator.free(m);
        defer if (result.output.len > 0) std.testing.allocator.free(result.output);
        if (!result.success) {
            std.debug.print("{s} unexpected fail error_msg={?s}\n", .{ h.name, result.error_msg });
            try std.testing.expect(false);
        }
    }
}

test "E2E: every extension_* tool surfaces timeout when mock never replies" {
    for (TOOL_HARNESSES) |h| {
        var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
        defer hub.deinit();
        var stream = RecordingStream{ .allocator = std.testing.allocator };
        defer stream.deinit();
        const conn = try hub.registerConn("alice", @ptrCast(&stream), RecordingStream.writeText, @ptrCast(&stream), RecordingStream.close);
        defer hub.destroyConn(conn);

        const tools = try root.allTools(std.testing.allocator, "/tmp", .{
            .extension_ws_hub = &hub,
        });
        defer root.deinitTools(std.testing.allocator, tools);
        root.bindExtensionTools(tools, "alice");

        // Bind a tiny timeout via the per-tool struct so the test runs
        // fast. Each tool exposes a `timeout_ms` field on its struct;
        // we set it via a small helper.
        setTinyTimeout(tools, h.name);

        const t = findTool(tools, h.name) orelse continue;
        const parsed = try root.parseTestArgs(h.args_json);
        defer parsed.deinit();
        const result = try t.execute(std.testing.allocator, parsed.value.object);
        defer if (result.error_msg) |m| std.testing.allocator.free(m);
        defer if (result.output.len > 0) std.testing.allocator.free(result.output);
        try std.testing.expect(!result.success);
        try std.testing.expect(result.error_msg != null);
        if (std.mem.indexOf(u8, result.error_msg.?, "timeout") == null and
            std.mem.indexOf(u8, result.error_msg.?, "did not respond") == null) {
            std.debug.print("{s} timeout msg='{s}'\n", .{ h.name, result.error_msg.? });
            try std.testing.expect(false);
        }
    }
}

test "E2E: every extension_* tool surfaces ok:false error frame as named failure" {
    for (TOOL_HARNESSES) |h| {
        var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
        defer hub.deinit();
        var stream = RecordingStream{ .allocator = std.testing.allocator };
        defer stream.deinit();
        const conn = try hub.registerConn("alice", @ptrCast(&stream), RecordingStream.writeText, @ptrCast(&stream), RecordingStream.close);
        defer hub.destroyConn(conn);

        const tools = try root.allTools(std.testing.allocator, "/tmp", .{
            .extension_ws_hub = &hub,
        });
        defer root.deinitTools(std.testing.allocator, tools);
        root.bindExtensionTools(tools, "alice");

        const DelivererCtx = struct {
            c: *hub_mod.ExtensionWsConn,
            s: *RecordingStream,
            fn run(ctx: @This()) void {
                deliverErr(ctx.c, ctx.s, "denied", "user blocked the action") catch {};
            }
        };
        var thread = try std.Thread.spawn(.{}, DelivererCtx.run, .{DelivererCtx{ .c = conn, .s = &stream }});
        defer thread.join();

        const t = findTool(tools, h.name) orelse continue;
        const parsed = try root.parseTestArgs(h.args_json);
        defer parsed.deinit();
        const result = try t.execute(std.testing.allocator, parsed.value.object);
        defer if (result.error_msg) |m| std.testing.allocator.free(m);
        defer if (result.output.len > 0) std.testing.allocator.free(result.output);
        try std.testing.expect(!result.success);
        try std.testing.expect(result.error_msg != null);
        if (std.mem.indexOf(u8, result.error_msg.?, "extension reported error") == null) {
            std.debug.print("{s} denied msg='{s}'\n", .{ h.name, result.error_msg.? });
            try std.testing.expect(false);
        }
    }
}

/// Mutate each extension_* tool's `timeout_ms` field to a small value
/// so the timeout-path test doesn't sleep for the 30 s default. Walks
/// the same tool family bindExtensionTools knows about.
fn setTinyTimeout(tools: []const root.Tool, name: []const u8) void {
    const tiny: u64 = 30;
    inline for (.{
        .{ "extension_navigate", root.extension_navigate.ExtensionNavigateTool },
        .{ "extension_click", root.extension_click.ExtensionClickTool },
        .{ "extension_type", root.extension_type.ExtensionTypeTool },
        .{ "extension_fill_form", root.extension_fill_form.ExtensionFillFormTool },
        .{ "extension_screenshot", root.extension_screenshot.ExtensionScreenshotTool },
        .{ "extension_get_text", root.extension_get_text.ExtensionGetTextTool },
        .{ "extension_get_dom", root.extension_get_dom.ExtensionGetDomTool },
        .{ "extension_wait_for", root.extension_wait_for.ExtensionWaitForTool },
        .{ "extension_scroll", root.extension_scroll.ExtensionScrollTool },
        .{ "extension_list_tabs", root.extension_list_tabs.ExtensionListTabsTool },
    }) |pair| {
        if (std.mem.eql(u8, name, pair[0])) {
            for (tools) |t| {
                if (std.mem.eql(u8, t.name(), name)) {
                    const ent: *pair[1] = @ptrCast(@alignCast(t.ptr));
                    ent.timeout_ms = tiny;
                    return;
                }
            }
        }
    }
}
```

- [ ] **Step 2: Verify the existing exports cover everything we need**

Run: `grep -nE 'pub const tools\b|pub const extension_navigate|pub const extension_click' src/root.zig src/tools/root.zig`

Expected: `src/root.zig` exports `pub const tools = @import("tools/root.zig");`, and `src/tools/root.zig` already exports each extension tool as `pub const extension_navigate = @import("extension_navigate.zig");` (verified during plan-write at lines 168-177). No changes needed in `src/root.zig` or `src/tools/root.zig`.

- [ ] **Step 3: Run the test**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E '^test \"E2E|FAIL|error:'`
Expected: all 4 E2E tests PASS.

If a tool's `args_json` schema rejects the test args (i.e., the schema-validation in the tool fires before the hub dispatch and a specific tool's no-extension-connected test sees a schema error instead of the "no extension connected" string), fix the harness `args_json` to match what the tool actually requires by reading the tool's `tool_params` JSON Schema in its source file. Do NOT relax the tool's schema.

- [ ] **Step 4: Commit**

```bash
git add tests/extension/mock_hub_e2e_test.zig
git commit -m "$(cat <<'EOF'
test(extension): S4 — mock-hub E2E across all ten extension_* tools

Drives navigate, click, type, fill_form, screenshot, get_text, get_dom,
wait_for, scroll, and list_tabs through a structurally equivalent mock
ExtensionWsConn across four scenarios: no_extension_connected, happy
path, timeout, and ok:false error frame. Cross-tool pin so a regression
in any tool's failure-surface strings would fail here even if its
per-tool inline tests still pass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Diagnostics route test

**Files:**
- Modify: `tests/extension/diagnostics_test.zig` (replace placeholder).

**Rationale:** Pins the two new diagnostic-route JSON shapes + auth gates end-to-end through `extensionStatusPayload` + `extensionUserStatusPayload` + the gate helpers added in Tasks 5-6. The gateway-level integration is covered by the inline tests added in Tasks 5-6; this file is the structural pin against shape regressions.

- [ ] **Step 1: Replace the placeholder**

Write `tests/extension/diagnostics_test.zig`:

```zig
//! Sprint S4 — diagnostics route shape + auth-gate tests.
//!
//! Each test exercises the payload renderer directly with a real hub
//! + simulated state. The auth-gate predicates (validateInternalServiceToken,
//! extensionUserDiagnosticsSelfAllowed) are tested in gateway.zig inline.
//! This file pins the rendered JSON shape and the per-user state
//! reflection.

const std = @import("std");
const nullalis = @import("nullalis");
const hub_mod = nullalis.extension_ws.hub;
const gateway = nullalis.gateway;

const RecordingStream = struct {
    allocator: std.mem.Allocator,
    pub fn writeText(_: *anyopaque, _: []const u8) anyerror!void {}
    pub fn close(_: *anyopaque) void {}
};

test "diagnostics status: enabled=false when hub is null" {
    const input: gateway.ExtensionDiagnosticInput = .{
        .hub = null,
        .connections_total = 0,
        .auth_failed_total = 0,
    };
    const json = try gateway.extensionStatusPayload(std.testing.allocator, input);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":false") != null);
}

test "diagnostics status: total_active reflects paired count" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var s_a = RecordingStream{ .allocator = std.testing.allocator };
    var s_b = RecordingStream{ .allocator = std.testing.allocator };
    const c_a = try hub.registerConn("alice", @ptrCast(&s_a), RecordingStream.writeText, @ptrCast(&s_a), RecordingStream.close);
    defer hub.destroyConn(c_a);
    const c_b = try hub.registerConn("bob", @ptrCast(&s_b), RecordingStream.writeText, @ptrCast(&s_b), RecordingStream.close);
    defer hub.destroyConn(c_b);

    const input: gateway.ExtensionDiagnosticInput = .{
        .hub = &hub,
        .connections_total = 7,
        .auth_failed_total = 2,
    };
    const json = try gateway.extensionStatusPayload(std.testing.allocator, input);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_active\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"connections_total\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"auth_failed_total\":2") != null);
}

test "diagnostics per-user: paired=false when no conn" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    const input: gateway.ExtensionDiagnosticInput = .{
        .hub = &hub,
        .connections_total = 0,
        .auth_failed_total = 0,
    };
    const json = try gateway.extensionUserStatusPayload(std.testing.allocator, input, "alice");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"user_id\":\"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"paired\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"last_command_tool\":\"\"") != null);
}

test "diagnostics per-user: paired=true with connected_at populated" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var s = RecordingStream{ .allocator = std.testing.allocator };
    const c = try hub.registerConn("alice", @ptrCast(&s), RecordingStream.writeText, @ptrCast(&s), RecordingStream.close);
    defer hub.destroyConn(c);
    const input: gateway.ExtensionDiagnosticInput = .{
        .hub = &hub,
        .connections_total = 1,
        .auth_failed_total = 0,
    };
    const json = try gateway.extensionUserStatusPayload(std.testing.allocator, input, "alice");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"paired\":true") != null);
    // connected_at_unix is in seconds since epoch; must be >0 since
    // registerConn just stamped it from std.time.nanoTimestamp.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"connected_at_unix\":0") == null);
}
```

- [ ] **Step 2: Verify all needed sub-modules and pub visibility**

Run: `grep -nE 'pub const gateway\b' src/root.zig && grep -nE 'pub fn extensionStatusPayload|pub fn extensionUserStatusPayload|pub const ExtensionDiagnosticInput' src/gateway.zig`

Expected:
- `src/root.zig` already has `pub const gateway = @import("gateway.zig");` (verified at line 77).
- `src/gateway.zig` has `pub fn extensionStatusPayload`, `pub fn extensionUserStatusPayload`, and `pub const ExtensionDiagnosticInput` — all already `pub` per Task 5's edits.

If any is not `pub`, hoist it now and amend the Task 5 commit with `git commit --amend --no-edit` (only safe because the commits haven't been pushed yet).

- [ ] **Step 3: Run the test**

Run: `zig build test -Dengines=base,sqlite,postgres 2>&1 | grep -E 'diagnostics status|diagnostics per-user|FAIL|error:'`
Expected: all 4 tests PASS.

- [ ] **Step 4: Commit**

```bash
git add tests/extension/diagnostics_test.zig
git commit -m "$(cat <<'EOF'
test(extension): S4 — diagnostic route payload + state-reflection tests

Pins the JSON shape and per-user state reflection of
extensionStatusPayload + extensionUserStatusPayload through the
public ExtensionDiagnosticInput surface. Calls land via
nullalis.gateway and nullalis.extension_ws.hub — no per-test file
changes to src/root.zig needed (both exports already exist).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Update `docs/extension-ws-contract.md`

**Files:**
- Modify: `docs/extension-ws-contract.md` — add three new sections.

**Rationale:** Spec requires per-user token semantics, pair/disconnect/timeout state machine, and UI-safe failure states to be documented. Two of the three are partially covered; we add structured sections.

- [ ] **Step 1: Add `## Connection state machine` section**

After the `## Token + user_id semantics` section (ends ~line 106) and before `## Approval-gate behavior` (starts ~line 108), insert:

```markdown
## Connection state machine

Each per-user `ExtensionWsConn` moves through a small set of named states.
Operators observe state transitions in three places: the canonical
`extension_ws.event=<class>` log line, the `extension_ws_command_total`
metric (tagged by result class), and the
`GET /api/v1/diagnostics/extension/users/{user_id}` endpoint.

| Event             | Trigger                                                      | Observable surface                                                                                  |
|-------------------|--------------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| `pair`            | Auth succeeds + `registerConn` returns                       | log `extension_ws.event=pair user_id='...'`; gauge `extension_ws_connections_active` bumps          |
| `disconnect`      | `unregister` (graceful close, eviction, or hub deinit)       | log `extension_ws.event=disconnect user_id='...'`; gauge decrements                                  |
| `timeout`         | `sendCommand` exceeds `timeout_ms`                            | log `extension_ws.event=timeout user_id='...' tool='...'`; metric `extension_ws_command_total{result=timeout,tool}` |
| `command_failed`  | `sendCommand` returns a named error class other than timeout | log `extension_ws.event=command_failed user_id='...' tool='...'`; metric tagged with the class       |

Eviction-on-reconnect is the only path where `pair` and `disconnect` fire
in the same tick: the prior connection emits `disconnect`, then the new
connection emits `pair`. Operators chasing "why did Alice's extension
drop" can disambiguate by checking whether an immediate `pair` follows
the `disconnect` (= reconnect / eviction) or not (= clean close).

## Control-plane diagnostics

Two routes return the live state of the extension surface.

### `GET /api/v1/diagnostics/extension/status`

System-wide view. Internal-token auth (same model as `/internal/diagnostics`).

Response shape:

```json
{
  "enabled": true,
  "total_active": 7,
  "connections_total": 142,
  "auth_failed_total": 3
}
```

`enabled` is true iff the gateway was started with `extension_ws_enabled`
+ at least one configured `(token, user_id)` entry. `total_active` is the
live count of paired users; `connections_total` is the cumulative lifetime
accept count; `auth_failed_total` is the cumulative count of `auth_ack
{ok:false}` outcomes.

### `GET /api/v1/diagnostics/extension/users/{user_id}`

Per-user view. Auth: internal-token OR `X-Zaki-User-Id == {user_id}`
(self-only). UI components SHOULD use the self-only mode so the
extension status pill in the chat header binds without operator
plumbing.

Response shape:

```json
{
  "user_id": "alice",
  "paired": true,
  "connected_at_unix": 1748534400,
  "last_command_at_unix": 1748534512,
  "last_command_tool": "navigate",
  "last_command_result": "ok"
}
```

Fields are zero / empty when the user has never paired or has not yet
dispatched a command since pairing. `last_command_result` is one of:
`ok`, `timeout`, `conn_closed`, `oom`, `error_other`. The UI maps
these to the user-safe states in the next section.
```

- [ ] **Step 2: Add `## UI-safe failure states` section**

Before the `Cost class` paragraph at the bottom of the file (~line 119), insert:

```markdown
## UI-safe failure states

The UI MUST branch on the diagnostic route's `last_command_result` (or
on the tool-call SSE error field) using these named states. Do NOT
parse free-form error strings — they are user-facing copy that can
change without notice.

| State                  | When                                                       | Suggested UI surface                                                |
|------------------------|------------------------------------------------------------|---------------------------------------------------------------------|
| `disconnected`         | `paired == false`                                           | "Browser extension not connected" pill + connect-extension banner   |
| `timed_out`            | `last_command_result == "timeout"`                          | "The browser took too long to respond" warning toast               |
| `denied`               | tool's `error_msg` matches `[denied]` or extension-side `code` is `denied` | "You blocked this action in the extension" copy                     |
| `command_failed`       | `last_command_result == "conn_closed"` or `"oom"` or `"error_other"`, or tool emitted an `[*]` error code other than `denied` | "Something went wrong driving your browser; retry?" with the code as small text |
| `success`              | `last_command_result == "ok"`                               | Standard success styling (no special surface needed)               |

The `denied` state is the only one that surfaces user intent (the user
declined the action in the extension's permission card). Every other
failure state is a system condition the user did not cause directly.
```

- [ ] **Step 3: Verify nothing else in the doc has bit-rotted**

Re-read lines 95-106 (the `Token + user_id semantics` section). The
existing prose is correct against the live code; do NOT rewrite. The
only change is the new sections sitting above and below it.

- [ ] **Step 4: Commit**

```bash
git add docs/extension-ws-contract.md
git commit -m "$(cat <<'EOF'
docs(extension): S4 — connection state machine + diagnostics + UI states

Three new sections:
- Connection state machine names pair / disconnect / timeout / command_failed
  with their observable surfaces (logs, metrics, diagnostic routes).
- Control-plane diagnostics documents GET /api/v1/diagnostics/extension/status
  and /users/{user_id} with response schemas.
- UI-safe failure states pins the disconnected / timed_out / denied /
  command_failed / success taxonomy the UI must branch on.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Update `docs/openapi-v1.yaml`

**Files:**
- Modify: `docs/openapi-v1.yaml` — add the two new routes and a WebSocket endpoint comment.

- [ ] **Step 1: Add the two diagnostic routes to the OpenAPI doc**

In `docs/openapi-v1.yaml`, find the existing `# WebSocket endpoints`
comment cluster near the bottom of the file (search for the comment-only
endpoint stubs around line 1307-1340). Add a new `paths:` entry before
that cluster — pick a spot alphabetically near `/api/v1/users/{user_id}/usage`
or after the last canonical user-scoped route. Insert:

```yaml
  /api/v1/diagnostics/extension/status:
    get:
      summary: System-wide extension WebSocket diagnostic state
      description: |
        Returns the live system-wide state of the extension WebSocket surface:
        whether the feature is enabled, how many users are currently paired,
        and lifetime counters. Requires `X-Internal-Token` (same model as
        `/internal/diagnostics`).
      security:
        - InternalServiceToken: []
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema:
                type: object
                required: [enabled, total_active, connections_total, auth_failed_total]
                properties:
                  enabled:
                    type: boolean
                  total_active:
                    type: integer
                    description: Live count of currently-paired users.
                  connections_total:
                    type: integer
                    description: Lifetime extension WS upgrades accepted.
                  auth_failed_total:
                    type: integer
                    description: Lifetime auth_ack{ok:false} outcomes.
        '401':
          description: Missing or invalid internal token.
        '405':
          description: Method not allowed (only GET supported).

  /api/v1/diagnostics/extension/users/{user_id}:
    get:
      summary: Per-user extension pairing + last-command state
      description: |
        Returns whether the requested user has a live extension paired,
        when they paired, and what their last command did. Auth model:
        either a valid `X-Internal-Token` (operator view) OR an
        `X-Zaki-User-Id` header that matches the path parameter (self
        view).
      security:
        - InternalServiceToken: []
        - ZakiUserId: []
      parameters:
        - in: path
          name: user_id
          required: true
          schema:
            type: string
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema:
                type: object
                required: [user_id, paired, connected_at_unix, last_command_at_unix, last_command_tool, last_command_result]
                properties:
                  user_id:
                    type: string
                  paired:
                    type: boolean
                  connected_at_unix:
                    type: integer
                    description: Seconds since epoch; 0 when not paired.
                  last_command_at_unix:
                    type: integer
                    description: Seconds since epoch; 0 when no command yet.
                  last_command_tool:
                    type: string
                    description: Empty when no command yet.
                  last_command_result:
                    type: string
                    description: One of "ok", "timeout", "conn_closed", "oom", "error_other", or empty.
        '400':
          description: Invalid user_id path parameter.
        '401':
          description: Neither a valid internal token nor a matching X-Zaki-User-Id was provided.
        '405':
          description: Method not allowed (only GET supported).
```

- [ ] **Step 2: Add the WebSocket endpoint comment**

In the same WebSocket-endpoints comment block near line 1340, add ONE line:

```yaml
  # GET /api/v1/extension/ws is a WebSocket upgrade endpoint. OpenAPI
  # 3.0 doesn't model WebSocket routes natively; the contract is in
  # docs/extension-ws-contract.md and the gateway source lives in
  # src/extension_ws/server.zig. Authentication uses per-user
  # extension tokens (config: gateway.extension_tokens) — there is
  # NO legacy global-token fallback.
```

- [ ] **Step 3: Commit**

```bash
git add docs/openapi-v1.yaml
git commit -m "$(cat <<'EOF'
docs(openapi): S4 — document /api/v1/diagnostics/extension/* + WS endpoint

Adds the system-wide and per-user diagnostic routes with full request
+ response schemas. Notes the per-user-token-only auth model. Adds a
comment block for the WebSocket endpoint (OpenAPI 3.0 cannot model WS;
existing pattern).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Update `docs/ui-handoff.md`

**Files:**
- Modify: `docs/ui-handoff.md` — extend the extension lane row and the P1 checklist.

- [ ] **Step 1: Update the extension lane reference**

In `docs/ui-handoff.md`, locate the table row at ~line 134 (the
"User-browser extension" row). Append a parenthetical reference to the
new diagnostic surface:

Find:
```markdown
| **User-browser extension** | User's logged-in sessions (Gmail, X, internal tools) | `extension_navigate`, `extension_click`, `extension_type`, `extension_fill_form`, `extension_screenshot`, `extension_get_text`, `extension_get_dom`, `extension_wait_for`, `extension_scroll`, `extension_list_tabs` | Chrome extension MV3 over `wss://` |
```

Replace with (changing only the last cell):
```markdown
| **User-browser extension** | User's logged-in sessions (Gmail, X, internal tools) | `extension_navigate`, `extension_click`, `extension_type`, `extension_fill_form`, `extension_screenshot`, `extension_get_text`, `extension_get_dom`, `extension_wait_for`, `extension_scroll`, `extension_list_tabs` | Chrome extension MV3 over `wss://`. UI binds pair state via `GET /api/v1/diagnostics/extension/users/{user_id}` (self-only via `X-Zaki-User-Id`). |
```

- [ ] **Step 2: Update the P1 row for "Extension browser readiness"**

Locate the table row at ~line 480 (`| P1 | Extension browser readiness | ...`). Update its acceptance cell from:

```markdown
| P1 | Extension browser readiness | backend + extension | Per-user token auth, pairing, disconnect state, approval behavior, and browser command failures are observable and test-covered |
```

To:

```markdown
| P1 | Extension browser readiness | backend + extension | Per-user token auth (only model), pair/disconnect/timeout/command_failed observable via `/api/v1/diagnostics/extension/*` + canonical `extension_ws.event=*` logs, cross-user isolation tested, mock-hub E2E across all ten extension_* tools |
```

- [ ] **Step 3: Check off the relevant extension boxes**

Lines 537-540 hold three open checkboxes:

```markdown
- [ ] Connect-extension banner shown when an `extension_*` tool is about to fire and no extension is paired.
- [ ] Per-tool permission card for the first `extension_*` invocation per session.
- [ ] Tab picker when `extension_list_tabs` returns >1 candidate.
```

These three depend on UI work, not backend, so leave the boxes
unchanged. The backend-side acceptance is captured in the P1 row above.

- [ ] **Step 4: Commit**

```bash
git add docs/ui-handoff.md
git commit -m "$(cat <<'EOF'
docs(ui-handoff): S4 — link UI to new extension diagnostic route

Updates the extension lane row to point at GET /api/v1/diagnostics/extension/users/{user_id}
as the self-only pairing-state binding for UI components, and refines
the P1 row's acceptance to name the now-observable state machine. UI
checkbox row remains open (UI work, not backend).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Update `docs/deferred-register.md`

**Files:**
- Modify: `docs/deferred-register.md` — close out the partial D67 row and add a Sprint S4 row.

- [ ] **Step 1: Find the current SHA of HEAD (which now has all S4 commits)**

Run: `git rev-parse --short HEAD`

Capture the SHA (call it `<S4_SHA>`). We embed it in the new row.

- [ ] **Step 2: Update the D67 row**

Find the row at line 268 in `docs/deferred-register.md`:

```markdown
| D67 | **Observability gap on the v1.14.21+22+23 new surfaces** — 20 new tools (10 extension_*, 8 artifact_*, trace_query, memory_doctor) have no `std.log.scoped` logger; no metric emissions from extension WS hub, artifact share, produce_document, Moonshot uploads. Operators have no chartable signal when features degrade | observability sweep is non-trivial and was not part of the commercial v1 scope; partially closed by the in-flight v1.14.23 observability subagent (`a8683b490`) | v1.14.23 in-flight (partial) → v1.15 (full SLO-grade) | **partial — scoped logger + metric emit subagent in flight; full SLO+alert wiring deferred** |
```

Update the status cell to:

```markdown
| D67 | **Observability gap on the v1.14.21+22+23 new surfaces** — 20 new tools (10 extension_*, 8 artifact_*, trace_query, memory_doctor) have no `std.log.scoped` logger; no metric emissions from extension WS hub, artifact share, produce_document, Moonshot uploads. Operators have no chartable signal when features degrade | observability sweep is non-trivial and was not part of the commercial v1 scope; partially closed by the v1.14.23 observability subagent (`a8683b490`); extension-WS lane closed by Sprint S4 (`<S4_SHA>`) — pair/disconnect/timeout/command_failed events + `/api/v1/diagnostics/extension/*` routes | v1.15 (full SLO-grade for the remaining surfaces) | **partial — extension WS lane shipped at S4; other lanes deferred to v1.15 SLO sweep** |
```

(Substitute the real short SHA you captured.)

- [ ] **Step 3: Add a new Sprint S4 row at the bottom of the table**

After the last existing row, add:

```markdown
| S4 | **Sprint S4 — extension browser readiness** — per-user token auth-only path documented, pair/disconnect/timeout/command_failed state machine on `ExtensionWsHub`, `GET /api/v1/diagnostics/extension/{status,users/:uid}` routes with documented JSON shapes, canonical `extension_ws.event=*` logs, cross-user isolation system test, mock-hub E2E across all ten extension_* tools, doc sync (extension-ws-contract.md + openapi-v1.yaml + ui-handoff.md) | shipped on branch `prod-readiness/s4-extension-browser-readiness` | n/a | **shipped at `<S4_SHA>`** |
```

- [ ] **Step 4: Commit**

```bash
git add docs/deferred-register.md
git commit -m "$(cat <<'EOF'
docs(deferred-register): S4 — close extension WS lane of D67 + Sprint S4 row

Updates D67 to record that the extension-WS observability lane is closed
by Sprint S4 (commit <S4_SHA>); remaining lanes (artifact share,
produce_document, Moonshot) stay deferred to v1.15. Adds a fresh row
pinning the Sprint S4 scope shipped on this branch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Final verification

**Files:**
- Read-only: every file touched above.
- No new commits unless verification surfaces a regression.

- [ ] **Step 1: Run the full verification matrix**

Run:
```bash
zig build -Dengines=base,sqlite,postgres 2>&1 | tail -10
```
Expected: build succeeds, no warnings or errors.

Run:
```bash
zig build test -Dengines=base,sqlite,postgres --summary all 2>&1 | tail -50
```
Expected: all tests pass; summary shows the new extension_* test artifacts running with non-zero test counts.

- [ ] **Step 2: Smoke the new diagnostic routes against a built binary (best-effort)**

If a local config + extension_tokens setup is available:

```bash
zig build -Dengines=base,sqlite,postgres
./zig-out/bin/nullalis --config tests/fixtures/extension-config.json &
GW_PID=$!
sleep 2
curl -s -H "X-Internal-Token: $(grep -oE '"internal_service_tokens".*' tests/fixtures/extension-config.json | head -1)" \
     http://localhost:8080/api/v1/diagnostics/extension/status
kill $GW_PID 2>/dev/null || true
```

Expected output (formatted): `{"enabled":true,"total_active":0,"connections_total":0,"auth_failed_total":0}`.

If no fixture exists, document the curl + expected output in the PR
description instead of executing — the inline tests already pin the
shape; the curl is operator-confidence only.

- [ ] **Step 3: Re-read every modified file**

Walk through the diff:

```bash
git diff main --stat
git log --oneline main..HEAD
```

Confirm:
- `src/extension_ws/auth.zig` is **unchanged** (the auth contract was already locked at META CRIT #2).
- `src/extension_ws/server.zig` is **unchanged** (the handshake/pump are already correct).
- No file outside the planned set was touched.

- [ ] **Step 4: Spec coverage cross-check**

Walk through the Sprint S4 spec sections and confirm:

| Spec section                              | Where addressed                                                     |
|-------------------------------------------|---------------------------------------------------------------------|
| Audit hub/tools/diagnostics/docs surface  | This plan's File Structure + Task 15 Step 3                          |
| Per-user token auth is only model         | Already locked in `src/extension_ws/auth.zig:13-23`; pinned in Task 8 |
| Legacy global token / fallback hard-disabled | Verified: `internal_service_tokens` is a separate config field used elsewhere; `extension_tokens` is the only auth source; closed-by-default. Pinned in Task 8. |
| Direct extension command without valid token fails closed | Task 8 + existing META CRIT #2 tests in `extension_ws/auth.zig`     |
| Pair/connected/disconnected/timeout/command_failed observable | Tasks 1-4 (state fields + lifecycle events) + Tasks 5-6 (diagnostic routes) |
| Canonical diagnostics routes or new `/api/v1/diagnostics/extension/*` | Tasks 5-6                                                            |
| Structured logs for pair/disconnect/timeout/command_failed | Task 4 (`emitLifecycleEvent` + `extension_ws.event=*`)              |
| Tool failure → structured tool_result failure / SSE error | Existing tools already do this via `ToolResult.fail(...)`. Task 9 verifies all ten. |
| Don't swallow exceptions for failed actions | Pinned by Task 9's "ok:false" branch covering all ten tools         |
| UI can render disconnected/timed_out/denied/command_failed/success | Task 11 documents the taxonomy + Task 13 points the UI at the route |
| E2E: every registered `extension_*` tool   | Task 9                                                              |
| E2E: navigate, click, type, screenshot, get_dom, get_text, disconnected | Task 9                                                              |
| Cross-user isolation tested                | Task 8                                                              |
| Docs synced (4 files)                      | Tasks 11-14                                                          |

If any row says "not addressed," go back and add a task for it.

- [ ] **Step 5: Create the PR**

```bash
git push -u origin prod-readiness/s4-extension-browser-readiness
gh pr create --title "Sprint S4: Extension browser readiness — diagnostics + lifecycle + isolation + E2E" --body "$(cat <<'EOF'
## Summary

Closes the chat-side browser-extension surface to production-grade for ZAKI commercial V1.

- Per-user `ExtensionWsConn` lifecycle fields (`connected_at_ns`, `last_command_at_ns`, `last_command_tool`, `last_command_result`) + `ExtensionWsHub.listSnapshot(allocator)`.
- Canonical `extension_ws.event=<pair|disconnect|timeout|command_failed>` log line via `emitLifecycleEvent`.
- New control-plane routes: `GET /api/v1/diagnostics/extension/status` (system-wide, internal-token-gated) and `GET /api/v1/diagnostics/extension/users/{user_id}` (per-user, internal-token-or-self via `X-Zaki-User-Id`).
- Three new test files under `tests/extension/`:
  - `cross_user_isolation_test.zig` — pins user A's command never reaches user B's socket; auth validator's mapped-user_id contract re-pinned at the system level.
  - `mock_hub_e2e_test.zig` — every shipped `extension_*` tool drives through a mock conn across the 4 named failure states + happy path.
  - `diagnostics_test.zig` — pins the diagnostic-route JSON shape.
- Doc sync: `docs/extension-ws-contract.md` (state machine + diagnostics + UI failure-state taxonomy), `docs/openapi-v1.yaml` (two new routes + WebSocket comment), `docs/ui-handoff.md` (UI route binding), `docs/deferred-register.md` (close D67 extension lane + Sprint S4 row).

## Rebase note

Base branched off main directly. If S2 (`prod-readiness/s2-approval-consolidation`) or fixed S3 (`prod-readiness/s3-durable-trace-shares`) land first, rebase this branch onto the new main before merge.

## Test plan

- [x] `zig build -Dengines=base,sqlite,postgres`
- [x] `zig build test -Dengines=base,sqlite,postgres --summary all`
- [x] Local curl against `GET /api/v1/diagnostics/extension/status` returns the documented shape (or noted as not-executed if no fixture is available).
- [ ] Reviewer: confirm `src/extension_ws/auth.zig` and `src/extension_ws/server.zig` are unchanged; all S4 deltas live in `hub.zig`, `gateway.zig`, `src/root.zig`, `build.zig`, the three new test files, and the four doc files.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Note: the verification step does NOT commit anything itself. If the
verification surfaces a regression, fix it via a new task and commit
that task atomically before re-running the verification.

---

## Self-Review Summary

**Spec coverage check** (see Task 15 Step 4 table) — every line of the
Sprint S4 spec maps to at least one numbered task. No gaps.

**Placeholder scan:** No "TBD" / "implement later" / "similar to Task N"
sentences. Every code step has the full code block. Every command step
has the exact command + expected output.

**Type-consistency check:**
- `ExtensionState` declared in Task 3 (used by `listSnapshot` only); does not leak into the diagnostic payload helpers because those take `ExtensionDiagnosticInput` directly.
- `ExtensionDiagnosticInput { hub, connections_total, auth_failed_total }` declared in Task 5; consumed by both `extensionStatusPayload` and `extensionUserStatusPayload`; constructed by the route arm in Task 6 from `state.extension_ws_*` fields; constructed by the test in Task 10 with hand-picked counters.
- `ExtensionWsConn.recordCommandOutcome(tool, result)` and `snapshotLastCommand(out_tool, out_result)` declared in Task 1; called by Task 2 (hub.sendCommand wiring) and Task 5 (`extensionUserStatusPayload`). Signatures match.
- `LifecycleEvent` enum with `.pair`, `.disconnect`, `.timeout`, `.command_failed` declared in Task 4; used at four sites in the same task.
- `extensionStatusPayload`, `extensionUserStatusPayload`, and `ExtensionDiagnosticInput` exposed as `pub` in Task 5; called from inside `src/gateway.zig` (Task 6) and from `tests/extension/diagnostics_test.zig` via `nullalis.gateway.*` (Task 10).
- `extensionUserDiagnosticsSelfAllowed(hdr_user_id, path_user_id) bool` declared in Task 6; tested in Task 6 inline test.
- `nullalis.extension_ws.hub` and `nullalis.extension_ws.auth` are the **only** namespace paths used in the standalone test files (Tasks 8, 9, 10). These already exist as `pub const extension_ws = struct { pub const hub = ...; pub const auth = ...; };` in `src/root.zig`.
- `nullalis.tools` and `nullalis.tools.extension_<name>.Extension<Name>Tool` are the **only** tool-side namespace paths used in Task 9. These already exist as `pub const tools = @import("tools/root.zig");` in `src/root.zig` and `pub const extension_navigate = @import(...);` etc. in `src/tools/root.zig`.
- `validateInternalServiceTokenWithPolicy(raw, tokens, auth_required) bool` (already at `src/gateway.zig:3494`) is the predicate Task 6 tests directly so the inline tests don't need to construct a `GatewayState`. If it isn't already `pub`, Task 6 Step 2 surfaces that and a follow-up hoists it.

No mismatched names. No undefined references. `GatewayState` is **not** constructed in any test — the helpers take a minimal `ExtensionDiagnosticInput` instead.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-29-s4-extension-browser-readiness.md`. The plan is 15 atomic tasks, each with TDD-shape steps (failing test → code → passing test → commit). The full Sprint S4 acceptance is covered. Verification at Task 15 runs the documented `zig build` + `zig build test` matrix.
