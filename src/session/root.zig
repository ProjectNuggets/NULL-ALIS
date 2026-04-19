//! Session module — canonical session identity, lane routing, and
//! legacy-compatible session-key helpers.
//!
//! `identity.zig` holds the canonical, zero-allocation SessionIdentity /
//! SessionLane / parseSessionKey / formatSessionKey / isOwnedBy surface.
//!
//! The helpers below replace `src/zaki_session.zig` and preserve the prior
//! legacy signatures (silent fallback on buffer error; lenient user_id
//! extraction that does not validate the lane). Internally they delegate to
//! `identity.formatSessionKey` so there is one canonical formatter.

const std = @import("std");

pub const identity = @import("identity.zig");
pub const SessionIdentity = identity.SessionIdentity;
pub const SessionLane = identity.SessionLane;
pub const parseSessionKey = identity.parseSessionKey;
pub const formatSessionKey = identity.formatSessionKey;
pub const isOwnedBy = identity.isOwnedBy;

// ── Legacy-compatible format helpers ────────────────────────────────────────
// Preserve prior `zaki_session.zig` signatures and silent-fallback semantics.
// All production paths now route through `identity.formatSessionKey`.

pub fn userMainSessionKey(buf: []u8, user_id: []const u8) []const u8 {
    return identity.formatSessionKey(buf, user_id, .main, null) catch
        "agent:zaki-bot:user:unknown:main";
}

pub fn userThreadSessionKey(buf: []u8, user_id: []const u8, conversation_id: []const u8) []const u8 {
    return identity.formatSessionKey(buf, user_id, .thread, conversation_id) catch
        "agent:zaki-bot:user:unknown:thread";
}

pub fn userTaskSessionKey(buf: []u8, user_id: []const u8, task_id: []const u8) []const u8 {
    return identity.formatSessionKey(buf, user_id, .task, task_id) catch
        "agent:zaki-bot:user:unknown:task";
}

pub fn userCronSessionKey(buf: []u8, user_id: []const u8, job_id: []const u8) []const u8 {
    return identity.formatSessionKey(buf, user_id, .cron, job_id) catch
        "agent:zaki-bot:user:unknown:cron";
}

pub fn fallbackMainSessionKey() []const u8 {
    return "agent:zaki-bot:main";
}

pub fn fallbackCronSessionKey() []const u8 {
    return "agent:zaki-bot:cron";
}

/// Lenient user_id extraction. Accepts any key of the form
/// `agent:zaki-bot:user:{user_id}:{suffix}` without validating the lane.
/// Matches prior `zaki_session.parseUserIdFromSessionKey` semantics.
pub fn parseUserIdFromSessionKey(session_key: []const u8) ?[]const u8 {
    const prefix = "agent:zaki-bot:user:";
    if (!std.mem.startsWith(u8, session_key, prefix)) return null;
    const rest = session_key[prefix.len..];
    const suffix_idx = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    if (suffix_idx == 0) return null;
    return rest[0..suffix_idx];
}

test {
    _ = identity;
}

// ── Legacy-signature tests (ported from zaki_session.zig) ──────────────────

test "userMainSessionKey formats canonical main session" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:main", userMainSessionKey(&buf, "42"));
}

test "userCronSessionKey formats canonical cron session" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:cron:job-7", userCronSessionKey(&buf, "42", "job-7"));
}

test "userThreadSessionKey formats canonical thread session" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:thread:conv-2", userThreadSessionKey(&buf, "42", "conv-2"));
}

test "userTaskSessionKey formats canonical task session" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:task:t-99", userTaskSessionKey(&buf, "42", "t-99"));
}

test "fallback session keys remain stable" {
    try std.testing.expectEqualStrings("agent:zaki-bot:main", fallbackMainSessionKey());
    try std.testing.expectEqualStrings("agent:zaki-bot:cron", fallbackCronSessionKey());
}

test "parseUserIdFromSessionKey extracts canonical user id" {
    try std.testing.expectEqualStrings("42", parseUserIdFromSessionKey("agent:zaki-bot:user:42:main").?);
    try std.testing.expectEqualStrings("7", parseUserIdFromSessionKey("agent:zaki-bot:user:7:thread:abc").?);
}

test "parseUserIdFromSessionKey rejects non-canonical keys" {
    try std.testing.expect(parseUserIdFromSessionKey("agent:zaki-bot:main") == null);
    try std.testing.expect(parseUserIdFromSessionKey("agent:zaki-bot:user::main") == null);
}

test "userMainSessionKey with short buffer falls back" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings(
        "agent:zaki-bot:user:unknown:main",
        userMainSessionKey(&buf, "42"),
    );
}
