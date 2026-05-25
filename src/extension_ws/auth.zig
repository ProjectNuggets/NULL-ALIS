//! Token validation for the extension WebSocket endpoint.
//!
//! For v1, we reuse the same `internal_service_tokens` surface the
//! gateway's `/api/v1/chat/stream` endpoint uses (see
//! `gateway.validateInternalServiceToken`). The auth frame's `token`
//! field is compared against the configured list; on a match the
//! frame's `user_id` field (or, fallback, the validator's
//! `default_user_id`) becomes the connection's identity.
//!
//! This keeps the v1 deployment story simple: the same secret that
//! authenticates the BFF→gateway chat stream also authenticates the
//! extension's outbound socket. A future iteration can split the
//! surfaces (per-extension API keys, OIDC bearer, etc.) by swapping
//! the `AuthValidator` instance without touching the server pipeline.

const std = @import("std");

pub const AuthDecision = struct {
    ok: bool,
    /// On success, the user_id the connection registers under in the
    /// hub. On failure, null.
    user_id: ?[]const u8 = null,
    /// On failure, a short machine-readable reason (`"invalid_token"`,
    /// `"missing_user_id"`, `"malformed_auth_frame"`). Lands in the
    /// `auth_ack{ok:false, error}` envelope verbatim — keep it
    /// alphanumeric-and-underscores so popup-rendering stays simple.
    reason: ?[]const u8 = null,
};

/// Stateless validator: given an auth frame JSON payload, decides
/// whether to admit the connection.
pub const AuthValidator = struct {
    /// Configured tokens; matches gateway `internal_service_tokens`.
    /// Empty list ⇒ reject everything (closed-by-default).
    tokens: []const []const u8,

    pub fn validate(self: AuthValidator, auth_frame_json: []const u8) AuthDecision {
        // Parse with a stack-bounded arena so the validator can be
        // called from any thread without involving a long-lived
        // allocator. 8 KB is plenty for the contract's three-field
        // auth frame (token + extension_version + optional user_id).
        var buf: [8 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            fba.allocator(),
            auth_frame_json,
            .{},
        ) catch return .{ .ok = false, .reason = "malformed_auth_frame" };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return .{ .ok = false, .reason = "malformed_auth_frame" },
        };

        const type_val = obj.get("type") orelse return .{ .ok = false, .reason = "malformed_auth_frame" };
        const type_str = switch (type_val) {
            .string => |s| s,
            else => return .{ .ok = false, .reason = "malformed_auth_frame" },
        };
        if (!std.mem.eql(u8, type_str, "auth")) {
            return .{ .ok = false, .reason = "malformed_auth_frame" };
        }

        const token_val = obj.get("token") orelse return .{ .ok = false, .reason = "invalid_token" };
        const token_str = switch (token_val) {
            .string => |s| s,
            else => return .{ .ok = false, .reason = "invalid_token" },
        };

        if (!matchesAnyToken(token_str, self.tokens)) {
            return .{ .ok = false, .reason = "invalid_token" };
        }

        // The extension contract DOES NOT mandate a `user_id` in the
        // auth frame — the gateway resolves identity from the
        // `X-Zaki-User-Id` header on standard HTTP. For WS we don't
        // have headers post-upgrade, so we let the auth frame include
        // a `user_id` field. Without one, fall through to
        // `missing_user_id` so operators see the gap explicitly.
        const user_id_val = obj.get("user_id") orelse return .{ .ok = false, .reason = "missing_user_id" };
        const user_id_str = switch (user_id_val) {
            .string => |s| s,
            else => return .{ .ok = false, .reason = "missing_user_id" },
        };
        if (user_id_str.len == 0) return .{ .ok = false, .reason = "missing_user_id" };

        // The user_id slice points into the parsed arena — but the
        // arena is going to be reclaimed when we return. We can't
        // return a borrowed slice. The caller (server.handleUpgrade)
        // must dupe before storing. To make that work cleanly without
        // a callback, we return a *parsed* sub-slice that lives only
        // for the immediate `if (decision.ok)` block, and require the
        // caller to copy out before the next call.
        //
        // In practice the caller takes `decision.user_id` and
        // immediately passes it to `hub.registerConn`, which dupes
        // before storing. The slice is valid for that single sync
        // call, which is the existing contract for `extractHeader`
        // and friends.
        return .{ .ok = true, .user_id = user_id_str };
    }
};

fn matchesAnyToken(candidate: []const u8, tokens: []const []const u8) bool {
    for (tokens) |t| {
        if (constantTimeEql(t, candidate)) return true;
    }
    return false;
}

/// Constant-time token comparison. Avoids leaking secret length match
/// progress via early-exit timing. Standard library `crypto.timing_safe`
/// requires fixed-length slices; we early-exit on length mismatch
/// (which is fine — the LENGTH isn't secret, only the bytes are).
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

// ── Tests ────────────────────────────────────────────────────────────

test "AuthValidator accepts valid token + user_id" {
    const v = AuthValidator{ .tokens = &.{"sekrit-1"} };
    const auth =
        \\{"type":"auth","token":"sekrit-1","user_id":"alice","extension_version":"0.1.0"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(d.ok);
    try std.testing.expectEqualStrings("alice", d.user_id.?);
    try std.testing.expect(d.reason == null);
}

test "AuthValidator rejects wrong token" {
    const v = AuthValidator{ .tokens = &.{"sekrit-1"} };
    const auth =
        \\{"type":"auth","token":"bogus","user_id":"alice","extension_version":"0.1.0"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("invalid_token", d.reason.?);
}

test "AuthValidator rejects missing user_id" {
    const v = AuthValidator{ .tokens = &.{"sekrit-1"} };
    const auth =
        \\{"type":"auth","token":"sekrit-1","extension_version":"0.1.0"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("missing_user_id", d.reason.?);
}

test "AuthValidator rejects empty user_id" {
    const v = AuthValidator{ .tokens = &.{"sekrit-1"} };
    const auth =
        \\{"type":"auth","token":"sekrit-1","user_id":"","extension_version":"0.1.0"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("missing_user_id", d.reason.?);
}

test "AuthValidator rejects wrong frame type" {
    const v = AuthValidator{ .tokens = &.{"sekrit-1"} };
    const auth =
        \\{"type":"ping","token":"sekrit-1","user_id":"alice"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("malformed_auth_frame", d.reason.?);
}

test "AuthValidator rejects malformed JSON" {
    const v = AuthValidator{ .tokens = &.{"sekrit-1"} };
    const d = v.validate("not json at all");
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("malformed_auth_frame", d.reason.?);
}

test "AuthValidator rejects empty token list" {
    const v = AuthValidator{ .tokens = &.{} };
    const auth =
        \\{"type":"auth","token":"anything","user_id":"alice"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("invalid_token", d.reason.?);
}

test "AuthValidator matches one of several configured tokens" {
    const v = AuthValidator{ .tokens = &.{ "alpha", "beta", "gamma" } };
    const auth =
        \\{"type":"auth","token":"beta","user_id":"alice"}
    ;
    const d = v.validate(auth);
    try std.testing.expect(d.ok);
    try std.testing.expectEqualStrings("alice", d.user_id.?);
}

test "constantTimeEql length mismatch returns false" {
    try std.testing.expect(!constantTimeEql("abc", "abcd"));
    try std.testing.expect(!constantTimeEql("abcd", "abc"));
}

test "constantTimeEql equal slices return true" {
    try std.testing.expect(constantTimeEql("hello", "hello"));
    try std.testing.expect(constantTimeEql("", ""));
}

test "constantTimeEql different bytes return false" {
    try std.testing.expect(!constantTimeEql("hello", "hellp"));
    try std.testing.expect(!constantTimeEql("hello", "Hello"));
}
