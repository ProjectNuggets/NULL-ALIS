//! Bounded, read-only provider probes for user-managed channel credentials.

const std = @import("std");
const http_util = @import("http_util.zig");

const probe_timeout_ms: u32 = 5_000;
const max_provider_response_bytes: usize = 64 * 1024;

/// Minimum spacing between two outbound `/test` probes for the same
/// (user, channel). A call inside this window is answered from local state
/// as `rate_limited` and never touches the provider — bounding the
/// outbound-probe / provider-rate-limit-burn vector a loop could otherwise
/// open by hammering `/test`.
const cooldown_window_s: i64 = 30;

/// Fixed capacity of the cooldown table. Bounds memory to a constant
/// regardless of how many distinct (user, channel) pairs probe — old
/// entries are recycled by eviction (see `checkAndClaim`), so the map never
/// grows unboundedly.
const rate_limit_slots: usize = 512;

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
    // Force the curl transport (`.curl_only`) rather than `.native_preferred`.
    //
    // The native channel transport bounds only socket recv/send via
    // SO_RCVTIMEO/SO_SNDTIMEO (`apply_timeouts` in http_native), which is
    // applied *after* the connect completes. Its `getAddressList` DNS lookup
    // and blocking `tcpConnectToAddress` are unbounded, so a blackholed
    // provider host hangs on connect/DNS for the OS default TCP timeout
    // (tens of seconds), well past our intended 5s bound.
    //
    // curl caps the connect+DNS+TLS-handshake phase with `--connect-timeout`
    // and the whole operation with `--max-time` (both emitted by
    // `buildCurlArgs`), so a dead provider fails fast within the total
    // deadline (~5s). The probe is a rare, cooldown-gated liveness check, so
    // giving up native connection pooling here costs nothing.
    const response = try http_util.request_with_mode(allocator, .{ .mode = .curl_only }, .{
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

// ── Per-(user, channel) outbound-probe cooldown ───────────────────────
//
// The gateway calls `probeWithCooldown` instead of `probe` so the rate
// decision and the outbound request live together: when a caller is inside
// the cooldown window we return `.rate_limited` and never invoke the
// transport at all.

/// Outcome of a cooldown-gated `/test`. `rate_limited` carries the number of
/// seconds remaining in the window; `probed` carries the real probe result.
pub const TestOutcome = union(enum) {
    rate_limited: i64,
    probed: ProbeResult,
};

const RateLimitSlot = struct {
    in_use: bool = false,
    user_id: i64 = 0,
    channel: Channel = .telegram,
    last_probe_s: i64 = 0,
};

/// Process-wide, fixed-capacity cooldown table. Thread-safe via `mutex`;
/// the lock is held only for the O(rate_limit_slots) check-and-claim scan,
/// never across the outbound probe.
const test_rate_limiter = struct {
    var mutex: std.Thread.Mutex = .{};
    var slots = [_]RateLimitSlot{.{}} ** rate_limit_slots;

    /// Atomically decide whether a (user, channel) probe is allowed at
    /// `now_s`. Returns the seconds remaining if still cooling down (state
    /// untouched); otherwise claims the slot (starting the window) and
    /// returns null. Bounded: reuses free/expired slots, and when every slot
    /// holds a live entry it evicts the most-stale one (fail-open under
    /// extreme load rather than wrongly rate-limiting a fresh key).
    fn checkAndClaim(user_id: i64, channel: Channel, now_s: i64) ?i64 {
        mutex.lock();
        defer mutex.unlock();

        var victim: usize = 0;
        var victim_probe_s: i64 = std.math.maxInt(i64);
        for (&slots, 0..) |*slot, i| {
            if (slot.in_use and slot.user_id == user_id and slot.channel == channel) {
                const elapsed = now_s - slot.last_probe_s;
                if (elapsed >= 0 and elapsed < cooldown_window_s) {
                    return cooldown_window_s - elapsed;
                }
                // Window elapsed (or clock moved backwards) — renew + allow.
                slot.last_probe_s = now_s;
                return null;
            }
            // Track the best eviction candidate: free slots sort ahead of any
            // in-use slot, then the most-stale in-use slot.
            const candidate_s = if (slot.in_use) slot.last_probe_s else std.math.minInt(i64);
            if (candidate_s < victim_probe_s) {
                victim_probe_s = candidate_s;
                victim = i;
            }
        }

        slots[victim] = .{
            .in_use = true,
            .user_id = user_id,
            .channel = channel,
            .last_probe_s = now_s,
        };
        return null;
    }

    fn reset() void {
        mutex.lock();
        defer mutex.unlock();
        slots = [_]RateLimitSlot{.{}} ** rate_limit_slots;
    }
};

/// Cooldown-gated production probe. When the (user, channel) is inside the
/// cooldown window, returns `.rate_limited` WITHOUT making any outbound
/// provider request; otherwise claims the window and performs exactly one
/// bounded probe. `now_s` is the caller's `std.time.timestamp()`.
pub fn probeWithCooldown(
    allocator: std.mem.Allocator,
    user_id: i64,
    channel: Channel,
    token: []const u8,
    now_s: i64,
) !TestOutcome {
    if (test_rate_limiter.checkAndClaim(user_id, channel, now_s)) |remaining_s| {
        return .{ .rate_limited = remaining_s };
    }
    return .{ .probed = try probe(allocator, channel, token) };
}

/// Transport-injecting variant of `probeWithCooldown` for deterministic
/// tests. Shares the same cooldown table so the "no outbound call while
/// rate-limited" property is exercised against a counting transport.
pub fn probeWithCooldownTransport(
    allocator: std.mem.Allocator,
    user_id: i64,
    channel: Channel,
    token: []const u8,
    now_s: i64,
    transport: Transport,
) !TestOutcome {
    if (test_rate_limiter.checkAndClaim(user_id, channel, now_s)) |remaining_s| {
        return .{ .rate_limited = remaining_s };
    }
    return .{ .probed = try probeWithTransport(allocator, channel, token, transport) };
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

test "second /test within the cooldown window is rate-limited without an outbound call" {
    test_rate_limiter.reset();
    var recording = RecordingTransport{};
    const transport: Transport = .{ .context = &recording, .request_fn = RecordingTransport.request };

    // First call probes the provider exactly once and starts the window.
    const first = try probeWithCooldownTransport(std.testing.allocator, 7, .telegram, "123456:ABC", 1_000, transport);
    try std.testing.expect(first == .probed);
    try std.testing.expect(first.probed.ok);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);

    // A second call 5s later is inside the 30s window: rate-limited, and the
    // transport is NOT invoked again (call count stays at 1).
    const second = try probeWithCooldownTransport(std.testing.allocator, 7, .telegram, "123456:ABC", 1_005, transport);
    try std.testing.expect(second == .rate_limited);
    try std.testing.expectEqual(@as(i64, 25), second.rate_limited);
    try std.testing.expectEqual(@as(usize, 1), recording.calls);

    // Once the window elapses the probe runs again.
    const third = try probeWithCooldownTransport(std.testing.allocator, 7, .telegram, "123456:ABC", 1_031, transport);
    try std.testing.expect(third == .probed);
    try std.testing.expectEqual(@as(usize, 2), recording.calls);
}

test "cooldown is scoped per (user, channel)" {
    test_rate_limiter.reset();
    var telegram_transport = RecordingTransport{};
    const t: Transport = .{ .context = &telegram_transport, .request_fn = RecordingTransport.request };

    // user 42 telegram: first allowed, immediate retry blocked.
    try std.testing.expect((try probeWithCooldownTransport(std.testing.allocator, 42, .telegram, "123456:ABC", 2_000, t)) == .probed);
    try std.testing.expect((try probeWithCooldownTransport(std.testing.allocator, 42, .telegram, "123456:ABC", 2_001, t)) == .rate_limited);

    // A different user is independent — not blocked by user 42's window.
    try std.testing.expect((try probeWithCooldownTransport(std.testing.allocator, 43, .telegram, "123456:ABC", 2_001, t)) == .probed);
    try std.testing.expectEqual(@as(usize, 2), telegram_transport.calls);

    // A different channel for the same user is independent too.
    var slack_transport = SlackRecordingTransport{};
    const s: Transport = .{ .context = &slack_transport, .request_fn = SlackRecordingTransport.request };
    try std.testing.expect((try probeWithCooldownTransport(std.testing.allocator, 42, .slack, "xoxb-test-token", 2_002, s)) == .probed);
    try std.testing.expectEqual(@as(usize, 1), slack_transport.calls);
}

test "cooldown table stays bounded and recycles expired slots" {
    test_rate_limiter.reset();
    var recording = RecordingTransport{};
    const transport: Transport = .{ .context = &recording, .request_fn = RecordingTransport.request };

    // Drive far more distinct users than the table has slots; expired entries
    // are recycled so this never grows past `rate_limit_slots` and never
    // panics. Each user is spaced beyond the window so none collide.
    var user_id: i64 = 0;
    while (user_id < @as(i64, rate_limit_slots) * 4) : (user_id += 1) {
        const now_s = 10_000 + user_id * (cooldown_window_s + 1);
        const outcome = try probeWithCooldownTransport(std.testing.allocator, user_id, .telegram, "123456:ABC", now_s, transport);
        try std.testing.expect(outcome == .probed);
    }
}
