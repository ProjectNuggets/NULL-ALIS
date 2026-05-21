//! V1.13 Day 4.2 — Procedural memory render + capture orchestrator.
//!
//! Layer 6 of the brain: skill execution traces. Maintains the session's
//! SkillExecution table (postgres skill_executions), which logs every tool-call
//! burst as a discrete skill execution with its tool manifest + outcome_quality
//! score. The capture gate fires when total tool calls across a session exceed
//! CAPTURE_TOOL_THRESHOLD, producing one SkillExecution record per capture.
//!
//! Used by Agent's turnOutcome to record procedural memory at
//! session-end (turn ~N when capture fires). If skill_executions.outcome_quality
//! is null or 0, memory eviction (v1.14.19 SC1) treats the record as low-value.
//! Non-null outcome_quality enables proportional scoring in memory ranking:
//! higher scores → longer retention; lower scores → earlier eviction.
//!
//! v1.14.18-A F3 update: outcome_quality is now driven by goal_loop.GoalStatus
//! when available (met=0.9, stuck=0.3, max_iterations=0.4, in_progress=0.5).
//! Falls back to tool-count heuristic when goal_status is null. The capture gate
//! in commands.zig:1576-1605 was rewritten to track session-wide tool count
//! (was last_turn_tool_count, which left skill_executions empty in production —
//! postgres confirmed 0 rows before fix; root cause: per-turn tracking never
//! accumulated to threshold when tools distributed across turns, e.g., 2/3/1/4
//! pattern).
//!
//! Future refinement (Day 4.3): detect specific skill archetypes (e.g., "web search → summarize",
//! "code review → refactor proposal") and label skill_name granularly instead of
//! GENERIC_SKILL_NAME. Requires input/output summarization to extract the skill shape.

const std = @import("std");
const log = std.log.scoped(.procedural_memory);

const memory_root = @import("../memory/root.zig");
const SkillExecution = memory_root.SkillExecution;
const zaki_state = @import("../zaki_state.zig");
const text_norm = @import("../memory/text_norm.zig");

const goal_loop = @import("goal_loop.zig");

/// Max recent skill traces to render in the prompt block. 3 gives the
/// agent context without bloating the volatile section.
pub const RENDER_TOP_N: usize = 3;

/// Tool-call threshold for capturing a skill execution. Below this, the
/// turn is conversational, not skill-shaped.
pub const CAPTURE_TOOL_THRESHOLD: u32 = 5;

/// Generic skill name used for non-specific captures. Future Day 4.3
/// will detect specific skill invocations and use their actual names.
pub const GENERIC_SKILL_NAME: []const u8 = "generic_multi_tool";

/// Result of `loadForRender` — top-N skill executions to inject. Caller
/// must call `freeSkillExecutions`.
pub const RenderSet = struct {
    traces: []SkillExecution,

    pub fn deinit(self: *const RenderSet, allocator: std.mem.Allocator) void {
        memory_root.freeSkillExecutions(allocator, self.traces);
    }
};

/// Load top-N most-recent skill traces for (user, skill_name) for prompt
/// rendering. Returns empty set when postgres unavailable or no traces
/// exist — failure-soft.
pub fn loadForRender(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    skill_name: []const u8,
) RenderSet {
    const traces = state_mgr.listRecentSkillExecutions(allocator, user_id, skill_name, RENDER_TOP_N) catch |err| {
        log.warn("procedural_memory.load_failed err={s} user={d} skill={s}", .{
            @errorName(err), user_id, skill_name,
        });
        return .{ .traces = allocator.alloc(SkillExecution, 0) catch &.{} };
    };
    return .{ .traces = traces };
}

/// Render skill traces into the volatile system prompt block.
/// Format:
///   <recent_skill_traces skill="generic_multi_tool" count="3">
///     [trace_id 12, 2026-05-08]: task=user wanted content strategy
///       executed: 7 steps, used tools: memory_recall, brain_graph
///       outcome: 0.80 (positive feedback next turn)
///     [trace_id 11, 2026-05-07]: task=user asked for image
///       executed: 3 steps, used tools: image_generate
///       outcome: 0.95
///   </recent_skill_traces>
///
/// Caller frees returned string. Empty when no traces.
pub fn renderBlock(
    allocator: std.mem.Allocator,
    skill_name: []const u8,
    traces: []const SkillExecution,
) ![]u8 {
    if (traces.len == 0) return allocator.alloc(u8, 0);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print("<recent_skill_traces skill=\"{s}\" count=\"{d}\">\n", .{ skill_name, traces.len });
    for (traces) |t| {
        // Format created_at as ISO date (YYYY-MM-DD) for compact display.
        const epoch_days: i64 = @divFloor(t.created_at_unix, 86400);
        // Approx ISO date — sufficient for "when was this trace" intuition.
        // Full ISO formatting would require std.time.epoch.EpochDay decomposition.
        const days_since_epoch = epoch_days;
        const summary_text = if (t.task_summary) |s| text_norm.truncateUtf8(s, 120) else "";
        const oq_str: f64 = t.outcome_quality orelse 0.0;
        const fb_text = if (t.user_feedback) |f| f else "(no feedback)";

        try w.print(
            "  [trace_id {d}, day_epoch={d}]: task={s}\n",
            .{ t.id, days_since_epoch, summary_text },
        );
        // Steps_executed is JSON; truncate display to keep prompt compact.
        const steps_truncated = text_norm.truncateUtf8(t.steps_executed_json, 200);
        try w.print("    steps: {s}\n", .{steps_truncated});
        try w.print("    outcome: {d:.2} feedback: {s}\n", .{ oq_str, fb_text });
    }
    try w.writeAll("</recent_skill_traces>\n");

    return buf.toOwnedSlice(allocator);
}

/// Capture a skill execution from a turn. Called at session_end when
/// `total_tool_calls >= CAPTURE_TOOL_THRESHOLD`. Stores a coarse-grained
/// trace tagged with the user's task summary + the tool-call manifest.
///
/// Failure-soft — any error is logged, returns 0.
pub fn captureSession(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    session_id: ?[]const u8,
    task_summary: ?[]const u8,
    tool_call_names: []const []const u8,
    total_tool_calls: u32,
    goal_status: ?goal_loop.GoalStatus,
    reflection_trail_json: []const u8,
) ?i64 {
    if (total_tool_calls < CAPTURE_TOOL_THRESHOLD) return null;

    // Build steps_executed JSON: array of strings (tool names). Future
    // refinement: include input/output excerpts per tool call.
    var steps_buf: std.ArrayListUnmanaged(u8) = .{};
    defer steps_buf.deinit(allocator);
    steps_buf.writer(allocator).writeAll("[") catch return null;
    for (tool_call_names, 0..) |name, i| {
        if (i > 0) steps_buf.writer(allocator).writeAll(",") catch return null;
        steps_buf.writer(allocator).print("{f}", .{std.json.fmt(name, .{})}) catch return null;
    }
    steps_buf.writer(allocator).writeAll("]") catch return null;

    // Heuristic outcome_quality: more tool calls usually = more
    // substantive task. Cap at 0.85 (initial; refined by feedback).
    const oq: f64 = if (goal_status) |gs| switch (gs) {
        .met => 0.9,
        .stuck => 0.3,
        .max_iterations => 0.4,
        .in_progress => 0.5,
    } else std.math.clamp(@as(f64, @floatFromInt(total_tool_calls)) / 20.0, 0.5, 0.85);

    const id = state_mgr.insertSkillExecution(
        user_id,
        session_id,
        GENERIC_SKILL_NAME,
        task_summary,
        steps_buf.items,
        reflection_trail_json, // v1.14.18-B G5: pass reflection trail
        oq,
    ) catch |err| {
        log.warn("procedural_memory.capture_failed err={s}", .{@errorName(err)});
        return null;
    };
    log.info(
        "procedural_memory.captured trace_id={d} user={d} skill={s} tool_calls={d}",
        .{ id, user_id, GENERIC_SKILL_NAME, total_tool_calls },
    );
    return id;
}

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

test "renderBlock empty traces returns empty string" {
    const allocator = std.testing.allocator;
    const empty: []const SkillExecution = &.{};
    const out = try renderBlock(allocator, "generic_multi_tool", empty);
    defer allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "renderBlock formats single trace" {
    const allocator = std.testing.allocator;
    const trace = SkillExecution{
        .id = 42,
        .user_id = 1,
        .session_id = null,
        .skill_name = "generic_multi_tool",
        .task_summary = "build content strategy",
        .steps_executed_json = "[\"memory_recall\",\"brain_graph\"]",
        .assumptions_made_json = "[]",
        .user_feedback = null,
        .outcome_quality = 0.85,
        .created_at_unix = 1_700_000_000,
    };
    const traces = [_]SkillExecution{trace};
    const out = try renderBlock(allocator, "generic_multi_tool", &traces);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<recent_skill_traces") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "trace_id 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "build content strategy") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "outcome: 0.85") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "</recent_skill_traces>") != null);
}

test "RENDER_TOP_N is 3" {
    try std.testing.expectEqual(@as(usize, 3), RENDER_TOP_N);
}

test "CAPTURE_TOOL_THRESHOLD is 5" {
    try std.testing.expectEqual(@as(u32, 5), CAPTURE_TOOL_THRESHOLD);
}
