const std = @import("std");

/// Reflection entry — single iteration's goal-loop reflection.
/// Part of ReflectionTrail, serialized to skill_executions.assumptions_made_json.
pub const ReflectionEntry = struct {
    iteration: u32,
    tool_name: ?[]const u8 = null,
    goal_status: []const u8, // "in_progress", "met", "stuck", "max_iterations"
    learning: []const u8, // One-line summary of what was learned
};

/// Reflection trail — accumulates reflection entries across a turn's iterations.
/// Persisted at turn-end to skill_executions.assumptions_made_json for cross-session learning.
/// Lifetime: turn-scoped (initialized at turnOutcome start, serialized at session-end checkpoint).
pub const ReflectionTrail = struct {
    goal_text: []const u8, // BORROW from caller (user_message) — not freed by deinit
    entries: std.ArrayListUnmanaged(ReflectionEntry) = .empty,

    /// Append a reflection entry from the current iteration.
    pub fn append(
        self: *@This(),
        allocator: std.mem.Allocator,
        iteration: u32,
        tool_name: ?[]const u8,
        goal_status: []const u8,
        learning: []const u8,
    ) !void {
        try self.entries.append(allocator, .{
            .iteration = iteration,
            .tool_name = if (tool_name) |t| try allocator.dupe(u8, t) else null,
            .goal_status = try allocator.dupe(u8, goal_status),
            .learning = try allocator.dupe(u8, learning),
        });
    }

    /// Serialize trail to JSON for storage in skill_executions.assumptions_made_json.
    /// Format: [{"iteration": N, "tool": "...", "status": "...", "learning": "..."}, ...]
    pub fn serialize(self: *const @This(), allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        const w = buf.writer(allocator);
        try w.writeAll("[");

        for (self.entries.items, 0..) |entry, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"iteration\":");
            try w.print("{d}", .{entry.iteration});

            if (entry.tool_name) |tool| {
                try w.writeAll(",\"tool\":");
                try w.print("\"{s}\"", .{tool});
            }

            try w.writeAll(",\"status\":");
            try w.print("\"{s}\"", .{entry.goal_status});

            try w.writeAll(",\"learning\":");
            try w.print("\"{s}\"", .{entry.learning});

            try w.writeAll("}");
        }

        try w.writeAll("]");
        return try buf.toOwnedSlice(allocator);
    }

    /// Deinit trail — frees all allocated entry strings, but NOT goal_text (borrowed).
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            if (entry.tool_name) |tool| {
                allocator.free(tool);
            }
            allocator.free(entry.goal_status);
            allocator.free(entry.learning);
        }
        self.entries.deinit(allocator);
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "ReflectionTrail accumulates entries" {
    const allocator = std.testing.allocator;
    var trail = ReflectionTrail{ .goal_text = "Test goal" };
    defer trail.deinit(allocator);

    try trail.append(allocator, 0, "web_search", "in_progress", "Found 3 results");
    try trail.append(allocator, 1, "memory_recall", "in_progress", "No matches");

    try std.testing.expectEqual(@as(usize, 2), trail.entries.items.len);
    try std.testing.expectEqual(@as(u32, 0), trail.entries.items[0].iteration);
    try std.testing.expectEqual(@as(u32, 1), trail.entries.items[1].iteration);
}

test "ReflectionTrail serialize produces valid JSON" {
    const allocator = std.testing.allocator;
    var trail = ReflectionTrail{ .goal_text = "Debug error" };
    defer trail.deinit(allocator);

    try trail.append(allocator, 0, "shell", "in_progress", "Ran git log");
    try trail.append(allocator, 1, null, "met", "Found the issue");

    const json = try trail.serialize(allocator);
    defer allocator.free(json);

    // Verify it's valid JSON array
    try std.testing.expect(std.mem.startsWith(u8, json, "["));
    try std.testing.expect(std.mem.endsWith(u8, json, "]"));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"iteration\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"learning\"") != null);
}

test "ReflectionTrail handles empty entries" {
    const allocator = std.testing.allocator;
    var trail = ReflectionTrail{ .goal_text = "Empty goal" };
    defer trail.deinit(allocator);

    const json = try trail.serialize(allocator);
    defer allocator.free(json);

    try std.testing.expectEqualStrings("[]", json);
}

test "ReflectionTrail entry without tool_name serializes" {
    const allocator = std.testing.allocator;
    var trail = ReflectionTrail{ .goal_text = "Goal" };
    defer trail.deinit(allocator);

    try trail.append(allocator, 0, null, "met", "Done");

    const json = try trail.serialize(allocator);
    defer allocator.free(json);

    // Should not have "tool" key if tool_name is null
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool\"") == null);
}
