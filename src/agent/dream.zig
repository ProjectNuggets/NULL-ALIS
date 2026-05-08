//! V1.13 Day 5 — Dream cycle (minimal shape).
//!
//! What this is: ONE LLM call fired by cron, that reads recent
//! conversation_messages, finds patterns, and persists a
//! `dream_log/<date>` memory. That's it.
//!
//! What this is NOT: a multi-step orchestrator with hygiene + importance
//! + WM-pre-populate phases. Those are separate concerns:
//!   - Brain hygiene → its own cron entry calling a hygiene CLI
//!   - Importance recompute → already happens on /brain render time
//!   - Working memory pre-populate → not actually needed; the next
//!     session populates WM organically via auto-promotion
//!
//! Trigger:
//!   ~/.nullalis/cron.json:
//!     {
//!       "id": "dream_3am_user_1",
//!       "user_id": 1,
//!       "schedule": "0 3 * * *",
//!       "kind": "command",
//!       "command": "nullalis dream --user-id 1",
//!       "enabled": true
//!     }
//!
//! Day 5.2 wires the CLI command + the LLM-driven body. Day 5.1
//! (this file) is the minimal callable function shape that fits in
//! one prompt + one persist op.

const std = @import("std");
const log = std.log.scoped(.dream);

const memory_root = @import("../memory/root.zig");
const zaki_state = @import("../zaki_state.zig");

/// V1.13 Day 5 dream prompt. Single call. Compose a reflection
/// from the user's recent activity.
///
/// Day 5.2 fills the `{transcript}` placeholder with the last 7 days
/// of conversation_messages and fires this against the same provider
/// the chat path uses.
pub const dream_system_prompt =
    \\You are reflecting overnight on the user's recent activity. The
    \\transcript below is the last 7 days of conversation. Your job:
    \\
    \\1. Identify 3-5 recurring themes — what does the user keep
    \\   coming back to? (work, decisions, relationships, struggles)
    \\
    \\2. Note 2-3 things that surprised you — patterns the user may
    \\   not have noticed about themselves.
    \\
    \\3. Identify 1-2 questions worth asking next time you talk —
    \\   gaps in your knowledge that would help you serve them better.
    \\
    \\4. Compose a short reflection (3-5 sentences) — what you think
    \\   the user's week was about, in your voice.
    \\
    \\Output as plain prose. No JSON, no headers, no preamble. Just the
    \\reflection. The user reads this in /brain as today's dream log.
    \\Be warm but observational; you are not the user, you observed
    \\the user. Multilingual: write in the dominant language of the
    \\transcript.
;

/// Dream-cycle result for observability.
pub const DreamResult = struct {
    user_id: i64,
    started_at_unix: i64,
    completed_at_unix: i64,
    dream_log_key: []const u8 = "",

    pub fn duration_secs(self: *const DreamResult) i64 {
        return self.completed_at_unix - self.started_at_unix;
    }
};

/// Persist a dream_log entry. Called from the LLM-driven body
/// (Day 5.2 will pass the LLM-composed reflection as `body`). Caller
/// frees the returned key.
pub fn persistDreamLog(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    body: []const u8,
) ![]u8 {
    const ts = std.time.timestamp();
    const day_num = @divFloor(ts, 86400);
    const key = try std.fmt.allocPrint(allocator, "dream_log/{d}", .{day_num});
    errdefer allocator.free(key);

    const content = try std.fmt.allocPrint(
        allocator,
        "type=dream_log\nat_unix={d}\nday_num={d}\n\n{s}\n",
        .{ ts, day_num, body },
    );
    defer allocator.free(content);

    state_mgr.upsertMemory(user_id, key, content, .daily, null) catch |err| {
        log.warn("dream.log.upsert_failed err={s}", .{@errorName(err)});
        return err;
    };
    log.info("dream.log.persisted key={s} body_bytes={d}", .{ key, body.len });
    return key;
}

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

test "DreamResult.duration_secs" {
    const r = DreamResult{
        .user_id = 1,
        .started_at_unix = 1_700_000_000,
        .completed_at_unix = 1_700_000_120,
    };
    try std.testing.expectEqual(@as(i64, 120), r.duration_secs());
}

test "dream_system_prompt is non-empty" {
    try std.testing.expect(dream_system_prompt.len > 100);
}
