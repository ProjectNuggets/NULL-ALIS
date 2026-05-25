//! `memory_doctor` — agent-side wrapper over the same in-process
//! diagnostic routine exposed at `/api/v1/users/:id/diagnostics/memory-doctor`.
//!
//! Closes the audit gap that the agent had zero ability to introspect
//! its own memory subsystem health from inside a turn (today this was
//! only reachable via the `/doctor` slash command or the FE
//! PowerUserSheet — both human-driven). When `memory_recall` returns
//! empty / stale results, or when the user reports the agent "forgot"
//! something it should have remembered, the agent can now self-check
//! Layer 0-7 of the brain architecture before reaching for heavier
//! tools (brain_graph, memory_purge_topic, etc.).
//!
//! Implementation mirrors `handleUserDiagnosticsMemoryDoctor` in
//! gateway.zig: walks every `MemoryRuntime` component (primary store,
//! vector plane, outbox, cache, retrieval engine, rollout policy,
//! lifecycle settings) and emits a `DiagnosticReport`. The HTTP path
//! wraps the human-readable text in a JSON envelope; we do the same
//! so the tool result is uniformly machine-parseable while still
//! preserving the rich human-readable detail the agent benefits from.

const std = @import("std");
const root = @import("root.zig");
const memory_mod = @import("../memory/root.zig");
const mem_lifecycle_diag = @import("../memory/lifecycle/diagnostics.zig");
const observability = @import("../observability.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const log = std.log.scoped(.memory_doctor);

pub const MemoryDoctorTool = struct {
    /// Bound at tool-construction time via `bindMemoryRuntime` (mirrors
    /// the pattern used by every other memory_* tool). When null we
    /// surface a clean "memory runtime not configured" error rather
    /// than crashing — handles the standalone CLI / pre-tenant path
    /// where no MemoryRuntime has been attached yet.
    mem_rt: ?*memory_mod.MemoryRuntime = null,

    pub const tool_name = "memory_doctor";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Return a structured health report for this user's memory subsystem (Layer 0-7).",
        .use_when = &.{
            "memory_recall returned empty or stale results and you need to confirm the brain is healthy",
            "User reports the agent 'forgot' something it should have remembered — diagnose before re-storing",
            "Before reaching for brain_graph queries, verify the graph layer is loaded and the retrieval pipeline is wired",
        },
        .do_not_use_for = &.{
            "memory_recall — for fetching specific stored facts rather than subsystem health",
            "brain_graph — for navigating the entity/edge graph rather than checking its health",
            "runtime_info — for runtime/session/integration state outside the memory subsystem",
        },
        .cost_note = "In-process inspection; no Postgres or vector-store reads beyond cheap counts.",
        .completion_hint = "Returns JSON with backend, capabilities, vector plane, outbox, cache, and pipeline-stage flags.",
        .see_also = &.{
            "memory_recall — fetch a specific fact after confirming the backend is healthy",
            "brain_graph — explore entities/edges once the graph layer is confirmed loaded",
            "runtime_info — runtime-wide state when the question is not memory-specific",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("memory_doctor", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Read-only diagnostic over the memory subsystem. Returns the same report shape " ++
        "the /memory doctor slash command and the FE PowerUserSheet surface — backend " ++
        "health, vector plane, outbox queue, response cache, retrieval pipeline stages.";

    pub const tool_params =
        \\{"type":"object","properties":{}}
    ;

    pub const tool_metadata: @import("metadata.zig").ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MemoryDoctorTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *MemoryDoctorTool, allocator: std.mem.Allocator, _: JsonObjectMap) !ToolResult {
        // HIGH 2.A: usage counter so operators can see how often the
        // agent self-checks Layer 0-7 health. A sudden spike often
        // pairs with a recall-failure user complaint — the metric is
        // the early-warning signal for that pattern.
        observability.recordMetricGlobal(.{ .memory_doctor_total = 1 });

        const rt = self.mem_rt orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "memory_doctor unavailable: memory runtime not configured for this session"),
                .output = "",
            };
        };

        const report = mem_lifecycle_diag.diagnose(rt);
        // The HTTP endpoint wraps the human-readable text in a JSON
        // envelope today (structured JSON formatter is a planned
        // follow-up — see handleUserDiagnosticsMemoryDoctor's TODO).
        // We do the same so the agent always sees a uniformly-parseable
        // JSON object regardless of which path produced it.
        const text = mem_lifecycle_diag.formatReport(report, allocator) catch |err| {
            log.warn("memory_doctor report rendering failed err={s}", .{@errorName(err)});
            const msg = try std.fmt.allocPrint(allocator, "memory_doctor: report rendering failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };
        defer allocator.free(text);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        try w.writeAll("{\"backend\":\"");
        try jsonEscapeInto(w, report.backend_name);
        try w.print("\",\"healthy\":{s},\"entries\":{d},\"vector_active\":{s},\"outbox_active\":{s},\"cache_active\":{s},\"retrieval_sources\":{d},\"rollout_mode\":\"", .{
            if (report.backend_healthy) "true" else "false",
            report.entry_count,
            if (report.vector_store_active) "true" else "false",
            if (report.outbox_active) "true" else "false",
            if (report.cache_active) "true" else "false",
            report.retrieval_sources,
        });
        try jsonEscapeInto(w, report.rollout_mode);
        try w.writeAll("\",\"report_text\":\"");
        try jsonEscapeInto(w, text);
        try w.writeAll("\"}");

        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
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

test "memory_doctor tool name" {
    var t = MemoryDoctorTool{};
    try std.testing.expectEqualStrings("memory_doctor", t.tool().name());
}

test "memory_doctor schema is an empty-object accepting schema" {
    var t = MemoryDoctorTool{};
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"object\"") != null);
    // No required params — agent calls it as a bare diagnostic.
    try std.testing.expect(std.mem.indexOf(u8, schema, "required") == null);
}

test "memory_doctor without mem_rt returns clean error" {
    var t = MemoryDoctorTool{};
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);

    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "memory runtime not configured") != null);
}

test "memory_doctor declares read_only + background_safe metadata" {
    try std.testing.expect(MemoryDoctorTool.tool_metadata.flags.read_only);
    try std.testing.expect(MemoryDoctorTool.tool_metadata.flags.background_safe);
    try std.testing.expect(!MemoryDoctorTool.tool_metadata.flags.mutating);
    try std.testing.expectEqual(@import("metadata.zig").CostClass.a, MemoryDoctorTool.tool_metadata.cost_class);
}

test "memory_doctor description struct passes lint" {
    // The comptime lintToolDescription block fires at compile time;
    // this test guards the surface lint cares about (.what length,
    // sentence terminator, sibling refs).
    const desc = MemoryDoctorTool.tool_description_struct;
    try std.testing.expect(desc.what.len >= 20 and desc.what.len <= 100);
    try std.testing.expect(desc.what[desc.what.len - 1] == '.');
    try std.testing.expect(desc.use_when.len >= 2 and desc.use_when.len <= 4);
    try std.testing.expect(desc.do_not_use_for.len >= 2);
}

test "memory_doctor tool() returns a Tool with our vtable" {
    var t = MemoryDoctorTool{};
    const tool = t.tool();
    try std.testing.expectEqual(&MemoryDoctorTool.vtable, tool.vtable);
}
