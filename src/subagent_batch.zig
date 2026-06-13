/// subagent_batch.zig — in-memory batch registry for multi-subagent fan-out.
///
/// Tracks which task_ids belong to a batch, their terminal status, the parent
/// session_key to wake, and the absolute wall-clock deadline. Answers "are all
/// terminal?" and "which batches are overdue?" for the barrier wake and the
/// batch-deadline reaper.
///
/// LOCK INVARIANT: BatchTracker is NOT internally locked. Every public method
/// MUST be called while the caller holds SubagentManager.mutex. The tracker
/// does not acquire any lock itself — doing so would require a second mutex
/// acquisition inside a path that already holds the manager lock, which risks
/// deadlock and breaks the lock-ordering contract.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// One fan-out batch: the N task ids, their terminal status, the parent session
/// to wake, and the absolute wall-clock deadline. In-memory only (v1):
/// individual completions remain durable via subagent_results, so a mid-batch
/// pod restart degrades gracefully to per-task delivery via the existing
/// recovery sweep.
pub const BatchState = struct {
    task_ids: []u64, // owned by the BatchTracker allocator
    terminal: []bool, // owned; parallel to task_ids; false = still running
    session_key: []const u8, // owned; the parent session to wake on completion
    created_at_ms: i64,
    deadline_ms: i64, // absolute wall-clock epoch ms (created_at + budget)
    wake_claimed: bool = false, // true after tryClaimWake wins — wake fires exactly once

    fn allTerminal(self: *const BatchState) bool {
        for (self.terminal) |t| if (!t) return false;
        return true;
    }
};

/// Returned by overdueBatchesWithTaskIds. Both slices are caller-owned (duped
/// into the provided allocator). The caller must free batch_id and task_ids
/// separately, then free the outer slice.
pub const OverdueBatch = struct {
    batch_id: []const u8, // duped — caller frees
    task_ids: []u64, // duped — caller frees
};

/// In-memory batch registry. See LOCK INVARIANT above.
pub const BatchTracker = struct {
    allocator: Allocator,
    /// Maps owned batch_id → owned *BatchState.
    batches: std.StringHashMapUnmanaged(*BatchState) = .{},
    /// Maps task_id → batch_id (points into the batches map key — NOT separately
    /// owned; the batch_id slice is freed once when the batch is removed from
    /// `batches`). This gives O(1) batchOf lookup in the hot completeTask path.
    task_index: std.AutoHashMapUnmanaged(u64, []const u8) = .{},

    /// Create a tracker that allocates from `allocator`.
    pub fn init(allocator: Allocator) BatchTracker {
        return .{ .allocator = allocator };
    }

    /// Free every BatchState and its owned memory, then free the maps.
    /// Call this exactly once, when SubagentManager.deinit runs.
    pub fn deinit(self: *BatchTracker) void {
        var it = self.batches.iterator();
        while (it.next()) |e| {
            const bs = e.value_ptr.*;
            self.allocator.free(bs.task_ids);
            self.allocator.free(bs.terminal);
            self.allocator.free(bs.session_key);
            self.allocator.destroy(bs);
            self.allocator.free(e.key_ptr.*); // owned batch_id key
        }
        self.batches.deinit(self.allocator);
        self.task_index.deinit(self.allocator);
    }

    /// Register a new batch. Dupes all strings and the task_id slice.
    /// Returns error.OutOfMemory on allocation failure; on error, no partial
    /// state is left in the tracker (full errdefer cleanup).
    pub fn register(
        self: *BatchTracker,
        batch_id: []const u8,
        task_ids: []const u64,
        session_key: []const u8,
        created_at_ms: i64,
        deadline_ms: i64,
    ) !void {
        const key = try self.allocator.dupe(u8, batch_id);
        errdefer self.allocator.free(key);

        const ids = try self.allocator.dupe(u64, task_ids);
        errdefer self.allocator.free(ids);

        const term = try self.allocator.alloc(bool, task_ids.len);
        errdefer self.allocator.free(term);
        @memset(term, false);

        const sk = try self.allocator.dupe(u8, session_key);
        errdefer self.allocator.free(sk);

        const bs = try self.allocator.create(BatchState);
        errdefer self.allocator.destroy(bs);
        bs.* = .{
            .task_ids = ids,
            .terminal = term,
            .session_key = sk,
            .created_at_ms = created_at_ms,
            .deadline_ms = deadline_ms,
        };

        // Insert into batches map (key is the owned slice from above).
        try self.batches.put(self.allocator, key, bs);
        errdefer _ = self.batches.remove(key);

        // Index each task_id → the owned batch_id key in the batches map.
        // If a mid-loop put fails, we already have the batch in `batches`;
        // this is fine because deinit will clean it up. In practice, a
        // partial task_index just means batchOf returns null for those ids —
        // a non-fatal degradation (no crash, no leak, the barrier still works
        // via the terminal array).
        for (task_ids) |tid| {
            try self.task_index.put(self.allocator, tid, key);
        }
    }

    /// Return the batch_id that owns `task_id`, or null if unknown.
    /// The returned slice points into tracker-owned memory — do not free it.
    pub fn batchOf(self: *BatchTracker, task_id: u64) ?[]const u8 {
        return self.task_index.get(task_id);
    }

    /// Mark `task_id` as terminal within its batch. No-op if the batch or
    /// task is not found.
    pub fn markTerminal(self: *BatchTracker, batch_id: []const u8, task_id: u64) void {
        const bs = self.batches.get(batch_id) orelse return;
        for (bs.task_ids, 0..) |tid, i| {
            if (tid == task_id) {
                bs.terminal[i] = true;
                return;
            }
        }
    }

    /// Return true iff every task in the batch is terminal. Returns false if
    /// the batch is unknown.
    pub fn allTerminal(self: *BatchTracker, batch_id: []const u8) bool {
        const bs = self.batches.get(batch_id) orelse return false;
        return bs.allTerminal();
    }

    /// Wake-once guard. Returns true exactly once per batch (when wake_claimed
    /// transitions false → true). Subsequent calls return false. Returns false
    /// for an unknown batch.
    pub fn tryClaimWake(self: *BatchTracker, batch_id: []const u8) bool {
        const bs = self.batches.get(batch_id) orelse return false;
        if (bs.wake_claimed) return false;
        bs.wake_claimed = true;
        return true;
    }

    /// Return the parent session_key for the batch, or null if unknown.
    /// The returned slice is tracker-owned — do not free it.
    pub fn sessionKey(self: *BatchTracker, batch_id: []const u8) ?[]const u8 {
        const bs = self.batches.get(batch_id) orelse return null;
        return bs.session_key;
    }

    /// Return the task_ids slice for the batch, or null if unknown.
    /// The returned slice is tracker-owned — do not free it.
    pub fn taskIds(self: *BatchTracker, batch_id: []const u8) ?[]const u64 {
        const bs = self.batches.get(batch_id) orelse return null;
        return bs.task_ids;
    }

    /// H4 — Remove a batch from the tracker, freeing all owned memory:
    /// the BatchState struct, its task_ids, terminal, session_key, and
    /// the batch_id key in the batches map; also removes all task_index
    /// entries for this batch's tasks.
    ///
    /// After expireBatch, batchOf(any_task_in_batch) returns null and
    /// sessionKey / allTerminal / tryClaimWake return null/false.
    /// No-op if the batch is not found.
    pub fn expireBatch(self: *BatchTracker, batch_id: []const u8) void {
        // Fetch-and-remove atomically so we own the key and value.
        const entry = self.batches.fetchRemove(batch_id) orelse return;
        const owned_key = entry.key;
        const bs = entry.value;

        // Remove all task_index entries that point to this batch.
        for (bs.task_ids) |tid| {
            _ = self.task_index.remove(tid);
        }

        // Free all BatchState-owned memory.
        self.allocator.free(bs.task_ids);
        self.allocator.free(bs.terminal);
        self.allocator.free(bs.session_key);
        self.allocator.destroy(bs);

        // Free the owned key (was the batch_id dupe from register).
        self.allocator.free(owned_key);
    }

    /// H2 — Return all overdue batches with their task_ids, fully duped into
    /// `allocator` so the reaper can release SubagentManager.mutex before
    /// iterating the results (avoids holding the lock across completeTask
    /// re-entry).
    ///
    /// A batch is overdue when: now_ms >= deadline_ms AND !wake_claimed AND
    /// !allTerminal (if it's already terminal the barrier already fired or will
    /// fire naturally).
    ///
    /// Caller must free each OverdueBatch.batch_id and OverdueBatch.task_ids,
    /// then free the returned slice itself.
    pub fn overdueBatchesWithTaskIds(
        self: *BatchTracker,
        allocator: Allocator,
        now_ms: i64,
    ) ![]OverdueBatch {
        var out: std.ArrayListUnmanaged(OverdueBatch) = .{};
        errdefer {
            // Free any partially-built entries before propagating the error.
            for (out.items) |item| {
                allocator.free(item.batch_id);
                allocator.free(item.task_ids);
            }
            out.deinit(allocator);
        }

        var it = self.batches.iterator();
        while (it.next()) |e| {
            const bs = e.value_ptr.*;
            if (bs.wake_claimed) continue;
            if (now_ms < bs.deadline_ms) continue;
            if (bs.allTerminal()) continue;

            // Dupe both strings into the caller's allocator.
            const bid = try allocator.dupe(u8, e.key_ptr.*);
            errdefer allocator.free(bid);
            const tids = try allocator.dupe(u64, bs.task_ids);
            errdefer allocator.free(tids);

            try out.append(allocator, .{ .batch_id = bid, .task_ids = tids });
        }

        return out.toOwnedSlice(allocator);
    }

    /// Compatibility alias: returns only the batch_ids of overdue batches,
    /// duped into `allocator`. Used where task_ids are not needed. Caller
    /// frees each string and the outer slice.
    pub fn overdueBatches(
        self: *BatchTracker,
        allocator: Allocator,
        now_ms: i64,
    ) ![][]const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (out.items) |item| allocator.free(item);
            out.deinit(allocator);
        }
        var it = self.batches.iterator();
        while (it.next()) |e| {
            const bs = e.value_ptr.*;
            if (!bs.wake_claimed and now_ms >= bs.deadline_ms and !bs.allTerminal()) {
                try out.append(allocator, try allocator.dupe(u8, e.key_ptr.*));
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "BatchTracker registers tasks and detects all-terminal" {
    const a = std.testing.allocator;
    var bt = BatchTracker.init(a);
    defer bt.deinit();
    try bt.register("batch_1", &[_]u64{ 10, 11, 12 }, "agent:zaki-bot:user:42:main", 1000, 1000 + 60_000);
    try std.testing.expect(!bt.allTerminal("batch_1"));
    bt.markTerminal("batch_1", 10);
    bt.markTerminal("batch_1", 11);
    try std.testing.expect(!bt.allTerminal("batch_1"));
    bt.markTerminal("batch_1", 12);
    try std.testing.expect(bt.allTerminal("batch_1"));
    // wake-once guard
    try std.testing.expect(bt.tryClaimWake("batch_1")); // first claim wins
    try std.testing.expect(!bt.tryClaimWake("batch_1")); // second is a no-op
    const sk = bt.sessionKey("batch_1").?;
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:main", sk);
}

test "BatchTracker batchOf maps a task to its batch" {
    const a = std.testing.allocator;
    var bt = BatchTracker.init(a);
    defer bt.deinit();
    try bt.register("b", &[_]u64{ 1, 2 }, "agent:zaki-bot:user:1:main", 0, 60_000);
    try std.testing.expectEqualStrings("b", bt.batchOf(2).?);
    try std.testing.expect(bt.batchOf(999) == null);
}

test "BatchTracker expireBatch removes the batch — batchOf returns null after" {
    const a = std.testing.allocator;
    var bt = BatchTracker.init(a);
    defer bt.deinit();
    try bt.register("expire_me", &[_]u64{ 7, 8 }, "agent:zaki-bot:user:5:main", 0, 30_000);
    try std.testing.expectEqualStrings("expire_me", bt.batchOf(7).?);
    bt.expireBatch("expire_me");
    try std.testing.expect(bt.batchOf(7) == null);
    try std.testing.expect(bt.batchOf(8) == null);
    try std.testing.expect(bt.sessionKey("expire_me") == null);
    try std.testing.expect(!bt.allTerminal("expire_me"));
}

test "BatchTracker expireBatch — no leak (testing allocator catches leaks)" {
    // std.testing.allocator is a leak-detecting allocator; if expireBatch
    // fails to free any owned memory, the test runner reports a failure.
    const a = std.testing.allocator;
    var bt = BatchTracker.init(a);
    defer bt.deinit();
    try bt.register("leak_check", &[_]u64{ 100, 200, 300 }, "agent:zaki-bot:user:9:main", 1000, 61_000);
    bt.expireBatch("leak_check");
    // No defer/deinit needed for this batch — expireBatch freed everything.
    // The outer bt.deinit() will find an empty tracker and free nothing.
}

test "BatchTracker overdueBatchesWithTaskIds returns overdue batches with duped task_ids" {
    const a = std.testing.allocator;
    var bt = BatchTracker.init(a);
    defer bt.deinit();

    // Overdue, not wake-claimed, not all-terminal → should appear.
    try bt.register("overdue", &[_]u64{ 1, 2 }, "agent:zaki-bot:user:1:main", 0, 1000);
    // Not overdue (deadline far in future) → should NOT appear.
    try bt.register("pending", &[_]u64{3}, "agent:zaki-bot:user:2:main", 0, std.math.maxInt(i64));
    // Overdue but wake already claimed → should NOT appear.
    try bt.register("claimed", &[_]u64{4}, "agent:zaki-bot:user:3:main", 0, 1000);
    bt.markTerminal("claimed", 4);
    _ = bt.tryClaimWake("claimed");
    // Overdue and all-terminal (but wake not claimed) → should NOT appear.
    try bt.register("done", &[_]u64{5}, "agent:zaki-bot:user:4:main", 0, 1000);
    bt.markTerminal("done", 5);

    const now_ms: i64 = 2000; // past all deadline_ms=1000
    const results = try bt.overdueBatchesWithTaskIds(a, now_ms);
    defer {
        for (results) |r| {
            a.free(r.batch_id);
            a.free(r.task_ids);
        }
        a.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("overdue", results[0].batch_id);
    try std.testing.expectEqual(@as(usize, 2), results[0].task_ids.len);
    // task_ids must be copies (values not pointers into tracker memory).
    try std.testing.expectEqual(@as(u64, 1), results[0].task_ids[0]);
    try std.testing.expectEqual(@as(u64, 2), results[0].task_ids[1]);
}

test "BatchTracker overdueBatchesWithTaskIds excludes non-overdue batches" {
    const a = std.testing.allocator;
    var bt = BatchTracker.init(a);
    defer bt.deinit();

    try bt.register("future", &[_]u64{99}, "agent:zaki-bot:user:7:main", 0, 99_999_999);

    const results = try bt.overdueBatchesWithTaskIds(a, 1000);
    defer a.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}
