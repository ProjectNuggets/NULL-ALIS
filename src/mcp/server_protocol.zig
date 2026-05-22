//! MCP server — JSON-RPC 2.0 protocol layer.
//!
//! This is the *inverse* of `src/mcp.zig` (the MCP *client*). Where the
//! client builds requests and parses responses, this module parses
//! incoming requests and builds responses/errors.
//!
//! Wire shape (newline-delimited JSON, one message per line):
//!   request:      {"jsonrpc":"2.0","id":<id>,"method":"...","params":{...}}
//!   notification: {"jsonrpc":"2.0","method":"...","params":{...}}   (no id)
//!   response:     {"jsonrpc":"2.0","id":<id>,"result":{...}}
//!   error:        {"jsonrpc":"2.0","id":<id>,"error":{"code":N,"message":"..."}}
//!
//! The protocol layer is transport-agnostic and side-effect-free: it does
//! no I/O. `src/mcp_server.zig` owns the stdio loop and tool dispatch.

const std = @import("std");
const json_util = @import("../json_util.zig");
const Allocator = std.mem.Allocator;

/// MCP protocol version this server advertises. Matches the version the
/// client in `src/mcp.zig` requests, so a nullalis-to-nullalis pairing
/// negotiates cleanly.
pub const protocol_version = "2024-11-05";

// ── JSON-RPC error codes ────────────────────────────────────────
// Standard codes from the JSON-RPC 2.0 spec plus MCP conventions.

pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    /// MCP/application-defined: caller failed the auth boundary.
    unauthorized = -32001,

    pub fn value(self: ErrorCode) i32 {
        return @intFromEnum(self);
    }
};

// ── Parsed inbound message ──────────────────────────────────────

pub const MessageKind = enum { request, notification };

/// A parsed JSON-RPC message. `params` points into the backing
/// `std.json.Parsed` document held by the caller — do not use it after
/// the document is freed. `id_*` carries the request id verbatim so the
/// response can echo it (JSON-RPC ids may be string or integer).
pub const ParsedMessage = struct {
    kind: MessageKind,
    method: []const u8,
    /// Request id. Exactly one of these is set for `.request`; both null
    /// for `.notification`. JSON-RPC permits string or number ids.
    id_int: ?i64 = null,
    id_str: ?[]const u8 = null,
    /// The `params` value, or null when the message carried none.
    params: ?std.json.Value = null,
};

/// Parse one JSON value into a JSON-RPC message. Returns
/// `error.InvalidRequest` for JSON that is valid but not a conformant
/// JSON-RPC message. The caller owns the backing document and must keep
/// it alive while it uses the returned `ParsedMessage`.
pub fn parseMessage(parsed_value: std.json.Value) !ParsedMessage {
    if (parsed_value != .object) return error.InvalidRequest;
    const obj = parsed_value.object;

    // jsonrpc must be "2.0" — be lenient and accept a missing field too,
    // since some minimal clients omit it, but reject a wrong value.
    if (obj.get("jsonrpc")) |v| {
        if (v != .string or !std.mem.eql(u8, v.string, "2.0")) return error.InvalidRequest;
    }

    const method_val = obj.get("method") orelse return error.InvalidRequest;
    if (method_val != .string) return error.InvalidRequest;

    var msg = ParsedMessage{
        .kind = .notification,
        .method = method_val.string,
        .params = obj.get("params"),
    };

    // Presence of an id makes it a request; absence makes it a notification.
    if (obj.get("id")) |id_val| {
        switch (id_val) {
            .integer => |i| {
                msg.kind = .request;
                msg.id_int = i;
            },
            .string => |s| {
                msg.kind = .request;
                msg.id_str = s;
            },
            // A null id is technically allowed by JSON-RPC for notifications;
            // treat it as a notification (no response expected).
            .null => msg.kind = .notification,
            else => return error.InvalidRequest,
        }
    }

    return msg;
}

// ── Response builders ───────────────────────────────────────────

/// Append the id field (`"id":<value>`) for a response, echoing whatever
/// form the request used. Falls back to `null` when no id is available
/// (used for error responses to unparseable input).
fn appendId(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, id_int: ?i64, id_str: ?[]const u8) !void {
    try buf.appendSlice(allocator, "\"id\":");
    if (id_int) |i| {
        try buf.writer(allocator).print("{d}", .{i});
    } else if (id_str) |s| {
        try json_util.appendJsonString(buf, allocator, s);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

/// Build a successful JSON-RPC response. `result_json` is a pre-serialized
/// JSON value (object/array/scalar) spliced verbatim into the `result` field.
/// Caller owns the returned slice.
pub fn buildResponse(
    allocator: Allocator,
    id_int: ?i64,
    id_str: ?[]const u8,
    result_json: []const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",");
    try appendId(&buf, allocator, id_int, id_str);
    try buf.appendSlice(allocator, ",\"result\":");
    try buf.appendSlice(allocator, result_json);
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

/// Build a JSON-RPC error response. `message` is escaped. Caller owns the
/// returned slice.
pub fn buildError(
    allocator: Allocator,
    id_int: ?i64,
    id_str: ?[]const u8,
    code: ErrorCode,
    message: []const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",");
    try appendId(&buf, allocator, id_int, id_str);
    try buf.writer(allocator).print(",\"error\":{{\"code\":{d},\"message\":", .{code.value()});
    try json_util.appendJsonString(&buf, allocator, message);
    try buf.appendSlice(allocator, "}}");
    return buf.toOwnedSlice(allocator);
}

// ── Tests ───────────────────────────────────────────────────────

const testing = std.testing;

fn parseLine(line: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
}

test "server_protocol: parseMessage request with integer id" {
    const p = try parseLine(
        \\{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}
    );
    defer p.deinit();
    const msg = try parseMessage(p.value);
    try testing.expectEqual(MessageKind.request, msg.kind);
    try testing.expectEqualStrings("tools/list", msg.method);
    try testing.expectEqual(@as(?i64, 7), msg.id_int);
    try testing.expect(msg.id_str == null);
    try testing.expect(msg.params != null);
}

test "server_protocol: parseMessage request with string id" {
    const p = try parseLine(
        \\{"jsonrpc":"2.0","id":"abc","method":"initialize"}
    );
    defer p.deinit();
    const msg = try parseMessage(p.value);
    try testing.expectEqual(MessageKind.request, msg.kind);
    try testing.expectEqualStrings("abc", msg.id_str.?);
    try testing.expect(msg.id_int == null);
}

test "server_protocol: parseMessage notification has no id" {
    const p = try parseLine(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    defer p.deinit();
    const msg = try parseMessage(p.value);
    try testing.expectEqual(MessageKind.notification, msg.kind);
    try testing.expect(msg.id_int == null and msg.id_str == null);
}

test "server_protocol: parseMessage rejects wrong jsonrpc version" {
    const p = try parseLine(
        \\{"jsonrpc":"1.0","id":1,"method":"x"}
    );
    defer p.deinit();
    try testing.expectError(error.InvalidRequest, parseMessage(p.value));
}

test "server_protocol: parseMessage rejects missing method" {
    const p = try parseLine(
        \\{"jsonrpc":"2.0","id":1}
    );
    defer p.deinit();
    try testing.expectError(error.InvalidRequest, parseMessage(p.value));
}

test "server_protocol: parseMessage rejects non-object" {
    const p = try parseLine("[1,2,3]");
    defer p.deinit();
    try testing.expectError(error.InvalidRequest, parseMessage(p.value));
}

test "server_protocol: buildResponse with integer id" {
    const out = try buildResponse(testing.allocator, 5, null, "{\"ok\":true}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":5,"result":{"ok":true}}
    , out);
}

test "server_protocol: buildResponse with string id" {
    const out = try buildResponse(testing.allocator, null, "req-1", "[]");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":"req-1","result":[]}
    , out);
}

test "server_protocol: buildError formats code and escapes message" {
    const out = try buildError(testing.allocator, 9, null, .method_not_found, "no such \"method\"");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":9,"error":{"code":-32601,"message":"no such \"method\""}}
    , out);
}

test "server_protocol: buildError with null id for parse failures" {
    const out = try buildError(testing.allocator, null, null, .parse_error, "bad json");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"bad json"}}
    , out);
}

test "server_protocol: ErrorCode values match JSON-RPC spec" {
    try testing.expectEqual(@as(i32, -32700), ErrorCode.parse_error.value());
    try testing.expectEqual(@as(i32, -32601), ErrorCode.method_not_found.value());
    try testing.expectEqual(@as(i32, -32001), ErrorCode.unauthorized.value());
}
