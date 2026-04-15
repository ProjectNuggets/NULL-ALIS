//! Anthropic prompt caching — serialize system prompts as cacheable content blocks.
//!
//! Anthropic's prompt caching reduces input token costs by ~90% on cache hits.
//! The system prompt and tool definitions are stable across turns, making them
//! ideal caching candidates. Cache TTL is 5 minutes (auto-extended on hits).
//!
//! API format change:
//!   Before: "system": "Your prompt text"
//!   After:  "system": [{"type":"text","text":"Your prompt text","cache_control":{"type":"ephemeral"}}]
//!
//! Both formats are accepted by the Anthropic API. The array-of-blocks format
//! enables cache_control annotations.

const std = @import("std");
const root = @import("root.zig");

/// Serialize a system prompt as a cacheable Anthropic content block array.
///
/// Output: [{"type":"text","text":"<escaped_prompt>","cache_control":{"type":"ephemeral"}}]
///
/// When the system prompt is identical across turns (which it usually is —
/// it only changes when workspace files are modified), Anthropic caches the
/// KV pairs for this prefix. Subsequent turns pay ~10% of the input cost
/// for the cached portion.
pub fn serializeSystemCacheable(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
) !void {
    try buf.appendSlice(allocator, "[{\"type\":\"text\",\"text\":");
    try root.appendJsonString(buf, allocator, system_prompt);
    try buf.appendSlice(allocator, ",\"cache_control\":{\"type\":\"ephemeral\"}}]");
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "serializeSystemCacheable produces valid JSON array" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try serializeSystemCacheable(&buf, allocator, "You are a helpful assistant.");
    const result = buf.items;

    // Must be a JSON array
    try std.testing.expect(result[0] == '[');
    try std.testing.expect(result[result.len - 1] == ']');

    // Must contain cache_control
    try std.testing.expect(std.mem.indexOf(u8, result, "\"cache_control\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"ephemeral\"") != null);

    // Must contain the prompt text
    try std.testing.expect(std.mem.indexOf(u8, result, "You are a helpful assistant.") != null);
}

test "serializeSystemCacheable escapes special characters" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try serializeSystemCacheable(&buf, allocator, "Line one\nLine \"two\"");
    const result = buf.items;

    // Newlines and quotes must be escaped in the JSON string
    try std.testing.expect(std.mem.indexOf(u8, result, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\"two\\\"") != null);
}

test "serializeSystemCacheable empty prompt" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try serializeSystemCacheable(&buf, allocator, "");
    const result = buf.items;

    try std.testing.expect(result[0] == '[');
    try std.testing.expect(std.mem.indexOf(u8, result, "\"cache_control\"") != null);
}
