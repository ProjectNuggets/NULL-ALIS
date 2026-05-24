//! task_stop tool — cancel a queued or running task.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const tasks_mod = @import("../tasks/root.zig");
const TaskDelivery = tasks_mod.TaskDelivery;

pub const TaskStopTool = struct {
    delivery: *TaskDelivery,

    pub const tool_name = "task_stop";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Cancel a QUEUED task before it starts; running tasks cannot be interrupted (returns error).",
        .use_when = &.{
            "User changed their mind about a task that was just queued via spawn",
            "Cleaning up obviously-redundant queued work before it consumes budget",
            "Cancelling a misrouted task spotted via task_list before it runs",
        },
        .do_not_use_for = &.{
            "spawn — for creating a new background task rather than cancelling one",
            "task_get — for inspecting status rather than acting on a task",
            "cron_remove — for deleting scheduled jobs rather than spawned tasks",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("task_stop", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description = "Cancel a queued task. Running tasks cannot be interrupted — returns an error if the task is already running or in a terminal state.";
    pub const tool_params =
        \\{"type":"object","properties":{"task_id":{"type":"string","description":"The task ID to cancel"}},"required":["task_id"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *TaskStopTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *TaskStopTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const task_id = root.getString(args, "task_id") orelse
            return ToolResult.fail("task_id is required");

        // WP2.1R: honest guard collapsed into a single atomic delivery
        // operation so the "is it running?" check cannot interleave with a
        // subagent lifecycle thread flipping queued → running between the
        // check and the mark-cancelled. cancelQueued refuses running tasks
        // outright (no live interruption) and does not mutate terminal or
        // missing entries.
        switch (self.delivery.cancelQueued(task_id)) {
            .cancelled => {},
            .running => return ToolResult.fail("cannot cancel a running task: live interruption is not supported"),
            .terminal => return ToolResult.fail("task is already in a terminal state"),
            .not_found => return ToolResult.fail("task not found"),
        }

        const output = try std.fmt.allocPrint(allocator, "{{\"task_id\":\"{s}\",\"status\":\"cancelled\"}}", .{task_id});
        return .{ .success = true, .output = output };
    }
};

// ── Tests ────────────────────────────────────────────────────────────

const observability = @import("../observability.zig");
const TaskLedger = tasks_mod.TaskLedger;

test "TaskStopTool.tool_name is task_stop" {
    try std.testing.expectEqualStrings("task_stop", TaskStopTool.tool_name);
}

test "TaskStopTool.execute cancels queued task" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    const entry = try ledger_inst.createTask("cancel me", "s1");
    const id = entry.task_id;

    var args = JsonObjectMap.init(allocator);
    defer args.deinit();
    try args.put("task_id", .{ .string = &id });

    var ts = TaskStopTool{ .delivery = &delivery };
    const result = try ts.execute(allocator, args);
    defer allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "cancelled") != null);
}

test "TaskStopTool.execute with invalid task_id returns error" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    var args = JsonObjectMap.init(allocator);
    defer args.deinit();
    try args.put("task_id", .{ .string = "nonexistent_0000" });

    var ts = TaskStopTool{ .delivery = &delivery };
    const result = try ts.execute(allocator, args);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("task not found", result.error_msg.?);
}

test "TaskStopTool.execute refuses to cancel running task" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    const entry = try ledger_inst.createTask("running task", "s1");
    const id = entry.task_id;
    try ledger_inst.markRunning(&id);

    var args = JsonObjectMap.init(allocator);
    defer args.deinit();
    try args.put("task_id", .{ .string = &id });

    var ts = TaskStopTool{ .delivery = &delivery };
    const result = try ts.execute(allocator, args);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "running") != null);
    // Status must stay running — the guard must not silently mutate state.
    const after = ledger_inst.getTask(&id).?;
    try std.testing.expectEqual(tasks_mod.TaskStatus.running, after.status);
}

test "TaskStopTool.execute with terminated task returns error" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    const entry = try ledger_inst.createTask("done task", "s1");
    const id = entry.task_id;
    try ledger_inst.markRunning(&id);
    try ledger_inst.markSucceeded(&id, null);

    var args = JsonObjectMap.init(allocator);
    defer args.deinit();
    try args.put("task_id", .{ .string = &id });

    var ts = TaskStopTool{ .delivery = &delivery };
    const result = try ts.execute(allocator, args);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("task is already in a terminal state", result.error_msg.?);
}
