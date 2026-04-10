//! Cooperative abort and cancellation signaling.
//!
//! CancellationToken provides an atomic boolean for lock-free cooperative
//! cancellation between threads. The HTTP handler or CLI can signal abort,
//! and the agent turn loop polls isCancelled() between iterations.
//!
//! Uses the same std.atomic.Value(bool) pattern established in
//! discord.zig/slack.zig for cooperative shutdown.

const std = @import("std");

pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Signal cancellation. Safe to call from any thread.
    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .release);
    }

    /// Check if cancellation has been requested. Safe to call from any thread.
    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.acquire);
    }

    /// Reset to non-cancelled state. Used for token reuse across turns.
    pub fn reset(self: *CancellationToken) void {
        self.cancelled.store(false, .release);
    }
};

pub const AbortReason = enum {
    user_request,
    timeout,
    error_limit,
    session_end,

    pub fn toSlice(self: AbortReason) []const u8 {
        return switch (self) {
            .user_request => "user_request",
            .timeout => "timeout",
            .error_limit => "error_limit",
            .session_end => "session_end",
        };
    }
};

pub const AbortEvent = struct {
    reason: AbortReason,
    iteration: u32 = 0,
    tool_in_progress: ?[]const u8 = null,
    timestamp_ms: i64 = 0,
};

// ── Tests ───────────────────────────────────────────────────────────

test "CancellationToken starts non-cancelled" {
    var token = CancellationToken{};
    try std.testing.expect(!token.isCancelled());
}

test "cancel sets cancelled state" {
    var token = CancellationToken{};
    token.cancel();
    try std.testing.expect(token.isCancelled());
}

test "reset clears cancelled state" {
    var token = CancellationToken{};
    token.cancel();
    try std.testing.expect(token.isCancelled());
    token.reset();
    try std.testing.expect(!token.isCancelled());
}

test "AbortReason toSlice returns string" {
    try std.testing.expectEqualStrings("user_request", AbortReason.user_request.toSlice());
    try std.testing.expectEqualStrings("timeout", AbortReason.timeout.toSlice());
    try std.testing.expectEqualStrings("error_limit", AbortReason.error_limit.toSlice());
    try std.testing.expectEqualStrings("session_end", AbortReason.session_end.toSlice());
}

test "AbortEvent captures context" {
    const event = AbortEvent{
        .reason = .user_request,
        .iteration = 5,
        .tool_in_progress = "shell",
        .timestamp_ms = 1234567890,
    };
    try std.testing.expectEqual(AbortReason.user_request, event.reason);
    try std.testing.expectEqual(@as(u32, 5), event.iteration);
    try std.testing.expectEqualStrings("shell", event.tool_in_progress.?);
}
