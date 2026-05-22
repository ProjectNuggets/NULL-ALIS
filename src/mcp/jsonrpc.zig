//! MCP — JSON-RPC 2.0 message construction and classification.
//!
//! This module is transport-agnostic: it builds request/notification frames
//! and classifies inbound frames. The MCP wire format on stdio is
//! newline-delimited JSON; on HTTP a frame is a whole response body (or one
//! SSE `data:` payload). Either way each frame is a complete JSON-RPC object,
//! and this module is the single place that knows the protocol shape.
//!
//! Why a separate module: the pre-Sprint-2 client built JSON-RPC strings
//! inline with `std.fmt.allocPrint` and treated *every* inbound line as the
//! response to the last request. That is the root cause of the multi-turn
//! stability bug — MCP servers legitimately interleave `notifications/*`
//! frames (progress, log messages, `tools/list_changed`) with responses.
//! Classifying frames here lets the transport skip notifications and keep
//! reading until the response whose `id` matches the request actually
//! arrives.

const std = @import("std");
const json_util = @import("../json_util.zig");
const Allocator = std.mem.Allocator;

/// A classified inbound JSON-RPC frame.
pub const FrameKind = enum {
    /// A response carrying `result` or `error`, with an `id`.
    response,
    /// A server-initiated notification (`method` set, no `id`).
    notification,
    /// A server-initiated request (`method` + `id`) — e.g. `sampling/*` or
    /// `roots/list`. We do not implement these yet; the transport replies
    /// with a "method not found" error so the server is not left hanging.
    server_request,
    /// Not a recognizable JSON-RPC object.
    invalid,
};

pub const Classified = struct {
    kind: FrameKind,
    /// Response/server_request id. Only meaningful for those kinds.
    id: ?i64 = null,
    /// Notification/server_request method. Only meaningful for those kinds.
    method: ?[]const u8 = null,
};

/// Classify a raw JSON frame WITHOUT taking ownership — `method` (when set)
/// points into a temporary parse tree and is valid only until `parsed`
/// is freed by the caller. The transport uses this purely for routing
/// decisions, so a borrowed slice is sufficient.
pub fn classify(allocator: Allocator, frame: []const u8) Classified {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, frame, .{}) catch
        return .{ .kind = .invalid };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .kind = .invalid };
    const obj = parsed.value.object;

    const has_method = obj.get("method") != null;
    const id_val = obj.get("id");
    const has_id = id_val != null and id_val.? != .null;

    if (has_method and has_id) {
        return .{ .kind = .server_request, .id = extractId(id_val.?) };
    }
    if (has_method) {
        return .{ .kind = .notification };
    }
    if (has_id) {
        // result or error — either way it's a response to one of our requests.
        return .{ .kind = .response, .id = extractId(id_val.?) };
    }
    return .{ .kind = .invalid };
}

fn extractId(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// Build a JSON-RPC 2.0 request frame. Caller owns the returned slice.
/// `params` must be a complete JSON value (object/array) or null.
/// A trailing newline is appended — harmless for HTTP, required for stdio.
pub fn buildRequest(
    allocator: Allocator,
    id: i64,
    method: []const u8,
    params: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    var id_buf: [24]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable;
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, ",\"method\":");
    try json_util.appendJsonString(&buf, allocator, method);
    if (params) |p| {
        try buf.appendSlice(allocator, ",\"params\":");
        try buf.appendSlice(allocator, p);
    }
    try buf.appendSlice(allocator, "}\n");
    return buf.toOwnedSlice(allocator);
}

/// Build a JSON-RPC 2.0 notification frame (no `id`, no response expected).
pub fn buildNotification(
    allocator: Allocator,
    method: []const u8,
    params: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":");
    try json_util.appendJsonString(&buf, allocator, method);
    if (params) |p| {
        try buf.appendSlice(allocator, ",\"params\":");
        try buf.appendSlice(allocator, p);
    }
    try buf.appendSlice(allocator, "}\n");
    return buf.toOwnedSlice(allocator);
}

/// Build a JSON-RPC error response for an inbound server request we cannot
/// service (-32601 = Method not found). Keeps the server from hanging on a
/// `sampling/*` / `roots/list` request we do not implement.
pub fn buildMethodNotFound(allocator: Allocator, id: i64) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}\n",
        .{id},
    );
}

// ── Tests ───────────────────────────────────────────────────────

test "classify response with integer id" {
    const c = classify(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":3,"result":{"ok":true}}
    );
    try std.testing.expectEqual(FrameKind.response, c.kind);
    try std.testing.expectEqual(@as(?i64, 3), c.id);
}

test "classify error response is still a response" {
    const c = classify(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":7,"error":{"code":-1,"message":"x"}}
    );
    try std.testing.expectEqual(FrameKind.response, c.kind);
    try std.testing.expectEqual(@as(?i64, 7), c.id);
}

test "classify notification has no id" {
    const c = classify(std.testing.allocator,
        \\{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}
    );
    try std.testing.expectEqual(FrameKind.notification, c.kind);
}

test "classify server request has method and id" {
    const c = classify(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":11,"method":"roots/list"}
    );
    try std.testing.expectEqual(FrameKind.server_request, c.kind);
    try std.testing.expectEqual(@as(?i64, 11), c.id);
}

test "classify invalid" {
    try std.testing.expectEqual(FrameKind.invalid, classify(std.testing.allocator, "not json").kind);
    try std.testing.expectEqual(FrameKind.invalid, classify(std.testing.allocator, "[1,2,3]").kind);
}

test "buildRequest with params" {
    const msg = try buildRequest(std.testing.allocator, 42, "tools/call", "{\"name\":\"x\"}");
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.endsWith(u8, msg, "}\n"));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, msg[0 .. msg.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("id").?.integer);
    try std.testing.expectEqualStrings("tools/call", parsed.value.object.get("method").?.string);
}

test "buildRequest without params omits the key" {
    const msg = try buildRequest(std.testing.allocator, 1, "tools/list", null);
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "params") == null);
}

test "buildNotification has no id" {
    const msg = try buildNotification(std.testing.allocator, "notifications/initialized", null);
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"id\"") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, msg[0 .. msg.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("notifications/initialized", parsed.value.object.get("method").?.string);
}

test "buildMethodNotFound is a valid error response" {
    const msg = try buildMethodNotFound(std.testing.allocator, 9);
    defer std.testing.allocator.free(msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, msg[0 .. msg.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 9), parsed.value.object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, -32601), parsed.value.object.get("error").?.object.get("code").?.integer);
}

test "method-name escaping is JSON-safe" {
    // A method containing a quote would break naive string concat — buildRequest
    // routes through json_util.appendJsonString so it stays valid JSON.
    const msg = try buildRequest(std.testing.allocator, 1, "weird\"method", null);
    defer std.testing.allocator.free(msg);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, msg[0 .. msg.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("weird\"method", parsed.value.object.get("method").?.string);
}
