const std = @import("std");
const config_types = @import("../config_types.zig");
const memory_mod = @import("../memory/root.zig");
const multimodal = @import("../multimodal.zig");
const zaki_state = @import("../zaki_state.zig");
const graph_expand = @import("graph_expand.zig");
const text_norm = @import("../memory/text_norm.zig");
const Memory = memory_mod.Memory;
const MemoryEntry = memory_mod.MemoryEntry;
const MemoryRuntime = memory_mod.MemoryRuntime;
const log = std.log.scoped(.memory_loader);

/// V1.7a-4 review fix WR-01: alias the consolidated UTF-8 truncation
/// helper so existing call sites in this file don't need to change. The
/// shared implementation lives in `memory/text_norm.zig` (one source of
/// truth across the 3 prior diverged copies).
const truncateUtf8 = text_norm.truncateUtf8;

// ═══════════════════════════════════════════════════════════════════════════
// Memory Loader — inject relevant memory context into user messages
// ═══════════════════════════════════════════════════════════════════════════

/// Default number of memory entries to recall per query.
const DEFAULT_RECALL_LIMIT: usize = config_types.DEFAULT_MEMORY_ENRICH_RECALL_LIMIT;
const GLOBAL_RECALL_CANDIDATE_LIMIT: usize = 64;
const WARM_CANDIDATE_FETCH_LIMIT: usize = @max(DEFAULT_RECALL_LIMIT, GLOBAL_RECALL_CANDIDATE_LIMIT);
const TIMELINE_FALLBACK_LIMIT: usize = config_types.DEFAULT_MEMORY_TIMELINE_FALLBACK_LIMIT;
const GLOBAL_RECALL_TOKEN_LIMIT: usize = 6;
const GLOBAL_RECALL_TOKEN_SEPARATORS = " \t\n\r,.;:!?()[]{}<>\"'/-_";

/// Maximum total bytes of memory context injected into a message.
/// Prevents a few large entries from blowing the token budget.
/// ~4000 chars ~ 1000 tokens — a safe ceiling for context injection.
const MAX_CONTEXT_BYTES: usize = config_types.DEFAULT_MEMORY_CONTEXT_MAX_BYTES;
const CONTINUITY_BUCKET_MAX_BYTES: usize = 1200;
const CONTINUITY_ENTRY_MAX_BYTES: usize = 1000;
const SEMANTIC_BUCKET_MIN_ENTRIES: usize = 4;
const SEMANTIC_BUCKET_MAX_BYTES: usize = 2200;
const SEMANTIC_ENTRY_MAX_BYTES: usize = 420;
const SEARCH_FALLBACK_BUCKET_MAX_ENTRIES: usize = 6;
const SEARCH_FALLBACK_BUCKET_MAX_BYTES: usize = 1600;
const FALLBACK_BUCKET_MAX_ENTRIES: usize = 2;
const FALLBACK_BUCKET_MAX_BYTES: usize = 700;
const FALLBACK_ENTRY_MAX_BYTES: usize = 320;

// V1.7a-2 — graph-expand recall consumer.
//
// When a state_mgr is threaded through `loadTurnMemorySlot` AND
// `NULLALIS_GRAPH_RECALL_MAX_HOPS` (default 1) is non-zero, an additional
// `<graph_neighbors>` block is appended to the memory_for_turn slot. This
// block lists 1-hop neighbors of the recall seeds that the legacy keyword/
// vector recall would NOT have surfaced (because they don't textually
// match the query, but they are graph-connected to a seed that does).
//
// `max_hops=0` disables graph-mode entirely (legacy behavior — strict
// backward compat). Operators set the env to 0 to roll back if needed.
const DEFAULT_GRAPH_RECALL_MAX_HOPS: u8 = 1;
const DEFAULT_GRAPH_RECALL_SEEDS: usize = 5;
const DEFAULT_GRAPH_RECALL_MAX_NODES_PER_HOP: usize = 20;
/// Hard cap on the appended `<graph_neighbors>` block bytes. Keeps the
/// graph-mode addition bounded so the volatile system block doesn't blow
/// the prompt cache budget when the graph is dense.
const GRAPH_NEIGHBORS_BLOCK_MAX_BYTES: usize = 1500;
/// Per-neighbor content cap inside the block. Same shape as
/// SEMANTIC_ENTRY_MAX_BYTES — short, scannable.
const GRAPH_NEIGHBOR_CONTENT_MAX_BYTES: usize = 220;

pub const SelectionStats = struct {
    available: bool = false,
    candidate_count: usize = 0,
    global_candidate_count: usize = 0,
    summary_latest_used: bool = false,
    context_anchor_used: bool = false,
    durable_fact_count: usize = 0,
    timeline_summary_count: usize = 0,
    search_match_count: usize = 0,
    global_fallback_count: usize = 0,
    continuity_bucket_entries: usize = 0,
    continuity_bucket_bytes: usize = 0,
    semantic_bucket_entries: usize = 0,
    semantic_bucket_bytes: usize = 0,
    fallback_bucket_entries: usize = 0,
    fallback_bucket_bytes: usize = 0,
    context_bytes: usize = 0,
    injected: bool = false,
    // V1.7a-2 — graph-expand recall consumer telemetry.
    graph_recall_active: bool = false,
    graph_recall_seed_count: usize = 0,
    graph_recall_neighbor_count: usize = 0,
    graph_recall_appended_bytes: usize = 0,
    graph_recall_max_hops: u8 = 0,
};

pub const ContextResult = struct {
    context: []const u8,
    stats: SelectionStats,
};

pub const EnrichmentResult = struct {
    text: []const u8,
    stats: SelectionStats,
};

/// Memory payload for the volatile system block. `fenced_content` is the
/// retrieved memory wrapped in `<memory_for_turn>…</memory_for_turn>` markers,
/// suitable for direct inclusion in PromptContext.memory_slot. Empty string
/// means no memory was retrieved for this turn.
pub const MemorySlot = struct {
    fenced_content: []const u8,
    stats: SelectionStats,
};

// truncateUtf8 helper has moved to memory/text_norm.zig — single source of
// truth (V1.7a-4 review fix WR-01). The local alias `const truncateUtf8 =
// text_norm.truncateUtf8;` near the top of this file preserves all existing
// call sites without code change.

fn containsKey(entries: []const MemoryEntry, key: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return true;
    }
    return false;
}

fn containsCandidateKey(entries: []const memory_mod.RetrievalCandidate, key: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return true;
    }
    return false;
}

fn cloneCategory(allocator: std.mem.Allocator, category: memory_mod.MemoryCategory) !memory_mod.MemoryCategory {
    return switch (category) {
        .custom => |name| memory_mod.MemoryCategory{ .custom = try allocator.dupe(u8, name) },
        else => category,
    };
}

fn cloneEntry(allocator: std.mem.Allocator, entry: MemoryEntry) !MemoryEntry {
    const id = try allocator.dupe(u8, entry.id);
    errdefer allocator.free(id);
    const key = try allocator.dupe(u8, entry.key);
    errdefer allocator.free(key);
    const content = try allocator.dupe(u8, entry.content);
    errdefer allocator.free(content);
    const timestamp = try allocator.dupe(u8, entry.timestamp);
    errdefer allocator.free(timestamp);
    const category = try cloneCategory(allocator, entry.category);
    errdefer switch (category) {
        .custom => |name| allocator.free(name),
        else => {},
    };
    const session_id = if (entry.session_id) |sid|
        try allocator.dupe(u8, sid)
    else
        null;
    errdefer if (session_id) |sid| allocator.free(sid);

    return MemoryEntry{
        .id = id,
        .key = key,
        .content = content,
        .category = category,
        .timestamp = timestamp,
        .session_id = session_id,
        .score = entry.score,
    };
}

fn containsIgnoreCase(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.ascii.eqlIgnoreCase(item, needle)) return true;
    }
    return false;
}

fn loadGlobalKeywordFallbackEntries(
    allocator: std.mem.Allocator,
    mem: Memory,
    user_message: []const u8,
    limit: usize,
    current_session_id: ?[]const u8,
) ![]MemoryEntry {
    var merged: std.ArrayListUnmanaged(MemoryEntry) = .empty;
    errdefer {
        for (merged.items) |*entry| entry.deinit(allocator);
        merged.deinit(allocator);
    }

    var seen_terms: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen_terms.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, user_message, GLOBAL_RECALL_TOKEN_SEPARATORS);
    while (iter.next()) |term| {
        if (term.len < 3) continue;
        if (containsIgnoreCase(seen_terms.items, term)) continue;
        try seen_terms.append(allocator, term);
        if (seen_terms.items.len > GLOBAL_RECALL_TOKEN_LIMIT) break;

        const recalled = mem.recall(allocator, term, limit, null) catch continue;
        defer memory_mod.freeEntries(allocator, recalled);

        for (recalled) |entry| {
            if (current_session_id) |session_id| {
                if (entry.session_id) |entry_session_id| {
                    if (std.mem.eql(u8, entry_session_id, session_id)) continue;
                }
            }
            if (containsKey(merged.items, entry.key)) continue;
            try merged.append(allocator, try cloneEntry(allocator, entry));
            if (merged.items.len >= limit) return try merged.toOwnedSlice(allocator);
        }
    }

    return try merged.toOwnedSlice(allocator);
}

fn isDurableFactKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "durable_fact/");
}

/// V1.7 commit 9.6 (full Gap 3 closure) — extracted-fact rows from
/// V1.6 cmt7+ are now first-class continuity artifacts, equivalent in
/// role to durable_fact for agent bootstrap context. Without this
/// predicate, persistExtracted-derived facts (the new authoritative
/// source after cmt9.6 unification) wouldn't be picked up at session
/// start; the agent would lose its working memory of structured facts
/// produced by Pass C extraction or the unified write paths.
///
/// The `extracted_<hash>` prefix matches deriveExtractionKey shape
/// (V1.6 cmt7 Gap 2). Brain-visible (per memory/root.zig — extracted_*
/// is NOT in BRAIN_HIDDEN_PREFIXES) AND continuity-bucket-eligible
/// (this predicate). Two roles, no conflict.
fn isExtractedFactKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "extracted_");
}

// Legacy compatibility artifact: retained for audit/debug access only and
// intentionally excluded from normal continuity injection.
fn isSessionSummaryAuditKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "session_summary/");
}

fn isTimelineSummaryKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "timeline_summary/");
}

fn isSummaryLatestKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "summary_latest/");
}

/// V1.5.5 polish — compaction Pass C archives at
/// `compaction_summary/{session}/{ts}` (compaction.zig:535). These are
/// recallable continuity artifacts on par with summary_latest and
/// timeline_summary; agent retrieval should treat them as warm
/// continuity entries, not generic vector hits. Without this predicate,
/// compaction_summary entries only surface through general retrieval
/// scoring and lose to fresher noise on long sessions.
fn isCompactionSummaryKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "compaction_summary/") or
        std.mem.startsWith(u8, key, "summary_fallback/") or
        std.mem.startsWith(u8, key, "compaction_dropped/");
}

fn isSessionCheckpointKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "session_checkpoint_");
}

fn summaryLatestKeyForSession(allocator: std.mem.Allocator, session_id: ?[]const u8) !?[]u8 {
    const sid = session_id orelse return null;
    return try std.fmt.allocPrint(allocator, "summary_latest/{s}", .{sid});
}

fn timelinePrefixForSession(allocator: std.mem.Allocator, session_id: ?[]const u8) !?[]u8 {
    const sid = session_id orelse return null;
    return try std.fmt.allocPrint(allocator, "timeline_summary/{s}/", .{sid});
}

fn sanitizeMemoryText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    // Strip inline image markers from recalled snippets so stale
    // [IMAGE:...] references do not accidentally trigger multimodal mode.
    const parsed = multimodal.parseImageMarkers(allocator, text) catch return try allocator.dupe(u8, text);
    defer allocator.free(parsed.refs);
    return parsed.cleaned_text;
}

fn ensureHeader(w: anytype, wrote_header: *bool) !void {
    if (!wrote_header.*) {
        try w.writeAll("[Memory context]\n");
        try w.writeAll("Retrieved continuity from the canonical runtime memory store for this turn.\n");
        try w.writeAll("If a relevant fact appears below, use it instead of saying you do not remember.\n");
        try w.writeAll("Direct user corrections, tool results, and fresher runtime state override this memory.\n");
        wrote_header.* = true;
    }
}

fn appendContextLine(
    allocator: std.mem.Allocator,
    w: anytype,
    wrote_header: *bool,
    key: []const u8,
    text: []const u8,
    clip_limit: usize,
) !void {
    try ensureHeader(w, wrote_header);
    const clipped = truncateUtf8(text, clip_limit);
    const sanitized = try sanitizeMemoryText(allocator, clipped);
    defer allocator.free(sanitized);
    try std.fmt.format(w, "- {s}: {s}\n", .{ key, sanitized });
}

fn appendDirectEntry(
    allocator: std.mem.Allocator,
    mem: Memory,
    w: anytype,
    wrote_header: *bool,
    key: []const u8,
    clip_limit: usize,
) !bool {
    const entry = (try mem.get(allocator, key)) orelse return false;
    defer entry.deinit(allocator);
    if (shouldSkipLowSignalEntry(entry.key, entry.content)) return false;
    try appendContextLine(allocator, w, wrote_header, entry.key, entry.content, clip_limit);
    return true;
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn markSeenKey(allocator: std.mem.Allocator, seen_keys: *std.ArrayListUnmanaged([]const u8), key: []const u8) !void {
    if (containsString(seen_keys.items, key)) return;
    try seen_keys.append(allocator, key);
}

fn isSemanticContinuityKey(key: []const u8) bool {
    return isDurableFactKey(key) or
        // V1.7 cmt9.6 — extracted_<hash> rows are first-class continuity
        // alongside durable_fact. Once cmt9.6 unifies write paths, the
        // session-end fact loop produces extracted_* keys instead of
        // (or in addition to) durable_fact/* keys; both must surface to
        // the agent's bootstrap context.
        isExtractedFactKey(key) or
        isTimelineSummaryKey(key) or
        isSummaryLatestKey(key) or
        // V1.5.5 polish: compaction Pass C summaries are continuity-class
        // per `memory_root.classifyArtifactKey` and per the iter29 family
        // taxonomy — but they were missing from this list, so the agent's
        // retrieval bucket-routing would not preferentially surface them.
        // Wired now so compaction summaries warm-bucket alongside their
        // sibling continuity families.
        isCompactionSummaryKey(key);
}

fn isNegativeDiagnosticKeyOrContent(content: []const u8) bool {
    const negative_needles = [_][]const u8{
        "no embeddings",
        "semantic recall returns nothing",
        "timeline returns nothing",
        "recall broken",
        "no structured session summaries",
        "the underlying store is empty",
        "memory_recall returns nothing",
        "no embeddings in pgvector",
    };
    for (negative_needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(content, needle) != null) return true;
    }
    return false;
}

fn shouldSkipLowSignalEntry(key: []const u8, content: []const u8) bool {
    return memory_mod.isInternalMemoryEntryKeyOrContent(key, content) or
        memory_mod.isMarkdownLineKey(key) or
        std.mem.eql(u8, key, "context_anchor_current") or
        isNegativeDiagnosticKeyOrContent(content);
}

fn shouldSkipGenericEntry(
    key: []const u8,
    content: []const u8,
    summary_latest_key: ?[]const u8,
    current_timeline_prefix: ?[]const u8,
    has_priority_context: bool,
) bool {
    if (shouldSkipLowSignalEntry(key, content)) return true;
    if (summary_latest_key) |latest_key| {
        if (std.mem.eql(u8, key, latest_key)) return true;
    }
    if (isSessionSummaryAuditKey(key)) return true;
    if (has_priority_context and isSessionCheckpointKey(key)) return true;
    if (current_timeline_prefix) |prefix| {
        if (std.mem.startsWith(u8, key, prefix)) return true;
    }
    return false;
}

fn canAppendToBucket(
    current_total_bytes: usize,
    bucket_bytes: usize,
    bucket_entries: usize,
    max_bucket_bytes: usize,
    max_bucket_entries: ?usize,
    projected_additional_bytes: usize,
) bool {
    if (current_total_bytes >= MAX_CONTEXT_BYTES) return false;
    if (bucket_bytes >= max_bucket_bytes) return false;
    if (max_bucket_entries) |limit| {
        if (bucket_entries >= limit) return false;
    }
    return bucket_bytes + projected_additional_bytes <= max_bucket_bytes and current_total_bytes + projected_additional_bytes <= MAX_CONTEXT_BYTES;
}

fn appendBucketEntry(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    wrote_header: *bool,
    key: []const u8,
    text: []const u8,
    clip_limit: usize,
    bucket_bytes: *usize,
) !void {
    const before = buf.items.len;
    const w = buf.writer(allocator);
    try appendContextLine(allocator, w, wrote_header, key, text, clip_limit);
    bucket_bytes.* += buf.items.len - before;
}

/// Build a memory context preamble by searching stored memories.
///
/// Returns a formatted string like:
/// ```
/// [Memory context]
/// - key1: value1
/// - key2: value2
/// ```
///
/// Returns an empty owned string if no relevant memories are found.
fn loadContextDetailed(
    allocator: std.mem.Allocator,
    mem: Memory,
    user_message: []const u8,
    session_id: ?[]const u8,
) !ContextResult {
    var stats = SelectionStats{ .available = true };
    const scoped_entries = mem.recall(allocator, user_message, WARM_CANDIDATE_FETCH_LIMIT, session_id) catch {
        return .{ .context = try allocator.dupe(u8, ""), .stats = stats };
    };
    defer memory_mod.freeEntries(allocator, scoped_entries);
    stats.candidate_count = scoped_entries.len;

    // When scoped recall is enabled, also include global (session_id = null) memory
    // so long-term facts from memory_store remain visible in session chats.
    var global_entries: ?[]MemoryEntry = null;
    if (session_id != null) {
        global_entries = mem.recall(allocator, user_message, GLOBAL_RECALL_CANDIDATE_LIMIT, null) catch null;
    }
    if (global_entries) |entries| {
        stats.global_candidate_count = entries.len;
    }
    defer if (global_entries) |entries| memory_mod.freeEntries(allocator, entries);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    var appended: usize = 0;
    var wrote_header = false;
    var has_priority_context = false;
    var timeline_added: usize = 0;
    var seen_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen_keys.deinit(allocator);
    var continuity_bytes: usize = 0;
    var semantic_bytes: usize = 0;
    var fallback_bytes: usize = 0;

    const summary_latest_key = try summaryLatestKeyForSession(allocator, session_id);
    defer if (summary_latest_key) |key| allocator.free(key);
    const current_timeline_prefix = try timelinePrefixForSession(allocator, session_id);
    defer if (current_timeline_prefix) |prefix| allocator.free(prefix);

    // V1.7 Item 3: surface any unresolved memory conflict at the top so
    // the agent sees it before any other context and can resolve it with
    // the user. Best-effort — failure must not block context loading.
    _ = appendDirectEntry(allocator, mem, w, &wrote_header, "pending_conflicts", 300) catch false;

    if (summary_latest_key) |key| {
        if (try appendDirectEntry(allocator, mem, w, &wrote_header, key, CONTINUITY_ENTRY_MAX_BYTES)) {
            appended += 1;
            has_priority_context = true;
            stats.summary_latest_used = true;
            try markSeenKey(allocator, &seen_keys, key);
            continuity_bytes = @min(buf.items.len, CONTINUITY_BUCKET_MAX_BYTES);
            stats.continuity_bucket_entries = 1;
            stats.continuity_bucket_bytes = continuity_bytes;
        }
    }

    if (global_entries) |entries| {
        for (entries) |entry| {
            // V1.7 cmt9.6: extracted_<hash> rows join durable_fact in the
            // continuity bucket. Both shapes feed agent bootstrap context.
            if (!isDurableFactKey(entry.key) and !isExtractedFactKey(entry.key)) continue;
            if (containsKey(scoped_entries, entry.key)) continue;
            if (containsString(seen_keys.items, entry.key)) continue;
            const estimated_bytes = @min(entry.content.len, SEMANTIC_ENTRY_MAX_BYTES) + entry.key.len + 8;
            if (!canAppendToBucket(buf.items.len, semantic_bytes, stats.semantic_bucket_entries, SEMANTIC_BUCKET_MAX_BYTES, null, estimated_bytes)) break;
            try appendBucketEntry(allocator, &buf, &wrote_header, entry.key, entry.content, SEMANTIC_ENTRY_MAX_BYTES, &semantic_bytes);
            appended += 1;
            has_priority_context = true;
            stats.durable_fact_count += 1;
            stats.semantic_bucket_entries += 1;
            stats.semantic_bucket_bytes = semantic_bytes;
            try markSeenKey(allocator, &seen_keys, entry.key);
            if (appended >= DEFAULT_RECALL_LIMIT or buf.items.len >= MAX_CONTEXT_BYTES) break;
        }
    }

    if (appended < DEFAULT_RECALL_LIMIT and buf.items.len < MAX_CONTEXT_BYTES and global_entries != null) {
        if (global_entries) |entries| {
            for (entries) |entry| {
                if (!isTimelineSummaryKey(entry.key)) continue;
                if (current_timeline_prefix) |prefix| {
                    if (std.mem.startsWith(u8, entry.key, prefix)) continue;
                }
                if (containsString(seen_keys.items, entry.key)) continue;
                const estimated_bytes = @min(entry.content.len, SEMANTIC_ENTRY_MAX_BYTES) + entry.key.len + 8;
                if (!canAppendToBucket(buf.items.len, semantic_bytes, stats.semantic_bucket_entries, SEMANTIC_BUCKET_MAX_BYTES, null, estimated_bytes)) break;
                try appendBucketEntry(allocator, &buf, &wrote_header, entry.key, entry.content, SEMANTIC_ENTRY_MAX_BYTES, &semantic_bytes);
                appended += 1;
                timeline_added += 1;
                has_priority_context = true;
                stats.timeline_summary_count += 1;
                stats.semantic_bucket_entries += 1;
                stats.semantic_bucket_bytes = semantic_bytes;
                try markSeenKey(allocator, &seen_keys, entry.key);
                if (timeline_added >= TIMELINE_FALLBACK_LIMIT or appended >= DEFAULT_RECALL_LIMIT or buf.items.len >= MAX_CONTEXT_BYTES) break;
            }
        }
    }

    for (scoped_entries) |entry| {
        if (shouldSkipGenericEntry(entry.key, entry.content, summary_latest_key, current_timeline_prefix, has_priority_context)) continue;
        if (containsString(seen_keys.items, entry.key)) continue;
        if (isSemanticContinuityKey(entry.key)) {
            const estimated_bytes = @min(entry.content.len, SEMANTIC_ENTRY_MAX_BYTES) + entry.key.len + 8;
            if (!canAppendToBucket(buf.items.len, semantic_bytes, stats.semantic_bucket_entries, SEMANTIC_BUCKET_MAX_BYTES, null, estimated_bytes)) continue;
            try appendBucketEntry(allocator, &buf, &wrote_header, entry.key, entry.content, SEMANTIC_ENTRY_MAX_BYTES, &semantic_bytes);
            stats.semantic_bucket_entries += 1;
            stats.semantic_bucket_bytes = semantic_bytes;
            stats.search_match_count += 1;
            appended += 1;
            try markSeenKey(allocator, &seen_keys, entry.key);
        } else {
            const estimated_bytes = @min(entry.content.len, FALLBACK_ENTRY_MAX_BYTES) + entry.key.len + 8;
            if (!canAppendToBucket(buf.items.len, fallback_bytes, stats.fallback_bucket_entries, FALLBACK_BUCKET_MAX_BYTES, FALLBACK_BUCKET_MAX_ENTRIES, estimated_bytes)) continue;
            try appendBucketEntry(allocator, &buf, &wrote_header, entry.key, entry.content, FALLBACK_ENTRY_MAX_BYTES, &fallback_bytes);
            stats.fallback_bucket_entries += 1;
            stats.fallback_bucket_bytes = fallback_bytes;
            stats.global_fallback_count += 1;
            appended += 1;
            try markSeenKey(allocator, &seen_keys, entry.key);
        }
        if (appended >= DEFAULT_RECALL_LIMIT or buf.items.len >= MAX_CONTEXT_BYTES) break;
    }

    if (appended < DEFAULT_RECALL_LIMIT and buf.items.len < MAX_CONTEXT_BYTES and session_id != null) {
        if (global_entries) |entries| {
            for (entries) |entry| {
                if (entry.session_id != null) continue; // keep scoped isolation (no cross-session bleed)
                if (containsKey(scoped_entries, entry.key)) continue;
                if (shouldSkipGenericEntry(entry.key, entry.content, summary_latest_key, current_timeline_prefix, has_priority_context)) continue;
                if (containsString(seen_keys.items, entry.key)) continue;
                const estimated_bytes = @min(entry.content.len, FALLBACK_ENTRY_MAX_BYTES) + entry.key.len + 8;
                if (!canAppendToBucket(buf.items.len, fallback_bytes, stats.fallback_bucket_entries, FALLBACK_BUCKET_MAX_BYTES, FALLBACK_BUCKET_MAX_ENTRIES, estimated_bytes)) break;
                try appendBucketEntry(allocator, &buf, &wrote_header, entry.key, entry.content, FALLBACK_ENTRY_MAX_BYTES, &fallback_bytes);
                appended += 1;
                stats.global_fallback_count += 1;
                stats.fallback_bucket_entries += 1;
                stats.fallback_bucket_bytes = fallback_bytes;
                try markSeenKey(allocator, &seen_keys, entry.key);
                if (appended >= DEFAULT_RECALL_LIMIT or buf.items.len >= MAX_CONTEXT_BYTES) break;
            }
        }
    }

    if (!wrote_header) {
        return .{ .context = try allocator.dupe(u8, ""), .stats = stats };
    }
    try w.writeAll("\n");
    stats.injected = true;
    stats.context_bytes = buf.items.len;

    return .{ .context = try buf.toOwnedSlice(allocator), .stats = stats };
}

/// Load context using the full retrieval pipeline (hybrid search, RRF, etc.)
/// when a MemoryRuntime is available.
fn loadContextWithRuntimeDetailed(
    allocator: std.mem.Allocator,
    mem: Memory,
    rt: *MemoryRuntime,
    user_message: []const u8,
    session_id: ?[]const u8,
) !ContextResult {
    var stats = SelectionStats{ .available = true };
    const candidates = rt.search(allocator, user_message, WARM_CANDIDATE_FETCH_LIMIT, session_id) catch {
        return .{ .context = try allocator.dupe(u8, ""), .stats = stats };
    };
    defer memory_mod.retrieval.freeCandidates(allocator, candidates);
    stats.candidate_count = candidates.len;

    var global_entries: ?[]MemoryEntry = null;
    if (session_id != null) {
        global_entries = mem.recall(allocator, user_message, GLOBAL_RECALL_CANDIDATE_LIMIT, null) catch null;
    }
    var global_keyword_entries: ?[]MemoryEntry = null;
    if (session_id != null) {
        global_keyword_entries = loadGlobalKeywordFallbackEntries(allocator, mem, user_message, GLOBAL_RECALL_CANDIDATE_LIMIT, session_id) catch null;
    }
    if (global_entries) |entries| {
        stats.global_candidate_count = entries.len;
    }
    if (global_keyword_entries) |entries| {
        stats.global_candidate_count += entries.len;
    }
    defer if (global_entries) |entries| memory_mod.freeEntries(allocator, entries);
    defer if (global_keyword_entries) |entries| memory_mod.freeEntries(allocator, entries);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var wrote_header = false;
    var has_priority_context = false;
    var timeline_added: usize = 0;
    var seen_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen_keys.deinit(allocator);
    var continuity_bytes: usize = 0;
    var semantic_bytes: usize = 0;
    var fallback_bytes: usize = 0;

    const summary_latest_key = try summaryLatestKeyForSession(allocator, session_id);
    defer if (summary_latest_key) |key| allocator.free(key);
    const current_timeline_prefix = try timelinePrefixForSession(allocator, session_id);
    defer if (current_timeline_prefix) |prefix| allocator.free(prefix);

    // V1.7 Item 3: surface any unresolved memory conflict first.
    _ = appendDirectEntry(allocator, mem, buf.writer(allocator), &wrote_header, "pending_conflicts", 300) catch false;

    if (summary_latest_key) |key| {
        if (try appendDirectEntry(allocator, mem, buf.writer(allocator), &wrote_header, key, CONTINUITY_ENTRY_MAX_BYTES)) {
            has_priority_context = true;
            stats.summary_latest_used = true;
            try markSeenKey(allocator, &seen_keys, key);
            continuity_bytes = @min(buf.items.len, CONTINUITY_BUCKET_MAX_BYTES);
            stats.continuity_bucket_entries = 1;
            stats.continuity_bucket_bytes = continuity_bytes;
        }
    }

    if (global_entries) |entries| {
        for (entries) |entry| {
            // V1.7 cmt9.6: extracted_<hash> rows join durable_fact in the
            // continuity bucket. Both shapes feed agent bootstrap context.
            if (!isDurableFactKey(entry.key) and !isExtractedFactKey(entry.key)) continue;
            if (containsString(seen_keys.items, entry.key)) continue;
            const estimated_bytes = @min(entry.content.len, SEMANTIC_ENTRY_MAX_BYTES) + entry.key.len + 8;
            if (!canAppendToBucket(buf.items.len, semantic_bytes, stats.semantic_bucket_entries, SEMANTIC_BUCKET_MAX_BYTES, null, estimated_bytes)) break;
            try appendBucketEntry(allocator, &buf, &wrote_header, entry.key, entry.content, SEMANTIC_ENTRY_MAX_BYTES, &semantic_bytes);
            has_priority_context = true;
            stats.durable_fact_count += 1;
            stats.semantic_bucket_entries += 1;
            stats.semantic_bucket_bytes = semantic_bytes;
            try markSeenKey(allocator, &seen_keys, entry.key);
            if (buf.items.len >= MAX_CONTEXT_BYTES) break;
        }
    }

    if (buf.items.len < MAX_CONTEXT_BYTES and global_entries != null) {
        if (global_entries) |entries| {
            for (entries) |entry| {
                if (!isTimelineSummaryKey(entry.key)) continue;
                if (current_timeline_prefix) |prefix| {
                    if (std.mem.startsWith(u8, entry.key, prefix)) continue;
                }
                if (containsString(seen_keys.items, entry.key)) continue;
                const estimated_bytes = @min(entry.content.len, SEMANTIC_ENTRY_MAX_BYTES) + entry.key.len + 8;
                if (!canAppendToBucket(buf.items.len, semantic_bytes, stats.semantic_bucket_entries, SEMANTIC_BUCKET_MAX_BYTES, null, estimated_bytes)) break;
                try appendBucketEntry(allocator, &buf, &wrote_header, entry.key, entry.content, SEMANTIC_ENTRY_MAX_BYTES, &semantic_bytes);
                timeline_added += 1;
                has_priority_context = true;
                stats.timeline_summary_count += 1;
                stats.semantic_bucket_entries += 1;
                stats.semantic_bucket_bytes = semantic_bytes;
                try markSeenKey(allocator, &seen_keys, entry.key);
                if (timeline_added >= TIMELINE_FALLBACK_LIMIT or buf.items.len >= MAX_CONTEXT_BYTES) break;
            }
        }
    }

    for (candidates) |cand| {
        if (shouldSkipGenericEntry(cand.key, cand.snippet, summary_latest_key, current_timeline_prefix, has_priority_context)) continue;
        if (containsString(seen_keys.items, cand.key)) continue;
        if (isSemanticContinuityKey(cand.key)) {
            const estimated_bytes = @min(cand.snippet.len, SEMANTIC_ENTRY_MAX_BYTES) + cand.key.len + 8;
            if (!canAppendToBucket(buf.items.len, semantic_bytes, stats.semantic_bucket_entries, SEMANTIC_BUCKET_MAX_BYTES, null, estimated_bytes)) continue;
            try appendBucketEntry(allocator, &buf, &wrote_header, cand.key, cand.snippet, SEMANTIC_ENTRY_MAX_BYTES, &semantic_bytes);
            stats.semantic_bucket_entries += 1;
            stats.semantic_bucket_bytes = semantic_bytes;
        } else {
            const estimated_bytes = @min(cand.snippet.len, FALLBACK_ENTRY_MAX_BYTES) + cand.key.len + 8;
            if (!canAppendToBucket(buf.items.len, fallback_bytes, stats.fallback_bucket_entries, SEARCH_FALLBACK_BUCKET_MAX_BYTES, SEARCH_FALLBACK_BUCKET_MAX_ENTRIES, estimated_bytes)) continue;
            try appendBucketEntry(allocator, &buf, &wrote_header, cand.key, cand.snippet, FALLBACK_ENTRY_MAX_BYTES, &fallback_bytes);
            stats.fallback_bucket_entries += 1;
            stats.fallback_bucket_bytes = fallback_bytes;
            stats.global_fallback_count += 1;
        }
        stats.search_match_count += 1;
        try markSeenKey(allocator, &seen_keys, cand.key);
        if (buf.items.len >= MAX_CONTEXT_BYTES) break;
    }

    if (buf.items.len < MAX_CONTEXT_BYTES and global_keyword_entries != null) {
        if (global_keyword_entries) |entries| {
            for (entries) |entry| {
                if (containsCandidateKey(candidates, entry.key)) continue;
                if (shouldSkipGenericEntry(entry.key, entry.content, summary_latest_key, current_timeline_prefix, has_priority_context)) continue;
                if (containsString(seen_keys.items, entry.key)) continue;
                if (isSemanticContinuityKey(entry.key) and (stats.semantic_bucket_entries < SEMANTIC_BUCKET_MIN_ENTRIES or semantic_bytes < 1600)) {
                    const semantic_estimated = @min(entry.content.len, SEMANTIC_ENTRY_MAX_BYTES) + entry.key.len + 8;
                    if (canAppendToBucket(buf.items.len, semantic_bytes, stats.semantic_bucket_entries, SEMANTIC_BUCKET_MAX_BYTES, null, semantic_estimated)) {
                        try appendBucketEntry(allocator, &buf, &wrote_header, entry.key, entry.content, SEMANTIC_ENTRY_MAX_BYTES, &semantic_bytes);
                        stats.search_match_count += 1;
                        stats.semantic_bucket_entries += 1;
                        stats.semantic_bucket_bytes = semantic_bytes;
                        try markSeenKey(allocator, &seen_keys, entry.key);
                    }
                    continue;
                }
                const estimated_bytes = @min(entry.content.len, FALLBACK_ENTRY_MAX_BYTES) + entry.key.len + 8;
                if (!canAppendToBucket(buf.items.len, fallback_bytes, stats.fallback_bucket_entries, FALLBACK_BUCKET_MAX_BYTES, FALLBACK_BUCKET_MAX_ENTRIES, estimated_bytes)) break;
                try appendBucketEntry(allocator, &buf, &wrote_header, entry.key, entry.content, FALLBACK_ENTRY_MAX_BYTES, &fallback_bytes);
                stats.global_fallback_count += 1;
                stats.fallback_bucket_entries += 1;
                stats.fallback_bucket_bytes = fallback_bytes;
                try markSeenKey(allocator, &seen_keys, entry.key);
                if (buf.items.len >= MAX_CONTEXT_BYTES) break;
            }
        }
    }

    if (buf.items.len < MAX_CONTEXT_BYTES and global_entries != null) {
        if (global_entries) |entries| {
            for (entries) |entry| {
                if (containsCandidateKey(candidates, entry.key)) continue;
                if (global_keyword_entries) |keyword_entries| {
                    if (containsKey(keyword_entries, entry.key)) continue;
                }
                if (shouldSkipGenericEntry(entry.key, entry.content, summary_latest_key, current_timeline_prefix, has_priority_context)) continue;
                if (containsString(seen_keys.items, entry.key)) continue;
                const estimated_bytes = @min(entry.content.len, FALLBACK_ENTRY_MAX_BYTES) + entry.key.len + 8;
                if (!canAppendToBucket(buf.items.len, fallback_bytes, stats.fallback_bucket_entries, FALLBACK_BUCKET_MAX_BYTES, FALLBACK_BUCKET_MAX_ENTRIES, estimated_bytes)) break;
                try appendBucketEntry(allocator, &buf, &wrote_header, entry.key, entry.content, FALLBACK_ENTRY_MAX_BYTES, &fallback_bytes);
                stats.global_fallback_count += 1;
                stats.fallback_bucket_entries += 1;
                stats.fallback_bucket_bytes = fallback_bytes;
                try markSeenKey(allocator, &seen_keys, entry.key);
                if (buf.items.len >= MAX_CONTEXT_BYTES) break;
            }
        }
    }

    if (!wrote_header) return .{ .context = try allocator.dupe(u8, ""), .stats = stats };
    try buf.writer(allocator).writeAll("\n");
    stats.injected = true;
    stats.context_bytes = buf.items.len;

    return .{ .context = try buf.toOwnedSlice(allocator), .stats = stats };
}

pub fn loadContext(
    allocator: std.mem.Allocator,
    mem: Memory,
    user_message: []const u8,
    session_id: ?[]const u8,
) ![]const u8 {
    const result = try loadContextDetailed(allocator, mem, user_message, session_id);
    return result.context;
}

pub fn loadContextWithRuntime(
    allocator: std.mem.Allocator,
    mem: Memory,
    rt: *MemoryRuntime,
    user_message: []const u8,
    session_id: ?[]const u8,
) ![]const u8 {
    const result = try loadContextWithRuntimeDetailed(allocator, mem, rt, user_message, session_id);
    return result.context;
}

// enrichMessage / enrichMessageWithRuntime / enrichMessageWithRuntimeDetailed
// were removed in iter21. Context v2 replaces the "prepend [Memory context]
// to user message" pattern with `loadTurnMemorySlot` which packages memory
// into the volatile portion of the system prompt instead. Production code
// no longer has callers. Use loadTurnMemorySlot in new code.

/// Load memory context for the current turn as a fenced payload for the
/// volatile system block. This is the context-v2 replacement for
/// enrichMessageWithRuntimeDetailed: instead of prepending memory into the
/// user message (which broke byte-stability across turns), we return the
/// memory as a self-contained fenced block that the caller places in
/// PromptContext.memory_slot. The user message remains untouched.
///
/// Returns `fenced_content = ""` when no memory is available for this turn.
/// Otherwise returns `<memory_for_turn>…retrieval payload…</memory_for_turn>`
/// with a trailing newline.
///
/// Preserves all existing retrieval semantics via loadContext* — only the
/// packaging changes.
///
/// **V1.7a-2 (graph mode):** when `state_mgr_for_graph` AND
/// `user_id_for_graph` are both provided AND the env-derived
/// `max_hops > 0` (default 1), an additional `<graph_neighbors>` block is
/// appended inside the same `<memory_for_turn>` wrapping. The block lists
/// 1-hop graph neighbors of the recall seeds that the legacy keyword/
/// vector path would not have surfaced (because they don't textually
/// match the query but ARE graph-connected via memory_edges). The block
/// is bounded to `GRAPH_NEIGHBORS_BLOCK_MAX_BYTES` (1500 bytes) so it
/// can't blow the prompt cache budget. Caller passes `null` for either
/// param to force legacy behavior; `NULLALIS_GRAPH_RECALL_MAX_HOPS=0`
/// also disables (operator-side rollback).
pub fn loadTurnMemorySlot(
    allocator: std.mem.Allocator,
    mem: Memory,
    mem_rt: ?*MemoryRuntime,
    user_message: []const u8,
    session_id: ?[]const u8,
    state_mgr_for_graph: ?*zaki_state.Manager,
    user_id_for_graph: ?i64,
) !MemorySlot {
    var result = if (mem_rt) |rt|
        try loadContextWithRuntimeDetailed(allocator, mem, rt, user_message, session_id)
    else
        try loadContextDetailed(allocator, mem, user_message, session_id);

    // ── V1.7a-2 graph-expand recall consumer ───────────────────────────
    // Append graph_neighbors block when state_mgr + user_id are both
    // present AND max_hops > 0. Falls back silently on any error so
    // graph mode can never make memory injection WORSE than legacy.
    var graph_block: ?[]u8 = null;
    var graph_stats = GraphAppendResult{};
    if (state_mgr_for_graph) |sm| if (user_id_for_graph) |uid| {
        const max_hops = readGraphRecallMaxHops();
        graph_stats.max_hops_resolved = max_hops;
        if (max_hops > 0) {
            graph_block = buildGraphNeighborsBlock(
                allocator,
                sm,
                uid,
                user_message,
                session_id,
                max_hops,
                &graph_stats,
            ) catch |err| blk: {
                log.warn("graph_recall.append_failed err={s} — keeping legacy memory_for_turn", .{@errorName(err)});
                break :blk null;
            };
        }
    };
    defer if (graph_block) |g| allocator.free(g);

    // Merge graph stats into the carried SelectionStats.
    result.stats.graph_recall_active = graph_stats.appended;
    result.stats.graph_recall_seed_count = graph_stats.seed_count;
    result.stats.graph_recall_neighbor_count = graph_stats.neighbor_count;
    result.stats.graph_recall_appended_bytes = graph_stats.appended_bytes;
    result.stats.graph_recall_max_hops = graph_stats.max_hops_resolved;

    // If both legacy + graph are empty, return empty slot (no fence).
    const has_legacy = result.context.len > 0;
    const has_graph = if (graph_block) |g| g.len > 0 else false;
    if (!has_legacy and !has_graph) {
        allocator.free(result.context);
        return .{
            .fenced_content = try allocator.dupe(u8, ""),
            .stats = result.stats,
        };
    }

    defer allocator.free(result.context);
    const graph_payload: []const u8 = if (graph_block) |g| g else "";
    const fenced = if (has_graph)
        try std.fmt.allocPrint(
            allocator,
            "<memory_for_turn>\n{s}{s}</memory_for_turn>\n",
            .{ result.context, graph_payload },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "<memory_for_turn>\n{s}</memory_for_turn>\n",
            .{result.context},
        );
    return .{
        .fenced_content = fenced,
        .stats = result.stats,
    };
}

// ── V1.7a-2 graph-expand recall consumer helpers ──────────────────────────

/// Internal accumulator passed by-pointer into `buildGraphNeighborsBlock`
/// so the outer `loadTurnMemorySlot` can pull telemetry into SelectionStats.
const GraphAppendResult = struct {
    appended: bool = false,
    seed_count: usize = 0,
    neighbor_count: usize = 0,
    appended_bytes: usize = 0,
    max_hops_resolved: u8 = 0,
};

/// Read `NULLALIS_GRAPH_RECALL_MAX_HOPS` env override; default
/// `DEFAULT_GRAPH_RECALL_MAX_HOPS` (1) when unset or unparseable.
/// Operator-side rollback knob: set to "0" to disable graph mode.
/// Capped at 3 — we never want unbounded BFS in a hot retrieval path.
fn readGraphRecallMaxHops() u8 {
    const raw = std.posix.getenv("NULLALIS_GRAPH_RECALL_MAX_HOPS") orelse return DEFAULT_GRAPH_RECALL_MAX_HOPS;
    const parsed = std.fmt.parseInt(u8, raw, 10) catch return DEFAULT_GRAPH_RECALL_MAX_HOPS;
    return @min(parsed, 3);
}

/// Build the `<graph_neighbors>` block for the current turn.
///
/// Runs `graph_expand.recallMemoriesAsGraph` with the configured
/// max_hops, then formats only the NON-SEED nodes (1+ hop neighbors)
/// into a bounded text block. Seeds themselves are intentionally
/// omitted — the legacy semantic/fallback buckets already cover them
/// via direct keyword/vector recall, and including them again would
/// duplicate content.
///
/// Per-neighbor lookup uses `state_mgr.getMemory` once per key. With
/// `DEFAULT_GRAPH_RECALL_MAX_NODES_PER_HOP=20` and `max_hops=1`, that's
/// ≤20 round trips per turn. If profiling shows this is hot, replace
/// with a `getMemoriesByKeys` batch helper (out-of-scope for this commit).
///
/// Returns an empty slice (caller must still free it) when no neighbors
/// were found or the block would have been empty after dedup vs seeds.
fn buildGraphNeighborsBlock(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    user_message: []const u8,
    session_id: ?[]const u8,
    max_hops: u8,
    out_stats: *GraphAppendResult,
) ![]u8 {
    const recall = try graph_expand.recallMemoriesAsGraph(
        allocator,
        state_mgr,
        user_id,
        user_message,
        DEFAULT_GRAPH_RECALL_SEEDS,
        .{
            .max_hops = max_hops,
            .max_nodes_per_hop = DEFAULT_GRAPH_RECALL_MAX_NODES_PER_HOP,
        },
        session_id,
    );
    defer recall.deinit(allocator);

    out_stats.seed_count = recall.seeds.len;
    if (recall.neighborhood.nodes.len == 0) return allocator.alloc(u8, 0);

    // Build a seed-key set for dedup (we only emit NON-SEED nodes).
    var seed_set: std.StringHashMapUnmanaged(void) = .{};
    defer seed_set.deinit(allocator);
    for (recall.seeds) |s| try seed_set.put(allocator, s.key, {});

    // For each non-seed node, find an edge that connects it to a seed
    // (so we can show the predicate + via-key context). If multiple edges
    // exist, the first match in `recall.neighborhood.edges` wins (already
    // sorted by weight DESC inside expandFromSeeds).
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("<graph_neighbors source=\"graph_expand\" hops=\"");
    try w.print("{d}", .{max_hops});
    try w.writeAll("\">\n");
    var emitted: usize = 0;
    for (recall.neighborhood.nodes) |node| {
        if (node.hop_distance == 0) continue; // seeds covered elsewhere
        if (seed_set.contains(node.key)) continue; // belt-and-suspenders dedup
        if (buf.items.len >= GRAPH_NEIGHBORS_BLOCK_MAX_BYTES) break;

        // Find a connecting edge (any edge incident to this node where
        // the OTHER endpoint is a seed).
        var via_seed: ?[]const u8 = null;
        var via_predicate: ?[]const u8 = null;
        for (recall.neighborhood.edges) |e| {
            if (std.mem.eql(u8, e.source_key, node.key) and seed_set.contains(e.target_key)) {
                via_seed = e.target_key;
                via_predicate = e.predicate;
                break;
            } else if (std.mem.eql(u8, e.target_key, node.key) and seed_set.contains(e.source_key)) {
                via_seed = e.source_key;
                via_predicate = e.predicate;
                break;
            }
        }
        // No connecting edge to any seed → skip (might be a 2-hop node;
        // we don't emit those in the v1 ship to keep the block focused).
        if (via_seed == null or via_predicate == null) continue;

        // Fetch content for this neighbor key (one round trip per neighbor).
        const entry_opt = state_mgr.getMemory(allocator, user_id, node.key) catch null;
        if (entry_opt) |entry| {
            defer entry.deinit(allocator);
            const trimmed = truncateUtf8(std.mem.trim(u8, entry.content, " \t\n\r"), GRAPH_NEIGHBOR_CONTENT_MAX_BYTES);
            // Format: one line per neighbor for easy LLM scanning.
            try w.print(
                "neighbor_key={s} predicate={s} via={s} content={s}\n",
                .{ node.key, via_predicate.?, via_seed.?, trimmed },
            );
            emitted += 1;
        } else {
            // Lookup failed (key vanished mid-flight) — emit a stub so the
            // edge isn't silently dropped from the agent's view.
            try w.print(
                "neighbor_key={s} predicate={s} via={s} content=<unavailable>\n",
                .{ node.key, via_predicate.?, via_seed.? },
            );
            emitted += 1;
        }
    }

    // If nothing was emitted, drop the header too (no point in an empty block).
    if (emitted == 0) {
        buf.deinit(allocator);
        return allocator.alloc(u8, 0);
    }

    try w.writeAll("</graph_neighbors>\n");
    out_stats.neighbor_count = emitted;
    // Telemetry intent: "how many bytes did graph mode add to the volatile
    // prompt slot?" — full block (header + body + closing tag) is the
    // honest answer. Earlier draft subtracted a body-only cursor and
    // undercounted by ~70B which broke downstream prompt-cache budgeting.
    out_stats.appended_bytes = buf.items.len;
    out_stats.appended = true;
    return buf.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "loadContext returns empty for no-op memory" {
    const allocator = std.testing.allocator;
    var none_mem = memory_mod.NoneMemory.init();
    const mem = none_mem.memory();

    const context = try loadContext(allocator, mem, "hello", null);
    defer allocator.free(context);

    try std.testing.expectEqualStrings("", context);
}

test "loadContext with session_id includes global entries but not other sessions" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("sess_a_fact", "session A favorite", .core, "sess-a");
    try mem.store("global_fact", "global favorite", .core, null);
    try mem.store("sess_b_fact", "session B favorite", .core, "sess-b");

    const context = try loadContext(allocator, mem, "favorite", "sess-a");
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "sess_a_fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "global_fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "sess_b_fact") == null);
}

test "loadContext prefers current-session summary latest without injecting anchor" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "summary_latest/agent:zaki-bot:user:1:main",
        "type=summary_latest\nsession=agent:zaki-bot:user:1:main\nfocus: shipping readiness\ndecisions:\n- keep summaries compact\nopen_loops:\n- validate recall\nnext:\n- ship\n",
        .core,
        null,
    );
    try mem.store(
        "context_anchor_current",
        "type=context_anchor\nlast_session=agent:zaki-bot:user:1:main\nlast_summary_key=timeline_summary/agent:zaki-bot:user:1:main/1774400000\nlast_at=2026-03-25T00:00:00Z",
        .core,
        null,
    );
    try mem.store("session_fact", "current lane detail", .conversation, "agent:zaki-bot:user:1:main");

    const context = try loadContext(allocator, mem, "validate shipping", "agent:zaki-bot:user:1:main");
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "summary_latest/agent:zaki-bot:user:1:main") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "shipping readiness") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "context_anchor_current") == null);
}

test "loadContext includes bounded global timeline summaries from other sessions" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "summary_latest/agent:zaki-bot:user:1:main",
        "type=summary_latest\nsession=agent:zaki-bot:user:1:main\nfocus: current work\ndecisions:\n- none\nopen_loops:\n- none\nnext:\n- continue\n",
        .core,
        null,
    );
    try mem.store("timeline_summary/agent:zaki-bot:user:1:telegram/1", "focus: shipping telegram shipping handoff\n\ndecisions:\n- plan rollout\nopen_loops:\n- verify reply latency\nnext:\n- continue on app", .daily, null);
    try mem.store("timeline_summary/agent:zaki-bot:user:1:other/2", "focus: shipping other channel shipping alignment\n\ndecisions:\n- align settings\nopen_loops:\n- none\nnext:\n- move forward", .daily, null);
    try mem.store("timeline_summary/agent:zaki-bot:user:1:third/3", "focus: unrelated archive thread\n\ndecisions:\n- none\nopen_loops:\n- none\nnext:\n- none", .daily, null);

    const context = try loadContext(allocator, mem, "shipping", "agent:zaki-bot:user:1:main");
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "timeline_summary/agent:zaki-bot:user:1:telegram/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "timeline_summary/agent:zaki-bot:user:1:other/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "timeline_summary/agent:zaki-bot:user:1:third/3") == null);
}

test "loadContext skips checkpoint style entries when summary context exists" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "summary_latest/agent:zaki-bot:user:1:main",
        "type=summary_latest\nsession=agent:zaki-bot:user:1:main\nfocus: compact continuity\ndecisions:\n- prefer summaries\nopen_loops:\n- none\nnext:\n- continue\n",
        .core,
        null,
    );
    try mem.store("session_checkpoint_1774400000", "type=session_checkpoint\nrecent_user:\n- shipping\n", .daily, null);

    const context = try loadContext(allocator, mem, "shipping", "agent:zaki-bot:user:1:main");
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "summary_latest/agent:zaki-bot:user:1:main") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "session_checkpoint_1774400000") == null);
}

test "loadContext ignores session_summary artifacts on the normal prompt path" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "session_summary/agent:zaki-bot:user:1:main/1774400000",
        "origin_channel=app\norigin_lane=main\n\nfocus: audit-only recap\ndecisions:\n- keep canonical latest separate\nopen_loops:\n- none\nnext:\n- continue\n",
        .conversation,
        "agent:zaki-bot:user:1:main",
    );

    const context = try loadContext(allocator, mem, "recap", "agent:zaki-bot:user:1:main");
    defer allocator.free(context);

    try std.testing.expectEqualStrings("", context);
}

test "loadContext prefers canonical continuity and ignores session_summary compatibility artifacts" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "summary_latest/agent:zaki-bot:user:1:main",
        "type=summary_latest\nsession=agent:zaki-bot:user:1:main\nfocus: canonical continuity\ndecisions:\n- trust summary_latest\nopen_loops:\n- none\nnext:\n- continue\n",
        .core,
        null,
    );
    try mem.store(
        "session_summary/agent:zaki-bot:user:1:main/1774400000",
        "origin_channel=app\norigin_lane=main\n\nfocus: stale compatibility recap\ndecisions:\n- should stay out of prompt loading\nopen_loops:\n- none\nnext:\n- none\n",
        .conversation,
        "agent:zaki-bot:user:1:main",
    );

    const context = try loadContext(allocator, mem, "continuity", "agent:zaki-bot:user:1:main");
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "summary_latest/agent:zaki-bot:user:1:main") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "canonical continuity") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "session_summary/agent:zaki-bot:user:1:main/1774400000") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "stale compatibility recap") == null);
}

test "truncateUtf8 does not split multi-byte sequences" {
    // ASCII-only: truncation at limit
    try std.testing.expectEqualStrings("abc", truncateUtf8("abcdef", 3));

    // Under limit: returns as-is
    try std.testing.expectEqualStrings("ab", truncateUtf8("ab", 10));

    // 2-byte char at boundary: "aaa" (3 bytes) + "Й" (D0 99 = 2 bytes)
    const s2 = "aaa\xd0\x99";
    // Limit 4: byte 4 is 0x99 (continuation), back up to 3 which is 0xD0 (leading) -> [0..3]
    try std.testing.expectEqualStrings("aaa", truncateUtf8(s2, 4));
    // Limit 5: full string fits exactly
    try std.testing.expectEqualStrings(s2, truncateUtf8(s2, 5));

    // 3-byte char "中" (E4 B8 AD) at boundary
    const s3 = "aa\xe4\xb8\xad";
    // Limit 3: byte 3 is 0xB8 (continuation), back to 2 -> 0xE4 (leading) -> [0..2]
    try std.testing.expectEqualStrings("aa", truncateUtf8(s3, 3));
    // Limit 4: byte 4 is 0xAD (continuation), back to 3 -> 0xB8 (continuation), back to 2 -> 0xE4 (leading) -> [0..2]
    try std.testing.expectEqualStrings("aa", truncateUtf8(s3, 4));

    // 4-byte emoji U+1F600 (F0 9F 98 80)
    const s4 = "a\xf0\x9f\x98\x80";
    // Limit 2: byte 2 is 0x9F (continuation), back to 1 -> 0xF0 (leading) -> [0..1]
    try std.testing.expectEqualStrings("a", truncateUtf8(s4, 2));

    // All results should be valid UTF-8
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncateUtf8(s2, 4)));
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncateUtf8(s3, 3)));
    try std.testing.expect(std.unicode.utf8ValidateSlice(truncateUtf8(s4, 2)));
}

test "isSemanticContinuityKey covers all warm continuity families (V1.5.5 polish)" {
    // V1.5.5 polish: compaction Pass C archives at compaction_summary/{s}/{ts}
    // (compaction.zig:535). Without this test, regressions to the predicate
    // would silently demote compaction summaries from warm-bucket retrieval
    // back to generic vector scoring.
    //
    // ── Should be warm-continuity (returns true) ──────────────────────
    try std.testing.expect(isSemanticContinuityKey("durable_fact/1714521600/0"));
    try std.testing.expect(isSemanticContinuityKey("timeline_summary/agent:zaki-bot:user:1:thread:main/1714521600"));
    try std.testing.expect(isSemanticContinuityKey("summary_latest/agent:zaki-bot:user:1:thread:main"));
    try std.testing.expect(isSemanticContinuityKey("compaction_summary/agent:zaki-bot:user:1:thread:main/1714521600"));
    // iter29 sibling families: summary_fallback/* and compaction_dropped/*
    // are also continuity per memory_root.classifyArtifactKey:498-502.
    try std.testing.expect(isSemanticContinuityKey("summary_fallback/agent:zaki-bot:user:1:thread:main/1714521600"));
    try std.testing.expect(isSemanticContinuityKey("compaction_dropped/agent:zaki-bot:user:1:thread:main/1714521600"));

    // ── Should NOT be warm-continuity (returns false) ─────────────────
    // User-authored memories — never warm-bucket via this path
    try std.testing.expect(!isSemanticContinuityKey("user_lang"));
    try std.testing.expect(!isSemanticContinuityKey("favorite_snack"));
    try std.testing.expect(!isSemanticContinuityKey("compose:0123456789abcdef"));
    // Audit family — explicitly demoted from continuity
    try std.testing.expect(!isSemanticContinuityKey("autosave_user_1714521600"));
    try std.testing.expect(!isSemanticContinuityKey("session_checkpoint_1714521600"));
    try std.testing.expect(!isSemanticContinuityKey("audit_shell/1714521600"));
    // Index family
    try std.testing.expect(!isSemanticContinuityKey("timeline_index/current"));
    // Internal anchors / tombstones / bootstrap
    try std.testing.expect(!isSemanticContinuityKey("context_anchor_current"));
    try std.testing.expect(!isSemanticContinuityKey("__tombstone__/anything"));
    try std.testing.expect(!isSemanticContinuityKey("__bootstrap.prompt.AGENTS.md"));
    try std.testing.expect(!isSemanticContinuityKey("last_hygiene_at"));
}

test "loadTurnMemorySlot returns empty when no memory available" {
    const allocator = std.testing.allocator;
    var none_mem = memory_mod.NoneMemory.init();
    const mem = none_mem.memory();

    const slot = try loadTurnMemorySlot(allocator, mem, null, "hello world", null, null, null);
    defer allocator.free(slot.fenced_content);

    try std.testing.expectEqualStrings("", slot.fenced_content);
}

test "loadTurnMemorySlot fences retrieved memory with markers (context v2 packaging)" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("user_lang", "Zig is the favorite language", .core, null);

    const slot = try loadTurnMemorySlot(allocator, mem, null, "language", null, null, null);
    defer allocator.free(slot.fenced_content);

    // Context v2: payload wrapped in <memory_for_turn>...</memory_for_turn> —
    // the retrieval body is unchanged (still [Memory context] header) but
    // it now lives inside the fence instead of being prepended to the user
    // message. Placement in the volatile system block, not the user turn.
    try std.testing.expect(std.mem.startsWith(u8, slot.fenced_content, "<memory_for_turn>\n"));
    try std.testing.expect(std.mem.endsWith(u8, slot.fenced_content, "</memory_for_turn>\n"));
    try std.testing.expect(std.mem.indexOf(u8, slot.fenced_content, "user_lang") != null);
    try std.testing.expect(std.mem.indexOf(u8, slot.fenced_content, "Zig is the favorite language") != null);
}

test "loadTurnMemorySlot reports selection stats (context v2 packaging)" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "summary_latest/agent:zaki-bot:user:1:main",
        "type=summary_latest\nfocus: shipping readiness\n",
        .core,
        null,
    );
    try mem.store(
        "context_anchor_current",
        "type=context_anchor\nlast_session=agent:zaki-bot:user:1:main\n",
        .core,
        null,
    );
    try mem.store("durable_fact/shipping_pref", "shipping updates should stay concise", .core, null);
    try mem.store("session_fact", "current lane detail", .conversation, "agent:zaki-bot:user:1:main");

    const slot = try loadTurnMemorySlot(
        allocator,
        mem,
        null,
        "shipping",
        "agent:zaki-bot:user:1:main",
        null,
        null,
    );
    defer allocator.free(slot.fenced_content);

    try std.testing.expect(slot.stats.available);
    try std.testing.expect(slot.stats.injected);
    try std.testing.expect(slot.stats.summary_latest_used);
    try std.testing.expect(!slot.stats.context_anchor_used);
    try std.testing.expect(slot.stats.durable_fact_count >= 1);
    try std.testing.expect(slot.stats.continuity_bucket_entries >= 1);
    try std.testing.expect(slot.stats.semantic_bucket_entries >= 1);
    try std.testing.expect(slot.stats.context_bytes > 0);
    try std.testing.expect(std.mem.startsWith(u8, slot.fenced_content, "<memory_for_turn>\n"));
    try std.testing.expect(std.mem.indexOf(u8, slot.fenced_content, "context_anchor_current") == null);
}

test "global keyword fallback pulls cross-session entries when exact global recall misses punctuation variant" {
    const allocator = std.testing.allocator;

    var mem_impl = memory_mod.InMemoryLruMemory.init(allocator, 32);
    defer mem_impl.deinit();
    const mem = mem_impl.memory();

    try mem.store("telegram_current", "ALEX from HRS?", .conversation, "agent:zaki-bot:user:1:thread:telegram");
    try mem.store("main_alex", "ALEX from HRS", .conversation, "agent:zaki-bot:user:1:thread:main");
    try mem.store("main_hrs", "HRS said yes on the 30GB deal", .conversation, "agent:zaki-bot:user:1:thread:main");

    const exact_global = try mem.recall(allocator, "ALEX from HRS?", 16, null);
    defer memory_mod.freeEntries(allocator, exact_global);
    try std.testing.expectEqual(@as(usize, 1), exact_global.len);
    try std.testing.expectEqualStrings("telegram_current", exact_global[0].key);

    const fallback = try loadGlobalKeywordFallbackEntries(
        allocator,
        mem,
        "ALEX from HRS?",
        16,
        "agent:zaki-bot:user:1:thread:telegram",
    );
    defer memory_mod.freeEntries(allocator, fallback);

    try std.testing.expect(containsKey(fallback, "main_alex"));
    try std.testing.expect(containsKey(fallback, "main_hrs"));
    try std.testing.expect(!containsKey(fallback, "telegram_current"));
}

test "loadContextWithRuntime caps visible warm matches while overfetching raw candidates" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var idx: usize = 0;
    while (idx < 12) : (idx += 1) {
        const key = try std.fmt.allocPrint(allocator, "warm_fact_{d}", .{idx});
        defer allocator.free(key);
        const content = try std.fmt.allocPrint(allocator, "shipping memory result {d}", .{idx});
        defer allocator.free(content);
        try mem.store(key, content, .core, null);
    }

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .conversation_retention_days = 0,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };

    const slot = try loadTurnMemorySlot(allocator, mem, &rt, "shipping memory", null, null, null);
    defer allocator.free(slot.fenced_content);

    try std.testing.expectEqual(@as(usize, 12), slot.stats.candidate_count);
    try std.testing.expect(slot.stats.search_match_count >= 2);
    try std.testing.expect(slot.stats.search_match_count <= SEARCH_FALLBACK_BUCKET_MAX_ENTRIES);
    try std.testing.expect(slot.stats.fallback_bucket_entries <= SEARCH_FALLBACK_BUCKET_MAX_ENTRIES);
    try std.testing.expectEqual(slot.stats.fallback_bucket_entries, slot.stats.global_fallback_count);

    var recalled_lines: usize = 0;
    var iter = std.mem.splitScalar(u8, slot.fenced_content, '\n');
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "- warm_fact_")) recalled_lines += 1;
    }
    try std.testing.expect(recalled_lines >= 2);
    try std.testing.expect(recalled_lines <= SEARCH_FALLBACK_BUCKET_MAX_ENTRIES);
}

test "loadContext keeps non-runtime fallback on the small bucket" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "summary_latest/agent:test:user:1:main",
        "focus: active thread",
        .core,
        null,
    );

    for (0..8) |i| {
        const key = try std.fmt.allocPrint(allocator, "raw_note_{d}", .{i});
        defer allocator.free(key);
        const content = try std.fmt.allocPrint(allocator, "shipping raw recall note {d}", .{i});
        defer allocator.free(content);
        try mem.store(key, content, .conversation, "agent:test:user:1:main");
    }

    const result = try loadContextDetailed(allocator, mem, "shipping raw recall", "agent:test:user:1:main");
    defer allocator.free(result.context);

    try std.testing.expect(result.stats.fallback_bucket_entries <= FALLBACK_BUCKET_MAX_ENTRIES);

    var recalled_lines: usize = 0;
    var iter = std.mem.splitScalar(u8, result.context, '\n');
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "- raw_note_")) recalled_lines += 1;
    }
    try std.testing.expect(recalled_lines <= FALLBACK_BUCKET_MAX_ENTRIES);
}

test "loadContext filters internal autosave and hygiene entries" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("autosave_user_1", "привет", .conversation, null);
    try mem.store("autosave_assistant_1", "Stored memory: autosave_user_1", .conversation, null);
    try mem.store("last_hygiene_at", "1772051598", .core, null);
    try mem.store("user_language", "Отвечай на русском языке", .core, null);

    const context = try loadContext(allocator, mem, "русском", null);
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "user_language") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "autosave_user_") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "autosave_assistant_") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "last_hygiene_at") == null);
}

test "loadContext filters audit and index artifacts" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("session_checkpoint_1", "type=session_checkpoint\nrecent_user:\n- shipping\n", .daily, null);
    try mem.store("timeline_index/current", "{\"session\":\"agent:zaki-bot:user:1:main\"}", .core, null);
    try mem.store("timeline_summary/agent:zaki-bot:user:1:other/1", "focus: shipping rollout", .daily, null);

    const context = try loadContext(allocator, mem, "shipping", "agent:zaki-bot:user:1:main");
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "timeline_summary/agent:zaki-bot:user:1:other/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "session_checkpoint_1") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "timeline_index/current") == null);
}

test "loadContext filters markdown-encoded internal entries" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    // Markdown backend can include encoded keys in content.
    try mem.store("raw_entry", "**last_hygiene_at**: 1772051598", .core, null);
    try mem.store("user_name", "User", .core, null);

    const context = try loadContext(allocator, mem, "User", null);
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "last_hygiene_at") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "user_name") != null);
}

test "loadContextWithRuntime filters markdown line keys" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("MEMORY:8", "Name: ZAKI BOT", .core, null);
    try mem.store("user_alias", "ZAKI BOT", .core, null);

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .conversation_retention_days = 0,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };

    const context = try loadContextWithRuntime(allocator, mem, &rt, "ZAKI", null);
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "MEMORY:8") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "user_alias") != null);
}

test "loadContext filters bootstrap prompt internal keys" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("__bootstrap.prompt.SOUL.md", "persona-internal", .core, null);
    try mem.store("user_goal", "ship reliable builds", .core, null);

    const context = try loadContext(allocator, mem, "ship", null);
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "user_goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "__bootstrap.prompt.SOUL.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "persona-internal") == null);
}

test "loadContextWithRuntime returns empty when only internal entries match" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("autosave_user_1", "привет", .conversation, null);
    try mem.store("autosave_assistant_1", "Stored memory: autosave_user_1", .conversation, null);
    try mem.store("last_hygiene_at", "1772051598", .core, null);

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .conversation_retention_days = 0,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };

    const context = try loadContextWithRuntime(allocator, mem, &rt, "привет", null);
    defer allocator.free(context);
    try std.testing.expectEqualStrings("", context);
}

test "loadContextWithRuntime overfetches past internal candidate pollution" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("visible_alex_fact", "alexsignal saturday recap: Alex from HRS came up earlier", .core, null);
    for (0..20) |i| {
        const key = try std.fmt.allocPrint(allocator, "autosave_user_{d}", .{i});
        defer allocator.free(key);
        const content = try std.fmt.allocPrint(allocator, "alexsignal autosave noise {d}", .{i});
        defer allocator.free(content);
        try mem.store(key, content, .conversation, null);
    }

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .conversation_retention_days = 0,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };

    const result = try loadContextWithRuntimeDetailed(allocator, mem, &rt, "alexsignal saturday", null);
    defer allocator.free(result.context);

    try std.testing.expect(result.stats.candidate_count > config_types.DEFAULT_MEMORY_ENRICH_RECALL_LIMIT);
    try std.testing.expectEqual(@as(usize, 1), result.stats.search_match_count);
    try std.testing.expect(std.mem.indexOf(u8, result.context, "visible_alex_fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.context, "autosave_user_") == null);
}

test "loadContextWithRuntime keeps semantic continuity candidates when priority context exists" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "summary_latest/agent:test:user:1:main",
        "focus: current thread continuity",
        .core,
        null,
    );
    try mem.store(
        "context_anchor_current",
        "type=context_anchor\nlast_session=agent:test:user:1:main\n",
        .core,
        null,
    );
    try mem.store(
        "timeline_summary/agent:test:user:1:other/1",
        "focus: Alex from HRS owns the 30GB project",
        .daily,
        null,
    );
    try mem.store(
        "durable_fact/hrs_contact",
        "Alex is the HRS contact for the 30GB project",
        .core,
        null,
    );

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .conversation_retention_days = 0,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };

    const result = try loadContextWithRuntimeDetailed(allocator, mem, &rt, "Alex 30GB project", "agent:test:user:1:main");
    defer allocator.free(result.context);

    try std.testing.expect(result.stats.summary_latest_used);
    try std.testing.expect(!result.stats.context_anchor_used);
    try std.testing.expect(result.stats.semantic_bucket_entries >= 2);
    try std.testing.expect(std.mem.indexOf(u8, result.context, "timeline_summary/agent:test:user:1:other/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.context, "durable_fact/hrs_contact") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.context, "context_anchor_current") == null);
}

test "loadContextWithRuntime keeps valid debug-key memories and filters known troubleshooting noise" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("user_debug_note", "debug checklist: Alex still owns the 30GB project", .conversation, null);
    try mem.store("pipeline_noise", "semantic recall returns nothing for this broken test case", .conversation, null);

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .conversation_retention_days = 0,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };

    const result = try loadContextWithRuntimeDetailed(allocator, mem, &rt, "Alex 30GB debug checklist", null);
    defer allocator.free(result.context);

    try std.testing.expect(std.mem.indexOf(u8, result.context, "user_debug_note") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.context, "pipeline_noise") == null);
}

test "loadContextWithRuntime caps fallback bucket and preserves semantic budget" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "summary_latest/agent:test:user:1:main",
        "focus: active thread",
        .core,
        null,
    );
    try mem.store(
        "timeline_summary/agent:test:user:1:other/1",
        "focus: 30GB export project with Alex",
        .daily,
        null,
    );
    try mem.store(
        "durable_fact/project_owner",
        "Alex owns the 30GB export delivery",
        .core,
        null,
    );
    try mem.store(
        "summary_latest/agent:test:user:1:other",
        "focus: HRS 30GB project remains active",
        .core,
        null,
    );

    for (0..8) |i| {
        const key = try std.fmt.allocPrint(allocator, "fallback_note_{d}", .{i});
        defer allocator.free(key);
        const content = try std.fmt.allocPrint(allocator, "30GB generic fallback note {d}", .{i});
        defer allocator.free(content);
        try mem.store(key, content, .conversation, null);
    }

    const resolved = memory_mod.ResolvedConfig{
        .primary_backend = "test",
        .retrieval_mode = "keyword",
        .vector_mode = "none",
        .embedding_provider = "none",
        .rollout_mode = "off",
        .vector_sync_mode = "best_effort",
        .hygiene_enabled = false,
        .conversation_retention_days = 0,
        .snapshot_enabled = false,
        .cache_enabled = false,
        .semantic_cache_enabled = false,
        .summarizer_enabled = false,
        .source_count = 0,
        .fallback_policy = "degrade",
    };
    var rt = memory_mod.MemoryRuntime{
        .memory = mem,
        .session_store = null,
        .response_cache = null,
        .capabilities = .{
            .supports_keyword_rank = false,
            .supports_session_store = false,
            .supports_transactions = false,
            .supports_outbox = false,
        },
        .resolved = resolved,
        ._db_path = null,
        ._cache_db_path = null,
        ._engine = null,
        ._allocator = allocator,
    };

    const result = try loadContextWithRuntimeDetailed(allocator, mem, &rt, "30GB Alex project", "agent:test:user:1:main");
    defer allocator.free(result.context);

    try std.testing.expect(result.stats.semantic_bucket_entries >= 2);
    try std.testing.expect(result.stats.semantic_bucket_bytes >= 1);
    try std.testing.expect(result.stats.fallback_bucket_entries <= SEARCH_FALLBACK_BUCKET_MAX_ENTRIES);
    try std.testing.expect(result.stats.fallback_bucket_bytes <= FALLBACK_BUCKET_MAX_BYTES);
    try std.testing.expect(std.mem.indexOf(u8, result.context, "timeline_summary/agent:test:user:1:other/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.context, "durable_fact/project_owner") != null);
}
