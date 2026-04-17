//! task_get tool — inspect a specific task by ID.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const tasks_mod = @import("../tasks/root.zig");
const TaskDelivery = tasks_mod.TaskDelivery;
const TaskEntry = tasks_mod.TaskEntry;

pub const TaskGetTool = struct {
    delivery: *TaskDelivery,

    pub const tool_name = "task_get";
    pub const tool_description = "Get details of a specific task by ID including description, status, timestamps, result summary, and error message.";
    pub const tool_params =
        \\{"type":"object","properties":{"task_id":{"type":"string","description":"The task ID to inspect"}},"required":["task_id"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *TaskGetTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *TaskGetTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const task_id = root.getString(args, "task_id") orelse
            return ToolResult.fail("task_id is required");

        // WP2.1R: take a copied snapshot rather than a borrowed pointer so a
        // concurrent subagent lifecycle update cannot mutate the entry while
        // we are serializing it.
        const snap = self.delivery.getTaskSnapshot(task_id) orelse
            return ToolResult.fail("task not found");
        const entry = &snap;

        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.writeAll("{\"task_id\":\"");
        try w.writeAll(&entry.task_id);
        try w.writeAll("\",\"description\":\"");
        try jsonEscapeInto(w, entry.description);
        try w.writeAll("\",\"status\":\"");
        try w.writeAll(entry.status.toSlice());
        try w.writeAll("\",\"owner_session\":\"");
        try jsonEscapeInto(w, entry.owner_session);
        try w.print("\",\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{ entry.created_at_ms, entry.updated_at_ms });
        if (entry.result_summary) |rs| {
            try w.writeAll(",\"result_summary\":\"");
            try jsonEscapeInto(w, rs);
            try w.writeByte('"');
        }
        if (entry.error_message) |em| {
            try w.writeAll(",\"error_message\":\"");
            try jsonEscapeInto(w, em);
            try w.writeByte('"');
        }
        try w.writeByte('}');

        return .{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

fn jsonEscapeInto(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

const observability = @import("../observability.zig");
const TaskLedger = tasks_mod.TaskLedger;

test "TaskGetTool.tool_name is task_get" {
    try std.testing.expectEqualStrings("task_get", TaskGetTool.tool_name);
}

test "TaskGetTool.execute with valid task_id returns JSON" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    const entry = try ledger_inst.createTask("my task", "session-1");
    const id = entry.task_id;

    var args = JsonObjectMap.init(allocator);
    defer args.deinit();
    try args.put("task_id", .{ .string = &id });

    var tg = TaskGetTool{ .delivery = &delivery };
    const result = try tg.execute(allocator, args);
    defer allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "my task") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "queued") != null);
}

test "TaskGetTool.execute with invalid task_id returns error" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    var args = JsonObjectMap.init(allocator);
    defer args.deinit();
    try args.put("task_id", .{ .string = "nonexistent_0000" });

    var tg = TaskGetTool{ .delivery = &delivery };
    const result = try tg.execute(allocator, args);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("task not found", result.error_msg.?);
}

test "TaskGetTool.execute without task_id returns error" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    var args = JsonObjectMap.init(allocator);
    defer args.deinit();

    var tg = TaskGetTool{ .delivery = &delivery };
    const result = try tg.execute(allocator, args);
    try std.testing.expect(!result.success);
}
