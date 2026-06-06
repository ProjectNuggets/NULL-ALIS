const std = @import("std");
const http_util = @import("../http_util.zig");

pub const Response = struct { status_code: u16, body: []u8 };

/// session ids are orchestrator-generated hex; restrict to a safe charset so an
/// agent-supplied id can't inject path/query metacharacters into the URL.
fn validSessionId(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    for (s) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_';
        if (!ok) return false;
    }
    return true;
}

/// Injectable transport so tools are unit-testable without a live orchestrator.
/// Default is `curl_transport`; tests supply a stub returning canned JSON.
pub const Transport = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, url: []const u8, body: ?[]const u8, timeout_secs: []const u8) anyerror!Response,
};

fn curlSend(_: *anyopaque, allocator: std.mem.Allocator, method: []const u8, url: []const u8, body: ?[]const u8, timeout_secs: []const u8) anyerror!Response {
    const r = try http_util.curlRequest(allocator, method, url, &.{}, body, null, timeout_secs);
    return .{ .status_code = r.status_code, .body = r.body };
}
var curl_ctx: u8 = 0;
pub const curl_transport = Transport{ .ctx = &curl_ctx, .sendFn = curlSend };

pub const OrchestratorClient = struct {
    base_url: []const u8,
    timeout_ms: u64 = 60_000,
    transport: Transport = curl_transport,

    fn timeoutSecs(self: OrchestratorClient, buf: []u8) []const u8 {
        const ms = self.timeout_ms;
        const secs = ms / 1000 +| @as(u64, @intFromBool(ms % 1000 != 0));
        return std.fmt.bufPrint(buf, "{d}", .{secs}) catch "60";
    }

    /// POST /v1/sessions {user_id, auth_profile} -> session_id (caller frees).
    pub fn newSession(self: OrchestratorClient, allocator: std.mem.Allocator, user_id: []const u8, auth_profile: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/sessions", .{self.base_url});
        defer allocator.free(url);
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);
        try body.appendSlice(allocator, "{\"user_id\":");
        try writeJsonString(allocator, &body, user_id);
        try body.appendSlice(allocator, ",\"auth_profile\":");
        try writeJsonString(allocator, &body, auth_profile);
        try body.append(allocator, '}');
        var tbuf: [16]u8 = undefined;
        const resp = try self.transport.sendFn(self.transport.ctx, allocator, "POST", url, body.items, self.timeoutSecs(&tbuf));
        defer allocator.free(resp.body);
        if (resp.status_code != 200) return error.OrchestratorError;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch return error.OrchestratorBadResponse;
        defer parsed.deinit();
        const obj = switch (parsed.value) { .object => |o| o, else => return error.OrchestratorBadResponse };
        const sid = switch (obj.get("session_id") orelse return error.OrchestratorBadResponse) { .string => |s| s, else => return error.OrchestratorBadResponse };
        return allocator.dupe(u8, sid);
    }

    /// POST /v1/sessions/{id}/exec {args} -> raw Response (caller frees body).
    pub fn exec(self: OrchestratorClient, allocator: std.mem.Allocator, session_id: []const u8, args_json: []const u8) !Response {
        if (!validSessionId(session_id)) return error.InvalidSessionId;
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/sessions/{s}/exec", .{ self.base_url, session_id });
        defer allocator.free(url);
        const body = try std.fmt.allocPrint(allocator, "{{\"args\":{s}}}", .{args_json});
        defer allocator.free(body);
        var tbuf: [16]u8 = undefined;
        return self.transport.sendFn(self.transport.ctx, allocator, "POST", url, body, self.timeoutSecs(&tbuf));
    }

    /// DELETE /v1/sessions/{id}.
    pub fn closeSession(self: OrchestratorClient, allocator: std.mem.Allocator, session_id: []const u8) !void {
        if (!validSessionId(session_id)) return error.InvalidSessionId;
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/sessions/{s}", .{ self.base_url, session_id });
        defer allocator.free(url);
        var tbuf: [16]u8 = undefined;
        const resp = try self.transport.sendFn(self.transport.ctx, allocator, "DELETE", url, null, self.timeoutSecs(&tbuf));
        allocator.free(resp.body);
        if (resp.status_code != 200) return error.OrchestratorError;
    }
};

const writeJsonString = @import("../tools/json_escape.zig").writeJsonString;

/// Exported test transport so tool unit tests (in other files) can inject canned responses.
pub const TestTransportPub = struct {
    body: []const u8,
    status: u16 = 200,
    fn send(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8, _: ?[]const u8, _: []const u8) anyerror!Response {
        const self: *TestTransportPub = @ptrCast(@alignCast(ctx));
        return .{ .status_code = self.status, .body = try allocator.dupe(u8, self.body) };
    }
    pub fn transport(self: *TestTransportPub) Transport {
        return .{ .ctx = self, .sendFn = TestTransportPub.send };
    }
};

test "newSession parses session_id from a mock transport" {
    var tt = TestTransportPub{ .body = "{\"session_id\":\"abc123\"}" };
    const c = OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    const sid = try c.newSession(std.testing.allocator, "alice", "");
    defer std.testing.allocator.free(sid);
    try std.testing.expectEqualStrings("abc123", sid);
}

test "newSession surfaces non-200 as error" {
    var tt = TestTransportPub{ .body = "{\"error\":\"cap\"}", .status = 429 };
    const c = OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    try std.testing.expectError(error.OrchestratorError, c.newSession(std.testing.allocator, "alice", ""));
}

test "validSessionId accepts hex ids, rejects path injection" {
    try std.testing.expect(validSessionId("ad559f86565be951f73e92307dfde5a2"));
    try std.testing.expect(validSessionId("sess-abc_123"));
    try std.testing.expect(!validSessionId(""));
    try std.testing.expect(!validSessionId("../../v1/admin"));
    try std.testing.expect(!validSessionId("a/b"));
    try std.testing.expect(!validSessionId("a?b"));
    try std.testing.expect(!validSessionId("a b"));
}

test "live: client drives new_session -> navigate -> snapshot(@eN) -> close" {
    const allocator = std.testing.allocator;
    _ = std.posix.getenv("NULLALIS_BROWSER_LIVE_TEST") orelse return error.SkipZigTest;
    const c = OrchestratorClient{ .base_url = "http://localhost:8080", .timeout_ms = 120_000 };

    const sid = try c.newSession(allocator, "e2e-user", "");
    defer allocator.free(sid);

    // open example.com (worker uses the chromium-ns wrapper for --no-sandbox)
    {
        const resp = try c.exec(allocator, sid, "[\"--executable-path\",\"/usr/local/bin/chromium-ns\",\"open\",\"https://example.com\"]");
        defer allocator.free(resp.body);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    }
    // snapshot must contain an @eN ref
    {
        const resp = try c.exec(allocator, sid, "[\"snapshot\"]");
        defer allocator.free(resp.body);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "ref=e") != null);
    }
    // 403 path: a denied verb is rejected by the orchestrator allowlist
    {
        const resp = try c.exec(allocator, sid, "[\"eval\",\"1+1\"]");
        defer allocator.free(resp.body);
        try std.testing.expectEqual(@as(u16, 403), resp.status_code);
    }
    try c.closeSession(allocator, sid);
}
