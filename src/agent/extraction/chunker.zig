//! V1.14.9 — Semantic episode chunker for boundary extraction.
//!
//! Replaces the V1.14.8 single-LLM-call-per-boundary pattern, which
//! degraded to entities=0 edges=0 on long sessions (293-msg windows
//! truncated to 80KB of fragments — no coherent narrative for the LLM
//! to extract).
//!
//! Industry pattern: Graphiti episodes, mem0 chunks, Zep auto-boundary.
//! Each "episode" is a coherent slice of the boundary window. The
//! runner fires one extraction LLM call per episode (fan-out, then
//! merge with coref dedup). Per-call input stays in the LLM's
//! coherence sweet spot (~3-5K tokens for Llama-3.3-70B-Turbo).
//!
//! Boundary signals, in priority order:
//!   1. Explicit `[SESSION BOUNDARY]` marker in message content
//!      (already emitted by compaction at session-stitching points)
//!   2. LoCoMo-style `Session N:` prefix at message start
//!      (bench artifact but harmless heuristic in production)
//!   3. Token-budget-full + clean turn boundary (assistant→user)
//!   4. Token-budget hard cap (fallback split mid-turn)
//!
//! Cost guard: max_episodes cap. When exceeded, keep first 5 + last
//! (cap-5) to preserve narrative arc (origin + recent context).
//!
//! Episodes are non-owning slices into the caller's window — caller
//! owns message content. Chunker only allocates the `[]Episode`
//! return slice.

const std = @import("std");
const log = std.log.scoped(.extraction_chunker);
const providers = @import("../../providers/root.zig");
const ChatMessage = providers.ChatMessage;

/// One coherent extraction unit. Held as a slice into the caller's
/// window — content is not copied.
pub const Episode = struct {
    /// Slice into the caller's `window` parameter.
    messages: []const ChatMessage,
    /// 4-chars-per-token rough estimate. Off by ±15%, sufficient for
    /// chunking. Matches StreamChunk.textDelta heuristic.
    estimated_tokens: u32,
    /// Why this episode boundary fired. Logged for telemetry; helps
    /// diagnose when episodes are too small/large.
    boundary_signal: BoundarySignal,
    /// Position in caller's window (telemetry only).
    start_idx: u32,
    end_idx: u32, // exclusive

    /// Why THIS episode began (not why it ended). The first episode
    /// in any chunking begins because the window started — every
    /// subsequent episode begins because a boundary signal fired on
    /// the previous flush.
    pub const BoundarySignal = enum {
        /// The first episode in the chunking. Window started here;
        /// no upstream trigger.
        window_start,
        /// Previous flush fired on a `[SESSION BOUNDARY]` marker in
        /// the message that begins THIS episode. Highest-priority
        /// signal. Emitted by Pass C summary stitching.
        explicit_marker,
        /// Previous flush fired on a `Session N:` prefix at message
        /// start — LoCoMo bench convention but also useful when
        /// users mark session changes ("Day 2 update: ..."). Strict
        /// regex on the starting message.
        locomo_session_prefix,
        /// Previous flush fired because the prior episode hit
        /// target_tokens AND we landed at a natural turn boundary
        /// (this msg is a new user turn after an assistant reply).
        /// Clean cut without splitting a user→assistant pair.
        turn_boundary_full,
        /// Previous flush fired because the prior episode would
        /// have exceeded max_episode_tokens if it absorbed this
        /// message. Cut may land mid-turn but prevents runaway
        /// episode sizes.
        token_budget_hard,
    };

    /// Token estimator used internally. Public so tests + callers can
    /// reuse the same heuristic.
    pub fn estimateTokens(content: []const u8) u32 {
        return @intCast((content.len + 3) / 4);
    }
};

/// Chunk a boundary window into semantic episodes.
///
/// `target_episode_tokens` — soft target for episode size. Chunker
///   tries to keep episodes near this size but won't split mid-turn
///   until `max_episode_tokens` is exceeded. 4000 = Llama-3.3-70B
///   coherence sweet spot per research report.
/// `max_episode_tokens` — hard cap. When current + next msg would
///   exceed, force a split even mid-turn. Usually 2× target.
/// `max_episodes` — cost guard. If chunker would emit more, sample
///   first 5 + last (max-5) and drop the middle. Logs a `warn` when
///   sampling fires.
///
/// Returns owned slice of Episode. Caller frees via
/// `allocator.free(result)` — episode contents are non-owning slices
/// into `window`, so caller MUST keep `window` alive for the
/// lifetime of the returned episodes.
pub fn chunkIntoEpisodes(
    allocator: std.mem.Allocator,
    window: []const ChatMessage,
    target_episode_tokens: u32,
    max_episode_tokens: u32,
    max_episodes: u32,
) ![]Episode {
    std.debug.assert(max_episode_tokens >= target_episode_tokens);
    std.debug.assert(max_episodes > 0);

    if (window.len == 0) {
        return try allocator.alloc(Episode, 0);
    }

    var episodes: std.ArrayListUnmanaged(Episode) = .empty;
    errdefer episodes.deinit(allocator);

    var current_start: u32 = 0;
    var current_tokens: u32 = 0;
    var current_signal: Episode.BoundarySignal = .window_start;
    var prev_role: ?providers.Role = null;

    for (window, 0..) |msg, i| {
        const idx: u32 = @intCast(i);
        const msg_tokens = Episode.estimateTokens(msg.content);

        // Detect boundary signals against the CURRENT msg (i.e., does
        // this msg begin a new episode?). Priority order matters.
        // Guard `current_start < idx` everywhere so we never emit a
        // zero-length episode (e.g., marker at msg index 0).
        const non_empty = current_start < idx;
        const explicit = hasExplicitMarker(msg) and non_empty;
        const locomo = matchesLocomoSessionPrefix(msg) and non_empty;
        const hard_cap = (current_tokens + msg_tokens > max_episode_tokens) and non_empty;
        const soft_turn = (current_tokens >= target_episode_tokens) and
            (msg.role == .user) and (prev_role == .assistant) and non_empty;

        if (explicit or locomo or hard_cap or soft_turn) {
            // Flush current episode with its existing begin-signal.
            try episodes.append(allocator, .{
                .messages = window[current_start..idx],
                .estimated_tokens = current_tokens,
                .boundary_signal = current_signal,
                .start_idx = current_start,
                .end_idx = idx,
            });
            // The signal that JUST fired becomes the new episode's
            // begin-signal. Priority matches the boolean order above.
            current_signal = if (explicit)
                .explicit_marker
            else if (locomo)
                .locomo_session_prefix
            else if (soft_turn)
                .turn_boundary_full
            else
                .token_budget_hard;
            current_start = idx;
            current_tokens = 0;
        }

        current_tokens += msg_tokens;
        prev_role = msg.role;
    }

    // Flush the tail with its begin-signal (preserved across the loop).
    if (current_start < window.len) {
        try episodes.append(allocator, .{
            .messages = window[current_start..],
            .estimated_tokens = current_tokens,
            .boundary_signal = current_signal,
            .start_idx = current_start,
            .end_idx = @intCast(window.len),
        });
    }

    // Cost guard: sample first 5 + last (max-5) if over cap.
    if (episodes.items.len > max_episodes) {
        const total = episodes.items.len;
        log.warn(
            "chunker.episodes_capped total={d} cap={d} sampling=first_5_plus_last_{d}",
            .{ total, max_episodes, max_episodes - 5 },
        );
        const keep_head: u32 = 5;
        const keep_tail: u32 = max_episodes - keep_head;
        const tail_start = total - keep_tail;

        var sampled: std.ArrayListUnmanaged(Episode) = .empty;
        errdefer sampled.deinit(allocator);
        try sampled.appendSlice(allocator, episodes.items[0..keep_head]);
        try sampled.appendSlice(allocator, episodes.items[tail_start..]);

        episodes.deinit(allocator);
        return try sampled.toOwnedSlice(allocator);
    }

    return try episodes.toOwnedSlice(allocator);
}

/// `[SESSION BOUNDARY]` marker check. Case-sensitive (we control the
/// emitter side). Anywhere in content because compaction may prepend
/// a `[Compaction summary]\n` header before the marker.
fn hasExplicitMarker(msg: ChatMessage) bool {
    return std.mem.indexOf(u8, msg.content, "[SESSION BOUNDARY]") != null;
}

/// LoCoMo `Session N:` prefix. Strict: must be at byte 0, must be
/// followed by a digit. Avoids over-matching content like "...My
/// favorite Session N video game is...".
fn matchesLocomoSessionPrefix(msg: ChatMessage) bool {
    if (msg.role != .user) return false;
    const prefix = "Session ";
    if (msg.content.len < prefix.len + 2) return false;
    if (!std.mem.startsWith(u8, msg.content, prefix)) return false;
    const after = msg.content[prefix.len..];
    // First non-space char must be a digit
    var i: usize = 0;
    while (i < after.len and after[i] == ' ') : (i += 1) {}
    if (i >= after.len) return false;
    return after[i] >= '0' and after[i] <= '9';
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "chunkIntoEpisodes empty window returns empty slice" {
    const allocator = std.testing.allocator;
    const window: []const ChatMessage = &.{};
    const episodes = try chunkIntoEpisodes(allocator, window, 4000, 8000, 20);
    defer allocator.free(episodes);
    try std.testing.expectEqual(@as(usize, 0), episodes.len);
}

test "chunkIntoEpisodes single small message returns single episode" {
    const allocator = std.testing.allocator;
    const window = [_]ChatMessage{
        .{ .role = .user, .content = "Hi" },
    };
    const episodes = try chunkIntoEpisodes(allocator, &window, 4000, 8000, 20);
    defer allocator.free(episodes);
    try std.testing.expectEqual(@as(usize, 1), episodes.len);
    // Single episode = first episode, no upstream trigger = window_start
    try std.testing.expectEqual(Episode.BoundarySignal.window_start, episodes[0].boundary_signal);
    try std.testing.expectEqual(@as(usize, 1), episodes[0].messages.len);
}

test "chunkIntoEpisodes splits on [SESSION BOUNDARY] marker" {
    const allocator = std.testing.allocator;
    const window = [_]ChatMessage{
        .{ .role = .user, .content = "First chunk content" },
        .{ .role = .assistant, .content = "ack" },
        .{ .role = .user, .content = "[SESSION BOUNDARY]\nSecond chunk begins" },
        .{ .role = .assistant, .content = "ack" },
    };
    const episodes = try chunkIntoEpisodes(allocator, &window, 4000, 8000, 20);
    defer allocator.free(episodes);
    try std.testing.expectEqual(@as(usize, 2), episodes.len);
    try std.testing.expectEqual(Episode.BoundarySignal.explicit_marker, episodes[1].boundary_signal);
    try std.testing.expectEqual(@as(usize, 2), episodes[0].messages.len);
    try std.testing.expectEqual(@as(usize, 2), episodes[1].messages.len);
}

test "chunkIntoEpisodes splits on LoCoMo Session N: prefix" {
    const allocator = std.testing.allocator;
    const window = [_]ChatMessage{
        .{ .role = .user, .content = "Session 1: Tim met John at the basketball court." },
        .{ .role = .assistant, .content = "noted" },
        .{ .role = .user, .content = "Session 2: Tim joined a fantasy forum." },
        .{ .role = .assistant, .content = "noted" },
        .{ .role = .user, .content = "Session 3: John signed a Nike deal." },
        .{ .role = .assistant, .content = "noted" },
    };
    const episodes = try chunkIntoEpisodes(allocator, &window, 4000, 8000, 20);
    defer allocator.free(episodes);
    try std.testing.expectEqual(@as(usize, 3), episodes.len);
    for (episodes[1..]) |ep| {
        try std.testing.expectEqual(Episode.BoundarySignal.locomo_session_prefix, ep.boundary_signal);
    }
}

test "matchesLocomoSessionPrefix does not match mid-content references" {
    try std.testing.expect(matchesLocomoSessionPrefix(.{ .role = .user, .content = "Session 1: real boundary" }));
    try std.testing.expect(!matchesLocomoSessionPrefix(.{ .role = .user, .content = "My Session 3 was great" }));
    try std.testing.expect(!matchesLocomoSessionPrefix(.{ .role = .user, .content = "Session without digit" }));
    try std.testing.expect(!matchesLocomoSessionPrefix(.{ .role = .assistant, .content = "Session 1: but assistant role" }));
}

test "chunkIntoEpisodes splits at turn_boundary_full when target tokens reached" {
    const allocator = std.testing.allocator;
    // Each user msg ~250 tokens (1000 chars), each assistant ~50.
    // target=300 tokens, so after a user→assistant pair (~300 tokens)
    // the next user msg should trigger turn_boundary_full.
    const big_content = "x" ** 1000;
    const window = [_]ChatMessage{
        .{ .role = .user, .content = big_content }, // 250 tok
        .{ .role = .assistant, .content = "ack" }, // 1 tok → cumulative ~251
        .{ .role = .user, .content = big_content }, // next user after assistant + over target → SPLIT
        .{ .role = .assistant, .content = "ack" },
    };
    const episodes = try chunkIntoEpisodes(allocator, &window, 200, 1000, 20);
    defer allocator.free(episodes);
    try std.testing.expectEqual(@as(usize, 2), episodes.len);
    try std.testing.expectEqual(Episode.BoundarySignal.turn_boundary_full, episodes[1].boundary_signal);
}

test "chunkIntoEpisodes hard cap splits mid-turn when budget exceeded" {
    const allocator = std.testing.allocator;
    const huge = "x" ** 4000; // 1000 tokens
    const window = [_]ChatMessage{
        .{ .role = .user, .content = huge },
        .{ .role = .user, .content = huge }, // adding this would exceed max 1500 → SPLIT
    };
    const episodes = try chunkIntoEpisodes(allocator, &window, 800, 1500, 20);
    defer allocator.free(episodes);
    try std.testing.expectEqual(@as(usize, 2), episodes.len);
    try std.testing.expectEqual(Episode.BoundarySignal.token_budget_hard, episodes[1].boundary_signal);
}

test "chunkIntoEpisodes max_episodes cap samples first 5 + last (max-5)" {
    const allocator = std.testing.allocator;
    // Create 30 messages, each with explicit marker → 30 episodes
    var messages: [30]ChatMessage = undefined;
    for (&messages, 0..) |*m, i| {
        m.* = .{
            .role = .user,
            .content = if (i == 0) "first" else "[SESSION BOUNDARY] msg",
        };
    }
    const episodes = try chunkIntoEpisodes(allocator, &messages, 4000, 8000, 10);
    defer allocator.free(episodes);
    // Cap = 10. Sample = first 5 + last 5.
    try std.testing.expectEqual(@as(usize, 10), episodes.len);
    // First episode is index 0 (head retained)
    try std.testing.expectEqual(@as(u32, 0), episodes[0].start_idx);
    // Last sampled episode ends at window end
    try std.testing.expectEqual(@as(u32, 30), episodes[9].end_idx);
}

test "chunkIntoEpisodes does not split when current episode is empty (avoids zero-size episodes)" {
    const allocator = std.testing.allocator;
    // First msg has the marker — should NOT cause an empty episode before it.
    const window = [_]ChatMessage{
        .{ .role = .user, .content = "[SESSION BOUNDARY] starts here" },
        .{ .role = .assistant, .content = "ack" },
    };
    const episodes = try chunkIntoEpisodes(allocator, &window, 4000, 8000, 20);
    defer allocator.free(episodes);
    try std.testing.expectEqual(@as(usize, 1), episodes.len);
    // Marker at index 0 is suppressed; first episode keeps window_start
    try std.testing.expectEqual(Episode.BoundarySignal.window_start, episodes[0].boundary_signal);
    try std.testing.expectEqual(@as(usize, 2), episodes[0].messages.len);
}

test "Episode.estimateTokens rounds up correctly" {
    try std.testing.expectEqual(@as(u32, 0), Episode.estimateTokens(""));
    try std.testing.expectEqual(@as(u32, 1), Episode.estimateTokens("a"));
    try std.testing.expectEqual(@as(u32, 1), Episode.estimateTokens("abcd"));
    try std.testing.expectEqual(@as(u32, 2), Episode.estimateTokens("abcde"));
    try std.testing.expectEqual(@as(u32, 25), Episode.estimateTokens("x" ** 100));
}
