//! MCP server — caller authentication boundary.
//!
//! Threat model: `nullalis mcp serve` exposes tool execution to whatever
//! is on the other end of the transport. For stdio that is the process
//! that spawned us (already a trust relationship — the parent chose to
//! launch nullalis as a child and could run anything else instead). For a
//! future network transport it would be an arbitrary remote peer.
//!
//! Policy:
//!   - stdio with no token configured  → allowed. The parent process
//!     already has full local authority; demanding a token it would have
//!     to pass to its own child adds no security and breaks the
//!     zero-config `claude mcp serve`-style UX. Logged loudly at startup.
//!   - a token IS configured           → every request after `initialize`
//!     must present it. The token travels in `initialize` params under
//!     `clientInfo.authToken` (MCP has no standard auth field for stdio;
//!     this mirrors how the gateway threads its internal token).
//!   - the escape hatch `NULLALIS_MCP_EXPOSE_ALL=1` (full registry) is
//!     orthogonal to auth: even with it set, an unauthenticated caller
//!     (token configured but not presented) is rejected at `initialize`.
//!
//! The token is sourced from `NULLALIS_MCP_AUTH_TOKEN`, falling back to the
//! gateway's `NULLALIS_INTERNAL_SERVICE_TOKEN` so an operator who already
//! runs a tokened gateway gets a consistent secret.

const std = @import("std");

pub const token_env = "NULLALIS_MCP_AUTH_TOKEN";
pub const fallback_token_env = "NULLALIS_INTERNAL_SERVICE_TOKEN";

/// Minimum length for a configured token. A short token is almost
/// certainly a mistake (placeholder, truncated paste) and we refuse it
/// rather than silently running with a weak secret. Matches the gateway's
/// `INTERNAL_TOKEN_MIN_LEN`.
pub const token_min_len: usize = 16;

pub const AuthError = error{
    /// A token is configured but the caller presented none or a wrong one.
    Unauthorized,
};

/// Resolved auth configuration for the server's lifetime.
pub const AuthConfig = struct {
    /// The expected token, or null when none is configured (open stdio mode).
    /// Heap-owned when non-null; freed by `deinit`.
    token: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    /// Load the auth config from the environment. Never fails: a missing
    /// or too-short token resolves to "no token" (open mode) so a
    /// misconfiguration degrades to the documented zero-config behavior
    /// rather than refusing to start. `weak_token` is set true when a
    /// token was present but rejected for being too short, so the caller
    /// can warn.
    pub fn load(allocator: std.mem.Allocator, weak_token: *bool) AuthConfig {
        weak_token.* = false;
        const raw = readEnv(allocator, token_env) orelse readEnv(allocator, fallback_token_env) orelse
            return .{ .token = null, .allocator = allocator };
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len < token_min_len) {
            weak_token.* = trimmed.len > 0;
            allocator.free(raw);
            return .{ .token = null, .allocator = allocator };
        }
        // Re-own just the trimmed slice so deinit frees exactly what we hold.
        const owned = allocator.dupe(u8, trimmed) catch {
            allocator.free(raw);
            return .{ .token = null, .allocator = allocator };
        };
        allocator.free(raw);
        return .{ .token = owned, .allocator = allocator };
    }

    pub fn deinit(self: *AuthConfig) void {
        if (self.token) |t| self.allocator.free(t);
        self.token = null;
    }

    /// True when a token is configured — i.e. requests must authenticate.
    pub fn required(self: AuthConfig) bool {
        return self.token != null;
    }

    /// Verify a presented token. When no token is configured this always
    /// succeeds (open stdio mode). When one is configured, `presented`
    /// must match it in constant time.
    pub fn verify(self: AuthConfig, presented: ?[]const u8) AuthError!void {
        const expected = self.token orelse return; // open mode
        const got = presented orelse return AuthError.Unauthorized;
        if (!constantTimeEqual(expected, got)) return AuthError.Unauthorized;
    }
};

fn readEnv(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

/// Length-independent comparison: avoids leaking the secret's length or a
/// prefix-match position through timing. Mirrors `gateway.constantTimeEqual`.
pub fn constantTimeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// Extract a caller-supplied auth token from `initialize` params, if any.
/// MCP defines no standard stdio auth field; we look under
/// `clientInfo.authToken` (string). Returns null when absent.
pub fn extractTokenFromInitParams(params: ?std.json.Value) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const client_info = p.object.get("clientInfo") orelse return null;
    if (client_info != .object) return null;
    const tok = client_info.object.get("authToken") orelse return null;
    if (tok != .string) return null;
    return tok.string;
}

// ── Tests ───────────────────────────────────────────────────────

const testing = std.testing;

test "server_auth: constantTimeEqual matches and mismatches" {
    try testing.expect(constantTimeEqual("secret-token-xyz", "secret-token-xyz"));
    try testing.expect(!constantTimeEqual("secret-token-xyz", "secret-token-xyy"));
    try testing.expect(!constantTimeEqual("short", "longer-string"));
    try testing.expect(constantTimeEqual("", ""));
}

test "server_auth: verify in open mode (no token) always succeeds" {
    var cfg = AuthConfig{ .token = null, .allocator = testing.allocator };
    try cfg.verify(null);
    try cfg.verify("anything");
    try testing.expect(!cfg.required());
}

test "server_auth: verify with configured token enforces match" {
    var cfg = AuthConfig{
        .token = try testing.allocator.dupe(u8, "a-sufficiently-long-token"),
        .allocator = testing.allocator,
    };
    defer cfg.deinit();
    try testing.expect(cfg.required());
    try cfg.verify("a-sufficiently-long-token");
    try testing.expectError(AuthError.Unauthorized, cfg.verify(null));
    try testing.expectError(AuthError.Unauthorized, cfg.verify("wrong"));
}

test "server_auth: extractTokenFromInitParams reads clientInfo.authToken" {
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"protocolVersion":"2024-11-05","clientInfo":{"name":"x","authToken":"tok-123"}}
    , .{});
    defer p.deinit();
    const tok = extractTokenFromInitParams(p.value);
    try testing.expect(tok != null);
    try testing.expectEqualStrings("tok-123", tok.?);
}

test "server_auth: extractTokenFromInitParams returns null when absent" {
    const p = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"protocolVersion":"2024-11-05","clientInfo":{"name":"x"}}
    , .{});
    defer p.deinit();
    try testing.expect(extractTokenFromInitParams(p.value) == null);
}

test "server_auth: extractTokenFromInitParams returns null for null params" {
    try testing.expect(extractTokenFromInitParams(null) == null);
}

test "server_auth: token_min_len matches gateway convention" {
    try testing.expectEqual(@as(usize, 16), token_min_len);
}
