//! subagent_batch_result tool — collect results for a fan-out batch by id.
//!
//! Registered in the MAIN profile when multiagent is enabled, then SELF-GATED
//! at execute() to ⚡ Superpowers turns (paired with spawn_many — a batch only
//! exists if it was spawned on a Superpowers turn). Excluded from
//! subagentTools() — depth guard.
//!
//! H7: returns a clear error when the batch is unknown or expired.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const subagent_mod = @import("../subagent.zig");
const SubagentManager = subagent_mod.SubagentManager;
const json_escape = @import("json_escape.zig");

/// subagent_batch_result tool — query a batch by id and return a JSON array
/// of per-task results (task_id, status, text, error).
pub const SubagentBatchResultTool = struct {
    manager: ?*SubagentManager = null,

    pub const tool_name = "subagent_batch_result";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Superpowers-only: collect all results for a fan-out batch (survivors, failures, timeouts).",
        .use_when = &.{
            "after spawn_many when you want to poll for results rather than waiting for the system-message delivery",
            "after a restart when the batch wake may have been missed and you need to recover results",
        },
        .do_not_use_for = &.{
            "spawn_many — for launching the fan-out batch in the first place",
            "task_get — for inspecting a single task by id rather than a whole batch",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("subagent_batch_result", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "⚡ Superpowers mode only. Collect all results for a batch spawned by spawn_many. " ++
        "Returns a JSON array with one entry per task: {task_id, status, text, error}. " ++
        "Includes tasks in any state (completed, failed, timeout, still running). " ++
        "H7: if the batch_id is unknown or expired, returns a clear error.";

    pub const tool_params =
        \\{"type":"object","properties":{"batch_id":{"type":"string","description":"The batch_id returned by spawn_many."}},"required":["batch_id"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SubagentBatchResultTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *SubagentBatchResultTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        // Phase 5 T3 — Superpowers self-gate (SAFETY INVARIANT). Paired with
        // spawn_many: a batch only exists if it was spawned on a Superpowers
        // turn, so collecting one is a Superpowers-only capability too. Runs
        // FIRST — a non-Superpowers turn can never reach the batch tracker.
        if (!root.getTurnContext().superpowers_mode) {
            return ToolResult.fail("subagent_batch_result is only available in ⚡ Superpowers mode — enable it from the reasoning toggle.");
        }

        // Parse batch_id before manager check so parameter errors are clear.
        const batch_id = root.getString(args, "batch_id") orelse
            return ToolResult.fail("Missing 'batch_id' parameter");

        const trimmed = std.mem.trim(u8, batch_id, " \t\n");
        if (trimmed.len == 0)
            return ToolResult.fail("'batch_id' must not be empty");

        const manager = self.manager orelse
            return ToolResult.fail("subagent_batch_result tool not connected to SubagentManager");

        // Collect entries — H7: error.UnknownBatch → clear message using the
        // output buffer (avoids a separate allocation for the error string).
        const entries = manager.getBatchResults(allocator, trimmed) catch |err| {
            if (err == error.UnknownBatch) {
                var ebuf: std.ArrayListUnmanaged(u8) = .{};
                errdefer ebuf.deinit(allocator);
                const ew = ebuf.writer(allocator);
                try ew.print("Batch not found or expired (batch_id={s})", .{trimmed});
                // Return as a failure with the output field carrying the message
                // so the caller sees it via error_msg. We embed the string in
                // output and set success=false (mirrors task_get's not-found pattern).
                return .{ .success = false, .output = "", .error_msg = try ebuf.toOwnedSlice(allocator) };
            }
            return ToolResult.fail("Failed to retrieve batch results");
        };
        defer SubagentManager.freeBatchResultEntries(allocator, entries);

        // Serialize as JSON array.
        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.writeByte('[');
        for (entries, 0..) |e, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"task_id\":{d},\"status\":\"", .{e.task_id});
            try json_escape.writeJsonStringContent(w, e.status);
            try w.writeAll("\",\"text\":\"");
            try json_escape.writeJsonStringContent(w, e.text);
            try w.writeByte('"');
            if (e.err) |err_str| {
                try w.writeAll(",\"error\":\"");
                try json_escape.writeJsonStringContent(w, err_str);
                try w.writeByte('"');
            } else {
                try w.writeAll(",\"error\":null");
            }
            try w.writeByte('}');
        }
        try w.writeByte(']');

        return .{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "subagent_batch_result tool name" {
    var sbt = SubagentBatchResultTool{};
    const t = sbt.tool();
    try std.testing.expectEqualStrings("subagent_batch_result", t.name());
}

test "subagent_batch_result tool description is non-empty" {
    var sbt = SubagentBatchResultTool{};
    const t = sbt.tool();
    try std.testing.expect(t.description().len > 0);
}

test "subagent_batch_result schema contains batch_id" {
    var sbt = SubagentBatchResultTool{};
    const t = sbt.tool();
    const schema = t.parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "batch_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "required") != null);
}

test "subagent_batch_result missing batch_id" {
    // Run as a Superpowers turn so we exercise arg validation past the T3 gate.
    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();
    var sbt = SubagentBatchResultTool{};
    const t = sbt.tool();
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "batch_id") != null);
}

test "subagent_batch_result without manager fails" {
    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();
    var sbt = SubagentBatchResultTool{};
    const t = sbt.tool();
    const parsed = try root.parseTestArgs("{\"batch_id\":\"batch:1:0\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "SubagentManager") != null);
}

const config_mod = @import("../config.zig");

test "subagent_batch_result H7 — unknown batch_id returns clear error" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();

    var sbt = SubagentBatchResultTool{ .manager = &manager };
    const t = sbt.tool();

    const parsed = try root.parseTestArgs("{\"batch_id\":\"batch:9999:never\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |em| std.testing.allocator.free(em);

    try std.testing.expect(!result.success);
    // H7: message must mention the batch_id
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "batch:9999:never") != null);
}

test "subagent_batch_result returns JSON array for known batch" {
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

    // Spawn a small batch via the manager directly.
    const specs = [_]SubagentManager.SpawnSpec{
        .{ .task = "look into X", .label = "x" },
        .{ .task = "look into Y", .label = "y" },
    };
    const handle = try manager.spawnMany(&specs, "agent:test:user:1:main", "agent", "chat:1", 60_000);
    defer {
        std.testing.allocator.free(handle.batch_id);
        std.testing.allocator.free(handle.task_ids);
    }

    // Phase 5 T3 — collecting a fan-out batch is a Superpowers-only capability.
    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();

    var sbt = SubagentBatchResultTool{ .manager = &manager };
    const t = sbt.tool();

    // Build args with the real batch_id.
    const json_str = try std.fmt.allocPrint(std.testing.allocator, "{{\"batch_id\":\"{s}\"}}", .{handle.batch_id});
    defer std.testing.allocator.free(json_str);
    const parsed = try root.parseTestArgs(json_str);
    defer parsed.deinit();

    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.success) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    // Output is a JSON array.
    try std.testing.expect(result.output[0] == '[');
    try std.testing.expect(std.mem.indexOf(u8, result.output, "task_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "status") != null);
}

// ── Phase 5 T3 — Superpowers self-gate (SAFETY INVARIANT) ────────────────────

test "subagent_batch_result refuses on a non-Superpowers turn" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    // Default turn context: superpowers_mode = false → a normal turn.
    root.setTurnContext(.{ .superpowers_mode = false });
    defer root.clearTurnContext();

    var sbt = SubagentBatchResultTool{ .manager = &manager };
    const t = sbt.tool();
    const parsed = try root.parseTestArgs("{\"batch_id\":\"batch:1:0\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    // The refusal uses ToolResult.fail — a static error_msg (do NOT free).

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Superpowers mode") != null);
}

test "subagent_batch_result proceeds on a Superpowers turn" {
    // Superpowers turn + unknown batch → it gets PAST the gate and reaches the
    // H7 unknown-batch path (proves the gate let it through).
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();

    var sbt = SubagentBatchResultTool{ .manager = &manager };
    const t = sbt.tool();
    const parsed = try root.parseTestArgs("{\"batch_id\":\"batch:9999:never\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |em| std.testing.allocator.free(em);

    try std.testing.expect(!result.success);
    // Past the gate: the failure is the H7 unknown-batch error, NOT the gate.
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Superpowers mode") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "batch:9999:never") != null);
}
