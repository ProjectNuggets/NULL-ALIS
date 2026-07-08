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

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Spawn a background subagent on a task; returns task_id, delivers result as system message.",
        .use_when = &.{
            "work that doesn't need to block the conversation — research, multi-step analysis, document synthesis, batch jobs",
            "self-contained tasks the subagent can complete with only the task string as context (no parent-conversation memory inheritance)",
            "parallel work where you want to keep talking to the user while something runs",
        },
        .do_not_use_for = &.{
            "schedule — for future-dated or recurring jobs (spawn runs immediately, once)",
            "delegate — when you want a synchronous single-turn call to a pre-configured named agent",
            "web_search — for external queries (answer directly with web_search; no subagent needed)",
            "memory_recall — for facts already stored in memory (call memory_recall yourself; no subagent needed)",
        },
        // S1b: the completion hint is the model-facing recovery promise, and it
        // is now TRUE — task_get(task_id) returns result_text with the final
        // answer once status=succeeded (in-memory live window, then the durable
        // subagent_results outbox). A follow-up turn can recover a prior batch's
        // output this way instead of re-spawning (which costs another LLM run).
        .completion_hint = "The result is delivered as a system message when the subagent finishes. " ++
            "To recover it on a later turn, call task_get(task_id) — once status=succeeded it returns " ++
            "the final answer in result_text (recoverable even after the system-message delivery). " ++
            "Do NOT re-spawn the same task to re-read an answer you already have.",
    };

    comptime {
        @import("lint.zig").lintToolDescription("spawn", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "Spawn a background subagent to work on a self-contained task asynchronously. " ++
        "Returns task_id immediately. After spawning, EITHER (a) keep talking to the user and the subagent's answer arrives as a system message later, " ++
        "OR (b) call task_get(task_id) to retrieve the final answer once its status=succeeded. " ++
        "Write the task as a complete, self-contained brief — the subagent inherits no conversation context. " ++
        "Recursive spawn/delegate/message are blocked in the subagent's tool catalog. Prefer schedule for future or recurring jobs.";
    pub const tool_params =
        \\{"type":"object","properties":{"task":{"type":"string","minLength":1,"description":"COMPLETE, self-contained task brief for the subagent. The subagent inherits NO context from this conversation — include everything it needs (background, success criteria, what output format you want back). A vague task gets a vague answer."},"label":{"type":"string","description":"Short human-readable label (e.g. 'research-zig-async', 'summarize-doc') for tracking in task_list. Optional."}},"required":["task"]}
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

        const runtime_turn = root.getTurnContext();
        const turn = message_tool.MessageTool.getTurnContext();
        const request_session_key = runtime_turn.session_key orelse
            self.default_chat_id orelse
            turn.chat_id orelse
            "agent";
        const channel = turn.channel orelse self.default_channel orelse "system";
        const chat_id = turn.chat_id orelse self.default_chat_id orelse "agent";

        const task_id = manager.spawn(trimmed_task, label, request_session_key, channel, chat_id) catch |err| {
            return switch (err) {
                error.TooManyConcurrentSubagents => ToolResult.fail("Too many concurrent subagents. Wait for some to complete."),
                else => ToolResult.fail("Failed to spawn subagent"),
            };
        };

        const msg = std.fmt.allocPrint(
            allocator,
            "Subagent '{s}' spawned with task_id={d} state=queued. Results will be delivered as system messages.",
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

// S1b: the spawn description PROMISES task_get(task_id) retrieves "the final
// answer". Before S1b that was false (task_get returned only metadata + a null
// summary for subagents). Task 3 makes it true by adding result_text to
// task_get (in-memory → durable subagent_results fallback). This test locks the
// promise to the behavior: if someone removes the task_get-recovers-the-answer
// wording, or the recovery path, this fails and forces the two back in sync.
test "S1b spawn description promises task_get retrieves the final answer" {
    var st = SpawnTool{};
    const t = st.tool();
    const desc = t.description();
    try std.testing.expect(std.mem.indexOf(u8, desc, "task_get(task_id)") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "final answer") != null);
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

test "spawn uses runtime turn session key over chat and tool defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    var cfg = config_mod.Config{
        .workspace_dir = workspace,
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

    root.setTurnContext(.{
        .origin = .user,
        .session_key = "agent:zaki-bot:user:7:main",
    });
    defer root.clearTurnContext();
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
    try std.testing.expectEqualStrings("agent:zaki-bot:user:7:main", state.session_key.?);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:7:task:1", state.runtime_session_key.?);
}

test "spawn falls back to tool defaults when turn context is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    var cfg = config_mod.Config{
        .workspace_dir = workspace,
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

    root.clearTurnContext();
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
