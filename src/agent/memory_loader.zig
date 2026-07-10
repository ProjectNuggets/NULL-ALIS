const std = @import("std");
const config_types = @import("../config_types.zig");
const memory_mod = @import("../memory/root.zig");
const multimodal = @import("../multimodal.zig");
const zaki_state = @import("../zaki_state.zig");
const graph_expand = @import("graph_expand.zig");
const text_norm = @import("../memory/text_norm.zig");
const learning = @import("learning.zig");
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
// `NULLALIS_GRAPH_RECALL_MAX_HOPS` (default 2 — see V1.14.11 below) is
// non-zero, an additional `<graph_neighbors>` block is appended to the
// memory_for_turn slot. This block lists hop-1+ neighbors of the recall
// seeds that the legacy keyword/vector recall would NOT have surfaced
// (because they don't textually match the query, but they are graph-
// connected to a seed that does).
//
// `max_hops=0` disables graph-mode entirely (legacy behavior — strict
// backward compat). Operators set the env to 0 to roll back if needed.
//
// V1.14.11 (Phase 3 R3 — Cat 3 multi-hop uplift). Default raised from
// 1 → 2. LoCoMo Cat 3 (temporal/inference) often needs friend-of-
// friend reach: "Mia mentioned a place; what cuisine does she like?"
// requires Mia → mentioned_place (hop 1) → cuisine_type (hop 2).
// At hop=1 we got only one of those bridges. The cost is bounded:
// max_nodes_per_hop=20 caps the depth-2 frontier at ~40 nodes,
// ~80 edges = 2 SQL round trips per turn. Block size unchanged
// (1500 byte cap → still ~6-10 neighbors in the prompt; the cap
// just gives the scorer a richer pool to pick from).
const DEFAULT_GRAPH_RECALL_MAX_HOPS: u8 = 2;
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
    /// P4 — candidates blocked by the tier gate (score < NULLALIS_TIER_GATE_MIN_SCORE).
    /// 0 when gate is disabled (default) or no candidates were filtered.
    tier_gated_count: usize = 0,
    context_bytes: usize = 0,
    injected: bool = false,
    // V1.7a-2 — graph-expand recall consumer telemetry.
    graph_recall_active: bool = false,
    graph_recall_seed_count: usize = 0,
    graph_recall_neighbor_count: usize = 0,
    graph_recall_appended_bytes: usize = 0,
    graph_recall_max_hops: u8 = 0,
    // V1.8-9 — active_identity pin telemetry. Mirrors graph_recall_*
    // shape so /agent/turn_audit + diagnostics surfaces can report
    // pin coverage per turn alongside other warm-context blocks.
    identity_pin_active: bool = false,
    identity_pin_fact_count: usize = 0,
    identity_pin_appended_bytes: usize = 0,
    // Phase 0.5 typed-view injection telemetry. True when at least one
    // of the four typed-view blocks (preferences / open_loops / decisions
    // / people) produced a non-empty fenced block. item_count and
    // appended_bytes are the aggregate across all four builders so
    // operators can measure typed-view coverage per turn in turn_audit.
    typed_views_active: bool = false,
    typed_views_item_count: usize = 0,
    typed_views_appended_bytes: usize = 0,
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

/// `pub`: test surface for `telos_contract_test.zig` — pins the
/// `durable_fact/telos/*` namespace against this recognizer (contract enforcement map).
pub fn isDurableFactKey(key: []const u8) bool {
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

/// Package 2a Task 2 — the learning contract's trust ladder gate
/// (inv. 1, 3, 7): SHADOW IS NEVER INJECTED. A durable_fact/behavior/
/// entry is skipped from priority injection when its stored content
/// carries an explicit `state=shadow` metadata header (learning.zig's
/// storeLearnedFact writes this for every origin except
/// user_correction/operator — the birth-state law).
///
/// Two other shapes both pass through (return false, i.e. "not shadow,
/// inject normally"):
///   - Non-behavior durable_fact/ keys (e.g. durable_fact/shipping_pref)
///     — outside the learning contract's scope entirely; this gate must
///     never touch facts that were never learning-contract artifacts.
///   - durable_fact/behavior/ entries with NO metadata header at all
///     (the legacy shape — exactly what the pre-Task-2 and still-
///     unmodified user_correction fast path in root.zig writes today).
///     Grandfathered as active per the brief: "facts without metadata =
///     legacy = active."
fn isShadowBehaviorFact(key: []const u8, content: []const u8) bool {
    if (!std.mem.startsWith(u8, key, "durable_fact/behavior/")) return false;
    const header = learning.parseLearnedMetadataHeader(content);
    return header.state == .shadow;
}

/// Package 2a Task 4 — "retired hygiene": a dismissed suggestion
/// (`/learn dismiss`, state=retired) must NEVER be injected, exactly like
/// a shadow draft. `isShadowBehaviorFact` above stays narrowly named/scoped
/// (state == .shadow only — its own unit test pins that meaning), so every
/// injection gate site uses THIS wider predicate instead: shadow OR
/// retired, never active/legacy. Same key-prefix scoping and grandfather
/// clause as isShadowBehaviorFact (legacy/non-behavior content passes
/// through untouched).
fn isRetiredOrShadowBehaviorFact(key: []const u8, content: []const u8) bool {
    if (!std.mem.startsWith(u8, key, "durable_fact/behavior/")) return false;
    const header = learning.parseLearnedMetadataHeader(content);
    return header.state == .shadow or header.state == .retired;
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

/// Task 4 (Loop-1 consumer, package1-activations) — find the most recent
/// nightly dream-cycle reflection. The dream cycle writes to
/// `dream_log/<YYYY-MM-DD>` (see the nightly job); nothing consumed those
/// keys before this — a write-only organ. This is the first reader.
///
/// Dates sort lexicographically the same as chronologically (YYYY-MM-DD),
/// so "lexicographic max across dream_log/ keys" == "latest date". Returns
/// an allocator-owned copy of the winning key, or null if no dream_log/
/// entries exist. Caller frees.
///
/// ponytail: full `mem.list(allocator, null, null)` scan + prefix filter.
/// Fine at current corpus sizes (nightly cadence, one key/day). If this
/// ever shows up in a profile, swap to a prefix-list API instead of
/// optimizing this scan in place.
fn latestDreamLogKey(allocator: std.mem.Allocator, mem: Memory) !?[]const u8 {
    const entries = try mem.list(allocator, null, null);
    defer memory_mod.freeEntries(allocator, entries);

    var latest: ?[]const u8 = null;
    for (entries) |entry| {
        if (!std.mem.startsWith(u8, entry.key, "dream_log/")) continue;
        if (latest == null or std.mem.order(u8, entry.key, latest.?) == .gt) {
            latest = entry.key;
        }
    }
    return if (latest) |key| try allocator.dupe(u8, key) else null;
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
    state_mgr_for_supersede: ?*zaki_state.Manager,
    user_id_for_supersede: ?i64,
    dream_log_warmstart_enabled: bool,
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

    // V1.10-A — supersede filter. Fetch every key whose
    // metadata.superseded_by_correction is set, mark them as
    // "already seen" upfront. Every existing skip-check
    // (`containsString(seen_keys, ...)`) then naturally honors the
    // supersede flag without per-site code changes.
    //
    // Memory ownership: superseded_keys array is allocator-owned.
    // Each entry is also allocator-owned. The slices get pushed into
    // seen_keys (which holds []const u8 references). Defer-free
    // ORDER: seen_keys.deinit fires first (declared above), then
    // superseded_keys free below — at that point seen_keys no longer
    // references them. Safe.
    const superseded_keys: [][]u8 = if (state_mgr_for_supersede) |sm|
        if (user_id_for_supersede) |uid|
            sm.findSupersededMemoryKeys(allocator, uid) catch |err| blk: {
                // V1.11 (2026-05-07): make degraded-state visible. Pre-fix this
                // bare catch silently no-op'd the V1.10-A filter when Postgres
                // was unreachable, letting superseded rows surface in agent
                // context. ZAKI surfaced this gap during self-analysis. Now
                // the operator sees the degradation in gateway.log instead of
                // chasing zombie facts in production. Filter still degrades
                // gracefully (returns empty), but no longer silently.
                std.log.scoped(.memory_loader).warn(
                    "supersede filter degraded — findSupersededMemoryKeys failed err={s} uid={d} — superseded entries may surface in retrieval until backend recovers",
                    .{ @errorName(err), uid },
                );
                break :blk &[_][]u8{};
            }
        else
            &[_][]u8{}
    else
        &[_][]u8{};
    defer {
        for (superseded_keys) |k| allocator.free(k);
        if (superseded_keys.len > 0) allocator.free(superseded_keys);
    }
    for (superseded_keys) |k| {
        try markSeenKey(allocator, &seen_keys, k);
    }

    const summary_latest_key = try summaryLatestKeyForSession(allocator, session_id);
    defer if (summary_latest_key) |key| allocator.free(key);
    const current_timeline_prefix = try timelinePrefixForSession(allocator, session_id);
    defer if (current_timeline_prefix) |prefix| allocator.free(prefix);
    const dream_log_key = if (dream_log_warmstart_enabled) try latestDreamLogKey(allocator, mem) else null;
    defer if (dream_log_key) |key| allocator.free(key);

    // V1.7 Item 3: surface any unresolved memory conflict at the top so
    // the agent sees it before any other context and can resolve it with
    // the user. Best-effort — failure must not block context loading.
    _ = appendDirectEntry(allocator, mem, w, &wrote_header, "pending_conflicts", 300) catch false;

    // Task 4 (Loop-1 consumer, package1-activations): the agent's own
    // latest overnight reflection joins warm-start — the dream stops
    // being write-only. Read-only consumption: this does not hide or
    // reclassify dream_log/ keys (still brain-visible derived synthesis).
    if (dream_log_key) |dk| {
        if (try appendDirectEntry(allocator, mem, w, &wrote_header, dk, CONTINUITY_ENTRY_MAX_BYTES)) {
            try markSeenKey(allocator, &seen_keys, dk);
        }
    }

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
            // Learning contract inv. 1/3/7 (Package 2a Task 2): shadow
            // behavior facts are never injected — see isRetiredOrShadowBehaviorFact.
            if (isRetiredOrShadowBehaviorFact(entry.key, entry.content)) continue;
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

    // P4 / C0 note: this secondary timeline-fallback bucket searches
    // global_entries (vector recall results, session_id=null) for
    // timeline_summary/ keys. Post-P4, `shouldEmbedMemoryEntry` returns
    // false for timeline_summary/ — new continuity rows are not embedded
    // and therefore do not appear in vector recall. C0 op-3 deletes
    // pre-P4 embedded continuity rows. Together these make this path
    // unreachable for fresh data on a fully-migrated instance.
    //
    // The loop is deliberately KEPT (not pruned) as a safety net for:
    //   (a) instances where C0 has not yet run (pre-migration rows),
    //   (b) any future embed-policy relaxation that re-embeds continuity.
    // On a post-C0 production instance the loop iterates over entries
    // but finds no timeline_summary/ matches — it is effectively a no-op
    // at negligible cost (~µs over an already-fetched slice).
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
        // Learning contract inv. 1/3/7 (Package 2a Task 2): shadow behavior
        // facts are never injected, through ANY bucket — see isRetiredOrShadowBehaviorFact.
        if (isRetiredOrShadowBehaviorFact(entry.key, entry.content)) continue;
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
                // Learning contract inv. 1/3/7 (Package 2a Task 2): shadow
                // behavior facts are never injected — see isRetiredOrShadowBehaviorFact.
                if (isRetiredOrShadowBehaviorFact(entry.key, entry.content)) continue;
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
    state_mgr_for_supersede: ?*zaki_state.Manager,
    user_id_for_supersede: ?i64,
    dream_log_warmstart_enabled: bool,
) !ContextResult {
    var stats = SelectionStats{ .available = true };
    // P4: tier gate — read once per call; 0.0 = disabled.
    const tier_gate_min_score = readTierGateMinScore();

    // P1: wire entity-overlap callback for this search call.
    // eo_ctx lives on the stack; rt.setEntityOverlapCallback clears it after.
    var eo_ctx: EntityOverlapCtx = undefined;
    if (readEntityOverlapEnabled()) {
        if (state_mgr_for_supersede) |sm| if (user_id_for_supersede) |uid| {
            eo_ctx = .{ .state_mgr = sm, .user_id = uid, .allocator = allocator };
            rt.setEntityOverlapCallback(.{ .ptr = &eo_ctx, .func = entityOverlapImpl });
        };
    }
    defer rt.setEntityOverlapCallback(null);

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

    // V1.10-A — supersede filter (see loadContextDetailed for full
    // rationale). Mark every superseded key as "already seen" so all
    // existing skip-checks naturally honor the flag.
    const superseded_keys: [][]u8 = if (state_mgr_for_supersede) |sm|
        if (user_id_for_supersede) |uid|
            sm.findSupersededMemoryKeys(allocator, uid) catch |err| blk: {
                // V1.11 (2026-05-07): make degraded-state visible. Pre-fix this
                // bare catch silently no-op'd the V1.10-A filter when Postgres
                // was unreachable, letting superseded rows surface in agent
                // context. ZAKI surfaced this gap during self-analysis. Now
                // the operator sees the degradation in gateway.log instead of
                // chasing zombie facts in production. Filter still degrades
                // gracefully (returns empty), but no longer silently.
                std.log.scoped(.memory_loader).warn(
                    "supersede filter degraded — findSupersededMemoryKeys failed err={s} uid={d} — superseded entries may surface in retrieval until backend recovers",
                    .{ @errorName(err), uid },
                );
                break :blk &[_][]u8{};
            }
        else
            &[_][]u8{}
    else
        &[_][]u8{};
    defer {
        for (superseded_keys) |k| allocator.free(k);
        if (superseded_keys.len > 0) allocator.free(superseded_keys);
    }
    for (superseded_keys) |k| {
        try markSeenKey(allocator, &seen_keys, k);
    }

    const summary_latest_key = try summaryLatestKeyForSession(allocator, session_id);
    defer if (summary_latest_key) |key| allocator.free(key);
    const current_timeline_prefix = try timelinePrefixForSession(allocator, session_id);
    defer if (current_timeline_prefix) |prefix| allocator.free(prefix);
    const dream_log_key = if (dream_log_warmstart_enabled) try latestDreamLogKey(allocator, mem) else null;
    defer if (dream_log_key) |key| allocator.free(key);

    // V1.7 Item 3: surface any unresolved memory conflict first.
    _ = appendDirectEntry(allocator, mem, buf.writer(allocator), &wrote_header, "pending_conflicts", 300) catch false;

    // Task 4 (Loop-1 consumer, package1-activations): the agent's own
    // latest overnight reflection joins warm-start — the dream stops
    // being write-only. Read-only consumption: this does not hide or
    // reclassify dream_log/ keys (still brain-visible derived synthesis).
    if (dream_log_key) |dk| {
        if (try appendDirectEntry(allocator, mem, buf.writer(allocator), &wrote_header, dk, CONTINUITY_ENTRY_MAX_BYTES)) {
            try markSeenKey(allocator, &seen_keys, dk);
        }
    }

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
            // Learning contract inv. 1/3/7 (Package 2a Task 2): shadow
            // behavior facts are never injected — see isRetiredOrShadowBehaviorFact.
            if (isRetiredOrShadowBehaviorFact(entry.key, entry.content)) continue;
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

    // P4 / C0 note: see the matching comment in loadContextFromMemory.
    // Post-P4 + post-C0, timeline_summary/ rows are not embedded so vector
    // recall never returns them; this loop is a no-op on fully-migrated
    // instances but is retained as a safety net for pre-C0 legacy rows.
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
        // Learning contract inv. 1/3/7 (Package 2a Task 2): shadow behavior
        // facts are never injected, even via the vector/RRF candidate path
        // — see isRetiredOrShadowBehaviorFact. cand.snippet is a full-content hydrate
        // (memory/root.zig's hydrateSnippet dupes owned_entry.content), so
        // the metadata header (if any) survives into it intact.
        if (isRetiredOrShadowBehaviorFact(cand.key, cand.snippet)) continue;
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
            // P4: tier gate — skip low-confidence RRF hits from the fallback bucket.
            // The isSemanticContinuityKey branch above is never gated (quality risk).
            // NOTE: gated candidates intentionally skip markSeenKey below, so they are
            // NOT added to seen_keys.  containsCandidateKey (used in global_keyword_entries
            // loop) still finds them in `candidates` so they won't double-inject via that
            // path.  They CAN resurface through the global_entries path (containsString on
            // seen_keys), which is correct: the gate suppresses a candidate from the premium
            // RRF fallback slot but does not permanently exclude it from the turn.
            // Only gate candidates that were actually scored by a ranker
            // (final_score > 0). `final_score == 0` means "no ranking was
            // applied" (keyword-only path, no RRF, no llm_reranker) — those
            // candidates are NOT low-confidence RRF hits and gating them
            // would be a category error. The gate's purpose is to suppress
            // low-confidence RRF hits, not to suppress unranked candidates.
            // This also lets `readTierGateMinScore`'s code default be a
            // production-safe positive value (0.005) without breaking the
            // keyword-only test paths that never set final_score.
            if (tier_gate_min_score > 0.0 and cand.final_score > 0.0 and cand.final_score < tier_gate_min_score) {
                stats.tier_gated_count += 1;
                continue;
            }
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
                // Learning contract inv. 1/3/7 (Package 2a Task 2): shadow
                // behavior facts are never injected — see isRetiredOrShadowBehaviorFact.
                if (isRetiredOrShadowBehaviorFact(entry.key, entry.content)) continue;
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
                // Learning contract inv. 1/3/7 (Package 2a Task 2): shadow
                // behavior facts are never injected — see isRetiredOrShadowBehaviorFact.
                if (isRetiredOrShadowBehaviorFact(entry.key, entry.content)) continue;
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
    // V1.10-A: legacy entry point. No state_mgr/user_id available on
    // the public signature → no supersede filter applied. Callers that
    // need filtering should use loadTurnMemorySlot (which threads
    // state_mgr through). This shim preserves backwards-compat for
    // tests + non-tenant call paths.
    const result = try loadContextDetailed(allocator, mem, user_message, session_id, null, null, true);
    return result.context;
}

pub fn loadContextWithRuntime(
    allocator: std.mem.Allocator,
    mem: Memory,
    rt: *MemoryRuntime,
    user_message: []const u8,
    session_id: ?[]const u8,
) ![]const u8 {
    // V1.10-A: same legacy-shim shape as loadContext above.
    const result = try loadContextWithRuntimeDetailed(allocator, mem, rt, user_message, session_id, null, null, true);
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
/// Options bag for loadTurnMemorySlot. Added in V1.13 to avoid breaking
/// the existing positional-arg API surface as new flags accumulate.
pub const LoadTurnMemoryOptions = struct {
    /// V1.13 DUP-1 fix: when true, skip the legacy <active_identity>
    /// block. Working Memory (V1.13 Layer 0) renders identity slots in
    /// the volatile prompt block already; injecting <active_identity>
    /// here too duplicates 500B-2KB per turn. When agent/root.zig
    /// confirms working_memory is populated (state_mgr + user_id +
    /// session_id wired AND postgres alive), it sets this flag. When
    /// working_memory is unavailable (sqlite build, postgres down,
    /// fresh session before any slots), the legacy path stays active
    /// as a fallback so identity is never lost.
    skip_legacy_identity: bool = false,

    /// Phase 0.5 — typed views gate (default ON). When true AND
    /// state_mgr + user_id are bound, four deterministic blocks
    /// (<preferences> / <open_loops> / <decisions> / <people>) are
    /// appended inside the <memory_for_turn> fence, reading the P3-typed
    /// memory signals. When false → no new blocks (exact prior context).
    /// Threaded from `agent.typed_views_enabled` (config_types.AgentConfig).
    typed_views_enabled: bool = true,

    /// Task 4 (Loop-1 consumer, package1-activations) — dream_log
    /// warm-start gate (default ON). When true, the loader finds the
    /// latest `dream_log/<YYYY-MM-DD>` key (the nightly dream cycle's
    /// most recent reflection) and injects it via appendDirectEntry
    /// right after pending_conflicts — the first consumer of an
    /// otherwise write-only organ.
    ///
    /// When FALSE, no dream_log entry is injected — exact prior
    /// (pre-Task-4) context. Read-only consumption either way: this
    /// never marks dream_log/ keys hidden or reclassifies them.
    ///
    /// Threaded from `agent.dream_log_warmstart_enabled`
    /// (config_types.AgentConfig), same plumbing pattern as
    /// `typed_views_enabled`.
    dream_log_warmstart_enabled: bool = true,
};

pub fn loadTurnMemorySlot(
    allocator: std.mem.Allocator,
    mem: Memory,
    mem_rt: ?*MemoryRuntime,
    user_message: []const u8,
    session_id: ?[]const u8,
    state_mgr_for_graph: ?*zaki_state.Manager,
    user_id_for_graph: ?i64,
) !MemorySlot {
    return loadTurnMemorySlotOpts(
        allocator,
        mem,
        mem_rt,
        user_message,
        session_id,
        state_mgr_for_graph,
        user_id_for_graph,
        .{},
    );
}

/// V1.13 — explicit-options variant. Takes a LoadTurnMemoryOptions
/// bag for new flags (today: skip_legacy_identity). Old positional
/// callers continue to work via the wrapper above.
pub fn loadTurnMemorySlotOpts(
    allocator: std.mem.Allocator,
    mem: Memory,
    mem_rt: ?*MemoryRuntime,
    user_message: []const u8,
    session_id: ?[]const u8,
    state_mgr_for_graph: ?*zaki_state.Manager,
    user_id_for_graph: ?i64,
    opts: LoadTurnMemoryOptions,
) !MemorySlot {
    // V1.10-A — pass state_mgr_for_graph + user_id_for_graph through as
    // the supersede-filter inputs. They're already required for graph
    // expansion / community block; reusing them avoids new params on
    // the public surface. Callers that don't supply them get
    // graceful-degrade (no supersede filtering — same behavior as pre-V1.10).
    var result = if (mem_rt) |rt|
        try loadContextWithRuntimeDetailed(allocator, mem, rt, user_message, session_id, state_mgr_for_graph, user_id_for_graph, opts.dream_log_warmstart_enabled)
    else
        try loadContextDetailed(allocator, mem, user_message, session_id, state_mgr_for_graph, user_id_for_graph, opts.dream_log_warmstart_enabled);

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

    // ── V1.7-ship S2b: warm <active_communities> block ─────────────────
    // Append top-3 communities by member_count when state_mgr + user_id
    // are bound AND at least one community exists. Cost: 1 PG call per
    // turn (listCommunities, bounded by per-user community count which
    // is typically 5-20). Block size: ~80-150 bytes. Falls back silently
    // on any error or cold-start (no recompute yet); legacy + graph
    // blocks are unaffected.
    var community_block: ?[]u8 = null;
    if (state_mgr_for_graph) |sm| if (user_id_for_graph) |uid| {
        community_block = buildActiveCommunitiesBlock(allocator, sm, uid) catch |err| blk: {
            log.warn("active_communities.append_failed err={s} — skipping community context", .{@errorName(err)});
            break :blk null;
        };
    };
    defer if (community_block) |c| allocator.free(c);

    // ── V1.8-9: warm <active_identity> block ───────────────────────────
    // Pin the user's identity facts in warm context regardless of cosine
    // relevance to this turn's user message. Identity is context-invariant
    // by definition (the user's name doesn't depend on what they just
    // said). Without pinning, identity facts get bumped from context on
    // turns whose text is unrelated to identity — agent loses "who am I
    // talking to" until the next cosine-relevant turn.
    //
    // Cost: 1 PG round-trip per turn via listIdentityFacts. Bounded by
    // limit=8 + IDENTITY_BLOCK_MAX_BYTES (1500). Falls back silently on
    // any error; legacy retrieval is unaffected.
    var identity_block: ?[]u8 = null;
    var identity_stats = IdentityAppendResult{};
    // V1.13 DUP-1 fix: when caller signals working_memory has identity
    // slots populated, skip the legacy <active_identity> block.
    // Working Memory's volatile-prompt render already covers identity.
    // Falls through to legacy when WM is unavailable (sqlite build,
    // postgres down, fresh session) so identity is never lost.
    if (!opts.skip_legacy_identity) {
        if (state_mgr_for_graph) |sm| if (user_id_for_graph) |uid| {
            identity_block = buildActiveIdentityBlock(allocator, sm, uid, &identity_stats) catch |err| blk: {
                log.warn("active_identity.append_failed err={s} — skipping identity context", .{@errorName(err)});
                break :blk null;
            };
        };
    }
    result.stats.identity_pin_active = identity_stats.appended;
    result.stats.identity_pin_fact_count = identity_stats.fact_count;
    result.stats.identity_pin_appended_bytes = identity_stats.appended_bytes;
    defer if (identity_block) |b| allocator.free(b);

    // ── Phase 0.5: typed views ─────────────────────────────────────────
    // Read the P3-typed memory signals as four deterministic, always-on
    // blocks. Gated behind opts.typed_views_enabled (default ON, threaded
    // from agent config). Requires state_mgr + user_id (these are
    // user-global, cross-session views). Each builder queries one
    // memory_type via listMemories(.{ .custom = … }, session_id=null) and
    // falls back silently on any error so it can never make injection
    // WORSE than legacy. 4 filtered queries/turn — acceptable per Phase
    // 0.5 perf note (small, user_id-indexed sets).
    var pref_block: ?[]u8 = null;
    var loop_block: ?[]u8 = null;
    var decision_block: ?[]u8 = null;
    var people_block: ?[]u8 = null;
    // Aggregate typed-view telemetry across all four builders so it can be
    // wired into result.stats after the block (mirrors graph_stats /
    // identity_stats pattern).
    var typed_views_stats: TypedViewAppendResult = .{};
    if (opts.typed_views_enabled) {
        if (state_mgr_for_graph) |sm| if (user_id_for_graph) |uid| {
            var s: TypedViewAppendResult = .{};
            pref_block = buildTypedViewBlock(allocator, sm, uid, "preference", "preferences", "User preferences — honor these by default when relevant.", &s) catch |err| blk: {
                log.warn("typed_views.preferences_failed err={s} — skipping block", .{@errorName(err)});
                break :blk null;
            };
            typed_views_stats.appended = typed_views_stats.appended or s.appended;
            typed_views_stats.item_count += s.item_count;
            typed_views_stats.appended_bytes += s.appended_bytes;
            s = .{};
            loop_block = buildTypedViewBlock(allocator, sm, uid, "open_loop", "open_loops", "Unfinished threads — proactively follow up; these are time-sensitive (most recent first).", &s) catch |err| blk: {
                log.warn("typed_views.open_loops_failed err={s} — skipping block", .{@errorName(err)});
                break :blk null;
            };
            typed_views_stats.appended = typed_views_stats.appended or s.appended;
            typed_views_stats.item_count += s.item_count;
            typed_views_stats.appended_bytes += s.appended_bytes;
            s = .{};
            decision_block = buildTypedViewBlock(allocator, sm, uid, "decision", "decisions", "Decisions already made — do not relitigate; treat as settled (most recent first).", &s) catch |err| blk: {
                log.warn("typed_views.decisions_failed err={s} — skipping block", .{@errorName(err)});
                break :blk null;
            };
            typed_views_stats.appended = typed_views_stats.appended or s.appended;
            typed_views_stats.item_count += s.item_count;
            typed_views_stats.appended_bytes += s.appended_bytes;
            s = .{};
            people_block = buildTypedViewBlock(allocator, sm, uid, "person", "people", "People in the user's life — relationships and CRM facts.", &s) catch |err| blk: {
                log.warn("typed_views.people_failed err={s} — skipping block", .{@errorName(err)});
                break :blk null;
            };
            typed_views_stats.appended = typed_views_stats.appended or s.appended;
            typed_views_stats.item_count += s.item_count;
            typed_views_stats.appended_bytes += s.appended_bytes;
        };
    }
    result.stats.typed_views_active = typed_views_stats.appended;
    result.stats.typed_views_item_count = typed_views_stats.item_count;
    result.stats.typed_views_appended_bytes = typed_views_stats.appended_bytes;
    defer if (pref_block) |b| allocator.free(b);
    defer if (loop_block) |b| allocator.free(b);
    defer if (decision_block) |b| allocator.free(b);
    defer if (people_block) |b| allocator.free(b);

    // If everything is empty, return empty slot (no fence).
    const has_legacy = result.context.len > 0;
    const has_graph = if (graph_block) |g| g.len > 0 else false;
    const has_community = if (community_block) |c| c.len > 0 else false;
    const has_identity = if (identity_block) |b| b.len > 0 else false;
    const has_pref = if (pref_block) |b| b.len > 0 else false;
    const has_loop = if (loop_block) |b| b.len > 0 else false;
    const has_decision = if (decision_block) |b| b.len > 0 else false;
    const has_people = if (people_block) |b| b.len > 0 else false;
    if (!has_legacy and !has_graph and !has_community and !has_identity and
        !has_pref and !has_loop and !has_decision and !has_people)
    {
        allocator.free(result.context);
        return .{
            .fenced_content = try allocator.dupe(u8, ""),
            .stats = result.stats,
        };
    }

    defer allocator.free(result.context);
    const graph_payload: []const u8 = if (graph_block) |g| g else "";
    const community_payload: []const u8 = if (community_block) |c| c else "";
    const identity_payload: []const u8 = if (identity_block) |b| b else "";
    const pref_payload: []const u8 = if (pref_block) |b| b else "";
    const loop_payload: []const u8 = if (loop_block) |b| b else "";
    const decision_payload: []const u8 = if (decision_block) |b| b else "";
    const people_payload: []const u8 = if (people_block) |b| b else "";
    // V1.8-9: identity block goes FIRST inside the fence — context-invariant
    // facts are read before turn-specific retrieval. Order: identity →
    // typed views → legacy retrieval → graph neighbors → communities.
    //
    // Priority cascade rationale:
    //   1. <active_identity>     — who the user IS (foundation, every turn)
    //   2. typed views           — <preferences>/<open_loops>/<decisions>/
    //                              <people>: context-invariant standing facts
    //                              (Phase 0.5). Like identity, these are
    //                              always-on (not cosine-gated), so they sit
    //                              with identity ahead of turn-specific recall.
    //   3. result.context        — starts with `pending_conflicts` (V1.7
    //                              Item 3) then summary_latest, semantic
    //                              bucket, fallback bucket
    //   4. <graph_neighbors>     — 1-hop graph expansion of recall seeds
    //   5. <active_communities>  — top-3 community labels for orientation
    //
    // Why identity beats pending_conflicts: without knowing who you're
    // talking to, you can't usefully process their stated confusion.
    // Identity grounds the conflict resolution. The V1.7 "first" in
    // pending_conflicts meant "first within retrieval payload," not
    // "first across all warm context."
    const fenced = try std.fmt.allocPrint(
        allocator,
        "<memory_for_turn>\n{s}{s}{s}{s}{s}{s}{s}{s}</memory_for_turn>\n",
        .{ identity_payload, pref_payload, loop_payload, decision_payload, people_payload, result.context, graph_payload, community_payload },
    );
    return .{
        .fenced_content = fenced,
        .stats = result.stats,
    };
}

/// V1.7-ship S2b — emit the top-3 communities by member_count as warm
/// always-on context. Gives the agent visibility into the user's
/// highest-level brain structure on every memory-touching turn without
/// requiring an explicit `brain_graph` tool call.
///
/// Format:
///   <active_communities source="lpa">
///   community_name (N members), community_name2 (M members), community_name3 (K members)
///   </active_communities>
///
/// Returns empty slice when:
///   - No communities computed yet (cold start, never recomputed) — this
///     is the common case before the first /brain/communities/recompute
///     POST or nightly scheduler run
///   - Every community has only an unnamed fallback (no useful signal)
///
/// listCommunities already returns rows sorted by member_count DESC (and
/// applies MEMORIES_VALIDITY_FILTER on the live count subquery), so we
/// just take the prefix.
fn buildActiveCommunitiesBlock(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
) !?[]u8 {
    const summaries = try state_mgr.listCommunities(allocator, user_id);
    defer memory_mod.freeCommunitySummaries(allocator, summaries);
    if (summaries.len == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("<active_communities source=\"lpa\">\n");
    var emitted: usize = 0;
    for (summaries) |s| {
        if (emitted >= 3) break;
        // Skip unnamed (still being computed) communities so the agent
        // doesn't see "Cluster 47312" noise. Named-only is the high-
        // signal subset.
        const name = s.name orelse continue;
        if (name.len == 0) continue;
        if (emitted > 0) try w.writeAll(", ");
        // V1.7-ship review WR-1 belt-and-suspenders: defense-in-depth
        // escape of `<` / `>` / `\n` even though community_llm_namer's
        // cleanName positively filters to `[A-Za-z0-9 ./&'_-]` + UTF-8.
        // If the cleaning ever regresses (or a future writer skips it),
        // this emission still cannot inject XML/structural chars into
        // the system prompt.
        for (name) |ch| {
            if (ch == '<' or ch == '>' or ch == '\n' or ch == '\r') continue;
            try w.writeByte(ch);
        }
        try w.print(" ({d} members)", .{s.member_count});
        emitted += 1;
    }
    if (emitted == 0) {
        // No NAMED communities yet (all fallbacks pending real LLM names).
        // Drop the block rather than emit an empty header.
        buf.deinit(allocator);
        return null;
    }
    try w.writeAll("\n</active_communities>\n");
    return try buf.toOwnedSlice(allocator);
}

// ── V1.8-9 active-identity pinning ──────────────────────────────────────

/// Hard cap on the `<active_identity>` block bytes. Identity facts are
/// typically short prose ("Eli Vance is a software engineer in Berlin");
/// 1500 bytes holds ~6-10 facts comfortably. Prevents identity bucket
/// from blowing the prompt cache budget when extraction has been busy.
const IDENTITY_BLOCK_MAX_BYTES: usize = 1500;
/// Per-fact content cap. Same shape as SEMANTIC_ENTRY_MAX_BYTES.
const IDENTITY_FACT_MAX_BYTES: usize = 220;
/// Maximum facts to fetch from PG. Loader trims further by byte budget.
const IDENTITY_FACT_FETCH_LIMIT: u32 = 8;

/// Telos fetch limit — a curated north star aggregates more referent types than
/// the identity block (mission + goals + challenges + strategies + values), so a
/// higher ceiling; still byte-bounded by IDENTITY_BLOCK_MAX_BYTES below.
const TELOS_FACT_FETCH_LIMIT: u32 = 24;
/// Lower-case prefix length used for de-dup. "Eli Vance is a software
/// engineer." vs "Eli Vance is a software engineer based in Berlin." —
/// the first 50 lowercase chars usually match for restated facts. Picks
/// the most-recent restatement (since SQL ORDER BY created_at DESC) and
/// drops older near-duplicates.
const IDENTITY_DEDUP_PREFIX_BYTES: usize = 50;

/// Telemetry emitted by `buildActiveIdentityBlock` for SelectionStats.
/// Mirrors the shape of GraphAppendResult so consumers (turn audit,
/// /agent/diagnostics, eval analyzers) can report identity-pin coverage
/// per turn alongside graph_recall_*.
const IdentityAppendResult = struct {
    appended: bool = false,
    fact_count: usize = 0,
    appended_bytes: usize = 0,
};

/// V1.8-9 — emit pinned identity facts as warm always-on context.
/// Bypasses cosine relevance scoring: identity is context-invariant
/// (the user's name doesn't depend on this turn's user message).
///
/// Format:
///   <active_identity source="pinned">
///   - Eli Vance is a software engineer based in Berlin, Germany.
///   - Eli works at OmniCorp on the Atlas project.
///   - …
///   </active_identity>
///
/// Returns null when:
///   - `listIdentityFacts` errors (caller logs + skips block — graceful
///     degrade, legacy retrieval unaffected)
///   - Zero facts match identity-class predicates yet (cold-start before
///     first identity write)
///   - All matched facts are empty/blank after trimming
///
/// De-dup: facts whose first IDENTITY_DEDUP_PREFIX_BYTES (lowercased,
/// whitespace-collapsed) match a previously emitted fact are skipped.
/// Because SQL returns rows by `created_at DESC`, the most-recent
/// restatement wins. Avoids "Eli prefers Helix" + "Eli prefers Helix as
/// his code editor over NeoVim" both pinning when they're the same
/// fact at different specificity.
///
/// Cost: 1 PG round-trip per turn. Bounded by IDENTITY_FACT_FETCH_LIMIT
/// (8 rows). EXISTS subquery covered by partial indexes.
fn buildActiveIdentityBlock(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    stats: *IdentityAppendResult,
) !?[]u8 {
    const facts = try state_mgr.listIdentityFacts(allocator, user_id, IDENTITY_FACT_FETCH_LIMIT);
    defer memory_mod.freeEntries(allocator, facts);
    if (facts.len == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("<active_identity source=\"pinned\">\n");

    // De-dup table: lowercase, whitespace-collapsed prefix of each
    // emitted fact. Bounded by IDENTITY_FACT_FETCH_LIMIT (8) so a
    // small fixed-size buffer suffices.
    var seen_prefixes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (seen_prefixes.items) |p| allocator.free(p);
        seen_prefixes.deinit(allocator);
    }

    var emitted: usize = 0;
    var bytes_used: usize = 0;
    for (facts) |entry| {
        const trimmed = std.mem.trim(u8, entry.content, " \t\r\n");
        if (trimmed.len == 0) continue;

        // De-dup against earlier emissions in this batch.
        const dedup_key = try identityDedupKey(allocator, trimmed);
        defer allocator.free(dedup_key);
        var is_dup = false;
        for (seen_prefixes.items) |seen| {
            if (std.mem.eql(u8, seen, dedup_key)) {
                is_dup = true;
                break;
            }
        }
        if (is_dup) continue;

        // Cap per-fact bytes (UTF-8 safe truncation) and account for the
        // "- " prefix + newline overhead.
        const truncated = truncateUtf8(trimmed, IDENTITY_FACT_MAX_BYTES);
        const line_overhead: usize = 3; // "- " + "\n"
        if (bytes_used + truncated.len + line_overhead > IDENTITY_BLOCK_MAX_BYTES) break;
        try w.writeAll("- ");
        // Defense-in-depth: strip XML structural chars so a future
        // extraction-classifier regression can't inject system-prompt
        // markup (mirrors buildActiveCommunitiesBlock WR-1 escape).
        for (truncated) |ch| {
            if (ch == '<' or ch == '>' or ch == '\r') continue;
            if (ch == '\n') {
                try w.writeByte(' ');
                continue;
            }
            try w.writeByte(ch);
        }
        try w.writeByte('\n');
        bytes_used += truncated.len + line_overhead;
        emitted += 1;

        // Record the prefix for subsequent dedup checks.
        try seen_prefixes.append(allocator, try allocator.dupe(u8, dedup_key));
    }

    if (emitted == 0) {
        // All matched facts were blank / oversized after trimming. Drop
        // the block rather than emit an empty header.
        buf.deinit(allocator);
        return null;
    }
    try w.writeAll("</active_identity>\n");
    log.info("active_identity.injected user_id={d} facts={d} bytes={d}", .{
        user_id,
        emitted,
        bytes_used,
    });
    stats.appended = true;
    stats.fact_count = emitted;
    stats.appended_bytes = bytes_used;
    return try buf.toOwnedSlice(allocator);
}

/// TELOS injection block (docs/telos-contract.md, T1) — the curated, always-on
/// user-model north star. Sibling of `buildActiveIdentityBlock`, but sourced from
/// the `durable_fact/telos/*` namespace via `listTelosFacts` and rendered
/// UNCONDITIONALLY (curated), not retrieval-gated. Fail-soft: no rows (cold start)
/// or all-blank → null, and the caller omits the block.
fn buildTelosBlock(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
) !?[]u8 {
    const facts = try state_mgr.listTelosFacts(allocator, user_id, TELOS_FACT_FETCH_LIMIT);
    defer memory_mod.freeEntries(allocator, facts);
    const block = try renderTelosBlock(allocator, facts);
    if (block) |b| log.info("telos.injected user_id={d} bytes={d}", .{ user_id, b.len });
    return block;
}

/// Pure renderer for the `<telos>` block — no DB, so it is unit-testable with
/// hand-built entries. Bounded (IDENTITY_BLOCK_MAX_BYTES), per-item capped
/// (IDENTITY_FACT_MAX_BYTES), XML-escaped (strips `<`/`>`/`\r`, `\n`→space so a
/// row cannot inject system-prompt markup), and deduped by content prefix.
/// Returns null when nothing renders (empty input or all-blank/dup) so the caller
/// never emits a bare `<telos></telos>`.
fn renderTelosBlock(allocator: std.mem.Allocator, facts: []const MemoryEntry) !?[]u8 {
    if (facts.len == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("<telos>\n");

    var seen_prefixes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (seen_prefixes.items) |p| allocator.free(p);
        seen_prefixes.deinit(allocator);
    }

    var emitted: usize = 0;
    var bytes_used: usize = 0;
    for (facts) |entry| {
        const trimmed = std.mem.trim(u8, entry.content, " \t\r\n");
        if (trimmed.len == 0) continue;

        const dedup_key = try identityDedupKey(allocator, trimmed);
        defer allocator.free(dedup_key);
        var is_dup = false;
        for (seen_prefixes.items) |seen| {
            if (std.mem.eql(u8, seen, dedup_key)) {
                is_dup = true;
                break;
            }
        }
        if (is_dup) continue;

        const truncated = truncateUtf8(trimmed, IDENTITY_FACT_MAX_BYTES);
        const line_overhead: usize = 3; // "- " + "\n"
        if (bytes_used + truncated.len + line_overhead > IDENTITY_BLOCK_MAX_BYTES) break;
        try w.writeAll("- ");
        for (truncated) |ch| {
            if (ch == '<' or ch == '>' or ch == '\r') continue;
            if (ch == '\n') {
                try w.writeByte(' ');
                continue;
            }
            try w.writeByte(ch);
        }
        try w.writeByte('\n');
        bytes_used += truncated.len + line_overhead;
        emitted += 1;
        try seen_prefixes.append(allocator, try allocator.dupe(u8, dedup_key));
    }

    if (emitted == 0) {
        buf.deinit(allocator);
        return null;
    }
    try w.writeAll("</telos>\n");
    return try buf.toOwnedSlice(allocator);
}

/// Build the dedup key for an identity fact: first
/// IDENTITY_DEDUP_PREFIX_BYTES of `text` lowercased with runs of
/// whitespace collapsed to single spaces. ASCII-only lowercase (matches
/// the identity-fact corpus we've seen — proper nouns + simple verbs).
/// Caller frees.
fn identityDedupKey(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var prev_space = false;
    for (text) |ch| {
        if (buf.items.len >= IDENTITY_DEDUP_PREFIX_BYTES) break;
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            if (!prev_space and buf.items.len > 0) {
                try buf.append(allocator, ' ');
                prev_space = true;
            }
            continue;
        }
        prev_space = false;
        const lower: u8 = if (ch >= 'A' and ch <= 'Z') ch + ('a' - 'A') else ch;
        try buf.append(allocator, lower);
    }
    return buf.toOwnedSlice(allocator);
}

// ── Phase 0.5 typed views — read the P3-typed memory signals ───────────────
//
// P3 routes a fact's durable `memory_type` by meaning into
// `MemoryCategory{ .custom = "preference" | "open_loop" | "decision" |
// "person" }`. Those signals were WRITTEN but nothing READ them. These four
// views are deterministic, always-on context blocks over the existing store
// (filter by type — NOT a new store) so the agent always sees the user's
// preferences, open loops, decisions, and people on every memory-touching
// turn, regardless of this turn's cosine relevance.
//
// Each block mirrors the <active_identity> shape exactly: a one-line header
// (so the model knows how to use it), compact bullet items, a hard per-block
// byte cap, and a per-item byte cap with UTF-8-safe truncation + XML-strip
// defense-in-depth. Empty type → block omitted entirely (no empty fence).
//
// Queried via state_mgr.listMemories(allocator, user_id, .{ .custom = … },
// null) — session_id null because these are user-global, cross-session.
// listMemories already ORDER BY updated_at DESC, so open_loops are
// recency-sorted and decisions are most-recent-N for free. 4 filtered
// queries/turn is acceptable for Phase 0.5 (small, user_id-indexed sets);
// each is bounded by a fetch limit below.

/// Hard per-block byte cap. Holds ~6-10 short facts each — same envelope as
/// IDENTITY_BLOCK_MAX_BYTES (1500). Keeps the four blocks combined well under
/// the warm-context budget (worst case ~4*1500 = 6KB, but in practice most
/// users have 0-2 populated types).
const TYPED_VIEW_BLOCK_MAX_BYTES: usize = 1200;
/// Per-item content cap (UTF-8 safe). Same shape as IDENTITY_FACT_MAX_BYTES.
const TYPED_VIEW_ITEM_MAX_BYTES: usize = 220;
/// Max rows fetched per typed query. Loader trims further by byte budget.
/// open_loops/decisions are recency-sorted (updated_at DESC) so the most
/// recent N survive the byte cap; preferences/people likewise.
const TYPED_VIEW_FETCH_LIMIT: i64 = 12;

/// Telemetry for a single typed-view block. Mirrors IdentityAppendResult.
const TypedViewAppendResult = struct {
    appended: bool = false,
    item_count: usize = 0,
    appended_bytes: usize = 0,
};

/// PURE renderer for a typed-view block. Takes an already-fetched slice of
/// MemoryEntry (does NOT own/free them — caller's responsibility) and renders
/// the fenced block. Returns null when no items survive trimming → caller
/// omits the block (no empty `<tag></tag>`).
///
/// Pure-function shape (slice in, optional bytes out) so the builders' core
/// logic is testable without a live DB. `tag` is the fence name
/// ("preferences" etc.); `header` is the one-line description the model reads.
fn renderTypedViewBlock(
    allocator: std.mem.Allocator,
    tag: []const u8,
    header: []const u8,
    entries: []const MemoryEntry,
    stats: *TypedViewAppendResult,
) !?[]u8 {
    if (entries.len == 0) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.print("<{s}>\n", .{tag});
    try w.writeAll(header);
    try w.writeByte('\n');
    // Header bytes are not counted against the item budget — they are a
    // fixed small cost. The cap governs how many ITEMS we admit.
    const header_bytes = buf.items.len;

    var emitted: usize = 0;
    var bytes_used: usize = 0;
    for (entries) |entry| {
        const trimmed = std.mem.trim(u8, entry.content, " \t\r\n");
        if (trimmed.len == 0) continue;
        const truncated = truncateUtf8(trimmed, TYPED_VIEW_ITEM_MAX_BYTES);
        const line_overhead: usize = 3; // "- " + "\n"
        if (bytes_used + truncated.len + line_overhead > TYPED_VIEW_BLOCK_MAX_BYTES) break;
        try w.writeAll("- ");
        // Defense-in-depth: strip XML structural chars so a future
        // extraction-classifier regression can't inject system-prompt markup
        // (mirrors buildActiveIdentityBlock / buildActiveCommunitiesBlock).
        for (truncated) |ch| {
            if (ch == '<' or ch == '>' or ch == '\r') continue;
            if (ch == '\n') {
                try w.writeByte(' ');
                continue;
            }
            try w.writeByte(ch);
        }
        try w.writeByte('\n');
        bytes_used += truncated.len + line_overhead;
        emitted += 1;
    }

    if (emitted == 0) {
        // Every candidate was blank/oversized after trimming. Drop the block
        // rather than emit an empty header.
        buf.deinit(allocator);
        return null;
    }
    try w.print("</{s}>\n", .{tag});
    stats.appended = true;
    stats.item_count = emitted;
    stats.appended_bytes = header_bytes + bytes_used + tag.len + 4; // "</…>\n"
    return try buf.toOwnedSlice(allocator);
}

/// Query one typed view by P3 custom memory_type, then render it.
/// `mem_type` is the durable `memory_type` string ("preference" etc.).
/// session_id is null: these are user-global, cross-session.
///
/// Returns null when state_mgr errors (caller logs + skips — graceful
/// degrade, legacy retrieval unaffected) or when no rows of this type exist.
/// Follows the file's free discipline: `defer memory_mod.freeEntries(...)`
/// on the listMemories result.
fn buildTypedViewBlock(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    mem_type: []const u8,
    tag: []const u8,
    header: []const u8,
    stats: *TypedViewAppendResult,
) !?[]u8 {
    const entries = try state_mgr.listMemories(
        allocator,
        user_id,
        .{ .custom = mem_type },
        null,
    );
    defer memory_mod.freeEntries(allocator, entries);
    if (entries.len == 0) return null;

    // Bound the rendered set to the most-recent N (listMemories already
    // ORDER BY updated_at DESC — recency-sorted for open_loops/decisions;
    // preferences/people likewise). The byte cap inside the renderer trims
    // further; this just caps the slice we hand it.
    const limit: usize = @intCast(TYPED_VIEW_FETCH_LIMIT);
    const bounded = entries[0..@min(entries.len, limit)];
    return renderTypedViewBlock(allocator, tag, header, bounded, stats);
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

// ── P4: Tier Gate ───────────────────────────────────────────────────────────

/// Minimum RRF final_score for fallback-bucket candidates that were ranked.
/// Set explicitly to `0` to disable the gate entirely.
///
/// **Default: 0.005** — the calibrated production value for the zaki_bot
/// profile (temporal_decay ON, half_life_days=30). At this threshold a
/// single-source rank-1 fact is blocked only after ~72 days of decay;
/// multi-source / recent facts always pass.
///
/// Score ranges at default rrf_k=60, top_k=25 (raw RRF, before temporal decay):
///   single-source  rank  1 → 1/61  ≈ 0.01639
///   single-source  rank 17 → 1/77  ≈ 0.01299
///   two-source     rank  1 → 2/61  ≈ 0.03279  (always passes at any sane threshold)
///   three-source   rank  1 → 3/61  ≈ 0.04918  (always passes)
///
/// With temporal decay ON (half_life_days=30, default for zaki_bot profile):
///   score *= exp(-ln(2)/30 * age_days)
///   threshold 0.005 → single-source rank-1 blocked after ~72 days
///   threshold 0.013 → single-source rank-1 blocked after ~11 days (too aggressive)
///
/// When temporal decay is OFF, 0.013 is a safer threshold (tighter on rank-17+).
/// Only applies to the runtime (hybrid/shadow_hybrid) path candidates.
/// Semantic-bucket entries (isSemanticContinuityKey path) are never gated.
/// The gate further requires `final_score > 0` (a ranker actually ran) —
/// unranked candidates bypass it (see comment at the application site).
/// Values out of [0,1] fall back to the production default rather than
/// silently disabling or blanket-blocking.
///
/// Note: when llm_reranker is enabled the pipeline overwrites final_score with
/// 1/(rank+1) — minimum score with top_k=25 is 1/25=0.04, so 0.005 has no
/// effect in that configuration (gate becomes a no-op, which is correct).
const DEFAULT_TIER_GATE_MIN_SCORE: f64 = 0.005;
fn readTierGateMinScore() f64 {
    const val = std.posix.getenv("NULLALIS_TIER_GATE_MIN_SCORE") orelse return DEFAULT_TIER_GATE_MIN_SCORE;
    const parsed = std.fmt.parseFloat(f64, val) catch return DEFAULT_TIER_GATE_MIN_SCORE;
    // Out-of-range values fall back to the calibrated default rather than
    // silently disabling the gate or (worse) blanket-blocking. An operator
    // who wants the gate off must set `NULLALIS_TIER_GATE_MIN_SCORE=0`
    // explicitly — that is a legal value in the [0, 1] range.
    return if (parsed >= 0.0 and parsed <= 1.0) parsed else DEFAULT_TIER_GATE_MIN_SCORE;
}

// ── P1: Entity Overlap Callback ────────────────────────────────────────────

/// Kill switch: set NULLALIS_ENTITY_OVERLAP=0 to disable entity overlap.
fn readEntityOverlapEnabled() bool {
    const val = std.posix.getenv("NULLALIS_ENTITY_OVERLAP") orelse return true;
    return !std.mem.eql(u8, val, "0");
}

/// Context bag threaded through the type-erased EntityOverlapCallCtx.
const EntityOverlapCtx = struct {
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    allocator: std.mem.Allocator,
};

/// Called by the retrieval engine as the 3rd RRF source.
/// Tokenises `query`, matches token patterns against `memory_edges`, and
/// returns normalised `RetrievalCandidate` slices ranked by match_count.
/// Snippet is populated so bucket rendering never emits blank lines.
fn entityOverlapImpl(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    query: []const u8,
) anyerror![]memory_mod.RetrievalCandidate {
    const eo: *EntityOverlapCtx = @ptrCast(@alignCast(ctx));

    // Build ILIKE patterns from query tokens (skip tokens shorter than 3 chars)
    var patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (patterns.items) |p| allocator.free(p);
        patterns.deinit(allocator);
    }
    var it = std.mem.tokenizeAny(u8, query, " \t\n.,;:!?\"'()[]{}");
    while (it.next()) |tok| {
        if (tok.len < 3) continue;
        const lower = try std.ascii.allocLowerString(allocator, tok);
        defer allocator.free(lower);
        const pat = try std.fmt.allocPrint(allocator, "%{s}%", .{lower});
        try patterns.append(allocator, pat);
    }
    if (patterns.items.len == 0) return allocator.alloc(memory_mod.RetrievalCandidate, 0);

    const rows = try eo.state_mgr.findEdgesEntityOverlap(allocator, eo.user_id, patterns.items, 10);
    defer {
        for (rows) |r| r.deinit(allocator);
        allocator.free(rows);
    }
    if (rows.len == 0) return allocator.alloc(memory_mod.RetrievalCandidate, 0);

    // Normalise scores: highest match_count → 1.0
    const max_count: f64 = @floatFromInt(rows[0].match_count);

    var out = try allocator.alloc(memory_mod.RetrievalCandidate, rows.len);
    var out_len: usize = 0; // tracks how many entries are fully initialised
    errdefer {
        // deinit only the fully-initialised entries to avoid freeing unset fields
        for (out[0..out_len]) |*c| c.deinit(allocator);
        allocator.free(out);
    }
    for (rows, 0..) |row, i| {
        const score: f64 = if (max_count > 0.0)
            @as(f64, @floatFromInt(row.match_count)) / max_count
        else
            0.0;
        // Heap-allocate every field that RetrievalCandidate.deinit() will free.
        // String literals must NOT be passed to allocator.free() — only the
        // zero-length "" is safe (free returns early on len==0), but "entity_overlap"
        // (len=14) would UB against a static segment pointer.
        //
        // Each allocation gets its own errdefer so a mid-struct OOM doesn't
        // leak the fields already allocated in this iteration. Matches the
        // pattern used by entriesToCandidates and vectorResultsToCandidates.
        const id_dup = try allocator.dupe(u8, "");
        errdefer allocator.free(id_dup);
        const key_dup = try allocator.dupe(u8, row.memory_key);
        errdefer allocator.free(key_dup);
        const content_dup = try allocator.dupe(u8, row.snippet); // MUST be non-empty
        errdefer allocator.free(content_dup);
        const snippet_dup = try allocator.dupe(u8, row.snippet);
        errdefer allocator.free(snippet_dup);
        const source_dup = try allocator.dupe(u8, "entity_overlap");
        errdefer allocator.free(source_dup);
        const source_path_dup = try allocator.dupe(u8, "");
        errdefer allocator.free(source_path_dup);
        out[i] = memory_mod.RetrievalCandidate{
            .id = id_dup,
            .key = key_dup,
            .content = content_dup,
            .snippet = snippet_dup,
            .category = .daily,
            .keyword_rank = null,
            .vector_score = null,
            .final_score = score,
            .source = source_dup,
            .source_path = source_path_dup,
            .start_line = 0,
            .end_line = 0,
            .created_at = 0,
            .lane = "",
        };
        out_len = i + 1;
    }
    return out;
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

    // V1.14.12 (Memory audit Finding 10 fix, 2026-05-19) — emit 2-hop
    // neighbors via their 1-hop predecessor. Pre-fix, the BFS reached
    // 2 hops (DEFAULT_GRAPH_RECALL_MAX_HOPS=2, motivated by Cat 3
    // inference at lines 60-67) but the emit code only matched edges
    // where the OTHER endpoint was a seed — so 2-hop nodes were
    // silently dropped despite paying the SQL cost. Now we track the
    // hop=1 frontier and let 2-hop nodes emit via their 1-hop bridge.
    var hop1_set: std.StringHashMapUnmanaged(void) = .{};
    defer hop1_set.deinit(allocator);
    for (recall.neighborhood.nodes) |n| {
        if (n.hop_distance == 1) try hop1_set.put(allocator, n.key, {});
    }

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

        // Find a connecting edge. For 1-hop nodes the OTHER endpoint
        // is a seed. For 2-hop nodes the OTHER endpoint is a 1-hop
        // node (the bridge). Prefer seed-connection when both exist —
        // it's the more salient relationship for the LLM.
        var via_key: ?[]const u8 = null;
        var via_predicate: ?[]const u8 = null;
        for (recall.neighborhood.edges) |e| {
            if (std.mem.eql(u8, e.source_key, node.key) and seed_set.contains(e.target_key)) {
                via_key = e.target_key;
                via_predicate = e.predicate;
                break;
            } else if (std.mem.eql(u8, e.target_key, node.key) and seed_set.contains(e.source_key)) {
                via_key = e.source_key;
                via_predicate = e.predicate;
                break;
            }
        }
        // V1.14.12 (Finding 10 fix) — 2-hop fallback: if no direct seed
        // connection, look for an edge to a 1-hop bridge node. Emit with
        // the bridge as via=. The LLM sees "neighbor_key=X predicate=Y
        // via=<1-hop bridge>" and can chain the inference.
        if (via_key == null and node.hop_distance == 2) {
            for (recall.neighborhood.edges) |e| {
                if (std.mem.eql(u8, e.source_key, node.key) and hop1_set.contains(e.target_key)) {
                    via_key = e.target_key;
                    via_predicate = e.predicate;
                    break;
                } else if (std.mem.eql(u8, e.target_key, node.key) and hop1_set.contains(e.source_key)) {
                    via_key = e.source_key;
                    via_predicate = e.predicate;
                    break;
                }
            }
        }
        // Still no connecting edge — skip (defensive; shouldn't happen
        // for a node in the BFS neighborhood, but guards against orphans
        // that slipped through edge filtering).
        if (via_key == null or via_predicate == null) continue;

        // Fetch content for this neighbor key (one round trip per neighbor).
        const entry_opt = state_mgr.getMemory(allocator, user_id, node.key) catch null;
        if (entry_opt) |entry| {
            defer entry.deinit(allocator);
            const trimmed = truncateUtf8(std.mem.trim(u8, entry.content, " \t\n\r"), GRAPH_NEIGHBOR_CONTENT_MAX_BYTES);
            // Format: one line per neighbor for easy LLM scanning.
            // hop=1|2 added per Finding 10 so the LLM can disambiguate
            // direct seed-neighbors from inferred 2-hop chains.
            try w.print(
                "neighbor_key={s} hop={d} predicate={s} via={s} content={s}\n",
                .{ node.key, node.hop_distance, via_predicate.?, via_key.?, trimmed },
            );
            emitted += 1;
        } else {
            // Lookup failed (key vanished mid-flight) — emit a stub so the
            // edge isn't silently dropped from the agent's view.
            try w.print(
                "neighbor_key={s} hop={d} predicate={s} via={s} content=<unavailable>\n",
                .{ node.key, node.hop_distance, via_predicate.?, via_key.? },
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

// ── Package 2a Task 2: injection obeys the learning-contract ladder ────────
// Learning contract inv. 1/3/7: SHADOW IS NEVER INJECTED. Only state=active
// behavior facts (and legacy facts with no state metadata — grandfathered,
// same as pre-Task-2 behavior) reach the prompt.

test "learning contract inv. 1/3/7: shadow behavior fact is never injected; active + legacy are" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    // Active: origin=user_correction (birth-state law: active at birth).
    const active_result = try learning.storeLearnedFact(
        allocator,
        mem,
        "always mention shipping deadlines upfront",
        .user_correction,
        &.{},
        null,
    );
    defer active_result.deinit(allocator);

    // Shadow: origin=mined_aggregate (birth-state law: shadow at birth —
    // NOT yet adopted, must never influence behavior per inv. 1).
    const shadow_result = try learning.storeLearnedFact(
        allocator,
        mem,
        "shipping retries should back off exponentially",
        .mined_aggregate,
        &.{},
        null,
    );
    defer shadow_result.deinit(allocator);

    // Legacy: pre-Task-2 shape — plain content, NO metadata header at all
    // (exactly what the unmodified user_correction fast path in root.zig
    // still writes today). Grandfathered as active.
    try mem.store(
        "durable_fact/behavior/legacyfact0000",
        "shipping confirmations go out same day",
        .core,
        null,
    );

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

    try std.testing.expect(std.mem.indexOf(u8, slot.fenced_content, "always mention shipping deadlines upfront") != null);
    try std.testing.expect(std.mem.indexOf(u8, slot.fenced_content, "shipping confirmations go out same day") != null);
    try std.testing.expect(std.mem.indexOf(u8, slot.fenced_content, "shipping retries should back off exponentially") == null);
}

test "learning contract: legacy behavior fact (no metadata header at all) is grandfathered active, in isolation" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    // The ONLY fact in this session is a legacy-shape durable_fact/behavior/
    // entry — exactly what the pre-Task-2, still-unmodified user_correction
    // fast path in root.zig writes (plain content, mem.store, no metadata).
    // No active/shadow facts present, so a pass here proves the grandfather
    // clause in isolation rather than as a side effect of a mixed scenario.
    try mem.store(
        "durable_fact/behavior/onlylegacyfact01",
        "onboarding reminders should be gentle",
        .core,
        null,
    );

    const slot = try loadTurnMemorySlot(
        allocator,
        mem,
        null,
        "onboarding",
        "agent:zaki-bot:user:2:main",
        null,
        null,
    );
    defer allocator.free(slot.fenced_content);

    try std.testing.expect(std.mem.indexOf(u8, slot.fenced_content, "onboarding reminders should be gentle") != null);
}

test "isShadowBehaviorFact: true only for durable_fact/behavior/ keys carrying state=shadow" {
    // Shadow behavior fact → true.
    try std.testing.expect(isShadowBehaviorFact(
        "durable_fact/behavior/abc123",
        "origin=mined_aggregate\nstate=shadow\n\nretry with backoff",
    ));

    // Active behavior fact → false.
    try std.testing.expect(!isShadowBehaviorFact(
        "durable_fact/behavior/abc123",
        "origin=user_correction\nstate=active\n\nalways use snake_case",
    ));

    // Legacy behavior fact (no header) → false (grandfathered active).
    try std.testing.expect(!isShadowBehaviorFact(
        "durable_fact/behavior/abc123",
        "always use snake_case",
    ));

    // Non-behavior durable_fact/ key → false, even with shadow-shaped
    // content — this gate must never touch facts outside its scope.
    try std.testing.expect(!isShadowBehaviorFact(
        "durable_fact/shipping_pref",
        "origin=mined_aggregate\nstate=shadow\n\nirrelevant",
    ));

    // Unrelated key entirely → false.
    try std.testing.expect(!isShadowBehaviorFact("summary_latest/agent:1:main", "state=shadow"));
}

// ── Task 4: retired facts are ALSO never injected ──────────────────────────
// Learning contract inv. 1/3/7 extended by Task 4's "retired hygiene": a
// dismissed suggestion (state=retired, via /learn dismiss) must never
// influence behavior, exactly like a shadow draft. isShadowBehaviorFact's
// name is shadow-specific (state == .shadow only) — a retired fact is NOT
// shadow, so it must be excluded by a SEPARATE predicate/gate, not silently
// rely on isShadowBehaviorFact widening.

test "learning contract: a retired (dismissed) behavior fact is never injected" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    // A dismissed suggestion: origin=mined_aggregate, state=retired (what
    // /learn dismiss produces — see commands.zig's handleLearnCommand).
    try mem.store(
        "durable_fact/behavior/retiredfact0000",
        "origin=mined_aggregate\nstate=retired\nevidence_run_ids=r-1-1\n\nretry uploads with exponential backoff",
        .core,
        null,
    );

    const slot = try loadTurnMemorySlot(
        allocator,
        mem,
        null,
        "uploads",
        "agent:zaki-bot:user:3:main",
        null,
        null,
    );
    defer allocator.free(slot.fenced_content);

    try std.testing.expect(std.mem.indexOf(u8, slot.fenced_content, "retry uploads with exponential backoff") == null);
}

test "isRetiredOrShadowBehaviorFact: true for both shadow and retired states, false for active/legacy" {
    // Shadow → true.
    try std.testing.expect(isRetiredOrShadowBehaviorFact(
        "durable_fact/behavior/abc123",
        "origin=mined_aggregate\nstate=shadow\n\nretry with backoff",
    ));
    // Retired (dismissed) → true.
    try std.testing.expect(isRetiredOrShadowBehaviorFact(
        "durable_fact/behavior/abc123",
        "origin=mined_aggregate\nstate=retired\n\nretry with backoff",
    ));
    // Active → false.
    try std.testing.expect(!isRetiredOrShadowBehaviorFact(
        "durable_fact/behavior/abc123",
        "origin=user_correction\nstate=active\n\nalways use snake_case",
    ));
    // Legacy (no header) → false (grandfathered active).
    try std.testing.expect(!isRetiredOrShadowBehaviorFact(
        "durable_fact/behavior/abc123",
        "always use snake_case",
    ));
    // Non-behavior key → false regardless of shadow-shaped content.
    try std.testing.expect(!isRetiredOrShadowBehaviorFact(
        "durable_fact/shipping_pref",
        "origin=mined_aggregate\nstate=retired\n\nirrelevant",
    ));
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

    const result = try loadContextDetailed(allocator, mem, "shipping raw recall", "agent:test:user:1:main", null, null, true);
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
    // V1.13: bumped fixture 20 → 35 noise rows. Recall limit raised
    // from 10 → 25; the test's intent is "over-fetch goes deeper than
    // the recall cap so internal pollution doesn't crowd out the real
    // fact." With recall_cap=25 we need >25 candidates to prove
    // over-fetch behavior.
    for (0..35) |i| {
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

    const result = try loadContextWithRuntimeDetailed(allocator, mem, &rt, "alexsignal saturday", null, null, null, true);
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

    const result = try loadContextWithRuntimeDetailed(allocator, mem, &rt, "Alex 30GB project", "agent:test:user:1:main", null, null, true);
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

    const result = try loadContextWithRuntimeDetailed(allocator, mem, &rt, "Alex 30GB debug checklist", null, null, null, true);
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

    const result = try loadContextWithRuntimeDetailed(allocator, mem, &rt, "30GB Alex project", "agent:test:user:1:main", null, null, true);
    defer allocator.free(result.context);

    try std.testing.expect(result.stats.semantic_bucket_entries >= 2);
    try std.testing.expect(result.stats.semantic_bucket_bytes >= 1);
    try std.testing.expect(result.stats.fallback_bucket_entries <= SEARCH_FALLBACK_BUCKET_MAX_ENTRIES);
    try std.testing.expect(result.stats.fallback_bucket_bytes <= FALLBACK_BUCKET_MAX_BYTES);
    try std.testing.expect(std.mem.indexOf(u8, result.context, "timeline_summary/agent:test:user:1:other/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.context, "durable_fact/project_owner") != null);
}

test "tier gate: readTierGateMinScore returns the calibrated default when env var absent" {
    // NULLALIS_TIER_GATE_MIN_SCORE must not be set in the test environment.
    // Gate ships ON at the calibrated default (DEFAULT_TIER_GATE_MIN_SCORE,
    // 0.005 for the zaki_bot temporal-decay profile). Operators wanting it
    // off must set the env to "0" explicitly.
    const score = readTierGateMinScore();
    try std.testing.expectEqual(DEFAULT_TIER_GATE_MIN_SCORE, score);
}

test "tier gate: SelectionStats.tier_gated_count initialises to zero" {
    const s = SelectionStats{};
    try std.testing.expectEqual(@as(usize, 0), s.tier_gated_count);
}

test "tier gate: score-range arithmetic at rrf_k=60 top_k=25" {
    // Verify the score-range assumptions baked into the recommended 0.013 default.
    // RRF formula: score = 1 / (0-indexed_rank + 1 + k)
    const k: f64 = 60.0;
    // Single source: worst case (rank 25, 0-indexed 24) must be above any sane gate.
    const single_worst = 1.0 / (24.0 + 1.0 + k); // 1/85 ≈ 0.01176
    try std.testing.expect(single_worst > 0.011);
    try std.testing.expect(single_worst < 0.013); // blocked by 0.013 threshold
    // Single source: rank-16 (0-indexed 15) must pass.
    const single_rank16 = 1.0 / (15.0 + 1.0 + k); // 1/76 ≈ 0.01316
    try std.testing.expect(single_rank16 > 0.013);
    // Two-source: even at rank 25 each, easily clears the gate.
    const two_source_worst = 2.0 / (24.0 + 1.0 + k); // 2/85 ≈ 0.02353
    try std.testing.expect(two_source_worst > 0.013);
    // Upper-bound clamp: value > 1.0 must NOT become the gate threshold
    // (tested indirectly — verify the clamp arithmetic is correct).
    const clamped = blk: {
        const parsed: f64 = 2.5; // simulate bad env value
        break :blk if (parsed >= 0.0 and parsed <= 1.0) parsed else @as(f64, 0.0);
    };
    try std.testing.expectEqual(@as(f64, 0.0), clamped);
}

// ── Phase 0.5 typed views — pure-function builder tests ────────────────────
//
// renderTypedViewBlock is the testable core of the four typed-view builders:
// it takes an already-fetched []const MemoryEntry (so no live DB needed) and
// renders the fenced block. buildTypedViewBlock wraps it with a listMemories
// query; that query path needs Postgres (Manager is PG-only), so the pure
// renderer is where the byte cap / inclusion / omission / empty-handling logic
// is asserted. MemoryEntry literals below use static string fields (the
// renderer only READS entry.content — it never owns or frees the slice).

/// Test helper: a static-string MemoryEntry for the pure renderer. The
/// renderer borrows `content`; nothing is allocated or freed.
fn testEntry(content: []const u8) MemoryEntry {
    return .{
        .id = "id",
        .key = "k",
        .content = content,
        .category = .{ .custom = "preference" },
        .timestamp = "0",
    };
}

test "typed views: renderTypedViewBlock includes the typed items + header + fence" {
    const allocator = std.testing.allocator;
    const entries = [_]MemoryEntry{
        testEntry("user prefers dark mode"),
        testEntry("user prefers concise replies"),
    };
    var stats: TypedViewAppendResult = .{};
    const out = (try renderTypedViewBlock(allocator, "preferences", "User preferences — honor these.", &entries, &stats)).?;
    defer allocator.free(out);

    // (a) typed items are present, one bullet each.
    try std.testing.expect(std.mem.indexOf(u8, out, "- user prefers dark mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- user prefers concise replies") != null);
    // header + open/close fence present.
    try std.testing.expect(std.mem.startsWith(u8, out, "<preferences>\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "User preferences — honor these.\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "</preferences>\n"));
    try std.testing.expect(stats.appended);
    try std.testing.expectEqual(@as(usize, 2), stats.item_count);
}

test "typed views: renderTypedViewBlock renders ONLY the items it is handed (type isolation)" {
    const allocator = std.testing.allocator;
    // Caller (buildTypedViewBlock) pre-filters by memory_type via listMemories,
    // so the renderer only ever sees the matching type. Verify it never invents
    // content not in its input slice — the omission guarantee at the render layer.
    const entries = [_]MemoryEntry{testEntry("open_loop: reply to Dana about the lease")};
    var stats: TypedViewAppendResult = .{};
    const out = (try renderTypedViewBlock(allocator, "open_loops", "Unfinished threads.", &entries, &stats)).?;
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "reply to Dana about the lease") != null);
    // No leakage of unrelated typed markup — the only fence is <open_loops>.
    try std.testing.expect(std.mem.indexOf(u8, out, "<preferences>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<decisions>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<people>") == null);
}

test "typed views: renderTypedViewBlock respects the hard per-block byte cap" {
    const allocator = std.testing.allocator;
    // Each item is ~100 bytes; with TYPED_VIEW_BLOCK_MAX_BYTES = 1200 and a
    // 3-byte line overhead, far fewer than 40 items can fit. The renderer must
    // stop admitting items once the cap would be exceeded — the block never
    // grows unbounded.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var list: std.ArrayListUnmanaged(MemoryEntry) = .empty;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const c = try std.fmt.allocPrint(aa, "preference item number {d} padded out to about a hundred bytes so the cap is exercised", .{i});
        try list.append(aa, testEntry(c));
    }
    var stats: TypedViewAppendResult = .{};
    const out = (try renderTypedViewBlock(allocator, "preferences", "Prefs.", list.items, &stats)).?;
    defer allocator.free(out);

    // (c) total bytes bounded: header + items + fence stays within the cap
    // plus a small fixed overhead for the header/fence lines.
    try std.testing.expect(out.len <= TYPED_VIEW_BLOCK_MAX_BYTES + 64);
    // And NOT all 40 items were admitted (the cap actually bit).
    try std.testing.expect(stats.item_count < 40);
    try std.testing.expect(stats.item_count > 0);
}

test "typed views: renderTypedViewBlock truncates an oversized single item to the per-item cap" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const huge = try aa.alloc(u8, TYPED_VIEW_ITEM_MAX_BYTES * 3);
    @memset(huge, 'x');
    const entries = [_]MemoryEntry{testEntry(huge)};
    var stats: TypedViewAppendResult = .{};
    const out = (try renderTypedViewBlock(allocator, "people", "People.", &entries, &stats)).?;
    defer allocator.free(out);

    // The rendered item is capped at the per-item byte budget (UTF-8 safe).
    // Count only the 'x' run so header/fence bytes don't inflate the figure.
    var x_run: usize = 0;
    for (out) |ch| {
        if (ch == 'x') x_run += 1;
    }
    try std.testing.expect(x_run <= TYPED_VIEW_ITEM_MAX_BYTES);
    try std.testing.expectEqual(@as(usize, 1), stats.item_count);
}

test "typed views: renderTypedViewBlock returns null for empty input (no empty fence)" {
    const allocator = std.testing.allocator;
    const empty: []const MemoryEntry = &[_]MemoryEntry{};
    var stats: TypedViewAppendResult = .{};
    const out = try renderTypedViewBlock(allocator, "decisions", "Decisions.", empty, &stats);
    try std.testing.expect(out == null);
    try std.testing.expect(!stats.appended);
}

test "typed views: renderTypedViewBlock returns null when every item is blank (no empty fence)" {
    const allocator = std.testing.allocator;
    const entries = [_]MemoryEntry{ testEntry("   "), testEntry("\n\t ") };
    var stats: TypedViewAppendResult = .{};
    const out = try renderTypedViewBlock(allocator, "decisions", "Decisions.", &entries, &stats);
    try std.testing.expect(out == null);
    try std.testing.expect(!stats.appended);
}

test "typed views: renderTypedViewBlock strips XML structural chars (defense-in-depth)" {
    const allocator = std.testing.allocator;
    const entries = [_]MemoryEntry{testEntry("decided to <inject>markup</inject>")};
    var stats: TypedViewAppendResult = .{};
    const out = (try renderTypedViewBlock(allocator, "decisions", "Decisions.", &entries, &stats)).?;
    defer allocator.free(out);

    // The only '<' / '>' allowed are the block's own fence tags. The item's
    // angle brackets are stripped so a classifier regression can't inject
    // system-prompt markup.
    try std.testing.expect(std.mem.indexOf(u8, out, "<inject>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "</inject>") == null);
    // Inner text survives (sans brackets).
    try std.testing.expect(std.mem.indexOf(u8, out, "injectmarkup/inject") != null);
}

test "typed views: LoadTurnMemoryOptions.typed_views_enabled defaults to true" {
    const opts = LoadTurnMemoryOptions{};
    try std.testing.expect(opts.typed_views_enabled);
}

// ── TELOS contract (executable form of docs/telos-contract.md) ─────────────
// Contract-first: hosts telos_contract_test.zig into the build so its
// invariants (T1–T6, T2b) compile+run under BOTH the default `zig build` and
// the all-engine `zig build test` — the stub-parity gate.
test {
    _ = @import("telos_contract_test.zig");
}

test "renderTelosBlock: empty→null, XML-escaped, deduped, blanks skipped [T1]" {
    const allocator = std.testing.allocator;

    // Force compile-analysis of the DB-backed wrapper now (it is wired into the
    // prompt in task 5; Zig would otherwise lazily skip an unreferenced fn).
    _ = &buildTelosBlock;

    // Cold start: no rows → null so the caller never emits a bare <telos></telos>.
    try std.testing.expect((try renderTelosBlock(allocator, &[_]MemoryEntry{})) == null);

    const entries = [_]MemoryEntry{
        .{ .id = "1", .key = "durable_fact/telos/mission/0", .content = "Build the best <agent>", .category = .core, .timestamp = "0" },
        .{ .id = "2", .key = "durable_fact/telos/goal/0", .content = "Ship v1 by Q3", .category = .core, .timestamp = "0" },
        .{ .id = "3", .key = "durable_fact/telos/goal/1", .content = "Ship v1 by Q3", .category = .core, .timestamp = "0" }, // dup
        .{ .id = "4", .key = "durable_fact/telos/value/0", .content = "   ", .category = .core, .timestamp = "0" }, // blank
    };
    const block = (try renderTelosBlock(allocator, &entries)).?;
    defer allocator.free(block);

    try std.testing.expect(std.mem.startsWith(u8, block, "<telos>\n"));
    try std.testing.expect(std.mem.endsWith(u8, block, "</telos>\n"));
    // XML structural chars stripped — a row cannot inject system-prompt markup.
    try std.testing.expect(std.mem.indexOf(u8, block, "Build the best agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "<agent>") == null);
    // Dedup by content prefix + blank skipped → exactly two bullets (mission + goal).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, block, "Ship v1 by Q3"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, block, "- "));
}

// ── dream_log warm-start injection (first dream consumer) ──────────────────

test "loadContext injects the latest dream_log entry, not an older one" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    // Deliberately share no keywords with the recall query below — this
    // proves the older entry surfaces (if at all) only through the
    // dream_log warm-start injection path, not through incidental
    // keyword-recall matching, which would confound the assertion.
    try mem.store(
        "dream_log/2026-07-01",
        "xqzplon vremtak zoblidge quixnar",
        .core,
        null,
    );
    try mem.store(
        "dream_log/2026-07-05",
        "reflection: latest overnight synthesis — ship the warm-start consumer",
        .core,
        null,
    );
    try mem.store("unrelated_key", "irrelevant content", .core, null);

    const context = try loadContext(allocator, mem, "zznomatch_query_9928", null);
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "dream_log/2026-07-05") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "latest overnight synthesis") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "dream_log/2026-07-01") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "xqzplon") == null);
}

test "loadContext is unchanged when no dream_log keys exist" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("unrelated_key", "irrelevant content", .core, null);

    const context = try loadContext(allocator, mem, "anything", null);
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "dream_log") == null);
}

test "dream_log warm-start: flag off leaves output unchanged even with dream_log keys present" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store(
        "dream_log/2026-07-05",
        "reflection: latest overnight synthesis — ship the warm-start consumer",
        .core,
        null,
    );

    const slot_on = try loadTurnMemorySlotOpts(
        allocator,
        mem,
        null,
        "zznomatch_query_9928",
        null,
        null,
        null,
        .{ .dream_log_warmstart_enabled = true },
    );
    defer allocator.free(slot_on.fenced_content);
    try std.testing.expect(std.mem.indexOf(u8, slot_on.fenced_content, "dream_log/2026-07-05") != null);

    const slot_off = try loadTurnMemorySlotOpts(
        allocator,
        mem,
        null,
        "zznomatch_query_9928",
        null,
        null,
        null,
        .{ .dream_log_warmstart_enabled = false },
    );
    defer allocator.free(slot_off.fenced_content);
    try std.testing.expect(std.mem.indexOf(u8, slot_off.fenced_content, "dream_log") == null);
}

test "latestDreamLogKey returns the lexicographic max dream_log key" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("dream_log/2026-07-01", "old reflection", .core, null);
    try mem.store("dream_log/2026-07-05", "latest reflection", .core, null);
    try mem.store("dream_log/2026-06-30", "older reflection", .core, null);
    try mem.store("unrelated_key", "irrelevant", .core, null);

    const key = (try latestDreamLogKey(allocator, mem)).?;
    defer allocator.free(key);
    try std.testing.expectEqualStrings("dream_log/2026-07-05", key);
}

test "latestDreamLogKey returns null when no dream_log keys exist" {
    const allocator = std.testing.allocator;

    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("unrelated_key", "irrelevant", .core, null);

    const key = try latestDreamLogKey(allocator, mem);
    try std.testing.expect(key == null);
}
