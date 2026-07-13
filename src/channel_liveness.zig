//! Bounded, read-only provider probes for user-managed channel credentials.

const std = @import("std");
const http_util = @import("http_util.zig");

const probe_timeout_ms: u32 = 5_000;
const max_provider_response_bytes: usize = 64 * 1024;

pub const Channel = enum { telegram, slack };

pub const Request = struct {
    method: []const u8,
    url: []const u8,
    headers: []const []const u8 = &.{},
    timeout_ms: u32,
    max_response_bytes: usize,
};

pub const Response = struct {
    status_code: u16,
    body: []u8,
};

pub const Transport = struct {
    context: *anyopaque,
    request_fn: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror!Response,
};

pub const ProbeResult = struct {
    ok: bool,
    detail: []const u8,
};

var production_transport_marker: u8 = 0;

fn productionRequest(_: *anyopaque, allocator: std.mem.Allocator, request_value: Request) !Response {
    const response = try http_util.request_with_mode(allocator, .{ .mode = .native_preferred }, .{
        .method = request_value.method,
        .url = request_value.url,
        .headers = request_value.headers,
        .timeout_ms = request_value.timeout_ms,
        .max_response_bytes = request_value.max_response_bytes,
        .subsystem = .channels,
    });
    return .{ .status_code = response.status_code, .body = response.body };
}

pub fn probe(allocator: std.mem.Allocator, channel: Channel, token: []const u8) !ProbeResult {
    return probeWithTransport(allocator, channel, token, .{
        .context = &production_transport_marker,
        .request_fn = productionRequest,
    });
}

pub fn probeWithTransport(
    allocator: std.mem.Allocator,
    channel: Channel,
    token: []const u8,
    transport: Transport,
) !ProbeResult {
    var owned_url: ?[]u8 = null;
    defer if (owned_url) |value| allocator.free(value);
    var owned_auth_header: ?[]u8 = null;
    defer if (owned_auth_header) |value| allocator.free(value);
    var header_buf: [1][]const u8 = undefined;

    const url: []const u8 = switch (channel) {
        .telegram => blk: {
            owned_url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/getMe", .{token});
            break :blk owned_url.?;
        },
        .slack => "https://slack.com/api/auth.test",
    };
    const headers: []const []const u8 = switch (channel) {
        .telegram => &.{},
        .slack => blk: {
            owned_auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
            header_buf[0] = owned_auth_header.?;
            break :blk header_buf[0..];
        },
    };

    const response = transport.request_fn(transport.context, allocator, .{
        .method = "GET",
        .url = url,
        .headers = headers,
        .timeout_ms = probe_timeout_ms,
        .max_response_bytes = max_provider_response_bytes,
    }) catch |err| return .{
        .ok = false,
        .detail = if (err == error.Timeout)
            "provider_timeout"
        else if (err == error.ResponseTooLarge)
            "invalid_provider_response"
        else
            "provider_unreachable",
    };
    defer allocator.free(response.body);

    if (response.body.len > max_provider_response_bytes) {
        return .{ .ok = false, .detail = "invalid_provider_response" };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
        if (response.status_code == 401 or response.status_code == 403) {
            return .{ .ok = false, .detail = "provider_auth_rejected" };
        }
        if (response.status_code != 200) return .{ .ok = false, .detail = "provider_unreachable" };
        return .{ .ok = false, .detail = "invalid_provider_response" };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .ok = false, .detail = "invalid_provider_response" };
    const ok_value = parsed.value.object.get("ok") orelse
        return .{ .ok = false, .detail = "invalid_provider_response" };
    if (response.status_code == 401 or response.status_code == 403) {
        return .{ .ok = false, .detail = "provider_auth_rejected" };
    }
    if (channel == .telegram and response.status_code == 404) {
        return .{ .ok = false, .detail = "provider_auth_rejected" };
    }
    if (response.status_code != 200) return .{ .ok = false, .detail = "provider_unreachable" };
    if (ok_value != .bool) {
        return .{ .ok = false, .detail = "invalid_provider_response" };
    }
    if (!ok_value.bool) {
        const auth_rejected = switch (channel) {
            .telegram => blk: {
                const error_code = parsed.value.object.get("error_code");
                break :blk error_code != null and error_code.? == .integer and
                    (error_code.?.integer == 401 or
                        error_code.?.integer == 403 or
                        error_code.?.integer == 404);
            },
            .slack => blk: {
                const error_value = parsed.value.object.get("error");
                if (error_value == null or error_value.? != .string) break :blk false;
                const code = error_value.?.string;
                break :blk std.mem.eql(u8, code, "invalid_auth") or
                    std.mem.eql(u8, code, "not_authed") or
                    std.mem.eql(u8, code, "token_revoked") or
                    std.mem.eql(u8, code, "account_inactive");
            },
        };
        return .{
            .ok = false,
            .detail = if (auth_rejected) "provider_auth_rejected" else "provider_unreachable",
        };
    }
    return switch (channel) {
        .telegram => blk: {
            const result_value = parsed.value.object.get("result") orelse
                break :blk .{ .ok = false, .detail = "invalid_provider_response" };
            const id_value = if (result_value == .object) result_value.object.get("id") else null;
            break :blk if (id_value != null and id_value.? == .integer)
                .{ .ok = true, .detail = "provider_reachable" }
            else
                .{ .ok = false, .detail = "invalid_provider_response" };
        },
        .slack => blk: {
            const user_id = parsed.value.object.get("user_id") orelse
                break :blk .{ .ok = false, .detail = "invalid_provider_response" };
            break :blk if (user_id == .string and user_id.string.len > 0)
                .{ .ok = true, .detail = "provider_reachable" }
            else
                .{ .ok = false, .detail = "invalid_provider_response" };
        },
    };
}

const RecordingTransport = struct {
    calls: usize = 0,

    fn request(context: *anyopaque, allocator: std.mem.Allocator, request_value: Request) !Response {
        const self: *RecordingTransport = @ptrCast(@alignCast(context));
        self.calls += 1;
        try std.testing.expectEqualStrings("GET", request_value.method);
        try std.testing.expectEqualStrings("https://api.telegram.org/bot123456:ABC/getMe", request_value.url);
        try std.testing.expectEqual(@as(u32, 5_000), request_value.timeout_ms);
        try std.testing.expectEqual(@as(usize, 64 * 1024), request_value.max_response_bytes);
        return .{
            .status_code = 200,
            .body = try allocator.dupe(u8, "{\"ok\":true,\"result\":{\"id\":42,\"username\":\"zaki_test_bot\"}}"),
        };
    }
};

test "telegram getMe reports a reachable provider with one bounded call" {
    var recording = RecordingTransport{};
    const result = try probeWithTransport(
        std.testing.allocator,
        .telegram,
        "123456:ABC",
        .{ .context = &recording, .request_fn = RecordingTransport.request },
    );

    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("provider_reachable", result.detail);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
}

const SlackRecordingTransport = struct {
    calls: usize = 0,

    fn request(context: *anyopaque, allocator: std.mem.Allocator, request_value: Request) !Response {
        const self: *SlackRecordingTransport = @ptrCast(@alignCast(context));
        self.calls += 1;
        try std.testing.expectEqualStrings("GET", request_value.method);
        try std.testing.expectEqualStrings("https://slack.com/api/auth.test", request_value.url);
        try std.testing.expectEqual(@as(usize, 1), request_value.headers.len);
        try std.testing.expectEqualStrings("Authorization: Bearer xoxb-test-token", request_value.headers[0]);
        try std.testing.expectEqual(@as(u32, 5_000), request_value.timeout_ms);
        return .{
            .status_code = 200,
            .body = try allocator.dupe(u8, "{\"ok\":true,\"user_id\":\"U123\",\"team_id\":\"T123\"}"),
        };
    }
};

test "slack auth.test reports a reachable provider with bearer auth" {
    var recording = SlackRecordingTransport{};
    const result = try probeWithTransport(
        std.testing.allocator,
        .slack,
        "xoxb-test-token",
        .{ .context = &recording, .request_fn = SlackRecordingTransport.request },
    );

    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("provider_reachable", result.detail);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);
}

const StaticTransport = struct {
    status_code: u16,
    body: []const u8,
    calls: usize = 0,

    fn request(context: *anyopaque, allocator: std.mem.Allocator, _: Request) !Response {
        const self: *StaticTransport = @ptrCast(@alignCast(context));
        self.calls += 1;
        return .{ .status_code = self.status_code, .body = try allocator.dupe(u8, self.body) };
    }
};

test "slack auth rejection is a completed negative liveness result" {
    var transport_state = StaticTransport{
        .status_code = 200,
        .body = "{\"ok\":false,\"error\":\"invalid_auth\"}",
    };
    const result = try probeWithTransport(
        std.testing.allocator,
        .slack,
        "xoxb-rejected",
        .{ .context = &transport_state, .request_fn = StaticTransport.request },
    );

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("provider_auth_rejected", result.detail);
    try std.testing.expectEqual(@as(usize, 1), transport_state.calls);
}

test "provider throttling is not misreported as rejected credentials" {
    var slack_transport = StaticTransport{
        .status_code = 429,
        .body = "{\"ok\":false,\"error\":\"ratelimited\"}",
    };
    const slack_result = try probeWithTransport(
        std.testing.allocator,
        .slack,
        "xoxb-rate-limited",
        .{ .context = &slack_transport, .request_fn = StaticTransport.request },
    );
    try std.testing.expect(!slack_result.ok);
    try std.testing.expectEqualStrings("provider_unreachable", slack_result.detail);

    var telegram_transport = StaticTransport{
        .status_code = 429,
        .body = "{\"ok\":false,\"error_code\":429,\"description\":\"Too Many Requests\"}",
    };
    const telegram_result = try probeWithTransport(
        std.testing.allocator,
        .telegram,
        "123456:rate-limited",
        .{ .context = &telegram_transport, .request_fn = StaticTransport.request },
    );
    try std.testing.expect(!telegram_result.ok);
    try std.testing.expectEqualStrings("provider_unreachable", telegram_result.detail);
}

const TimeoutTransport = struct {
    calls: usize = 0,

    fn request(context: *anyopaque, _: std.mem.Allocator, _: Request) !Response {
        const self: *TimeoutTransport = @ptrCast(@alignCast(context));
        self.calls += 1;
        return error.Timeout;
    }
};

test "provider timeout is a stable negative result without retry" {
    var transport_state = TimeoutTransport{};
    const result = try probeWithTransport(
        std.testing.allocator,
        .telegram,
        "123456:ABC",
        .{ .context = &transport_state, .request_fn = TimeoutTransport.request },
    );

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("provider_timeout", result.detail);
    try std.testing.expectEqual(@as(usize, 1), transport_state.calls);
}

test "telegram HTTP auth rejection is distinguished from provider outage" {
    var transport_state = StaticTransport{
        .status_code = 401,
        .body = "{\"ok\":false,\"description\":\"Unauthorized\"}",
    };
    const result = try probeWithTransport(
        std.testing.allocator,
        .telegram,
        "123456:rejected",
        .{ .context = &transport_state, .request_fn = StaticTransport.request },
    );

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("provider_auth_rejected", result.detail);
}

test "malformed and oversized provider bodies are rejected safely" {
    var malformed_transport = StaticTransport{ .status_code = 200, .body = "not-json" };
    const malformed = try probeWithTransport(
        std.testing.allocator,
        .telegram,
        "123456:ABC",
        .{ .context = &malformed_transport, .request_fn = StaticTransport.request },
    );
    try std.testing.expect(!malformed.ok);
    try std.testing.expectEqualStrings("invalid_provider_response", malformed.detail);

    const oversized_body = try std.testing.allocator.alloc(u8, 64 * 1024 + 1);
    defer std.testing.allocator.free(oversized_body);
    @memset(oversized_body, ' ');
    const valid_prefix = "{\"ok\":true,\"user_id\":\"U123\"}";
    @memcpy(oversized_body[0..valid_prefix.len], valid_prefix);
    var oversized_transport = StaticTransport{ .status_code = 200, .body = oversized_body };
    const oversized = try probeWithTransport(
        std.testing.allocator,
        .slack,
        "xoxb-test-token",
        .{ .context = &oversized_transport, .request_fn = StaticTransport.request },
    );
    try std.testing.expect(!oversized.ok);
    try std.testing.expectEqualStrings("invalid_provider_response", oversized.detail);
}
