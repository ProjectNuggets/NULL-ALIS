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
    /// Phase 5 (Superpowers mode) — the in-turn coordinator. Plans, fans out
    /// to subagents, reviews their results, and synthesizes a single
    /// deliverable. It does NOT do direct mutating grunt work; that is
    /// delegated. Activated per-turn when the FE sends
    /// reasoning_effort="superpowers" (and no explicit mode override).
    coordinator,

    pub fn toSlice(self: ExecutionMode) []const u8 {
        return switch (self) {
            .plan => "plan",
            .execute => "execute",
            .review => "review",
            .background => "background",
            .coordinator => "coordinator",
        };
    }

    pub fn fromString(s: []const u8) ?ExecutionMode {
        if (std.mem.eql(u8, s, "plan")) return .plan;
        if (std.mem.eql(u8, s, "execute")) return .execute;
        if (std.mem.eql(u8, s, "review")) return .review;
        if (std.mem.eql(u8, s, "background")) return .background;
        if (std.mem.eql(u8, s, "coordinator")) return .coordinator;
        return null;
    }

    /// Whether a tool is allowed in this execution mode based on its metadata.
    /// Execute mode allows all tools. Plan/review only allow read_only tools.
    /// Background only allows background_safe tools. Coordinator allows
    /// read_only OR coordinator_dispatch tools — it plans, dispatches, and
    /// reads, but delegates direct mutating grunt work to subagents.
    pub fn allowsTool(self: ExecutionMode, meta: metadata.ToolMetadata) bool {
        return switch (self) {
            .execute => true,
            .plan, .review => meta.flags.read_only,
            .background => meta.flags.background_safe,
            .coordinator => meta.flags.read_only or meta.flags.coordinator_dispatch,
        };
    }

    pub fn isReadOnly(self: ExecutionMode) bool {
        return switch (self) {
            .plan, .review => true,
            // Coordinator dispatches (spawn_many mutates) → not read-only.
            .execute, .background, .coordinator => false,
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

// ── Phase 5 (Superpowers mode) — .coordinator execution mode ─────────

test "coordinator mode exists and round-trips" {
    const m = ExecutionMode.coordinator;
    try std.testing.expectEqualStrings("coordinator", m.toSlice());
    const back = ExecutionMode.fromString("coordinator") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ExecutionMode.coordinator, back);
}

test "coordinator mode allows read_only tools" {
    const meta = metadata.ToolMetadata{ .name = "file_read", .flags = .{ .read_only = true } };
    try std.testing.expect(ExecutionMode.coordinator.allowsTool(meta));
}

test "coordinator mode allows coordinator_dispatch tools" {
    // spawn_many mutates, but it's a dispatch tool — coordinator must be able
    // to plan + dispatch + read, just not do direct mutating grunt work.
    const dispatch = metadata.ToolMetadata{ .name = "spawn_many", .flags = .{ .mutating = true, .coordinator_dispatch = true } };
    try std.testing.expect(ExecutionMode.coordinator.allowsTool(dispatch));
}

test "coordinator mode blocks pure-mutating non-dispatch tools" {
    // file_write is mutating grunt work with no dispatch flag — coordinator
    // delegates that to subagents rather than doing it directly.
    const grunt = metadata.ToolMetadata{ .name = "file_write", .flags = .{ .mutating = true } };
    try std.testing.expect(!ExecutionMode.coordinator.allowsTool(grunt));
}

test "coordinator mode is not flagged read-only (it dispatches)" {
    try std.testing.expect(!ExecutionMode.coordinator.isReadOnly());
}
