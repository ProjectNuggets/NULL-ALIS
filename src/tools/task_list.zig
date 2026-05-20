//! task_list tool — list spawned/detached tasks with optional status filter.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const tasks_mod = @import("../tasks/root.zig");
const TaskDelivery = tasks_mod.TaskDelivery;
const TaskStatus = tasks_mod.TaskStatus;
const TaskEntry = tasks_mod.TaskEntry;

pub const TaskListTool = struct {
    delivery: *TaskDelivery,

    pub const tool_name = "task_list";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "List all tasks with filtering and sorting options.",
        .use_when = &.{
            "first scenario",
            "second scenario",
        },
        .do_not_use_for = &.{
            "web_search — for external queries",
            "memory_store — for persistence",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("task_list", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description = "List spawned/detached tasks with optional status filter. Returns JSON array of task entries with id, description, status, timestamps.";
    pub const tool_params =
        \\{"type":"object","properties":{"status":{"type":"string","enum":["queued","running","succeeded","failed","timed_out","cancelled","lost"],"description":"Filter by task status"}}}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *TaskListTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *TaskListTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const status_filter = if (root.getString(args, "status")) |s| TaskStatus.fromString(s) else null;
        // WP2.1R: consume a snapshot instead of a borrowed ledger slice, so
        // subagent lifecycle threads can append concurrently without
        // racing the reader.
        const entries = try self.delivery.listTasksSnapshot(allocator);
        defer allocator.free(entries);

        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.writeByte('[');
        var first = true;
        for (entries) |*entry| {
            if (status_filter) |filter| {
                if (entry.status != filter) continue;
            }
            if (!first) try w.writeByte(',');
            first = false;
            try writeEntryJson(w, entry);
        }
        try w.writeByte(']');

        return .{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

fn writeEntryJson(w: anytype, entry: *const TaskEntry) !void {
    try w.writeAll("{\"task_id\":\"");
    try w.writeAll(&entry.task_id);
    try w.writeAll("\",\"description\":\"");
    try jsonEscapeInto(w, entry.description);
    try w.writeAll("\",\"status\":\"");
    try w.writeAll(entry.status.toSlice());
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
}

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

test "TaskListTool.tool_name is task_list" {
    try std.testing.expectEqualStrings("task_list", TaskListTool.tool_name);
}

test "TaskListTool.execute returns all tasks" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    _ = try ledger_inst.createTask("task A", "s1");
    _ = try ledger_inst.createTask("task B", "s1");

    var tl = TaskListTool{ .delivery = &delivery };
    var empty_args = JsonObjectMap.init(allocator);
    defer empty_args.deinit();

    const result = try tl.execute(allocator, empty_args);
    defer allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "task A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "task B") != null);
}

test "TaskListTool.execute with status filter" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    const t1 = try ledger_inst.createTask("queued task", "s1");
    const t2 = try ledger_inst.createTask("running task", "s1");
    const id2 = t2.task_id;
    _ = t1;
    try ledger_inst.markRunning(&id2);

    var args = JsonObjectMap.init(allocator);
    defer args.deinit();
    try args.put("status", .{ .string = "running" });

    var tl = TaskListTool{ .delivery = &delivery };
    const result = try tl.execute(allocator, args);
    defer allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "running task") != null);
    // queued task should not be in output
    try std.testing.expect(std.mem.indexOf(u8, result.output, "queued task") == null);
}
