//! Learning loop — detects corrections and preferences in user messages,
//! stores them as durable behavioral facts under durable_fact/behavior/ keys.
//!
//! Behavioral facts are distinct from raw memory recall. They are injected
//! with higher priority during memory enrichment and change how the agent
//! behaves, not just what it knows.
//!
//! Session scoping: per-user behavioral facts require session_id.
//! Global workspace preferences (operator-set) use null session_id.
//!
//! Security: T-1.5-07 — per-user facts require session_id; null session_id
//! is reserved for operator-set workspace globals. T-1.5-08 — MAX_FACTS_PER_SESSION
//! limits unbounded writes to 100 per session. T-1.5-09 — durable_fact/ keys
//! are system-managed; users cannot modify them via normal memory commands.
//! /learn forget is the only user-facing removal path.

const std = @import("std");
const memory_mod = @import("../memory/root.zig");
const Memory = memory_mod.Memory;
const MemoryEntry = memory_mod.MemoryEntry;

/// V1.13: lifted 100 → 250. Long active sessions (multi-hour
/// brainstorming, content-strategy work, long onboarding flows) hit
/// the 100-fact cap and silently dropped subsequent learning. 250
/// gives realistic headroom while still bounding session-scope writes.
/// V1.13 dream-state recompute will dedup + consolidate at 3am, so
/// session-scope facts have a daily natural cleanup path.
pub const MAX_FACTS_PER_SESSION: usize = 250;

pub const LearningSignal = enum {
    explicit_correction, // "no, actually" / "that's wrong" / "I meant"
    explicit_preference, // "always do X" / "prefer Y" / "never do Z"
    implicit_correction, // "I meant the other one" / repeats request differently
};

pub const LearnedFact = struct {
    key: []const u8,
    content: []const u8,
    signal: LearningSignal,
};

// ── The Learning Contract vocabulary ────────────────────────────────────────
// Normative source: docs/learning-contract.md. Executable form:
// learning_contract_test.zig. If you change a name or a birth-state row,
// change both.

/// LearnedOrigin — axis 1 (provenance) of the learning contract. Immutable,
/// stamped at birth. Trust follows provenance, never content (inv. 3):
/// `user_correction` and `mined_aggregate` are never conflated.
pub const LearnedOrigin = enum {
    user_correction,
    observed_success,
    observed_failure,
    mined_aggregate,
    operator,

    pub fn toSlice(self: LearnedOrigin) []const u8 {
        return @tagName(self);
    }

    pub fn fromSlice(slice: []const u8) ?LearnedOrigin {
        return std.meta.stringToEnum(LearnedOrigin, slice);
    }
};

/// LearnedState — axis 4 (the trust ladder) of the learning contract:
/// `shadow -> active -> retired`. Transitions are EXTERNAL events only
/// (inv. 1); this type only names the rungs, it does not gate movement
/// between them.
pub const LearnedState = enum {
    shadow,
    active,
    retired,

    pub fn toSlice(self: LearnedState) []const u8 {
        return @tagName(self);
    }

    pub fn fromSlice(slice: []const u8) ?LearnedState {
        return std.meta.stringToEnum(LearnedState, slice);
    }
};

/// The birth-state LAW (learning contract inv. 1): only a human-stated
/// correction or operator directive is active at birth; everything the
/// agent derives itself starts shadow.
pub fn birthState(origin: LearnedOrigin) LearnedState {
    return switch (origin) {
        .user_correction, .operator => .active,
        .observed_success, .observed_failure, .mined_aggregate => .shadow,
    };
}

// Patterns for each signal type. All checked case-insensitively.
const CORRECTION_PATTERNS = [_][]const u8{
    "no, actually",
    "that's wrong",
    "that is wrong",
    "not what i",
    "i didn't mean",
    "i meant",
    "wrong,",
    "incorrect",
};

const PREFERENCE_PATTERNS = [_][]const u8{
    "always ",
    "never ",
    "prefer ",
    "don't ever ",
    "from now on",
    "going forward",
    "remember that i",
    "keep in mind",
};

// Note: "i meant" appears in both correction and implicit_correction checks.
// explicit_correction takes priority if matched first (dedup logic handles this).
const IMPLICIT_CORRECTION_PATTERNS = [_][]const u8{
    "what i really want",
    "let me rephrase",
    "try again",
};

/// detectLearningSignals scans a user message for behavioral correction and
/// preference patterns using case-insensitive heuristic string matching.
///
/// Returns a deduplicated slice of detected LearningSignal values.
/// The returned slice is allocated with the provided allocator.
/// Returns an empty slice if no patterns match.
pub fn detectLearningSignals(allocator: std.mem.Allocator, user_message: []const u8) ![]LearningSignal {
    // Lowercase the message for case-insensitive matching.
    const lower = try allocator.alloc(u8, user_message.len);
    defer allocator.free(lower);
    _ = std.ascii.lowerString(lower, user_message);

    var found = std.EnumSet(LearningSignal){};

    for (CORRECTION_PATTERNS) |pattern| {
        if (std.mem.indexOf(u8, lower, pattern) != null) {
            found.insert(.explicit_correction);
            break;
        }
    }

    for (PREFERENCE_PATTERNS) |pattern| {
        if (std.mem.indexOf(u8, lower, pattern) != null) {
            found.insert(.explicit_preference);
            break;
        }
    }

    // implicit_correction: check its own patterns (excluding "i meant" which is
    // already handled by explicit_correction). Only emit implicit_correction if
    // explicit_correction was NOT already detected.
    if (!found.contains(.explicit_correction)) {
        for (IMPLICIT_CORRECTION_PATTERNS) |pattern| {
            if (std.mem.indexOf(u8, lower, pattern) != null) {
                found.insert(.implicit_correction);
                break;
            }
        }
    }

    var result = std.ArrayListUnmanaged(LearningSignal){};
    const iter_order = [_]LearningSignal{ .explicit_correction, .explicit_preference, .implicit_correction };
    for (iter_order) |sig| {
        if (found.contains(sig)) {
            try result.append(allocator, sig);
        }
    }
    return result.toOwnedSlice(allocator);
}

/// factKey generates a deterministic memory key for a behavioral fact.
///
/// Algorithm:
///   1. Lowercase fact_content
///   2. Hash with FNV-1a 64-bit
///   3. Format as `durable_fact/behavior/{x:0>16}` (16-char lowercase hex)
///
/// The returned slice is allocated with the provided allocator.
pub fn factKey(allocator: std.mem.Allocator, fact_content: []const u8) ![]const u8 {
    const lower = try allocator.alloc(u8, fact_content.len);
    defer allocator.free(lower);
    _ = std.ascii.lowerString(lower, fact_content);

    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(lower);
    const hash = hasher.final();

    return std.fmt.allocPrint(allocator, "durable_fact/behavior/{x:0>16}", .{hash});
}

/// formatFactForEnrichment returns the fact content as-is.
///
/// Behavioral facts are stored as human-readable instructions. This function
/// exists as a named API entry point for consistency and future formatting
/// (e.g., adding a "Learned preference:" prefix).
pub fn formatFactForEnrichment(fact_content: []const u8) []const u8 {
    return fact_content;
}

// ── The Learning Contract store (Package 2a Task 2) ────────────────────────
// Provenance-typed writes: every behavior fact written via storeLearnedFact
// carries its origin + birth-state as a leading metadata-line header in the
// stored content, mirroring the origin_channel=/origin_lane= idiom already
// established in memory/root.zig's metadataValue()/extractStoredOriginMetadata().
// This is the ONLY backend-agnostic, in-process-readable channel: the real
// storeWithMetadata JSONB side-channel is Postgres-only (see
// memory/engines/zaki_postgres.zig) and silently no-ops on every other
// backend (sqlite/none/memory_lru/markdown/...), so it cannot be the source
// of truth for the injection gate or /learn list, which must work on every
// backend the same way.
//
// The EXISTING user_correction fast path (root.zig ~4319, unmodified by this
// task) writes plain content with NO header. stripLearnedMetadataHeader
// treats "no header" as legacy — the caller (memory_loader.zig's injection
// gate) applies the birth-state law's grandfather clause: no metadata means
// active, exactly matching pre-Task-2 behavior for that path.

const LEARNED_ORIGIN_PREFIX = "origin=";
const LEARNED_STATE_PREFIX = "state=";
const LEARNED_EVIDENCE_PREFIX = "evidence_run_ids=";

/// Parsed provenance header on a stored behavior fact's content, or the
/// legacy/no-header case (both fields null).
pub const LearnedMetadataHeader = struct {
    origin: ?LearnedOrigin = null,
    state: ?LearnedState = null,
};

/// headerBlockEnd returns the byte offset of the body start (just past the
/// first "\n\n") ONLY when `content`'s very FIRST line is a real
/// `origin=` header line — i.e. a header written by
/// buildLearnedMetadataHeader. Returns null otherwise (legacy shape, or
/// arbitrary user-authored text that happens to contain an `origin=`/
/// `state=`-shaped line somewhere in its BODY, not at position 0).
///
/// This is the hardening fix for a real misclassification risk:
/// memory_mod.metadataValue() scans EVERY line of `content` looking for a
/// prefix match, not just a leading block. A legacy user_correction fact
/// (stored with no header at all by the unmodified root.zig fast path)
/// could have multi-line text where some line deep in the body incidentally
/// starts with "state=" (e.g. correcting a config value literally named
/// that) — scanning the whole string would misread that as the contract's
/// state metadata and the injection gate could wrongly hide an active
/// fact. Requiring the header at line 0 makes that ambiguity impossible:
/// only content storeLearnedFact itself wrote can ever match.
fn headerBlockEnd(content: []const u8) ?usize {
    if (!std.mem.startsWith(u8, content, LEARNED_ORIGIN_PREFIX)) return null;
    const blank_idx = std.mem.indexOf(u8, content, "\n\n") orelse return null;
    return blank_idx + 2;
}

/// parseLearnedMetadataHeader reads the `origin=`/`state=` header lines
/// from a durable_fact/behavior/ entry's stored content, if present.
///
/// Returns `.{ .origin = null, .state = null }` when no header is present
/// (the legacy case — pre-Task-2 user_correction writes, or any content
/// that predates this contract, INCLUDING content whose body merely
/// contains an origin=/state=-shaped line that isn't a real leading
/// header — see headerBlockEnd). Callers apply the grandfather clause
/// (no state metadata = active) themselves; this function only parses.
pub fn parseLearnedMetadataHeader(content: []const u8) LearnedMetadataHeader {
    var header = LearnedMetadataHeader{};
    const header_end = headerBlockEnd(content) orelse return header;
    const header_block = content[0..header_end];
    if (memory_mod.metadataValue(header_block, LEARNED_ORIGIN_PREFIX)) |slice| {
        header.origin = LearnedOrigin.fromSlice(slice);
    }
    if (memory_mod.metadataValue(header_block, LEARNED_STATE_PREFIX)) |slice| {
        header.state = LearnedState.fromSlice(slice);
    }
    return header;
}

/// stripLearnedMetadataHeader returns the human-readable fact body, with
/// any leading origin=/state=/evidence_run_ids= header lines removed.
///
/// Header lines are terminated by the first blank line (matching the
/// appendOriginMetadata idiom in commands.zig), and MUST start at byte 0
/// (see headerBlockEnd) — content with no real leading header (the legacy
/// shape, or user-authored text that merely contains a header-shaped line
/// in its body) is returned unchanged. This is what makes the existing
/// user_correction path's stored content round-trip identically through
/// this function.
pub fn stripLearnedMetadataHeader(content: []const u8) []const u8 {
    const header_end = headerBlockEnd(content) orelse return content;
    return content[header_end..];
}

/// buildLearnedMetadataHeader writes the `origin=`/`state=`/
/// `evidence_run_ids=` header block (each line \n-terminated, followed by
/// a blank line) for a fact birthed with the given origin/evidence.
/// Caller frees the returned slice.
fn buildLearnedMetadataHeader(
    allocator: std.mem.Allocator,
    origin: LearnedOrigin,
    state: LearnedState,
    evidence_run_ids: []const []const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.print("{s}{s}\n", .{ LEARNED_ORIGIN_PREFIX, origin.toSlice() });
    try w.print("{s}{s}\n", .{ LEARNED_STATE_PREFIX, state.toSlice() });
    if (evidence_run_ids.len > 0) {
        try w.writeAll(LEARNED_EVIDENCE_PREFIX);
        for (evidence_run_ids, 0..) |run_id, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll(run_id);
        }
        try w.writeByte('\n');
    }
    try w.writeByte('\n');
    return buf.toOwnedSlice(allocator);
}

/// buildLearnedMetadataJson writes the JSONB metadata blob passed to
/// Memory.storeWithMetadata — the real, SQL-queryable side-channel on the
/// Postgres backend (see zaki_postgres.zig::implStoreWithMetadata). Other
/// backends silently drop this (memory/root.zig's storeWithMetadata falls
/// back to plain store() when the vtable slot is null); the content header
/// built by buildLearnedMetadataHeader is the backend-agnostic source of
/// truth used by the injection gate and /learn list.
fn buildLearnedMetadataJson(
    allocator: std.mem.Allocator,
    origin: LearnedOrigin,
    state: LearnedState,
    evidence_run_ids: []const []const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.print("{{\"origin\":\"{s}\",\"state\":\"{s}\"", .{ origin.toSlice(), state.toSlice() });
    if (evidence_run_ids.len > 0) {
        try w.writeAll(",\"evidence_run_ids\":[");
        for (evidence_run_ids, 0..) |run_id, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte('"');
            try writeJsonEscapedRunId(w, run_id);
            try w.writeByte('"');
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

fn writeJsonEscapedRunId(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
}

pub const StoreLearnedResult = struct {
    /// Whether the fact was actually written. False when refused (empty
    /// content) or dropped (MAX_FACTS_PER_SESSION reached) — never false
    /// for a silently-swallowed store error; those are returned as `!` errors.
    stored: bool,
    /// The durable_fact/behavior/ key (owned, caller frees via deinit).
    /// Always populated (even when stored=false) so callers can log which
    /// key was refused/dropped.
    key: []const u8,
    /// The birth-state this fact was stamped with (birthState(origin)).
    /// Meaningful only when stored=true.
    state: LearnedState,

    pub fn deinit(self: StoreLearnedResult, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

pub const StoreLearnedError = error{EmptyContent} || std.mem.Allocator.Error || anyerror;

/// storeLearnedFact writes a behavior fact carrying full provenance
/// (learning contract axis 1 + 4): origin is stamped immutably, state is
/// derived via birthState(origin) (axis 4 — the birth-state law, inv. 1:
/// only user_correction/operator birth active; everything else births
/// shadow and awaits an external gate).
///
/// Keys via the existing factKey() content hash (same dedup semantics as
/// the pre-Task-2 fast path). Refuses empty content. Respects
/// MAX_FACTS_PER_SESSION — scans existing durable_fact/behavior/ entries
/// for the given session_id (mirrors the lazy-count idiom in root.zig);
/// at the cap, returns `.{ .stored = false, ... }` rather than erroring,
/// so callers can log-and-continue exactly like the existing signal path.
///
/// Writes the provenance header into `content` (the backend-agnostic,
/// in-process-readable source of truth — see the module doc comment
/// above) AND calls storeWithMetadata with an equivalent JSON blob (the
/// real side-channel on Postgres, per the brief's storeWithMetadata idiom;
/// no-ops elsewhere).
pub fn storeLearnedFact(
    allocator: std.mem.Allocator,
    mem: Memory,
    content: []const u8,
    origin: LearnedOrigin,
    evidence_run_ids: []const []const u8,
    session_id: ?[]const u8,
) StoreLearnedError!StoreLearnedResult {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyContent;

    const state = birthState(origin);
    const key = try factKey(allocator, trimmed);
    errdefer allocator.free(key);

    // MAX_FACTS_PER_SESSION — count existing durable_fact/behavior/ entries
    // scoped to this session_id. Mirrors root.zig's lazy per-session scan;
    // storeLearnedFact has no persistent counter to amortize this across
    // calls (that optimization lives in the agent struct, not here), so
    // this is O(N) over session entries per call — acceptable for the
    // mining/adoption call sites (Task 3+), which are not per-turn-hot.
    const entries: []MemoryEntry = mem.list(allocator, null, session_id) catch try allocator.alloc(MemoryEntry, 0);
    defer memory_mod.freeEntries(allocator, entries);
    var fact_count: usize = 0;
    for (entries) |e| {
        if (std.mem.startsWith(u8, e.key, "durable_fact/behavior/")) fact_count += 1;
    }
    if (fact_count >= MAX_FACTS_PER_SESSION) {
        return .{ .stored = false, .key = key, .state = state };
    }

    const header = try buildLearnedMetadataHeader(allocator, origin, state, evidence_run_ids);
    defer allocator.free(header);
    const stored_content = try std.mem.concat(allocator, u8, &.{ header, trimmed });
    defer allocator.free(stored_content);

    const metadata_json = try buildLearnedMetadataJson(allocator, origin, state, evidence_run_ids);
    defer allocator.free(metadata_json);

    try mem.storeWithMetadata(key, stored_content, .core, session_id, metadata_json);

    return .{ .stored = true, .key = key, .state = state };
}

/// extractFactFromMessage extracts a behavioral instruction from a user message
/// given the detected signals.
///
/// Rules:
///   - explicit_preference: returns a copy of the full message (e.g., "always respond in English")
///   - explicit_correction: returns a copy of the full message (corrections are
///     context-dependent; the full message provides context)
///   - implicit_correction only: returns null (insufficient context in a single message)
///   - empty message: returns null
///
/// The returned slice (when non-null) is allocated with the provided allocator.
/// Returns null if no extractable fact is found.
pub fn extractFactFromMessage(
    allocator: std.mem.Allocator,
    user_message: []const u8,
    signals: []const LearningSignal,
) !?[]const u8 {
    const trimmed = std.mem.trim(u8, user_message, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (signals.len == 0) return null;

    for (signals) |sig| {
        switch (sig) {
            .explicit_preference, .explicit_correction => {
                return try allocator.dupe(u8, trimmed);
            },
            .implicit_correction => {
                // implicit corrections lack enough context; skip unless another
                // higher-priority signal was also detected (handled by priority order above).
            },
        }
    }

    return null;
}

// ── Inline tests ──────────────────────────────────────────────────────────────

test "MAX_FACTS_PER_SESSION is 250 (V1.13 lifted from 100)" {
    try std.testing.expectEqual(@as(usize, 250), MAX_FACTS_PER_SESSION);
}

test "detectLearningSignals finds explicit_correction for 'no, actually'" {
    const allocator = std.testing.allocator;
    const sigs = try detectLearningSignals(allocator, "No, actually do X instead");
    defer allocator.free(sigs);
    try std.testing.expect(sigs.len >= 1);
    try std.testing.expectEqual(LearningSignal.explicit_correction, sigs[0]);
}

test "detectLearningSignals finds explicit_correction for 'that's wrong'" {
    const allocator = std.testing.allocator;
    const sigs = try detectLearningSignals(allocator, "That's wrong, I need the other approach");
    defer allocator.free(sigs);
    var found_correction = false;
    for (sigs) |s| {
        if (s == .explicit_correction) found_correction = true;
    }
    try std.testing.expect(found_correction);
}

test "detectLearningSignals finds explicit_preference for 'always respond in English'" {
    const allocator = std.testing.allocator;
    const sigs = try detectLearningSignals(allocator, "Always respond in English");
    defer allocator.free(sigs);
    var found = false;
    for (sigs) |s| {
        if (s == .explicit_preference) found = true;
    }
    try std.testing.expect(found);
}

test "detectLearningSignals finds explicit_preference for 'prefer concise answers'" {
    const allocator = std.testing.allocator;
    const sigs = try detectLearningSignals(allocator, "I prefer concise answers");
    defer allocator.free(sigs);
    var found = false;
    for (sigs) |s| {
        if (s == .explicit_preference) found = true;
    }
    try std.testing.expect(found);
}

test "detectLearningSignals returns empty for normal conversational messages" {
    const allocator = std.testing.allocator;
    {
        const sigs = try detectLearningSignals(allocator, "thanks");
        defer allocator.free(sigs);
        try std.testing.expectEqual(@as(usize, 0), sigs.len);
    }
    {
        const sigs = try detectLearningSignals(allocator, "what time is it?");
        defer allocator.free(sigs);
        try std.testing.expectEqual(@as(usize, 0), sigs.len);
    }
}

test "detectLearningSignals finds implicit_correction for 'I meant the other one'" {
    const allocator = std.testing.allocator;
    const sigs = try detectLearningSignals(allocator, "I meant the other one");
    defer allocator.free(sigs);
    // "i meant" is in explicit_correction patterns too, so this could be either
    var found_any_correction = false;
    for (sigs) |s| {
        if (s == .implicit_correction or s == .explicit_correction) found_any_correction = true;
    }
    try std.testing.expect(found_any_correction);
}

test "detectLearningSignals finds implicit_correction for 'let me rephrase'" {
    const allocator = std.testing.allocator;
    const sigs = try detectLearningSignals(allocator, "Let me rephrase what I said");
    defer allocator.free(sigs);
    var found = false;
    for (sigs) |s| {
        if (s == .implicit_correction) found = true;
    }
    try std.testing.expect(found);
}

test "detectLearningSignals deduplicates signals" {
    const allocator = std.testing.allocator;
    // Message triggers both correction patterns and preference patterns
    const sigs = try detectLearningSignals(allocator, "No, actually, always respond in English from now on");
    defer allocator.free(sigs);
    // Should have at most one of each type
    var corr_count: usize = 0;
    var pref_count: usize = 0;
    for (sigs) |s| {
        if (s == .explicit_correction) corr_count += 1;
        if (s == .explicit_preference) pref_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), corr_count);
    try std.testing.expectEqual(@as(usize, 1), pref_count);
}

test "factKey generates durable_fact/behavior/ prefixed key" {
    const allocator = std.testing.allocator;
    const key = try factKey(allocator, "always respond in English");
    defer allocator.free(key);
    try std.testing.expect(std.mem.startsWith(u8, key, "durable_fact/behavior/"));
}

test "factKey generates a stable key for the same fact content" {
    const allocator = std.testing.allocator;
    const key1 = try factKey(allocator, "always respond in English");
    defer allocator.free(key1);
    const key2 = try factKey(allocator, "always respond in English");
    defer allocator.free(key2);
    try std.testing.expectEqualStrings(key1, key2);
}

test "factKey key has expected format length (durable_fact/behavior/ + 16 hex chars)" {
    const allocator = std.testing.allocator;
    const key = try factKey(allocator, "prefer concise answers");
    defer allocator.free(key);
    // "durable_fact/behavior/" = 22 chars + 16 hex chars = 38 total
    try std.testing.expectEqual(@as(usize, 38), key.len);
}

test "factKey is case-insensitive (same key for different cases)" {
    const allocator = std.testing.allocator;
    const key1 = try factKey(allocator, "Always Respond In English");
    defer allocator.free(key1);
    const key2 = try factKey(allocator, "always respond in english");
    defer allocator.free(key2);
    try std.testing.expectEqualStrings(key1, key2);
}

test "formatFactForEnrichment returns fact content as-is" {
    const content = "Always respond in English";
    const result = formatFactForEnrichment(content);
    try std.testing.expectEqualStrings(content, result);
}

test "extractFactFromMessage returns copy for explicit_preference" {
    const allocator = std.testing.allocator;
    const sigs = [_]LearningSignal{.explicit_preference};
    const msg = "Always respond in English";
    const result = try extractFactFromMessage(allocator, msg, &sigs);
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings(msg, result.?);
}

test "extractFactFromMessage returns copy for explicit_correction" {
    const allocator = std.testing.allocator;
    const sigs = [_]LearningSignal{.explicit_correction};
    const msg = "No, actually use snake_case";
    const result = try extractFactFromMessage(allocator, msg, &sigs);
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings(msg, result.?);
}

test "extractFactFromMessage returns null for implicit_correction only" {
    const allocator = std.testing.allocator;
    const sigs = [_]LearningSignal{.implicit_correction};
    const result = try extractFactFromMessage(allocator, "I meant the other one", &sigs);
    try std.testing.expect(result == null);
}

test "extractFactFromMessage returns null for empty signals" {
    const allocator = std.testing.allocator;
    const sigs = [_]LearningSignal{};
    const result = try extractFactFromMessage(allocator, "hello", &sigs);
    try std.testing.expect(result == null);
}

test "extractFactFromMessage returns null for empty message" {
    const allocator = std.testing.allocator;
    const sigs = [_]LearningSignal{.explicit_preference};
    const result = try extractFactFromMessage(allocator, "   ", &sigs);
    try std.testing.expect(result == null);
}

// ── storeLearnedFact: provenance-typed store (Task 2) ──────────────────────
// Package 2a Task 2 — every behavior fact write carries origin + state.
// The user_correction fast path (root.zig ~4319) is UNCHANGED by this task;
// these tests cover the NEW storeLearnedFact API that Task 3 (mining) will
// call for observed_success/observed_failure/mined_aggregate origins.

test "storeLearnedFact: user_correction stamps origin=user_correction, state=active" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    const result = try storeLearnedFact(
        allocator,
        mem,
        "always respond in English",
        .user_correction,
        &.{},
        "session-1",
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.stored);
    const entry = (try mem.get(allocator, result.key)) orelse return error.EntryNotFound;
    defer entry.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, entry.content, "origin=user_correction") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.content, "state=active") != null);
}

test "storeLearnedFact: mined_aggregate stamps origin=mined_aggregate, state=shadow (inv. 1 — no self-promotion)" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    const result = try storeLearnedFact(
        allocator,
        mem,
        "retry with exponential backoff on 429s",
        .mined_aggregate,
        &.{},
        "session-1",
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.stored);
    try std.testing.expectEqual(LearnedState.shadow, result.state);
    const entry = (try mem.get(allocator, result.key)) orelse return error.EntryNotFound;
    defer entry.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, entry.content, "origin=mined_aggregate") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.content, "state=shadow") != null);
}

test "storeLearnedFact: evidence run_ids are serialized into stored content" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    const run_ids = [_][]const u8{ "run-abc123", "run-def456" };
    const result = try storeLearnedFact(
        allocator,
        mem,
        "prefer terse commit messages",
        .observed_success,
        &run_ids,
        "session-1",
    );
    defer result.deinit(allocator);

    const entry = (try mem.get(allocator, result.key)) orelse return error.EntryNotFound;
    defer entry.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, entry.content, "run-abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry.content, "run-def456") != null);
}

test "storeLearnedFact: rejects empty content" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    const result = storeLearnedFact(allocator, mem, "   ", .user_correction, &.{}, "session-1");
    try std.testing.expectError(error.EmptyContent, result);
}

test "storeLearnedFact: respects MAX_FACTS_PER_SESSION" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var i: usize = 0;
    while (i < MAX_FACTS_PER_SESSION) : (i += 1) {
        const content = try std.fmt.allocPrint(allocator, "fact number {d}", .{i});
        defer allocator.free(content);
        const r = try storeLearnedFact(allocator, mem, content, .user_correction, &.{}, "session-full");
        defer r.deinit(allocator);
        try std.testing.expect(r.stored);
    }

    // One more, over the cap — must be refused, not errored.
    const over_cap = try storeLearnedFact(allocator, mem, "one fact too many", .user_correction, &.{}, "session-full");
    defer over_cap.deinit(allocator);
    try std.testing.expect(!over_cap.stored);
}

test "parseLearnedMetadataHeader: round-trips origin + state through stored content" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    const result = try storeLearnedFact(allocator, mem, "always ack tool errors", .observed_failure, &.{}, "session-1");
    defer result.deinit(allocator);

    const entry = (try mem.get(allocator, result.key)) orelse return error.EntryNotFound;
    defer entry.deinit(allocator);

    const header = parseLearnedMetadataHeader(entry.content);
    try std.testing.expectEqual(LearnedOrigin.observed_failure, header.origin.?);
    try std.testing.expectEqual(LearnedState.shadow, header.state.?);
}

test "parseLearnedMetadataHeader: legacy content with no header parses as null/null" {
    const header = parseLearnedMetadataHeader("always respond in English");
    try std.testing.expectEqual(@as(?LearnedOrigin, null), header.origin);
    try std.testing.expectEqual(@as(?LearnedState, null), header.state);
}

test "stripLearnedMetadataHeader: strips header down to the human-readable body" {
    const allocator = std.testing.allocator;
    var sqlite_mem = try memory_mod.SqliteMemory.init(allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    const result = try storeLearnedFact(allocator, mem, "prefer dark mode", .user_correction, &.{}, "session-1");
    defer result.deinit(allocator);

    const entry = (try mem.get(allocator, result.key)) orelse return error.EntryNotFound;
    defer entry.deinit(allocator);

    const body = stripLearnedMetadataHeader(entry.content);
    try std.testing.expectEqualStrings("prefer dark mode", body);
}

test "stripLearnedMetadataHeader: legacy content with no header is returned unchanged (byte-identical)" {
    const legacy = "always respond in English";
    try std.testing.expectEqualStrings(legacy, stripLearnedMetadataHeader(legacy));
}

// ── Hardening: a legacy fact whose BODY happens to contain a line that
// looks like a metadata header must not be misparsed as a real header.
// metadataValue() scans every line of content (not just a leading block),
// so a legacy user-correction fact whose multi-line text incidentally
// contains a line starting with "state=" or "origin=" deep in the body
// could otherwise be misclassified by parseLearnedMetadataHeader. Only a
// LEADING header (line 0 = origin=, line 1 = state=) is a real header;
// this predicate is what parseLearnedMetadataHeader/stripLearnedMetadataHeader
// must agree on so the injection gate can't be tricked into hiding a
// legitimate active fact by user-authored text.
test "parseLearnedMetadataHeader: a state=-shaped line buried in the BODY (not the leading header) does not parse as a header" {
    // Legacy shape (no real header — this is exactly what the unmodified
    // user_correction fast path would store): the correction text itself
    // happens to contain a line that looks like a header key on line 3.
    const legacy_with_embedded_lookalike =
        "always keep this setting:\n" ++
        "some other line\n" ++
        "state=shadow\n" ++
        "the rest of the correction";
    const header = parseLearnedMetadataHeader(legacy_with_embedded_lookalike);
    try std.testing.expectEqual(@as(?LearnedState, null), header.state);
}

test {
    _ = @import("learning_contract_test.zig");
}
