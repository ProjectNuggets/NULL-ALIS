//! Task delivery — wraps TaskLedger + Observer for event-driven task updates.
//!
//! TaskDelivery emits a task_update ObserverEvent on every state transition,
//! bridging the ledger state machine to the run-event stream so clients see
//! real-time task status updates (REQ-005).
//!
//! WP2.1R: TaskDelivery owns a mutex that serializes ledger access. The
//! runtime task tools (task_list / task_get / task_stop) and the subagent
//! lifecycle bridge both flow through this mutex, so concurrent access to
//! the underlying ArrayList-backed ledger cannot race. Observer events are
//! always emitted outside the mutex to avoid lock-order deadlocks with
//! downstream consumers (SubagentManager, gateway run-event stream).
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

const log = std.log.scoped(.tasks);

// ── Owned in-memory TaskDelivery fallback (V4) ─────────────────────
//
// v1.14.18 Step 7 (V4) — the subagent ledger bridge used to be optional:
// `SubagentManager.task_delivery` defaulted to null, so the standalone
// CLI / channel-loop construction paths spawned subagents whose lifecycle
// was never mirrored into a TaskLedger. `task_list` / `task_get` then
// showed nothing for those tasks.
//
// `createOwnedFallback` returns a heap-owned `OwnedFallback` bundle (a
// fresh in-memory `TaskLedger`, a `NoopObserver`, and a `TaskDelivery`
// pointing at them). The `SubagentManager` owns it for its lifetime and
// destroys it in `deinit`. The gateway path overrides via
// `attachTaskDelivery`, at which point the owned fallback remains
// allocated but unused — the manager still owns and frees it. Two managers
// in the same process never share a ledger, so canonical task IDs (which
// restart at 1 per manager) cannot collide.

pub const OwnedFallback = struct {
    allocator: std.mem.Allocator,
    ledger: *TaskLedger,
    noop: *observability.NoopObserver,
    delivery: *TaskDelivery,

    pub fn deinit(self: *OwnedFallback) void {
        self.ledger.deinit();
        self.allocator.destroy(self.ledger);
        self.allocator.destroy(self.noop);
        self.allocator.destroy(self.delivery);
    }
};

/// Build a heap-owned fallback bundle for a SubagentManager that has no
/// canonical TaskDelivery attached. Returns null on allocation failure —
/// the caller logs and continues without a bridge.
pub fn createOwnedFallback(allocator: std.mem.Allocator) ?OwnedFallback {
    const led = allocator.create(TaskLedger) catch return null;
    led.* = TaskLedger.init(allocator);
    const noop = allocator.create(observability.NoopObserver) catch {
        allocator.destroy(led);
        return null;
    };
    noop.* = .{};
    const del = allocator.create(TaskDelivery) catch {
        allocator.destroy(noop);
        allocator.destroy(led);
        return null;
    };
    del.* = .{ .ledger = led, .observer = noop.observer() };
    return .{
        .allocator = allocator,
        .ledger = led,
        .noop = noop,
        .delivery = del,
    };
}

pub const TaskDelivery = struct {
    /// Outcome of an atomic queued-only cancel attempt. See cancelQueued.
    pub const CancelOutcome = enum {
        /// Task was queued and has been transitioned to cancelled.
        cancelled,
        /// Task exists but is running. Live interruption is not supported,
        /// so the task is left untouched.
        running,
        /// Task exists but is already in a terminal state (succeeded,
        /// failed, timed_out, cancelled, lost).
        terminal,
        /// No task with the given id is present in the ledger.
        not_found,
    };

    ledger: *TaskLedger,
    observer: Observer,
    mutex: std.Thread.Mutex = .{},

    pub fn createTask(self: *TaskDelivery, description: []const u8, owner_session: []const u8) ![]const u8 {
        var id_buf: [ledger_mod.TASK_ID_LEN]u8 = undefined;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            const entry = try self.ledger.createTask(description, owner_session);
            id_buf = entry.task_id;
        }
        self.emitTaskUpdate(&id_buf, "queued", truncate(description));
        // Return a stable slice into the ledger. Callers that intend to
        // retain the returned pointer past further ledger mutations must
        // copy it themselves — this preserves the pre-WP2.1R borrow
        // semantics for existing callers.
        return self.relocateIdSlice(&id_buf);
    }

    /// Create a canonical task entry using a caller-supplied numeric id and
    /// emit the queued task_update event. Used by the subagent bridge
    /// (WP2.1). Idempotent: if an entry with the same id already exists,
    /// it is returned without re-emitting the queued event.
    pub fn createTaskWithNumericId(
        self: *TaskDelivery,
        description: []const u8,
        owner_session: []const u8,
        numeric_id: u64,
    ) ![]const u8 {
        var id_buf: [ledger_mod.TASK_ID_LEN]u8 = undefined;
        var emit_queued = false;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            const before_len = self.ledger.entries.items.len;
            const entry = try self.ledger.createTaskWithNumericId(description, owner_session, numeric_id);
            id_buf = entry.task_id;
            emit_queued = self.ledger.entries.items.len > before_len;
        }
        if (emit_queued) {
            self.emitTaskUpdate(&id_buf, "queued", truncate(description));
        }
        return self.relocateIdSlice(&id_buf);
    }

    pub fn markRunning(self: *TaskDelivery, task_id: []const u8) !void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.ledger.markRunning(task_id);
        }
        self.emitTaskUpdate(task_id, "running", null);
    }

    pub fn markSucceeded(self: *TaskDelivery, task_id: []const u8, result: ?[]const u8) !void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.ledger.markSucceeded(task_id, result);
        }
        self.emitTaskUpdate(task_id, "succeeded", truncate(result));
    }

    pub fn markFailed(self: *TaskDelivery, task_id: []const u8, err_msg: ?[]const u8) !void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.ledger.markFailed(task_id, err_msg);
        }
        self.emitTaskUpdate(task_id, "failed", truncate(err_msg));
    }

    pub fn markCancelled(self: *TaskDelivery, task_id: []const u8) !void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.ledger.markCancelled(task_id);
        }
        self.emitTaskUpdate(task_id, "cancelled", null);
    }

    pub fn markTimedOut(self: *TaskDelivery, task_id: []const u8) !void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.ledger.markTimedOut(task_id);
        }
        self.emitTaskUpdate(task_id, "timed_out", null);
    }

    /// Atomic queued-only cancel. Used by task_stop (WP2.1R) so that the
    /// check-status and mark-cancelled steps cannot interleave with a
    /// concurrent markRunning from the subagent bridge. See CancelOutcome
    /// for result semantics.
    pub fn cancelQueued(self: *TaskDelivery, task_id: []const u8) CancelOutcome {
        const outcome = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const entry = self.ledger.getTaskMut(task_id) orelse break :blk CancelOutcome.not_found;
            if (entry.status == .running) break :blk CancelOutcome.running;
            if (entry.status.isTerminal()) break :blk CancelOutcome.terminal;
            self.ledger.markCancelled(task_id) catch break :blk CancelOutcome.terminal;
            break :blk CancelOutcome.cancelled;
        };
        if (outcome == .cancelled) {
            self.emitTaskUpdate(task_id, "cancelled", null);
        }
        return outcome;
    }

    /// Return a copied snapshot of the full ledger. Caller owns the slice
    /// and must free it with `allocator.free(slice)`. TaskEntry string
    /// fields are shallow-copied and point into ledger-owned storage
    /// (WP2.1S), so snapshot readers can safely outlive any external owner
    /// such as SubagentManager.TaskState — the strings remain valid as long
    /// as the TaskLedger itself is alive.
    pub fn listTasksSnapshot(self: *TaskDelivery, allocator: std.mem.Allocator) ![]TaskEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        const source = self.ledger.listTasks();
        const copy = try allocator.alloc(TaskEntry, source.len);
        @memcpy(copy, source);
        return copy;
    }

    /// Return a copied snapshot of a single task, or null if not present.
    /// String fields are ledger-owned (see listTasksSnapshot).
    pub fn getTaskSnapshot(self: *TaskDelivery, task_id: []const u8) ?TaskEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.ledger.getTask(task_id) orelse return null;
        return entry.*;
    }

    /// Re-locate a task_id inside the ledger to produce a pointer into the
    /// entry's `task_id` buffer. Used by createTask/createTaskWithNumericId
    /// so the returned slice preserves the pre-WP2.1R borrow semantics.
    /// Takes the mutex briefly. The returned slice points into ArrayList
    /// storage and is subject to the same borrow caveat as any ledger
    /// read: it may be invalidated by a later createTask that triggers a
    /// reallocation. Callers that need a longer-lived id must copy.
    /// Falls back to a static placeholder only if the entry is somehow
    /// missing (cannot happen for callers invoking this immediately after
    /// a successful create).
    fn relocateIdSlice(self: *TaskDelivery, id_buf: *const [ledger_mod.TASK_ID_LEN]u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.ledger.getTask(id_buf)) |entry| {
            return entry.taskIdSlice();
        }
        return "task_unknown___";
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

test "TaskDelivery.createTaskWithNumericId emits queued event with supplied id" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var capture = TestEventCapture{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = capture.observer() };

    const id = try delivery.createTaskWithNumericId("bridged work", "session-b", 99);
    try std.testing.expectEqualStrings("task_00000000063", id);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("queued", capture.lastStatus());
}

test "TaskDelivery.createTaskWithNumericId does not re-emit for duplicate ids" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var capture = TestEventCapture{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = capture.observer() };

    _ = try delivery.createTaskWithNumericId("bridged work", "session-b", 5);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    _ = try delivery.createTaskWithNumericId("bridged work", "session-b", 5);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
}

test "TaskDelivery.listTasksSnapshot returns copied entries" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    _ = try ledger_inst.createTask("a", "s1");
    _ = try ledger_inst.createTask("b", "s1");

    const snap = try delivery.listTasksSnapshot(allocator);
    defer allocator.free(snap);
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expectEqualStrings("a", snap[0].description);
    try std.testing.expectEqualStrings("b", snap[1].description);
}

test "TaskDelivery.listTasksSnapshot is stable across subsequent mutations" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    _ = try ledger_inst.createTask("original", "s1");
    const snap = try delivery.listTasksSnapshot(allocator);
    defer allocator.free(snap);

    // Mutating the ledger after the snapshot should not change the snapshot
    // entries' status — the snapshot is a copy, not a view.
    const id = snap[0].task_id;
    try delivery.markRunning(&id);
    try std.testing.expectEqual(TaskStatus.queued, snap[0].status);
}

test "TaskDelivery.getTaskSnapshot returns copied entry" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    const entry = try ledger_inst.createTask("find me", "s1");
    const id = entry.task_id;
    const snap = delivery.getTaskSnapshot(&id) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("find me", snap.description);
    try std.testing.expectEqual(TaskStatus.queued, snap.status);
}

test "TaskDelivery.getTaskSnapshot returns null for missing id" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    try std.testing.expect(delivery.getTaskSnapshot("nonexistent_0000") == null);
}

test "TaskDelivery.cancelQueued cancels queued task and emits event" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var capture = TestEventCapture{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = capture.observer() };

    const entry = try ledger_inst.createTask("cancel queued", "s1");
    const id = entry.task_id;

    try std.testing.expectEqual(TaskDelivery.CancelOutcome.cancelled, delivery.cancelQueued(&id));
    try std.testing.expectEqualStrings("cancelled", capture.lastStatus());
    try std.testing.expectEqual(TaskStatus.cancelled, ledger_inst.getTask(&id).?.status);
}

test "TaskDelivery.cancelQueued refuses running task without mutating" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var capture = TestEventCapture{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = capture.observer() };

    const entry = try ledger_inst.createTask("running", "s1");
    const id = entry.task_id;
    try ledger_inst.markRunning(&id);
    capture.count = 0;

    try std.testing.expectEqual(TaskDelivery.CancelOutcome.running, delivery.cancelQueued(&id));
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expectEqual(TaskStatus.running, ledger_inst.getTask(&id).?.status);
}

test "TaskDelivery.cancelQueued reports terminal state" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var capture = TestEventCapture{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = capture.observer() };

    const entry = try ledger_inst.createTask("done", "s1");
    const id = entry.task_id;
    try ledger_inst.markRunning(&id);
    try ledger_inst.markSucceeded(&id, null);
    capture.count = 0;

    try std.testing.expectEqual(TaskDelivery.CancelOutcome.terminal, delivery.cancelQueued(&id));
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expectEqual(TaskStatus.succeeded, ledger_inst.getTask(&id).?.status);
}

test "TaskDelivery.cancelQueued returns not_found for unknown id" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    try std.testing.expectEqual(TaskDelivery.CancelOutcome.not_found, delivery.cancelQueued("nonexistent_0000"));
}
