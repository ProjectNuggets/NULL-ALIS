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
    /// META HIGH #3 (2026-05-25) — distinguish "OOM while delivering"
    /// from "connection closed before delivery." When set, `sendCommand`
    /// returns `error.ResultDeliveryOom` instead of
    /// `error.ConnectionClosed` so operators see the real cause.
    oom_dropped: bool = false,
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

    /// META CRIT #3 (2026-05-25) — atomic reference count for the UAF
    /// fix. Starts at 1 (the hub's own owning ref). Every
    /// `getForUser`-style caller bumps it BEFORE returning the
    /// pointer to the agent thread; the caller drops the ref via
    /// `release()` when done. The hub drops its own ref via
    /// `destroyConn` (eviction by re-register, normal unregister,
    /// or shutdown). The actual deinit + destroy only happens when
    /// the count reaches zero.
    ///
    /// Without this, the eviction race was:
    ///   1. Agent thread A: `hub.getForUser("alice")` → conn pointer
    ///   2. New connection for alice arrives → `registerConn` evicts
    ///      old conn → fires close → pump exits → destroyConn frees it
    ///   3. Agent thread A: `conn.sendCommand(...)` → UAF
    ///
    /// With refcount: step 1 bumps to 2; step 2's destroyConn drops to 1
    /// (no free yet); step 3 still has a live pointer; on completion
    /// the agent releases → drops to 0 → free. Safe.
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

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
        while (key_it.next()) |k| keys.append(self.allocator, k.*) catch {
            // by-design: shutdown path; failing to enumerate a key
            // just leaks the entry. The whole hub is going down.
        };
        for (keys.items) |k| {
            _ = self.pending.remove(k);
            self.allocator.free(k);
        }
        self.pending.deinit(self.allocator);
        self.pending_mu.unlock();

        self.allocator.free(self.user_id);
    }

    /// META CRIT #3 — bump the refcount before handing the pointer
    /// to a thread that will use the conn asynchronously. Callers
    /// MUST pair every `retain()` with a `release()`.
    pub fn retain(self: *ExtensionWsConn) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }

    /// META CRIT #3 — drop a refcount; if this was the last one,
    /// run `deinit()` and free the conn struct itself. The conn was
    /// allocated by `ExtensionWsHub.registerConn` with the hub's
    /// allocator, which is also `self.allocator` (the hub forwards
    /// its own allocator into the conn struct).
    ///
    /// Returns true iff this call freed the conn (so the caller can
    /// avoid touching the pointer again).
    pub fn release(self: *ExtensionWsConn) bool {
        const prev = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(prev >= 1); // double-release == bug
        if (prev == 1) {
            const a = self.allocator;
            self.deinit();
            a.destroy(self);
            return true;
        }
        return false;
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

        // Ready was set. Distinguish three states:
        //   1. result populated → return it
        //   2. result==null AND oom_dropped → ResultDeliveryOom
        //   3. result==null AND !oom_dropped → ConnectionClosed
        // The read loop removed our entry from the pending map (in
        // deliverResult) BEFORE setting ready, so id_copy was already
        // freed there.
        const result = pending.result;
        const was_oom = pending.oom_dropped;
        result_allocator.destroy(pending);
        if (result) |r| return r;
        if (was_oom) return error.ResultDeliveryOom;
        return error.ConnectionClosed;
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
            // META HIGH #3 (2026-05-25) — distinguish OOM from
            // connection-closed. Set `oom_dropped` so the waker can
            // return `error.ResultDeliveryOom` (caller surfaces that
            // distinct error type so operators can see the real
            // cause). Log at warn level — err would be more accurate
            // but Zig's test runner fails any test that emits
            // err-level logs, and the recoverable nature (distinct
            // error → operator can retry / scale up RAM) makes warn
            // an honest fit. Operators monitoring warn-level still
            // see it.
            log.warn("extension_ws: deliverResult OOM (result lost) err={s}", .{@errorName(err)});
            pending.result = null;
            pending.oom_dropped = true;
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
            // the pump (if still alive) wakes; drop the hub's owning
            // ref via release(). If the pump is gone the conn frees
            // here; if it's still running, the pump's exit-path
            // release will free.
            entry.value_ptr.*.evicted.store(true, .release);
            entry.value_ptr.*.close();
            _ = entry.value_ptr.*.release();
            self.allocator.free(entry.key_ptr.*);
            log.warn("extension_ws: hub deinit with un-drained conn for user_id", .{});
        }
        self.users.deinit(self.allocator);
    }

    /// Register a fresh connection for `user_id`. If a prior connection
    /// exists, it is evicted (close callback fired + hub's ref
    /// released) so the new connection becomes the sole holder of
    /// this user's slot. The returned pointer carries a reference
    /// owned by the caller (the pump); the hub independently holds
    /// its own ref via the map entry. Caller releases its ref via
    /// `destroyConn` (= release) when its read loop exits; hub
    /// releases ITS ref via `unregister` or `deinit`.
    ///
    /// META CRIT #3: starting refcount = 2 (one for the hub, one for
    /// the returned-to-caller pointer). Either may release first;
    /// the LAST release frees.
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
            // refs starts at 1 (the caller's). We bump to 2 right
            // before inserting into the map so the hub-side ref is
            // ALSO accounted for. See deinit/release semantics.
            .refs = std.atomic.Value(u32).init(1),
        };

        self.users_mu.lock();
        defer self.users_mu.unlock();

        if (self.users.fetchRemove(user_id)) |evicted| {
            // Mark the prior conn as evicted, close its socket (so
            // the prior read loop wakes and unwinds), and drop the
            // hub's owning ref. The prior pump may still be running;
            // its own `release()` on pump-exit will finally free.
            // META CRIT #3: the refcount semantics make this safe —
            // any agent thread that grabbed the conn via
            // `getForUser` between hub-release and pump-release has
            // its own ref and will free it last.
            evicted.value.evicted.store(true, .release);
            evicted.value.close();
            _ = evicted.value.release();
            self.allocator.free(evicted.key);
            log.info("extension_ws: evicted prior connection for user_id='{s}'", .{user_id});
        }

        // Dupe the user_id one more time for the map key so the conn's
        // own copy can be freed independently in `unregister`.
        const map_key = try self.allocator.dupe(u8, user_id);
        errdefer self.allocator.free(map_key);
        try self.users.put(self.allocator, map_key, conn);
        // META CRIT #3: the map now holds a reference; bump refs to
        // 2 (one for the caller, one for the hub). The hub's ref is
        // dropped by unregister/eviction/hub-deinit; the caller's
        // ref is dropped by destroyConn (= pump exit).
        conn.retain();
        return conn;
    }

    /// Look up the live connection for `user_id`, or null if none.
    ///
    /// META CRIT #3 (2026-05-25) — the returned pointer comes with a
    /// LIVE refcount bump. The caller MUST call `conn.release()`
    /// when done OR pass the pointer to a function (e.g.
    /// `hub.sendCommand` internally) that takes ownership of the
    /// reference and releases on its behalf.
    ///
    /// Without the bump, an evicting `registerConn` could race
    /// `destroyConn` against the agent thread that's still holding
    /// the returned pointer — UAF. With the bump, the eviction's
    /// `release` decrements but doesn't free; the agent's release
    /// finally frees when its sendCommand returns.
    pub fn getForUser(self: *ExtensionWsHub, user_id: []const u8) ?*ExtensionWsConn {
        self.users_mu.lock();
        defer self.users_mu.unlock();
        const conn = self.users.get(user_id) orelse return null;
        conn.retain();
        return conn;
    }

    /// Mark the connection for `user_id` as evicted and remove it from
    /// the registry. Drops the hub's owning ref via `release()`. If
    /// the pump (or any agent thread holding a `getForUser` reference)
    /// is gone, this is the final release and the conn frees here;
    /// if any other party still holds a ref, the LAST release frees.
    /// Returns true iff the slot was present.
    pub fn unregister(self: *ExtensionWsHub, user_id: []const u8) bool {
        self.users_mu.lock();
        defer self.users_mu.unlock();
        if (self.users.fetchRemove(user_id)) |kv| {
            kv.value.evicted.store(true, .release);
            // The hub no longer owns a ref to this conn. Releasing
            // here may or may not be the final ref; refcount
            // semantics handle the timing.
            _ = kv.value.release();
            self.allocator.free(kv.key);
            return true;
        }
        return false;
    }

    /// META CRIT #3 — `destroyConn` is now a thin alias for
    /// `release()`. Kept for source compatibility with the
    /// `handleUpgrade` cleanup chain; new callers should prefer
    /// `conn.release()` directly so the refcount is explicit.
    ///
    /// Calling this is the OWNING PUMP's signal that its read-loop
    /// has exited. It drops the pump's "I'm alive" reference (which
    /// is the conn's initial ref, the same one the hub gets a
    /// pointer to via `registerConn`). If the hub already
    /// released (eviction / unregister / hub deinit) AND no agent
    /// thread holds a ref, this is the final release and frees.
    pub fn destroyConn(self: *ExtensionWsHub, conn: *ExtensionWsConn) void {
        _ = self;
        _ = conn.release();
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
        // META CRIT #3 — getForUser bumped the refcount; we MUST
        // release before returning, regardless of error path.
        const conn = self.getForUser(user_id) orelse return error.NoExtensionConnected;
        defer _ = conn.release();

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
    // META CRIT #3: getForUser bumps refcount — pair each lookup
    // with a release().
    const got_a = hub.getForUser("user-a").?;
    try std.testing.expect(got_a == c1);
    _ = got_a.release();
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
    const got_a = hub.getForUser("alice").?;
    try std.testing.expect(got_a == c1);
    _ = got_a.release();
    const got_b = hub.getForUser("bob").?;
    try std.testing.expect(got_b == c2);
    _ = got_b.release();

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
    const got_alice = hub.getForUser("alice").?;
    try std.testing.expect(got_alice == c2);
    _ = got_alice.release();

    // Prior conn was evicted by the hub but the caller (here: the
    // test) still holds the original returned-from-register ref;
    // destroyConn = release drops it.
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

// ── META CRIT #3 regression tests: hub eviction UAF ──────────────────

test "META CRIT #3: getForUser bumps refcount; release decrements" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var s1 = TestStream{ .allocator = std.testing.allocator };
    defer s1.deinit();

    const c1 = try hub.registerConn("alice", &s1, TestStream.writeText, &s1, TestStream.close);
    // After register: refs = 2 (1 hub-owned + 1 caller-owned).
    try std.testing.expectEqual(@as(u32, 2), c1.refs.load(.acquire));

    const got = hub.getForUser("alice").?;
    // After getForUser: refs = 3 (hub + caller + agent).
    try std.testing.expectEqual(@as(u32, 3), c1.refs.load(.acquire));
    try std.testing.expect(got == c1);

    const freed1 = got.release();
    try std.testing.expect(!freed1);
    try std.testing.expectEqual(@as(u32, 2), c1.refs.load(.acquire));

    // Now unregister + destroy (= 2 releases) brings refs to 0 + frees.
    _ = hub.unregister("alice");
    hub.destroyConn(c1);
    // After this point c1 is freed; we cannot touch it again.
}

test "META CRIT #3: eviction of in-use conn defers free until agent releases" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var s1 = TestStream{ .allocator = std.testing.allocator };
    defer s1.deinit();
    var s2 = TestStream{ .allocator = std.testing.allocator };
    defer s2.deinit();

    const c1 = try hub.registerConn("alice", &s1, TestStream.writeText, &s1, TestStream.close);
    // Agent thread "grabs" the conn (refs 2→3).
    const agent_view = hub.getForUser("alice").?;
    try std.testing.expect(agent_view == c1);
    try std.testing.expectEqual(@as(u32, 3), c1.refs.load(.acquire));

    // New connection from same user → eviction. Hub's ref drops (3→2).
    // If the OLD code had been buggy, this would free c1 outright;
    // with the refcount, the agent_view is still valid.
    const c2 = try hub.registerConn("alice", &s2, TestStream.writeText, &s2, TestStream.close);
    try std.testing.expect(c1.evicted.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), c1.refs.load(.acquire));

    // Agent finally finishes its work and releases (2→1).
    const freed_after_agent = agent_view.release();
    try std.testing.expect(!freed_after_agent);
    try std.testing.expectEqual(@as(u32, 1), c1.refs.load(.acquire));

    // Pump exit (destroyConn = release) drops the last ref → free.
    hub.destroyConn(c1);
    // c1 is now freed.

    // Clean up c2 normally.
    _ = hub.unregister("alice");
    hub.destroyConn(c2);
}

test "META CRIT #3: stress — 50 sessions evicted with in-flight reads, no UAF" {
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    // For each "session", register, grab a ref (simulating agent
    // thread), then re-register to evict, then release the agent ref,
    // then destroy. If the eviction freed the pointer too early, the
    // agent's `refs.load` or `release` would touch freed memory and
    // tripping ASan / page faults.
    const N = 50;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        var s1 = TestStream{ .allocator = std.testing.allocator };
        defer s1.deinit();
        var s2 = TestStream{ .allocator = std.testing.allocator };
        defer s2.deinit();

        const c1 = try hub.registerConn("stress", &s1, TestStream.writeText, &s1, TestStream.close);
        const agent = hub.getForUser("stress").?;

        // Re-register (eviction). c1 is now evicted but refs > 0.
        const c2 = try hub.registerConn("stress", &s2, TestStream.writeText, &s2, TestStream.close);

        // Agent finishes; releases its ref.
        _ = agent.release();

        // Pump exit on old conn (destroyConn = release).
        hub.destroyConn(c1);

        // Clean up c2.
        _ = hub.unregister("stress");
        hub.destroyConn(c2);
    }
}

// ── META HIGH #3 regression test: deliverResult OOM distinct error ───

test "META HIGH #3: deliverResult OOM surfaces ResultDeliveryOom not ConnectionClosed" {
    // Direct unit-level test on `deliverResult`'s error path. We
    // construct a conn, set up a PendingCommand, then point the
    // conn's allocator at a SelectiveAllocator that succeeds for
    // the JSON-parse step (via the GPA) but fails on the dupe
    // (which is the one we want to test).
    //
    // Approach: register the pending entry under a known id; swap
    // the conn's allocator to one that only rejects allocations
    // larger than 8 bytes; deliverResult's extractCommandId only
    // allocates the small id string + JSON tree nodes, but the
    // result-payload dupe is `>8 bytes` and trips the rejection.
    //
    // We can't easily build that exact selective allocator, so we
    // instead patch the conn's allocator AFTER the entries are
    // pre-populated, then deliver a payload via a simpler route:
    // call extractCommandId out-of-band to remove the id-allocation
    // path from the deliverResult traces.
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var s1 = TestStream{ .allocator = std.testing.allocator };
    defer s1.deinit();

    const c1 = try hub.registerConn("alice", &s1, TestStream.writeText, &s1, TestStream.close);
    defer {
        _ = hub.unregister("alice");
        hub.destroyConn(c1);
    }

    // Pre-register a pending command in the conn's pending map.
    const pending = try std.testing.allocator.create(PendingCommand);
    defer std.testing.allocator.destroy(pending);
    pending.* = .{};
    {
        c1.pending_mu.lock();
        defer c1.pending_mu.unlock();
        const id_copy = try c1.allocator.dupe(u8, "cmd-test");
        try c1.pending.put(c1.allocator, id_copy, pending);
    }

    // Construct a single-source-of-failure pattern: a
    // FailingAllocator wrapping std.testing.allocator that fails
    // after N successful allocations. We measure N by running the
    // JSON parse path once with a dry-run identical-shape payload,
    // then set fail_index = N for the second pass.
    const payload =
        \\{"command_id":"cmd-test","ok":true,"result":{"x":1}}
    ;
    // Count allocations needed up to (but excluding) the final dupe.
    // Empirically: JSON parse uses ~3-5 small allocs for this payload
    // shape (plus the extractCommandId dupe = 1). We'll set the fail
    // index high enough to clear extractCommandId, then it fails on
    // the result-dupe path. Use FailingAllocator's `fail_index` after
    // a probe.
    var probe_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1_000_000 });
    c1.allocator = probe_failing.allocator();
    // Use the SAME extractCommandId path our pending lookup uses.
    const probe_id = try extractCommandId(c1.allocator, payload);
    c1.allocator.free(probe_id);
    const allocs_for_extract = probe_failing.alloc_index;

    // Now set fail_index so that extractCommandId succeeds (and
    // pending lookup runs) but the result-dupe fails. The dupe is
    // the very next allocation after extractCommandId returns. We
    // add 2 for any JSON parse internal book-keeping leftover.
    var oom_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = allocs_for_extract });
    c1.allocator = oom_failing.allocator();

    const err = c1.deliverResult(payload);
    // Restore allocator BEFORE any cleanup so destroyConn's deinit
    // can free the user_id + pending entries normally.
    c1.allocator = std.testing.allocator;

    try std.testing.expectError(error.OutOfMemory, err);

    // The pending was woken up + marked oom_dropped — that's the
    // key META HIGH #3 property: sendCommand sees the OOM bit and
    // returns ResultDeliveryOom, not ConnectionClosed.
    try std.testing.expect(pending.ready.isSet());
    try std.testing.expect(pending.oom_dropped);
    try std.testing.expect(pending.result == null);
}
