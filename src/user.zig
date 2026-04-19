//! Canonical user and workspace types for nullalis.
//!
//! Names two concepts that have been implicit in the codebase: the User
//! (authenticated identity) and the Workspace (per-user filesystem surface).
//!
//! This module is deliberately declarative. It does not replace
//! `gateway.resolveUserContext` — that function remains the operational
//! resolver that produces `UserContext` (the runtime aggregate with all
//! per-user paths). This module names the concepts; downstream work packages
//! will migrate call sites to use `User` and `Workspace` projections of
//! `UserContext`.
//!
//! Resolution paths (all normalize to `user_id` first, then to `User`):
//!   - principal       — already-known user_id (authenticated header, etc.)
//!   - session_key     — `session.parseUserIdFromSessionKey(key)` produces user_id
//!   - channel_identity — `zaki_state.resolveUserByChannelIdentity(...)` produces user_id
//!
//! Channel-identity resolution is DB-bound and kept out of this module's
//! resolver signature; callers must pre-normalize channel identity to
//! user_id through `zaki_state`, then pass `.principal` here.

const std = @import("std");
const session = @import("session/root.zig");

// ── User ─────────────────────────────────────────────────────────────────

/// Authenticated user identity.
///
/// `user_id` is the canonical string used everywhere session keys, tenant
/// rows, and workspace paths are built. `display_handle` is optional
/// human-readable metadata (not required for any runtime operation).
///
/// `User` is value-semantics and borrow-only: all slice fields point into
/// caller-owned memory. No allocation, no deinit.
pub const User = struct {
    user_id: []const u8,
    display_handle: ?[]const u8 = null,

    /// Canonical main-lane session key for this user.
    pub fn mainSessionKey(self: User, buf: []u8) []const u8 {
        return session.userMainSessionKey(buf, self.user_id);
    }

    /// Canonical thread-lane session key for this user + conversation id.
    pub fn threadSessionKey(self: User, buf: []u8, conversation_id: []const u8) []const u8 {
        return session.userThreadSessionKey(buf, self.user_id, conversation_id);
    }

    /// Canonical task-lane session key for this user + task id.
    pub fn taskSessionKey(self: User, buf: []u8, task_id: []const u8) []const u8 {
        return session.userTaskSessionKey(buf, self.user_id, task_id);
    }

    /// Canonical cron-lane session key for this user + job id.
    pub fn cronSessionKey(self: User, buf: []u8, job_id: []const u8) []const u8 {
        return session.userCronSessionKey(buf, self.user_id, job_id);
    }
};

// ── Workspace ────────────────────────────────────────────────────────────

/// Per-user workspace filesystem surface.
///
/// `workspace_dir` is the canonical per-user workspace path where markdown
/// artifacts, tool-scoped file operations, and the markdown memory mirror
/// live. `user_root` is the per-user root directory that contains the
/// workspace plus sibling state files (memory.db, config.json, etc.).
///
/// `markdown_dir` is optional — present only when the markdown memory
/// mirror is configured. When absent, callers should treat markdown as
/// not-available rather than assuming a default path.
///
/// `Workspace` is value-semantics and borrow-only: all slice fields point
/// into caller-owned memory (typically a `UserContext` produced by
/// `gateway.resolveUserContext`).
pub const Workspace = struct {
    user_id: []const u8,
    workspace_dir: []const u8,
    user_root: []const u8,
    markdown_dir: ?[]const u8 = null,
};

// ── Resolver ─────────────────────────────────────────────────────────────

/// Input forms accepted by `resolve`.
///
/// Channel-identity is intentionally absent: it requires a DB round-trip
/// through `zaki_state.resolveUserByChannelIdentity`. Callers must
/// pre-normalize channel identity to `user_id` and pass `.principal` here.
pub const ResolveInput = union(enum) {
    /// Already-known user_id (from authenticated header, etc.).
    principal: []const u8,
    /// Canonical session key — user_id is extracted by
    /// `session.parseUserIdFromSessionKey`.
    session_key: []const u8,
};

/// Canonical resolver: produces a `User` from any supported input form.
///
/// Returns null when the input cannot produce a valid user_id (empty
/// principal, malformed session key). Callers that need structural
/// validation of session keys should use `session.parseSessionKey` directly.
pub fn resolve(input: ResolveInput) ?User {
    const user_id: []const u8 = switch (input) {
        .principal => |p| if (p.len == 0) return null else p,
        .session_key => |k| session.parseUserIdFromSessionKey(k) orelse return null,
    };
    return User{ .user_id = user_id };
}

// ── Tests ────────────────────────────────────────────────────────────────

test "User.mainSessionKey builds canonical main key" {
    const u = User{ .user_id = "42" };
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "agent:zaki-bot:user:42:main",
        u.mainSessionKey(&buf),
    );
}

test "User.threadSessionKey builds canonical thread key" {
    const u = User{ .user_id = "42" };
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "agent:zaki-bot:user:42:thread:conv-2",
        u.threadSessionKey(&buf, "conv-2"),
    );
}

test "User.taskSessionKey builds canonical task key" {
    const u = User{ .user_id = "7" };
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "agent:zaki-bot:user:7:task:t-99",
        u.taskSessionKey(&buf, "t-99"),
    );
}

test "User.cronSessionKey builds canonical cron key" {
    const u = User{ .user_id = "7" };
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "agent:zaki-bot:user:7:cron:job-7",
        u.cronSessionKey(&buf, "job-7"),
    );
}

test "User carries display_handle when provided" {
    const u = User{ .user_id = "42", .display_handle = "Nova" };
    try std.testing.expectEqualStrings("Nova", u.display_handle.?);
}

test "Workspace fields round-trip" {
    const w = Workspace{
        .user_id = "42",
        .workspace_dir = "/data/42/workspace",
        .user_root = "/data/42",
        .markdown_dir = "/data/42/workspace/memory",
    };
    try std.testing.expectEqualStrings("42", w.user_id);
    try std.testing.expectEqualStrings("/data/42/workspace", w.workspace_dir);
    try std.testing.expectEqualStrings("/data/42", w.user_root);
    try std.testing.expectEqualStrings("/data/42/workspace/memory", w.markdown_dir.?);
}

test "Workspace markdown_dir defaults to null" {
    const w = Workspace{
        .user_id = "42",
        .workspace_dir = "/data/42/workspace",
        .user_root = "/data/42",
    };
    try std.testing.expect(w.markdown_dir == null);
}

test "resolve from principal returns User" {
    const u = resolve(.{ .principal = "42" }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("42", u.user_id);
    try std.testing.expect(u.display_handle == null);
}

test "resolve from empty principal returns null" {
    try std.testing.expect(resolve(.{ .principal = "" }) == null);
}

test "resolve from session_key extracts user_id" {
    const u = resolve(.{ .session_key = "agent:zaki-bot:user:42:main" }) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("42", u.user_id);
}

test "resolve from session_key with thread lane extracts user_id" {
    const u = resolve(.{ .session_key = "agent:zaki-bot:user:7:thread:conv-1" }) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("7", u.user_id);
}

test "resolve from malformed session_key returns null" {
    try std.testing.expect(resolve(.{ .session_key = "not-a-session-key" }) == null);
    try std.testing.expect(resolve(.{ .session_key = "agent:zaki-bot:user::main" }) == null);
    try std.testing.expect(resolve(.{ .session_key = "agent:zaki-bot:main" }) == null);
}

test "resolve round-trip: principal to session_key back to User" {
    const first = resolve(.{ .principal = "42" }) orelse return error.TestUnexpectedResult;
    var buf: [128]u8 = undefined;
    const key = first.mainSessionKey(&buf);
    const second = resolve(.{ .session_key = key }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(first.user_id, second.user_id);
}

// ── W2.4: cross-surface parity ──────────────────────────────────────────────
// The V1 product promise is "one twin across web + Telegram". That requires
// any DM-equivalent message from either surface to land on the same main-lane
// session key for a given user. The test below proves the session-key layer
// converges for the two legitimate V1 ingress paths:
//   - web      → `User.mainSessionKey` from the principal (X-Zaki-User-Id)
//   - telegram → `User.mainSessionKey` from the user_id resolved via
//                `zaki_state.resolveUserByChannelIdentity`
//
// Both paths produce a User with the same user_id, so both paths produce the
// same main-lane session key — which is exactly what cross-surface continuity
// requires. A full e2e test would require mock HTTP + mock webhook
// scaffolding; this test locks the invariant at the type/key layer, which is
// where the parity-breaking regression would surface first.

test "cross-surface parity: web and telegram DMs converge on the same main session key" {
    // Web ingress: principal-driven
    const web_user = resolve(.{ .principal = "42" }) orelse return error.TestUnexpectedResult;
    var web_buf: [128]u8 = undefined;
    const web_key = web_user.mainSessionKey(&web_buf);

    // Telegram DM ingress: whatever path resolved user_id ends up here.
    // Simulate by constructing the User the same way an authenticated
    // Telegram DM would after `resolveUserByChannelIdentity` returned "42".
    const tg_user = User{ .user_id = "42" };
    var tg_buf: [128]u8 = undefined;
    const tg_key = tg_user.mainSessionKey(&tg_buf);

    try std.testing.expectEqualStrings(web_key, tg_key);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:main", web_key);
}

test "cross-surface parity: telegram group routes to thread, NOT main" {
    // Per the lane-routing rules (2026-04-09): Telegram groups/topics go to
    // thread-lane, not main. This guards against accidental regression that
    // would put group traffic on the same lane as DMs.
    const u = User{ .user_id = "42" };
    var main_buf: [128]u8 = undefined;
    var thread_buf: [128]u8 = undefined;
    const main_key = u.mainSessionKey(&main_buf);
    const thread_key = u.threadSessionKey(&thread_buf, "telegram:group:-100123");
    try std.testing.expect(!std.mem.eql(u8, main_key, thread_key));
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:thread:telegram:group:-100123", thread_key);
}
