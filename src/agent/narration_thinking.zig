//! Thinking narration sidecar — generates human-readable reasoning summaries
//! during multi-step agent tasks using a cheap LLM (Groq Llama 8B).
//!
//! Called every N tool iterations to explain what the agent figured out and
//! what it plans next. The output is emitted as a NarrationFrame with
//! frame_type = .thinking, displayed to the user as a thought bubble.
//!
//! Design principles:
//! - Cheap: uses sidecar model (free on Groq, $0.18/M on Together)
//! - Fast: ~500 tokens in, ~50 tokens out, ~100-200ms on Groq
//! - Non-blocking: failures are swallowed (narration is optional)
//! - Specific: mentions file names, tool names, concepts — not generic

const std = @import("std");
const providers = @import("../providers/root.zig");
const Provider = providers.Provider;
const ChatMessage = providers.ChatMessage;

const log = std.log.scoped(.agent);

/// A role+content pair for building narration prompts.
pub const MessageEntry = struct {
    role: []const u8,
    content: []const u8,
};

const NARRATION_SYSTEM_PROMPT =
    "You narrate an AI agent's work between tool calls. Write exactly one " ++
    "sentence in first person. Cover both halves: what you just learned from " ++
    "the last tool result, and what you're about to do next. Mention concrete " ++
    "things (file names, error messages, concepts) over generic phrasing. " ++
    "Do not name the tools themselves. No markdown. No filler phrases like " ++
    "'Let me' or 'I will now'. Under 30 words.";

/// Build a short summary of recent tool activity for the narration prompt.
/// Extracts tool name + first 200 chars of content from each message.
fn buildToolSummary(
    allocator: std.mem.Allocator,
    recent_messages: []const MessageEntry,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (recent_messages) |msg| {
        try buf.appendSlice(allocator, "[");
        try buf.appendSlice(allocator, msg.role);
        try buf.appendSlice(allocator, "] ");
        const preview = if (msg.content.len > 200) msg.content[0..200] else msg.content;
        try buf.appendSlice(allocator, preview);
        try buf.append(allocator, '\n');
    }

    return try buf.toOwnedSlice(allocator);
}

/// Generate a thinking narration from recent tool activity.
///
/// Returns an owned string with the narration text, or null if the sidecar
/// call fails (graceful degradation — narration is never a hard requirement).
pub fn generateThinkingNarration(
    allocator: std.mem.Allocator,
    sidecar_provider: Provider,
    sidecar_model: []const u8,
    history_items: []const @import("root.zig").Agent.OwnedMessage,
    history_len: usize,
    narration_interval: u32,
) ?[]const u8 {
    // Collect the last N*2 messages (tool pairs: assistant tool_call + tool result)
    const lookback = @min(history_len, narration_interval * 2 + 2);
    if (lookback < 2) return null;

    const start = history_len - lookback;

    // Build a compact summary of recent activity
    var entries: [16]MessageEntry = undefined;
    var entry_count: usize = 0;
    for (history_items[start..history_len]) |msg| {
        if (entry_count >= 16) break;
        const role_str: []const u8 = switch (msg.role) {
            .user => "user",
            .assistant => "assistant",
            .system => continue, // skip system messages
            .tool => "tool_result",
        };
        entries[entry_count] = .{ .role = role_str, .content = msg.content };
        entry_count += 1;
    }

    if (entry_count == 0) return null;

    const summary = buildToolSummary(allocator, entries[0..entry_count]) catch return null;
    defer allocator.free(summary);

    // Build the prompt
    const user_prompt = std.fmt.allocPrint(
        allocator,
        "Recent agent activity:\n\n{s}\n\nWhat did the agent figure out and what's the next step?",
        .{summary},
    ) catch return null;
    defer allocator.free(user_prompt);

    // Call the sidecar
    var messages: [2]ChatMessage = .{
        .{ .role = .system, .content = NARRATION_SYSTEM_PROMPT },
        .{ .role = .user, .content = user_prompt },
    };

    const response = sidecar_provider.chat(
        allocator,
        .{
            .messages = &messages,
            .model = sidecar_model,
            .temperature = 0.3,
            .max_tokens = 100,
            .timeout_secs = 5, // hard cap — narration must be fast
        },
        sidecar_model,
        0.3,
    ) catch |err| {
        log.warn("narration.sidecar_failed error={s} — skipping thinking narration", .{@errorName(err)});
        return null;
    };

    // Single defer for all response field cleanup (W1+W2 fix: no duplication,
    // includes tool_calls for defensive completeness).
    defer {
        if (response.content) |c| if (c.len > 0) allocator.free(c);
        if (response.model.len > 0) allocator.free(response.model);
        if (response.reasoning_content) |rc| if (rc.len > 0) allocator.free(rc);
        for (response.tool_calls) |tc| {
            if (tc.id.len > 0) allocator.free(tc.id);
            if (tc.name.len > 0) allocator.free(tc.name);
            if (tc.arguments.len > 0) allocator.free(tc.arguments);
        }
        if (response.tool_calls.len > 0) allocator.free(response.tool_calls);
    }

    const content = response.contentOrEmpty();
    if (content.len == 0) return null;

    return allocator.dupe(u8, content) catch null;
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "buildToolSummary formats entries correctly" {
    const allocator = std.testing.allocator;
    const entries = [_]MessageEntry{
        .{ .role = "assistant", .content = "I'll read the config file" },
        .{ .role = "tool_result", .content = "port = 8080\nhost = localhost" },
    };
    const summary = try buildToolSummary(allocator, &entries);
    defer allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "[assistant]") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "[tool_result]") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "port = 8080") != null);
}

test "buildToolSummary truncates long content" {
    const allocator = std.testing.allocator;
    const long_content = "x" ** 500;
    const entries = [_]MessageEntry{
        .{ .role = "tool_result", .content = long_content },
    };
    const summary = try buildToolSummary(allocator, &entries);
    defer allocator.free(summary);

    // Should be truncated to ~200 chars + role prefix + newline
    try std.testing.expect(summary.len < 250);
}
