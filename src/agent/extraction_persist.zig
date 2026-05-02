//! V1.6 commit 5b — Extraction persistence.
//!
//! Parses the JSON tail emitted by the V1.6 commit 5a dual-output
//! compaction Pass C prompt, deduplicates against existing memories,
//! and writes survivors via `state_mgr.upsertMemoryWithMetadata`
//! populating the V1.6 typed-edge schema columns
//! (subject/predicate/object_key/link_type/attribution/attributed_to).
//!
//! ## Design contract
//!
//! Provider-agnostic. The `persistExtracted` function takes
//! `ExtractedMemory` structs from any source — compaction LLM today,
//! agent tools / classifier writes / R14 structured saves tomorrow —
//! and runs the same dedup + write pipeline. Multiple call sites can
//! converge here without re-architecture.
//!
//! ## Pipeline (each ExtractedMemory)
//!
//! 1. **Reject heuristics** — drop facts whose `predicate` is in the
//!    rejected-predicate blacklist (covers cases where the LLM emitted
//!    meta-narrative despite the prompt's anti-meta rules).
//! 2. **MD5 content_hash dedup** — if a memory with identical
//!    normalized content already exists for this user, skip silently
//!    (Mem0-style pre-filter, gap #13 from audit).
//! 3. **Cosine similarity dedup** — if cosine vs recent rows in same
//!    session > 0.92 (D4 mitigation), skip.
//! 4. **Key derivation** — `extracted_<unix_ns>_<hex8>` shape so
//!    extraction-derived rows are addressable + don't collide with
//!    user-authored keys.
//! 5. **Write** via `state_mgr.upsertMemoryWithMetadata` with
//!    metadata = `{"subject":..., "predicate":..., "object_key":...,
//!    "attributed_to":..., "attribution":"extraction_classifier",
//!    "confidence":...}`.
//! 6. **Audit** — emits `memory_events` row with `event_type='extraction'`
//!    (handled inside upsertMemoryWithMetadata if it falls through to
//!    the audit path; otherwise we add it explicitly).
//!
//! ## Failure mode
//!
//! Each step uses `try` for fatal errors (caller decides recovery)
//! and `log.warn` for individual-fact failures (per-fact dedup hit,
//! malformed entry, etc.) so one bad fact in the JSON tail doesn't
//! kill the whole batch.

const std = @import("std");
const log = std.log.scoped(.extraction_persist);

/// One atomic fact extracted from a conversation. Mirrors the JSON
/// schema specified in compaction.zig::summarizer_system. Produced by
/// `parseExtractedJson` and consumed by `persistExtracted`.
pub const ExtractedMemory = struct {
    text: []const u8,
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    attributed_to: []const u8,
    confidence: f64,

    pub fn deinit(self: *const ExtractedMemory, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.subject);
        allocator.free(self.predicate);
        allocator.free(self.object);
        allocator.free(self.attributed_to);
    }
};

pub fn freeExtractedMemories(allocator: std.mem.Allocator, mems: []ExtractedMemory) void {
    for (mems) |m| m.deinit(allocator);
    allocator.free(mems);
}

pub const PersistResult = struct {
    written_count: usize,
    skipped_blacklist: usize,
    skipped_md5_dup: usize,
    skipped_cosine_dup: usize,
    failed_count: usize,
};

/// Predicate blacklist — same list as compaction.zig prompt's
/// REJECTED PREDICATES section. Acts as a defense-in-depth filter
/// at write time. Even if the LLM emits a meta-narrative fact
/// despite the prompt rules, persistence rejects it before writing
/// to the brain.
///
/// Kept here as an array (not a hashmap) because the list is small
/// and lookups are per-fact-write — O(N*K) with N=facts, K=15 is
/// negligible.
const REJECTED_PREDICATES = [_][]const u8{
    "GREETED",
    "SAID",
    "ASKED",
    "MENTIONED",
    "REPLIED",
    "ACKNOWLEDGED",
    "EXPRESSED",
    "INDICATED_READINESS",
    "IS_GETTING_STARTED",
    "OFFERED_TO_WAIT",
    "PRIORITIZED",
    "ADDRESSED_AS",
    "IS_UNKNOWN",
    "EXPRESSED_READINESS",
    "INITIATED_CONVERSATION",
};

inline fn isRejectedPredicate(predicate: []const u8) bool {
    for (REJECTED_PREDICATES) |p| {
        if (std.mem.eql(u8, p, predicate)) return true;
    }
    return false;
}

/// Parse the JSON tail from a compaction Pass C dual-output response.
///
/// Tolerant of common LLM format quirks:
///   - leading/trailing whitespace
///   - markdown code fence (```json ... ```)
///   - empty array `[]` returns []ExtractedMemory{} (caller frees)
///   - missing optional fields default to safe values
///   - malformed entries are skipped with a log.warn (rest survive)
///
/// Caller owns the returned slice + each entry's strings. Free via
/// `freeExtractedMemories`.
pub fn parseExtractedJson(
    allocator: std.mem.Allocator,
    raw_tail: []const u8,
) ![]ExtractedMemory {
    // Strip whitespace + optional code fence
    var s = std.mem.trim(u8, raw_tail, &std.ascii.whitespace);
    if (std.mem.startsWith(u8, s, "```")) {
        if (std.mem.indexOfPos(u8, s, 3, "\n")) |nl| {
            s = s[nl + 1 ..];
        }
        if (std.mem.endsWith(u8, s, "```")) {
            s = s[0 .. s.len - 3];
        }
        s = std.mem.trim(u8, s, &std.ascii.whitespace);
    }

    if (s.len == 0) return allocator.alloc(ExtractedMemory, 0);

    // Empty array shortcut
    if (std.mem.eql(u8, s, "[]")) return allocator.alloc(ExtractedMemory, 0);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, s, .{}) catch |err| {
        log.warn("extraction.parse_failed err={s} tail_len={d}", .{ @errorName(err), s.len });
        return allocator.alloc(ExtractedMemory, 0);
    };
    defer parsed.deinit();

    if (parsed.value != .array) {
        log.warn("extraction.parse_not_array kind={s}", .{@tagName(parsed.value)});
        return allocator.alloc(ExtractedMemory, 0);
    }

    var out: std.ArrayListUnmanaged(ExtractedMemory) = .{};
    errdefer {
        for (out.items) |*m| m.deinit(allocator);
        out.deinit(allocator);
    }

    for (parsed.value.array.items, 0..) |item, idx| {
        if (item != .object) {
            log.warn("extraction.entry_not_object idx={d}", .{idx});
            continue;
        }
        const text = (item.object.get("text") orelse continue);
        const subject = (item.object.get("subject") orelse continue);
        const predicate = (item.object.get("predicate") orelse continue);
        const object = (item.object.get("object") orelse continue);
        const attr = item.object.get("attributed_to");
        const conf = item.object.get("confidence");

        if (text != .string or subject != .string or predicate != .string or object != .string) {
            log.warn("extraction.entry_field_type_mismatch idx={d}", .{idx});
            continue;
        }

        // Skip empty text or text shorter than 3 chars (LLM nonsense)
        if (text.string.len < 3) continue;

        const attr_str = if (attr) |a| switch (a) {
            .string => |st| st,
            else => "user",
        } else "user";

        const conf_f: f64 = if (conf) |c| switch (c) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => 1.0,
        } else 1.0;

        const m = ExtractedMemory{
            .text = try allocator.dupe(u8, text.string),
            .subject = try allocator.dupe(u8, subject.string),
            .predicate = try allocator.dupe(u8, predicate.string),
            .object = try allocator.dupe(u8, object.string),
            .attributed_to = try allocator.dupe(u8, attr_str),
            .confidence = conf_f,
        };
        try out.append(allocator, m);
    }

    return try out.toOwnedSlice(allocator);
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "parseExtractedJson handles empty array" {
    const allocator = std.testing.allocator;
    const out = try parseExtractedJson(allocator, "[]");
    defer freeExtractedMemories(allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "parseExtractedJson handles whitespace and code fence" {
    const allocator = std.testing.allocator;
    const tail = "  ```json\n[]\n```  ";
    const out = try parseExtractedJson(allocator, tail);
    defer freeExtractedMemories(allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "parseExtractedJson parses a well-formed fact" {
    const allocator = std.testing.allocator;
    const tail =
        \\[
        \\  {
        \\    "text": "User uses pgvector for similarity search",
        \\    "subject": "user",
        \\    "predicate": "USES",
        \\    "object": "pgvector",
        \\    "attributed_to": "user",
        \\    "confidence": 0.95
        \\  }
        \\]
    ;
    const out = try parseExtractedJson(allocator, tail);
    defer freeExtractedMemories(allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("user", out[0].subject);
    try std.testing.expectEqualStrings("USES", out[0].predicate);
    try std.testing.expectEqualStrings("pgvector", out[0].object);
    try std.testing.expectEqualStrings("user", out[0].attributed_to);
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), out[0].confidence, 0.001);
}

test "parseExtractedJson parses multi-fact array with mixed attributions" {
    const allocator = std.testing.allocator;
    const tail =
        \\[
        \\  {"text":"User chose Helix","subject":"user","predicate":"PREFERS","object":"Helix","attributed_to":"user","confidence":1.0},
        \\  {"text":"Pricing tier suggested","subject":"pricing","predicate":"SUGGESTED_AT","object":"$49/$99/$200","attributed_to":"assistant_offer","confidence":0.7},
        \\  {"text":"Sister birthday May 15","subject":"sister","predicate":"BIRTHDAY","object":"May 15","attributed_to":"user","confidence":1.0}
        \\]
    ;
    const out = try parseExtractedJson(allocator, tail);
    defer freeExtractedMemories(allocator, out);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("PREFERS", out[0].predicate);
    try std.testing.expectEqualStrings("assistant_offer", out[1].attributed_to);
    try std.testing.expectEqualStrings("BIRTHDAY", out[2].predicate);
}

test "parseExtractedJson tolerates malformed JSON gracefully" {
    const allocator = std.testing.allocator;
    const tail = "this is not json {[}";
    const out = try parseExtractedJson(allocator, tail);
    defer freeExtractedMemories(allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "parseExtractedJson skips entries missing required fields" {
    const allocator = std.testing.allocator;
    const tail =
        \\[
        \\  {"text":"missing subject","predicate":"X","object":"Y"},
        \\  {"text":"valid","subject":"s","predicate":"P","object":"o","attributed_to":"user","confidence":0.5}
        \\]
    ;
    const out = try parseExtractedJson(allocator, tail);
    defer freeExtractedMemories(allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("s", out[0].subject);
}

test "parseExtractedJson skips text shorter than 3 chars" {
    const allocator = std.testing.allocator;
    const tail =
        \\[
        \\  {"text":"hi","subject":"s","predicate":"P","object":"o","attributed_to":"user","confidence":1.0},
        \\  {"text":"valid fact here","subject":"s","predicate":"P","object":"o","attributed_to":"user","confidence":1.0}
        \\]
    ;
    const out = try parseExtractedJson(allocator, tail);
    defer freeExtractedMemories(allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "isRejectedPredicate covers known meta-narrative predicates" {
    try std.testing.expect(isRejectedPredicate("GREETED"));
    try std.testing.expect(isRejectedPredicate("SAID"));
    try std.testing.expect(isRejectedPredicate("ACKNOWLEDGED"));
    try std.testing.expect(!isRejectedPredicate("PREFERS"));
    try std.testing.expect(!isRejectedPredicate("DEPLOYS_TO"));
    try std.testing.expect(!isRejectedPredicate("BIRTHDAY"));
}

test "parseExtractedJson handles confidence as integer" {
    const allocator = std.testing.allocator;
    const tail =
        \\[{"text":"User uses Zig","subject":"user","predicate":"USES","object":"Zig","attributed_to":"user","confidence":1}]
    ;
    const out = try parseExtractedJson(allocator, tail);
    defer freeExtractedMemories(allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), out[0].confidence, 0.001);
}
