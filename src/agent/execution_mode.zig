//! Execution mode — determines what tools and behaviors are available in a turn.
//!
//! The agent's current execution mode gates tool dispatch (via allowsTool),
//! shapes the reflection prompt, and is surfaced to users via /mode.

const std = @import("std");
const metadata = @import("../tools/metadata.zig");

pub const ExecutionMode = enum {
    plan,
    execute,
    review,
    background,

    pub fn toSlice(self: ExecutionMode) []const u8 {
        return switch (self) {
            .plan => "plan",
            .execute => "execute",
            .review => "review",
            .background => "background",
        };
    }

    pub fn fromString(s: []const u8) ?ExecutionMode {
        if (std.mem.eql(u8, s, "plan")) return .plan;
        if (std.mem.eql(u8, s, "execute")) return .execute;
        if (std.mem.eql(u8, s, "review")) return .review;
        if (std.mem.eql(u8, s, "background")) return .background;
        return null;
    }

    /// Whether a tool is allowed in this execution mode based on its metadata.
    /// Execute mode allows all tools. Plan/review only allow read_only tools.
    /// Background only allows background_safe tools.
    pub fn allowsTool(self: ExecutionMode, meta: metadata.ToolMetadata) bool {
        return switch (self) {
            .execute => true,
            .plan, .review => meta.flags.read_only,
            .background => meta.flags.background_safe,
        };
    }

    pub fn isReadOnly(self: ExecutionMode) bool {
        return switch (self) {
            .plan, .review => true,
            .execute, .background => false,
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "toSlice roundtrip" {
    const modes = [_]ExecutionMode{ .plan, .execute, .review, .background };
    for (modes) |mode| {
        const s = mode.toSlice();
        const roundtripped = ExecutionMode.fromString(s) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(mode, roundtripped);
    }
}

test "fromString returns null for invalid" {
    try std.testing.expect(ExecutionMode.fromString("invalid") == null);
    try std.testing.expect(ExecutionMode.fromString("") == null);
    try std.testing.expect(ExecutionMode.fromString("PLAN") == null);
}

test "execute mode allows all tools" {
    const mutating_meta = metadata.ToolMetadata{ .name = "shell", .flags = .{ .mutating = true } };
    const readonly_meta = metadata.ToolMetadata{ .name = "read", .flags = .{ .read_only = true } };
    try std.testing.expect(ExecutionMode.execute.allowsTool(mutating_meta));
    try std.testing.expect(ExecutionMode.execute.allowsTool(readonly_meta));
}

test "plan mode blocks mutating tools" {
    const meta = metadata.ToolMetadata{ .name = "shell", .flags = .{ .mutating = true } };
    try std.testing.expect(!ExecutionMode.plan.allowsTool(meta));
}

test "plan mode allows read_only tools" {
    const meta = metadata.ToolMetadata{ .name = "file_read", .flags = .{ .read_only = true } };
    try std.testing.expect(ExecutionMode.plan.allowsTool(meta));
}

test "review mode blocks mutating tools" {
    const meta = metadata.ToolMetadata{ .name = "shell", .flags = .{ .mutating = true } };
    try std.testing.expect(!ExecutionMode.review.allowsTool(meta));
}

test "background mode requires background_safe" {
    const safe = metadata.ToolMetadata{ .name = "cron", .flags = .{ .background_safe = true } };
    const unsafe = metadata.ToolMetadata{ .name = "shell", .flags = .{} };
    try std.testing.expect(ExecutionMode.background.allowsTool(safe));
    try std.testing.expect(!ExecutionMode.background.allowsTool(unsafe));
}

test "isReadOnly" {
    try std.testing.expect(ExecutionMode.plan.isReadOnly());
    try std.testing.expect(ExecutionMode.review.isReadOnly());
    try std.testing.expect(!ExecutionMode.execute.isReadOnly());
    try std.testing.expect(!ExecutionMode.background.isReadOnly());
}
