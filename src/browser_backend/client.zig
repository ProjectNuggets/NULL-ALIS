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
    sendFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, url: []const u8, headers: []const []const u8, body: ?[]const u8, timeout_secs: []const u8) anyerror!Response,
};

fn curlSend(_: *anyopaque, allocator: std.mem.Allocator, method: []const u8, url: []const u8, headers: []const []const u8, body: ?[]const u8, timeout_secs: []const u8) anyerror!Response {
    const r = try http_util.curlRequest(allocator, method, url, headers, body, null, timeout_secs);
    return .{ .status_code = r.status_code, .body = r.body };
}
var curl_ctx: u8 = 0;
pub const curl_transport = Transport{ .ctx = &curl_ctx, .sendFn = curlSend };

pub const OrchestratorClient = struct {
    base_url: []const u8,
    timeout_ms: u64 = 60_000,
    transport: Transport = curl_transport,
    /// Bearer token for the orchestrator's auth gate. When non-null/non-empty,
    /// each request carries `Authorization: Bearer <token>`.
    auth_token: ?[]const u8 = null,
    /// Per-user id bound at tool-bind time. When non-null/non-empty, each
    /// request carries `X-Nullalis-User: <id>` so the orchestrator can enforce
    /// per-session ownership.
    user_id: ?[]const u8 = null,

    fn timeoutSecs(self: OrchestratorClient, buf: []u8) []const u8 {
        const ms = self.timeout_ms;
        const secs = ms / 1000 +| @as(u64, @intFromBool(ms % 1000 != 0));
        return std.fmt.bufPrint(buf, "{d}", .{secs}) catch "60";
    }

    /// Build the auth/identity header list into `out` (a 2-slot slice) and the
    /// header strings into `arena`. Returns the populated header slice. The
    /// returned slice and its strings remain valid until `arena` is freed.
    /// When neither field is set, returns an empty slice (preserving the
    /// original unauthenticated behavior).
    fn buildHeaders(self: OrchestratorClient, allocator: std.mem.Allocator, out: *[2][]const u8) ![]const []const u8 {
        var n: usize = 0;
        if (self.auth_token) |tok| {
            if (tok.len > 0) {
                out[n] = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{tok});
                n += 1;
            }
        }
        if (self.user_id) |uid| {
            if (uid.len > 0) {
                out[n] = try std.fmt.allocPrint(allocator, "X-Nullalis-User: {s}", .{uid});
                n += 1;
            }
        }
        return out[0..n];
    }

    fn freeHeaders(allocator: std.mem.Allocator, headers: []const []const u8) void {
        for (headers) |h| allocator.free(h);
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
        var hbuf: [2][]const u8 = undefined;
        const headers = try self.buildHeaders(allocator, &hbuf);
        defer freeHeaders(allocator, headers);
        const resp = try self.transport.sendFn(self.transport.ctx, allocator, "POST", url, headers, body.items, self.timeoutSecs(&tbuf));
        defer allocator.free(resp.body);
        if (resp.status_code == 429) return error.OrchestratorRateLimited;
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
        var hbuf: [2][]const u8 = undefined;
        const headers = try self.buildHeaders(allocator, &hbuf);
        defer freeHeaders(allocator, headers);
        return self.transport.sendFn(self.transport.ctx, allocator, "POST", url, headers, body, self.timeoutSecs(&tbuf));
    }

    /// GET /v1/sessions/{id}/frame -> raw Response (caller parses {frame,url,title}).
    pub fn getFrame(self: OrchestratorClient, allocator: std.mem.Allocator, session_id: []const u8) !Response {
        if (!validSessionId(session_id)) return error.InvalidSessionId;
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/sessions/{s}/frame", .{ self.base_url, session_id });
        defer allocator.free(url);
        var tbuf: [16]u8 = undefined;
        var hbuf: [2][]const u8 = undefined;
        const headers = try self.buildHeaders(allocator, &hbuf);
        defer freeHeaders(allocator, headers);
        return self.transport.sendFn(self.transport.ctx, allocator, "GET", url, headers, null, self.timeoutSecs(&tbuf));
    }

    /// DELETE /v1/sessions/{id}.
    pub fn closeSession(self: OrchestratorClient, allocator: std.mem.Allocator, session_id: []const u8) !void {
        if (!validSessionId(session_id)) return error.InvalidSessionId;
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/sessions/{s}", .{ self.base_url, session_id });
        defer allocator.free(url);
        var tbuf: [16]u8 = undefined;
        var hbuf: [2][]const u8 = undefined;
        const headers = try self.buildHeaders(allocator, &hbuf);
        defer freeHeaders(allocator, headers);
        const resp = try self.transport.sendFn(self.transport.ctx, allocator, "DELETE", url, headers, null, self.timeoutSecs(&tbuf));
        allocator.free(resp.body);
        if (resp.status_code != 200) return error.OrchestratorError;
    }
};

const writeJsonString = @import("../tools/json_escape.zig").writeJsonString;

/// Resolve the orchestrator bearer token: env `BROWSER_ORCHESTRATOR_AUTH_TOKEN`
/// overrides the config value when set (and non-empty). The returned slice
/// either points into the process environment (static for the process lifetime)
/// or into the config (owned by the config allocator) — both outlive the
/// client, so no copy is made.
pub fn resolveAuthToken(config_token: ?[]const u8) ?[]const u8 {
    if (std.posix.getenv("BROWSER_ORCHESTRATOR_AUTH_TOKEN")) |env_tok| {
        if (env_tok.len > 0) return env_tok;
    }
    return config_token;
}

/// Exported test transport so tool unit tests (in other files) can inject canned responses.
pub const TestTransportPub = struct {
    body: []const u8,
    status: u16 = 200,
    /// Records the headers received on the last `send` call so tests can assert
    /// that the client sent the expected auth/identity headers. Each entry is a
    /// copy owned by `header_arena`; freed in `deinit`.
    recorded_headers: [2][]const u8 = .{ "", "" },
    recorded_header_count: usize = 0,
    header_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),

    fn send(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8, headers: []const []const u8, _: ?[]const u8, _: []const u8) anyerror!Response {
        const self: *TestTransportPub = @ptrCast(@alignCast(ctx));
        const a = self.header_arena.allocator();
        self.recorded_header_count = @min(headers.len, self.recorded_headers.len);
        for (headers[0..self.recorded_header_count], 0..) |h, i| {
            self.recorded_headers[i] = try a.dupe(u8, h);
        }
        return .{ .status_code = self.status, .body = try allocator.dupe(u8, self.body) };
    }
    pub fn transport(self: *TestTransportPub) Transport {
        return .{ .ctx = self, .sendFn = TestTransportPub.send };
    }
    /// Returns the recorded headers received on the last send (slice into the
    /// internal fixed buffer; valid until the next send or deinit).
    pub fn lastHeaders(self: *TestTransportPub) []const []const u8 {
        return self.recorded_headers[0..self.recorded_header_count];
    }
    pub fn deinit(self: *TestTransportPub) void {
        self.header_arena.deinit();
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
    var tt = TestTransportPub{ .body = "{\"error\":\"cap\"}", .status = 500 };
    const c = OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    try std.testing.expectError(error.OrchestratorError, c.newSession(std.testing.allocator, "alice", ""));
}

test "newSession surfaces 429 as OrchestratorRateLimited" {
    var tt = TestTransportPub{ .body = "{\"error\":\"cap\"}", .status = 429 };
    const c = OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    try std.testing.expectError(error.OrchestratorRateLimited, c.newSession(std.testing.allocator, "alice", ""));
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

test "getFrame parses a canned frame response" {
    var tt = TestTransportPub{ .body = "{\"frame\":\"AAAA\",\"url\":\"https://x\",\"title\":\"X\"}" };
    const c = OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    const resp = try c.getFrame(std.testing.allocator, "s1");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "AAAA") != null);
}

test "getFrame rejects an injected session id" {
    const c = OrchestratorClient{ .base_url = "http://x" };
    try std.testing.expectError(error.InvalidSessionId, c.getFrame(std.testing.allocator, "../../admin"));
}

test "client sends Authorization bearer and X-Nullalis-User headers when set" {
    var tt = TestTransportPub{ .body = "{\"frame\":\"AAAA\"}" };
    defer tt.deinit();
    const c = OrchestratorClient{
        .base_url = "http://x",
        .transport = tt.transport(),
        .auth_token = "t",
        .user_id = "alice",
    };
    const resp = try c.getFrame(std.testing.allocator, "s1");
    defer std.testing.allocator.free(resp.body);
    const hdrs = tt.lastHeaders();
    try std.testing.expectEqual(@as(usize, 2), hdrs.len);
    try std.testing.expectEqualStrings("Authorization: Bearer t", hdrs[0]);
    try std.testing.expectEqualStrings("X-Nullalis-User: alice", hdrs[1]);
}

test "client sends no auth/identity headers when both fields are null" {
    var tt = TestTransportPub{ .body = "{\"frame\":\"AAAA\"}" };
    defer tt.deinit();
    const c = OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    const resp = try c.getFrame(std.testing.allocator, "s1");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqual(@as(usize, 0), tt.lastHeaders().len);
}

test "client omits empty-string auth_token but still sends user_id" {
    var tt = TestTransportPub{ .body = "{\"frame\":\"AAAA\"}" };
    defer tt.deinit();
    const c = OrchestratorClient{
        .base_url = "http://x",
        .transport = tt.transport(),
        .auth_token = "",
        .user_id = "bob",
    };
    const resp = try c.getFrame(std.testing.allocator, "s1");
    defer std.testing.allocator.free(resp.body);
    const hdrs = tt.lastHeaders();
    try std.testing.expectEqual(@as(usize, 1), hdrs.len);
    try std.testing.expectEqualStrings("X-Nullalis-User: bob", hdrs[0]);
}

test "live: client drives new_session -> navigate -> snapshot(@eN) -> close" {
    const allocator = std.testing.allocator;
    _ = std.posix.getenv("NULLALIS_BROWSER_LIVE_TEST") orelse return error.SkipZigTest;
    // The orchestrator enforces bearer auth + per-session ownership. Read the
    // token the e2e harness exported and present a user id so the authenticated
    // path is exercised. When unset, auth_token stays null (orchestrator with no
    // token enforcement still works).
    const live_token = std.posix.getenv("BROWSER_ORCHESTRATOR_AUTH_TOKEN");
    const c = OrchestratorClient{
        .base_url = "http://localhost:8080",
        .timeout_ms = 120_000,
        .auth_token = live_token,
        .user_id = "e2e-user",
    };

    const sid = try c.newSession(allocator, "e2e-user", "");
    defer allocator.free(sid);

    // open example.com (worker uses the chromium-ns wrapper for --no-sandbox)
    {
        const resp = try c.exec(allocator, sid, "[\"open\",\"https://example.com\"]");
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
