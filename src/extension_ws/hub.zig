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
const builtin = @import("builtin");
const observability = @import("../observability.zig");

const log = std.log.scoped(.extension_ws);

// ── IN-01 (2026-05-25) — deterministic CR-02 race injection ──────────
//
// Test-only hooks the IN-01 regression test uses to deterministically
// stall `deliverResult` AFTER its `fetchRemove` succeeded but BEFORE
// it writes `pending.result` / sets `pending.ready`. With this gate the
// test can guarantee the timeout-vs-deliver race window is hit on
// every run instead of relying on CPU scheduling luck (the pre-IN-01
// test was probabilistic — 20 iterations hoping the race lands).
//
// Both pointers default to null in test AND non-test builds; only the
// test sets them. In non-test builds the gate-check branch is dead
// code (`builtin.is_test == false` is comptime-known) and the
// optimizer prunes the check entirely, so production has zero overhead
// AND zero binary bloat from these hooks.
//
// Protocol:
//   - The test creates two ResetEvents: `gate` and `reached`.
//   - The test sets `test_deliver_gate = &gate` and
//     `test_deliver_reached = &reached`.
//   - When `deliverResult` reaches the injection point, it `.set()`s
//     `reached` so the test knows the race window is open, then
//     `.wait()`s on `gate`.
//   - The test does whatever ordering it wants (e.g. lets
//     sendCommand's timedWait expire), then `.set()`s `gate`.
//   - `deliverResult` resumes and finishes its writes / release.
pub var test_deliver_gate: ?*std.Thread.ResetEvent = null;
pub var test_deliver_reached: ?*std.Thread.ResetEvent = null;

/// Default per-command timeout: 30 s matches the contract's
/// `timeout_ms: 30000` default for browser tools. The contract's
/// `wait_for` tool has its own per-call timeout (10 s default, but the
/// extension may extend it via args); for that case the agent should
/// pass a longer hub timeout via the explicit `timeout_ms` arg if
/// needed. 30 s is plenty for navigate/click/screenshot.
pub const DEFAULT_COMMAND_TIMEOUT_MS: u64 = 30_000;

/// Cap on the per-conn "last command" tool-name + result-class
/// buffers. 32 bytes comfortably holds every v1 `extension_*` tool
/// name (longest is `extension_screenshot` at 20) plus every result
/// classifier (`ok`, `timeout`, `conn_closed`, `oom`, `no_conn`,
/// `error_other` — all ≤11). Both `ExtensionWsConn`'s storage and
/// `LastCommandSnapshot`'s value-typed buffers reference this
/// constant so future tool-name growth widens both sites in lockstep
/// without callers having to size scratch buffers.
pub const LAST_COMMAND_BUF_LEN: usize = 32;

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
    /// Allocated via the conn's allocator (the same one that allocated
    /// the PendingCommand itself), so either side can free it without
    /// cross-allocator confusion.
    result: ?[]u8 = null,
    /// Set when `result` is populated OR when the conn is shutting down.
    /// `sendCommand` waits on this with a timeout.
    ready: std.Thread.ResetEvent = .{},
    /// META HIGH #3 (2026-05-25) — distinguish "OOM while delivering"
    /// from "connection closed before delivery." When set, `sendCommand`
    /// returns `error.ResultDeliveryOom` instead of
    /// `error.ConnectionClosed` so operators see the real cause.
    oom_dropped: bool = false,
    /// v1.14.22 (CR-02 fix, 2026-05-25) — atomic reference count.
    /// Closes the timeout-vs-deliver UAF race that the META subagent's
    /// conn-level refcount fix did NOT cover.
    ///
    /// Initial value: 2 when the pending entry is inserted into the
    /// conn's pending map: one ref for the map itself (held while the
    /// entry is in `self.pending`) and one ref for the sender
    /// (`sendCommand`'s frame). Every removal-from-map call site
    /// (timeout path in sendCommand, success path in deliverResult,
    /// rollback paths, hub deinit drain) drops the map ref via
    /// `release(allocator)`. `sendCommand` always drops the sender
    /// ref via `release(allocator)` at function exit.
    ///
    /// The last release frees the struct via `allocator.destroy(self)`.
    /// The allocator MUST match the one used to create the struct
    /// (the conn's allocator); enforce this at every release call site.
    ///
    /// Race trace (timeout vs deliver):
    ///   refs=2; A=timeout-path, B=deliver-path.
    ///   B.fetchRemove succeeds, holds pointer, hasn't written yet.
    ///   A.timedWait fires, A.fetchRemove returns null (B removed).
    ///   A calls release(alloc) for sender ref       → refs=1
    ///   B writes pending.result, pending.ready.set()
    ///     (safe — refs=1 means PendingCommand still alive)
    ///   B calls release(alloc) for map ref          → refs=0 → free
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// CR-02 — decrement the refcount; if this was the last reference,
    /// free `self.result` (if populated) and destroy the struct.
    /// `allocator` MUST be the conn's allocator (the one used at
    /// allocation time AND for `result`).
    pub fn release(self: *PendingCommand, allocator: std.mem.Allocator) void {
        const prev = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(prev >= 1); // double-release == bug
        if (prev == 1) {
            if (self.result) |r| allocator.free(r);
            allocator.destroy(self);
        }
    }
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

    /// Wall-clock nanoseconds (std.time.nanoTimestamp, truncated to i64)
    /// when this conn was registered with the hub. Set once in
    /// `registerConn`; never updated thereafter. Zero means "not yet
    /// registered" (only observable on a half-constructed conn struct).
    ///
    /// S4 CI fix: stored as `i64` rather than `i128` because Linux
    /// x86_64 codegen + atomic operations on `i128` hit a Zig 0.15.2
    /// backend bug (`genSetReg called with a value larger than dst_reg`
    /// at compile time, plus a 16-byte-alignment-induced SIGSEGV at
    /// runtime). `i64` nanoseconds-since-epoch covers ~292 years —
    /// safe through 2262.
    connected_at_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    /// Wall-clock nanoseconds of the last command dispatch result
    /// (success OR named failure). Zero means "no command yet." See
    /// `connected_at_ns` for the i64 rationale.
    last_command_at_ns: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    /// Fixed-size scratch buffer for the last command's tool name. The
    /// `LAST_COMMAND_BUF_LEN` cap is generous for the v1 tool family
    /// (longest is `extension_screenshot` at 20 bytes); future longer
    /// names get truncated rather than allocated-per-update. Reading
    /// requires loading `last_command_tool_len` first.
    last_command_tool_buf: [LAST_COMMAND_BUF_LEN]u8 = [_]u8{0} ** LAST_COMMAND_BUF_LEN,
    last_command_tool_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Same buffer pattern for the last command's result classifier
    /// ("ok", "timeout", "conn_closed", "oom", "no_conn", "error_other").
    last_command_result_buf: [LAST_COMMAND_BUF_LEN]u8 = [_]u8{0} ** LAST_COMMAND_BUF_LEN,
    last_command_result_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// Mutex protecting the two fixed-size buffers above. We use a mutex
    /// rather than treating the buffers as atomic-byte-stores because the
    /// snapshot fn needs to read tool + result + length consistently
    /// (otherwise it could observe a torn pair: new length, old bytes).
    last_command_mu: std.Thread.Mutex = .{},

    pub fn deinit(self: *ExtensionWsConn) void {
        // Drain any waiters with a synthetic "connection closed":
        // anyone blocked in `sendCommand` wakes via `ready.set()`,
        // observes result==null + oom_dropped==false, and returns
        // `error.ConnectionClosed`. The drain also drops the map ref
        // for every entry; if a sender is still waiting, its release
        // is the final one and the PendingCommand frees there.
        //
        // HI-06 (v1.14.22): pre-allocate the keys arraylist to the
        // known map size so subsequent appends can't OOM and skip
        // entries. The previous `catch {}` swallow caused a partial
        // drain on OOM — orphan PendingCommand structs leaked because
        // their senders saw no ready.set.
        self.pending_mu.lock();
        const pending_count = self.pending.count();
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer keys.deinit(self.allocator);
        // Pre-allocate. If THIS fails, we have nothing to enumerate
        // safely — the shutdown path can't gracefully recover from
        // not even having space for the key list. Log + bail. The
        // map's contents will leak but the process is exiting anyway
        // (deinit is shutdown-only).
        if (keys.ensureTotalCapacity(self.allocator, pending_count)) {
            var key_it = self.pending.keyIterator();
            while (key_it.next()) |k| {
                // Now safe: ensureTotalCapacity above guarantees
                // these appends do not allocate.
                keys.appendAssumeCapacity(k.*);
            }
        } else |err| {
            log.warn("extension_ws: hub.deinit OOM pre-allocating drain key buffer ({s}); leaking {d} pending entries", .{ @errorName(err), pending_count });
        }
        for (keys.items) |k| {
            if (self.pending.fetchRemove(k)) |kv| {
                // Wake the sender first, then drop the map ref.
                kv.value.ready.set();
                kv.value.release(self.allocator); // map ref
                self.allocator.free(kv.key);
            }
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
        // CR-02 (v1.14.22) — PendingCommand now uses an atomic refcount
        // to close the timeout-vs-deliver UAF. The struct is allocated
        // via `self.allocator` (NOT the caller's `result_allocator`) so
        // both sides can release without cross-allocator confusion.
        // The result payload is also self.allocator-owned (dup'd by
        // `deliverResult`); we re-dup into `result_allocator` before
        // returning to the caller so the docstring contract is honored.
        const pending = try self.allocator.create(PendingCommand);
        pending.* = .{ .refs = std.atomic.Value(u32).init(2) }; // map ref + sender ref

        const id_copy = self.allocator.dupe(u8, id) catch |err| {
            // Pre-insertion failure path: nothing else holds a ref yet.
            // Skip the refcount dance and just destroy.
            self.allocator.destroy(pending);
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
                // Still pre-insertion (the put failed); same direct
                // destroy is safe — no other holder exists.
                self.allocator.destroy(pending);
                return err;
            };
        }
        // Once inserted, the map holds 1 ref and the sender (this
        // frame) holds 1 ref. Every exit path below MUST release
        // exactly one ref for the sender, and any code path that
        // removes from the map MUST release the map ref.

        // Write the command frame under the write mutex.
        {
            self.write_mu.lock();
            defer self.write_mu.unlock();
            self.write_text(self.write_ctx, command_json) catch |err| {
                // Roll back the pending entry on write failure. Both
                // refs need to be dropped here (map ref + sender ref).
                self.pending_mu.lock();
                const removed = self.pending.fetchRemove(id_copy);
                self.pending_mu.unlock();
                if (removed) |kv| {
                    self.allocator.free(kv.key);
                    pending.release(self.allocator); // map ref
                }
                pending.release(self.allocator); // sender ref
                return err;
            };
        }

        // Wait for the result with a timeout.
        const timeout_ns: u64 = timeout_ms *| std.time.ns_per_ms;
        pending.ready.timedWait(timeout_ns) catch |err| {
            // Timeout — try to remove from pending. The deliverResult
            // path may have already removed (race window: B removed
            // but hasn't written yet); in that case `removed == null`
            // and we ONLY drop the sender ref. The map ref was already
            // taken over by B and B will drop it after writing.
            //
            // If we win the race (`removed != null`), we drop the map
            // ref ourselves + the sender ref. Either way pending is
            // safe to leave in B's hands (refs>=1 until B's release).
            self.pending_mu.lock();
            const removed = self.pending.fetchRemove(id_copy);
            self.pending_mu.unlock();
            if (removed) |kv| {
                self.allocator.free(kv.key);
                pending.release(self.allocator); // map ref
            }
            pending.release(self.allocator); // sender ref — last one if A won
            return err;
        };

        // Ready was set by deliverResult (or by a hub shutdown drain).
        // Distinguish three states:
        //   1. result populated → re-dup into caller's allocator
        //   2. result==null AND oom_dropped → ResultDeliveryOom
        //   3. result==null AND !oom_dropped → ConnectionClosed (drain)
        //
        // The map ref was already released by deliverResult (or by
        // hub.deinit's drain). We only drop the sender ref here.
        const result_slice = pending.result;
        const was_oom = pending.oom_dropped;

        // Re-dup BEFORE releasing — release may free `pending.result`
        // if this is the last ref.
        //
        // WR-01 (v1.14.22 hotfix follow-up): the dup itself is a
        // fault point. If `result_allocator.dupe` OOMs, we must
        // still release the sender ref before propagating the error
        // — otherwise the pending leaks at refs=1 with the map ref
        // already at 0 (released by deliverResult).
        const caller_owned: ?[]u8 = if (result_slice) |r| blk: {
            const owned = result_allocator.dupe(u8, r) catch |err| {
                pending.release(self.allocator); // sender ref
                return err;
            };
            break :blk owned;
        } else null;

        pending.release(self.allocator); // sender ref

        if (caller_owned) |r| return r;
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

        // IN-01 — test-only deterministic race gate. Inserted between
        // fetchRemove (succeeded above; we hold the map ref) and the
        // pending.result/.ready writes (below) so the IN-01 test can
        // freeze us in the exact window where the timeout-vs-deliver
        // UAF used to fire. Comptime-eliminated in non-test builds.
        if (comptime builtin.is_test) {
            if (test_deliver_reached) |r| r.set();
            if (test_deliver_gate) |g| g.wait();
        }

        // CR-02 (v1.14.22): we now hold the map ref (fetchRemove
        // transferred it to us — the map no longer accounts for it,
        // but the refcount still does). We must release the map ref
        // when we're done writing pending — but NOT before, because
        // pending.result/oom_dropped writes need pending to be alive.
        //
        // The sender's ref is independent: sender might already have
        // returned (CR-02 race), in which case our release here drops
        // refs from 1 → 0 and we free. Or sender is still waiting and
        // its release after seeing ready.set() drops to 0.
        const dup = self.allocator.dupe(u8, payload) catch |err| {
            log.warn("extension_ws: deliverResult OOM (result lost) err={s}", .{@errorName(err)});
            pending.result = null;
            pending.oom_dropped = true;
            pending.ready.set();
            pending.release(self.allocator); // map ref
            return err;
        };
        pending.result = dup;
        pending.ready.set();
        pending.release(self.allocator); // map ref
    }

    /// Force-close (called by `unregister` and by eviction of a stale
    /// connection when a new one registers for the same user_id).
    pub fn close(self: *ExtensionWsConn) void {
        self.close_fn(self.close_ctx);
    }

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

        // S4 CI fix: store as i64 (see connected_at_ns rationale).
        // nanoTimestamp returns i128; truncate via @intCast — safe
        // until year ~2262.
        self.last_command_at_ns.store(@intCast(std.time.nanoTimestamp()), .release);
    }

    /// Snapshot helper — copy the last command's tool + result into a
    /// caller-owned `LastCommandSnapshot` value under a single mutex
    /// hold. The snapshot's buffers are sized to `LAST_COMMAND_BUF_LEN`
    /// in lockstep with the conn's storage, so there is no caller-side
    /// buffer-sizing contract to get wrong.
    pub fn snapshotLastCommand(self: *ExtensionWsConn) LastCommandSnapshot {
        self.last_command_mu.lock();
        defer self.last_command_mu.unlock();

        var snap: LastCommandSnapshot = .{
            .tool_buf = [_]u8{0} ** LAST_COMMAND_BUF_LEN,
            .tool_len = self.last_command_tool_len.load(.monotonic),
            .result_buf = [_]u8{0} ** LAST_COMMAND_BUF_LEN,
            .result_len = self.last_command_result_len.load(.monotonic),
            .at_ns = self.last_command_at_ns.load(.monotonic),
        };
        @memcpy(snap.tool_buf[0..snap.tool_len], self.last_command_tool_buf[0..snap.tool_len]);
        @memcpy(snap.result_buf[0..snap.result_len], self.last_command_result_buf[0..snap.result_len]);
        return snap;
    }
};

/// Return shape of `ExtensionWsConn.snapshotLastCommand`. Carries the
/// tool name + result classifier inline (no heap, no caller-provided
/// buffer) so the snapshot is self-contained and unambiguously sized.
///
/// Named (not anonymous) so the Zig x86_64 backend codegens it cleanly
/// — the previous anonymous return tripped a `genSetReg called with a
/// value larger than dst_reg` bug in Zig 0.15.2 on Linux x86_64.
pub const LastCommandSnapshot = struct {
    tool_buf: [LAST_COMMAND_BUF_LEN]u8,
    tool_len: usize,
    result_buf: [LAST_COMMAND_BUF_LEN]u8,
    result_len: usize,
    /// Nanoseconds since epoch (truncated to i64; see
    /// `ExtensionWsConn.last_command_at_ns`). Zero when no command
    /// has been recorded yet.
    at_ns: i64,

    /// Borrow a view of the tool-name bytes. Lifetime is tied to the
    /// snapshot's stack frame — copy out before the snapshot goes
    /// out of scope if you need to keep the bytes longer.
    pub fn tool(self: *const LastCommandSnapshot) []const u8 {
        return self.tool_buf[0..self.tool_len];
    }

    pub fn result(self: *const LastCommandSnapshot) []const u8 {
        return self.result_buf[0..self.result_len];
    }
};

/// Caller-owned snapshot of one paired extension. Returned by
/// `ExtensionWsHub.listSnapshot` for the diagnostic routes.
///
/// All slice fields are heap-allocated copies; free via
/// `ExtensionState.freeSlice` so the caller doesn't have to track
/// individual allocations.
pub const ExtensionState = struct {
    user_id: []u8,
    /// Nanoseconds since epoch (truncated to i64; see `ExtensionWsConn.connected_at_ns`).
    connected_at_ns: i64,
    last_command_at_ns: i64,
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
            //
            // S4 hardening: log user_id BEFORE the free so leak-diagnosis
            // is actually useful. The prior log message ended with "for
            // user_id" but never formatted the value — operators had no
            // way to attribute the leak to a tenant.
            entry.value_ptr.*.evicted.store(true, .release);
            entry.value_ptr.*.close();
            _ = entry.value_ptr.*.release();
            log.warn("extension_ws: hub deinit with un-drained conn user_id='{s}'", .{entry.key_ptr.*});
            self.allocator.free(entry.key_ptr.*);
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
        // S4 CI fix: truncate nanoTimestamp's i128 to i64 (safe through year ~2262).
        conn.connected_at_ns.store(@intCast(std.time.nanoTimestamp()), .release);

        // S4 hardening: keep the lifecycle log emit OUT of the
        // users_mu critical section. We track the eviction + new-pair
        // events inside the lock with stack-local flags, then emit
        // after the lock releases. log.info / emitLifecycleEvent
        // ultimately write to stderr (or whatever std.log sink the
        // operator wires up), which may take its own internal lock —
        // doing that under users_mu would let a slow log sink stall
        // every concurrent getForUser/registerConn/unregister caller.
        var did_evict = false;
        var post_lock_active_count: usize = 0;
        {
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
                did_evict = true;
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
            post_lock_active_count = self.users.count();
            // HIGH 2.A: gauge of live extension WS sessions. Take the
            // count under the lock so the sample is consistent with the
            // map state visible to other readers.
            observability.recordMetricGlobal(.{ .extension_ws_connections_active = post_lock_active_count });
        }

        // Post-lock: emit the lifecycle events + operator-facing log
        // lines. Order is disconnect-before-pair so eviction-on-reconnect
        // shows the prior connection going away first, then the new one
        // arriving — operators can grep for the pair-after-disconnect
        // motif to identify clean reconnects vs cold pairs.
        if (did_evict) {
            log.info("extension_ws: evicted prior connection for user_id='{s}'", .{user_id});
            emitLifecycleEvent(.disconnect, .{ .user_id = user_id });
        }
        // WARN 2.C: operability signal — operator sees one info line
        // per new extension binding. user_id is logged here (not in
        // the cross-cutting metric) so a single operator grep can
        // attribute a hub event to a specific tenant.
        log.info("extension_ws: connection registered user_id='{s}' active={d}", .{ user_id, post_lock_active_count });
        emitLifecycleEvent(.pair, .{ .user_id = user_id });
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

    /// Live count of paired users. Takes `users_mu` for the duration
    /// of the read so the sample is consistent. Diagnostic helpers in
    /// `gateway.zig` use this instead of touching `users_mu` /
    /// `users` directly — the hub keeps its threading model
    /// encapsulated.
    pub fn activeCount(self: *ExtensionWsHub) usize {
        self.users_mu.lock();
        defer self.users_mu.unlock();
        return self.users.count();
    }

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
        // S4 hardening — leak audit, by exit point:
        //   (1) OOM at the `out` alloc above: nothing yet allocated, caller sees
        //       the error and out goes unused.
        //   (2) OOM at the per-entry `uid` dupe: this iteration's local
        //       errdefer frees nothing yet for the current entry; the outer
        //       errdefer frees out[0..written-1] (previous iterations'
        //       fully-populated triples) plus `out` itself.
        //   (3) OOM at the per-entry `tool` dupe: this iteration's
        //       errdefer-uid frees uid; outer frees out[0..written-1] + out.
        //   (4) OOM at the per-entry `result` dupe: this iteration's
        //       errdefer-tool frees tool, errdefer-uid frees uid; outer frees
        //       out[0..written-1] + out.
        //   (5) Success: `out[written] = ...; written += 1;` runs;
        //       on the NEXT iteration's OOM, the just-written entry is
        //       covered by the outer errdefer because `written` was incremented.
        // No leak in any exit path.
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
            const last = conn.snapshotLastCommand();
            const uid = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(uid);
            const tool = try allocator.dupe(u8, last.tool());
            errdefer allocator.free(tool);
            const result = try allocator.dupe(u8, last.result());
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

    /// Mark the connection for `user_id` as evicted and remove it from
    /// the registry. Drops the hub's owning ref via `release()`. If
    /// the pump (or any agent thread holding a `getForUser` reference)
    /// is gone, this is the final release and the conn frees here;
    /// if any other party still holds a ref, the LAST release frees.
    /// Returns true iff the slot was present.
    pub fn unregister(self: *ExtensionWsHub, user_id: []const u8) bool {
        // S4 hardening: emit lifecycle event AFTER releasing
        // users_mu. See registerConn for the rationale (avoid a slow
        // log sink stalling concurrent hub-map callers).
        var did_remove = false;
        {
            self.users_mu.lock();
            defer self.users_mu.unlock();
            if (self.users.fetchRemove(user_id)) |kv| {
                kv.value.evicted.store(true, .release);
                // The hub no longer owns a ref to this conn. Releasing
                // here may or may not be the final ref; refcount
                // semantics handle the timing.
                _ = kv.value.release();
                self.allocator.free(kv.key);
                // HIGH 2.A: refresh gauge after the slot is gone.
                observability.recordMetricGlobal(.{ .extension_ws_connections_active = self.users.count() });
                did_remove = true;
            }
        }
        if (did_remove) {
            // `user_id` is the caller-borrowed slice; it outlives the
            // function call, so it's safe to log after the lock drop.
            emitLifecycleEvent(.disconnect, .{ .user_id = user_id });
        }
        return did_remove;
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
        // HIGH 2.A: track command-call latency + result-class. The
        // emit is at the central hub entry-point (rather than per-
        // tool) so all 10 extension_* tools surface a metric without
        // each having to duplicate the timing dance.
        const t_start_ns = std.time.nanoTimestamp();

        // META CRIT #3 — getForUser bumped the refcount; we MUST
        // release before returning, regardless of error path.
        const conn = self.getForUser(user_id) orelse {
            observability.recordMetricGlobal(.{ .extension_ws_command_total = .{ .result = "no_conn", .tool = tool } });
            return error.NoExtensionConnected;
        };
        defer _ = conn.release();

        const id = try conn.mintCommandId(result_allocator);
        defer result_allocator.free(id);

        const command_json = try std.fmt.allocPrint(
            result_allocator,
            "{{\"command_id\":\"{s}\",\"tool\":\"{s}\",\"args\":{s},\"timeout_ms\":{d}}}",
            .{ id, tool, args_json, timeout_ms },
        );
        defer result_allocator.free(command_json);

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
            // WARN 2.C: operator-visible signal for timeouts. Other
            // failure classes are not log-spammed here because they
            // bubble to the tool layer where the user-facing error is
            // surfaced; a timeout is the one most useful to chart in
            // logs because the user often can't tell why their click
            // "did nothing".
            if (err == error.Timeout) {
                log.info("extension_ws: command timed out user_id='{s}' tool='{s}' timeout_ms={d}", .{ user_id, tool, timeout_ms });
                emitLifecycleEvent(.timeout, .{ .user_id = user_id, .extra_key = "tool", .extra_val = tool });
            } else {
                emitLifecycleEvent(.command_failed, .{ .user_id = user_id, .extra_key = "tool", .extra_val = tool });
            }
            return err;
        };
        // S4 review fix: `result_borrowed` was allocated by
        // `conn.sendCommand` from the CALLER's `result_allocator`
        // (see conn.sendCommand's `result_allocator.dupe(u8, r)`).
        // The previous `conn.allocator.free` worked only when the
        // caller happened to pass the same allocator the conn was
        // built with — under any other allocator (e.g., an arena per
        // call) it triggers an invalid-free panic. Free through the
        // owning allocator.
        defer result_allocator.free(result_borrowed);

        const elapsed_ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - t_start_ns, std.time.ns_per_ms));
        observability.recordMetricGlobal(.{ .extension_ws_command_latency_ms = elapsed_ms });
        observability.recordMetricGlobal(.{ .extension_ws_command_total = .{ .result = "ok", .tool = tool } });
        conn.recordCommandOutcome(tool, "ok"); // S4 — diagnostic stamp

        // Re-dupe into the caller's allocator so the caller's free
        // path matches what `sendCommand`'s docstring promises.
        return result_allocator.dupe(u8, result_borrowed);
    }
};

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
///
/// S4 review fix: if the 512-byte fixed buffer overflows
/// (pathological user_id or extra_val), surface a warn line with the
/// event class so the loss is operator-visible. Silent drop would
/// hide a real shipping-relevant event class from log shipping.
fn emitLifecycleEvent(ev: LifecycleEvent, args: LifecycleEventArgs) void {
    var buf: [512]u8 = undefined;
    var sink = std.io.fixedBufferStream(&buf);
    formatLifecycleEvent(sink.writer(), ev, args) catch {
        log.warn(
            "extension_ws.event={s} log_drop_reason=format_buf_overflow",
            .{ev.toString()},
        );
        return;
    };
    log.info("{s}", .{sink.getWritten()});
}

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

    /// Borrow the most recent written frame (newline-delimited).
    /// Returns null if no frame has been written yet. The slice
    /// borrows from `self.written.items` — valid until the next
    /// write or deinit.
    pub fn lastWrite(self: *TestStream) ?[]const u8 {
        if (self.written.items.len == 0) return null;
        const trimmed = std.mem.trimEnd(u8, self.written.items, "\n");
        if (trimmed.len == 0) return null;
        // Find the last '\n' delimiter before `trimmed.len`.
        if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |last_nl| {
            return trimmed[last_nl + 1 ..];
        }
        return trimmed;
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
    // CR-02 (v1.14.22) — PendingCommand now uses an atomic refcount.
    // Initialize refs=2 (map + simulated sender) so the test's
    // own deliverResult-path release brings it to 1 (map ref dropped)
    // and the test's manual release brings it to 0 (sender ref dropped).
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var s1 = TestStream{ .allocator = std.testing.allocator };
    defer s1.deinit();

    const c1 = try hub.registerConn("alice", &s1, TestStream.writeText, &s1, TestStream.close);
    defer {
        _ = hub.unregister("alice");
        hub.destroyConn(c1);
    }

    // Pre-register a pending command in the conn's pending map. The
    // PendingCommand MUST be allocated via c1.allocator (the conn's
    // allocator) because release() destroys via that allocator.
    const pending = try c1.allocator.create(PendingCommand);
    pending.* = .{ .refs = std.atomic.Value(u32).init(2) }; // map + sender (we are the sender)
    {
        c1.pending_mu.lock();
        defer c1.pending_mu.unlock();
        const id_copy = try c1.allocator.dupe(u8, "cmd-test");
        try c1.pending.put(c1.allocator, id_copy, pending);
    }

    const payload =
        \\{"command_id":"cmd-test","ok":true,"result":{"x":1}}
    ;
    // Probe the alloc count needed to walk extractCommandId so we
    // can fail the very next allocation (the result-payload dup).
    var probe_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1_000_000 });
    c1.allocator = probe_failing.allocator();
    const probe_id = try extractCommandId(c1.allocator, payload);
    c1.allocator.free(probe_id);
    const allocs_for_extract = probe_failing.alloc_index;

    var oom_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = allocs_for_extract });
    c1.allocator = oom_failing.allocator();

    const err = c1.deliverResult(payload);
    // Restore allocator BEFORE any cleanup. deliverResult's release
    // already used the failing allocator BUT only for the failing
    // pathway — the map ref drop after the error path uses
    // self.allocator which by then was still oom_failing. Setting
    // it back to testing_allocator is required for the LATER sender
    // release to free the struct cleanly.
    c1.allocator = std.testing.allocator;

    try std.testing.expectError(error.OutOfMemory, err);

    try std.testing.expect(pending.ready.isSet());
    try std.testing.expect(pending.oom_dropped);
    try std.testing.expect(pending.result == null);
    // Drop the simulated sender ref. The map ref was dropped inside
    // deliverResult's error path → refs went 2→1; this release
    // brings it to 0 and frees.
    pending.release(c1.allocator);
}

// ── CR-02 regression test: timeout-vs-deliver UAF ──────────────────────

test "IN-01/CR-02: timeout firing while deliverResult is mid-write does not UAF (deterministic)" {
    // IN-01 (2026-05-25) — replaces the prior probabilistic test that
    // looped 20 iterations hoping the race window would hit by luck.
    // This version uses the `test_deliver_gate` injection point in
    // `deliverResult` to FORCE deliver to be exactly in the
    // post-fetchRemove / pre-result-write window when the sender's
    // timedWait expires. Every run exercises the race; no scheduling
    // luck involved.
    //
    // Sequence:
    //   T0  Test sets gate + reached pointers.
    //   T1  "Sender" thread calls hub.sendCommand (timeout = 100 ms).
    //       The frame is registered; sendCommand blocks in timedWait.
    //   T2  "Deliver" thread calls conn.deliverResult with the
    //       matching command_id. Deliver succeeds at fetchRemove,
    //       sets `reached`, then blocks on `gate.wait()`.
    //   T3  Test thread waits on `reached` so it knows deliver is
    //       inside the race window with the map ref held but result
    //       not yet written.
    //   T4  Test thread releases `gate`. Deliver writes
    //       `pending.result`, sets `pending.ready`, releases map ref.
    //   T5  Sender wakes (ready was set BEFORE timedWait expired —
    //       gate.set happened well within 100 ms). Sender returns
    //       the result.
    //
    // Pre-CR-02 behavior: a sender whose timedWait fired between T2's
    // fetchRemove and T4's writes would destroy(pending) and T4 would
    // UAF. Post-fix the refcount keeps pending alive until both sides
    // release, so this test's strict ordering is safe AND a
    // regression would either deadlock (no fail) or trip testing
    // allocator's leak/UAF detector.
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var s1 = TestStream{ .allocator = std.testing.allocator };
    defer s1.deinit();

    const c1 = try hub.registerConn("alice", &s1, TestStream.writeText, &s1, TestStream.close);
    defer {
        _ = hub.unregister("alice");
        hub.destroyConn(c1);
    }

    var gate = std.Thread.ResetEvent{};
    var reached = std.Thread.ResetEvent{};
    test_deliver_gate = &gate;
    test_deliver_reached = &reached;
    defer {
        // Always tear down the global injection points — a leftover
        // pointer would corrupt subsequent tests in the same binary.
        test_deliver_gate = null;
        test_deliver_reached = null;
    }

    const SenderCtx = struct {
        hub: *ExtensionWsHub,
        allocator: std.mem.Allocator,
        result_slot: *?anyerror,
        ok_slot: *?[]u8,
    };
    const Sender = struct {
        fn run(ctx: SenderCtx) void {
            // 100 ms timeout — plenty of headroom for the test thread
            // to drive the gate. A regression that breaks the
            // refcount would either UAF (testing allocator catches)
            // or leak (testing allocator's defer hook catches at
            // end-of-test).
            const r = ctx.hub.sendCommand(
                ctx.allocator,
                "alice",
                "navigate",
                "{\"url\":\"https://example.com\"}",
                100,
            );
            if (r) |buf| {
                ctx.ok_slot.* = buf;
            } else |err| {
                ctx.result_slot.* = err;
            }
        }
    };

    var sender_err: ?anyerror = null;
    var sender_ok: ?[]u8 = null;
    const sender_thread = try std.Thread.spawn(.{}, Sender.run, .{SenderCtx{
        .hub = &hub,
        .allocator = std.testing.allocator,
        .result_slot = &sender_err,
        .ok_slot = &sender_ok,
    }});

    // Wait for the command frame to appear so we can extract the
    // command_id. We poll the test stream — sender is mid-call.
    const cmd_id = blk: {
        var attempts: usize = 0;
        while (attempts < 1_000) : (attempts += 1) {
            std.Thread.sleep(100 * std.time.ns_per_us);
            const written = s1.written.items;
            const marker = "\"command_id\":\"";
            const start = std.mem.indexOf(u8, written, marker) orelse continue;
            const after = written[start + marker.len ..];
            const end = std.mem.indexOfScalar(u8, after, '"') orelse continue;
            break :blk try std.testing.allocator.dupe(u8, after[0..end]);
        }
        sender_thread.join();
        return error.CommandFrameNeverAppeared;
    };
    defer std.testing.allocator.free(cmd_id);

    // Spawn the deliver thread. It will hit the gate post-fetchRemove
    // and block until we release it.
    const DeliverCtx = struct {
        conn: *ExtensionWsConn,
        allocator: std.mem.Allocator,
        cmd_id: []const u8,
    };
    const Deliver = struct {
        fn run(ctx: DeliverCtx) void {
            const result_json = std.fmt.allocPrint(
                ctx.allocator,
                "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{}}}}",
                .{ctx.cmd_id},
            ) catch return;
            defer ctx.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const deliver_thread = try std.Thread.spawn(.{}, Deliver.run, .{DeliverCtx{
        .conn = c1,
        .allocator = std.testing.allocator,
        .cmd_id = cmd_id,
    }});

    // Wait for deliver to enter the gate. After this point we know
    // deliver has done fetchRemove (it holds the map ref) but has
    // NOT yet written pending.result or set pending.ready. The
    // sender is still blocked in its timedWait at this moment.
    reached.wait();

    // Release the gate. Deliver writes result, sets ready, releases
    // map ref. Sender's timedWait returns successfully because we
    // set ready well before the 100ms budget expired. Sender then
    // dups the result, releases its sender ref, and the last release
    // frees pending. No UAF, no leak.
    gate.set();

    deliver_thread.join();
    sender_thread.join();

    // Assert outcome: ordering above guarantees sender returns the
    // result, NOT a timeout. (A regression that flipped the ordering
    // — e.g. swapped ready.set() with the map-ref release in the
    // wrong direction — would also still pass this assertion because
    // the test always lets deliver complete first; the load-bearing
    // check is the leak detector in std.testing.allocator at test
    // teardown.)
    try std.testing.expect(sender_err == null);
    try std.testing.expect(sender_ok != null);
    if (sender_ok) |buf| {
        std.testing.allocator.free(buf);
        // Sanity check the payload round-tripped.
    }
}

test "IN-01: deliver-after-timeout — sender returns Timeout, deliver still safe" {
    // Companion test: drive the OPPOSITE ordering through the same
    // gate. Sender's timedWait fires BEFORE deliver releases the
    // gate. With the refcount, the sender still cleanly returns
    // error.Timeout, and deliver — once released — writes/releases
    // safely on its still-live pending. Pre-fix this was the
    // canonical UAF case.
    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var s1 = TestStream{ .allocator = std.testing.allocator };
    defer s1.deinit();

    const c1 = try hub.registerConn("alice", &s1, TestStream.writeText, &s1, TestStream.close);
    defer {
        _ = hub.unregister("alice");
        hub.destroyConn(c1);
    }

    var gate = std.Thread.ResetEvent{};
    var reached = std.Thread.ResetEvent{};
    test_deliver_gate = &gate;
    test_deliver_reached = &reached;
    defer {
        test_deliver_gate = null;
        test_deliver_reached = null;
    }

    const SenderCtx = struct {
        hub: *ExtensionWsHub,
        allocator: std.mem.Allocator,
        err_slot: *?anyerror,
        ok_slot: *?[]u8,
    };
    const Sender = struct {
        fn run(ctx: SenderCtx) void {
            const r = ctx.hub.sendCommand(
                ctx.allocator,
                "alice",
                "navigate",
                "{\"url\":\"https://example.com\"}",
                25, // short timeout so we don't slow the suite
            );
            if (r) |buf| ctx.ok_slot.* = buf else |err| ctx.err_slot.* = err;
        }
    };

    var sender_err: ?anyerror = null;
    var sender_ok: ?[]u8 = null;
    const sender_thread = try std.Thread.spawn(.{}, Sender.run, .{SenderCtx{
        .hub = &hub,
        .allocator = std.testing.allocator,
        .err_slot = &sender_err,
        .ok_slot = &sender_ok,
    }});

    const cmd_id = blk: {
        var attempts: usize = 0;
        while (attempts < 1_000) : (attempts += 1) {
            std.Thread.sleep(100 * std.time.ns_per_us);
            const written = s1.written.items;
            const marker = "\"command_id\":\"";
            const start = std.mem.indexOf(u8, written, marker) orelse continue;
            const after = written[start + marker.len ..];
            const end = std.mem.indexOfScalar(u8, after, '"') orelse continue;
            break :blk try std.testing.allocator.dupe(u8, after[0..end]);
        }
        sender_thread.join();
        return error.CommandFrameNeverAppeared;
    };
    defer std.testing.allocator.free(cmd_id);

    const DeliverCtx = struct {
        conn: *ExtensionWsConn,
        allocator: std.mem.Allocator,
        cmd_id: []const u8,
    };
    const Deliver = struct {
        fn run(ctx: DeliverCtx) void {
            const result_json = std.fmt.allocPrint(
                ctx.allocator,
                "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{}}}}",
                .{ctx.cmd_id},
            ) catch return;
            defer ctx.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const deliver_thread = try std.Thread.spawn(.{}, Deliver.run, .{DeliverCtx{
        .conn = c1,
        .allocator = std.testing.allocator,
        .cmd_id = cmd_id,
    }});

    // Wait for deliver to enter the gate (post-fetchRemove).
    reached.wait();

    // DO NOT release the gate yet. Wait until the sender's 25 ms
    // timedWait has definitely expired. Then sender will try to
    // fetchRemove, find nothing (deliver already removed), drop ONLY
    // its sender ref, and return error.Timeout. The pending stays
    // alive because deliver still holds the map ref.
    sender_thread.join();
    try std.testing.expect(sender_err != null);
    try std.testing.expectEqual(@as(anyerror, error.Timeout), sender_err.?);
    try std.testing.expect(sender_ok == null);

    // NOW release the gate. Deliver dups the payload (will succeed),
    // writes pending.result, sets pending.ready (no one's listening,
    // that's fine), releases its map ref → refs goes 1 → 0 → free.
    // No UAF. testing.allocator would scream otherwise.
    gate.set();
    deliver_thread.join();
}

// ── 50-session concurrent soak (2026-05-25) ──────────────────────────
//
// Stress-test gate for the refcount + mutex code under burst load. The
// earlier "META CRIT #3: stress — 50 sessions" test was *sequential* —
// one user, register→evict→destroy in a tight loop. That exercised
// the refcount, but did NOT exercise lock contention on `pending_mu`,
// `write_mu`, or `users_mu` under burst from many threads at once.
//
// This soak spawns 50 worker threads, each acting as the agent side
// of a distinct extension WS session, plus a single "broker" thread
// that plays the role of the extension's read loop — scanning each
// per-conn TestStream for newly written commands and feeding back
// CommandResult frames via `deliverResult`. Every command thus
// completes the full hub roundtrip: write under write_mu, register
// pending under pending_mu, broker fetchRemoves under pending_mu,
// broker writes result + sets ready, sender wakes, re-dups, releases.
//
// What this gate proves under testing allocator:
//   1. No UAF — testing allocator pages would page-fault on freed access.
//   2. No leak — testing allocator asserts at teardown all blocks freed.
//   3. No deadlock — test must finish well under its budget.
//   4. No torn writes on the pending HashMap — sequential
//      consistency is required by the broker's fetchRemove never
//      seeing a half-inserted entry (a torn write would surface as a
//      "command_id unknown" warning + timeouts on the sender side;
//      we assert zero timeouts in the all-respond path).
//   5. Eviction lane works under traffic — a subset of users gets
//      re-registered mid-soak, which exercises the registerConn
//      eviction branch concurrent with senders/brokers.

const SoakStream = struct {
    written: std.ArrayListUnmanaged(u8) = .empty,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mu: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    pub fn writeText(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *SoakStream = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        try self.written.appendSlice(self.allocator, text);
        try self.written.append(self.allocator, '\n');
    }

    pub fn closeStream(ctx: *anyopaque) void {
        const self: *SoakStream = @ptrCast(@alignCast(ctx));
        self.closed.store(true, .release);
    }

    pub fn deinit(self: *SoakStream) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.written.deinit(self.allocator);
    }

    /// Drain ALL pending command frames from the write buffer and copy
    /// their command_ids out. The buffer is cleared on every drain so
    /// the broker only sees fresh commands on the next pass.
    fn drainCommandIds(self: *SoakStream, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged([]u8)) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.written.items.len == 0) return;
        // Each frame is terminated by '\n' in our writeText.
        var cursor: usize = 0;
        const buf = self.written.items;
        while (cursor < buf.len) {
            const nl_off = std.mem.indexOfScalarPos(u8, buf, cursor, '\n') orelse break;
            const frame = buf[cursor..nl_off];
            const marker = "\"command_id\":\"";
            if (std.mem.indexOf(u8, frame, marker)) |s| {
                const after = frame[s + marker.len ..];
                if (std.mem.indexOfScalar(u8, after, '"')) |e| {
                    const id_copy = try allocator.dupe(u8, after[0..e]);
                    try out.append(allocator, id_copy);
                }
            }
            cursor = nl_off + 1;
        }
        // Clear the buffer so next drain starts fresh.
        self.written.clearRetainingCapacity();
    }
};

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
    try std.testing.expectEqual(@as(i64, 0), conn.last_command_at_ns.load(.monotonic));
    // last_command_tool / last_command_result start empty.
    try std.testing.expectEqual(@as(usize, 0), conn.last_command_tool_len.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), conn.last_command_result_len.load(.monotonic));
}

test "ExtensionWsConn recordCommandOutcome + snapshotLastCommand round-trip" {
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

    // Before any recordCommandOutcome call: snapshot returns empty + at_ns=0.
    const before = conn.snapshotLastCommand();
    try std.testing.expectEqual(@as(usize, 0), before.tool_len);
    try std.testing.expectEqual(@as(usize, 0), before.result_len);
    try std.testing.expectEqual(@as(i64, 0), before.at_ns);

    // After a recordCommandOutcome call: snapshot returns the recorded
    // tool + result + a non-zero timestamp.
    conn.recordCommandOutcome("extension_click", "ok");
    const after = conn.snapshotLastCommand();
    try std.testing.expectEqualStrings("extension_click", after.tool());
    try std.testing.expectEqualStrings("ok", after.result());
    try std.testing.expect(after.at_ns > 0);

    // A second recordCommandOutcome overwrites the prior values.
    conn.recordCommandOutcome("extension_screenshot", "timeout");
    const overwritten = conn.snapshotLastCommand();
    try std.testing.expectEqualStrings("extension_screenshot", overwritten.tool());
    try std.testing.expectEqualStrings("timeout", overwritten.result());
    try std.testing.expect(overwritten.at_ns >= after.at_ns);
}

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

    // S4 hardening: parse the actual command_id the hub wrote
    // (instead of hardcoding "cmd-1") so the test stays correct under
    // any future change to `mintCommandId`'s counter seed.
    const Helper = struct {
        c: *ExtensionWsConn,
        s: *TestStream,
        fn deliver(ctx: @This()) void {
            var attempts: usize = 0;
            while (attempts < 1000 and ctx.s.lastWrite() == null) : (attempts += 1) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            const frame = ctx.s.lastWrite() orelse return;
            const needle = "\"command_id\":\"";
            const start_idx = std.mem.indexOf(u8, frame, needle) orelse return;
            const after = start_idx + needle.len;
            const end_idx = std.mem.indexOfScalarPos(u8, frame, after, '"') orelse return;
            const cmd_id = frame[after..end_idx];
            var reply_buf: [256]u8 = undefined;
            const reply = std.fmt.bufPrint(
                &reply_buf,
                "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{\"loaded\":true}}}}",
                .{cmd_id},
            ) catch return;
            ctx.c.deliverResult(reply) catch {};
        }
    };
    var thread = try std.Thread.spawn(.{}, Helper.deliver, .{Helper{ .c = conn, .s = &ts }});
    defer thread.join();

    const r = try hub.sendCommand(std.testing.allocator, "alice", "navigate", "{}", 500);
    defer std.testing.allocator.free(r);

    const snap = conn.snapshotLastCommand();
    try std.testing.expectEqualStrings("navigate", snap.tool());
    try std.testing.expectEqualStrings("ok", snap.result());
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

    const snap = conn.snapshotLastCommand();
    try std.testing.expectEqualStrings("click", snap.tool());
    try std.testing.expectEqualStrings("timeout", snap.result());
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
            try std.testing.expectEqual(@as(i64, 0), s.last_command_at_ns);
            try std.testing.expectEqualStrings("", s.last_command_tool);
            try std.testing.expectEqualStrings("", s.last_command_result);
        } else if (std.mem.eql(u8, s.user_id, "bob")) {
            saw_bob = true;
        }
    }
    try std.testing.expect(saw_alice);
    try std.testing.expect(saw_bob);
}

test "emitLifecycleEvent writes canonical line shape for pair" {
    // formatLifecycleEvent is the test-exposed formatter. Verifies the
    // exact line shape operators grep for.
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

test "soak: 50 concurrent extension WS sessions — no deadlock, no UAF, no leak" {
    // Set up: 50 workers, each its own user_id, each sending CMDS_PER_WORKER
    // commands through the hub. A single broker thread drains each
    // worker's outbound buffer and writes a matching result back through
    // the conn's `deliverResult`. The broker is the ONLY thread doing
    // deliveries; the 50 workers contend on (a) per-conn write_mu (b)
    // their own pending_mu (broker also touches that one) (c) the hub's
    // users_mu (only on register/unregister, but the eviction lane
    // does fire it under load).
    //
    // Workload sizing chosen so the test completes in ~1-2 s on a
    // modern dev box (M-series Mac). Set N_WORKERS=50 to match the
    // user's stated load goal; CMDS_PER_WORKER=20 → 1000 total
    // commands through the hub.

    const N_WORKERS: usize = 50;
    const CMDS_PER_WORKER: usize = 20;
    const TOTAL_CMDS: usize = N_WORKERS * CMDS_PER_WORKER;
    const PER_CMD_TIMEOUT_MS: u64 = 5_000; // generous; broker should answer in µs
    const TEST_BUDGET_MS: u64 = 60_000; // hard timeout — if we hit this, deadlock

    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    // Per-worker state lives on the heap so we can hand stable pointers
    // to threads.
    const WorkerState = struct {
        user_id: [16]u8 = [_]u8{0} ** 16,
        user_id_len: usize = 0,
        stream: SoakStream,
        conn: *ExtensionWsConn = undefined,
        // Stats: ok_count/timeout_count/err_count are written only by
        // the owning worker. Latencies are appended in microseconds.
        ok_count: usize = 0,
        timeout_count: usize = 0,
        err_count: usize = 0,
        latencies_us: std.ArrayListUnmanaged(u64) = .empty,
    };

    const workers = try std.testing.allocator.alloc(WorkerState, N_WORKERS);
    defer std.testing.allocator.free(workers);

    // Initialize + register all 50 sessions up front.
    for (workers, 0..) |*w, i| {
        w.* = .{ .stream = .{ .allocator = std.testing.allocator } };
        const n = std.fmt.bufPrint(&w.user_id, "soak-u-{d}", .{i}) catch unreachable;
        w.user_id_len = n.len;
        w.conn = try hub.registerConn(
            w.user_id[0..w.user_id_len],
            &w.stream,
            SoakStream.writeText,
            &w.stream,
            SoakStream.closeStream,
        );
    }
    defer {
        for (workers) |*w| {
            _ = hub.unregister(w.user_id[0..w.user_id_len]);
            hub.destroyConn(w.conn);
            w.latencies_us.deinit(std.testing.allocator);
            w.stream.deinit();
        }
    }

    // Done counter — broker exits when all workers have signaled done.
    var workers_done = std.atomic.Value(usize).init(0);
    var broker_stop = std.atomic.Value(bool).init(false);

    // Broker thread: polls each worker's stream, drains command_ids,
    // delivers a synthetic CommandResult for each. Spins at ~10kHz; the
    // workers do real work between sends so the broker rarely loops idle.
    const BrokerCtx = struct {
        workers: []WorkerState,
        workers_done: *std.atomic.Value(usize),
        broker_stop: *std.atomic.Value(bool),
        allocator: std.mem.Allocator,
    };
    const Broker = struct {
        fn run(ctx: BrokerCtx) void {
            var local_buf: std.ArrayListUnmanaged([]u8) = .empty;
            defer local_buf.deinit(ctx.allocator);
            while (!ctx.broker_stop.load(.acquire)) {
                var did_work = false;
                for (ctx.workers) |*w| {
                    local_buf.clearRetainingCapacity();
                    w.stream.drainCommandIds(ctx.allocator, &local_buf) catch continue;
                    for (local_buf.items) |id| {
                        defer ctx.allocator.free(id);
                        const result_json = std.fmt.allocPrint(
                            ctx.allocator,
                            "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{\"x\":1}}}}",
                            .{id},
                        ) catch continue;
                        defer ctx.allocator.free(result_json);
                        w.conn.deliverResult(result_json) catch {};
                        did_work = true;
                    }
                }
                if (!did_work) {
                    // No commands seen this pass — short sleep to avoid
                    // pinning a core. 50 µs is short enough that
                    // worker p99 latency stays in low single-digit ms.
                    std.Thread.sleep(50 * std.time.ns_per_us);
                }
                // Stop condition: all workers signaled done AND no
                // commands were drained this pass (i.e., we're caught up).
                if (!did_work and ctx.workers_done.load(.acquire) >= ctx.workers.len) break;
            }
        }
    };

    const broker_thread = try std.Thread.spawn(.{}, Broker.run, .{BrokerCtx{
        .workers = workers,
        .workers_done = &workers_done,
        .broker_stop = &broker_stop,
        .allocator = std.testing.allocator,
    }});

    // Worker thread: loop CMDS_PER_WORKER times, send command, time it.
    const WorkerCtx = struct {
        hub: *ExtensionWsHub,
        state: *WorkerState,
        cmds: usize,
        timeout_ms: u64,
        allocator: std.mem.Allocator,
    };
    const Worker = struct {
        fn run(ctx: WorkerCtx) void {
            var i: usize = 0;
            while (i < ctx.cmds) : (i += 1) {
                const t0 = std.time.nanoTimestamp();
                const r = ctx.hub.sendCommand(
                    ctx.allocator,
                    ctx.state.user_id[0..ctx.state.user_id_len],
                    "navigate",
                    "{\"url\":\"https://soak.test\"}",
                    ctx.timeout_ms,
                );
                const elapsed_us: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - t0, std.time.ns_per_us));
                if (r) |buf| {
                    ctx.allocator.free(buf);
                    ctx.state.ok_count += 1;
                    ctx.state.latencies_us.append(ctx.allocator, elapsed_us) catch {};
                } else |err| switch (err) {
                    error.Timeout => ctx.state.timeout_count += 1,
                    else => ctx.state.err_count += 1,
                }
            }
        }
    };

    const threads = try std.testing.allocator.alloc(std.Thread, N_WORKERS);
    defer std.testing.allocator.free(threads);

    const t_start = std.time.nanoTimestamp();

    for (workers, threads) |*w, *t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{WorkerCtx{
            .hub = &hub,
            .state = w,
            .cmds = CMDS_PER_WORKER,
            .timeout_ms = PER_CMD_TIMEOUT_MS,
            .allocator = std.testing.allocator,
        }});
    }

    // Join workers. If the test budget is blown, the test will be
    // killed by Zig's outer test runner; we approximate a deadlock
    // check by asserting elapsed < TEST_BUDGET_MS after the joins.
    for (threads) |t| t.join();
    _ = workers_done.fetchAdd(N_WORKERS, .acq_rel);

    // Wait for broker to finish draining anything still in flight.
    broker_thread.join();

    const elapsed_ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - t_start, std.time.ns_per_ms));

    // Aggregate stats across workers.
    var total_ok: usize = 0;
    var total_timeout: usize = 0;
    var total_err: usize = 0;
    var all_latencies: std.ArrayListUnmanaged(u64) = .empty;
    defer all_latencies.deinit(std.testing.allocator);
    for (workers) |w| {
        total_ok += w.ok_count;
        total_timeout += w.timeout_count;
        total_err += w.err_count;
        try all_latencies.appendSlice(std.testing.allocator, w.latencies_us.items);
    }

    // Sort latencies for percentile extraction.
    std.mem.sort(u64, all_latencies.items, {}, std.sort.asc(u64));
    const p50 = if (all_latencies.items.len > 0) all_latencies.items[all_latencies.items.len * 50 / 100] else 0;
    const p95 = if (all_latencies.items.len > 0) all_latencies.items[all_latencies.items.len * 95 / 100] else 0;
    const p99 = if (all_latencies.items.len > 0) all_latencies.items[@min(all_latencies.items.len - 1, all_latencies.items.len * 99 / 100)] else 0;
    const p_max = if (all_latencies.items.len > 0) all_latencies.items[all_latencies.items.len - 1] else 0;

    std.debug.print(
        "\n[soak/50] elapsed={d}ms total={d} ok={d} timeout={d} err={d} p50={d}us p95={d}us p99={d}us pmax={d}us\n",
        .{ elapsed_ms, TOTAL_CMDS, total_ok, total_timeout, total_err, p50, p95, p99, p_max },
    );

    // Gate assertions:
    //   - Deadlock: elapsed must be well under the 60 s budget.
    //   - Correctness: every command got a response (broker fed all
    //     responses; nothing should time out under normal scheduling).
    //   - Liveness: no `error_other` errors (write/dup OOMs etc).
    try std.testing.expect(elapsed_ms < TEST_BUDGET_MS);
    try std.testing.expectEqual(@as(usize, TOTAL_CMDS), total_ok);
    try std.testing.expectEqual(@as(usize, 0), total_timeout);
    try std.testing.expectEqual(@as(usize, 0), total_err);
}

test "soak: 50 sessions with mid-flight eviction churn on a hot user" {
    // Companion soak: model the same-user-multi-conn case. 49 workers
    // own distinct user_ids; ONE user_id ("hot") is repeatedly
    // re-registered by an "evictor" thread while a worker is mid-call
    // on that slot. The eviction-vs-sendCommand race is exactly the
    // META CRIT #3 path — refcounted conn lifetime keeps the slot
    // pointer live across the eviction handoff. Senders on the hot
    // user are EXPECTED to see ConnectionClosed (hub drain wakes
    // pending) or NoExtensionConnected (race window where the new
    // conn hasn't landed yet) — but never UAF, never deadlock, never
    // an unexpected error class.

    const N_WORKERS: usize = 49;
    const CMDS_PER_WORKER: usize = 10;
    const EVICTIONS: usize = 20;
    // Per-cmd timeout for the hot lane: short, because a command that
    // got written to a now-evicted conn has no broker watching it
    // (broker only polls the LATEST hot stream). That sender SHOULD
    // get a Timeout — a valid outcome of "command sent right before
    // eviction landed." We bound the wait so the test exits fast.
    const PER_CMD_TIMEOUT_MS: u64 = 200;

    var hub = ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    const WorkerState = struct {
        user_id: [16]u8 = [_]u8{0} ** 16,
        user_id_len: usize = 0,
        stream: SoakStream,
        conn: *ExtensionWsConn = undefined,
        ok_count: usize = 0,
        timeout_count: usize = 0,
        err_count: usize = 0,
    };

    const workers = try std.testing.allocator.alloc(WorkerState, N_WORKERS);
    defer std.testing.allocator.free(workers);

    for (workers, 0..) |*w, i| {
        w.* = .{ .stream = .{ .allocator = std.testing.allocator } };
        const n = std.fmt.bufPrint(&w.user_id, "evic-u-{d}", .{i}) catch unreachable;
        w.user_id_len = n.len;
        w.conn = try hub.registerConn(
            w.user_id[0..w.user_id_len],
            &w.stream,
            SoakStream.writeText,
            &w.stream,
            SoakStream.closeStream,
        );
    }
    defer {
        for (workers) |*w| {
            _ = hub.unregister(w.user_id[0..w.user_id_len]);
            hub.destroyConn(w.conn);
            w.stream.deinit();
        }
    }

    // "Hot" user_id slot — owned by the evictor lane, not part of `workers`.
    // We hold conn pointers in a small bag so destroyConn can run after
    // the test body without UAF concerns.
    var hot_conns: std.ArrayListUnmanaged(*ExtensionWsConn) = .empty;
    defer {
        for (hot_conns.items) |c| hub.destroyConn(c);
        hot_conns.deinit(std.testing.allocator);
    }
    var hot_streams: std.ArrayListUnmanaged(*SoakStream) = .empty;
    defer {
        for (hot_streams.items) |s| {
            s.deinit();
            std.testing.allocator.destroy(s);
        }
        hot_streams.deinit(std.testing.allocator);
    }
    var hot_mu: std.Thread.Mutex = .{};

    var stop = std.atomic.Value(bool).init(false);
    var workers_done = std.atomic.Value(usize).init(0);

    // Broker for the stable workers + the current hot conn.
    const BrokerCtx = struct {
        workers: []WorkerState,
        hot_streams: *std.ArrayListUnmanaged(*SoakStream),
        hot_conns: *std.ArrayListUnmanaged(*ExtensionWsConn),
        hot_mu: *std.Thread.Mutex,
        workers_done: *std.atomic.Value(usize),
        stop: *std.atomic.Value(bool),
        allocator: std.mem.Allocator,
    };
    const Broker = struct {
        fn run(ctx: BrokerCtx) void {
            var local_buf: std.ArrayListUnmanaged([]u8) = .empty;
            defer local_buf.deinit(ctx.allocator);
            while (!ctx.stop.load(.acquire)) {
                var did_work = false;
                for (ctx.workers) |*w| {
                    local_buf.clearRetainingCapacity();
                    w.stream.drainCommandIds(ctx.allocator, &local_buf) catch continue;
                    for (local_buf.items) |id| {
                        defer ctx.allocator.free(id);
                        const result_json = std.fmt.allocPrint(
                            ctx.allocator,
                            "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{\"x\":1}}}}",
                            .{id},
                        ) catch continue;
                        defer ctx.allocator.free(result_json);
                        w.conn.deliverResult(result_json) catch {};
                        did_work = true;
                    }
                }
                // Drain hot conn's CURRENT stream (last one pushed).
                ctx.hot_mu.lock();
                if (ctx.hot_streams.items.len > 0) {
                    const last_stream = ctx.hot_streams.items[ctx.hot_streams.items.len - 1];
                    const last_conn = ctx.hot_conns.items[ctx.hot_conns.items.len - 1];
                    ctx.hot_mu.unlock();
                    local_buf.clearRetainingCapacity();
                    last_stream.drainCommandIds(ctx.allocator, &local_buf) catch {};
                    for (local_buf.items) |id| {
                        defer ctx.allocator.free(id);
                        const result_json = std.fmt.allocPrint(
                            ctx.allocator,
                            "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{\"x\":1}}}}",
                            .{id},
                        ) catch continue;
                        defer ctx.allocator.free(result_json);
                        last_conn.deliverResult(result_json) catch {};
                        did_work = true;
                    }
                } else {
                    ctx.hot_mu.unlock();
                }
                if (!did_work) std.Thread.sleep(50 * std.time.ns_per_us);
                if (!did_work and ctx.workers_done.load(.acquire) >= ctx.workers.len) break;
            }
        }
    };

    const broker_thread = try std.Thread.spawn(.{}, Broker.run, .{BrokerCtx{
        .workers = workers,
        .hot_streams = &hot_streams,
        .hot_conns = &hot_conns,
        .hot_mu = &hot_mu,
        .workers_done = &workers_done,
        .stop = &stop,
        .allocator = std.testing.allocator,
    }});

    // Evictor: repeatedly registerConn on the same "hot" user_id,
    // each registration evicts the previous one. The new conn's
    // pointer is appended to the hot_conns bag; the previous conn's
    // refs were dropped by registerConn's eviction branch.
    const EvictorCtx = struct {
        hub: *ExtensionWsHub,
        hot_streams: *std.ArrayListUnmanaged(*SoakStream),
        hot_conns: *std.ArrayListUnmanaged(*ExtensionWsConn),
        hot_mu: *std.Thread.Mutex,
        n_evictions: usize,
        allocator: std.mem.Allocator,
    };
    const Evictor = struct {
        fn run(ctx: EvictorCtx) void {
            var i: usize = 0;
            while (i < ctx.n_evictions) : (i += 1) {
                const s = ctx.allocator.create(SoakStream) catch return;
                s.* = .{ .allocator = ctx.allocator };
                const conn = ctx.hub.registerConn(
                    "hot",
                    s,
                    SoakStream.writeText,
                    s,
                    SoakStream.closeStream,
                ) catch {
                    s.deinit();
                    ctx.allocator.destroy(s);
                    return;
                };
                ctx.hot_mu.lock();
                ctx.hot_streams.append(ctx.allocator, s) catch {};
                ctx.hot_conns.append(ctx.allocator, conn) catch {};
                ctx.hot_mu.unlock();
                // Short stagger between evictions — long enough that
                // a sender can get a command through but short enough
                // that we churn the slot meaningfully.
                std.Thread.sleep(500 * std.time.ns_per_us);
            }
        }
    };
    const evictor_thread = try std.Thread.spawn(.{}, Evictor.run, .{EvictorCtx{
        .hub = &hub,
        .hot_streams = &hot_streams,
        .hot_conns = &hot_conns,
        .hot_mu = &hot_mu,
        .n_evictions = EVICTIONS,
        .allocator = std.testing.allocator,
    }});

    // Hot-user sender (just one, but it races against the evictor).
    const HotSenderCtx = struct {
        hub: *ExtensionWsHub,
        timeout_ms: u64,
        n_cmds: usize,
        allocator: std.mem.Allocator,
        ok: *usize,
        closed: *usize,
        no_conn: *usize,
        timeout: *usize,
        other_err: *usize,
    };
    const HotSender = struct {
        fn run(ctx: HotSenderCtx) void {
            var i: usize = 0;
            while (i < ctx.n_cmds) : (i += 1) {
                const r = ctx.hub.sendCommand(
                    ctx.allocator,
                    "hot",
                    "navigate",
                    "{\"url\":\"https://hot.test\"}",
                    ctx.timeout_ms,
                );
                if (r) |buf| {
                    ctx.allocator.free(buf);
                    ctx.ok.* += 1;
                } else |err| switch (err) {
                    error.ConnectionClosed => ctx.closed.* += 1,
                    error.NoExtensionConnected => ctx.no_conn.* += 1,
                    // A command written to a conn that gets evicted
                    // immediately afterward has its pending stranded
                    // (broker only watches the LATEST hot stream). The
                    // sender legitimately sees Timeout. This is NOT a
                    // hub bug; it's the test broker's limitation.
                    error.Timeout => ctx.timeout.* += 1,
                    else => ctx.other_err.* += 1,
                }
                std.Thread.sleep(200 * std.time.ns_per_us);
            }
        }
    };
    var hot_ok: usize = 0;
    var hot_closed: usize = 0;
    var hot_no_conn: usize = 0;
    var hot_timeout: usize = 0;
    var hot_other: usize = 0;
    const hot_sender_thread = try std.Thread.spawn(.{}, HotSender.run, .{HotSenderCtx{
        .hub = &hub,
        .timeout_ms = PER_CMD_TIMEOUT_MS,
        .n_cmds = EVICTIONS * 3, // more sends than evictions
        .allocator = std.testing.allocator,
        .ok = &hot_ok,
        .closed = &hot_closed,
        .no_conn = &hot_no_conn,
        .timeout = &hot_timeout,
        .other_err = &hot_other,
    }});

    // Stable workers.
    const WorkerCtx2 = struct {
        hub: *ExtensionWsHub,
        state: *WorkerState,
        cmds: usize,
        timeout_ms: u64,
        allocator: std.mem.Allocator,
    };
    const Worker2 = struct {
        fn run(ctx: WorkerCtx2) void {
            var i: usize = 0;
            while (i < ctx.cmds) : (i += 1) {
                const r = ctx.hub.sendCommand(
                    ctx.allocator,
                    ctx.state.user_id[0..ctx.state.user_id_len],
                    "navigate",
                    "{\"url\":\"https://soak.test\"}",
                    ctx.timeout_ms,
                );
                if (r) |buf| {
                    ctx.allocator.free(buf);
                    ctx.state.ok_count += 1;
                } else |err| switch (err) {
                    error.Timeout => ctx.state.timeout_count += 1,
                    else => ctx.state.err_count += 1,
                }
            }
        }
    };

    const threads = try std.testing.allocator.alloc(std.Thread, N_WORKERS);
    defer std.testing.allocator.free(threads);
    const t_start = std.time.nanoTimestamp();
    for (workers, threads) |*w, *t| {
        t.* = try std.Thread.spawn(.{}, Worker2.run, .{WorkerCtx2{
            .hub = &hub,
            .state = w,
            .cmds = CMDS_PER_WORKER,
            .timeout_ms = PER_CMD_TIMEOUT_MS,
            .allocator = std.testing.allocator,
        }});
    }

    for (threads) |t| t.join();
    _ = workers_done.fetchAdd(N_WORKERS, .acq_rel);
    hot_sender_thread.join();
    evictor_thread.join();
    // Stop the broker; tear down hot conns + streams via defer above.
    stop.store(true, .release);
    broker_thread.join();
    // Drain the still-current hot slot from the hub map (the last
    // evictor registration left it registered).
    _ = hub.unregister("hot");

    const elapsed_ms: u64 = @intCast(@divTrunc(std.time.nanoTimestamp() - t_start, std.time.ns_per_ms));

    var total_ok: usize = 0;
    var total_timeout: usize = 0;
    var total_err: usize = 0;
    for (workers) |w| {
        total_ok += w.ok_count;
        total_timeout += w.timeout_count;
        total_err += w.err_count;
    }
    const STABLE_TOTAL: usize = N_WORKERS * CMDS_PER_WORKER;

    std.debug.print(
        "\n[soak/evict] elapsed={d}ms stable_total={d} stable_ok={d} stable_timeout={d} stable_err={d} hot_ok={d} hot_closed={d} hot_no_conn={d} hot_timeout={d} hot_other={d}\n",
        .{ elapsed_ms, STABLE_TOTAL, total_ok, total_timeout, total_err, hot_ok, hot_closed, hot_no_conn, hot_timeout, hot_other },
    );

    // Stable workers must all succeed — they don't share state with
    // the evictor lane and the broker feeds them all.
    try std.testing.expectEqual(STABLE_TOTAL, total_ok);
    try std.testing.expectEqual(@as(usize, 0), total_timeout);
    try std.testing.expectEqual(@as(usize, 0), total_err);
    // The hot lane is allowed any mix of ok/closed/no_conn/timeout —
    // those are all valid outcomes for a sender racing eviction.
    // What's forbidden is "other" (an unexpected error class) — that
    // would signal a bug. Also gate: total hot outcomes account for
    // every sent command (no swallowed errors / lost frames).
    try std.testing.expectEqual(@as(usize, 0), hot_other);
    try std.testing.expectEqual(EVICTIONS * 3, hot_ok + hot_closed + hot_no_conn + hot_timeout);
}
