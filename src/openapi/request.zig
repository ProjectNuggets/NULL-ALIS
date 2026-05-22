//! OpenAPI request builder — pure functions that turn an `Operation`
//! plus caller-supplied arguments into a concrete HTTP request shape
//! (method, URL, query string, headers, body).
//!
//! Auth injection is NOT done here — credentials are applied at the tool
//! layer (`tools/openapi.zig`) so they never pass through this pure,
//! testable code path and never end up in any string this module returns
//! to the model. This module only validates + builds the un-authenticated
//! skeleton.

const std = @import("std");
const spec = @import("spec.zig");

/// A built HTTP request, ready for the tool layer to add auth + fire.
/// All slices are owned by the caller-supplied allocator.
pub const BuiltRequest = struct {
    method: []const u8,
    /// Absolute URL: base + substituted path + query string.
    url: []const u8,
    /// Header lines as `Name: Value` (auth headers are added later).
    headers: []const []const u8,
    /// Request body bytes, or null for GET/DELETE-without-body.
    body: ?[]const u8 = null,

    pub fn deinit(self: BuiltRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.url);
        for (self.headers) |h| allocator.free(h);
        allocator.free(self.headers);
        if (self.body) |b| allocator.free(b);
    }
};

pub const BuildError = error{
    MissingRequiredPathParam,
    MissingRequiredQueryParam,
    MissingRequiredBody,
    InvalidBaseUrl,
    UnresolvedPathTemplate,
} || std.mem.Allocator.Error;

/// Inputs to `build`. `path_params`, `query`, and `body` come straight
/// from the tool's JSON args. `body` is the already-serialized JSON body
/// string (the tool serializes the `body` arg object) or null.
pub const BuildInput = struct {
    /// Base URL with no trailing slash, e.g. `https://api.example.com/v1`.
    base_url: []const u8,
    path_params: ?std.json.ObjectMap = null,
    query: ?std.json.ObjectMap = null,
    /// Pre-serialized request body (the tool serializes its `body` arg).
    body_json: ?[]const u8 = null,
};

/// Build a concrete HTTP request for `op`. Validates that every required
/// path parameter is supplied and that a required body is present.
/// Required query parameters that are absent are reported too.
pub fn build(
    allocator: std.mem.Allocator,
    op: spec.Operation,
    input: BuildInput,
) BuildError!BuiltRequest {
    // ── method ──────────────────────────────────────────────────────
    const method = try allocator.dupe(u8, op.method);
    errdefer allocator.free(method);

    // ── path: substitute {placeholders} ────────────────────────────
    const substituted_path = try substitutePath(allocator, op, input.path_params);
    defer allocator.free(substituted_path);

    // ── query string ───────────────────────────────────────────────
    const query_string = try buildQueryString(allocator, op, input.query);
    defer allocator.free(query_string);

    // ── full URL ────────────────────────────────────────────────────
    const trimmed_base = std.mem.trimRight(u8, input.base_url, "/");
    if (trimmed_base.len == 0) return error.InvalidBaseUrl;

    var url_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer url_buf.deinit(allocator);
    try url_buf.appendSlice(allocator, trimmed_base);
    if (substituted_path.len > 0 and substituted_path[0] != '/') {
        try url_buf.append(allocator, '/');
    }
    try url_buf.appendSlice(allocator, substituted_path);
    if (query_string.len > 0) {
        try url_buf.append(allocator, '?');
        try url_buf.appendSlice(allocator, query_string);
    }
    const url = try url_buf.toOwnedSlice(allocator);
    errdefer allocator.free(url);

    // ── body ────────────────────────────────────────────────────────
    var body: ?[]const u8 = null;
    if (op.request_body) |rb| {
        if (input.body_json) |bj| {
            body = try allocator.dupe(u8, bj);
        } else if (rb.required) {
            return error.MissingRequiredBody;
        }
    }
    errdefer if (body) |b| allocator.free(b);

    // ── headers ─────────────────────────────────────────────────────
    var headers: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (headers.items) |h| allocator.free(h);
        headers.deinit(allocator);
    }
    if (body != null) {
        const media = if (op.request_body) |rb| rb.media_type else "application/json";
        try headers.append(allocator, try std.fmt.allocPrint(
            allocator,
            "Content-Type: {s}",
            .{media},
        ));
    }
    try headers.append(allocator, try allocator.dupe(u8, "Accept: application/json"));

    // Header parameters from the spec, when supplied via `query` args.
    // (Spec header params and query args share the same `query` map for
    // ergonomics; we route by the parameter's declared location.)
    if (input.query) |q| {
        for (op.parameters) |p| {
            if (p.location != .header) continue;
            if (q.get(p.name)) |v| {
                const val_str = jsonValueToString(allocator, v) catch continue;
                defer allocator.free(val_str);
                try headers.append(allocator, try std.fmt.allocPrint(
                    allocator,
                    "{s}: {s}",
                    .{ p.name, val_str },
                ));
            }
        }
    }

    return BuiltRequest{
        .method = method,
        .url = url,
        .headers = try headers.toOwnedSlice(allocator),
        .body = body,
    };
}

/// Substitute `{name}` placeholders in `op.path` from `path_params`.
/// Returns `error.MissingRequiredPathParam` when a placeholder has no
/// supplied value.
fn substitutePath(
    allocator: std.mem.Allocator,
    op: spec.Operation,
    path_params: ?std.json.ObjectMap,
) BuildError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    const path = op.path;
    while (i < path.len) {
        if (path[i] == '{') {
            const close = std.mem.indexOfScalarPos(u8, path, i, '}') orelse
                return error.UnresolvedPathTemplate;
            const name = path[i + 1 .. close];
            const value = blk: {
                const pp = path_params orelse return error.MissingRequiredPathParam;
                const v = pp.get(name) orelse return error.MissingRequiredPathParam;
                break :blk v;
            };
            const val_str = try jsonValueToString(allocator, value);
            defer allocator.free(val_str);
            try percentEncodePathSegment(allocator, &out, val_str);
            i = close + 1;
        } else {
            try out.append(allocator, path[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Build a `&`-joined, percent-encoded query string from query args.
/// Reports `error.MissingRequiredQueryParam` when a spec-required query
/// parameter is absent from `query`.
fn buildQueryString(
    allocator: std.mem.Allocator,
    op: spec.Operation,
    query: ?std.json.ObjectMap,
) BuildError![]u8 {
    // First, enforce required query params.
    for (op.parameters) |p| {
        if (p.location != .query or !p.required) continue;
        const has = blk: {
            const q = query orelse break :blk false;
            break :blk q.get(p.name) != null;
        };
        if (!has) return error.MissingRequiredQueryParam;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const q = query orelse return try out.toOwnedSlice(allocator);
    var it = q.iterator();
    var first = true;
    while (it.next()) |entry| {
        // Skip keys that the spec declares as header parameters — those
        // become headers, not query string entries.
        if (isHeaderParam(op, entry.key_ptr.*)) continue;
        const val_str = jsonValueToString(allocator, entry.value_ptr.*) catch continue;
        defer allocator.free(val_str);

        if (!first) try out.append(allocator, '&');
        first = false;
        try percentEncodeComponent(allocator, &out, entry.key_ptr.*);
        try out.append(allocator, '=');
        try percentEncodeComponent(allocator, &out, val_str);
    }
    return try out.toOwnedSlice(allocator);
}

fn isHeaderParam(op: spec.Operation, name: []const u8) bool {
    for (op.parameters) |p| {
        if (p.location == .header and std.mem.eql(u8, p.name, name)) return true;
    }
    return false;
}

/// Render a JSON value as a flat string for use in a URL or header.
/// Objects/arrays are rejected (returns an empty-string-safe error path
/// at call sites that `catch continue`).
fn jsonValueToString(allocator: std.mem.Allocator, value: std.json.Value) BuildError![]u8 {
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .number_string => |s| try allocator.dupe(u8, s),
        else => try allocator.dupe(u8, ""),
    };
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

/// Percent-encode a query-string component (key or value).
fn percentEncodeComponent(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    text: []const u8,
) BuildError!void {
    const hex = "0123456789ABCDEF";
    for (text) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0f]);
        }
    }
}

/// Percent-encode a path segment. Same set as a component — a slash in a
/// path param value is encoded so it cannot break out of the segment.
fn percentEncodePathSegment(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    text: []const u8,
) BuildError!void {
    try percentEncodeComponent(allocator, out, text);
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn parseObj(arena: std.mem.Allocator, json: []const u8) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    return parsed.value.object;
}

test "build GET with path param" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const op = spec.Operation{
        .operation_id = "getPet",
        .method = "GET",
        .path = "/pets/{petId}",
        .parameters = &.{
            .{ .name = "petId", .location = .path, .required = true },
        },
    };
    const path_params = try parseObj(a, "{\"petId\": \"abc-123\"}");
    const req = try build(a, op, .{
        .base_url = "https://api.example.com/v1",
        .path_params = path_params,
    });
    try testing.expectEqualStrings("GET", req.method);
    try testing.expectEqualStrings("https://api.example.com/v1/pets/abc-123", req.url);
    try testing.expect(req.body == null);
}

test "build rejects missing required path param" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const op = spec.Operation{
        .operation_id = "getPet",
        .method = "GET",
        .path = "/pets/{petId}",
        .parameters = &.{
            .{ .name = "petId", .location = .path, .required = true },
        },
    };
    try testing.expectError(error.MissingRequiredPathParam, build(arena.allocator(), op, .{
        .base_url = "https://api.example.com",
    }));
}

test "build query string with encoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const op = spec.Operation{
        .operation_id = "search",
        .method = "GET",
        .path = "/search",
        .parameters = &.{
            .{ .name = "q", .location = .query, .required = false },
        },
    };
    const query = try parseObj(a, "{\"q\": \"hello world\"}");
    const req = try build(a, op, .{
        .base_url = "https://api.example.com",
        .query = query,
    });
    try testing.expectEqualStrings("https://api.example.com/search?q=hello%20world", req.url);
}

test "build rejects missing required query param" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const op = spec.Operation{
        .operation_id = "search",
        .method = "GET",
        .path = "/search",
        .parameters = &.{
            .{ .name = "q", .location = .query, .required = true },
        },
    };
    try testing.expectError(error.MissingRequiredQueryParam, build(arena.allocator(), op, .{
        .base_url = "https://api.example.com",
    }));
}

test "build POST with body and Content-Type header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const op = spec.Operation{
        .operation_id = "createPet",
        .method = "POST",
        .path = "/pets",
        .request_body = .{ .required = true, .media_type = "application/json" },
    };
    const req = try build(a, op, .{
        .base_url = "https://api.example.com",
        .body_json = "{\"name\":\"Rex\"}",
    });
    try testing.expectEqualStrings("POST", req.method);
    try testing.expectEqualStrings("{\"name\":\"Rex\"}", req.body.?);
    var saw_ct = false;
    for (req.headers) |h| {
        if (std.mem.eql(u8, h, "Content-Type: application/json")) saw_ct = true;
    }
    try testing.expect(saw_ct);
}

test "build rejects missing required body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const op = spec.Operation{
        .operation_id = "createPet",
        .method = "POST",
        .path = "/pets",
        .request_body = .{ .required = true },
    };
    try testing.expectError(error.MissingRequiredBody, build(arena.allocator(), op, .{
        .base_url = "https://api.example.com",
    }));
}

test "build trims trailing slash from base URL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const op = spec.Operation{
        .operation_id = "list",
        .method = "GET",
        .path = "/items",
    };
    const req = try build(arena.allocator(), op, .{
        .base_url = "https://api.example.com/v2/",
    });
    try testing.expectEqualStrings("https://api.example.com/v2/items", req.url);
}

test "build rejects empty base URL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const op = spec.Operation{ .operation_id = "x", .method = "GET", .path = "/x" };
    try testing.expectError(error.InvalidBaseUrl, build(arena.allocator(), op, .{
        .base_url = "",
    }));
}

test "integer path param renders as digits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const op = spec.Operation{
        .operation_id = "getUser",
        .method = "GET",
        .path = "/users/{id}",
        .parameters = &.{.{ .name = "id", .location = .path, .required = true }},
    };
    const pp = try parseObj(a, "{\"id\": 42}");
    const req = try build(a, op, .{
        .base_url = "https://api.example.com",
        .path_params = pp,
    });
    try testing.expectEqualStrings("https://api.example.com/users/42", req.url);
}

test "header parameter routed to header not query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const op = spec.Operation{
        .operation_id = "getThing",
        .method = "GET",
        .path = "/thing",
        .parameters = &.{
            .{ .name = "X-Request-Id", .location = .header, .required = false },
        },
    };
    const query = try parseObj(a, "{\"X-Request-Id\": \"req-7\"}");
    const req = try build(a, op, .{
        .base_url = "https://api.example.com",
        .query = query,
    });
    // No query string — the key was a header param.
    try testing.expectEqualStrings("https://api.example.com/thing", req.url);
    var saw_header = false;
    for (req.headers) |h| {
        if (std.mem.eql(u8, h, "X-Request-Id: req-7")) saw_header = true;
    }
    try testing.expect(saw_header);
}

test "path param slash is percent-encoded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const op = spec.Operation{
        .operation_id = "getFile",
        .method = "GET",
        .path = "/files/{name}",
        .parameters = &.{.{ .name = "name", .location = .path, .required = true }},
    };
    const pp = try parseObj(a, "{\"name\": \"a/b\"}");
    const req = try build(a, op, .{
        .base_url = "https://api.example.com",
        .path_params = pp,
    });
    try testing.expectEqualStrings("https://api.example.com/files/a%2Fb", req.url);
}
