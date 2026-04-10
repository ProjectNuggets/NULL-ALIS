//! Task ledger — durable in-memory store for spawned/detached work lifecycle.
//!
//! Tracks tasks through 7 states (queued, running, succeeded, failed,
//! timed_out, cancelled, lost) with state machine enforcement.
//! MAX_TASKS cap prevents unbounded growth (T-02-06).

const std = @import("std");

// ── TaskStatus ───────────────────────────────────────────────────────

pub const TaskStatus = enum {
    queued,
    running,
    succeeded,
    failed,
    timed_out,
    cancelled,
    lost,

    pub fn toSlice(self: TaskStatus) []const u8 {
        return switch (self) {
            .queued => "queued",
            .running => "running",
            .succeeded => "succeeded",
            .failed => "failed",
            .timed_out => "timed_out",
            .cancelled => "cancelled",
            .lost => "lost",
        };
    }

    pub fn fromString(s: []const u8) ?TaskStatus {
        const map = std.StaticStringMap(TaskStatus).initComptime(.{
            .{ "queued", .queued },
            .{ "running", .running },
            .{ "succeeded", .succeeded },
            .{ "failed", .failed },
            .{ "timed_out", .timed_out },
            .{ "cancelled", .cancelled },
            .{ "lost", .lost },
        });
        return map.get(s);
    }

    pub fn isTerminal(self: TaskStatus) bool {
        return switch (self) {
            .succeeded, .failed, .timed_out, .cancelled, .lost => true,
            .queued, .running => false,
        };
    }
};

// ── TaskEntry ────────────────────────────────────────────────────────

pub const TASK_ID_LEN: usize = 16;

pub const TaskEntry = struct {
    task_id: [TASK_ID_LEN]u8,
    description: []const u8,
    status: TaskStatus,
    owner_session: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    result_summary: ?[]const u8 = null,
    error_message: ?[]const u8 = null,

    pub fn taskIdSlice(self: *const TaskEntry) []const u8 {
        return &self.task_id;
    }
};

// ── TaskLedger ───────────────────────────────────────────────────────

pub const MAX_TASKS: usize = 256;
pub const LOST_TIMEOUT_MS: i64 = 300_000; // 5 minutes

fn validateTransition(from: TaskStatus, to: TaskStatus) !void {
    const valid = switch (to) {
        .running => from == .queued,
        .succeeded, .failed, .timed_out => from == .running,
        .cancelled => from == .queued or from == .running,
        .lost => from == .running,
        .queued => false,
    };
    if (!valid) return error.InvalidTransition;
}

pub const TaskLedger = struct {
    entries: std.ArrayListUnmanaged(TaskEntry),
    allocator: std.mem.Allocator,
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator) TaskLedger {
        return .{
            .entries = .{},
            .allocator = allocator,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *TaskLedger) void {
        self.entries.deinit(self.allocator);
    }

    pub fn createTask(self: *TaskLedger, description: []const u8, owner_session: []const u8) !*TaskEntry {
        if (self.entries.items.len >= MAX_TASKS) return error.LedgerFull;

        const now = std.time.milliTimestamp();
        try self.entries.append(self.allocator, .{
            .task_id = undefined,
            .description = description,
            .status = .queued,
            .owner_session = owner_session,
            .created_at_ms = now,
            .updated_at_ms = now,
        });

        const entry = &self.entries.items[self.entries.items.len - 1];
        _ = std.fmt.bufPrint(&entry.task_id, "task_{x:0>11}", .{self.next_id}) catch unreachable;
        self.next_id += 1;

        return entry;
    }

    fn findIndex(self: *const TaskLedger, task_id: []const u8) ?usize {
        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, &entry.task_id, task_id)) return i;
        }
        return null;
    }

    pub fn getTask(self: *const TaskLedger, task_id: []const u8) ?*const TaskEntry {
        const idx = self.findIndex(task_id) orelse return null;
        return &self.entries.items[idx];
    }

    pub fn getTaskMut(self: *TaskLedger, task_id: []const u8) ?*TaskEntry {
        const idx = self.findIndex(task_id) orelse return null;
        return &self.entries.items[idx];
    }

    pub fn markRunning(self: *TaskLedger, task_id: []const u8) !void {
        const entry = self.getTaskMut(task_id) orelse return error.TaskNotFound;
        try validateTransition(entry.status, .running);
        entry.status = .running;
        entry.updated_at_ms = std.time.milliTimestamp();
    }

    pub fn markSucceeded(self: *TaskLedger, task_id: []const u8, result: ?[]const u8) !void {
        const entry = self.getTaskMut(task_id) orelse return error.TaskNotFound;
        try validateTransition(entry.status, .succeeded);
        entry.status = .succeeded;
        entry.result_summary = result;
        entry.updated_at_ms = std.time.milliTimestamp();
    }

    pub fn markFailed(self: *TaskLedger, task_id: []const u8, err_msg: ?[]const u8) !void {
        const entry = self.getTaskMut(task_id) orelse return error.TaskNotFound;
        try validateTransition(entry.status, .failed);
        entry.status = .failed;
        entry.error_message = err_msg;
        entry.updated_at_ms = std.time.milliTimestamp();
    }

    pub fn markTimedOut(self: *TaskLedger, task_id: []const u8) !void {
        const entry = self.getTaskMut(task_id) orelse return error.TaskNotFound;
        try validateTransition(entry.status, .timed_out);
        entry.status = .timed_out;
        entry.updated_at_ms = std.time.milliTimestamp();
    }

    pub fn markCancelled(self: *TaskLedger, task_id: []const u8) !void {
        const entry = self.getTaskMut(task_id) orelse return error.TaskNotFound;
        try validateTransition(entry.status, .cancelled);
        entry.status = .cancelled;
        entry.updated_at_ms = std.time.milliTimestamp();
    }

    pub fn listTasks(self: *const TaskLedger) []const TaskEntry {
        return self.entries.items;
    }

    pub fn sweepLost(self: *TaskLedger, now_ms: i64) usize {
        var swept: usize = 0;
        for (self.entries.items) |*entry| {
            if (entry.status == .running and (now_ms - entry.updated_at_ms) > LOST_TIMEOUT_MS) {
                entry.status = .lost;
                entry.updated_at_ms = now_ms;
                swept += 1;
            }
        }
        return swept;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "TaskStatus has exactly 7 variants" {
    const fields = @typeInfo(TaskStatus).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 7), fields.len);
}

test "TaskStatus.toSlice returns correct strings" {
    try std.testing.expectEqualStrings("queued", TaskStatus.queued.toSlice());
    try std.testing.expectEqualStrings("running", TaskStatus.running.toSlice());
    try std.testing.expectEqualStrings("succeeded", TaskStatus.succeeded.toSlice());
    try std.testing.expectEqualStrings("failed", TaskStatus.failed.toSlice());
    try std.testing.expectEqualStrings("timed_out", TaskStatus.timed_out.toSlice());
    try std.testing.expectEqualStrings("cancelled", TaskStatus.cancelled.toSlice());
    try std.testing.expectEqualStrings("lost", TaskStatus.lost.toSlice());
}

test "TaskStatus.fromString roundtrips" {
    const variants = [_][]const u8{ "queued", "running", "succeeded", "failed", "timed_out", "cancelled", "lost" };
    for (variants) |name| {
        const status = TaskStatus.fromString(name) orelse return error.ParseFailed;
        try std.testing.expectEqualStrings(name, status.toSlice());
    }
}

test "TaskStatus.fromString returns null for unknown" {
    try std.testing.expect(TaskStatus.fromString("bogus") == null);
}

test "TaskStatus.isTerminal" {
    try std.testing.expect(!TaskStatus.queued.isTerminal());
    try std.testing.expect(!TaskStatus.running.isTerminal());
    try std.testing.expect(TaskStatus.succeeded.isTerminal());
    try std.testing.expect(TaskStatus.failed.isTerminal());
    try std.testing.expect(TaskStatus.timed_out.isTerminal());
    try std.testing.expect(TaskStatus.cancelled.isTerminal());
    try std.testing.expect(TaskStatus.lost.isTerminal());
}

test "TaskEntry.taskIdSlice returns id buffer" {
    var entry = TaskEntry{
        .task_id = "task_00000000001".*,
        .description = "test",
        .status = .queued,
        .owner_session = "s1",
        .created_at_ms = 0,
        .updated_at_ms = 0,
    };
    try std.testing.expectEqual(@as(usize, TASK_ID_LEN), entry.taskIdSlice().len);
}

test "TaskLedger.createTask returns queued task with unique id" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    const t1 = try ledger_inst.createTask("first task", "session-a");
    try std.testing.expectEqual(TaskStatus.queued, t1.status);
    try std.testing.expectEqualStrings("first task", t1.description);
    // Copy id before next createTask (append may reallocate, invalidating t1)
    const id1 = t1.task_id;

    const t2 = try ledger_inst.createTask("second task", "session-a");
    try std.testing.expect(!std.mem.eql(u8, &id1, &t2.task_id));
}

test "TaskLedger.getTask returns created task" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    const t = try ledger_inst.createTask("find me", "s1");
    const id = t.task_id;
    const found = ledger_inst.getTask(&id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("find me", found.?.description);
}

test "TaskLedger.getTask returns null for unknown id" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    try std.testing.expect(ledger_inst.getTask("nonexistent_0000") == null);
}

test "TaskLedger.markRunning transitions queued -> running" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    const t = try ledger_inst.createTask("run me", "s1");
    const id_buf = t.task_id;
    try ledger_inst.markRunning(&id_buf);
    const updated = ledger_inst.getTask(&id_buf).?;
    try std.testing.expectEqual(TaskStatus.running, updated.status);
}

test "TaskLedger.markSucceeded transitions running -> succeeded" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    const t = try ledger_inst.createTask("succeed me", "s1");
    const id_buf = t.task_id;
    try ledger_inst.markRunning(&id_buf);
    try ledger_inst.markSucceeded(&id_buf, "all done");
    const updated = ledger_inst.getTask(&id_buf).?;
    try std.testing.expectEqual(TaskStatus.succeeded, updated.status);
    try std.testing.expectEqualStrings("all done", updated.result_summary.?);
}

test "TaskLedger.markFailed transitions running -> failed" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    const t = try ledger_inst.createTask("fail me", "s1");
    const id_buf = t.task_id;
    try ledger_inst.markRunning(&id_buf);
    try ledger_inst.markFailed(&id_buf, "boom");
    const updated = ledger_inst.getTask(&id_buf).?;
    try std.testing.expectEqual(TaskStatus.failed, updated.status);
    try std.testing.expectEqualStrings("boom", updated.error_message.?);
}

test "TaskLedger.markTimedOut transitions running -> timed_out" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    const t = try ledger_inst.createTask("timeout me", "s1");
    const id_buf = t.task_id;
    try ledger_inst.markRunning(&id_buf);
    try ledger_inst.markTimedOut(&id_buf);
    const updated = ledger_inst.getTask(&id_buf).?;
    try std.testing.expectEqual(TaskStatus.timed_out, updated.status);
}

test "TaskLedger.markCancelled from queued" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    const t = try ledger_inst.createTask("cancel me", "s1");
    const id_buf = t.task_id;
    try ledger_inst.markCancelled(&id_buf);
    const updated = ledger_inst.getTask(&id_buf).?;
    try std.testing.expectEqual(TaskStatus.cancelled, updated.status);
}

test "TaskLedger.markCancelled from running" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    const t = try ledger_inst.createTask("cancel running", "s1");
    const id_buf = t.task_id;
    try ledger_inst.markRunning(&id_buf);
    try ledger_inst.markCancelled(&id_buf);
    const updated = ledger_inst.getTask(&id_buf).?;
    try std.testing.expectEqual(TaskStatus.cancelled, updated.status);
}

test "Invalid transition returns error" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    const t = try ledger_inst.createTask("bad transition", "s1");
    const id_buf = t.task_id;
    try ledger_inst.markRunning(&id_buf);
    try ledger_inst.markSucceeded(&id_buf, null);
    // succeeded -> running should fail
    try std.testing.expectError(error.InvalidTransition, ledger_inst.markRunning(&id_buf));
}

test "TaskLedger.listTasks returns all entries" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    _ = try ledger_inst.createTask("a", "s1");
    _ = try ledger_inst.createTask("b", "s1");
    _ = try ledger_inst.createTask("c", "s1");
    try std.testing.expectEqual(@as(usize, 3), ledger_inst.listTasks().len);
}

test "TaskLedger.sweepLost marks stale running tasks" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    const t = try ledger_inst.createTask("stale", "s1");
    const id_buf = t.task_id;
    try ledger_inst.markRunning(&id_buf);

    // Manually set updated_at_ms far in the past
    const entry = ledger_inst.getTaskMut(&id_buf).?;
    entry.updated_at_ms = 0;

    const swept = ledger_inst.sweepLost(LOST_TIMEOUT_MS + 1);
    try std.testing.expectEqual(@as(usize, 1), swept);

    const updated = ledger_inst.getTask(&id_buf).?;
    try std.testing.expectEqual(TaskStatus.lost, updated.status);
}

test "TaskLedger enforces MAX_TASKS" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();

    var i: usize = 0;
    while (i < MAX_TASKS) : (i += 1) {
        _ = try ledger_inst.createTask("fill", "s1");
    }
    try std.testing.expectError(error.LedgerFull, ledger_inst.createTask("overflow", "s1"));
}
