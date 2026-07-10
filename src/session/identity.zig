//! Session identity types and canonical key parsing/formatting.
//!
//! Provides a first-class SessionIdentity struct and SessionLane enum that
//! replace the ad-hoc inline key construction and validation scattered across
//! gateway.zig and zaki_session.zig.
//!
//! All parse operations are zero-allocation — returned SessionIdentity fields
//! point into the input slice. Format operations write into caller-provided
//! buffers.

const std = @import("std");

// ── SessionLane ─────────────────────────────────────────────────────────────

/// The canonical execution lane for a session.
pub const SessionLane = enum {
    main,
    thread,
    task,
    cron,

    /// Convert lane to its canonical string representation.
    pub fn toSlice(self: SessionLane) []const u8 {
        return switch (self) {
            .main => "main",
            .thread => "thread",
            .task => "task",
            .cron => "cron",
        };
    }

    /// Parse a lane from its canonical string representation.
    /// Returns null for unrecognised values.
    pub fn fromSlice(s: []const u8) ?SessionLane {
        if (std.mem.eql(u8, s, "main")) return .main;
        if (std.mem.eql(u8, s, "thread")) return .thread;
        if (std.mem.eql(u8, s, "task")) return .task;
        if (std.mem.eql(u8, s, "cron")) return .cron;
        return null;
    }
};

// ── SessionIdentity ─────────────────────────────────────────────────────────

/// Canonical identity for any session.
///
/// All slice fields point into the original session_key string — no allocation.
pub const SessionIdentity = struct {
    /// Authenticated user identifier.
    user_id: []const u8,
    /// Execution lane (main / thread / task / cron).
    lane: SessionLane,
    /// Lane-scoped identifier — null for .main, required for thread/task/cron.
    lane_id: ?[]const u8,
    /// The full canonical session key string (the source for other fields).
    session_key: []const u8,

    /// Key prefix shared by every canonical user session key.
    pub const PREFIX = "agent:zaki-bot:user:";
    /// Maximum accepted key length (inclusive); longer keys are rejected.
    pub const MAX_KEY_LEN = 255;
};

// ── ParseError ───────────────────────────────────────────────────────────────

pub const ParseError = error{
    /// Key does not begin with SessionIdentity.PREFIX.
    InvalidPrefix,
    /// No lane segment follows the user_id (missing colon after user_id).
    MissingUserId,
    /// user_id segment is present but empty.
    EmptyUserId,
    /// Lane name is not one of main/thread/task/cron.
    InvalidLane,
    /// Lane requires a lane_id (thread/task/cron) but none was supplied.
    MissingLaneId,
    /// session_key exceeds MAX_KEY_LEN.
    KeyTooLong,
};

// ── parseSessionKey ──────────────────────────────────────────────────────────

/// Parse a canonical session key into its constituent parts.
///
/// Zero-allocation: all returned slice fields point into `session_key`.
///
/// Valid key formats:
///   agent:zaki-bot:user:{user_id}:main
///   agent:zaki-bot:user:{user_id}:thread:{lane_id}
///   agent:zaki-bot:user:{user_id}:task:{lane_id}
///   agent:zaki-bot:user:{user_id}:cron:{lane_id}
pub fn parseSessionKey(session_key: []const u8) ParseError!SessionIdentity {
    // Length guards
    if (session_key.len == 0 or session_key.len > SessionIdentity.MAX_KEY_LEN) {
        return ParseError.KeyTooLong;
    }

    // Prefix check
    if (!std.mem.startsWith(u8, session_key, SessionIdentity.PREFIX)) {
        return ParseError.InvalidPrefix;
    }

    // Everything after "agent:zaki-bot:user:"
    const after_prefix = session_key[SessionIdentity.PREFIX.len..];

    // Split on first ':' to extract user_id
    const user_end = std.mem.indexOfScalar(u8, after_prefix, ':') orelse
        return ParseError.MissingUserId;

    if (user_end == 0) return ParseError.EmptyUserId;

    const user_id = after_prefix[0..user_end];

    // Remainder is "{lane}" or "{lane}:{lane_id}"
    const lane_rest = after_prefix[user_end + 1 ..];

    // Split lane name from optional lane_id
    const lane_end = std.mem.indexOfScalar(u8, lane_rest, ':');
    const lane_str = if (lane_end) |e| lane_rest[0..e] else lane_rest;

    const lane = SessionLane.fromSlice(lane_str) orelse return ParseError.InvalidLane;

    const lane_id: ?[]const u8 = switch (lane) {
        .main => null,
        .thread, .task, .cron => blk: {
            const e = lane_end orelse return ParseError.MissingLaneId;
            const id = lane_rest[e + 1 ..];
            if (id.len == 0) return ParseError.MissingLaneId;
            break :blk id;
        },
    };

    return SessionIdentity{
        .user_id = user_id,
        .lane = lane,
        .lane_id = lane_id,
        .session_key = session_key,
    };
}

// ── formatSessionKey ─────────────────────────────────────────────────────────

/// Format a canonical session key from its constituent parts into `buf`.
///
/// Returns the populated slice on success, or `error.BufferTooSmall` if `buf`
/// is not large enough.
pub fn formatSessionKey(
    buf: []u8,
    user_id: []const u8,
    lane: SessionLane,
    lane_id: ?[]const u8,
) error{BufferTooSmall}![]const u8 {
    return switch (lane) {
        .main => std.fmt.bufPrint(buf, "{s}{s}:{s}", .{
            SessionIdentity.PREFIX,
            user_id,
            lane.toSlice(),
        }) catch return error.BufferTooSmall,
        .thread, .task, .cron => std.fmt.bufPrint(buf, "{s}{s}:{s}:{s}", .{
            SessionIdentity.PREFIX,
            user_id,
            lane.toSlice(),
            lane_id orelse "",
        }) catch return error.BufferTooSmall,
    };
}

// ── isOwnedBy ────────────────────────────────────────────────────────────────

/// Return true if `session_key` belongs to `user_id`.
///
/// Checks that the key starts with `"agent:zaki-bot:user:{user_id}:"`.
/// Replaces gateway.zig's sessionKeyOwnedByUser.
pub fn isOwnedBy(session_key: []const u8, user_id: []const u8) bool {
    var prefix_buf: [SessionIdentity.MAX_KEY_LEN + 1]u8 = undefined;
    const prefix = std.fmt.bufPrint(
        &prefix_buf,
        "{s}{s}:",
        .{ SessionIdentity.PREFIX, user_id },
    ) catch return false;
    return std.mem.startsWith(u8, session_key, prefix);
}

// ── sameUser ─────────────────────────────────────────────────────────────────

/// Return true when two session keys belong to the SAME user.
///
/// Ownership checks built on session keys must be USER-granular, not
/// lane-granular: one user's turns run on many lanes of the same identity
/// (`agent:zaki-bot:user:{id}:main`, `:thread:{conv}`, `:cron:{job}`), and
/// artifacts created on one lane (subagent batches, ledger task entries) must
/// stay accessible from the user's other lanes — the S1a wake turn collects
/// on the cron:heartbeat lane, S1b recovery reads from later main/thread
/// turns.
///
/// When BOTH keys parse as canonical identities, they match iff their
/// `user_id` components are equal. When either key is non-canonical
/// (legacy/opaque keys), fall back to exact key equality — fail-closed: an
/// unparseable key never matches anything but its byte-identical self, and a
/// canonical key never matches a non-canonical one.
pub fn sameUser(key_a: []const u8, key_b: []const u8) bool {
    const a = parseSessionKey(key_a) catch return std.mem.eql(u8, key_a, key_b);
    const b = parseSessionKey(key_b) catch return std.mem.eql(u8, key_a, key_b);
    return std.mem.eql(u8, a.user_id, b.user_id);
}

// ── Inline tests ─────────────────────────────────────────────────────────────

test "parse valid main key" {
    const id = try parseSessionKey("agent:zaki-bot:user:42:main");
    try std.testing.expectEqualStrings("42", id.user_id);
    try std.testing.expectEqual(SessionLane.main, id.lane);
    try std.testing.expect(id.lane_id == null);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:main", id.session_key);
}

test "parse valid thread key" {
    const id = try parseSessionKey("agent:zaki-bot:user:42:thread:conv-2");
    try std.testing.expectEqualStrings("42", id.user_id);
    try std.testing.expectEqual(SessionLane.thread, id.lane);
    try std.testing.expectEqualStrings("conv-2", id.lane_id.?);
}

test "parse valid task key" {
    const id = try parseSessionKey("agent:zaki-bot:user:42:task:t-99");
    try std.testing.expectEqualStrings("42", id.user_id);
    try std.testing.expectEqual(SessionLane.task, id.lane);
    try std.testing.expectEqualStrings("t-99", id.lane_id.?);
}

test "parse valid cron key" {
    const id = try parseSessionKey("agent:zaki-bot:user:42:cron:job-7");
    try std.testing.expectEqualStrings("42", id.user_id);
    try std.testing.expectEqual(SessionLane.cron, id.lane);
    try std.testing.expectEqualStrings("job-7", id.lane_id.?);
}

test "parse invalid prefix returns InvalidPrefix" {
    const result = parseSessionKey("totally-wrong:42:main");
    try std.testing.expectError(ParseError.InvalidPrefix, result);
}

test "parse empty user_id returns EmptyUserId" {
    const result = parseSessionKey("agent:zaki-bot:user::main");
    try std.testing.expectError(ParseError.EmptyUserId, result);
}

test "parse unknown lane returns InvalidLane" {
    const result = parseSessionKey("agent:zaki-bot:user:42:unknown");
    try std.testing.expectError(ParseError.InvalidLane, result);
}

test "parse thread without lane_id returns MissingLaneId" {
    const result = parseSessionKey("agent:zaki-bot:user:42:thread");
    try std.testing.expectError(ParseError.MissingLaneId, result);
}

test "parse thread with empty lane_id returns MissingLaneId" {
    const result = parseSessionKey("agent:zaki-bot:user:42:thread:");
    try std.testing.expectError(ParseError.MissingLaneId, result);
}

test "parse key longer than MAX_KEY_LEN returns KeyTooLong" {
    // Build a key with 256 characters
    var buf: [300]u8 = undefined;
    @memset(&buf, 'x');
    const prefix = "agent:zaki-bot:user:";
    @memcpy(buf[0..prefix.len], prefix);
    const key = buf[0 .. SessionIdentity.MAX_KEY_LEN + 1];
    const result = parseSessionKey(key);
    try std.testing.expectError(ParseError.KeyTooLong, result);
}

test "format main key matches expected string" {
    var buf: [256]u8 = undefined;
    const key = try formatSessionKey(&buf, "42", .main, null);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:main", key);
}

test "format thread key matches expected string" {
    var buf: [256]u8 = undefined;
    const key = try formatSessionKey(&buf, "42", .thread, "conv-2");
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:thread:conv-2", key);
}

test "isOwnedBy returns true for matching user" {
    try std.testing.expect(isOwnedBy("agent:zaki-bot:user:42:main", "42"));
    try std.testing.expect(isOwnedBy("agent:zaki-bot:user:42:thread:conv-1", "42"));
}

test "isOwnedBy returns false for non-matching user" {
    try std.testing.expect(!isOwnedBy("agent:zaki-bot:user:42:main", "99"));
    try std.testing.expect(!isOwnedBy("agent:zaki-bot:user:42:main", "4"));
    try std.testing.expect(!isOwnedBy("totally-wrong", "42"));
}

test "sameUser: same user matches across every lane pairing" {
    // main ↔ cron (the S1a wake lane), main ↔ thread, thread ↔ task.
    try std.testing.expect(sameUser("agent:zaki-bot:user:7:main", "agent:zaki-bot:user:7:cron:heartbeat"));
    try std.testing.expect(sameUser("agent:zaki-bot:user:7:main", "agent:zaki-bot:user:7:thread:conv-a"));
    try std.testing.expect(sameUser("agent:zaki-bot:user:7:thread:conv-a", "agent:zaki-bot:user:7:task:t-1"));
    // Identical keys trivially match.
    try std.testing.expect(sameUser("agent:zaki-bot:user:7:main", "agent:zaki-bot:user:7:main"));
}

test "sameUser: different users never match" {
    try std.testing.expect(!sameUser("agent:zaki-bot:user:7:main", "agent:zaki-bot:user:8:main"));
    // Same lane naming across users must not confuse the check.
    try std.testing.expect(!sameUser("agent:zaki-bot:user:7:cron:heartbeat", "agent:zaki-bot:user:8:cron:heartbeat"));
    // Prefix-shaped user ids must not match ("7" vs "77").
    try std.testing.expect(!sameUser("agent:zaki-bot:user:7:main", "agent:zaki-bot:user:77:main"));
}

test "sameUser: non-canonical keys fall back to exact equality (fail-closed)" {
    // Legacy/opaque keys: byte-identical → match, anything else → no match.
    try std.testing.expect(sameUser("session-1", "session-1"));
    try std.testing.expect(!sameUser("session-1", "session-2"));
    // Unparseable prefix, same-user-looking pair: NOT treated as same user.
    try std.testing.expect(!sameUser("agent:test:user:1:main", "agent:test:user:1:thread:x"));
    // Canonical vs non-canonical never match.
    try std.testing.expect(!sameUser("agent:zaki-bot:user:7:main", "session-1"));
    try std.testing.expect(!sameUser("session-1", "agent:zaki-bot:user:7:main"));
}

test "SessionLane fromSlice and toSlice round-trip all variants" {
    const lanes = [_]SessionLane{ .main, .thread, .task, .cron };
    for (lanes) |lane| {
        const str = lane.toSlice();
        const parsed = SessionLane.fromSlice(str);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(lane, parsed.?);
    }
    // Unknown string returns null
    try std.testing.expect(SessionLane.fromSlice("background") == null);
}
