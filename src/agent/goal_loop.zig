const std = @import("std");

/// Goal status tracking for ReAct-style reflection loop.
/// Maps to outcome_quality signal in procedural_memory capture.
pub const GoalStatus = enum {
    in_progress, // Default; no progress verdict yet
    met, // Goal achieved
    stuck, // No progress detected; needs different approach
    max_iterations, // Iteration limit reached
};

/// Per-turn goal state. Lifetime = single turnOutcome call.
/// Accumulates progress notes across iterations within a turn.
pub const GoalState = struct {
    goal_text: []const u8,
    progress_notes: std.ArrayListUnmanaged([]const u8) = .empty,
    no_progress_count: u32 = 0,
    iteration_count: u32 = 0,
    status: GoalStatus = .in_progress,

    pub fn deinit(self: *GoalState, allocator: std.mem.Allocator) void {
        for (self.progress_notes.items) |note| {
            allocator.free(note);
        }
        self.progress_notes.deinit(allocator);
    }
};

/// Extract goal from user message (verbatim copy).
/// The goal is the user's stated intent; no transformation.
pub fn extractGoal(_: std.mem.Allocator, user_message: []const u8) ![]const u8 {
    return user_message;
}

/// Build reflection prompt for model emission.
/// Elicits structured <reflection> tags with goal_status attribute.
pub fn buildReflectionPrompt(
    allocator: std.mem.Allocator,
    goal_text: []const u8,
    iteration: u32,
    last_tool: ?[]const u8,
    last_result_summary: ?[]const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "\n<reflection iteration=\"");
    try buf.writer(allocator).print("{d}", .{iteration});
    try buf.appendSlice(allocator, "\"");

    if (last_tool) |tool| {
        try buf.appendSlice(allocator, " tool=\"");
        try buf.appendSlice(allocator, tool);
        try buf.appendSlice(allocator, "\"");
    }

    try buf.appendSlice(allocator, ">\n");
    try buf.appendSlice(allocator, "Goal: ");
    try buf.appendSlice(allocator, goal_text);
    try buf.appendSlice(allocator, "\n\n");

    if (last_result_summary) |summary| {
        try buf.appendSlice(allocator, "Last action result: ");
        try buf.appendSlice(allocator, summary);
        try buf.appendSlice(allocator, "\n\n");
    }

    try buf.appendSlice(allocator, "Assess progress:\n");
    try buf.appendSlice(allocator, "- Am I closer to the goal, or stuck?\n");
    try buf.appendSlice(allocator, "- What did I learn?\n");
    try buf.appendSlice(allocator, "- Next action: [tool_name or \"finalize\"]\n");
    try buf.appendSlice(allocator, "- goal_status: [in_progress|met|stuck] (your judgment)\n");
    try buf.appendSlice(allocator, "</reflection>\n");

    return try buf.toOwnedSlice(allocator);
}

/// Parse reflection output tolerantly.
/// Extracts goal_status attribute from <reflection> tag.
/// Returns .in_progress as default if tag/attribute missing (failure-soft).
pub fn parseReflection(reflection_text: []const u8) GoalStatus {
    // Look for goal_status="..." attribute
    const goal_status_prefix = "goal_status=\"";
    if (std.mem.indexOf(u8, reflection_text, goal_status_prefix)) |start| {
        const search_start = start + goal_status_prefix.len;
        if (search_start < reflection_text.len) {
            if (std.mem.indexOf(u8, reflection_text[search_start..], "\"")) |end| {
                const status_str = reflection_text[search_start .. search_start + end];
                if (std.mem.eql(u8, status_str, "met")) {
                    return .met;
                } else if (std.mem.eql(u8, status_str, "stuck")) {
                    return .stuck;
                } else if (std.mem.eql(u8, status_str, "max_iterations")) {
                    return .max_iterations;
                }
            }
        }
    }
    // Default to in_progress if not found or unparseable
    return .in_progress;
}

/// ToolInvocation minimal type for context building.
/// (Full definition in memory/root.zig; this is the subset we need.)
pub const ToolInvocation = struct {
    tool_name: []const u8,
    input: []const u8,
    output: []const u8,
};

/// Build prior attempts context anchored to goal.
/// Formats recent skill traces for injection at turn-start.
/// Format: <prior_attempts goal_shape="..." count=N>
///   tool1: input → output
///   tool2: input → output
/// </prior_attempts>
pub fn buildSkillTraceContext(
    allocator: std.mem.Allocator,
    traces: []const ToolInvocation,
    goal_text: []const u8,
) ![]const u8 {
    if (traces.len == 0) {
        return try allocator.dupe(u8, "");
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<prior_attempts goal_shape=\"");
    try buf.appendSlice(allocator, goal_text);
    try buf.appendSlice(allocator, "\" count=\"");
    try buf.writer(allocator).print("{d}", .{traces.len});
    try buf.appendSlice(allocator, "\">\n");

    for (traces) |trace| {
        try buf.appendSlice(allocator, trace.tool_name);
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, trace.input);
        try buf.appendSlice(allocator, " → ");
        try buf.appendSlice(allocator, trace.output);
        try buf.appendSlice(allocator, "\n");
    }

    try buf.appendSlice(allocator, "</prior_attempts>\n");

    return try buf.toOwnedSlice(allocator);
}

// ============================================================================
// TESTS
// ============================================================================

test "extractGoal copies user message verbatim" {
    const allocator = std.testing.allocator;
    const user_msg = "Find the root cause of the 500 error in auth service";
    const goal = try extractGoal(allocator, user_msg);
    try std.testing.expectEqualStrings(user_msg, goal);
}

test "buildReflectionPrompt includes goal, iteration, tool, and result" {
    const allocator = std.testing.allocator;
    const goal = "Fix the database connection timeout";
    const result_summary = "Query returned 0 rows";

    const prompt = try buildReflectionPrompt(
        allocator,
        goal,
        3,
        "database_query",
        result_summary,
    );
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "iteration=\"3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "tool=\"database_query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, goal) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, result_summary) != null);
}

test "parseReflection extracts goal_status=met" {
    const reflection = "<reflection goal_status=\"met\">Success achieved</reflection>";
    const status = parseReflection(reflection);
    try std.testing.expectEqual(GoalStatus.met, status);
}

test "parseReflection extracts goal_status=stuck" {
    const reflection = "<reflection goal_status=\"stuck\">No progress made</reflection>";
    const status = parseReflection(reflection);
    try std.testing.expectEqual(GoalStatus.stuck, status);
}

test "parseReflection extracts goal_status=max_iterations" {
    const reflection = "<reflection goal_status=\"max_iterations\">Limit reached</reflection>";
    const status = parseReflection(reflection);
    try std.testing.expectEqual(GoalStatus.max_iterations, status);
}

test "parseReflection defaults to in_progress when status missing" {
    const reflection = "<reflection>No status attribute here</reflection>";
    const status = parseReflection(reflection);
    try std.testing.expectEqual(GoalStatus.in_progress, status);
}

test "buildSkillTraceContext formats traces with goal shape" {
    const allocator = std.testing.allocator;
    var traces: [2]ToolInvocation = .{
        .{ .tool_name = "file_read", .input = "config.json", .output = "json content" },
        .{ .tool_name = "grep", .input = "error", .output = "error found at line 42" },
    };

    const goal = "Debug the error in config";
    const context = try buildSkillTraceContext(allocator, &traces, goal);
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "prior_attempts") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, goal) != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "file_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "grep") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "count=\"2\"") != null);
}

test "buildSkillTraceContext returns empty string for no traces" {
    const allocator = std.testing.allocator;
    const context = try buildSkillTraceContext(allocator, &.{}, "any goal");
    defer allocator.free(context);
    try std.testing.expectEqualStrings("", context);
}

test "GoalState can track progress notes" {
    const allocator = std.testing.allocator;
    var state = GoalState{
        .goal_text = "Test goal",
    };
    defer state.deinit(allocator);

    const note1 = try allocator.dupe(u8, "First attempt failed");
    try state.progress_notes.append(allocator, note1);

    const note2 = try allocator.dupe(u8, "Second attempt succeeded");
    try state.progress_notes.append(allocator, note2);

    try std.testing.expectEqual(@as(usize, 2), state.progress_notes.items.len);
    try std.testing.expectEqualStrings("First attempt failed", state.progress_notes.items[0]);
    try std.testing.expectEqualStrings("Second attempt succeeded", state.progress_notes.items[1]);
}
