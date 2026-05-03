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
const providers = @import("../providers/root.zig");
const edge_resolution = @import("edge_resolution.zig");
const memory_embeddings = @import("../memory/vector/embeddings.zig");
const text_norm = @import("../memory/text_norm.zig");

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
    /// V1.6 commit 6 — facts the contradiction judge marked as semantic
    /// duplicates of an existing extraction-classifier memory. Distinct
    /// from `skipped_md5_dup` (which catches byte-identical content):
    /// this catches "User uses Helix" vs "Helix is what user uses" — the
    /// judge says they're the same fact under different phrasing.
    skipped_semantic_dup: usize = 0,
    /// V1.6 commit 6 — count of existing rows the new batch closed out
    /// via `setMemoryInvalidation`. One contradicting NEW fact may close
    /// multiple older rows (e.g. correcting a chain of stale prefs).
    contradictions_resolved: usize = 0,
    failed_count: usize,
};

/// V1.6 commit 6 — optional context for the contradiction LLM judge.
///
/// Callers that have an LLM provider in scope (compaction Pass C is the
/// primary case today) pass this struct to enable bi-temporal close-out.
/// Callers without a provider (agent tool writes, classifier writes that
/// land in V1.7) pass `null` and persist proceeds with MD5 dedup only.
///
/// Provider must implement `chat()`. Judge model can be the same as the
/// extraction model (Together's Llama-3.3-70B-Instruct-Turbo handles both)
/// or a smaller faster model — the judge prompt is short + bounded so
/// even a 7B model gives reasonable results. Default per spec: same as
/// the extraction model.
pub const JudgeContext = struct {
    provider: providers.Provider,
    model_name: []const u8,
};

/// V1.6 commit 8 — optional embedding provider for entity coreference.
/// When set, the object side of each extracted triple is embedded and
/// matched against existing entities via pgvector cosine ≥0.95 (Mem0
/// threshold). Cosine match → reuse entity_id as edge target_key.
/// No match → create new entity row, use its id as target_key.
/// Provider absent → fall back to hash-based entity_<sha256(lower(object))>
/// (V1.6 cmt7 behavior).
///
/// The embed call adds ~50-200ms per fact. Acceptable for Pass C
/// (already async after summary archive). Failures are non-fatal:
/// fall back to hash key + log.warn.
pub const EntityResolution = struct {
    embed_provider: memory_embeddings.EmbeddingProvider,
    /// Cosine similarity threshold above which two entity strings are
    /// considered coreferent (the same entity). Mem0 spec: 0.95.
    threshold: f64 = 0.95,
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

/// V1.6 commit 7 (Gap 2 from memory pipeline handoff): deterministic key
/// derivation via SHA-256 of `subject|predicate|object`. Same fact extracted
/// across different sessions / different times maps to the SAME key.
///
/// **Why this matters:** the contradiction judge prevents writes that
/// duplicate semantics, but write paths that BYPASS the judge (session-end
/// loop, agent memory_store tool — Gap 3) could otherwise accumulate
/// phantom nodes for the same fact under different random keys. Stable
/// keys make the judge's role purely "should we close out the prior
/// version" rather than "should we suppress this write".
///
/// Pairs with the V1.6 5b.3 MD5 content_hash dedup pre-filter:
///   - MD5 catches re-extractions with byte-identical text → silent skip
///   - Stable key catches re-extractions with rephrased text + identical
///     (subject, predicate, object) triple → ON CONFLICT DO UPDATE on the
///     same row, which the W-INT-01 fix's resurrect-on-upsert handles.
///
/// SHA-256 truncated to 16 hex chars = 64 bits of entropy. Collision
/// probability for 1M extracted facts per user: ~2.7e-8. Acceptable.
///
/// Pre-V1.6 cmt7 extraction_<unix>_<hex8> rows survive untouched — they
/// just don't dedupe across re-extractions. New writes use the stable
/// shape going forward; one-shot backfill (V1.6 cmt15) will rekey legacy
/// rows if needed.
fn deriveExtractionKey(
    allocator: std.mem.Allocator,
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(subject);
    hasher.update("|");
    hasher.update(predicate);
    hasher.update("|");
    hasher.update(object);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex_buf: [16]u8 = undefined;
    _ = security_secrets.hexEncode(digest[0..8], &hex_buf);
    return std.fmt.allocPrint(allocator, "extracted_{s}", .{hex_buf});
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
    const link_type = linkTypeForPredicate(mem.predicate);
    try w.writeAll("{\"subject\":\"");
    try writeJsonEscaped(w, mem.subject);
    try w.writeAll("\",\"predicate\":\"");
    try writeJsonEscaped(w, mem.predicate);
    try w.writeAll("\",\"object_key\":\"");
    try writeJsonEscaped(w, mem.object);
    try w.writeAll("\",\"attributed_to\":\"");
    try writeJsonEscaped(w, mem.attributed_to);
    try w.writeAll("\",\"attribution\":\"extraction_classifier\"");
    // V1.7a-5 (spec seam 3) — emit link_type derived from predicate so
    // SQL-side population (`metadata->>'link_type'`) populates the column
    // atomically with the metadata write. SQL backfill for legacy rows
    // (zaki_state migrate) covers pre-V1.7a-5 data.
    try w.writeAll(",\"link_type\":\"");
    try writeJsonEscaped(w, link_type.toString());
    try w.writeAll("\"");
    try w.print(",\"confidence\":{d:.3}", .{mem.confidence});
    try w.print(",\"extracted_at\":{d}", .{std.time.timestamp()});
    try w.writeAll("}");
    return buf.toOwnedSlice(allocator);
}

/// V1.7a-5 (spec seam 3) — map an extraction-time `predicate` (the SVO
/// triple verb, e.g. PREFERS, REPLACES, USED_FOR) to its high-level
/// `LinkType` category for FE rendering + agent-side reasoning.
///
/// The mapping is OPINIONATED but conservative: predicates we recognize
/// route to specific categories; unrecognized predicates default to
/// `.attribute` (the broadest category) AND log an info so production
/// telemetry surfaces gaps in our vocabulary. Adding a new predicate
/// to a category is a one-line patch in this function.
///
/// Single source of truth — every extraction write routes through here.
/// Comparison is case-INsensitive on ASCII so `"PREFERS"`, `"prefers"`,
/// and `"Prefers"` all map identically.
pub fn linkTypeForPredicate(predicate: []const u8) memory_root.LinkType {
    // Normalize to uppercase for compare. Bounded buffer matches longest
    // expected predicate (~32 chars; predicates with COMPLEX_NAMES_LIKE_THIS
    // top out around 24 chars in practice). Longer → fall through to default.
    var buf: [64]u8 = undefined;
    if (predicate.len > buf.len) {
        log.info("extraction.linktype_map_default predicate_len={d} fallback=attribute", .{predicate.len});
        return .attribute;
    }
    for (predicate, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    const norm = buf[0..predicate.len];

    // Preference (likes/dislikes/values)
    if (std.mem.eql(u8, norm, "PREFERS")) return .preference;
    if (std.mem.eql(u8, norm, "LIKES")) return .preference;
    if (std.mem.eql(u8, norm, "HATES")) return .preference;
    if (std.mem.eql(u8, norm, "AVOIDS")) return .preference;
    if (std.mem.eql(u8, norm, "FAVORS")) return .preference;
    if (std.mem.eql(u8, norm, "DISLIKES")) return .preference;
    if (std.mem.eql(u8, norm, "ENJOYS")) return .preference;
    if (std.mem.eql(u8, norm, "VALUES")) return .preference;

    // Supersession (this fact replaces another)
    if (std.mem.eql(u8, norm, "REPLACES")) return .supersession;
    if (std.mem.eql(u8, norm, "USED_TO_BE")) return .supersession;
    if (std.mem.eql(u8, norm, "FORMERLY")) return .supersession;
    if (std.mem.eql(u8, norm, "PREVIOUSLY")) return .supersession;
    if (std.mem.eql(u8, norm, "USED_TO_PREFER")) return .supersession;
    if (std.mem.eql(u8, norm, "USED_TO_USE")) return .supersession;

    // Relationship (entity↔entity)
    if (std.mem.eql(u8, norm, "KNOWS")) return .relationship;
    if (std.mem.eql(u8, norm, "WORKS_WITH")) return .relationship;
    if (std.mem.eql(u8, norm, "MARRIED_TO")) return .relationship;
    if (std.mem.eql(u8, norm, "FRIENDS_WITH")) return .relationship;
    if (std.mem.eql(u8, norm, "MANAGES")) return .relationship;
    if (std.mem.eql(u8, norm, "REPORTS_TO")) return .relationship;
    if (std.mem.eql(u8, norm, "COLLABORATES_WITH")) return .relationship;
    if (std.mem.eql(u8, norm, "RELATED_TO")) return .relationship;

    // Usage (uses/owns/consumes)
    if (std.mem.eql(u8, norm, "USED_FOR")) return .usage;
    if (std.mem.eql(u8, norm, "USES")) return .usage;
    if (std.mem.eql(u8, norm, "OWNS")) return .usage;
    if (std.mem.eql(u8, norm, "DEPENDS_ON")) return .usage;
    if (std.mem.eql(u8, norm, "BUILDS_WITH")) return .usage;
    if (std.mem.eql(u8, norm, "DEPLOYS_TO")) return .usage;

    // Episode (event-shaped)
    if (std.mem.eql(u8, norm, "HAPPENED_ON")) return .episode;
    if (std.mem.eql(u8, norm, "ATTENDED")) return .episode;
    if (std.mem.eql(u8, norm, "OCCURRED_AT")) return .episode;
    if (std.mem.eql(u8, norm, "JOINED")) return .episode;
    if (std.mem.eql(u8, norm, "VISITED")) return .episode;

    // Default: .attribute (descriptive properties — BIRTHDAY, LIVES_IN,
    // WORKS_AT, IS, HAS, etc.). Log so we can grow the mapping when
    // production reveals new predicate surface forms.
    log.info("extraction.linktype_map_default predicate={s} fallback=attribute", .{predicate});
    return .attribute;
}

test "linkTypeForPredicate maps known predicates correctly" {
    try std.testing.expectEqual(memory_root.LinkType.preference, linkTypeForPredicate("PREFERS"));
    try std.testing.expectEqual(memory_root.LinkType.preference, linkTypeForPredicate("prefers"));
    try std.testing.expectEqual(memory_root.LinkType.supersession, linkTypeForPredicate("REPLACES"));
    try std.testing.expectEqual(memory_root.LinkType.supersession, linkTypeForPredicate("USED_TO_BE"));
    try std.testing.expectEqual(memory_root.LinkType.relationship, linkTypeForPredicate("KNOWS"));
    try std.testing.expectEqual(memory_root.LinkType.usage, linkTypeForPredicate("USED_FOR"));
    try std.testing.expectEqual(memory_root.LinkType.episode, linkTypeForPredicate("ATTENDED"));
}

test "linkTypeForPredicate defaults unknown predicates to .attribute" {
    try std.testing.expectEqual(memory_root.LinkType.attribute, linkTypeForPredicate("BIRTHDAY"));
    try std.testing.expectEqual(memory_root.LinkType.attribute, linkTypeForPredicate("UNKNOWN_VERB"));
    try std.testing.expectEqual(memory_root.LinkType.attribute, linkTypeForPredicate(""));
}

test "linkTypeForPredicate handles oversize input without panic" {
    // 65 chars — exceeds 64-byte normalize buffer; falls through to default.
    const huge = "A" ** 65;
    try std.testing.expectEqual(memory_root.LinkType.attribute, linkTypeForPredicate(huge));
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
///   2. MD5 content_hash dedup pre-filter (V1.6 5b.3 — exact-byte match)
///   3. **V1.6 commit 6**: contradiction LLM judge when `judge` provided
///      a. duplicate detected → skip (treat as semantic-dup of existing row)
///      b. contradicted older facts → close out via setMemoryInvalidation
///   4. Write via state_mgr.upsertMemoryWithMetadata with V1.6 metadata
///
/// `judge == null` means LLM judging is disabled — the call still works
/// (MD5 still guards), it just doesn't catch semantic duplicates or
/// resolve contradictions. Use null for non-LLM call sites (agent tool
/// writes today, V1.7 classifier writes tomorrow).
///
/// Per-fact failures emit log.warn but don't abort the batch — one bad
/// fact shouldn't kill the run. Judge LLM failures are non-fatal: they
/// degrade to MD5-only behavior for that fact.
pub fn persistExtracted(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    session_id: ?[]const u8,
    memories: []const ExtractedMemory,
    judge: ?JudgeContext,
    coref: ?EntityResolution,
) !PersistResult {
    var result = PersistResult{
        .written_count = 0,
        .skipped_blacklist = 0,
        .skipped_md5_dup = 0,
        .skipped_cosine_dup = 0,
        .skipped_semantic_dup = 0,
        .contradictions_resolved = 0,
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

        // Step 3 (V1.6 commit 6): contradiction LLM judge.
        //
        // Fetches two candidate lists per Graphiti spec:
        //   - related: same-subject extraction-classifier memories (dedup-eligible)
        //   - broader: hybrid BM25+key recall results (contradiction-eligible only)
        //
        // Runs only when caller provided a JudgeContext. Without it, this
        // step short-circuits and persistence falls back to MD5-only
        // semantics (same as V1.6 commit 5b.3 behavior).
        //
        // Failure mode: any error in candidate fetch OR judge call → log
        // + proceed to write. Better one extra duplicate than a lost fact.
        if (judge) |j| {
            const empty_entries: []memory_root.MemoryEntry = &.{};
            const related: []memory_root.MemoryEntry = state_mgr.findRelatedExtractedMemories(
                allocator,
                user_id,
                m.subject,
                edge_resolution.MAX_RELATED_CANDIDATES,
            ) catch |err| blk: {
                log.warn("extraction.related_fetch_failed err={s} subject={s}", .{
                    @errorName(err), m.subject,
                });
                break :blk empty_entries;
            };
            defer memory_root.freeEntries(allocator, related);

            const broader: []memory_root.MemoryEntry = state_mgr.recallMemories(
                allocator,
                user_id,
                m.text,
                edge_resolution.MAX_BROADER_CANDIDATES,
                null,
            ) catch |err| blk: {
                log.warn("extraction.broader_fetch_failed err={s}", .{@errorName(err)});
                break :blk empty_entries;
            };
            defer memory_root.freeEntries(allocator, broader);

            // De-overlap: filter broader candidates whose keys also appear
            // in related, so the judge's idx range stays semantically
            // distinct (per Graphiti spec, related is dedup+contradiction,
            // broader is contradiction-only — same row in both ranges
            // would let dup_facts hit at idx >= related.len, which the
            // judge then rejects per the constraint comment, wasting
            // a candidate slot).
            const broader_filtered: []memory_root.MemoryEntry = filterOverlap(allocator, broader, related) catch |err| blk: {
                log.warn("extraction.dedup_filter_failed err={s}", .{@errorName(err)});
                break :blk empty_entries;
            };
            defer allocator.free(broader_filtered);

            const outcome = edge_resolution.resolveOne(
                allocator,
                j.provider,
                j.model_name,
                m,
                related,
                broader_filtered,
            ) catch |err| blk: {
                log.warn("extraction.judge_failed err={s} subject={s} predicate={s}", .{
                    @errorName(err), m.subject, m.predicate,
                });
                break :blk edge_resolution.ResolveOutcome{
                    .is_duplicate = false,
                    .contradictions = &.{},
                };
            };
            defer outcome.deinit(allocator);

            if (outcome.is_duplicate) {
                log.info("extraction.semantic_dup_skipped subject={s} predicate={s}", .{
                    m.subject, m.predicate,
                });
                result.skipped_semantic_dup += 1;
                continue;
            }

            // Apply contradictions BEFORE writing the new fact so that
            // hybrid recall in the next iteration of this same batch
            // doesn't see the about-to-be-superseded rows. Since
            // applyContradictions is idempotent + the new fact's hash
            // is different from any existing row's, this ordering is
            // safe even if the new write fails afterward.
            if (outcome.contradictions.len > 0) {
                const applied = edge_resolution.applyContradictions(
                    state_mgr,
                    user_id,
                    outcome.contradictions,
                );
                result.contradictions_resolved += applied;
                log.info("extraction.contradictions_applied count={d} new_subject={s} new_predicate={s}", .{
                    applied, m.subject, m.predicate,
                });
            }
        }

        // Step 4-5 — derive key + metadata + write.
        // V1.6 cmt7 (Gap 2): key is deterministic from (subject, predicate,
        // object) so re-extracting the same fact across sessions hits the
        // same row via ON CONFLICT (the W-INT-01 resurrect-on-upsert path
        // takes care of any prior close-out state).
        const key = deriveExtractionKey(allocator, m.subject, m.predicate, m.object) catch |err| {
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

        // V1.6 commit 14 (M4): populate source attribution columns. The
        // session_id is already known; the snippet uses the fact's own
        // text truncated to 256 chars (covers ~50 words; enough for
        // "where did this come from?" UI without bloating the row).
        // Future enhancement: have the extraction LLM emit a verbatim
        // source_snippet from the originating message (more accurate
        // attribution); today's truncated-fact-text is good enough for
        // the M4 spec milestone. Failure is non-fatal — the memory row
        // is already written; missing source attribution degrades the
        // drilldown UX but preserves the fact.
        const SNIPPET_CAP: usize = 256;
        // V1.7a-4 review fix WR-01: route through the consolidated UTF-8
        // truncation helper in `memory/text_norm.zig`. Was an inline copy
        // of the same logic — single source of truth eliminates drift.
        const snippet: ?[]const u8 = if (m.text.len == 0) null else text_norm.truncateUtf8(m.text, SNIPPET_CAP);
        state_mgr.setMemorySource(user_id, key, session_id, snippet) catch |err| {
            log.warn("extraction.source_set_failed key={s} err={s}", .{ key, @errorName(err) });
        };

        // V1.6 commit 7 (Gap 1 from memory pipeline handoff): materialize
        // the typed edge into memory_edges. Source key is the just-written
        // memory row; target key is a synthetic entity ref derived from
        // (subject, object). For "user PREFERS Helix":
        //   source_key = "extracted_<hash(user|PREFERS|Helix)>"  (this row)
        //   target_key = "entity_<hash(Helix)>"                  (target side)
        //   predicate  = "PREFERS"
        // V1.6 commit 8 (entity coreference) will populate the target side
        // with stable entity IDs from memory_entities; for now the synthetic
        // entity_<hash(object)> shape gives us a queryable graph.
        //
        // Failure mode: edge write failure does NOT abort persistence.
        // The memory row is already written; an orphan-without-edge is
        // benign (importance scoring sees edge_count=0 for that node, same
        // as pre-V1.6cmt7 baseline).
        // V1.6 commit 8: resolve entity-side target_key. With a coref
        // provider configured, embed the object + cosine-search existing
        // entities (≥0.95 = same entity, reuse its id). Without a provider,
        // fall back to V1.6 cmt7's hash-based shape entity_<hash(lower(o))>.
        // Either way: every fact about the same object lands on the same
        // graph node — the difference is whether "Helix" and "Helix editor"
        // collapse to ONE node (cosine yes, hash no).
        const target_key = resolveEntityKey(allocator, state_mgr, user_id, m.object, coref) catch |err| blk: {
            log.warn("extraction.entity_resolve_failed err={s} object={s}", .{ @errorName(err), m.object });
            // Final fallback: hash-only key so the edge still writes
            break :blk deriveEntityKey(allocator, m.object) catch null;
        };
        if (target_key) |tk| {
            defer allocator.free(tk);
            state_mgr.upsertMemoryEdge(
                user_id,
                key,
                tk,
                m.predicate,
                "extraction_classifier",
                m.confidence,
            ) catch |err| {
                log.warn("extraction.edge_write_failed source={s} target={s} predicate={s} err={s}", .{
                    key, tk, m.predicate, @errorName(err),
                });
            };
        }

        log.info("extraction.persisted key={s} subject={s} predicate={s} attributed_to={s}", .{
            key, m.subject, m.predicate, m.attributed_to,
        });
        result.written_count += 1;
    }

    return result;
}

/// V1.6 commit 7 — derive a stable entity-side target key from an object
/// string. Shape: `entity_<sha256(lower(object))[0..16]>`. Lowercase to
/// stabilize against capitalization variance ("Helix" vs "helix").
///
/// V1.6 commit 8 (entity coreference) will replace this with a real
/// memory_entities lookup that handles "Helix" / "Helix editor" /
/// "the helix editor" cosine-merging. Today's hash gives us a consistent
/// target key for the graph topology; coreference can rewrite later
/// without losing existing edges (the edge UNIQUE INDEX includes
/// target_key so re-keying generates fresh edges + cascades old ones via
/// is_latest=false).
/// V1.6 commit 8 — resolve the canonical entity_id for an object string,
/// using cosine coreference when an embedding provider is available, falling
/// back to the V1.6 cmt7 hash shape otherwise.
///
/// Resolution order:
///   1. coref absent → return deriveEntityKey(object) (hash fallback)
///   2. coref present → embed(object). On embed failure → hash fallback.
///   3. findEntityByCosine(user_id, embedding, threshold). Match → reuse id.
///   4. No match → upsertEntity(user_id, name=object, embedding). Use new id.
///
/// Caller frees the returned slice. The returned key is the value the
/// edge writer uses as `target_key`, so a coreference match means existing
/// edges to that entity gain weight via the UNIQUE INDEX.
fn resolveEntityKey(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    object: []const u8,
    coref: ?EntityResolution,
) ![]u8 {
    const c = coref orelse return deriveEntityKey(allocator, object);

    // Embed the object. Failure → log + hash fallback; never abort the write.
    const embedding = c.embed_provider.embed(allocator, object) catch |err| {
        log.warn("extraction.embed_failed err={s} object={s} — using hash fallback", .{
            @errorName(err), object,
        });
        return deriveEntityKey(allocator, object);
    };
    defer allocator.free(embedding);

    // Cosine match → reuse existing entity_id.
    const existing = state_mgr.findEntityByCosine(allocator, user_id, embedding, c.threshold) catch |err| blk: {
        log.warn("extraction.entity_search_failed err={s}", .{@errorName(err)});
        break :blk null;
    };
    if (existing) |row| {
        defer row.deinit(allocator);
        log.info("extraction.entity_coref_match object={s} matches_existing={s} similarity={d:.3}", .{
            object, row.name, row.similarity,
        });
        return allocator.dupe(u8, row.id);
    }

    // No match → create new entity.
    const new_id = state_mgr.upsertEntity(allocator, user_id, object, embedding) catch |err| {
        log.warn("extraction.entity_upsert_failed err={s} object={s} — using hash fallback", .{
            @errorName(err), object,
        });
        return deriveEntityKey(allocator, object);
    };
    log.info("extraction.entity_created object={s} entity_id={s}", .{ object, new_id });
    return new_id;
}

fn deriveEntityKey(allocator: std.mem.Allocator, object: []const u8) ![]u8 {
    const lower = try lowerForEntityKey(allocator, object);
    defer allocator.free(lower);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(lower);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex_buf: [16]u8 = undefined;
    _ = security_secrets.hexEncode(digest[0..8], &hex_buf);
    return std.fmt.allocPrint(allocator, "entity_{s}", .{hex_buf});
}

/// V1.7a-4 (closes V1.6 ship-review WR-02) — canonicalization helper for
/// entity-key hashing. Both `extraction_persist.deriveEntityKey` and
/// `commands.deriveSessionEndEntityKey` route every `object` string through
/// this before SHA-256. The PG cmt16 backfill SQL must also call PG's
/// `lower(...)` (Unicode-aware) on the same input, so all three paths
/// produce byte-identical hashes for the same surface form.
///
/// Coverage (matches PG `lower(...)` in standard UTF-8 locales for these ranges):
///   - ASCII A-Z → a-z
///   - Latin-1 Supplement uppercase (À..Þ excluding ×) → lowercase
///   - Cyrillic Capital (А..Я, U+0410..U+042F) → lowercase (а..я)
///   - Greek Capital (Α..Ω, U+0391..U+03A9) → lowercase (α..ω; Σ → σ)
///   - All other codepoints pass through unchanged. CJK has no case so
///     this is correct; some Latin Extended-A pairs (Ā/ā etc.) are NOT
///     covered — rare in entity surface forms, defer until profiling
///     shows convergence loss.
///
/// **Deployment caveat:** PG `lower(...)` behavior depends on the database
/// LC_COLLATE setting. Production deployments use `en_US.UTF-8` (or
/// equivalent UTF-8 locale) where this helper converges with PG. Under
/// the C locale, PG `lower()` is ASCII-only and would diverge from this
/// helper for any Latin-1+ input — DO NOT run nullalis prod on C locale.
///
/// Returns an allocator-owned slice. Caller frees.
pub fn lowerForEntityKey(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);
    try buf.ensureTotalCapacity(allocator, s.len);

    var i: usize = 0;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            // Invalid UTF-8 lead byte — pass through unchanged
            // (lossless on bad input rather than failing hash derivation).
            try buf.append(allocator, s[i]);
            i += 1;
            continue;
        };
        if (i + cp_len > s.len) {
            // Truncated UTF-8 sequence at end — preserve remaining bytes.
            try buf.appendSlice(allocator, s[i..]);
            break;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + cp_len]) catch {
            // Decode failed despite valid lead byte length — preserve raw bytes.
            try buf.appendSlice(allocator, s[i .. i + cp_len]);
            i += cp_len;
            continue;
        };
        const mapped = mapCodepointToLower(cp);
        if (mapped == cp) {
            // No change — copy original bytes (faster than re-encoding).
            try buf.appendSlice(allocator, s[i .. i + cp_len]);
        } else {
            var enc_buf: [4]u8 = undefined;
            const enc_len = std.unicode.utf8Encode(mapped, &enc_buf) catch unreachable;
            try buf.appendSlice(allocator, enc_buf[0..enc_len]);
        }
        i += cp_len;
    }
    return buf.toOwnedSlice(allocator);
}

fn mapCodepointToLower(cp: u21) u21 {
    // ASCII A-Z → a-z
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    // Latin-1 Supplement uppercase: À..Þ (U+00C0..U+00DE), excluding × (U+00D7).
    // Lowercase mirrors at U+00E0..U+00FE excluding ÷ (U+00F7), offset +0x20.
    if (cp >= 0x00C0 and cp <= 0x00DE and cp != 0x00D7) return cp + 0x20;
    // V1.7a-4 review fix WR-6 — Cyrillic Capital (А..Я, U+0410..U+042F) →
    // lowercase (а..я, U+0430..U+044F). PG `lower()` handles Cyrillic in
    // UTF-8 locales; without this branch a tenant with Cyrillic uppercase
    // entity surface forms would diverge between Zig hash and SQL backfill.
    if (cp >= 0x0410 and cp <= 0x042F) return cp + 0x20;
    // V1.7a-4 review fix WR-6 — Greek Capital (Α..Ω, U+0391..U+03A9) →
    // lowercase (α..ω, U+03B1..U+03C9). Same rationale as Cyrillic. Note
    // that Σ has TWO lowercase forms (σ and ς depending on word position);
    // we map to σ (U+03C3) which matches PG `lower(...)` default behavior
    // (PG does not contextually choose final-sigma in lower()).
    if (cp >= 0x0391 and cp <= 0x03A9) return cp + 0x20;
    return cp;
}

/// V1.6 commit 6 helper — drop entries from `xs` whose key appears in
/// `ys`. O(N*M) but candidate caps (12 + 8 = 20) keep it negligible.
/// Returned slice is allocator-owned; entries are NOT cloned (they
/// remain owned by the original `xs` slice — caller must keep `xs`
/// alive until the filtered slice is consumed).
fn filterOverlap(
    allocator: std.mem.Allocator,
    xs: []const memory_root.MemoryEntry,
    ys: []const memory_root.MemoryEntry,
) ![]memory_root.MemoryEntry {
    var out: std.ArrayListUnmanaged(memory_root.MemoryEntry) = .{};
    errdefer out.deinit(allocator);
    outer: for (xs) |x| {
        for (ys) |y| {
            if (std.mem.eql(u8, x.key, y.key)) continue :outer;
        }
        try out.append(allocator, x);
    }
    return out.toOwnedSlice(allocator);
}

// I3: dropped local `freeMemoryEntries` — was a duplicate of
// `memory_root.freeEntries`. All call sites now use the canonical helper.

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

// V1.7a-4 (closes V1.6 ship-review WR-02) — lowerForEntityKey unit tests.
// Both Zig sites + the SQL backfill (lower(...) post-V1.7a-4) must
// produce byte-identical lowercased input for any covered surface form.

test "lowerForEntityKey: ASCII A-Z → a-z" {
    const allocator = std.testing.allocator;
    const out = try lowerForEntityKey(allocator, "HELIX EDITOR");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("helix editor", out);
}

test "lowerForEntityKey: already-lowercase passes through unchanged" {
    const allocator = std.testing.allocator;
    const out = try lowerForEntityKey(allocator, "helix editor");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("helix editor", out);
}

test "lowerForEntityKey: Latin-1 Supplement uppercase → lowercase" {
    const allocator = std.testing.allocator;
    // À É Ñ Ö Ü Þ → à é ñ ö ü þ (all in U+00C0..U+00DE except U+00D7)
    const out = try lowerForEntityKey(allocator, "ÀÉÑÖÜÞ");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("àéñöüþ", out);
}

test "lowerForEntityKey: mixed ASCII + Latin-1 (CAFÉ → café)" {
    const allocator = std.testing.allocator;
    const out = try lowerForEntityKey(allocator, "CAFÉ");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("café", out);
}

test "lowerForEntityKey: × (U+00D7) is NOT a letter — passes unchanged" {
    const allocator = std.testing.allocator;
    // U+00D7 (multiplication sign) sits in the Latin-1 uppercase range
    // numerically but is not a letter; PG lower() leaves it alone.
    const out = try lowerForEntityKey(allocator, "5×3");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("5×3", out);
}

test "lowerForEntityKey: Cyrillic Capital → lowercase (V1.7a-4 review WR-6)" {
    const allocator = std.testing.allocator;
    // Cyrillic uppercase ПРИВЕТ → привет (matches PG lower() in UTF-8
    // locales — convergence with the SQL backfill side).
    const out = try lowerForEntityKey(allocator, "ПРИВЕТ");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("привет", out);
}

test "lowerForEntityKey: Greek Capital → lowercase (V1.7a-4 review WR-6)" {
    const allocator = std.testing.allocator;
    // Greek uppercase ΑΛΦΑΒΗΤΟΣ → αλφαβητοσ (Σ → σ; we map to default
    // sigma, not contextual final-sigma ς, matching PG lower() default).
    const out = try lowerForEntityKey(allocator, "ΑΛΦΑΒΗΤΟΣ");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("αλφαβητοσ", out);
}

test "lowerForEntityKey: truly out-of-range codepoints pass through (CJK)" {
    const allocator = std.testing.allocator;
    // CJK chars (here: Chinese 你好) have no upper/lower distinction.
    // PG lower() leaves them unchanged too. Convergence verified.
    const out = try lowerForEntityKey(allocator, "你好");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("你好", out);
}

test "lowerForEntityKey: invalid UTF-8 lead byte preserved (lossless on bad input)" {
    const allocator = std.testing.allocator;
    // 0xFF is never a valid UTF-8 lead byte. Helper passes it through
    // rather than failing — entity-key derivation must always succeed
    // even on garbage input (otherwise extraction pipeline crashes).
    const input = [_]u8{ 'a', 0xFF, 'b' };
    const out = try lowerForEntityKey(allocator, &input);
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u8, &input, out);
}

test "lowerForEntityKey: truncated UTF-8 sequence at end preserved" {
    const allocator = std.testing.allocator;
    // 0xC3 is a 2-byte UTF-8 lead but no continuation follows. Helper
    // emits the partial bytes rather than reading past end-of-buffer.
    const input = [_]u8{ 'a', 0xC3 };
    const out = try lowerForEntityKey(allocator, &input);
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u8, &input, out);
}

test "lowerForEntityKey: empty string returns empty allocation" {
    const allocator = std.testing.allocator;
    const out = try lowerForEntityKey(allocator, "");
    defer allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "lowerForEntityKey: deriveEntityKey produces stable key for case variants" {
    const allocator = std.testing.allocator;
    const k1 = try deriveEntityKey(allocator, "Helix");
    defer allocator.free(k1);
    const k2 = try deriveEntityKey(allocator, "HELIX");
    defer allocator.free(k2);
    const k3 = try deriveEntityKey(allocator, "helix");
    defer allocator.free(k3);
    // All three surface forms must hash to the same entity_<...> key.
    try std.testing.expectEqualStrings(k1, k2);
    try std.testing.expectEqualStrings(k2, k3);
}

test "lowerForEntityKey: deriveEntityKey unifies Latin-1 case variants (Café/CAFÉ/café)" {
    const allocator = std.testing.allocator;
    const k1 = try deriveEntityKey(allocator, "Café");
    defer allocator.free(k1);
    const k2 = try deriveEntityKey(allocator, "CAFÉ");
    defer allocator.free(k2);
    const k3 = try deriveEntityKey(allocator, "café");
    defer allocator.free(k3);
    // Pre-V1.7a-4 these would have produced 3 different entity rows;
    // post-fix they collapse to one.
    try std.testing.expectEqualStrings(k1, k2);
    try std.testing.expectEqualStrings(k2, k3);
}
