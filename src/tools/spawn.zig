const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const SubagentManager = @import("../subagent.zig").SubagentManager;
const config_mod = @import("../config.zig");
const message_tool = @import("message.zig");

/// Spawn tool — launches a background subagent to work on a task asynchronously.
/// Returns a task ID immediately. Results are delivered as system messages.
pub const SpawnTool = struct {
    manager: ?*SubagentManager = null,
    default_channel: ?[]const u8 = null,
    default_chat_id: ?[]const u8 = null,

    pub const tool_name = "spawn";
    pub const tool_description = "Start async work now and return immediately. Prefer `schedule` for future or recurring jobs.";
    pub const tool_params =
        \\{"type":"object","properties":{"task":{"type":"string","minLength":1,"description":"The task/prompt for the subagent"},"label":{"type":"string","description":"Optional human-readable label for tracking"}},"required":["task"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SpawnTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *SpawnTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const task = root.getString(args, "task") orelse
            return ToolResult.fail("Missing 'task' parameter");

        const trimmed_task = std.mem.trim(u8, task, " \t\n");
        if (trimmed_task.len == 0) {
            return ToolResult.fail("'task' must not be empty");
        }

        const label = root.getString(args, "label") orelse "subagent";

        const manager = self.manager orelse
            return ToolResult.fail("Spawn tool not connected to SubagentManager");

        const turn = message_tool.MessageTool.getTurnContext();
        const channel = turn.channel orelse self.default_channel orelse "system";
        const chat_id = turn.chat_id orelse self.default_chat_id orelse "agent";

        const task_id = manager.spawn(trimmed_task, label, channel, chat_id) catch |err| {
            return switch (err) {
                error.TooManyConcurrentSubagents => ToolResult.fail("Too many concurrent subagents. Wait for some to complete."),
                else => ToolResult.fail("Failed to spawn subagent"),
            };
        };

        const msg = std.fmt.allocPrint(
            allocator,
            "Subagent '{s}' spawned with task_id={d}. Results will be delivered as system messages.",
            .{ label, task_id },
        ) catch return ToolResult.ok("Subagent spawned");

        return ToolResult.ok(msg);
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "spawn tool name" {
    var st = SpawnTool{};
    const t = st.tool();
    try std.testing.expectEqualStrings("spawn", t.name());
}

test "spawn tool description" {
    var st = SpawnTool{};
    const t = st.tool();
    try std.testing.expect(t.description().len > 0);
}

test "spawn tool schema has task" {
    var st = SpawnTool{};
    const t = st.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "task") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "label") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "required") != null);
}

test "spawn missing task parameter" {
    var st = SpawnTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"label\": \"test\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "task") != null);
}

test "spawn empty task rejected" {
    var st = SpawnTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"task\": \"  \"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "empty") != null);
}

test "spawn without manager fails" {
    var st = SpawnTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"task\": \"do something\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "SubagentManager") != null);
}

test "spawn empty JSON rejected" {
    var st = SpawnTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "spawn uses current turn context over tool defaults" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    var st = SpawnTool{
        .manager = &manager,
        .default_channel = "system",
        .default_chat_id = "fallback-chat",
    };
    const t = st.tool();

    message_tool.MessageTool.setTurnContext(.{
        .channel = "telegram",
        .chat_id = "chat-42",
    });
    defer message_tool.MessageTool.clearTurnContext();

    const parsed = try root.parseTestArgs("{\"task\": \"inspect routing\", \"label\": \"routing\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);

    manager.mutex.lock();
    defer manager.mutex.unlock();
    const state = manager.tasks.get(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("telegram", state.origin_channel.?);
    try std.testing.expectEqualStrings("chat-42", state.origin_chat_id.?);
    try std.testing.expectEqualStrings("chat-42", state.session_key.?);
}

test "spawn falls back to tool defaults when turn context is absent" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    var st = SpawnTool{
        .manager = &manager,
        .default_channel = "agent",
        .default_chat_id = "session:alpha",
    };
    const t = st.tool();

    message_tool.MessageTool.clearTurnContext();

    const parsed = try root.parseTestArgs("{\"task\": \"fallback routing\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);

    manager.mutex.lock();
    defer manager.mutex.unlock();
    const state = manager.tasks.get(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("agent", state.origin_channel.?);
    try std.testing.expectEqualStrings("session:alpha", state.origin_chat_id.?);
    try std.testing.expectEqualStrings("session:alpha", state.session_key.?);
}

test "spawn surfaces concurrency limit" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = SubagentManager.init(std.testing.allocator, &cfg, null, .{
        .max_concurrent = 0,
    });
    defer manager.deinit();

    var st = SpawnTool{ .manager = &manager };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"task\": \"blocked\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Too many concurrent subagents") != null);
}
