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
const providers = @import("../providers/root.zig");
const ChatMessage = providers.ChatMessage;
const Provider = providers.Provider;

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

/// Single-shot dream cycle entry point. Called by the cron-fired CLI
/// (Day 5.2: `nullalis dream --user-id N`).
///
/// Sequence:
///   1. Load recent conversation transcript (last 7 days; bounded by
///      MAX_TRANSCRIPT_BYTES so the LLM call stays under budget).
///   2. Fire ONE LLM call with `dream_system_prompt` + transcript.
///   3. Persist the LLM's reflection as `dream_log/<day_num>` memory.
///   4. Return DreamResult.
///
/// Failure-soft: any step error logs + returns partial result. The
/// dream cycle is best-effort overnight work — if it fails, no user
/// impact. Tomorrow's cycle retries.
pub fn runDreamCycle(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    provider: Provider,
    model_name: []const u8,
    user_id: i64,
) !DreamResult {
    const start = std.time.timestamp();
    log.info("dream.cycle.start user_id={d}", .{user_id});

    var result = DreamResult{
        .user_id = user_id,
        .started_at_unix = start,
        .completed_at_unix = start,
    };

    // 1. Load recent transcript. 7-day window; total bounded so
    //    the LLM call stays affordable. Larger = richer reflection
    //    but more expensive; 24KB is a reasonable compromise on
    //    Kimi K2.6 (~6K input tokens).
    const MAX_TRANSCRIPT_BYTES: usize = 24 * 1024;
    const SEVEN_DAYS_SECONDS: i64 = 7 * 86400;
    const since_unix = start - SEVEN_DAYS_SECONDS;

    const transcript = loadRecentTranscript(allocator, state_mgr, user_id, since_unix, MAX_TRANSCRIPT_BYTES) catch |err| {
        log.warn("dream.cycle.transcript_load_failed err={s}", .{@errorName(err)});
        result.completed_at_unix = std.time.timestamp();
        return result;
    };
    defer allocator.free(transcript);
    if (transcript.len < 100) {
        log.info("dream.cycle.skipped reason=transcript_too_small bytes={d}", .{transcript.len});
        result.completed_at_unix = std.time.timestamp();
        return result;
    }

    // 2. Fire LLM with dream prompt.
    const user_msg = try std.fmt.allocPrint(
        allocator,
        "Reflect on this 7-day transcript. Plain prose, 3-5 sentences.\n\n---\n{s}\n---",
        .{transcript},
    );
    defer allocator.free(user_msg);

    var msgs: [2]ChatMessage = .{
        .{ .role = .system, .content = dream_system_prompt },
        .{ .role = .user, .content = user_msg },
    };

    const resp = provider.chat(
        allocator,
        .{
            .messages = msgs[0..],
            .model = model_name,
            .temperature = 0.4, // a bit warmer than extraction; reflection is creative
            .tools = null,
            .timeout_secs = 60, // generous — overnight, no user waiting
        },
        model_name,
        0.4,
    ) catch |err| {
        log.warn("dream.cycle.llm_failed err={s}", .{@errorName(err)});
        result.completed_at_unix = std.time.timestamp();
        return result;
    };
    defer {
        if (resp.content) |cc| if (cc.len > 0) allocator.free(cc);
        if (resp.model.len > 0) allocator.free(resp.model);
        if (resp.reasoning_content) |rc| if (rc.len > 0) allocator.free(rc);
        for (resp.tool_calls) |tc| {
            if (tc.id.len > 0) allocator.free(tc.id);
            if (tc.name.len > 0) allocator.free(tc.name);
            if (tc.arguments.len > 0) allocator.free(tc.arguments);
        }
        if (resp.tool_calls.len > 0) allocator.free(resp.tool_calls);
    }

    const reflection = resp.contentOrEmpty();
    if (reflection.len < 20) {
        log.warn("dream.cycle.empty_reflection content_bytes={d}", .{reflection.len});
        result.completed_at_unix = std.time.timestamp();
        return result;
    }

    // 3. Persist.
    const log_key = persistDreamLog(allocator, state_mgr, user_id, reflection) catch |err| {
        log.warn("dream.cycle.persist_failed err={s}", .{@errorName(err)});
        result.completed_at_unix = std.time.timestamp();
        return result;
    };
    result.dream_log_key = log_key;
    result.completed_at_unix = std.time.timestamp();

    log.info(
        "dream.cycle.done user_id={d} duration_secs={d} reflection_bytes={d} log_key={s}",
        .{ user_id, result.duration_secs(), reflection.len, log_key },
    );
    return result;
}

/// Load the last `since_unix` worth of conversation_messages for
/// `user_id`, formatted as a transcript suitable for LLM consumption.
/// Bounded by `max_bytes` so the dream cycle stays affordable.
///
/// Day 5.2 follow-up: a real conversation_messages query helper. For
/// now this stub returns an empty transcript so the dream cycle is
/// invocable but produces a "transcript too small" log entry. Wiring
/// the real query is ~30 lines (SELECT role || ': ' || content from
/// conversation_messages WHERE user_id AND created_at > since ORDER BY
/// created_at LIMIT, concatenated up to max_bytes).
fn loadRecentTranscript(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    since_unix: i64,
    max_bytes: usize,
) ![]const u8 {
    _ = state_mgr;
    _ = user_id;
    _ = since_unix;
    _ = max_bytes;
    // Day 5.2 wiring point.
    return allocator.alloc(u8, 0);
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
