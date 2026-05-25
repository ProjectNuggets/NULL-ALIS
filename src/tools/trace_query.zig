//! `trace_query` — agent-side wrapper over `RunTraceStore`.
//!
//! Closes the audit gap that the agent today CANNOT reflect on its own
//! action history except by scraping the chat transcript. The
//! `RunTraceStore` already holds a bounded, sanitized log of every
//! recent run's events (LLM calls, tool starts/results, approvals,
//! turn stages, agent_end markers); the HTTP endpoint at
//! `/api/v1/users/:id/traces[/:id]` exposes this to the FE trace
//! browser. This tool gives the agent the same view, scoped to the
//! current process's trace store (runs are global; user scoping
//! happens at the HTTP layer via auth — at the tool layer the agent
//! is already running as the user, so the in-process store IS the
//! agent's view).
//!
//! Two modes:
//!   * `{run_id: "..."}` — return the full sanitized event timeline
//!     of a single run. Used when the agent wants to answer "what
//!     tools did I fire on turn X" with maximum detail.
//!   * `{limit?: N}` — return the most-recent N runs (default 5,
//!     max 20). Used for "what have I been doing lately" reflection.
//!
//! Cost class A — read-only snapshot of an in-memory store. No
//! Postgres reads, no provider calls.

const std = @import("std");
const root = @import("root.zig");
const run_trace_store_mod = @import("../run_trace_store.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// Hard cap on the recent-runs list — keeps response size predictable
/// even if the operator bumps `DEFAULT_MAX_RUNS` above 20. Mirrors the
/// memory_recall convention of capping the in-context projection.
const TRACE_QUERY_MAX_LIMIT: usize = 20;
const TRACE_QUERY_DEFAULT_LIMIT: usize = 5;

pub const TraceQueryTool = struct {
    /// Bound at tool-construction time. When null we surface a clean
    /// "trace store not configured" error rather than crashing —
    /// handles standalone CLI / pre-tenant paths.
    store: ?*run_trace_store_mod.RunTraceStore = null,

    pub const tool_name = "trace_query";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Read this user's recent run traces — the structured event log of past turns.",
        .use_when = &.{
            "User asks 'what tools did you fire on the last turn?' and the answer is not in the chat history",
            "Reflecting on prior turn behavior before deciding what to do next — e.g. avoid re-firing a recently-failed tool",
            "Debugging a stale or wrong result by checking what tools actually ran in the producing turn",
        },
        .do_not_use_for = &.{
            "transcript_read — for the raw chat transcript rather than the tool/event timeline",
            "context_snapshot — for the agent's own current state rather than past run events",
            "memory_recall — for stored facts and preferences rather than execution history",
        },
        .cost_note = "In-process read of a bounded RAM store; no Postgres or provider calls.",
        .completion_hint = "Returns recent runs (newest first) or one run's sanitized event timeline.",
        .see_also = &.{
            "transcript_read — pair with this to correlate tool calls back to the conversational turn",
            "context_snapshot — the agent's current self-state vs past run events",
            "runtime_info — runtime/integration state vs past behavior",
        },
    };

    comptime {
        @setEvalBranchQuota(4000);
        @import("lint.zig").lintToolDescription("trace_query", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Read recent agent run traces. Pass `run_id` for a specific run's full event " ++
        "timeline, or omit it for the N most-recent runs (default 5, max 20). Each event " ++
        "carries tool name, kind, timestamp, success/failure, and duration where known.";

    pub const tool_params =
        \\{"type":"object","properties":{"run_id":{"type":"string","description":"Optional specific run id; when present the limit field is ignored and the full event timeline is returned."},"limit":{"type":"integer","description":"Max number of recent runs to return when run_id is omitted (default 5, max 20)."}}}
    ;

    pub const tool_metadata: @import("metadata.zig").ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *TraceQueryTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *TraceQueryTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const store = self.store orelse {
            return ToolResult{
                .success = false,
                .output = try allocator.dupe(u8, "trace_query unavailable: run trace store not configured"),
            };
        };

        if (root.getString(args, "run_id")) |run_id| {
            if (run_id.len == 0) return ToolResult.fail("'run_id' must not be empty");
            return self.snapshotSingleRun(allocator, store, run_id);
        }

        var limit: usize = TRACE_QUERY_DEFAULT_LIMIT;
        if (root.getInt(args, "limit")) |v| {
            if (v <= 0) return ToolResult.fail("'limit' must be a positive integer");
            const requested: usize = @intCast(@min(v, @as(i64, @intCast(TRACE_QUERY_MAX_LIMIT))));
            limit = requested;
        }
        return self.listRecentRuns(allocator, store, limit);
    }

    fn snapshotSingleRun(
        _: *TraceQueryTool,
        allocator: std.mem.Allocator,
        store: *run_trace_store_mod.RunTraceStore,
        run_id: []const u8,
    ) !ToolResult {
        const snap_opt = store.snapshotRun(allocator, run_id) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "trace_query: snapshot failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        var snap = snap_opt orelse {
            return ToolResult{
                .success = false,
                .output = try std.fmt.allocPrint(allocator, "no run found with id '{s}'", .{run_id}),
            };
        };
        defer snap.deinit();

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        try w.writeAll("{\"run_id\":\"");
        try jsonEscapeInto(w, snap.run_id);
        try w.print(
            "\",\"first_event_ms\":{d},\"last_event_ms\":{d},\"truncated\":{s},\"events\":[",
            .{ snap.first_event_ms, snap.last_event_ms, if (snap.truncated) "true" else "false" },
        );
        for (snap.events, 0..) |*evt, i| {
            if (i > 0) try w.writeAll(",");
            try serializeTraceEventJson(w, evt);
        }
        try w.writeAll("]}");
        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }

    fn listRecentRuns(
        _: *TraceQueryTool,
        allocator: std.mem.Allocator,
        store: *run_trace_store_mod.RunTraceStore,
        limit: usize,
    ) !ToolResult {
        var index = store.listRuns(allocator) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "trace_query: list failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer index.deinit();

        // listRuns sorts ascending by first_event_ms (chronological).
        // For "recent N" reflection we want NEWEST first — slice the
        // tail of the index in reverse. This avoids re-sorting the
        // owned slice in place.
        const total = index.entries.len;
        const take = @min(limit, total);
        const start = total - take;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        try w.print("{{\"total_runs_retained\":{d},\"returned\":{d},\"traces\":[", .{ total, take });
        var emitted: usize = 0;
        var i: usize = total;
        while (i > start) {
            i -= 1;
            const entry = index.entries[i];
            if (emitted > 0) try w.writeAll(",");
            try w.writeAll("{\"run_id\":\"");
            try jsonEscapeInto(w, entry.run_id);
            try w.print(
                "\",\"event_count\":{d},\"first_event_ms\":{d},\"last_event_ms\":{d},\"truncated\":{s}}}",
                .{
                    entry.event_count,
                    entry.first_event_ms,
                    entry.last_event_ms,
                    if (entry.truncated) "true" else "false",
                },
            );
            emitted += 1;
        }
        try w.writeAll("]}");
        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

/// Serialize one trace event — mirrors `serializeTraceEventJson` in
/// gateway.zig so the agent's view of an event matches what the FE
/// trace browser sees.
fn serializeTraceEventJson(w: anytype, evt: *const run_trace_store_mod.TraceEvent) !void {
    try w.writeAll("{\"kind\":\"");
    try jsonEscapeInto(w, evt.kind.toSlice());
    try w.print("\",\"ts_ms\":{d}", .{evt.ts_ms});
    if (evt.phase) |v| {
        try w.writeAll(",\"phase\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.tool) |v| {
        try w.writeAll(",\"tool\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.tool_use_id) |v| {
        try w.writeAll(",\"tool_use_id\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.label) |v| {
        try w.writeAll(",\"label\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.risk_level) |v| {
        try w.writeAll(",\"risk_level\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.status) |v| {
        try w.writeAll(",\"status\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.task_id) |v| {
        try w.writeAll(",\"task_id\":\"");
        try jsonEscapeInto(w, v);
        try w.writeAll("\"");
    }
    if (evt.success) |v| try w.print(",\"success\":{s}", .{if (v) "true" else "false"});
    if (evt.duration_ms) |v| try w.print(",\"duration_ms\":{d}", .{v});
    if (evt.iteration) |v| try w.print(",\"iteration\":{d}", .{v});
    if (evt.exit_code) |v| try w.print(",\"exit_code\":{d}", .{v});
    if (evt.usage_tokens) |v| try w.print(",\"usage_tokens\":{d}", .{v});
    try w.writeAll("}");
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

test "trace_query tool name" {
    var t = TraceQueryTool{};
    try std.testing.expectEqualStrings("trace_query", t.tool().name());
}

test "trace_query schema declares run_id and limit, neither required" {
    var t = TraceQueryTool{};
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "run_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "required") == null);
}

test "trace_query without store returns clean error" {
    var t = TraceQueryTool{};
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "trace store not configured") != null);
}

test "trace_query rejects empty run_id" {
    var store = run_trace_store_mod.RunTraceStore.init(std.testing.allocator, 8, 16);
    defer store.deinit();
    var t = TraceQueryTool{ .store = &store };
    const parsed = try root.parseTestArgs("{\"run_id\":\"\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "must not be empty") != null);
}

test "trace_query rejects non-positive limit" {
    var store = run_trace_store_mod.RunTraceStore.init(std.testing.allocator, 8, 16);
    defer store.deinit();
    var t = TraceQueryTool{ .store = &store };
    const parsed = try root.parseTestArgs("{\"limit\":0}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "positive integer") != null);
}

test "trace_query empty store returns empty list" {
    var store = run_trace_store_mod.RunTraceStore.init(std.testing.allocator, 8, 16);
    defer store.deinit();
    var t = TraceQueryTool{ .store = &store };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"total_runs_retained\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"returned\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"traces\":[]") != null);
}

test "trace_query returns 404-shape when run_id is not found" {
    var store = run_trace_store_mod.RunTraceStore.init(std.testing.allocator, 8, 16);
    defer store.deinit();
    var t = TraceQueryTool{ .store = &store };
    const parsed = try root.parseTestArgs("{\"run_id\":\"missing-run-xyz\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "no run found") != null);
}

test "trace_query lists most-recent runs newest-first when populated" {
    const observability = @import("../observability.zig");
    var store = run_trace_store_mod.RunTraceStore.init(std.testing.allocator, 8, 16);
    defer store.deinit();
    const obs = store.observer();
    // Fire three runs with synthetic events. The trace store derives
    // run_id from the event payload; emit `agent_end` events which
    // carry a run_id field.
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        var id_buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "run-{d}", .{i});
        const evt = observability.ObserverEvent{
            .agent_end = .{
                .duration_ms = 100,
                .tokens_used = 50,
                .run_id = id,
            },
        };
        obs.recordEvent(&evt);
        // Force a small ts gap so the chronological sort is stable.
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }

    var t = TraceQueryTool{ .store = &store };
    const parsed = try root.parseTestArgs("{\"limit\":2}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"total_runs_retained\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"returned\":2") != null);
    // Newest-first means run-2 appears before run-1 in the output.
    const r2 = std.mem.indexOf(u8, result.output, "run-2") orelse return error.TestUnexpectedResult;
    const r1 = std.mem.indexOf(u8, result.output, "run-1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(r2 < r1);
}

test "trace_query declares read_only metadata" {
    try std.testing.expect(TraceQueryTool.tool_metadata.flags.read_only);
    try std.testing.expect(TraceQueryTool.tool_metadata.flags.background_safe);
    try std.testing.expectEqual(@import("metadata.zig").CostClass.a, TraceQueryTool.tool_metadata.cost_class);
}
