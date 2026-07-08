//! subagent_batch_result tool — collect results for a fan-out batch by id.
//!
//! Registered in the MAIN profile when multiagent is enabled. UNGATED at
//! execute() since S1a (Package 3 Task 4): the collector is READ-ONLY
//! (read_only + coordinator_dispatch in the registry) — collecting an
//! already-dispatched batch is not a fan-out privilege, and the out-of-band
//! wake turn (superpowers unset on the wake lane) plus ordinary follow-up
//! turns must be able to recover results. spawn_many KEEPS its Superpowers
//! self-gate, so batches still only come into existence on a Superpowers
//! turn. Excluded from subagentTools() — depth guard.
//!
//! S1a: optional `wait_seconds` (clamped [0,120], default 0) turns the read
//! into a bounded blocking collect: ONE call waits until the batch is
//! all-terminal (or the wait expires) and returns everything — no repeated
//! byte-identical collect calls for the loop detector (agent/root.zig D1.10)
//! to trip on. The blocking response carries `waited_ms` for observability.
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
        .what = "Collect all results for a spawn_many batch, optionally blocking until every task finishes.",
        .use_when = &.{
            "after spawn_many — pass wait_seconds (~ the batch budget) so ONE call blocks until the batch is done and returns everything",
            "after a restart or on a later turn when the batch wake may have been missed and you need to recover results",
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
        "Collect all results for a batch spawned by spawn_many. " ++
        "Returns one entry per task: {task_id, status, text, error} — tasks in any state (completed, failed, timeout, still running). " ++
        "Set wait_seconds (1-120) to block until every task in the batch is terminal before returning: " ++
        "ONE blocking call collects the whole batch (the response then also carries waited_ms) — never call this tool in a retry loop. " ++
        "H7: if the batch_id is unknown or expired, returns a clear error.";

    pub const tool_params =
        \\{"type":"object","properties":{"batch_id":{"type":"string","description":"The batch_id returned by spawn_many."},"wait_seconds":{"type":"integer","description":"Optional, clamped to 0-120. When >0, blocks until every task in the batch is terminal (or this many seconds elapse), then returns the current results plus waited_ms. Default 0 returns immediately. Set it to roughly your batch budget so one call collects everything."}},"required":["batch_id"]}
    ;

    /// S1a — hard ceiling for the blocking collect (seconds). Two minutes
    /// keeps one tool call from pinning a turn indefinitely while comfortably
    /// covering the default 60-90 s batch budgets.
    pub const WAIT_SECONDS_MAX: i64 = 120;

    /// S1a — clamp the optional `wait_seconds` argument into
    /// [0, WAIT_SECONDS_MAX]. null (absent) and negative values → 0 (the
    /// original non-blocking read); anything above the ceiling → the ceiling.
    pub fn clampWaitSeconds(raw: ?i64) i64 {
        return std.math.clamp(raw orelse 0, 0, WAIT_SECONDS_MAX);
    }

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SubagentBatchResultTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// H7 failure builder — the clear "batch not found" message, shared by the
    /// wait path and the collect path so both spellings stay byte-identical.
    fn unknownBatchFailure(allocator: std.mem.Allocator, batch_id: []const u8) !ToolResult {
        var ebuf: std.ArrayListUnmanaged(u8) = .{};
        errdefer ebuf.deinit(allocator);
        const ew = ebuf.writer(allocator);
        try ew.print("Batch not found or expired (batch_id={s})", .{batch_id});
        // Return as a failure with the output field carrying the message
        // so the caller sees it via error_msg. We embed the string in
        // output and set success=false (mirrors task_get's not-found pattern).
        return .{ .success = false, .output = "", .error_msg = try ebuf.toOwnedSlice(allocator) };
    }

    pub fn execute(self: *SubagentBatchResultTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        // S1a (Package 3 Task 4): the Phase 5 T3 Superpowers self-gate was
        // REMOVED here — this tool is a read-only collector, and collecting an
        // already-dispatched batch is not a fan-out privilege (dispatching
        // is: spawn_many keeps its gate, so batches still only exist if a
        // Superpowers turn created them). Ungating lets the out-of-band wake
        // turn (superpowers unset on the wake lane) and ordinary follow-up
        // turns recover batch results.

        // Parse batch_id before manager check so parameter errors are clear.
        const batch_id = root.getString(args, "batch_id") orelse
            return ToolResult.fail("Missing 'batch_id' parameter");

        const trimmed = std.mem.trim(u8, batch_id, " \t\n");
        if (trimmed.len == 0)
            return ToolResult.fail("'batch_id' must not be empty");

        // S1a — optional bounded blocking collect. Clamped [0,120] s; 0
        // (absent/default) preserves the original non-blocking read exactly.
        const wait_seconds = clampWaitSeconds(root.getInt(args, "wait_seconds"));

        const manager = self.manager orelse
            return ToolResult.fail("subagent_batch_result tool not connected to SubagentManager");

        var waited_ms: i64 = 0;
        if (wait_seconds > 0) {
            // Bounded wait until all-terminal or deadline; the deadline expiry
            // is NOT an error — the collect below returns current states.
            // error.UnknownBatch → same H7 contract as the collect path, and
            // immediately: never wait on a nonexistent id.
            waited_ms = manager.waitBatchTerminal(trimmed, wait_seconds * std.time.ms_per_s) catch {
                return unknownBatchFailure(allocator, trimmed);
            };
        }

        // Collect entries — H7: error.UnknownBatch → clear message.
        const entries = manager.getBatchResults(allocator, trimmed) catch |err| {
            if (err == error.UnknownBatch) return unknownBatchFailure(allocator, trimmed);
            return ToolResult.fail("Failed to retrieve batch results");
        };
        defer SubagentManager.freeBatchResultEntries(allocator, entries);

        // Serialize. wait_seconds=0 keeps the original bare-array output
        // byte-for-byte (zero regression); a blocking collect wraps the SAME
        // array as {"waited_ms":N,"results":[…]} for observability.
        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);

        if (wait_seconds > 0) try w.print("{{\"waited_ms\":{d},\"results\":", .{waited_ms});
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
        if (wait_seconds > 0) try w.writeByte('}');

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
    // Superpowers ctx kept for coverage parity — the tool is ungated (S1a).
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

    // Superpowers ctx kept for coverage parity — the tool is ungated (S1a).
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

// ── Phase 5 T3 gate — REMOVED by S1a (Package 3 Task 4) ──────────────────────
//
// The old "refuses on a non-Superpowers turn" test asserted the execute-time
// Superpowers self-gate. That gate is gone: the collector is read-only and the
// out-of-band wake turn (superpowers unset) must be able to recover results.
// Its replacement is "S1a: returns results on a non-Superpowers turn" below.
// spawn_many keeps its gate — see spawn_many.zig
// "spawn_many refuses on a non-Superpowers turn (no spawn)".

test "subagent_batch_result proceeds on a Superpowers turn" {
    // Superpowers turns keep working after the S1a ungating; unknown batch →
    // the H7 error (not any refusal).
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
    // The failure is the H7 unknown-batch error, NOT a gate refusal.
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Superpowers mode") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "batch:9999:never") != null);
}

test "subagent_batch_result S1a: clampWaitSeconds clamps into [0, 120]" {
    try std.testing.expectEqual(@as(i64, 0), SubagentBatchResultTool.clampWaitSeconds(null)); // absent → non-blocking
    try std.testing.expectEqual(@as(i64, 0), SubagentBatchResultTool.clampWaitSeconds(0));
    try std.testing.expectEqual(@as(i64, 0), SubagentBatchResultTool.clampWaitSeconds(-1)); // negative → 0
    try std.testing.expectEqual(@as(i64, 0), SubagentBatchResultTool.clampWaitSeconds(-999));
    try std.testing.expectEqual(@as(i64, 1), SubagentBatchResultTool.clampWaitSeconds(1));
    try std.testing.expectEqual(@as(i64, 120), SubagentBatchResultTool.clampWaitSeconds(120));
    try std.testing.expectEqual(@as(i64, 120), SubagentBatchResultTool.clampWaitSeconds(121)); // over → ceiling
    try std.testing.expectEqual(@as(i64, 120), SubagentBatchResultTool.clampWaitSeconds(999));
    try std.testing.expectEqual(@as(i64, 120), SubagentBatchResultTool.clampWaitSeconds(std.math.maxInt(i64)));
}

// ── S1a (Package 3 Task 4) — ungated read-only collector + blocking collect ──

/// S1a test helper — mark every task in a batch terminal after a delay, from
/// a separate thread, under the manager mutex (the tracker's LOCK INVARIANT).
/// Simulates the batch's tasks reaching a terminal state mid-wait.
fn markBatchTerminalAfterDelay(manager: *SubagentManager, batch_id: []const u8, task_ids: []const u64, delay_ms: u64) void {
    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
    manager.mutex.lock();
    defer manager.mutex.unlock();
    for (task_ids) |tid| manager.batches.markTerminal(batch_id, tid);
}

test "subagent_batch_result S1a: returns results on a non-Superpowers turn (gate removed)" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    // Register a batch directly in the tracker (LOCK INVARIANT: hold the
    // manager mutex) — no OS threads, no provider needed.
    {
        manager.mutex.lock();
        defer manager.mutex.unlock();
        const now = std.time.milliTimestamp();
        try manager.batches.register("batch:1:100", &[_]u64{ 501, 502 }, "agent:test:user:1:main", now, now + 60_000);
    }

    // NON-Superpowers turn: the collector is read-only — collecting an
    // already-dispatched batch is not a fan-out privilege. The out-of-band
    // wake turn (superpowers unset on the wake lane) and ordinary follow-up
    // turns must be able to recover results.
    root.setTurnContext(.{ .superpowers_mode = false });
    defer root.clearTurnContext();

    var sbt = SubagentBatchResultTool{ .manager = &manager };
    const t = sbt.tool();
    const parsed = try root.parseTestArgs("{\"batch_id\":\"batch:1:100\"}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.success) std.testing.allocator.free(result.output);

    // Results, not the refusal string.
    try std.testing.expect(result.success);
    try std.testing.expect(result.output[0] == '[');
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"task_id\":501") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"task_id\":502") != null);
}

test "subagent_batch_result S1a: wait_seconds blocks until the batch is terminal — one call" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    const task_ids = [_]u64{ 601, 602 };
    {
        manager.mutex.lock();
        defer manager.mutex.unlock();
        const now = std.time.milliTimestamp();
        try manager.batches.register("batch:2:200", &task_ids, "agent:test:user:1:main", now, now + 600_000);
    }

    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();

    // Complete the batch from another thread ~400 ms after the call starts.
    // (defer join runs BEFORE manager.deinit — LIFO — so the helper can never
    // touch a deinitialized tracker, even when an assert below fails first.)
    const helper = try std.Thread.spawn(.{}, markBatchTerminalAfterDelay, .{ &manager, "batch:2:200", &task_ids, 400 });
    defer helper.join();

    var sbt = SubagentBatchResultTool{ .manager = &manager };
    const t = sbt.tool();
    const parsed = try root.parseTestArgs("{\"batch_id\":\"batch:2:200\",\"wait_seconds\":10}");
    defer parsed.deinit();

    const started_ms = std.time.milliTimestamp();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    const elapsed_ms = std.time.milliTimestamp() - started_ms;
    defer if (result.success) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    // ONE call returned the whole batch after an in-call wait: waited_ms
    // observability field present, every task present.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"waited_ms\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"results\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"task_id\":601") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"task_id\":602") != null);
    // It genuinely blocked (the batch cannot be terminal before the helper
    // runs at ~400 ms) and returned on terminality — far below the 10 s cap.
    try std.testing.expect(elapsed_ms >= 300);
    try std.testing.expect(elapsed_ms < 8_000);
}

test "subagent_batch_result S1a: wait_seconds returns current states at the deadline, not an error" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    // One task that NEVER completes — the wait must expire, then report the
    // current (non-terminal) state rather than failing.
    {
        manager.mutex.lock();
        defer manager.mutex.unlock();
        const now = std.time.milliTimestamp();
        try manager.batches.register("batch:3:300", &[_]u64{701}, "agent:test:user:1:main", now, now + 600_000);
    }

    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();

    var sbt = SubagentBatchResultTool{ .manager = &manager };
    const t = sbt.tool();
    const parsed = try root.parseTestArgs("{\"batch_id\":\"batch:3:300\",\"wait_seconds\":1}");
    defer parsed.deinit();

    const started_ms = std.time.milliTimestamp();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    const elapsed_ms = std.time.milliTimestamp() - started_ms;
    defer if (result.success) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"waited_ms\":") != null);
    // The task is reported in its CURRENT non-terminal state ("unknown" here —
    // tracker-registered id with no TaskState), not dropped, not an error.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"task_id\":701") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"status\":\"unknown\"") != null);
    // The call blocked to (about) the 1 s wait deadline.
    try std.testing.expect(elapsed_ms >= 900);
    try std.testing.expect(elapsed_ms < 5_000);
}

test "subagent_batch_result S1a: wait_seconds on an unknown batch fails immediately (no wait)" {
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
    const parsed = try root.parseTestArgs("{\"batch_id\":\"batch:9999:never\",\"wait_seconds\":30}");
    defer parsed.deinit();

    const started_ms = std.time.milliTimestamp();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    const elapsed_ms = std.time.milliTimestamp() - started_ms;
    defer if (result.error_msg) |em| std.testing.allocator.free(em);

    // H7 contract unchanged — and no waiting on nonexistent ids.
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "batch:9999:never") != null);
    try std.testing.expect(elapsed_ms < 2_000);
}

test "subagent_batch_result S1a: wait_seconds=0 keeps the bare-array non-blocking output" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    {
        manager.mutex.lock();
        defer manager.mutex.unlock();
        const now = std.time.milliTimestamp();
        try manager.batches.register("batch:4:400", &[_]u64{801}, "agent:test:user:1:main", now, now + 60_000);
    }

    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();

    var sbt = SubagentBatchResultTool{ .manager = &manager };
    const t = sbt.tool();
    const parsed = try root.parseTestArgs("{\"batch_id\":\"batch:4:400\",\"wait_seconds\":0}");
    defer parsed.deinit();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    defer if (result.success) std.testing.allocator.free(result.output);

    // Zero regression: byte-shape identical to the original non-blocking read.
    try std.testing.expect(result.success);
    try std.testing.expect(result.output[0] == '[');
    try std.testing.expect(std.mem.indexOf(u8, result.output, "waited_ms") == null);
}

test "subagent_batch_result S1a: negative wait_seconds clamps to 0 (non-blocking)" {
    var cfg = config_mod.Config{
        .workspace_dir = "/tmp/yc",
        .config_path = "/tmp/yc/config.json",
        .allocator = std.testing.allocator,
    };
    var manager = SubagentManager.init(std.testing.allocator, &cfg, null, .{});
    defer manager.deinit();

    {
        manager.mutex.lock();
        defer manager.mutex.unlock();
        const now = std.time.milliTimestamp();
        try manager.batches.register("batch:5:500", &[_]u64{901}, "agent:test:user:1:main", now, now + 60_000);
    }

    root.setTurnContext(.{ .superpowers_mode = true });
    defer root.clearTurnContext();

    var sbt = SubagentBatchResultTool{ .manager = &manager };
    const t = sbt.tool();
    const parsed = try root.parseTestArgs("{\"batch_id\":\"batch:5:500\",\"wait_seconds\":-5}");
    defer parsed.deinit();

    const started_ms = std.time.milliTimestamp();
    const result = try t.execute(std.testing.allocator, parsed.value.object);
    const elapsed_ms = std.time.milliTimestamp() - started_ms;
    defer if (result.success) std.testing.allocator.free(result.output);

    try std.testing.expect(result.success);
    try std.testing.expect(result.output[0] == '[');
    try std.testing.expect(std.mem.indexOf(u8, result.output, "waited_ms") == null);
    try std.testing.expect(elapsed_ms < 1_000);
}

test "subagent_batch_result S1a: description and schema teach wait_seconds" {
    var sbt = SubagentBatchResultTool{};
    const t = sbt.tool();
    try std.testing.expect(std.mem.indexOf(u8, t.description(), "wait_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.parametersJson(), "wait_seconds") != null);
}
