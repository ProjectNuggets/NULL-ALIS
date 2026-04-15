//! OpenAI-compatible stable prefix ordering for automatic prompt caching.
//!
//! OpenAI automatically caches request prefixes >= 1024 tokens when the
//! prefix is identical across requests. This means tool definitions must
//! be serialized in a deterministic order — if tool order changes between
//! turns, the cache is invalidated and the user pays full input cost.
//!
//! This module provides sorted tool serialization that ensures identical
//! prefixes across turns regardless of tool registration order.
//!
//! Works with: OpenAI, OpenRouter, Compatible (any OpenAI-format provider).

const std = @import("std");
const root = @import("root.zig");
const json_util = @import("../json_util.zig");

/// ToolSpec from the provider interface.
const ToolSpec = root.ToolSpec;

/// Serialize tool definitions sorted by name for stable prefix caching.
///
/// Same format as convertToolsOpenAI but tools are emitted in lexicographic
/// order by name. This ensures the tools section of the request body is
/// byte-identical across turns, maximizing OpenAI's automatic prefix cache hits.
///
/// Cost impact: OpenAI gives 50% discount on cached input tokens. For a
/// typical agent with ~20 tools and a long system prompt, this saves
/// meaningful cost on multi-turn conversations.
pub fn convertToolsSorted(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    tools: []const ToolSpec,
) !void {
    if (tools.len == 0) {
        try buf.appendSlice(allocator, "[]");
        return;
    }

    // Build index sorted by tool name
    const indices = try allocator.alloc(usize, tools.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx, i| {
        idx.* = i;
    }

    // Sort indices by tool name (lexicographic)
    const Context = struct {
        tools_ptr: []const ToolSpec,
    };
    const ctx = Context{ .tools_ptr = tools };
    std.mem.sortUnstable(usize, indices, ctx, struct {
        fn lessThan(c: Context, a: usize, b: usize) bool {
            return std.mem.order(u8, c.tools_ptr[a].name, c.tools_ptr[b].name) == .lt;
        }
    }.lessThan);

    // Serialize in sorted order
    try buf.append(allocator, '[');
    for (indices, 0..) |tool_idx, i| {
        if (i > 0) try buf.append(allocator, ',');
        const tool = tools[tool_idx];
        try buf.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":");
        try json_util.appendJsonString(buf, allocator, tool.name);
        try buf.appendSlice(allocator, ",\"description\":");
        try json_util.appendJsonString(buf, allocator, tool.description);
        try buf.appendSlice(allocator, ",\"parameters\":");
        try buf.appendSlice(allocator, tool.parameters_json);
        try buf.appendSlice(allocator, "}}");
    }
    try buf.append(allocator, ']');
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "convertToolsSorted produces deterministic output regardless of input order" {
    const allocator = std.testing.allocator;

    const tool_a = ToolSpec{ .name = "alpha", .description = "First tool", .parameters_json = "{}" };
    const tool_b = ToolSpec{ .name = "beta", .description = "Second tool", .parameters_json = "{}" };
    const tool_c = ToolSpec{ .name = "gamma", .description = "Third tool", .parameters_json = "{}" };

    // Order 1: a, b, c
    var buf1: std.ArrayListUnmanaged(u8) = .empty;
    defer buf1.deinit(allocator);
    try convertToolsSorted(&buf1, allocator, &.{ tool_a, tool_b, tool_c });

    // Order 2: c, a, b (shuffled)
    var buf2: std.ArrayListUnmanaged(u8) = .empty;
    defer buf2.deinit(allocator);
    try convertToolsSorted(&buf2, allocator, &.{ tool_c, tool_a, tool_b });

    // Both must produce identical output
    try std.testing.expectEqualStrings(buf1.items, buf2.items);

    // Verify sorted order: alpha before beta before gamma
    const alpha_pos = std.mem.indexOf(u8, buf1.items, "\"alpha\"").?;
    const beta_pos = std.mem.indexOf(u8, buf1.items, "\"beta\"").?;
    const gamma_pos = std.mem.indexOf(u8, buf1.items, "\"gamma\"").?;
    try std.testing.expect(alpha_pos < beta_pos);
    try std.testing.expect(beta_pos < gamma_pos);
}

test "convertToolsSorted empty tools" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try convertToolsSorted(&buf, allocator, &.{});
    try std.testing.expectEqualStrings("[]", buf.items);
}

test "convertToolsSorted single tool" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const tool = ToolSpec{ .name = "shell", .description = "Run commands", .parameters_json = "{\"type\":\"object\"}" };
    try convertToolsSorted(&buf, allocator, &.{tool});

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"shell\"") != null);
    try std.testing.expect(buf.items[0] == '[');
    try std.testing.expect(buf.items[buf.items.len - 1] == ']');
}
