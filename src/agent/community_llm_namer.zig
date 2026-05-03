//! V1.7-ship S1 — Concrete LlmNamer for community pipeline (V1.7a-9c).
//!
//! Wraps the existing `providers.Provider.chatWithSystem` API (already
//! tested + stable) into a `community_pipeline.LlmNamer` callback. The
//! pipeline calls this when a community needs naming (cache miss on
//! `member_set_hash`); we format the top-K member contents into a
//! prompt, ask the model for a short cluster name, and return the
//! cleaned result.
//!
//! ## Provider preference
//!
//! Use the SIDECAR provider/model when available (cheap-and-fast model
//! configured for narration / compaction / extraction — same place
//! we'd put any non-critical batch work). Falls back to the primary
//! provider when sidecar isn't configured.
//!
//! ## Cost shape
//!
//! Per-call cost: ~150 input tokens (system + members) + ~10 output
//! tokens (the name). Total recompute cost capped by
//! `RecomputeConfig.max_llm_calls` (default 50) so a worst-case
//! recompute is ~7.5K input + 500 output = sub-cent on cheap sidecars.
//!
//! ## Failure modes
//!
//! Provider error → returns the error to the pipeline → pipeline
//! falls back to "Cluster <id>" name. No retries (the pipeline already
//! caches the resulting fallback in member_set_hash so a transient
//! provider blip costs ONE recompute cycle of ugly names, not
//! recurring cost).

const std = @import("std");
const log = std.log.scoped(.community_llm_namer);

const providers = @import("../providers/root.zig");
const community_pipeline = @import("community_pipeline.zig");

/// Closure context carried by the LlmNamer callback. Holds borrowed
/// references to the provider + model name; both must outlive the
/// recomputeCommunitiesForUser call (which they do since they live on
/// the tenant runtime, not the request allocator).
pub const NamerCtx = struct {
    provider: providers.Provider,
    model: []const u8,
    temperature: f64 = 0.2, // low temperature → deterministic short names
};

/// Build an LlmNamer wrapping the given context. Caller owns ctx —
/// must keep it alive for the duration of the recomputeCommunitiesForUser
/// call. Typical usage: stack-allocate ctx in the handler, build namer
/// from it, pass namer + ctx pointer through the pipeline call, then
/// drop ctx when the handler returns.
pub fn make(ctx: *NamerCtx) community_pipeline.LlmNamer {
    return .{
        .ctx = @ptrCast(ctx),
        .name_fn = nameCommunity,
    };
}

/// Concrete name_fn implementation matching the LlmNamer signature.
/// Builds the prompt, calls the provider, cleans the response. Returns
/// owned slice (allocator-allocated) per the LlmNamer contract.
fn nameCommunity(
    raw_ctx: *anyopaque,
    members: []const community_pipeline.NamerMember,
    allocator: std.mem.Allocator,
) anyerror![]u8 {
    const ctx: *NamerCtx = @ptrCast(@alignCast(raw_ctx));

    // ── Build prompt ──────────────────────────────────────────────
    // System + user split: system tells the model HOW to respond;
    // user message contains the actual cluster members. Keeps the
    // system reusable + cheap to cache provider-side (when supported).
    const system_prompt =
        "You are naming a thematic cluster of facts from a person's memory. " ++
        "Given a small list of fact summaries, output a 2-5 word category " ++
        "name capturing what the cluster is about. Output ONLY the name " ++
        "(no quotes, no explanation, no period). " ++
        "Examples: 'Engineering work', 'Daily routines', 'Family', " ++
        "'Travel planning', 'Health and fitness', 'Work projects', " ++
        "'Personal preferences'.";

    var user_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer user_buf.deinit(allocator);
    const w = user_buf.writer(allocator);
    try w.writeAll("Cluster members (importance-ranked):\n");
    for (members, 0..) |m, i| {
        // Truncate each member content to 200 chars to keep prompt
        // bounded. Prepend index for the model's structure cue.
        const content = if (m.content.len > 200) m.content[0..200] else m.content;
        try w.print("{d}. {s}\n", .{ i + 1, content });
    }
    try w.writeAll("\nName this cluster:");

    // ── Call provider ─────────────────────────────────────────────
    const raw_name = ctx.provider.chatWithSystem(
        allocator,
        system_prompt,
        user_buf.items,
        ctx.model,
        ctx.temperature,
    ) catch |err| {
        log.warn("community_namer.provider_failed model={s} err={s}", .{ ctx.model, @errorName(err) });
        return err;
    };
    defer allocator.free(raw_name);

    // ── Clean the response ────────────────────────────────────────
    // Models sometimes add quotes, periods, "Cluster name:", etc.
    // Strip whitespace, surrounding quotes (single + double), and
    // trailing punctuation. Cap at 60 chars (ample for 2-5 words).
    const cleaned = try cleanName(allocator, raw_name);
    if (cleaned.len == 0) {
        allocator.free(cleaned);
        return error.EmptyNameAfterCleaning;
    }
    return cleaned;
}

/// Strip whitespace + surrounding quotes + trailing punctuation, cap
/// at 60 chars. Returns owned slice.
fn cleanName(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    // Drop wrapping quotes (single OR double)
    if (trimmed.len >= 2) {
        const first = trimmed[0];
        const last = trimmed[trimmed.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            trimmed = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
        }
    }
    // Drop trailing punctuation (`.`, `!`, `?`, `,`)
    while (trimmed.len > 0) {
        const last = trimmed[trimmed.len - 1];
        if (last == '.' or last == '!' or last == '?' or last == ',') {
            trimmed = trimmed[0 .. trimmed.len - 1];
            trimmed = std.mem.trim(u8, trimmed, " \t");
        } else break;
    }
    // Cap length (UTF-8-safe truncation: drop any partial codepoint at end)
    var capped_len: usize = @min(trimmed.len, 60);
    while (capped_len > 0 and (trimmed[capped_len - 1] & 0xC0) == 0x80) {
        capped_len -= 1;
    }
    if (capped_len > 0 and (trimmed[capped_len - 1] & 0x80) != 0 and (trimmed[capped_len - 1] & 0xC0) != 0xC0) {
        // Trailing partial multi-byte — drop the lead byte too
        if (capped_len > 0) capped_len -= 1;
    }
    return allocator.dupe(u8, trimmed[0..capped_len]);
}

// ── Tests ───────────────────────────────────────────────────────────

test "cleanName — strips quotes + trailing punctuation + whitespace" {
    const allocator = std.testing.allocator;

    const cases = [_]struct { raw: []const u8, expected: []const u8 }{
        .{ .raw = "Engineering work", .expected = "Engineering work" },
        .{ .raw = "  Engineering work  ", .expected = "Engineering work" },
        .{ .raw = "\"Engineering work\"", .expected = "Engineering work" },
        .{ .raw = "'Engineering work'", .expected = "Engineering work" },
        .{ .raw = "Engineering work.", .expected = "Engineering work" },
        .{ .raw = "Engineering work!", .expected = "Engineering work" },
        .{ .raw = "  \"Engineering work.\"  ", .expected = "Engineering work" },
        .{ .raw = "\nEngineering work\n", .expected = "Engineering work" },
    };
    for (cases) |c| {
        const out = try cleanName(allocator, c.raw);
        defer allocator.free(out);
        try std.testing.expectEqualStrings(c.expected, out);
    }
}

test "cleanName — caps at 60 chars, UTF-8 safe" {
    const allocator = std.testing.allocator;

    // Long ASCII → truncated at 60
    const long_ascii = "A" ** 100;
    const out_a = try cleanName(allocator, long_ascii);
    defer allocator.free(out_a);
    try std.testing.expectEqual(@as(usize, 60), out_a.len);

    // UTF-8 multi-byte: ensure we don't split a codepoint
    // "Engineering работа Engineering работа Engineering работа..." (Cyrillic
    // chars are 2 bytes each). Just verify the output is valid UTF-8 +
    // length ≤ 60.
    const long_utf8 = "Engineering работа Engineering работа Engineering работа Engineering";
    const out_u = try cleanName(allocator, long_utf8);
    defer allocator.free(out_u);
    try std.testing.expect(out_u.len <= 60);
    // Last byte must not be a UTF-8 lead byte (0b110xxxxx, 0b1110xxxx, 0b11110xxx)
    if (out_u.len > 0) {
        const last = out_u[out_u.len - 1];
        const is_ascii = (last & 0x80) == 0;
        const is_continuation = (last & 0xC0) == 0x80;
        // Either ASCII or a continuation byte at the end is fine
        // (continuation means we kept the whole codepoint).
        try std.testing.expect(is_ascii or is_continuation);
    }
}

test "cleanName — empty / whitespace-only input" {
    const allocator = std.testing.allocator;
    const out = try cleanName(allocator, "   \t\n  ");
    defer allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
