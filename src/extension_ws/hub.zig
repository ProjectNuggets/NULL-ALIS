//! Per-user registry for active extension WebSocket connections.
//!
//! The hub is the bridge between the agent-side tool dispatcher (which
//! calls `sendCommand(user_id, cmd)` and waits for a CommandResult) and
//! the read-loop in `extension_ws/server.zig` (which receives result
//! frames and routes them to the waiting tool call).
//!
//! Threading model:
//!   - One write-mutex per connection guards outbound frame writes so
//!     the agent's tool-thread and any background ping never interleave
//!     bytes on the socket.
//!   - The connection's `pending` map is guarded by a per-conn mutex
//!     (`pending_mu`); it's only touched by the read loop (insert from
//!     `deliverResult`) and `sendCommand` (register/wait/remove).
//!   - The hub-level `users` map is guarded by `users_mu`. New
//!     registrations under an existing user atomically kick out the
//!     prior connection (calls its `closeFn` so the prior read-loop
//!     wakes and exits).
//!
//! Lifetime contract:
//!   - `registerConn` returns a `*ExtensionWsConn` owned by the hub.
//!     The caller (server's `handleUpgrade`) must call `hub.unregister`
//!     when the read loop exits.
//!   - `unregister` is idempotent — calling it for a connection that
//!     was already evicted by a new registration is a no-op.

const std = @import("std");

const log = std.log.scoped(.extension_ws);

/// Default per-command timeout: 30 s matches the contract's
/// `timeout_ms: 30000` default for browser tools. The contract's
/// `wait_for` tool has its own per-call timeout (10 s default, but the
/// extension may extend it via args); for that case the agent should
/// pass a longer hub timeout via the explicit `timeout_ms` arg if
/// needed. 30 s is plenty for navigate/click/screenshot.
pub const DEFAULT_COMMAND_TIMEOUT_MS: u64 = 30_000;

/// Callback type for writing a text frame to the underlying socket.
/// Server-side framing (no mask) is built by the implementation; the
/// hub only knows about text payloads. `ctx` is whatever opaque pointer
/// the registration supplied.
pub const WriteTextFn = *const fn (ctx: *anyopaque, text: []const u8) anyerror!void;

/// Callback type for closing the underlying connection. Called when a
/// newer connection for the same user evicts an older one. Best-effort:
/// implementations should not panic on already-closed sockets.
pub const CloseFn = *const fn (ctx: *anyopaque) void;

pub const PendingCommand = struct {
    /// Heap-allocated copy of the result payload (null until the read
    /// loop delivers, or until `sendCommand` gives up on timeout).
    /// On timeout, `sendCommand` removes this entry from the pending
    /// map BEFORE the result lands, so a late result is dropped on the
    /// floor (no use-after-free).
    result: ?[]u8 = null,
    /// Set when `result` is populated. `sendCommand` waits on this with
    /// a timeout. The event-vs-mutex split exists because Zig 0.15.2's
    /// `ResetEvent.timedWait` returns a clean timeout signal we can map
    /// to `error.Timeout` without ambiguous state.
    ready: std.Thread.ResetEvent = .{},
};

pub const ExtensionWsConn = struct {
    allocator: std.mem.Allocator,
    user_id: []u8, // owned by the conn; freed in deinit
    write_ctx: *anyopaque,
    write_text: WriteTextFn,
    close_ctx: *anyopaque,
    close_fn: CloseFn,
    write_mu: std.Thread.Mutex = .{},
    pending_mu: std.Thread.Mutex = .{},
    pending: std.StringHashMapUnmanaged(*PendingCommand) = .empty,
    /// Monotonic counter so the hub can mint unique command_ids without
    /// pulling in a UUID/ULID dependency. The contract example uses
    /// ULID-shaped strings but says nothing about their format — the
    /// extension just echoes whatever it gets back in the result frame.
    /// Decimal counter prefixed with `cmd-` is enough for v1.
    next_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    /// True when the hub has already removed this conn from its
    /// `users` map (either via eviction by a new registration or by
    /// `unregister`). The owning `handleUpgrade` checks this in its
    /// cleanup path to decide whether to free the conn itself
    /// (`evicted = true` ⇒ hub no longer owns it ⇒ caller frees) or
    /// let `unregister` do the freeing.
    evicted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn deinit(self: *ExtensionWsConn) void {
        // Drain any waiters with a synthetic error: anyone still
        // blocked in `sendCommand` should wake up and observe their
        // PendingCommand was removed, then return error.ConnectionClosed.
        // We can't set their `ready` here because the result slot is
        // null — they'll see ready+result==null and treat it as a
        // dropped connection.
        self.pending_mu.lock();
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.ready.set();
        }
        // Free key strings + remove entries. PendingCommand structs
        // themselves are owned by the `sendCommand` stack frame, so
        // we don't `destroy` them here — they'll be freed once their
        // owner returns.
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer keys.deinit(self.allocator);
        var key_it = self.pending.keyIterator();
        while (key_it.next()) |k| keys.append(self.allocator, k.*) catch {};
        for (keys.items) |k| {
            _ = self.pending.remove(k);
            self.allocator.free(k);
        }
        self.pending.deinit(self.allocator);
        self.pending_mu.unlock();

        self.allocator.free(self.user_id);
    }

    /// Send a Command JSON frame and block until the matching
    /// CommandResult arrives or the timeout fires. Caller frees the
    /// returned slice via `allocator.free`.
    ///
    /// `command_json` is a serialized Command (`{"command_id":...,
    /// "tool":..., "args":..., "timeout_ms":...}`). The caller is
    /// responsible for putting a real `command_id` in there that
    /// matches the `id` parameter.
    pub fn sendCommand(
        self: *ExtensionWsConn,
        result_allocator: std.mem.Allocator,
        id: []const u8,
        command_json: []const u8,
        timeout_ms: u64,
    ) ![]u8 {
        // Allocate the PendingCommand on the heap so the read loop can
        // safely populate `result` after we return from a timed-out
        // wait. We remove it from the map on timeout BEFORE freeing,
        // so the read loop can't find it after the timeout fires.
        //
        // The destroy(pending) lands in every exit path explicitly
        // rather than via `errdefer` — error paths and the success
        // path all need to free, and errdefer + explicit free in the
        // same path is the double-free trap we hit on first pass.
        const pending = try result_allocator.create(PendingCommand);
        pending.* = .{};

        const id_copy = self.allocator.dupe(u8, id) catch |err| {
            result_allocator.destroy(pending);
            return err;
        };

        // Register pending BEFORE writing the command — otherwise a
        // very fast extension could reply before we registered, and
        // the result would be dropped.
        {
            self.pending_mu.lock();
            defer self.pending_mu.unlock();
            self.pending.put(self.allocator, id_copy, pending) catch |err| {
                self.allocator.free(id_copy);
                result_allocator.destroy(pending);
                return err;
            };
        }

        // Write the command frame under the write mutex.
        {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            self.write_text(self.write_ctx, command_json) catch |err| {
                // Roll back the pending entry on write failure.
                self.pending_mu.lock();
                if (self.pending.fetchRemove(id_copy)) |kv| {
                    self.allocator.free(kv.key);
                }
                self.pending_mu.unlock();
                result_allocator.destroy(pending);
                return err;
            };
        }

        // Wait for the result with a timeout.
        const timeout_ns: u64 = timeout_ms *| std.time.ns_per_ms;
        pending.ready.timedWait(timeout_ns) catch |err| {
            // Timeout — remove from pending so a late result is dropped
            // on the floor (the read loop will find no entry and log).
            self.pending_mu.lock();
            if (self.pending.fetchRemove(id_copy)) |kv| {
                self.allocator.free(kv.key);
            }
            self.pending_mu.unlock();
            result_allocator.destroy(pending);
            return err;
        };

        // Ready was set. Either result is populated, or the connection
        // was closed (deinit fan-out). Distinguish via result nullity.
        // The read loop removed our entry from the pending map (in
        // deliverResult) BEFORE setting ready, so id_copy was already
        // freed there.
        const result = pending.result;
        result_allocator.destroy(pending);
        if (result == null) return error.ConnectionClosed;
        return result.?;
    }

    /// Build a command_id unique to this connection. Returns an
    /// allocator-owned slice the caller frees after use.
    pub fn mintCommandId(self: *ExtensionWsConn, allocator: std.mem.Allocator) ![]u8 {
        const n = self.next_id.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(allocator, "cmd-{d}", .{n});
    }

    /// Route a CommandResult JSON payload to the waiting `sendCommand`.
    /// The payload buffer is borrowed for the JSON-parse window; on
    /// successful routing we duplicate the bytes so the caller's arena
    /// can be reclaimed independently.
    pub fn deliverResult(self: *ExtensionWsConn, payload: []const u8) !void {
        const id = try extractCommandId(self.allocator, payload);
        defer self.allocator.free(id);

        var maybe_pending: ?*PendingCommand = null;
        {
            self.pending_mu.lock();
            defer self.pending_mu.unlock();
            if (self.pending.fetchRemove(id)) |kv| {
                self.allocator.free(kv.key);
                maybe_pending = kv.value;
            }
        }
        const pending = maybe_pending orelse {
            // Late result for a timed-out / unknown command. Log at
            // info level — useful for diagnosing wonky extensions but
            // not noisy enough to fill the operator's log.
            log.info("extension_ws: dropping result for unknown command_id={s}", .{id});
            return;
        };

        // Dupe into the conn's long-lived allocator; the caller's
        // arena will be reclaimed when its frame is dropped. The
        // `sendCommand` waker frees `pending.result` via the
        // result_allocator it owns — but we're not using that here;
        // instead `sendCommand` returns the slice to the caller as
        // owned-by-result_allocator. So we MUST dupe via that same
        // allocator. We don't know it here — so dupe via the conn's
        // allocator and let `sendCommand` re-dupe + free.
        //
        // For v1 simplicity: dupe via the conn's allocator. The
        // `sendCommand` contract above says "caller frees returned
        // slice via `allocator.free` (the allocator the caller passed
        // as `result_allocator`)". We satisfy that by having
        // `sendCommand` re-dupe into `result_allocator` before
        // returning, and free this intermediate buffer.
        const dup = self.allocator.dupe(u8, payload) catch |err| {
            // OOM: signal the waker with a null result so the caller
            // can return error.ConnectionClosed (closest match — we
            // can't deliver but can't fail-out from here).
            pending.result = null;
            pending.ready.set();
            return err;
        };
        pending.result = dup;
        pending.ready.set();
    }

    /// Force-close (called by `unregister` and by eviction of a stale
    /// connection when a new one registers for the same user_id).
    pub fn close(self: *ExtensionWsConn) void {
        self.close_fn(self.close_ctx);
    }
};

pub const ExtensionWsHub = struct {
    allocator: std.mem.Allocator,
    users_mu: std.Thread.Mutex = .{},
    users: std.StringHashMapUnmanaged(*ExtensionWsConn) = .empty,

    pub fn init(allocator: std.mem.Allocator) ExtensionWsHub {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ExtensionWsHub) void {
        self.users_mu.lock();
        defer self.users_mu.unlock();
        var it = self.users.iterator();
        while (it.next()) |entry| {
            // Defensive: any conn still present at shutdown was not
            // properly drained by its owner. Mark evicted + close so
            // the pump (if still alive) wakes; do NOT destroy the
            // conn — that's the owner's job. Free only the map key.
            entry.value_ptr.*.evicted.store(true, .release);
            entry.value_ptr.*.close();
            self.allocator.free(entry.key_ptr.*);
            log.warn("extension_ws: hub deinit with un-drained conn for user_id (leak risk)", .{});
        }
        self.users.deinit(self.allocator);
    }

    /// Register a fresh connection for `user_id`. If a prior connection
    /// exists, it is evicted (close callback fired + struct freed) so
    /// the new connection becomes the sole holder of this user's slot.
    /// The returned pointer is owned by the hub; the caller releases it
    /// via `unregister(user_id)` when its read loop exits.
    pub fn registerConn(
        self: *ExtensionWsHub,
        user_id: []const u8,
        write_ctx: *anyopaque,
        write_text: WriteTextFn,
        close_ctx: *anyopaque,
        close_fn: CloseFn,
    ) !*ExtensionWsConn {
        const user_id_copy = try self.allocator.dupe(u8, user_id);
        errdefer self.allocator.free(user_id_copy);

        const conn = try self.allocator.create(ExtensionWsConn);
        errdefer self.allocator.destroy(conn);
        conn.* = .{
            .allocator = self.allocator,
            .user_id = user_id_copy,
            .write_ctx = write_ctx,
            .write_text = write_text,
            .close_ctx = close_ctx,
            .close_fn = close_fn,
        };

        self.users_mu.lock();
        defer self.users_mu.unlock();

        if (self.users.fetchRemove(user_id)) |evicted| {
            // Mark the prior conn as evicted, close its socket (so
            // the prior read loop wakes and unwinds), but DO NOT
            // destroy it here — the prior `handleUpgrade` could still
            // be mid-`deliverResult` on it. The prior caller's
            // cleanup path observes `evicted=true` and calls
            // `deinit + destroy` itself, after its pump has returned.
            evicted.value.evicted.store(true, .release);
            evicted.value.close();
            self.allocator.free(evicted.key);
            log.info("extension_ws: evicted prior connection for user_id='{s}'", .{user_id});
        }

        // Dupe the user_id one more time for the map key so the conn's
        // own copy can be freed independently in `unregister`.
        const map_key = try self.allocator.dupe(u8, user_id);
        errdefer self.allocator.free(map_key);
        try self.users.put(self.allocator, map_key, conn);
        return conn;
    }

    /// Look up the live connection for `user_id`, or null if none.
    pub fn getForUser(self: *ExtensionWsHub, user_id: []const u8) ?*ExtensionWsConn {
        self.users_mu.lock();
        defer self.users_mu.unlock();
        return self.users.get(user_id);
    }

    /// Mark the connection for `user_id` as evicted and remove it from
    /// the registry. Does NOT deinit/destroy the conn — the caller (or
    /// the prior owner if this slot was already evicted by a new
    /// registration) owns that timing. Returns true iff the slot was
    /// present in the registry.
    ///
    /// Why the caller frees instead of the hub: the conn struct may
    /// still have an active pump-frames thread mid-`deliverResult`.
    /// The caller is the only party that knows when its pump has
    /// returned, so it owns the destroy timing.
    pub fn unregister(self: *ExtensionWsHub, user_id: []const u8) bool {
        self.users_mu.lock();
        defer self.users_mu.unlock();
        if (self.users.fetchRemove(user_id)) |kv| {
            kv.value.evicted.store(true, .release);
            self.allocator.free(kv.key);
            return true;
        }
        return false;
    }

    /// Finalize a connection record: deinit + free its backing memory.
    /// Call this from the owning thread AFTER its read loop has
    /// returned and AFTER `unregister` (or eviction by a new
    /// registration). Idempotent only in the sense that calling it
    /// twice on the same pointer is undefined behavior — the owning
    /// thread must ensure single-call.
    pub fn destroyConn(self: *ExtensionWsHub, conn: *ExtensionWsConn) void {
        conn.deinit();
        self.allocator.destroy(conn);
    }

    /// Convenience: send a command to a registered user by user_id.
    /// Mints a fresh command_id, wraps `tool` + `args_json` into a
    /// Command frame, and forwards to `conn.sendCommand`.
    ///
    /// Returns the raw JSON CommandResult payload (caller frees via
    /// `result_allocator`).
    pub fn sendCommand(
        self: *ExtensionWsHub,
        result_allocator: std.mem.Allocator,
        user_id: []const u8,
        tool: []const u8,
        args_json: []const u8,
        timeout_ms: u64,
    ) ![]u8 {
        const conn = self.getForUser(user_id) orelse return error.NoExtensionConnected;

        const id = try conn.mintCommandId(result_allocator);
        defer result_allocator.free(id);

        const command_json = try std.fmt.allocPrint(
            result_allocator,
            "{{\"command_id\":\"{s}\",\"tool\":\"{s}\",\"args\":{s},\"timeout_ms\":{d}}}",
            .{ id, tool, args_json, timeout_ms },
        );
        defer result_allocator.free(command_json);

        const result_borrowed = try conn.sendCommand(result_allocator, id, command_json, timeout_ms);
        defer conn.allocator.free(result_borrowed);

        // Re-dupe into the caller's allocator so the caller's free
        // path matches what `sendCommand`'s docstring promises.
        return result_allocator.dupe(u8, result_borrowed);
    }
};

/// Extract the `command_id` field from a CommandResult JSON payload.
/// Returns an allocator-owned copy. Errors:
///   - `error.MissingCommandId` — payload didn't include the field
///   - JSON parse errors propagate (the read loop logs and drops).
fn extractCommandId(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return error.MalformedResultFrame;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.MalformedResultFrame,
    };
    const id_val = obj.get("command_id") orelse return error.MissingCommandId;
    const id_str = switch (id_val) {
        .string => |s| s,
        else => return error.MissingCommandId,
    };
    return allocator.dupe(u8, id_str);
}

// ── Tests ────────────────────────────────────────────────────────────

/// Test stream: collects writes; close just flips a flag. Lets us
/// drive the hub without touching real sockets.
const TestStream = struct {
    written: std.ArrayListUnmanaged(u8) = .empty,
    closed: bool = false,
    allocator: std.mem.Allocator,

    pub fn writeText(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *TestStream = @ptrCast(@alignCast(ctx));
        try self.written.appendSlice(self.allocator, text);
        try self.written.append(self.allocator, '\n'); // delimiter for the test
    }

    pub fn close(ctx: *anyopaque) void {
        const self: *TestStream = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }

    pub fn deinit(self: *TestStream) void {
        self.written.deinit(self.allocator);
    }
};

test "hub registerConn + getForUser + unregister" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var s1 = TestStream{ .allocator = std.testing.allocator };
    defer s1.deinit();

    const c1 = try hub.registerConn("user-a", &s1, TestStream.writeText, &s1, TestStream.close);
    try std.testing.expectEqualStrings("user-a", c1.user_id);
    try std.testing.expect(hub.getForUser("user-a") == c1);
    try std.testing.expect(hub.getForUser("user-b") == null);

    try std.testing.expect(hub.unregister("user-a"));
    try std.testing.expect(hub.getForUser("user-a") == null);
    hub.destroyConn(c1);
}

test "hub register two users distinct connections" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var s1 = TestStream{ .allocator = std.testing.allocator };
    defer s1.deinit();
    var s2 = TestStream{ .allocator = std.testing.allocator };
    defer s2.deinit();

    const c1 = try hub.registerConn("alice", &s1, TestStream.writeText, &s1, TestStream.close);
    const c2 = try hub.registerConn("bob", &s2, TestStream.writeText, &s2, TestStream.close);
    try std.testing.expect(c1 != c2);
    try std.testing.expect(hub.getForUser("alice") == c1);
    try std.testing.expect(hub.getForUser("bob") == c2);

    try std.testing.expect(hub.unregister("alice"));
    try std.testing.expect(hub.unregister("bob"));
    hub.destroyConn(c1);
    hub.destroyConn(c2);
}

test "hub re-registering same user evicts prior connection" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var s1 = TestStream{ .allocator = std.testing.allocator };
    defer s1.deinit();
    var s2 = TestStream{ .allocator = std.testing.allocator };
    defer s2.deinit();

    const c1 = try hub.registerConn("alice", &s1, TestStream.writeText, &s1, TestStream.close);
    try std.testing.expect(!s1.closed);
    try std.testing.expect(!c1.evicted.load(.acquire));

    const c2 = try hub.registerConn("alice", &s2, TestStream.writeText, &s2, TestStream.close);
    try std.testing.expect(s1.closed); // prior closeFn was invoked
    try std.testing.expect(c1.evicted.load(.acquire)); // eviction flag set
    try std.testing.expect(hub.getForUser("alice") == c2);

    // Prior conn was evicted by the hub but not destroyed; the owner
    // (here: the test) must finalize it.
    hub.destroyConn(c1);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c2);
}

test "extractCommandId parses well-formed CommandResult" {
    const payload =
        \\{"command_id":"cmd-42","ok":true,"result":{}}
    ;
    const id = try extractCommandId(std.testing.allocator, payload);
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("cmd-42", id);
}

test "extractCommandId rejects missing command_id" {
    const payload =
        \\{"ok":true}
    ;
    try std.testing.expectError(error.MissingCommandId, extractCommandId(std.testing.allocator, payload));
}

test "extractCommandId rejects malformed JSON" {
    const payload = "not json at all";
    try std.testing.expectError(error.MalformedResultFrame, extractCommandId(std.testing.allocator, payload));
}

test "hub sendCommand routes by command_id and returns result" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var s1 = TestStream{ .allocator = std.testing.allocator };
    defer s1.deinit();

    const c1 = try hub.registerConn("alice", &s1, TestStream.writeText, &s1, TestStream.close);

    // Spawn a "fake extension" thread that, once a command lands in
    // s1.written, looks up the command_id and delivers a matching
    // result back through the conn.
    const HelperCtx = struct {
        stream: *TestStream,
        conn: *ExtensionWsConn,
    };
    const Helper = struct {
        fn run(ctx: HelperCtx) void {
            // Spin until the command frame appears on the stream.
            var attempts: usize = 0;
            while (attempts < 1000) : (attempts += 1) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                if (ctx.stream.written.items.len > 0) break;
            }
            // Extract the command_id from the JSON we just received.
            const written = ctx.stream.written.items;
            const id_marker = "\"command_id\":\"";
            const id_start = std.mem.indexOf(u8, written, id_marker).?;
            const after = written[id_start + id_marker.len ..];
            const id_end = std.mem.indexOfScalar(u8, after, '"').?;
            const id = after[0..id_end];

            // Deliver a synthetic CommandResult.
            const result_json = std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{\"navigated\":\"https://example.com\"}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &s1, .conn = c1 }});

    const result = try hub.sendCommand(
        std.testing.allocator,
        "alice",
        "navigate",
        "{\"url\":\"https://example.com\"}",
        2_000, // 2 s budget — well under the helper's 1 s scan window
    );
    defer std.testing.allocator.free(result);

    thread.join();

    try std.testing.expect(std.mem.indexOf(u8, result, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "navigated") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}

test "hub sendCommand times out when no result arrives" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var s1 = TestStream{ .allocator = std.testing.allocator };
    defer s1.deinit();

    const c1 = try hub.registerConn("alice", &s1, TestStream.writeText, &s1, TestStream.close);

    // No reader: command is sent, no result lands, timer fires.
    const result = hub.sendCommand(
        std.testing.allocator,
        "alice",
        "navigate",
        "{\"url\":\"https://example.com\"}",
        50, // 50 ms — short enough to keep the test fast
    );
    try std.testing.expectError(error.Timeout, result);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}

test "hub sendCommand returns NoExtensionConnected when no user registered" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    const r = hub.sendCommand(
        std.testing.allocator,
        "alice",
        "navigate",
        "{}",
        500,
    );
    try std.testing.expectError(error.NoExtensionConnected, r);
}
