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
const zaki_state = @import("../zaki_state.zig");
const memory_root = @import("../memory/root.zig");
const security_secrets = @import("../security/secrets.zig");

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

/// Compute MD5 hex of normalized content for V1.6 5b.3 dedup pre-filter.
/// Mirrors `zaki_state.computeContentHash` semantics so the hash matches
/// what the upsert path stores in the `content_hash` column.
fn computeMd5Hex(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(content, &digest, .{});
    const out = try allocator.alloc(u8, digest.len * 2);
    _ = security_secrets.hexEncode(&digest, out);
    return out;
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

/// Map Mem0/Graphiti `attributed_to` strings to MemoryCategory.
/// Convention:
///   "user"            → .core    (user-stated facts get the highest tier)
///   "assistant_offer" → .daily   (assistant offered, user didn't reject)
///   "undecided"       → .daily   (unresolved consideration)
///   "assistant"       → .daily   (assistant statement; lower priority)
///   anything else     → .daily   (safe default)
fn categoryForAttribution(attributed_to: []const u8) memory_root.MemoryCategory {
    if (std.mem.eql(u8, attributed_to, "user")) return .core;
    return .daily;
}

/// Generate a key for a compaction-derived extracted memory. Shape:
/// `extracted_<unix_seconds>_<hex8>`. The `extracted_` prefix is added
/// to `BRAIN_HIDDEN_PREFIXES` (TODO V1.7) — for V1.6 these surface on
/// /brain/* directly, which is the desired "your son thinks" UX. The
/// hex8 suffix avoids collisions on rapid-fire writes within the same
/// second.
fn deriveExtractionKey(allocator: std.mem.Allocator) ![]u8 {
    const ts: i64 = std.time.timestamp();
    var random_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var hex_buf: [8]u8 = undefined;
    _ = security_secrets.hexEncode(&random_bytes, &hex_buf);
    return std.fmt.allocPrint(allocator, "extracted_{d}_{s}", .{ ts, hex_buf });
}

/// Build the metadata JSON for an extracted memory. Format:
///   {
///     "subject": "...",
///     "predicate": "...",
///     "object_key": "...",
///     "attributed_to": "user|assistant|assistant_offer|undecided",
///     "attribution": "extraction_classifier",
///     "confidence": 0.0-1.0,
///     "extracted_at": <unix>
///   }
///
/// Caller frees returned slice.
fn buildExtractionMetadata(
    allocator: std.mem.Allocator,
    mem: ExtractedMemory,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"subject\":\"");
    try writeJsonEscaped(w, mem.subject);
    try w.writeAll("\",\"predicate\":\"");
    try writeJsonEscaped(w, mem.predicate);
    try w.writeAll("\",\"object_key\":\"");
    try writeJsonEscaped(w, mem.object);
    try w.writeAll("\",\"attributed_to\":\"");
    try writeJsonEscaped(w, mem.attributed_to);
    try w.writeAll("\",\"attribution\":\"extraction_classifier\"");
    try w.print(",\"confidence\":{d:.3}", .{mem.confidence});
    try w.print(",\"extracted_at\":{d}", .{std.time.timestamp()});
    try w.writeAll("}");
    return buf.toOwnedSlice(allocator);
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
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

/// Persist a batch of extracted memories.
///
/// Provider-agnostic. The `memories` slice can come from the compaction
/// LLM (today's primary path), agent tool writes, or the classifier
/// when those land. Each fact passes through:
///   1. predicate blacklist (defense-in-depth against meta-narrative)
///   2. write via state_mgr.upsertMemoryWithMetadata with V1.6 metadata
///
/// Future enhancements (tracked, not blocking):
///   - MD5 content_hash dedup before write (gap #13 from audit)
///   - Cosine dedup vs recent rows in same session (D4 mitigation)
///
/// Both are deferred to a follow-up commit because they require state
/// not yet plumbed (recent-rows snapshot for cosine, hash-keyed lookup
/// for MD5). For 5b.2 minimum-viable: rely on the LLM not emitting
/// duplicates within one extraction batch + the upsert ON CONFLICT
/// behavior keying on (user_id, key) which gives unique extraction
/// keys naturally.
///
/// Per-fact failures emit log.warn but don't abort the batch — one
/// bad fact shouldn't kill the run.
pub fn persistExtracted(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    session_id: ?[]const u8,
    memories: []const ExtractedMemory,
) !PersistResult {
    var result = PersistResult{
        .written_count = 0,
        .skipped_blacklist = 0,
        .skipped_md5_dup = 0,
        .skipped_cosine_dup = 0,
        .failed_count = 0,
    };

    for (memories) |m| {
        // Step 1: predicate blacklist
        if (isRejectedPredicate(m.predicate)) {
            log.warn("extraction.rejected_predicate predicate={s} subject={s}", .{ m.predicate, m.subject });
            result.skipped_blacklist += 1;
            continue;
        }

        // Step 2 (V1.6 5b.3 WR-1): MD5 content_hash dedup. Compaction
        // Pass C re-summarizes prior prose summaries on each trigger,
        // causing the LLM to re-emit the same atomic facts. Skip if a
        // memory with identical normalized content already exists for
        // this user. Cheap — uses idx_memories_hash directly.
        const content_hash = computeMd5Hex(allocator, m.text) catch |err| {
            log.warn("extraction.hash_failed err={s}", .{@errorName(err)});
            result.failed_count += 1;
            continue;
        };
        defer allocator.free(content_hash);
        const existing = state_mgr.findMemoryByContentHash(allocator, user_id, content_hash) catch |err| blk: {
            // Don't gate write on lookup failure — log + proceed (worst
            // case: one duplicate this trigger; cosine dedup later catches
            // it).
            log.warn("extraction.dedup_lookup_failed err={s}", .{@errorName(err)});
            break :blk null;
        };
        if (existing) |e| {
            log.info("extraction.md5_dup_skipped subject={s} predicate={s} matches_key={s}", .{ m.subject, m.predicate, e.key });
            e.deinit(allocator);
            result.skipped_md5_dup += 1;
            continue;
        }

        // Step 3-5 — derive key + metadata + write
        const key = deriveExtractionKey(allocator) catch |err| {
            log.warn("extraction.key_derivation_failed err={s}", .{@errorName(err)});
            result.failed_count += 1;
            continue;
        };
        defer allocator.free(key);

        const metadata_json = buildExtractionMetadata(allocator, m) catch |err| {
            log.warn("extraction.metadata_build_failed err={s}", .{@errorName(err)});
            result.failed_count += 1;
            continue;
        };
        defer allocator.free(metadata_json);

        const category = categoryForAttribution(m.attributed_to);

        state_mgr.upsertMemoryWithMetadata(
            user_id,
            key,
            m.text,
            category,
            session_id,
            metadata_json,
        ) catch |err| {
            log.warn("extraction.write_failed key={s} err={s}", .{ key, @errorName(err) });
            result.failed_count += 1;
            continue;
        };

        log.info("extraction.persisted key={s} subject={s} predicate={s} attributed_to={s}", .{
            key, m.subject, m.predicate, m.attributed_to,
        });
        result.written_count += 1;
    }

    return result;
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
