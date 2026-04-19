const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const mem_root = @import("../memory/root.zig");
const Memory = mem_root.Memory;

/// Memory edit tool — explicitly updates an existing mutable memory by key.
pub const MemoryEditTool = struct {
    memory: ?Memory = null,
    mem_rt: ?*mem_root.MemoryRuntime = null,

    pub const tool_name = "memory_edit";
    pub const tool_description = "Edit an existing mutable memory by key. Preserves the original category and scope.";
    pub const tool_params =
        \\{"type":"object","properties":{"key":{"type":"string","description":"Existing memory key to edit"},"content":{"type":"string","description":"Replacement memory content"}},"required":["key","content"]}
    ;

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryEditTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *MemoryEditTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const key = root.getString(args, "key") orelse
            return ToolResult.fail("Missing 'key' parameter");
        if (key.len == 0) return ToolResult.fail("'key' must not be empty");

        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing 'content' parameter");
        if (content.len == 0) return ToolResult.fail("'content' must not be empty");

        const m = self.memory orelse {
            const msg = try std.fmt.allocPrint(allocator, "Memory backend not configured. Cannot edit: {s}", .{key});
            return ToolResult{ .success = false, .output = msg };
        };

        var lookup = try mem_root.lookupMemoryLifecycleEntry(allocator, m, key);
        defer lookup.deinit(allocator);
        switch (lookup.status) {
            .missing => {
                const msg = try std.fmt.allocPrint(allocator, "No memory found with key: {s}", .{key});
                return ToolResult{ .success = false, .output = msg };
            },
            .protected => {
                const msg = try std.fmt.allocPrint(allocator, "Memory key is not editable: {s}", .{key});
                return ToolResult{ .success = false, .output = msg };
            },
            .editable => {},
        }
        const existing = lookup.entry.?;

        if (std.mem.eql(u8, existing.content, content)) {
            const msg = try std.fmt.allocPrint(allocator, "Memory unchanged: {s}", .{key});
            return ToolResult{ .success = true, .output = msg };
        }

        m.store(existing.key, content, existing.category, existing.session_id) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to edit memory '{s}': {s}", .{ key, @errorName(err) });
            return ToolResult{ .success = false, .output = msg };
        };

        if (self.mem_rt) |rt| {
            _ = rt.syncVectorAfterStore(allocator, existing.key, content);
        }

        const msg = try std.fmt.allocPrint(allocator, "Edited memory: {s}", .{key});
        return ToolResult{ .success = true, .output = msg };
    }
};

test "memory_edit tool name" {
    var mt = MemoryEditTool{};
    const t = mt.tool();
    try std.testing.expectEqualStrings("memory_edit", t.name());
}

test "memory_edit updates existing mutable key" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("user_name", "Nova", .core, null);

    var mt = MemoryEditTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"user_name\",\"content\":\"Nova Alis\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);

    try std.testing.expect(result.success);
    const entry = (try mem.get(allocator, "user_name")) orelse return error.TestUnexpectedResult;
    defer entry.deinit(allocator);
    try std.testing.expectEqualStrings("Nova Alis", entry.content);
    try std.testing.expect(entry.category.eql(.core));
    try std.testing.expect(entry.session_id == null);
}

test "memory_edit rejects missing key" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();

    var mt = MemoryEditTool{ .memory = sqlite_mem.memory() };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"missing\",\"content\":\"x\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    try std.testing.expect(!result.success);
}

test "memory_edit rejects system-managed key" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try mem_root.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("summary_latest/agent:zaki-bot:user:1:main", "focus: shipping", .core, null);

    var mt = MemoryEditTool{ .memory = mem };
    const t = mt.tool();
    const parsed = try root.parseTestArgs("{\"key\":\"summary_latest/agent:zaki-bot:user:1:main\",\"content\":\"focus: changed\"}");
    defer parsed.deinit();
    const result = try t.execute(allocator, parsed.value.object);
    defer if (result.output.len > 0) allocator.free(result.output);
    try std.testing.expect(!result.success);
}
