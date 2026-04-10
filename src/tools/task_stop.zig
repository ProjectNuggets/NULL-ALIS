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
    pub const tool_description = "Cancel a queued or running task. Returns error if task is already in a terminal state.";
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

        self.delivery.markCancelled(task_id) catch |err| switch (err) {
            error.InvalidTransition => return ToolResult.fail("task is already in a terminal state"),
            error.TaskNotFound => return ToolResult.fail("task not found"),
        };

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
