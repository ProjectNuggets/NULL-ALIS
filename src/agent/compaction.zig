//! History compaction — token estimation, auto-compaction, force-compression, trimming.
//!
//! Extracted from agent/root.zig. All functions operate on history slices
//! passed by the caller; no dependency on the Agent struct.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.agent);
const providers = @import("../providers/root.zig");
const config_types = @import("../config_types.zig");
const Provider = providers.Provider;
const ChatMessage = providers.ChatMessage;

const Agent = @import("root.zig").Agent;
const OwnedMessage = Agent.OwnedMessage;

// ═══════════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════════

/// Default: keep this many most-recent non-system messages after compaction.
pub const DEFAULT_COMPACTION_KEEP_RECENT: u32 = 20;

/// Default: max characters retained in stored compaction summary.
pub const DEFAULT_COMPACTION_MAX_SUMMARY_CHARS: u32 = 2_000;
/// Maximum characters appended from workspace critical rules.
const MAX_WORKSPACE_CONTEXT_CHARS: usize = 2_000;
/// Maximum AGENTS.md bytes read for critical rules extraction.
const MAX_AGENTS_FILE_BYTES: usize = 2 * 1024 * 1024;

/// Default: max characters in source transcript passed to the summarizer.
pub const DEFAULT_COMPACTION_MAX_SOURCE_CHARS: u32 = 12_000;

/// Default token limit for context window (used by token-based compaction trigger).
pub const DEFAULT_TOKEN_LIMIT: u64 = config_types.DEFAULT_AGENT_TOKEN_LIMIT;

pub const TrimStats = struct {
    history_before: usize = 0,
    history_after: usize = 0,
    removed_messages: usize = 0,
    removed_bytes: usize = 0,
    shrunk_capacity: bool = false,
};

/// Minimum history length before context exhaustion recovery is attempted.
pub const CONTEXT_RECOVERY_MIN_HISTORY: usize = 6;

/// Number of recent messages to keep during force compression.
pub const CONTEXT_RECOVERY_KEEP: usize = 4;

// ═══════════════════════════════════════════════════════════════════════════
// Config
// ═══════════════════════════════════════════════════════════════════════════

pub const CompactionConfig = struct {
    keep_recent: u32 = DEFAULT_COMPACTION_KEEP_RECENT,
    max_summary_chars: u32 = DEFAULT_COMPACTION_MAX_SUMMARY_CHARS,
    max_source_chars: u32 = DEFAULT_COMPACTION_MAX_SOURCE_CHARS,
    token_limit: u64 = DEFAULT_TOKEN_LIMIT,
    max_tokens: u32 = 0,
    message_timeout_secs: u64 = 0,
    max_history_messages: u32 = 50,
    workspace_dir: ?[]const u8 = null,
};

pub const TokenBudgetPolicy = struct {
    reply_reserve: u64,
    tool_reserve: u64,
    safety_reserve: u64,
    total_reserve: u64,
    threshold: u64,
};

pub fn buildTokenBudgetPolicy(token_limit: u64, max_tokens: u32) TokenBudgetPolicy {
    if (token_limit == 0) {
        return .{
            .reply_reserve = 0,
            .tool_reserve = 0,
            .safety_reserve = 0,
            .total_reserve = 0,
            .threshold = 0,
        };
    }

    const reply_reserve = if (max_tokens > 0) @as(u64, max_tokens) else @as(u64, 8_192);
    const tool_reserve = @max(@as(u64, 2_048), @min(token_limit / 8, @as(u64, 16_384)));
    const safety_reserve = @max(@as(u64, 1_024), @min(token_limit / 20, @as(u64, 8_192)));
    const total_reserve = reply_reserve + tool_reserve + safety_reserve;
    const threshold_from_reserve = if (token_limit > total_reserve) token_limit - total_reserve else token_limit / 2;
    const minimum_threshold = (token_limit * 65) / 100;
    return .{
        .reply_reserve = reply_reserve,
        .tool_reserve = tool_reserve,
        .safety_reserve = safety_reserve,
        .total_reserve = total_reserve,
        .threshold = @max(minimum_threshold, threshold_from_reserve),
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// Public functions
// ═══════════════════════════════════════════════════════════════════════════

/// Estimate total tokens in conversation history using heuristic: (total_chars + 3) / 4.
pub fn tokenEstimate(history: []const OwnedMessage) u64 {
    var total_chars: u64 = 0;
    for (history) |*msg| {
        total_chars += msg.content.len;
    }
    return (total_chars + 3) / 4;
}

/// Auto-compact history when it exceeds max_history_messages or when
/// estimated token usage exceeds the dynamic reserve-aware token threshold.
/// For large histories (>10 messages to summarize), uses multi-part strategy:
/// splits into halves, summarizes each independently, then merges.
/// Returns true if compaction was performed.
pub fn autoCompactHistory(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    provider: Provider,
    model_name: []const u8,
    config: CompactionConfig,
) !bool {
    const has_system = history.items.len > 0 and history.items[0].role == .system;
    const start: usize = if (has_system) 1 else 0;
    _ = history.items.len - start;

    // Trigger when estimated tokens exceed the usable window after reserving
    // reply/tool/safety headroom for the current model.
    const budget_policy = buildTokenBudgetPolicy(config.token_limit, config.max_tokens);
    const token_threshold = budget_policy.threshold;
    const token_trigger = config.token_limit > 0 and tokenEstimate(history.items) > token_threshold;

    // Automatic compaction is reserved for true context pressure only.
    // Session-boundary continuity is handled by explicit checkpoint paths
    // such as /new, reset, eviction, or the durable seed writer.
    if (!token_trigger) return false;

    return compactHistoryKeepingRecent(allocator, history, provider, model_name, config, config.keep_recent);
}

/// Manual compaction for explicit operator boundaries.
/// Summarizes older context and keeps the most recent recovery tail intact.
pub fn manualCompactHistory(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    provider: Provider,
    model_name: []const u8,
    config: CompactionConfig,
) !bool {
    return compactHistoryKeepingRecent(allocator, history, provider, model_name, config, CONTEXT_RECOVERY_KEEP);
}

fn compactHistoryKeepingRecent(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    provider: Provider,
    model_name: []const u8,
    config: CompactionConfig,
    requested_keep_recent: usize,
) !bool {
    const has_system = history.items.len > 0 and history.items[0].role == .system;
    const start: usize = if (has_system) 1 else 0;
    const non_system_count = history.items.len - start;

    const keep_recent: usize = @min(non_system_count, requested_keep_recent);
    const compact_count = non_system_count - keep_recent;
    if (compact_count == 0) return false;

    const compact_end = start + compact_count;

    // Multi-part strategy: if >10 messages to summarize, split into halves
    const summary = if (compact_count > 10) blk: {
        const mid = start + compact_count / 2;

        // Summarize first half
        const summary_a = try summarizeSlice(allocator, provider, model_name, history.items, start, mid, config);
        defer allocator.free(summary_a);

        // Summarize second half
        const summary_b = try summarizeSlice(allocator, provider, model_name, history.items, mid, compact_end, config);
        defer allocator.free(summary_b);

        // Merge the two summaries
        const merged = try std.fmt.allocPrint(
            allocator,
            "Earlier context:\n{s}\n\nMore recent context:\n{s}",
            .{ summary_a, summary_b },
        );

        // Truncate if too long
        if (merged.len > config.max_summary_chars) {
            const truncated = try allocator.dupe(u8, merged[0..config.max_summary_chars]);
            allocator.free(merged);
            break :blk truncated;
        }

        break :blk merged;
    } else try summarizeSlice(allocator, provider, model_name, history.items, start, compact_end, config);
    defer allocator.free(summary);

    const workspace_context = try readWorkspaceContextForSummary(allocator, config.workspace_dir);
    defer allocator.free(workspace_context);

    const summary_with_context = if (workspace_context.len > 0)
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ summary, workspace_context })
    else
        try allocator.dupe(u8, summary);
    defer allocator.free(summary_with_context);

    // Create the compaction summary message
    const summary_content = try std.fmt.allocPrint(allocator, "[Compaction summary]\n{s}", .{summary_with_context});

    // Free old messages being compacted
    for (history.items[start..compact_end]) |*msg| {
        msg.deinit(allocator);
    }

    // Replace compacted messages with summary
    history.items[start] = .{
        .role = .assistant,
        .content = summary_content,
    };

    // Shift remaining messages
    if (compact_end > start + 1) {
        const src = history.items[compact_end..];
        std.mem.copyForwards(OwnedMessage, history.items[start + 1 ..], src);
        history.items.len -= (compact_end - start - 1);
    }

    return true;
}

/// Force-compress history for context exhaustion recovery.
/// Keeps system prompt (if any) + last CONTEXT_RECOVERY_KEEP messages.
/// Everything in between is dropped without LLM summarization (we can't call
/// the LLM since the context is exhausted). Returns true if compression was performed.
///
/// NOTE: This is a lossy hard-drop. Callers MUST surface this to the user so
/// they are aware context continuity has been interrupted.
/// Maximum characters saved in a compaction archive entry.
const MAX_ARCHIVE_CHARS: usize = 6_000;

pub fn forceCompressHistory(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
) bool {
    return forceCompressHistoryWithArchive(allocator, history, null, null);
}

/// Force-compress history, optionally archiving dropped messages to memory.
/// When mem and session_id are provided, dropped messages are saved as a
/// compaction_archive/* entry before deletion — preventing silent context loss.
pub fn forceCompressHistoryWithArchive(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    mem: ?@import("../memory/root.zig").Memory,
    session_id: ?[]const u8,
) bool {
    const has_system = history.items.len > 0 and history.items[0].role == .system;
    const start: usize = if (has_system) 1 else 0;
    const non_system_count = history.items.len - start;

    if (non_system_count <= CONTEXT_RECOVERY_KEEP) return false;

    const keep_start = history.items.len - CONTEXT_RECOVERY_KEEP;
    const to_remove = keep_start - start;

    log.warn("compaction: force-compressing history — dropping {} messages (context exhausted, LLM unavailable)", .{to_remove});

    // Archive dropped messages to memory before deletion (best-effort)
    if (mem) |m| {
        archiveDroppedMessages(allocator, m, session_id, history.items[start..keep_start], to_remove);
    }

    // Free messages being removed
    for (history.items[start..keep_start]) |*msg| {
        msg.deinit(allocator);
    }

    // Shift remaining elements
    const src = history.items[keep_start..];
    std.mem.copyForwards(OwnedMessage, history.items[start..], src);
    history.items.len -= to_remove;

    return true;
}

/// Best-effort archive of messages about to be dropped.
fn archiveDroppedMessages(
    allocator: std.mem.Allocator,
    mem: @import("../memory/root.zig").Memory,
    session_id: ?[]const u8,
    messages: []const OwnedMessage,
    count: usize,
) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    std.fmt.format(w, "type=compaction_archive\nmessages_dropped={d}\nreason=context_exhaustion\n\n", .{count}) catch return;

    for (messages) |msg| {
        if (buf.items.len >= MAX_ARCHIVE_CHARS) {
            w.writeAll("\n[... remaining messages truncated ...]\n") catch {};
            break;
        }
        const role_str: []const u8 = switch (msg.role) {
            .user => "user",
            .assistant => "assistant",
            .system => "system",
            .tool => "tool",
        };
        std.fmt.format(w, "[{s}] {s}\n\n", .{
            role_str,
            if (msg.content.len > 500) msg.content[0..500] else msg.content,
        }) catch break;
    }

    const ts: u128 = @bitCast(std.time.nanoTimestamp());
    const key = std.fmt.allocPrint(allocator, "compaction_archive/{d}", .{ts}) catch return;
    defer allocator.free(key);

    mem.store(key, buf.items, .conversation, session_id) catch |err| {
        log.warn("compaction: failed to archive dropped messages: {}", .{err});
    };
}

/// Trim history to prevent unbounded growth.
/// Preserves the system prompt (first message) and the most recent messages.
pub fn trimHistoryDetailed(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    max_history_messages: u32,
) TrimStats {
    var stats = TrimStats{
        .history_before = history.items.len,
        .history_after = history.items.len,
    };

    const max = max_history_messages;
    if (history.items.len <= max + 1) return stats; // +1 for system prompt

    const has_system = history.items.len > 0 and history.items[0].role == .system;
    const start: usize = if (has_system) 1 else 0;
    const non_system_count = history.items.len - start;

    if (non_system_count <= max) return stats;

    const to_remove = non_system_count - max;
    stats.removed_messages = to_remove;

    // Free the messages being removed
    for (history.items[start .. start + to_remove]) |*msg| {
        stats.removed_bytes += msg.content.len;
        msg.deinit(allocator);
    }

    // Shift remaining elements
    const src = history.items[start + to_remove ..];
    std.mem.copyForwards(OwnedMessage, history.items[start..], src);
    history.items.len -= to_remove;
    stats.history_after = history.items.len;

    // Shrink backing array if capacity is much larger than needed
    if (history.capacity > history.items.len * 2 + 8) {
        history.shrinkAndFree(allocator, history.items.len);
        stats.shrunk_capacity = true;
    }

    return stats;
}

/// Trim history to prevent unbounded growth.
/// Preserves the system prompt (first message) and the most recent messages.
pub fn trimHistory(
    allocator: std.mem.Allocator,
    history: *std.ArrayListUnmanaged(OwnedMessage),
    max_history_messages: u32,
) void {
    _ = trimHistoryDetailed(allocator, history, max_history_messages);
}

test "trimHistoryDetailed reports removed messages and bytes" {
    const allocator = std.testing.allocator;
    var history: std.ArrayListUnmanaged(OwnedMessage) = .empty;
    defer {
        for (history.items) |*msg| msg.deinit(allocator);
        history.deinit(allocator);
    }

    try history.append(allocator, .{ .role = .system, .content = try allocator.dupe(u8, "sys") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u1") });
    try history.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "assistant-one") });
    try history.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "u2") });

    const stats = trimHistoryDetailed(allocator, &history, 2);
    try std.testing.expectEqual(@as(usize, 4), stats.history_before);
    try std.testing.expectEqual(@as(usize, 3), stats.history_after);
    try std.testing.expectEqual(@as(usize, 1), stats.removed_messages);
    try std.testing.expectEqual(@as(usize, 2), stats.removed_bytes);
    try std.testing.expectEqual(@as(usize, 3), history.items.len);
    try std.testing.expectEqualStrings("assistant-one", history.items[1].content);
    try std.testing.expectEqualStrings("u2", history.items[2].content);
}

test "buildTokenBudgetPolicy keeps dynamic headroom" {
    const kimi = buildTokenBudgetPolicy(262_144, 32_768);
    try std.testing.expectEqual(@as(u64, 32_768), kimi.reply_reserve);
    try std.testing.expectEqual(@as(u64, 16_384), kimi.tool_reserve);
    try std.testing.expectEqual(@as(u64, 8_192), kimi.safety_reserve);
    try std.testing.expectEqual(@as(u64, 57_344), kimi.total_reserve);
    try std.testing.expectEqual(@as(u64, 204_800), kimi.threshold);

    const smaller = buildTokenBudgetPolicy(32_768, 8_192);
    try std.testing.expect(smaller.threshold >= (32_768 * 65) / 100);
}

// ═══════════════════════════════════════════════════════════════════════════
// Internal helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Build a compaction transcript from a slice of history messages.
fn buildCompactionTranscript(
    allocator: std.mem.Allocator,
    history_items: []const OwnedMessage,
    start: usize,
    end: usize,
    max_source_chars: u32,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (history_items[start..end]) |*msg| {
        const role_str: []const u8 = switch (msg.role) {
            .system => "SYSTEM",
            .user => "USER",
            .assistant => "ASSISTANT",
            .tool => "TOOL",
        };
        try buf.appendSlice(allocator, role_str);
        try buf.appendSlice(allocator, ": ");
        // Truncate very long messages in transcript
        const content = if (msg.content.len > 500) msg.content[0..500] else msg.content;
        try buf.appendSlice(allocator, content);
        try buf.append(allocator, '\n');

        // Safety cap
        if (buf.items.len > max_source_chars) break;
    }

    if (buf.items.len > max_source_chars) {
        buf.items.len = max_source_chars;
    }

    return buf.toOwnedSlice(allocator);
}

/// Summarize a slice of history messages via the LLM provider.
/// Returns an owned summary string. Falls back to transcript truncation on error.
fn summarizeSlice(
    allocator: std.mem.Allocator,
    provider: Provider,
    model_name: []const u8,
    history_items: []const OwnedMessage,
    start: usize,
    end: usize,
    config: CompactionConfig,
) ![]u8 {
    const transcript = try buildCompactionTranscript(allocator, history_items, start, end, config.max_source_chars);
    defer allocator.free(transcript);

    const summarizer_system = "You are a conversation compaction engine. Summarize older chat history into concise context for future turns. Preserve: user preferences, commitments, decisions, unresolved tasks, key facts. Omit: filler, repeated chit-chat, verbose tool logs. Output plain text bullet points only.";
    const summarizer_user = try std.fmt.allocPrint(allocator, "Summarize the following conversation history for context preservation. Keep it short (max 12 bullet points).\n\n{s}", .{transcript});
    defer allocator.free(summarizer_user);

    var summary_messages: [2]ChatMessage = .{
        .{ .role = .system, .content = summarizer_system },
        .{ .role = .user, .content = summarizer_user },
    };

    const messages_slice = summary_messages[0..2];

    const summary_resp = provider.chat(
        allocator,
        .{
            .messages = messages_slice,
            .model = model_name,
            .temperature = 0.2,
            .tools = null,
            .timeout_secs = config.message_timeout_secs,
        },
        model_name,
        0.2,
    ) catch |err| {
        // LLM summarization failed — fall back to a hard truncation of the raw
        // transcript. Log this clearly: the caller will surface it to the user so
        // they know context continuity may be degraded.
        log.warn("compaction: LLM summarization failed ({}), falling back to transcript truncation — context continuity may be degraded", .{err});
        const max_len = @min(transcript.len, config.max_summary_chars);
        return try allocator.dupe(u8, transcript[0..max_len]);
    };
    // Free response's heap-allocated fields after extracting what we need
    defer {
        if (summary_resp.content) |c| {
            if (c.len > 0) allocator.free(c);
        }
        if (summary_resp.model.len > 0) allocator.free(summary_resp.model);
        if (summary_resp.reasoning_content) |rc| {
            if (rc.len > 0) allocator.free(rc);
        }
    }

    const raw_summary = summary_resp.contentOrEmpty();
    const max_len = @min(raw_summary.len, config.max_summary_chars);
    return try allocator.dupe(u8, raw_summary[0..max_len]);
}

const HeadingInfo = struct {
    level: u8,
    text: []const u8,
};

fn parseHeadingLine(line: []const u8) ?HeadingInfo {
    const trimmed_left = std.mem.trimLeft(u8, line, " \t");
    if (trimmed_left.len < 4) return null;

    var level: u8 = 0;
    var idx: usize = 0;
    while (idx < trimmed_left.len and trimmed_left[idx] == '#') : (idx += 1) {
        level += 1;
    }
    if (level < 2 or level > 3) return null;
    if (idx >= trimmed_left.len) return null;
    if (trimmed_left[idx] != ' ' and trimmed_left[idx] != '\t') return null;
    const heading_text = std.mem.trim(u8, trimmed_left[idx + 1 ..], " \t");
    if (heading_text.len == 0) return null;
    return .{
        .level = level,
        .text = heading_text,
    };
}

fn appendSectionLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    has_any: *bool,
    line: []const u8,
) !void {
    if (has_any.*) {
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, line);
    has_any.* = true;
}

fn extractNamedSection(
    allocator: std.mem.Allocator,
    content: []const u8,
    section_name: []const u8,
) !?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var in_section = false;
    var section_level: u8 = 0;
    var in_code_block = false;
    var has_any = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const left_trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, left_trimmed, "```")) {
            in_code_block = !in_code_block;
            if (in_section) {
                try appendSectionLine(allocator, &out, &has_any, line);
            }
            continue;
        }

        if (!in_code_block) {
            if (parseHeadingLine(line)) |heading| {
                if (!in_section) {
                    if (std.ascii.eqlIgnoreCase(heading.text, section_name)) {
                        in_section = true;
                        section_level = heading.level;
                        try appendSectionLine(allocator, &out, &has_any, line);
                        continue;
                    }
                } else {
                    if (heading.level <= section_level) {
                        break;
                    }
                    try appendSectionLine(allocator, &out, &has_any, line);
                    continue;
                }
            }
        }

        if (in_section) {
            try appendSectionLine(allocator, &out, &has_any, line);
        }
    }

    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }

    const raw = try out.toOwnedSlice(allocator);
    errdefer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return null;
    }
    if (trimmed.len == raw.len) return raw;

    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return duped;
}

fn extractSections(
    allocator: std.mem.Allocator,
    content: []const u8,
    section_names: []const []const u8,
) ![]u8 {
    var combined: std.ArrayListUnmanaged(u8) = .empty;
    errdefer combined.deinit(allocator);

    for (section_names) |section_name| {
        const maybe_section = try extractNamedSection(allocator, content, section_name);
        if (maybe_section) |section| {
            defer allocator.free(section);
            if (combined.items.len > 0) {
                try combined.appendSlice(allocator, "\n\n");
            }
            try combined.appendSlice(allocator, section);
        }
    }

    return try combined.toOwnedSlice(allocator);
}

fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    if (prefix.len > 0 and (prefix[prefix.len - 1] == '/' or prefix[prefix.len - 1] == '\\')) return true;
    const c = path[prefix.len];
    return c == '/' or c == '\\';
}

fn openWorkspaceAgentsFileGuarded(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
) ?std.fs.File {
    const workspace_root = std.fs.cwd().realpathAlloc(allocator, workspace_dir) catch return null;
    defer allocator.free(workspace_root);

    const agents_candidate = std.fs.path.join(allocator, &.{ workspace_root, "AGENTS.md" }) catch return null;
    defer allocator.free(agents_candidate);

    const agents_canonical = std.fs.cwd().realpathAlloc(allocator, agents_candidate) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    defer allocator.free(agents_canonical);

    if (!pathStartsWith(agents_canonical, workspace_root)) return null;
    return std.fs.openFileAbsolute(agents_canonical, .{}) catch null;
}

fn readWorkspaceContextForSummary(
    allocator: std.mem.Allocator,
    workspace_dir: ?[]const u8,
) ![]u8 {
    const dir = workspace_dir orelse return try allocator.dupe(u8, "");
    const file = openWorkspaceAgentsFileGuarded(allocator, dir) orelse return try allocator.dupe(u8, "");
    defer file.close();

    const content = file.readToEndAlloc(allocator, MAX_AGENTS_FILE_BYTES) catch return try allocator.dupe(u8, "");
    defer allocator.free(content);

    const sections = try extractSections(allocator, content, &.{ "Session Startup", "Red Lines" });
    defer allocator.free(sections);
    if (sections.len == 0) return try allocator.dupe(u8, "");

    const safe_content = if (sections.len > MAX_WORKSPACE_CONTEXT_CHARS)
        try std.fmt.allocPrint(allocator, "{s}\n...[truncated]...", .{sections[0..MAX_WORKSPACE_CONTEXT_CHARS]})
    else
        try allocator.dupe(u8, sections);
    defer allocator.free(safe_content);

    return try std.fmt.allocPrint(
        allocator,
        "\n\n<workspace-critical-rules>\n{s}\n</workspace-critical-rules>",
        .{safe_content},
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

const observability = @import("../observability.zig");
const ToolSpec = providers.ToolSpec;

fn makeTestAgent(allocator: std.mem.Allocator) !Agent {
    var noop = observability.NoopObserver{};
    return Agent{
        .allocator = allocator,
        .provider = undefined,
        .tools = &.{},
        .tool_specs = try allocator.alloc(ToolSpec, 0),
        .mem = null,
        .observer = noop.observer(),
        .model_name = "test-model",
        .temperature = 0.7,
        .workspace_dir = "/tmp",
        .max_tool_iterations = 10,
        .max_history_messages = 50,
        .auto_save = false,
        .history = .empty,
        .total_tokens = 0,
        .has_system_prompt = false,
    };
}

test "tokenEstimate empty history" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Empty history: (0 + 3) / 4 = 0
    try std.testing.expectEqual(@as(u64, 0), tokenEstimate(agent.history.items));
}

test "tokenEstimate with messages" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add messages with known content lengths
    // "hello" = 5 chars, "world" = 5 chars => total 10 chars => (10 + 3) / 4 = 3
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });
    try agent.history.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "world"),
    });

    try std.testing.expectEqual(@as(u64, 3), tokenEstimate(agent.history.items));
}

test "tokenEstimate heuristic accuracy" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // 400 chars should estimate ~100 tokens
    const content = try allocator.alloc(u8, 400);
    defer allocator.free(content);
    @memset(content, 'a');

    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, content),
    });

    // (400 + 3) / 4 = 100
    try std.testing.expectEqual(@as(u64, 100), tokenEstimate(agent.history.items));
}

test "autoCompactHistory no-op below token threshold" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add a few small messages — well below the token threshold.
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const compacted = try autoCompactHistory(allocator, &agent.history, agent.provider, agent.model_name, .{
        .token_limit = DEFAULT_TOKEN_LIMIT,
    });
    try std.testing.expect(!compacted);
    try std.testing.expectEqual(@as(usize, 2), agent.history.items.len);
}

test "DEFAULT_TOKEN_LIMIT constant" {
    try std.testing.expectEqual(config_types.DEFAULT_AGENT_TOKEN_LIMIT, DEFAULT_TOKEN_LIMIT);
}

test "forceCompressHistory keeps system + last 4 messages" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add system prompt + 8 messages
    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system prompt"),
    });
    for (0..8) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg-{d}", .{i}),
        });
    }
    try std.testing.expectEqual(@as(usize, 9), agent.history.items.len);

    const compressed = forceCompressHistory(allocator, &agent.history);
    try std.testing.expect(compressed);

    // Should keep system + last 4
    try std.testing.expectEqual(@as(usize, 5), agent.history.items.len);
    try std.testing.expect(agent.history.items[0].role == .system);
    try std.testing.expectEqualStrings("system prompt", agent.history.items[0].content);
    try std.testing.expectEqualStrings("msg-4", agent.history.items[1].content);
    try std.testing.expectEqualStrings("msg-7", agent.history.items[4].content);
}

test "forceCompressHistory without system prompt" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    // Add 8 messages (no system prompt)
    for (0..8) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg-{d}", .{i}),
        });
    }

    const compressed = forceCompressHistory(allocator, &agent.history);
    try std.testing.expect(compressed);

    // Should keep last 4
    try std.testing.expectEqual(@as(usize, 4), agent.history.items.len);
    try std.testing.expectEqualStrings("msg-4", agent.history.items[0].content);
    try std.testing.expectEqualStrings("msg-7", agent.history.items[3].content);
}

test "forceCompressHistory no-op when history is small" {
    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "sys"),
    });
    try agent.history.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
    });

    const compressed = forceCompressHistory(allocator, &agent.history);
    try std.testing.expect(!compressed);
    try std.testing.expectEqual(@as(usize, 2), agent.history.items.len);
}

test "manualCompactHistory summarizes older context and keeps recent recovery tail" {
    const SummaryProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "- compacted summary");
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{
                .content = try allocator.dupe(u8, "- compacted summary"),
                .tool_calls = &.{},
                .usage = .{},
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "summary-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const allocator = std.testing.allocator;
    var agent = try makeTestAgent(allocator);
    defer agent.deinit();
    var provider_state: u8 = 0;
    const provider_vtable = Provider.VTable{
        .chatWithSystem = SummaryProvider.chatWithSystem,
        .chat = SummaryProvider.chat,
        .supportsNativeTools = SummaryProvider.supportsNativeTools,
        .getName = SummaryProvider.getName,
        .deinit = SummaryProvider.deinitFn,
    };
    agent.provider = .{ .ptr = @ptrCast(&provider_state), .vtable = &provider_vtable };

    try agent.history.append(allocator, .{
        .role = .system,
        .content = try allocator.dupe(u8, "system prompt"),
    });
    for (0..6) |i| {
        try agent.history.append(allocator, .{
            .role = .user,
            .content = try std.fmt.allocPrint(allocator, "msg-{d}", .{i}),
        });
    }

    const compacted = try manualCompactHistory(allocator, &agent.history, agent.provider, agent.model_name, .{
        .keep_recent = 20,
        .max_summary_chars = 500,
        .max_source_chars = 1_500,
    });
    try std.testing.expect(compacted);
    try std.testing.expectEqual(@as(usize, 6), agent.history.items.len);
    try std.testing.expect(agent.history.items[0].role == .system);
    try std.testing.expect(agent.history.items[1].role == .assistant);
    try std.testing.expect(std.mem.startsWith(u8, agent.history.items[1].content, "[Compaction summary]\n"));
    try std.testing.expectEqualStrings("msg-2", agent.history.items[2].content);
    try std.testing.expectEqualStrings("msg-5", agent.history.items[5].content);
}

test "CONTEXT_RECOVERY constants" {
    try std.testing.expectEqual(@as(usize, 6), CONTEXT_RECOVERY_MIN_HISTORY);
    try std.testing.expectEqual(@as(usize, 4), CONTEXT_RECOVERY_KEEP);
}

test "extractSections captures Session Startup and Red Lines, ignoring code fences" {
    const content =
        \\## Intro
        \\hello
        \\
        \\```md
        \\## Session Startup
        \\this must be ignored
        \\```
        \\
        \\## Session Startup
        \\- read SOUL.md
        \\
        \\### Nested detail
        \\- keep this too
        \\
        \\## Red Lines
        \\- do not leak secrets
        \\
        \\## Other
        \\ignored
    ;

    const sections = try extractSections(std.testing.allocator, content, &.{ "Session Startup", "Red Lines" });
    defer std.testing.allocator.free(sections);

    try std.testing.expect(std.mem.indexOf(u8, sections, "## Session Startup") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "### Nested detail") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "## Red Lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections, "this must be ignored") == null);
}

test "readWorkspaceContextForSummary wraps AGENTS critical sections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("AGENTS.md", .{});
        defer f.close();
        try f.writeAll(
            \\## Session Startup
            \\- read AGENTS.md
            \\- read SOUL.md
            \\
            \\## Red Lines
            \\- never leak tokens
        );
    }

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const context = try readWorkspaceContextForSummary(std.testing.allocator, workspace);
    defer std.testing.allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "<workspace-critical-rules>") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "Session Startup") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "Red Lines") != null);
}

test "readWorkspaceContextForSummary returns empty when AGENTS missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const context = try readWorkspaceContextForSummary(std.testing.allocator, workspace);
    defer std.testing.allocator.free(context);

    try std.testing.expectEqual(@as(usize, 0), context.len);
}

test "readWorkspaceContextForSummary blocks AGENTS symlink escape" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    var outside_tmp = std.testing.tmpDir(.{});
    defer outside_tmp.cleanup();

    try outside_tmp.dir.writeFile(.{
        .sub_path = "outside-agents.md",
        .data =
        \\## Session Startup
        \\- outside
        \\
        \\## Red Lines
        \\- outside
        ,
    });

    const outside_path = try outside_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(outside_path);
    const outside_agents = try std.fs.path.join(std.testing.allocator, &.{ outside_path, "outside-agents.md" });
    defer std.testing.allocator.free(outside_agents);

    try ws_tmp.dir.symLink(outside_agents, "AGENTS.md", .{});

    const workspace = try ws_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    const context = try readWorkspaceContextForSummary(std.testing.allocator, workspace);
    defer std.testing.allocator.free(context);

    try std.testing.expectEqual(@as(usize, 0), context.len);
}

test "buildCompactionTranscript excludes bootstrap system prompt when start skips system" {
    var history = std.ArrayListUnmanaged(OwnedMessage).empty;
    defer {
        for (history.items) |*msg| msg.deinit(std.testing.allocator);
        history.deinit(std.testing.allocator);
    }

    try history.append(std.testing.allocator, .{
        .role = .system,
        .content = try std.testing.allocator.dupe(u8, "AGENTS.md bootstrap content"),
    });
    try history.append(std.testing.allocator, .{
        .role = .user,
        .content = try std.testing.allocator.dupe(u8, "user-message"),
    });

    const transcript = try buildCompactionTranscript(
        std.testing.allocator,
        history.items,
        1,
        history.items.len,
        DEFAULT_COMPACTION_MAX_SOURCE_CHARS,
    );
    defer std.testing.allocator.free(transcript);

    try std.testing.expect(std.mem.indexOf(u8, transcript, "AGENTS.md bootstrap content") == null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "USER: user-message") != null);
}
