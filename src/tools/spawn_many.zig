//! spawn_many tool — fan out N subagents under one batch.
//!
//! Registered in the MAIN profile when multiagent is enabled (same gate as
//! spawn/delegate), then SELF-GATED at execute() to ⚡ Superpowers turns: a
//! non-Superpowers turn refuses before any spawn (the safety invariant — only
//! a coordinator turn may fan out). Excluded from subagentTools() — subagents
//! must not fan out (depth guard).

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const subagent_mod = @import("../subagent.zig");
const SubagentManager = subagent_mod.SubagentManager;
const message_tool = @import("message.zig");

/// spawn_many tool — fans out up to 8 subagents under a single batch.
/// The tool returns a batch_id + task_ids immediately. Results are
/// collected via subagent_batch_result or arrive as system messages.
pub const SpawnManyTool = struct {
    manager: ?*SubagentManager = null,
    default_channel: ?[]const u8 = null,
    default_chat_id: ?[]const u8 = null,

    pub const tool_name = "spawn_many";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Superpowers-only: fan out up to 8 parallel subagents under one batch.",
        .use_when = &.{
            "multiple self-contained research tasks that are genuinely parallel (e.g. 'summarise A, B, C simultaneously')",
            "coordinator workflow where you want to collect ALL subagent results in one go before continuing",
        },
        .do_not_use_for = &.{
            "spawn — for a single background task when fan-out is not needed",
            "subagent_batch_result — to poll an in-flight batch by its batch_id",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("spawn_many", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "⚡ Superpowers mode only — available when the user enables the Superpowers reasoning toggle. " ++
        "Fan out up to 8 parallel subagents under a single batch. " ++
        "Returns batch_id + task_ids immediately. " ++
        "Results are delivered together as a system message when all complete, " ++
        "or call subagent_batch_result(batch_id) to collect them on demand. " ++
        "Each task must be a complete, self-contained brief — subagents inherit no conversation context. " ++
        "Capacity is checked atomically: if N exceeds the remaining concurrent-subagent budget the whole call is rejected. " ++
        "Excluded from subagent tool catalogs — subagents may not fan out.";

    pub const tool_params =
        \\{"type":"object","properties":{"tasks":{"type":"array","minItems":1,"maxItems":8,"description":"List of tasks to fan out (1–8). Each item needs a 'task' (self-contained brief) and an optional 'label'.","items":{"type":"object","properties":{"task":{"type":"string","minLength":1,"description":"Complete, self-contained task brief for the subagent."},"label":{"type":"string","description":"Short tracking label (e.g. 'research-a')."}},"required":["task"]}},"budget_seconds":{"type":"integer","description":"Batch wall-clock deadline in seconds. Default 300, min 30, max 900."}},"required":["tasks"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SpawnManyTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *SpawnManyTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        // Phase 5 T3 — Superpowers self-gate (SAFETY INVARIANT). Fan-out is a
        // coordinator-only capability that burns N× credits. This runs FIRST,
        // before any arg parsing or spawn, so a non-Superpowers turn can never
        // fan out — defense-in-depth on top of the not-presented-to-provider
        // filter (the tool is filtered out of a normal turn's tool list). The
        // per-turn flag arrives via the turn context the session installs.
        if (!root.getTurnContext().superpowers_mode) {
            return ToolResult.fail("spawn_many is only available in ⚡ Superpowers mode — enable it from the reasoning toggle.");
        }

        // Parse tasks array first so parameter errors surface before manager check.
        const tasks_val = args.get("tasks") orelse
            return ToolResult.fail("Missing 'tasks' parameter");
        const tasks_arr = switch (tasks_val) {
            .array => |a| a,
            else => return ToolResult.fail("'tasks' must be an array"),
        };

        if (tasks_arr.items.len == 0)
            return ToolResult.fail("'tasks' array must have at least 1 item");
        if (tasks_arr.items.len > 8)
            return ToolResult.fail("'tasks' array exceeds maximum of 8 items");

        // Build SpawnSpec slice on the stack (max 8 items).
        var spec_buf: [8]SubagentManager.SpawnSpec = undefined;
        var spec_count: usize = 0;
        for (tasks_arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => return ToolResult.fail("Each task must be a JSON object"),
            };
            const task_str = switch (obj.get("task") orelse return ToolResult.fail("Each task must have a 'task' field")) {
                .string => |s| s,
                else => return ToolResult.fail("'task' field must be a string"),
            };
            const trimmed = std.mem.trim(u8, task_str, " \t\n");
            if (trimmed.len == 0)
                return ToolResult.fail("'task' must not be empty");

            const label: []const u8 = blk: {
                if (obj.get("label")) |lv| {
                    if (lv == .string and lv.string.len > 0) break :blk lv.string;
                }
                break :blk "subagent";
            };

            spec_buf[spec_count] = .{ .task = trimmed, .label = label };
            spec_count += 1;
        }
        const specs = spec_buf[0..spec_count];

        // Manager check — after args validation so parameter errors are clear.
        const manager = self.manager orelse
            return ToolResult.fail("spawn_many tool not connected to SubagentManager");

        // Resolve session_key / channel / chat_id from turn context (mirrors spawn.zig).
        const runtime_turn = root.getTurnContext();
        const turn = message_tool.MessageTool.getTurnContext();
        const request_session_key = runtime_turn.session_key orelse
            self.default_chat_id orelse
            turn.chat_id orelse
            "agent";
        const channel = turn.channel orelse self.default_channel orelse "system";
        const chat_id = turn.chat_id orelse self.default_chat_id orelse "agent";

        // Clamp budget: default 300 s, min 30 s, max 900 s.
        const budget_seconds: i64 = blk: {
            if (args.get("budget_seconds")) |bv| {
                const raw: i64 = switch (bv) {
                    .integer => |i| i,
                    else => 300,
                };
                break :blk @max(30, @min(900, raw));
            }
            break :blk 300;
        };
        const budget_ms: i64 = budget_seconds * 1000;

        // Fan out.
        const handle = manager.spawnMany(specs, request_session_key, channel, chat_id, budget_ms) catch |err| {
            return switch (err) {
                error.TooManyConcurrentSubagents =>
                    ToolResult.fail("Too many concurrent subagents for this batch; spawn fewer or wait."),
                error.EmptyBatch =>
                    ToolResult.fail("'tasks' array is empty"),
                error.SpawnFailed =>
                    ToolResult.fail("All spawns failed (out of resources)"),
                else => ToolResult.fail("Failed to fan out subagents"),
            };
        };
        // Caller owns handle.batch_id + handle.task_ids; free after building output.
        defer {
            manager.allocator.free(handle.batch_id);
            manager.allocator.free(handle.task_ids);
        }

        // H8 — count vs requested note.
        const count = handle.task_ids.len;
        const requested = handle.requested;

        // Build JSON response.
        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.print("{{\"batch_id\":\"{s}\",\"task_ids\":[", .{handle.batch_id});
        for (handle.task_ids, 0..) |tid, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{d}", .{tid});
        }
        var note_buf: [128]u8 = undefined;
        const note = if (count == requested)
            try std.fmt.bufPrint(&note_buf,
                "{d} of {d} spawned; results arrive together, or call subagent_batch_result",
                .{ count, requested })
        else
            try std.fmt.bufPrint(&note_buf,
                "{d} of {d} spawned (partial); results arrive together, or call subagent_batch_result",
                .{ count, requested });
        try w.print("],\"count\":{d},\"requested\":{d},\"note\":\"{s}\"}}", .{ count, requested, note });

        return .{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "spawn_many tool name" {
    var st = SpawnManyTool{};
    const t = st.tool();
    try std.testing.expectEqualStrings("spawn_many", t.name());
}

test "spawn_many tool description is non-empty" {
    var st = SpawnManyTool{};
    const t = st.tool();
    try std.testing.expect(t.description().len > 0);
}

test "spawn_many schema contains tasks and budget_seconds" {
    var st = SpawnManyTool{};
    const t = st.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "tasks") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "budget_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "required") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "maxItems") != null);
}

test "spawn_many missing tasks parameter" {
    // Run as a Superpowers turn so we exercise arg validation past the T3 gate.
    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();
    var st = SpawnManyTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "tasks") != null);
}

test "spawn_many without manager fails" {
    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();
    var st = SpawnManyTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"tasks\":[{\"task\":\"do something\"}]}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "SubagentManager") != null);
}

test "spawn_many empty tasks array rejected" {
    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();
    var st = SpawnManyTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"tasks\":[]}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "spawn_many rejects more than 8 tasks" {
    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();
    var st = SpawnManyTool{};
    const t = st.tool();
    const parsed = try root.parseTestArgs(
        \\{"tasks":[{"task":"a"},{"task":"b"},{"task":"c"},{"task":"d"},{"task":"e"},{"task":"f"},{"task":"g"},{"task":"h"},{"task":"i"}]}
    );
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "maximum") != null);
}

const config_mod = @import("../config.zig");

test "spawn_many fanout succeeds and returns batch_id + task_ids" {
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

    // Phase 5 T3 — fan-out is a Superpowers-only capability; the happy path
    // runs on a Superpowers turn.
    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();

    var st = SpawnManyTool{ .manager = &manager };
    const t = st.tool();

    const parsed = try root.parseTestArgs(
        \\{"tasks":[{"task":"research A","label":"la"},{"task":"research B","label":"lb"}],"budget_seconds":60}
    );
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.success) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "batch_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "task_ids") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "count") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "note") != null);
}

// ── Phase 5 T3 — Superpowers self-gate (SAFETY INVARIANT) ────────────────────

test "spawn_many refuses on a non-Superpowers turn (no spawn)" {
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

    // Default turn context: superpowers_mode = false → a normal turn.
    root.setTurnContext(.{ .superpowers_mode = false });
    defer root.clearTurnContext();

    var st = SpawnManyTool{ .manager = &manager };
    const t = st.tool();

    // Well-formed args + a connected manager: the ONLY reason this must fail
    // is the Superpowers gate. Proves a non-superpowers turn cannot fan out.
    const parsed = try root.parseTestArgs(
        \\{"tasks":[{"task":"research A"},{"task":"research B"}]}
    );
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // The refusal uses ToolResult.fail — a static error_msg (do NOT free).

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Superpowers mode") != null);
    // No batch was created — the refusal carries no batch_id (the gate runs
    // before manager.spawnMany is ever reached). output is empty on failure.
    try std.testing.expectEqualStrings("", result.output);
}

test "spawn_many proceeds on a Superpowers turn" {
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

    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();

    var st = SpawnManyTool{ .manager = &manager };
    const t = st.tool();
    const parsed = try root.parseTestArgs(
        \\{"tasks":[{"task":"research A"}]}
    );
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.success) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "batch_id") != null);
}

test "spawn_many surfaces TooManyConcurrentSubagents" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = SubagentManager.init(std.testing.allocator, &cfg, null, .{
        .max_concurrent = 0,
    });
    defer manager.deinit();

    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();

    var st = SpawnManyTool{ .manager = &manager };
    const t = st.tool();
    const parsed = try root.parseTestArgs("{\"tasks\":[{\"task\":\"blocked\"}]}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Too many concurrent subagents") != null);
}
