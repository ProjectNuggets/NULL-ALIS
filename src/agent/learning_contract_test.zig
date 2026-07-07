//! Executable form of docs/learning-contract.md's axes + invariant 1 (the
//! birth-state law) and invariant 3 (provenance is mandatory and immutable).
//! One assertion per contract row. If you change a predicate or the doc,
//! change this.
const std = @import("std");
const learning = @import("learning.zig");

const LearnedOrigin = learning.LearnedOrigin;
const LearnedState = learning.LearnedState;
const birthState = learning.birthState;

// ── Axis 1 (provenance): enum round-trips are total ────────────────────────

test "learning contract: LearnedOrigin toSlice/fromSlice round-trips for every origin" {
    const origins = [_]LearnedOrigin{
        .user_correction,
        .observed_success,
        .observed_failure,
        .mined_aggregate,
        .operator,
    };
    for (origins) |origin| {
        const slice = origin.toSlice();
        const parsed = LearnedOrigin.fromSlice(slice);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(origin, parsed.?);
    }
}

test "learning contract: LearnedOrigin fromSlice rejects unknown provenance" {
    try std.testing.expectEqual(@as(?LearnedOrigin, null), LearnedOrigin.fromSlice("made_up_origin"));
    try std.testing.expectEqual(@as(?LearnedOrigin, null), LearnedOrigin.fromSlice(""));
}

// ── Axis 4 (state / trust ladder): enum round-trips are total ─────────────

test "learning contract: LearnedState toSlice/fromSlice round-trips for every state" {
    const states = [_]LearnedState{ .shadow, .active, .retired };
    for (states) |state| {
        const slice = state.toSlice();
        const parsed = LearnedState.fromSlice(slice);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(state, parsed.?);
    }
}

test "learning contract: LearnedState fromSlice rejects unknown state" {
    try std.testing.expectEqual(@as(?LearnedState, null), LearnedState.fromSlice("quantum_superposition"));
    try std.testing.expectEqual(@as(?LearnedState, null), LearnedState.fromSlice(""));
}

// ── Invariant 1: the birth-state law ───────────────────────────────────────
// "No self-promotion." Only a human-stated correction (origin=user_correction)
// or an operator directive (origin=operator) is active at birth; everything
// the agent derives itself (observed_success, observed_failure, mined_aggregate)
// starts shadow — never injected until an external gate promotes it.

test "learning contract inv. 1: birth-state law — exactly user_correction and operator birth active" {
    const Row = struct { origin: LearnedOrigin, expected: LearnedState };
    const table = [_]Row{
        .{ .origin = .user_correction, .expected = .active },
        .{ .origin = .observed_success, .expected = .shadow },
        .{ .origin = .observed_failure, .expected = .shadow },
        .{ .origin = .mined_aggregate, .expected = .shadow },
        .{ .origin = .operator, .expected = .active },
    };
    for (table) |row| {
        try std.testing.expectEqual(row.expected, birthState(row.origin));
    }
}

test "learning contract inv. 1: no origin births retired (retired is only reachable via external transition)" {
    const origins = [_]LearnedOrigin{
        .user_correction,
        .observed_success,
        .observed_failure,
        .mined_aggregate,
        .operator,
    };
    for (origins) |origin| {
        try std.testing.expect(birthState(origin) != .retired);
    }
}

// ── Bucket 5 (proposal): wish ledger ───────────────────────────────────────
// Learning contract bucket 5 (docs/learning-contract.md line 24): "proposal"
// = capability gap the agent wants; wish-ledger entry; never a behaviour,
// never injected — it's a request to the roadmap. Wishes are brain-visible
// (user may see them), excluded from embedding (semantic bookkeeping), never
// injectable as directives.

test "learning contract bucket 5: wish/ keys are brain-visible" {
    const mem_root = @import("../memory/root.zig");
    try std.testing.expect(mem_root.isBrainVisibleKey("wish/fix-npm-timeout"));
    try std.testing.expect(mem_root.isBrainVisibleKey("wish/multipart-upload"));
}

test "learning contract bucket 5: wish/ keys excluded from embedding (semantic bookkeeping)" {
    const mem_root = @import("../memory/root.zig");
    try std.testing.expect(mem_root.isSemanticBookkeepingKey("wish/x"));
    try std.testing.expect(mem_root.isSemanticBookkeepingKey("wish/some-feature"));
}

test "learning contract bucket 5: wish/ keys pass inlineKeyGuard (agent-authored, user-scoped)" {
    const memory_store_tool = @import("../tools/memory_store.zig").MemoryStoreTool;
    try std.testing.expectEqual(@as(?[]const u8, null), memory_store_tool.inlineKeyGuard("wish/calendar-tz-fix"));
    try std.testing.expectEqual(@as(?[]const u8, null), memory_store_tool.inlineKeyGuard("wish/send-sms"));
}
