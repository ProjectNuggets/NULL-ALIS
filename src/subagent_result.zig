//! SubagentResult — structured value object returned by a subagent on completion.
//!
//! Phase 2 of the Subagent Pass replaces the text-only `result: ?[]const u8`
//! on `TaskState` with this struct so the parent agent receives metadata
//! (status, token/turn counts, tools used, duration) alongside the final
//! answer text. The struct serializes to/from the durable outbox row's
//! `result_json` column (no table change — same column the Phase-1 minimal
//! `{status,text}` payload used).
//!
//! Ownership: a `SubagentResult` stored in `TaskState.result` is owned by the
//! SubagentManager's allocator (its `text` and every slice it points at). The
//! manager dupes the incoming result's slices on `completeTask` and frees them
//! via `freeSubagentResult` (in subagent.zig). A `Parsed` returned by
//! `fromJsonAlloc` owns its memory via an arena — call `deinit` to free it.

const std = @import("std");

test "SubagentResult round-trips through JSON" {
    const a = std.testing.allocator;
    const original = SubagentResult{
        .status = .completed,
        .text = "the answer",
        .artifacts = &.{.{ .id = "art_1", .kind = "markdown", .title = "Report", .url = "/api/v1/artifacts/art_1", .version = 1 }},
        .tokens = 1234,
        .turns = 3,
        .tools_used = &.{ "shell", "produce_document" },
        .err = null,
        .duration_ms = 4200,
    };
    const json = try original.toJsonAlloc(a);
    defer a.free(json);

    // The Status enum MUST serialize as its tag name, not an integer.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"completed\"") != null);

    var parsed = try SubagentResult.fromJsonAlloc(a, json);
    defer parsed.deinit(a);
    try std.testing.expectEqual(Status.completed, parsed.value.status);
    try std.testing.expectEqualStrings("the answer", parsed.value.text);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.artifacts.len);
    try std.testing.expectEqualStrings("art_1", parsed.value.artifacts[0].id);
    try std.testing.expectEqualStrings("markdown", parsed.value.artifacts[0].kind);
    try std.testing.expectEqual(@as(u64, 1), parsed.value.artifacts[0].version);
    try std.testing.expectEqual(@as(u64, 1234), parsed.value.tokens);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.turns);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tools_used.len);
    try std.testing.expectEqualStrings("shell", parsed.value.tools_used[0]);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.err);
    try std.testing.expectEqual(@as(u64, 4200), parsed.value.duration_ms);
}

test "SubagentResult round-trips a failed status with err and defaults" {
    const a = std.testing.allocator;
    const original = SubagentResult{
        .status = .failed,
        .text = "",
        .err = "boom",
    };
    const json = try original.toJsonAlloc(a);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"failed\"") != null);

    var parsed = try SubagentResult.fromJsonAlloc(a, json);
    defer parsed.deinit(a);
    try std.testing.expectEqual(Status.failed, parsed.value.status);
    try std.testing.expectEqualStrings("", parsed.value.text);
    try std.testing.expect(parsed.value.err != null);
    try std.testing.expectEqualStrings("boom", parsed.value.err.?);
    // Defaulted fields round-trip to their zero values.
    try std.testing.expectEqual(@as(usize, 0), parsed.value.artifacts.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tools_used.len);
    try std.testing.expectEqual(@as(u64, 0), parsed.value.tokens);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.turns);
    try std.testing.expectEqual(@as(u64, 0), parsed.value.duration_ms);
}

/// Terminal disposition of a subagent run. Serializes to its tag name
/// ("completed" / "failed" / "timeout") — verified by the round-trip test.
pub const Status = enum { completed, failed, timeout };

/// A reference to a user-visible artifact a subagent produced. Phase 3
/// populates `SubagentResult.artifacts` with these; in Phase 2 the field
/// stays empty but the type exists so the JSON shape is stable.
pub const ArtifactRef = struct {
    id: []const u8,
    kind: []const u8,
    title: []const u8,
    url: []const u8,
    version: u64 = 1,
};

pub const SubagentResult = struct {
    status: Status,
    text: []const u8,
    artifacts: []const ArtifactRef = &.{},
    tokens: u64 = 0,
    turns: u32 = 0,
    tools_used: []const []const u8 = &.{},
    err: ?[]const u8 = null,
    duration_ms: u64 = 0,

    /// Serialize to a freshly allocated JSON string (caller frees). Mirrors
    /// the `std.json.Stringify.valueAlloc` idiom used throughout this tree
    /// (e.g. completeTask's Phase-1 persist, user_settings.zig). In Zig
    /// 0.15.2 std this renders a plain `enum` as its tag-name string, so
    /// `Status.completed` becomes `"completed"` (asserted in the round-trip
    /// test) — no custom `jsonStringify` needed.
    pub fn toJsonAlloc(self: SubagentResult, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    /// Arena-backed parse result. `value` points into `arena`; call `deinit`
    /// (which frees the arena and destroys it) to release everything.
    pub const Parsed = struct {
        value: SubagentResult,
        arena: *std.heap.ArenaAllocator,

        pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };

    /// Parse a JSON string (as produced by `toJsonAlloc`) into an owned
    /// `Parsed`. Uses `parseFromSliceLeaky` into an arena so the nested
    /// slices (`text`, `artifacts`, `tools_used`, `err`) all live in one
    /// arena freed by `Parsed.deinit`. `ignore_unknown_fields` keeps forward
    /// compatibility if a future phase adds fields to the payload.
    pub fn fromJsonAlloc(allocator: std.mem.Allocator, json: []const u8) !Parsed {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        const value = try std.json.parseFromSliceLeaky(
            SubagentResult,
            arena.allocator(),
            json,
            .{ .ignore_unknown_fields = true },
        );
        return .{ .value = value, .arena = arena };
    }
};
