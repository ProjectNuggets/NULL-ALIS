//! task_get tool — inspect a specific task by ID.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const tasks_mod = @import("../tasks/root.zig");
const TaskDelivery = tasks_mod.TaskDelivery;
const TaskEntry = tasks_mod.TaskEntry;
const SubagentManager = @import("../subagent.zig").SubagentManager;

pub const TaskGetTool = struct {
    delivery: *TaskDelivery,
    /// Subagent Pass S1b — optional handle to the subagent runtime, wired in
    /// the main profile alongside spawn/subagent_batch_result. Present → task_get
    /// can recover a subagent task's final-answer text (in-memory live window,
    /// then the durable `subagent_results` outbox). Null (e.g. file-tenant/CLI
    /// with no subagent manager) → metadata-only, exactly as before S1b.
    manager: ?*SubagentManager = null,

    pub const tool_name = "task_get";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Fetch one task's full record: description, status, timestamps, result summary, error message.",
        .use_when = &.{
            "Checking whether a previously-spawned subagent task has finished",
            "Reading the result summary or error message of a completed task by ID",
            "Drilling into a single task surfaced by task_list before deciding to cancel or wait",
        },
        .do_not_use_for = &.{
            "task_list — for browsing many tasks rather than inspecting one by ID",
            "task_stop — for cancelling a running task rather than just inspecting it",
            "cron_runs — for execution history of scheduled jobs rather than tasks",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("task_get", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
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

        const session_key = root.getTurnContext().session_key orelse
            return ToolResult.fail("task not found");
        if (!std.mem.eql(u8, session_key, entry.owner_session))
            return ToolResult.fail("task not found");

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

        // Subagent Pass S1b — recover the subagent's full final-answer text so a
        // follow-up turn can read a prior batch's output instead of re-spawning
        // (which costs an LLM run). The ledger mirror stores a null summary for
        // subagents by design, so the answer lives only in the SubagentManager
        // (in-memory, live) and the durable `subagent_results` outbox (survives
        // delivery). Resolution order: in-memory live path first, then durable
        // fallback. The owner-session check above guards both metadata and the
        // recovered answer text.
        if (self.manager) |manager| {
            if (numericTaskId(&entry.task_id)) |numeric_id| {
                if (try manager.getTaskResultTextAlloc(allocator, numeric_id)) |text| {
                    defer allocator.free(text);
                    try w.writeAll(",\"result_text\":\"");
                    try jsonEscapeInto(w, text);
                    try w.writeByte('"');
                } else if (manager.getDurableResultText(allocator, numeric_id)) |durable_text| {
                    defer allocator.free(durable_text);
                    try w.writeAll(",\"result_text\":\"");
                    try jsonEscapeInto(w, durable_text);
                    try w.writeByte('"');
                }
            }
        }

        try w.writeByte('}');

        return .{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }

    /// Subagent Pass S1b — parse the numeric subagent task id from the canonical
    /// ledger id string. The id is formatted `task_<11 hex digits>` (see
    /// `formatCanonicalTaskId` in subagent.zig / `createTaskWithNumericId` in
    /// tasks/ledger.zig); this reverses that. Returns null for any id that does
    /// not match the shape (e.g. a non-subagent task id), so callers silently
    /// skip result recovery rather than misresolving.
    fn numericTaskId(id: []const u8) ?u64 {
        const prefix = "task_";
        if (!std.mem.startsWith(u8, id, prefix)) return null;
        const hex = id[prefix.len..];
        if (hex.len == 0) return null;
        return std.fmt.parseInt(u64, hex, 16) catch null;
    }
};

/// HIGH 3.B (v1.14.23 holistic review): consolidated onto the shared
/// escaper. See `task_list.zig` for the rationale.
const jsonEscapeInto = @import("json_escape.zig").writeJsonStringContent;

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

    root.setTurnContext(.{ .session_key = "session-1" });
    defer root.clearTurnContext();

    var tg = TaskGetTool{ .delivery = &delivery };
    const result = try tg.execute(allocator, args);
    defer allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "my task") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "queued") != null);
}

test "TaskGetTool.execute without current session hides existing task" {
    const allocator = std.testing.allocator;
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };

    const entry = try ledger_inst.createTask("private task", "session-1");
    const id = entry.task_id;

    var args = JsonObjectMap.init(allocator);
    defer args.deinit();
    try args.put("task_id", .{ .string = &id });

    root.clearTurnContext();

    var tg = TaskGetTool{ .delivery = &delivery };
    const result = try tg.execute(allocator, args);
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("task not found", result.error_msg.?);
    try std.testing.expectEqualStrings("", result.output);
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

// ── S1b: task_get recovers the subagent's result text ────────────────────
// RED→GREEN. A completed subagent task's `task_get` must surface `result_text`
// carrying the actual answer, recovered from the in-memory SubagentManager via
// getTaskResultText — the ledger mirror stores a null summary for subagents, so
// before S1b this text was unrecoverable through task_get.

const subagent_mod = @import("../subagent.zig");
const config_mod = @import("../config.zig");

test "S1b task_get returns result_text from the in-memory subagent path" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    var mgr = SubagentManager.init(allocator, &cfg, null, .{});
    defer mgr.deinit();

    // Insert a completed task under numeric id 1 with the structured result set
    // directly (completeTask is private to subagent.zig). All owned slices —
    // including result.text — are duped into `allocator` so the manager's
    // deinit → freeTaskState → freeSubagentResult frees them cleanly.
    // getTaskResultText(1) then returns the answer text.
    const state = try allocator.create(subagent_mod.TaskState);
    state.* = .{
        .status = .completed,
        .label = try allocator.dupe(u8, "s1b-task"),
        .task_summary = try allocator.dupe(u8, "answer the question"),
        .task_prompt = try allocator.dupe(u8, "answer the question"),
        .result = .{
            .status = .completed,
            .text = try allocator.dupe(u8, "the sky is blue because of Rayleigh scattering"),
        },
        .started_at = std.time.milliTimestamp(),
        .completed_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(allocator, 1, state);

    // Ledger carries the canonical id string for the same numeric id so the
    // metadata snapshot resolves; the numeric id (1) drives the in-memory lookup.
    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };
    const entry = try ledger_inst.createTaskWithNumericId("answer the question", "agent:zaki-bot:user:7:main", 1);
    const id = entry.task_id;

    var args = JsonObjectMap.init(allocator);
    defer args.deinit();
    try args.put("task_id", .{ .string = &id });

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:7:main" });
    defer root.clearTurnContext();

    var tg = TaskGetTool{ .delivery = &delivery, .manager = &mgr };
    const result = try tg.execute(allocator, args);
    defer allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"result_text\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Rayleigh scattering") != null);
}

test "S1b task_get refuses a different session" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(workspace);
    const cfg = config_mod.Config{
        .workspace_dir = workspace,
        .config_path = "/tmp/yc/config.json",
        .allocator = allocator,
    };
    var mgr = SubagentManager.init(allocator, &cfg, null, .{});
    defer mgr.deinit();

    const state = try allocator.create(subagent_mod.TaskState);
    state.* = .{
        .status = .completed,
        .label = try allocator.dupe(u8, "foreign-task"),
        .task_summary = try allocator.dupe(u8, "answer another session"),
        .task_prompt = try allocator.dupe(u8, "answer another session"),
        .result = .{
            .status = .completed,
            .text = try allocator.dupe(u8, "session private final answer"),
        },
        .started_at = std.time.milliTimestamp(),
        .completed_at = std.time.milliTimestamp(),
    };
    try mgr.tasks.put(allocator, 2, state);

    var ledger_inst = TaskLedger.init(allocator);
    defer ledger_inst.deinit();
    var noop = observability.NoopObserver{};
    var delivery = TaskDelivery{ .ledger = &ledger_inst, .observer = noop.observer() };
    const entry = try ledger_inst.createTaskWithNumericId("answer another session", "agent:zaki-bot:user:7:main", 2);
    const id = entry.task_id;

    var args = JsonObjectMap.init(allocator);
    defer args.deinit();
    try args.put("task_id", .{ .string = &id });

    root.setTurnContext(.{ .session_key = "agent:zaki-bot:user:8:main" });
    defer root.clearTurnContext();

    var tg = TaskGetTool{ .delivery = &delivery, .manager = &mgr };
    const result = try tg.execute(allocator, args);

    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("task not found", result.error_msg.?);
    try std.testing.expectEqualStrings("", result.output);
}
