//! Task delivery — wraps TaskLedger + Observer for event-driven task updates.
//!
//! TaskDelivery emits a task_update ObserverEvent on every state transition,
//! bridging the ledger state machine to the run-event stream so clients see
//! real-time task status updates (REQ-005).
//!
//! Truncation: description/error fields truncated to MAX_DETAIL_LEN (256 chars)
//! before emission to prevent leaking full tool output in SSE stream (T-02-09).

const std = @import("std");
const ledger_mod = @import("ledger.zig");
const TaskLedger = ledger_mod.TaskLedger;
const TaskEntry = ledger_mod.TaskEntry;
const TaskStatus = ledger_mod.TaskStatus;
const observability = @import("../observability.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;

const MAX_DETAIL_LEN: usize = 256;

pub const TaskDelivery = struct {
    ledger: *TaskLedger,
    observer: Observer,

    pub fn createTask(self: *TaskDelivery, description: []const u8, owner_session: []const u8) ![]const u8 {
        const entry = try self.ledger.createTask(description, owner_session);
        self.emitTaskUpdate(entry.taskIdSlice(), "queued", truncate(description));
        return entry.taskIdSlice();
    }

    pub fn markRunning(self: *TaskDelivery, task_id: []const u8) !void {
        try self.ledger.markRunning(task_id);
        self.emitTaskUpdate(task_id, "running", null);
    }

    pub fn markSucceeded(self: *TaskDelivery, task_id: []const u8, result: ?[]const u8) !void {
        try self.ledger.markSucceeded(task_id, result);
        self.emitTaskUpdate(task_id, "succeeded", truncate(result));
    }

    pub fn markFailed(self: *TaskDelivery, task_id: []const u8, err_msg: ?[]const u8) !void {
        try self.ledger.markFailed(task_id, err_msg);
        self.emitTaskUpdate(task_id, "failed", truncate(err_msg));
    }

    pub fn markCancelled(self: *TaskDelivery, task_id: []const u8) !void {
        try self.ledger.markCancelled(task_id);
        self.emitTaskUpdate(task_id, "cancelled", null);
    }

    pub fn markTimedOut(self: *TaskDelivery, task_id: []const u8) !void {
        try self.ledger.markTimedOut(task_id);
        self.emitTaskUpdate(task_id, "timed_out", null);
    }

    pub fn getTask(self: *const TaskDelivery, task_id: []const u8) ?*const TaskEntry {
        return self.ledger.getTask(task_id);
    }

    pub fn listTasks(self: *const TaskDelivery) []const TaskEntry {
        return self.ledger.listTasks();
    }

    fn emitTaskUpdate(self: *TaskDelivery, task_id: []const u8, status: []const u8, detail: ?[]const u8) void {
        const event = ObserverEvent{ .task_update = .{
            .task_id = task_id,
            .status = status,
            .description = detail,
        } };
        self.observer.recordEvent(&event);
    }

    fn truncate(s: ?[]const u8) ?[]const u8 {
        const val = s orelse return null;
        if (val.len <= MAX_DETAIL_LEN) return val;
        return val[0..MAX_DETAIL_LEN];
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const TestEventCapture = struct {
    events: [32]CapturedEvent = undefined,
    count: usize = 0,

    const CapturedEvent = struct {
        task_id_buf: [16]u8 = undefined,
        task_id_len: usize = 0,
        status_buf: [32]u8 = undefined,
        status_len: usize = 0,
    };

    const vtable = Observer.VTable{
        .record_event = captureEvent,
        .record_metric = noopMetric,
        .flush = noopFlush,
        .name = captureName,
    };

    fn observer(self: *TestEventCapture) Observer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn captureEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
        const self: *TestEventCapture = @ptrCast(@alignCast(ptr));
        switch (event.*) {
            .task_update => |e| {
                if (self.count < 32) {
                    var captured = &self.events[self.count];
                    const tid_len = @min(e.task_id.len, 16);
                    @memcpy(captured.task_id_buf[0..tid_len], e.task_id[0..tid_len]);
                    captured.task_id_len = tid_len;
                    const slen = @min(e.status.len, 32);
                    @memcpy(captured.status_buf[0..slen], e.status[0..slen]);
                    captured.status_len = slen;
                    self.count += 1;
                }
            },
            else => {},
        }
    }

    fn lastStatus(self: *const TestEventCapture) []const u8 {
        if (self.count == 0) return "";
        const last = &self.events[self.count - 1];
        return last.status_buf[0..last.status_len];
    }

    fn noopMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn noopFlush(_: *anyopaque) void {}
    fn captureName(_: *anyopaque) []const u8 {
        return "test_capture";
    }
};

test "TaskDelivery.createTask emits queued event" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var capture = TestEventCapture{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = capture.observer() };

    _ = try delivery.createTask("build project", "session-1");
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("queued", capture.lastStatus());
}

test "TaskDelivery.markRunning emits running event" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var capture = TestEventCapture{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = capture.observer() };

    const entry = try ledger_inst.createTask("run me", "s1");
    const id = entry.task_id;
    try delivery.markRunning(&id);
    try std.testing.expectEqualStrings("running", capture.lastStatus());
}

test "TaskDelivery.markSucceeded emits succeeded event" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var capture = TestEventCapture{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = capture.observer() };

    const entry = try ledger_inst.createTask("succeed me", "s1");
    const id = entry.task_id;
    try ledger_inst.markRunning(&id);
    capture.count = 0; // reset
    try delivery.markSucceeded(&id, "done!");
    try std.testing.expectEqualStrings("succeeded", capture.lastStatus());
}

test "TaskDelivery.markFailed emits failed event" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var capture = TestEventCapture{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = capture.observer() };

    const entry = try ledger_inst.createTask("fail me", "s1");
    const id = entry.task_id;
    try ledger_inst.markRunning(&id);
    capture.count = 0;
    try delivery.markFailed(&id, "error occurred");
    try std.testing.expectEqualStrings("failed", capture.lastStatus());
}

test "TaskDelivery.markCancelled emits cancelled event" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var capture = TestEventCapture{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = capture.observer() };

    const entry = try ledger_inst.createTask("cancel me", "s1");
    const id = entry.task_id;
    try delivery.markCancelled(&id);
    try std.testing.expectEqualStrings("cancelled", capture.lastStatus());
}

test "Invalid transition returns error without emitting event" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var capture = TestEventCapture{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = capture.observer() };

    const entry = try ledger_inst.createTask("bad", "s1");
    const id = entry.task_id;
    try ledger_inst.markRunning(&id);
    try ledger_inst.markSucceeded(&id, null);
    capture.count = 0;
    // succeeded -> running is invalid
    try std.testing.expectError(error.InvalidTransition, delivery.markRunning(&id));
    try std.testing.expectEqual(@as(usize, 0), capture.count);
}

test "TaskDelivery.getTask delegates to ledger" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    const entry = try ledger_inst.createTask("find me", "s1");
    const id = entry.task_id;
    const found = delivery.getTask(&id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("find me", found.?.description);
}

test "TaskDelivery.listTasks delegates to ledger" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    _ = try ledger_inst.createTask("a", "s1");
    _ = try ledger_inst.createTask("b", "s1");
    try std.testing.expectEqual(@as(usize, 2), delivery.listTasks().len);
}
