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
//! 2. **SHA-256 content_hash dedup** — if a memory with identical
//!    normalized content already exists for this user, skip silently
//!    (Mem0-style pre-filter, gap #13 from audit). Previously used MD5
//!    (dead layer — 32-char hex can never match a 64-char SHA-256 column).
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
const pii_detect = @import("../memory/pii_detect.zig");
const working_memory = @import("working_memory.zig");
// Brain-leak Fix A — keystone reuse. `context_builder.isScaffoldEntityName`
// is derived from the `stable_prompt_markers` list (the system-prompt scaffold
// section titles), so the entity-name denylist here can never drift from the
// prompt that produces the leak. context_builder imports only leaf modules
// (no extraction_persist / zaki_state), so this introduces no import cycle.
const context_builder = @import("context_builder.zig");

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
    /// V1.14 — optional unix-epoch timestamp when the fact became true,
    /// distinct from write-time. Populated when extractor's JSON
    /// includes `valid_at` (an ISO-8601 datetime). null means "no
    /// temporal anchor known"; downstream uses write-time as fallback.
    temporal_anchor_unix: ?i64 = null,
    /// V1.14.8 C4 — optional working-memory slot type to promote to.
    /// MUST be one of the static strings on `working_memory.SlotType`
    /// (e.g., "open_loop", "active_goal", "decision", "identity",
    /// "temporal"). Always a static string slice — never freed by deinit.
    /// When set, persistExtracted prefers this over the predicate-derived
    /// mapping so the LLM-tagged intent wins (catches cases where the
    /// predicate isn't on `predicateToSlotType`'s allowlist but the LLM
    /// correctly identified the working-memory intent).
    slot_intent: ?[]const u8 = null,

    pub fn deinit(self: *const ExtractedMemory, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.subject);
        allocator.free(self.predicate);
        allocator.free(self.object);
        allocator.free(self.attributed_to);
        // slot_intent is a static string (working_memory.SlotType.*) — never freed.
    }
};

pub fn freeExtractedMemories(allocator: std.mem.Allocator, mems: []ExtractedMemory) void {
    for (mems) |m| m.deinit(allocator);
    allocator.free(mems);
}

/// Parse an optional ISO-8601 date / datetime string to a unix epoch in
/// seconds (start-of-day UTC for date-only inputs). Returns null on any
/// parse failure or out-of-range value (failure-soft: downstream treats
/// null as "no temporal anchor known; use write-time fallback"). Accepts:
///   - `YYYY-MM-DD`              (start-of-day UTC)
///   - `YYYY-MM-DDThh:mm:ss[Z]`  (date portion used; time portion ignored)
/// Validates day against month with leap-year handling so 2020-02-30
/// returns null rather than silently rolling to March 1.
///
/// Lifted from the inline extractor parser (V1.14) so the agent-facing
/// memory_store tool can share the same shape via the new `valid_at`
/// parameter (D55, 2026-05-24).
pub fn parseValidAtIso(iso_opt: ?[]const u8) ?i64 {
    const iso = iso_opt orelse return null;
    if (iso.len < 10) return null;
    const year = std.fmt.parseInt(i32, iso[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, iso[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, iso[8..10], 10) catch return null;
    if (year < 1970 or year > 2100) return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    const leap_now = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
    const max_day_per_month = [_]u8{
        31,                       // Jan
        if (leap_now) 29 else 28, // Feb
        31,                       // Mar
        30,                       // Apr
        31,                       // May
        30,                       // Jun
        31,                       // Jul
        31,                       // Aug
        30,                       // Sep
        31,                       // Oct
        30,                       // Nov
        31,                       // Dec
    };
    if (day > max_day_per_month[@as(usize, @intCast(month)) - 1]) return null;
    const days_per_month = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var days: i64 = 0;
    const y_offset: i32 = year - 1970;
    var y: i32 = 0;
    while (y < y_offset) : (y += 1) {
        const yy = 1970 + y;
        const leap = (@mod(yy, 4) == 0 and @mod(yy, 100) != 0) or (@mod(yy, 400) == 0);
        days += if (leap) 366 else 365;
    }
    var mi: usize = 0;
    while (mi < @as(usize, @intCast(month)) - 1) : (mi += 1) {
        days += days_per_month[mi];
        if (mi == 1) {
            const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
            if (leap) days += 1;
        }
    }
    days += @as(i64, @intCast(day)) - 1;
    return days * 86400;
}

test "parseValidAtIso accepts YYYY-MM-DD" {
    const out = parseValidAtIso("2026-05-24");
    try std.testing.expect(out != null);
    // 2026-05-24 → 56 years + months. Sanity-check: not the epoch.
    try std.testing.expect(out.? > 1_700_000_000);
}

test "parseValidAtIso rejects impossible dates" {
    try std.testing.expectEqual(@as(?i64, null), parseValidAtIso("2020-02-30")); // not a leap day Feb 30
    try std.testing.expectEqual(@as(?i64, null), parseValidAtIso("2021-13-01")); // month 13
    try std.testing.expectEqual(@as(?i64, null), parseValidAtIso("2021-06-31")); // June has 30 days
    try std.testing.expectEqual(@as(?i64, null), parseValidAtIso("1969-06-15")); // pre-epoch
}

test "parseValidAtIso accepts leap day Feb 29" {
    try std.testing.expect(parseValidAtIso("2020-02-29") != null);
    try std.testing.expectEqual(@as(?i64, null), parseValidAtIso("2021-02-29")); // non-leap
}

test "parseValidAtIso returns null on too-short input" {
    try std.testing.expectEqual(@as(?i64, null), parseValidAtIso(null));
    try std.testing.expectEqual(@as(?i64, null), parseValidAtIso(""));
    try std.testing.expectEqual(@as(?i64, null), parseValidAtIso("2026-05"));
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
    /// Brain-leak Fix A — facts rejected because their subject OR object is a
    /// system-prompt scaffold artifact (`isRejectedEntityName`). Distinct from
    /// `skipped_blacklist` (predicate denylist) so observability can tell the
    /// two write-boundary defenses apart.
    skipped_scaffold: usize = 0,
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
    /// V1.14.12 (M2 review CRITICAL fix) — cardinality fast-path runtime
    /// gate. When TRUE (default), persistExtracted skips the judge for
    /// set-valued predicates without explicit negation (M2 behavior).
    /// When FALSE, the judge fires on every write regardless of
    /// cardinality (pre-M2 behavior).
    ///
    /// Wired from `agent.extraction_cardinality_fastpath` config field
    /// through the 6 caller sites (memory_store, compaction Pass A/C,
    /// commands session-end). Default true preserves M2 effects.
    ///
    /// Pre-fix: the config flag was parsed but never read at the gate
    /// (persistExtracted ignored it). Operators couldn't disable M2 via
    /// config — only via code revert. This restores the contract.
    cardinality_fastpath_enabled: bool = true,
    /// P3 (memory-phase-0.5) — semantic type-routing gate. When TRUE
    /// (default), the durable `memory_type` of each extracted fact is
    /// routed by what the fact MEANS (open_loop / decision / preference /
    /// person custom: types, derived from `classifyPredicate`) rather than
    /// by WHO said it. When FALSE, the persist site falls back to the
    /// legacy `categoryForAttribution(attributed_to)` (user→core, else→
    /// daily) — the EXACT pre-P3 behavior.
    ///
    /// Wired from `agent.semantic_type_routing_enabled` config through the
    /// same caller chain as `cardinality_fastpath_enabled`. Default true.
    ///
    /// NOTE (P3 review): the persist-site gate no longer reads this field.
    /// The off-switch is honored via an explicit `semantic_type_routing_enabled`
    /// parameter on `persistExtracted`, which is ALWAYS present — so the flag
    /// works even on no-judge tenants (where there is no JudgeContext to read).
    /// This field is retained for symmetry with `cardinality_fastpath_enabled`
    /// and so construction sites that build a JudgeContext from the same config
    /// stay uniform; callers forward the same configured value into the
    /// explicit persist parameter.
    semantic_type_routing_enabled: bool = true,
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
/// and lookups are per-fact-write — O(N*K) with N=facts and a small K is
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
    "NO_CONNECTION_FOUND",
    "DESCRIPTION",
    // P7 — entity_pipeline speaker hub predicate (RENAMED from "MENTIONED").
    // Keep it rejected at this write-time defense-in-depth filter too, so the
    // gateway blacklist (gateway.isRejectedExtractionPredicate) and this list
    // stay in sync — the dense user→entity hub must not render or feed PPR.
    "USER_MENTIONED",
};

inline fn isRejectedPredicate(predicate: []const u8) bool {
    for (REJECTED_PREDICATES) |p| {
        if (std.mem.eql(u8, p, predicate)) return true;
    }
    return false;
}

/// Brain-leak Fix A — entity-name denylist at the write boundary.
///
/// The #48 leak surfaced the agent's system-prompt scaffold (section titles
/// like `## Brain Architecture`, body terms like "Working memory" / "Layer 0")
/// into a visible assistant turn, which then entered thread history and got
/// persisted as brain ENTITIES at session-end extraction. There was a
/// predicate denylist (`REJECTED_PREDICATES`) but NO entity-name denylist —
/// so any fact whose SUBJECT or OBJECT *is* a scaffold artifact wrote straight
/// to `memory_entities`/`memory_edges` and then rendered in `/brain` + got
/// recalled into replies (the feedback loop).
///
/// This is the keystone gate that stops new poison: it delegates to
/// `context_builder.isScaffoldEntityName`, which is built from the
/// `stable_prompt_markers` list (the single source of truth for the scaffold
/// section titles) plus the curated scaffold-body terms. Reusing that list
/// means this denylist can never drift from the prompt that produces the leak.
///
/// Match is case-insensitive, whitespace-normalized, EXACT-full-name (not
/// substring) so legitimate facts that merely *contain* a scaffold word
/// ("Safety team", "uses Layer 0 of the stack") are not over-filtered.
inline fn isRejectedEntityName(name: []const u8) bool {
    return context_builder.isScaffoldEntityName(name);
}

/// Compute SHA-256 hex of content for the V1.6 5b.3 dedup pre-filter.
/// Produces a 64-char hex string that matches the `content_hash` column,
/// which is populated by `zaki_state.computeContentHash` (also SHA-256).
/// Previous implementation used MD5 (32-char hex), making it impossible
/// for the dedup query to ever match a stored hash — the layer was
/// silently dead. Fixed in P1 of the memory-phase-0.5 patch series.
fn computeContentHashHex(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
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

        // V1.14 — parse optional `valid_at` ISO-8601 datetime to unix
        // epoch. Failure-soft: any parse issue → null (downstream treats
        // null as "no temporal anchor; use write-time fallback").
        // D55 (2026-05-24): parser extracted as `parseValidAtIso` above so
        // memory_store can share the same shape via its new `valid_at`
        // parameter; this site is now a thin wrapper that pulls the value
        // out of the LLM JSON.
        const valid_at_unix: ?i64 = blk: {
            const va = item.object.get("valid_at") orelse break :blk null;
            if (va != .string) break :blk null;
            break :blk parseValidAtIso(va.string);
        };

        const m = ExtractedMemory{
            .text = try allocator.dupe(u8, text.string),
            .subject = try allocator.dupe(u8, subject.string),
            .predicate = try allocator.dupe(u8, predicate.string),
            .object = try allocator.dupe(u8, object.string),
            .attributed_to = try allocator.dupe(u8, attr_str),
            .confidence = conf_f,
            .temporal_anchor_unix = valid_at_unix,
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

/// P3 (memory-phase-0.5) — route a memory's durable `memory_type` by what
/// the fact MEANS (its predicate semantics), not by WHO said it.
///
/// Uses the signals `classifyPredicate` already computes for the
/// predicate:
///   - slot_type == "open_loop"          → custom:"open_loop"
///   - slot_type == "decision"           → custom:"decision"
///   - link_type == .preference          → custom:"preference"
///   - link_type == .relationship        → custom:"person"
///   - otherwise → legacy categoryForAttribution(attributed_to)
///     (user→core, else→daily)
///
/// The custom strings are `memory_root.MemoryCategory.custom` free-text
/// values — `toString` passes them straight to the `memory_type` column,
/// and the read path (`memoryTypeToCategory` / `MemoryCategory.fromString`)
/// maps any unknown string back to `.custom`, so this needs no enum change
/// and no DB migration. The strings are static literals (no alloc/free).
///
/// Priority note: slot_type checks come before link_type. The only
/// predicates carrying BOTH a slot_type and a non-attribute link_type are
/// none in the current maps (slot-type predicates all default to
/// .attribute link), so order is not load-bearing today, but slot signals
/// (open_loop/decision) are the more specific intent and win by design.
///
/// `attributed_to` is NOT consulted for the semantic types — it remains
/// recorded as provenance in the row metadata (buildExtractionMetadata
/// emits `metadata.attributed_to`) and is still the fallback router for
/// facts with no distinctive semantic signal.
pub fn categoryForSemantics(class: PredicateClass, attributed_to: []const u8) memory_root.MemoryCategory {
    if (class.slot_type) |st| {
        if (std.mem.eql(u8, st, working_memory.SlotType.open_loop)) return .{ .custom = "open_loop" };
        if (std.mem.eql(u8, st, working_memory.SlotType.decision)) return .{ .custom = "decision" };
    }
    switch (class.link_type) {
        .preference => return .{ .custom = "preference" },
        .relationship => return .{ .custom = "person" },
        else => {},
    }
    // No distinctive semantic signal — fall back to attribution routing.
    return categoryForAttribution(attributed_to);
}

/// P4d (memory-phase-0.5) — public routing entry for the legacy session-end
/// `durable_fact` loop (commands.zig). That loop hardcoded `.core` for every
/// fact, so a preference/decision/person learned ONLY at session end never
/// got a semantic `memory_type` and never surfaced in the typed
/// <preferences>/<people>/etc. views.
///
/// Mirrors the P3 persistExtracted routing (line ~1428): when
/// `semantic_type_routing_enabled` is ON (default), route by what the fact
/// MEANS via `categoryForSemantics(classifyPredicate(predicate), …)`; OFF →
/// legacy `categoryForAttribution`. `attributed_to` may be empty (session-end
/// facts often lack it) — categoryForAttribution treats non-"user" as the
/// daily fallback, so an empty attribution with no semantic signal lands the
/// same `.daily`/`.core` shape the loop relied on. Prose-only facts (no
/// predicate) should NOT call this — the caller keeps `.core` for them.
pub fn categoryForSessionEndFact(
    predicate: []const u8,
    attributed_to: []const u8,
    semantic_type_routing_enabled: bool,
) memory_root.MemoryCategory {
    if (semantic_type_routing_enabled)
        return categoryForSemantics(classifyPredicate(predicate), attributed_to);
    return categoryForAttribution(attributed_to);
}

// ── C0 (memory-phase-0.5) — one-time backfill decision helpers ───────────
//
// The prior patches (P1/P3/P4/P7) fix NEW writes. C0 is the operator-triggered
// backfill that repairs EXISTING rows for ALL users. These two pure functions
// are the testable core of the re-type and re-entity-type decisions; the
// Manager-side SQL loop (`zaki_state.phase05Backfill`) calls them per row.
// Keeping the decision logic here — beside the write-path helpers it mirrors —
// means the backfill can NEVER drift from how new writes are typed.

/// C0 op 1 — should an EXISTING memory row be re-typed?
///
/// Only rows still carrying the legacy untyped defaults (`core`/`daily`) are
/// candidates: a row already routed to a semantic type (preference/decision/
/// person/open_loop/…) by P3 must be left exactly as-is so a second backfill
/// run is a no-op (idempotence). The new type is computed with the SAME logic
/// as new writes — `categoryForSemantics(classifyPredicate(predicate),
/// attributed_to)` — so re-typing converges on the write path's answer.
///
/// Returns the new `memory_type` string (a static literal owned by the
/// MemoryCategory union — never allocated) ONLY when ALL hold:
///   - `current_type` is `core` or `daily` (untyped legacy default), AND
///   - a non-empty `predicate` is available, AND
///   - the predicate routes to a type that DIFFERS from `current_type`.
///
/// Returns null (leave the row untouched) otherwise — including the
/// already-typed case, the no-predicate case, and the "predicate routes back
/// to the same core/daily" case (no churn). Idempotent by construction:
/// re-running on an already-backfilled row finds `current_type` is now the
/// semantic type → not core/daily → returns null.
pub fn backfillMemoryType(
    current_type: []const u8,
    predicate: []const u8,
    attributed_to: []const u8,
) ?[]const u8 {
    // Gate: only legacy untyped rows are candidates. A row already at a
    // semantic type is left alone (idempotence + don't fight P3).
    const is_legacy_default = std.mem.eql(u8, current_type, "core") or
        std.mem.eql(u8, current_type, "daily");
    if (!is_legacy_default) return null;
    // No predicate → no semantic signal → leave untyped (spec: only re-type
    // where a predicate is genuinely available).
    if (predicate.len == 0) return null;

    const new_type = categoryForSemantics(classifyPredicate(predicate), attributed_to).toString();
    // No-op when the predicate routes back to the same legacy default
    // (e.g. an `.attribute` predicate with attributed_to="user" → "core"):
    // re-typing core→core is churn with no benefit, so report nothing.
    if (std.mem.eql(u8, new_type, current_type)) return null;
    return new_type;
}

/// C0 op 2 — can an EXISTING `'PROPER'` entity be upgraded to a known class
/// from the predicate context of an edge pointing at it?
///
/// The only DETERMINISTIC predicate→entity-class signal in the system is the
/// relationship family (KNOWS, MARRIED_TO, WORKS_WITH, MANAGES, …): a triple
/// `subject <relationship-pred> object` makes the OBJECT a PERSON. This is the
/// SAME `.relationship` signal P3 uses to route the memory to `custom:"person"`
/// (`categoryForSemantics`), so the two stay consistent. Reuses
/// `classifyPredicate(...).link_type` — no new vocabulary.
///
/// All other predicates yield null: we do NOT guess ORG/PRODUCT/PLACE/etc. from
/// a predicate (there is no deterministic mapping; that typing is the LLM
/// entity-pipeline's job). Returns the static "PERSON" literal or null. The
/// caller stamps it via `upsertEntity`, whose no-clobber CASE means a stamp of
/// "PERSON" on a row already typed PERSON is a no-op (idempotence) and a stamp
/// can only UPGRADE — never demote a known type.
pub fn backfillEntityTypeFromPredicate(predicate: []const u8) ?[]const u8 {
    if (predicate.len == 0) return null;
    return switch (classifyPredicate(predicate).link_type) {
        .relationship => "PERSON",
        else => null,
    };
}

test "backfillMemoryType: legacy core/daily re-typed by semantic predicate" {
    // PREFERS → preference (differs from core) → re-type.
    try std.testing.expectEqualStrings(
        "preference",
        backfillMemoryType("core", "PREFERS", "user").?,
    );
    // KNOWS → person (relationship) — re-type a daily row.
    try std.testing.expectEqualStrings(
        "person",
        backfillMemoryType("daily", "KNOWS", "user").?,
    );
    // DECIDED → decision (slot_type) — re-type.
    try std.testing.expectEqualStrings(
        "decision",
        backfillMemoryType("core", "DECIDED", "user").?,
    );
    // TODO → open_loop (slot_type) — re-type.
    try std.testing.expectEqualStrings(
        "open_loop",
        backfillMemoryType("daily", "TODO", "user").?,
    );
}

test "backfillMemoryType: already-typed rows are left alone (idempotence)" {
    // A row already at a semantic type is never a candidate — the second
    // backfill run finds these and returns null.
    try std.testing.expect(backfillMemoryType("preference", "PREFERS", "user") == null);
    try std.testing.expect(backfillMemoryType("person", "KNOWS", "user") == null);
    try std.testing.expect(backfillMemoryType("decision", "DECIDED", "user") == null);
    try std.testing.expect(backfillMemoryType("open_loop", "TODO", "user") == null);
    // conversation is also not a legacy untyped default.
    try std.testing.expect(backfillMemoryType("conversation", "PREFERS", "user") == null);
}

test "backfillMemoryType: no predicate or same-type route → no-op" {
    // No predicate → leave untyped.
    try std.testing.expect(backfillMemoryType("core", "", "user") == null);
    // An .attribute predicate with attributed_to="user" routes back to core
    // → core==core → no churn.
    try std.testing.expect(backfillMemoryType("core", "LIVES_IN", "user") == null);
    // .attribute predicate with non-user attribution routes to daily → and a
    // daily row stays daily → no churn.
    try std.testing.expect(backfillMemoryType("daily", "LIVES_IN", "assistant") == null);
}

test "backfillMemoryType: attribute predicate can still move daily→core for user facts" {
    // A user-attributed .attribute fact that was mis-stored as daily routes to
    // core under the write-path logic; backfill corrects it.
    try std.testing.expectEqualStrings(
        "core",
        backfillMemoryType("daily", "LIVES_IN", "user").?,
    );
}

test "backfillEntityTypeFromPredicate: relationship predicates imply PERSON" {
    try std.testing.expectEqualStrings("PERSON", backfillEntityTypeFromPredicate("KNOWS").?);
    try std.testing.expectEqualStrings("PERSON", backfillEntityTypeFromPredicate("MARRIED_TO").?);
    try std.testing.expectEqualStrings("PERSON", backfillEntityTypeFromPredicate("WORKS_WITH").?);
    try std.testing.expectEqualStrings("PERSON", backfillEntityTypeFromPredicate("manages").?); // case-insensitive
}

test "backfillEntityTypeFromPredicate: non-relationship predicates yield null (no guessing)" {
    try std.testing.expect(backfillEntityTypeFromPredicate("PREFERS") == null); // preference
    try std.testing.expect(backfillEntityTypeFromPredicate("USES") == null); // usage
    try std.testing.expect(backfillEntityTypeFromPredicate("LIVES_IN") == null); // attribute
    try std.testing.expect(backfillEntityTypeFromPredicate("ATTENDED") == null); // episode
    try std.testing.expect(backfillEntityTypeFromPredicate("") == null);
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
///
/// **V1.14.11 — canonicalization fix (Captain Mochi investigation, 2026-05-18):**
/// Pre-fix, `subject` and `object` were hashed as-is, so the same logical
/// fact written via two paths with different casing produced two distinct
/// extracted_<hash> keys:
///   - Agent's memory_store: subject="user" → key A
///   - Extraction batch re-extract: subject="User" → key B
/// Two rows for one fact = duplicate writes that bypass primary-key dedup.
/// The contradiction judge then cleaned up the duplicates, but wastefully
/// (extra LLM call per orphan + alarming-looking "contradiction" log lines).
///
/// Fix: lowercase subject + object via `lowerForEntityKey` (the SAME
/// canonicalizer used by `deriveEntityKey` for entity-side hashing). Now
/// the same logical fact produces the SAME extracted_<hash> key regardless
/// of casing path, so re-extraction collides on primary key via
/// `INSERT ... ON CONFLICT DO NOTHING` → no duplicate row → no judge call.
///
/// **Predicate is NOT lowercased** because predicates are stored as
/// uppercase tokens by convention (LIKES, USES, IS_TYPE_OF) and the
/// extractor + agent both already emit them uppercase. Lowercasing
/// would break the existing wire format.
///
/// **Backwards compat:** pre-fix `extracted_<hash>` rows survive untouched.
/// They just don't dedupe against post-fix re-extractions of the SAME fact
/// with DIFFERENT case (one orphan duplicate per fact is the worst case,
/// matching pre-fix behavior). Going forward, new writes converge.
///
/// V1.14.12 (M3) — visibility changed from `fn` to `pub fn`. Callers
/// outside this module (specifically the coverage filter in
/// extraction/runner.zig) need to compute the same canonical key
/// to compare against agent_keys returned by
/// state_mgr.listAgentMemoryStoreKeys. Single source of truth for
/// the hash function — DO NOT inline-recompute in other modules.
pub fn deriveExtractionKey(
    allocator: std.mem.Allocator,
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
) ![]u8 {
    const subject_lower = try lowerForEntityKey(allocator, subject);
    defer allocator.free(subject_lower);
    const object_lower = try lowerForEntityKey(allocator, object);
    defer allocator.free(object_lower);

    // V1.14.12 (M3 review HIGH#2) — uppercase-normalize predicate.
    // Pre-fix: if the agent's memory_store wrote `predicate="likes"`
    // and the boundary extractor emitted `predicate="LIKES"`, the
    // hashes diverged and the M3 coverage filter silently MISSED the
    // duplicate — defeating the whole sprint. Predicates are stored
    // uppercase by convention (LIKES, USES, IS_TYPE_OF) but LLMs
    // occasionally emit them in mixed/lower case; this normalize
    // ensures key collision happens regardless of writer's casing.
    //
    // Migration note: like the V1.14.11 subject/object lowercase fix,
    // pre-V1.14.12 `extracted_<hash>` rows hashed without this
    // normalization survive untouched. New writes converge.
    var pred_buf: [128]u8 = undefined;
    const pred_len = @min(predicate.len, pred_buf.len);
    for (predicate[0..pred_len], 0..) |ch, i| pred_buf[i] = std.ascii.toUpper(ch);
    const predicate_upper = pred_buf[0..pred_len];

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(subject_lower);
    hasher.update("|");
    hasher.update(predicate_upper);
    hasher.update("|");
    hasher.update(object_lower);
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
///
/// V1.14.12 (M3) — `origin` field is now persisted to
/// `metadata->>'write_origin'` so the M3 coverage filter SQL query
/// (`listAgentMemoryStoreKeys`) can filter for facts the agent's
/// memory_store tool wrote, distinguishing them from boundary
/// extraction writes.
fn buildExtractionMetadata(
    allocator: std.mem.Allocator,
    mem: ExtractedMemory,
    origin: WriteOrigin,
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
    // V1.14.12 (M3) — write_origin enables the coverage filter to
    // identify agent-tool writes via SQL `metadata->>'write_origin'`.
    try w.writeAll(",\"write_origin\":\"");
    try writeJsonEscaped(w, origin.toSlice());
    try w.writeAll("\"");
    // V1.7a-5 (spec seam 3) — emit link_type derived from predicate so
    // SQL-side population (`metadata->>'link_type'`) populates the column
    // atomically with the metadata write. SQL backfill for legacy rows
    // (zaki_state migrate) covers pre-V1.7a-5 data.
    try w.writeAll(",\"link_type\":\"");
    try writeJsonEscaped(w, link_type.toString());
    try w.writeAll("\"");
    try w.print(",\"confidence\":{d:.3}", .{mem.confidence});
    try w.print(",\"extracted_at\":{d}", .{std.time.timestamp()});

    // D52 Pillar 2 (2026-05-28, prod-readiness Sprint 1) — tag detected
    // PII categories so the `memory_purge_pii` tool can offer
    // category-scoped delete. Detection is allocation-free + runs once
    // per write. Conservative set: phone + email only (see
    // `memory/pii_detect.zig` rationale on address/name omission).
    const pii_flags = pii_detect.detect(mem.text);
    if (pii_flags.any()) {
        try w.writeAll(",");
        try pii_detect.writeTagsJson(w, pii_flags);
    }

    try w.writeAll("}");
    return buf.toOwnedSlice(allocator);
}

/// P9 (memory-phase-0.5) — UNIFIED predicate classification.
///
/// Historically two disjoint allowlists classified the same `predicate`:
///   - `predicateToSlotType` → working-memory `SlotType` string (or null)
///   - `linkTypeForPredicate` → high-level `LinkType` category
/// They were separate functions that could silently disagree (e.g. a
/// predicate gaining a slot_type but never a matching link_type, or vice
/// versa). `classifyPredicate` is the single source of truth that returns
/// BOTH signals from ONE pass; the two legacy functions now delegate here
/// so the maps can never drift apart again.
///
/// NOTE — name disambiguation: this is DISTINCT from
/// `edge_resolution.classifyPredicate`, which returns a
/// `PredicateCardinality` (set-valued vs single-valued) for the judge
/// fast-path. Different concern, different return type; both names are
/// qualified at every call site.
///
/// Behavior contract (must remain byte-for-byte identical to the two
/// legacy maps):
///   - `slot_type` is matched case-INsensitively with NO length cap
///     (mirrors the old `predicateToSlotType`, which used
///     `std.ascii.eqlIgnoreCase` directly). null = no WM-slot promotion.
///   - `link_type` is matched case-INsensitively via an uppercase
///     normalize into a bounded 64-byte buffer; predicates longer than
///     the buffer fall through to `.attribute` (mirrors the old
///     `linkTypeForPredicate`). Default for any unrecognized predicate is
///     `.attribute`.
///
/// This function does NOT log — logging (the `extraction.linktype_map_default`
/// info on oversize / default) is preserved by the `linkTypeForPredicate`
/// wrapper so production telemetry is unchanged.
pub const PredicateClass = struct {
    /// Working-memory slot type (a `working_memory.SlotType.*` string), or
    /// null when the predicate does not warrant WM promotion.
    slot_type: ?[]const u8,
    /// High-level relationship category for the memory's entity edge.
    link_type: memory_root.LinkType,
};

pub fn classifyPredicate(predicate: []const u8) PredicateClass {
    return .{
        .slot_type = slotTypeForPredicate(predicate),
        .link_type = linkTypeForPredicateInner(predicate),
    };
}

/// Pure slot-type lookup — no length cap, case-insensitive. Extracted from
/// the legacy `predicateToSlotType` body so `classifyPredicate` and the
/// `predicateToSlotType` wrapper share ONE allowlist.
fn slotTypeForPredicate(predicate: []const u8) ?[]const u8 {
    // Open loops — pending actions the user mentioned.
    if (std.ascii.eqlIgnoreCase(predicate, "TODO")) return working_memory.SlotType.open_loop;
    if (std.ascii.eqlIgnoreCase(predicate, "WILL_DO")) return working_memory.SlotType.open_loop;
    if (std.ascii.eqlIgnoreCase(predicate, "REMINDS_ME_TO")) return working_memory.SlotType.open_loop;
    if (std.ascii.eqlIgnoreCase(predicate, "NEEDS_TO")) return working_memory.SlotType.open_loop;
    if (std.ascii.eqlIgnoreCase(predicate, "PROMISED")) return working_memory.SlotType.open_loop;
    if (std.ascii.eqlIgnoreCase(predicate, "OPEN_LOOP")) return working_memory.SlotType.open_loop;

    // Active goals — current projects / objectives.
    if (std.ascii.eqlIgnoreCase(predicate, "WORKING_ON")) return working_memory.SlotType.active_goal;
    if (std.ascii.eqlIgnoreCase(predicate, "BUILDING")) return working_memory.SlotType.active_goal;
    if (std.ascii.eqlIgnoreCase(predicate, "GOAL")) return working_memory.SlotType.active_goal;
    if (std.ascii.eqlIgnoreCase(predicate, "FOCUSING_ON")) return working_memory.SlotType.active_goal;
    if (std.ascii.eqlIgnoreCase(predicate, "WANTS_TO_FINISH")) return working_memory.SlotType.active_goal;

    // Decisions — committed choices.
    if (std.ascii.eqlIgnoreCase(predicate, "DECIDED")) return working_memory.SlotType.decision;
    if (std.ascii.eqlIgnoreCase(predicate, "CHOSE")) return working_memory.SlotType.decision;
    if (std.ascii.eqlIgnoreCase(predicate, "PICKED")) return working_memory.SlotType.decision;

    // Emotional state.
    if (std.ascii.eqlIgnoreCase(predicate, "FEELS")) return working_memory.SlotType.emotional;
    if (std.ascii.eqlIgnoreCase(predicate, "MENTAL_STATE")) return working_memory.SlotType.emotional;
    if (std.ascii.eqlIgnoreCase(predicate, "STRESSED_ABOUT")) return working_memory.SlotType.emotional;

    // Open questions.
    if (std.ascii.eqlIgnoreCase(predicate, "ASKING")) return working_memory.SlotType.open_question;
    if (std.ascii.eqlIgnoreCase(predicate, "WONDERING")) return working_memory.SlotType.open_question;

    // Temporal events.
    if (std.ascii.eqlIgnoreCase(predicate, "HAPPENS_ON")) return working_memory.SlotType.temporal;
    if (std.ascii.eqlIgnoreCase(predicate, "SCHEDULED_FOR")) return working_memory.SlotType.temporal;
    if (std.ascii.eqlIgnoreCase(predicate, "BIRTHDAY")) return working_memory.SlotType.temporal;

    return null;
}

/// Pure link-type lookup — NO logging. The oversize/default `log.info`
/// telemetry lives in the public `linkTypeForPredicate` wrapper so this
/// inner function stays side-effect-free and shareable by
/// `classifyPredicate`. Behavior (buffer size, default) matches the legacy
/// `linkTypeForPredicate` exactly.
fn linkTypeForPredicateInner(predicate: []const u8) memory_root.LinkType {
    var buf: [64]u8 = undefined;
    if (predicate.len > buf.len) return .attribute;
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

    return .attribute;
}

/// V1.7a-5 (spec seam 3) — map an extraction-time `predicate` (the SVO
/// triple verb, e.g. PREFERS, REPLACES, USED_FOR) to its high-level
/// `LinkType` category for FE rendering + agent-side reasoning.
///
/// The mapping is OPINIONATED but conservative: predicates we recognize
/// route to specific categories; unrecognized predicates default to
/// `.attribute` (the broadest category) AND log an info so production
/// telemetry surfaces gaps in our vocabulary. Adding a new predicate
/// to a category is a one-line patch in `linkTypeForPredicateInner`.
///
/// P9: this is now a thin LOGGING wrapper around the shared
/// `classifyPredicate`/`linkTypeForPredicateInner` lookup. The mapping
/// table moved into `linkTypeForPredicateInner` (single source of truth);
/// this wrapper preserves the legacy `extraction.linktype_map_default`
/// telemetry on the oversize + default branches so production behavior is
/// unchanged.
///
/// Single source of truth — every extraction write routes through here.
/// Comparison is case-INsensitive on ASCII so `"PREFERS"`, `"prefers"`,
/// and `"Prefers"` all map identically.
pub fn linkTypeForPredicate(predicate: []const u8) memory_root.LinkType {
    // Oversize predicates exceed the inner lookup's 64-byte normalize
    // buffer and fall through to .attribute. Preserve the legacy
    // oversize telemetry (logs predicate_len, not the raw string) before
    // delegating.
    if (predicate.len > 64) {
        log.info("extraction.linktype_map_default predicate_len={d} fallback=attribute", .{predicate.len});
        return .attribute;
    }
    const lt = linkTypeForPredicateInner(predicate);
    // `linkTypeForPredicateInner` returns .attribute ONLY on its default
    // branch (there are no explicit .attribute mappings), so a non-oversize
    // input landing on .attribute is exactly the legacy default branch —
    // emit the same telemetry the inlined map used to.
    if (lt == .attribute) {
        log.info("extraction.linktype_map_default predicate={s} fallback=attribute", .{predicate});
    }
    return lt;
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

// ── P9 parity: classifyPredicate is the single source of truth ────────
//
// This test pins the behavior-preserving contract for the P9 refactor.
// `Case` enumerates a representative predicate for EVERY branch of BOTH
// legacy maps (gathered by reading the pre-refactor bodies of
// `predicateToSlotType` and `linkTypeForPredicate` in full), plus the
// case-insensitivity, empty, and oversize edge cases. For each:
//   - `classifyPredicate(p).slot_type` MUST equal the EXPECTED legacy
//     `predicateToSlotType(p)` value, and
//   - `classifyPredicate(p).link_type` MUST equal the EXPECTED legacy
//     `linkTypeForPredicate(p)` value, and
//   - the two delegating wrappers MUST agree with `classifyPredicate`.
const ParityCase = struct {
    predicate: []const u8,
    want_slot: ?[]const u8,
    want_link: memory_root.LinkType,
};

test "P9 parity: classifyPredicate matches both legacy maps for every branch" {
    const WM = working_memory.SlotType;
    const cases = [_]ParityCase{
        // ── link_type: preference branch ──
        .{ .predicate = "PREFERS", .want_slot = null, .want_link = .preference },
        .{ .predicate = "LIKES", .want_slot = null, .want_link = .preference },
        .{ .predicate = "HATES", .want_slot = null, .want_link = .preference },
        .{ .predicate = "AVOIDS", .want_slot = null, .want_link = .preference },
        .{ .predicate = "FAVORS", .want_slot = null, .want_link = .preference },
        .{ .predicate = "DISLIKES", .want_slot = null, .want_link = .preference },
        .{ .predicate = "ENJOYS", .want_slot = null, .want_link = .preference },
        .{ .predicate = "VALUES", .want_slot = null, .want_link = .preference },
        // ── link_type: supersession branch ──
        .{ .predicate = "REPLACES", .want_slot = null, .want_link = .supersession },
        .{ .predicate = "USED_TO_BE", .want_slot = null, .want_link = .supersession },
        .{ .predicate = "FORMERLY", .want_slot = null, .want_link = .supersession },
        .{ .predicate = "PREVIOUSLY", .want_slot = null, .want_link = .supersession },
        .{ .predicate = "USED_TO_PREFER", .want_slot = null, .want_link = .supersession },
        .{ .predicate = "USED_TO_USE", .want_slot = null, .want_link = .supersession },
        // ── link_type: relationship branch ──
        .{ .predicate = "KNOWS", .want_slot = null, .want_link = .relationship },
        .{ .predicate = "WORKS_WITH", .want_slot = null, .want_link = .relationship },
        .{ .predicate = "MARRIED_TO", .want_slot = null, .want_link = .relationship },
        .{ .predicate = "FRIENDS_WITH", .want_slot = null, .want_link = .relationship },
        .{ .predicate = "MANAGES", .want_slot = null, .want_link = .relationship },
        .{ .predicate = "REPORTS_TO", .want_slot = null, .want_link = .relationship },
        .{ .predicate = "COLLABORATES_WITH", .want_slot = null, .want_link = .relationship },
        .{ .predicate = "RELATED_TO", .want_slot = null, .want_link = .relationship },
        // ── link_type: usage branch ──
        .{ .predicate = "USED_FOR", .want_slot = null, .want_link = .usage },
        .{ .predicate = "USES", .want_slot = null, .want_link = .usage },
        .{ .predicate = "OWNS", .want_slot = null, .want_link = .usage },
        .{ .predicate = "DEPENDS_ON", .want_slot = null, .want_link = .usage },
        .{ .predicate = "BUILDS_WITH", .want_slot = null, .want_link = .usage },
        .{ .predicate = "DEPLOYS_TO", .want_slot = null, .want_link = .usage },
        // ── link_type: episode branch ──
        .{ .predicate = "HAPPENED_ON", .want_slot = null, .want_link = .episode },
        .{ .predicate = "ATTENDED", .want_slot = null, .want_link = .episode },
        .{ .predicate = "OCCURRED_AT", .want_slot = null, .want_link = .episode },
        .{ .predicate = "JOINED", .want_slot = null, .want_link = .episode },
        .{ .predicate = "VISITED", .want_slot = null, .want_link = .episode },
        // ── slot_type: open_loop branch (all unmapped link → .attribute) ──
        .{ .predicate = "TODO", .want_slot = WM.open_loop, .want_link = .attribute },
        .{ .predicate = "WILL_DO", .want_slot = WM.open_loop, .want_link = .attribute },
        .{ .predicate = "REMINDS_ME_TO", .want_slot = WM.open_loop, .want_link = .attribute },
        .{ .predicate = "NEEDS_TO", .want_slot = WM.open_loop, .want_link = .attribute },
        .{ .predicate = "PROMISED", .want_slot = WM.open_loop, .want_link = .attribute },
        .{ .predicate = "OPEN_LOOP", .want_slot = WM.open_loop, .want_link = .attribute },
        // ── slot_type: active_goal branch ──
        .{ .predicate = "WORKING_ON", .want_slot = WM.active_goal, .want_link = .attribute },
        .{ .predicate = "BUILDING", .want_slot = WM.active_goal, .want_link = .attribute },
        .{ .predicate = "GOAL", .want_slot = WM.active_goal, .want_link = .attribute },
        .{ .predicate = "FOCUSING_ON", .want_slot = WM.active_goal, .want_link = .attribute },
        .{ .predicate = "WANTS_TO_FINISH", .want_slot = WM.active_goal, .want_link = .attribute },
        // ── slot_type: decision branch ──
        .{ .predicate = "DECIDED", .want_slot = WM.decision, .want_link = .attribute },
        .{ .predicate = "CHOSE", .want_slot = WM.decision, .want_link = .attribute },
        .{ .predicate = "PICKED", .want_slot = WM.decision, .want_link = .attribute },
        // ── slot_type: emotional branch ──
        .{ .predicate = "FEELS", .want_slot = WM.emotional, .want_link = .attribute },
        .{ .predicate = "MENTAL_STATE", .want_slot = WM.emotional, .want_link = .attribute },
        .{ .predicate = "STRESSED_ABOUT", .want_slot = WM.emotional, .want_link = .attribute },
        // ── slot_type: open_question branch ──
        .{ .predicate = "ASKING", .want_slot = WM.open_question, .want_link = .attribute },
        .{ .predicate = "WONDERING", .want_slot = WM.open_question, .want_link = .attribute },
        // ── slot_type: temporal branch ──
        .{ .predicate = "HAPPENS_ON", .want_slot = WM.temporal, .want_link = .attribute },
        .{ .predicate = "SCHEDULED_FOR", .want_slot = WM.temporal, .want_link = .attribute },
        // BIRTHDAY: temporal slot AND .attribute link — the canonical
        // example of a predicate the two legacy maps classified
        // DIFFERENTLY (slot ≠ null, link = default). Pins the cross-map
        // independence the unified function must preserve.
        .{ .predicate = "BIRTHDAY", .want_slot = WM.temporal, .want_link = .attribute },
        // ── case-insensitivity (both maps are case-insensitive) ──
        .{ .predicate = "prefers", .want_slot = null, .want_link = .preference },
        .{ .predicate = "Prefers", .want_slot = null, .want_link = .preference },
        .{ .predicate = "todo", .want_slot = WM.open_loop, .want_link = .attribute },
        .{ .predicate = "birthday", .want_slot = WM.temporal, .want_link = .attribute },
        // ── unknown + empty → slot null, link .attribute ──
        .{ .predicate = "UNKNOWN_VERB", .want_slot = null, .want_link = .attribute },
        .{ .predicate = "WORKS_AT", .want_slot = null, .want_link = .attribute },
        .{ .predicate = "", .want_slot = null, .want_link = .attribute },
        // ── oversize (65 chars) → slot null, link .attribute ──
        .{ .predicate = "A" ** 65, .want_slot = null, .want_link = .attribute },
    };

    for (cases) |tc| {
        const got = classifyPredicate(tc.predicate);
        // slot_type parity (optional []const u8 — compare via expectEqualSlices)
        if (tc.want_slot) |ws| {
            try std.testing.expect(got.slot_type != null);
            try std.testing.expectEqualSlices(u8, ws, got.slot_type.?);
        } else {
            try std.testing.expect(got.slot_type == null);
        }
        // link_type parity
        try std.testing.expectEqual(tc.want_link, got.link_type);

        // The two delegating wrappers MUST return EXACTLY what
        // classifyPredicate computed (behavior-preserving contract).
        const wrapper_slot = predicateToSlotType(tc.predicate);
        if (got.slot_type) |gs| {
            try std.testing.expect(wrapper_slot != null);
            try std.testing.expectEqualSlices(u8, gs, wrapper_slot.?);
        } else {
            try std.testing.expect(wrapper_slot == null);
        }
        try std.testing.expectEqual(got.link_type, linkTypeForPredicate(tc.predicate));
    }
}

// ── P3: semantic memory_type routing ──────────────────────────────────
//
// categoryForSemantics routes the durable memory_type by the predicate's
// meaning (via classifyPredicate), falling back to attribution only when
// the fact carries no distinctive semantic signal. Asserts each of the
// four custom: types fires for a representative predicate, the fallback
// preserves the legacy user→core / else→daily behavior, and the routing is
// independent of `attributed_to` for the semantic cases.
test "P3 categoryForSemantics routes by predicate meaning, not attribution" {
    const expectCustom = struct {
        fn f(cat: memory_root.MemoryCategory, want: []const u8) !void {
            try std.testing.expect(cat == .custom);
            try std.testing.expectEqualStrings(want, cat.custom);
        }
    }.f;

    // open_loop slot → custom:"open_loop" (regardless of speaker).
    try expectCustom(categoryForSemantics(classifyPredicate("TODO"), "user"), "open_loop");
    try expectCustom(categoryForSemantics(classifyPredicate("PROMISED"), "assistant"), "open_loop");
    // decision slot → custom:"decision".
    try expectCustom(categoryForSemantics(classifyPredicate("DECIDED"), "assistant"), "decision");
    try expectCustom(categoryForSemantics(classifyPredicate("CHOSE"), "user"), "decision");
    // preference link → custom:"preference".
    try expectCustom(categoryForSemantics(classifyPredicate("PREFERS"), "assistant"), "preference");
    try expectCustom(categoryForSemantics(classifyPredicate("LIKES"), "user"), "preference");
    // relationship link → custom:"person".
    try expectCustom(categoryForSemantics(classifyPredicate("KNOWS"), "user"), "person");
    try expectCustom(categoryForSemantics(classifyPredicate("MARRIED_TO"), "assistant"), "person");

    // No distinctive signal → fall back to attribution routing
    // (user→core, else→daily) — the exact legacy behavior.
    try std.testing.expect(categoryForSemantics(classifyPredicate("WORKS_AT"), "user").eql(.core));
    try std.testing.expect(categoryForSemantics(classifyPredicate("WORKS_AT"), "assistant").eql(.daily));
    try std.testing.expect(categoryForSemantics(classifyPredicate("LIVES_IN"), "undecided").eql(.daily));
    // Unknown predicate, user-attributed → core (fallback path).
    try std.testing.expect(categoryForSemantics(classifyPredicate("UNKNOWN_VERB"), "user").eql(.core));
}

// P4d: the public session-end routing entry used by commands.zig's legacy
// durable_fact loop. With the flag ON it mirrors categoryForSemantics; with
// the flag OFF it reduces to categoryForAttribution. The headline case: a
// triple-bearing session-end PREFERS fact gets memory_type="preference"
// (previously it was hardcoded `.core` and never surfaced in <preferences>).
test "P4d categoryForSessionEndFact routes triple-bearing session-end facts by meaning" {
    const expectCustom = struct {
        fn f(cat: memory_root.MemoryCategory, want: []const u8) !void {
            try std.testing.expect(cat == .custom);
            try std.testing.expectEqualStrings(want, cat.custom);
        }
    }.f;

    // Headline TDD case: triple-bearing PREFERS fact → "preference".
    try expectCustom(categoryForSessionEndFact("PREFERS", "user", true), "preference");
    // Other semantic types route too.
    try expectCustom(categoryForSessionEndFact("DECIDED", "assistant", true), "decision");
    try expectCustom(categoryForSessionEndFact("TODO", "user", true), "open_loop");
    try expectCustom(categoryForSessionEndFact("MARRIED_TO", "user", true), "person");

    // Empty attribution (common at session end) with no semantic signal → the
    // legacy `.daily` fallback shape (else→daily). Confirms an empty string is
    // safe.
    try std.testing.expect(categoryForSessionEndFact("WORKS_AT", "", true).eql(.daily));
    // Semantic signal wins even with empty attribution.
    try expectCustom(categoryForSessionEndFact("PREFERS", "", true), "preference");

    // Flag OFF → exact legacy categoryForAttribution behavior (no semantic
    // routing). A PREFERS fact attributed to the user lands `.core`, NOT
    // "preference" — this is the cost/latency-free rollback contract.
    try std.testing.expect(categoryForSessionEndFact("PREFERS", "user", false).eql(.core));
    try std.testing.expect(categoryForSessionEndFact("PREFERS", "assistant", false).eql(.daily));
}

// P3: with the flag OFF (the `else` branch at the persist site), routing
// reduces to the legacy categoryForAttribution. This pins that the
// fallback function itself is unchanged.
test "P3 categoryForAttribution unchanged (flag-off path)" {
    try std.testing.expect(categoryForAttribution("user").eql(.core));
    try std.testing.expect(categoryForAttribution("assistant").eql(.daily));
    try std.testing.expect(categoryForAttribution("assistant_offer").eql(.daily));
    try std.testing.expect(categoryForAttribution("undecided").eql(.daily));
    try std.testing.expect(categoryForAttribution("anything_else").eql(.daily));
}

// P3 review (memory-phase-0.5) — the persist-site gate's category decision,
// extracted as a pure helper so the off-switch is testable WITHOUT a live DB
// or a JudgeContext. This mirrors the exact expression at the persist site:
//   category = if (enabled) categoryForSemantics(...) else categoryForAttribution(...)
// The point being pinned: the result depends ONLY on the explicit flag, never
// on whether a judge is present.
fn gateCategory(
    semantic_type_routing_enabled: bool,
    predicate: []const u8,
    attributed_to: []const u8,
) memory_root.MemoryCategory {
    return if (semantic_type_routing_enabled)
        categoryForSemantics(classifyPredicate(predicate), attributed_to)
    else
        categoryForAttribution(attributed_to);
}

test "P3 review: off-switch honored on no-judge tenants (flag false → legacy routing)" {
    // A user-attributed PREFERS fact. With routing ON it becomes
    // custom:"preference" (semantic). With routing OFF it must reproduce
    // the EXACT legacy categoryForAttribution result: user → .core.
    //
    // The gate value passed to persistExtracted is now an explicit param
    // that is ALWAYS present (no JudgeContext required) — so an operator's
    // flag=false takes effect even when judge == null. These assertions pin
    // that the category is a pure function of the flag, independent of judge.

    // Flag ON → semantic type (regression baseline: must be preference).
    try std.testing.expect(gateCategory(true, "PREFERS", "user").eql(.{ .custom = "preference" }));

    // Flag OFF → legacy attribution routing, identical to the pre-P3 path.
    // This is the no-judge off-switch: the value below is what the persist
    // site computes when judge == null AND the operator set the flag false.
    try std.testing.expect(gateCategory(false, "PREFERS", "user").eql(.core));
    try std.testing.expect(gateCategory(false, "PREFERS", "assistant").eql(.daily));
    // Open-loop predicate, user-attributed: ON → custom:"open_loop";
    // OFF → legacy (user → core), proving the override is total.
    try std.testing.expect(gateCategory(true, "NEEDS_TO", "user").eql(.{ .custom = "open_loop" }));
    try std.testing.expect(gateCategory(false, "NEEDS_TO", "user").eql(.core));
    // Flag OFF must EXACTLY equal categoryForAttribution for every input,
    // with no dependence on predicate semantics.
    try std.testing.expect(gateCategory(false, "PREFERS", "user").eql(categoryForAttribution("user")));
    try std.testing.expect(gateCategory(false, "NEEDS_TO", "assistant").eql(categoryForAttribution("assistant")));
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

/// V1.14.12 (M1) — origin tag for telemetry. Identifies which of the
/// production write callsites invoked persistExtracted. Used by the
/// `memory.write.batch origin=X ...` log line to build the per-path
/// write histogram that gates M3 (coverage filter), M5 (legacy direct-
/// write deletion), and M6 (judge model swap). Tag set by caller, no
/// behavior change — just labels the call for the histogram.
///
/// Each caller MUST pass an explicit tag. There is no default. If a new
/// callsite is added without picking a tag, the build breaks (no
/// implicit `.unknown` fallback) — forces conscious decision.
pub const WriteOrigin = enum {
    /// Agent's memory_store tool (per-turn, agent-driven).
    memory_store_tool,
    /// Mid-session compaction drop extraction (compaction.zig::compactHistory).
    pass_a_drop,
    /// End-of-compaction summary extraction via extractAtBoundary
    /// (compaction.zig Pass C site → runner.zig::extractAtBoundary).
    pass_c_compaction_extract,
    /// Session-end TTL extraction via extractAtBoundary
    /// (commands.zig session_end site → runner.zig::extractAtBoundary).
    session_end_extract,
    /// Test harness wire (zaki_state.zig test fixture + unit tests). Not production.
    test_wire,
    /// V1.14.12 (M3 review MED) — defensive fallback for a future caller
    /// added without picking a precise tag. A `.unknown` emission in the
    /// histogram is a LOUD signal to add a real tag. Never use in new
    /// callers; safety net only.
    unknown,

    pub fn toSlice(self: WriteOrigin) []const u8 {
        return @tagName(self);
    }
};

/// Persist a batch of extracted memories.
///
/// Provider-agnostic. The `memories` slice can come from the compaction
/// LLM (today's primary path), agent tool writes, or the classifier
/// when those land. Each fact passes through:
///   1. predicate blacklist (defense-in-depth against meta-narrative)
///   2. SHA-256 content_hash dedup pre-filter (V1.6 5b.3 — exact-byte match)
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
///
/// P3 — map a WriteOrigin to the short extraction_pass label stored in
/// memory_edges.extraction_pass. Callers that fire at a compaction or
/// session-end boundary get a descriptive label; the entity pipeline and
/// test wire get "tool" / "test" / "unknown" so the column is never NULL
/// for rows that have a real origin.
fn originToExtractionPass(origin: WriteOrigin) []const u8 {
    return switch (origin) {
        .pass_a_drop               => "pass_a",
        .pass_c_compaction_extract => "pass_c",
        .session_end_extract       => "session_end",
        .memory_store_tool         => "tool",
        .test_wire                 => "test",
        else                       => "unknown",
    };
}

/// V1.14.12 (M1) — `origin` parameter labels the call for per-path
/// telemetry. See WriteOrigin docstring.
///
/// P3 — `session_boundary_id` is a milliTimestamp captured by the caller
/// immediately before firing a compaction or session-end boundary. Pass 0
/// for non-boundary callers (memory_store_tool, test_wire). The value is
/// stored in memory_edges.session_boundary_id so boundary-scoped edges can
/// be grouped without parsing timestamps.
pub fn persistExtracted(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    session_id: ?[]const u8,
    memories: []const ExtractedMemory,
    judge: ?JudgeContext,
    coref: ?EntityResolution,
    // V1.8-2: when non-null, every successfully persisted fact also gets
    // indexed into the vector store via syncVectorAfterStore. This closes
    // G-C — extraction_persist was the conspicuous omission across 13
    // existing syncVectorAfterStore callers, leaving extracted_* memories
    // un-vectorized (audit found 4/43 = 9% coverage on user 7777).
    // Failure is non-fatal: the memory row is canonical; the vector is
    // a retrieval optimization. Pass null to keep V1.7 behavior (test
    // fixtures, non-postgres deploys).
    mem_rt: ?*memory_root.MemoryRuntime,
    origin: WriteOrigin,
    session_boundary_id: i64, // P3: milliTimestamp at boundary fire; 0 for non-boundary callers
    // P3 review (memory-phase-0.5) — semantic type-routing off-switch.
    // Threaded ALWAYS (independent of `judge`) so the config flag is honored
    // even on no-judge tenants (graceful-degradation path). Default-ON is the
    // caller's responsibility; every call site forwards the configured value
    // (memory_store `self.`, runner `ctx.`) or `true` for test fixtures.
    // Previously this was read off `JudgeContext` and defaulted to `true`
    // whenever `judge == null`, which silently ignored an operator's
    // flag=false on tenants with no extraction judge.
    semantic_type_routing_enabled: bool,
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

    // V1.14.12 (M1) — per-path telemetry. One log per persistExtracted
    // call; downstream baseline_analyzer.py builds the origin histogram.
    //
    // V1.14.12 (M1 review MEDIUM#2) — renamed `count` → `attempted` to
    // reflect that this is INPUT cardinality, not write cardinality.
    // Blacklist + MD5 + cardinality fast-path + judge skips can all
    // reduce attempted → written. The trailing log line at end of
    // batch reports `written` + `skipped_total` so M3/M5 redundancy
    // decisions get accurate numerators/denominators.
    log.info(
        "memory.write.batch origin={s} attempted={d} user_id={d} session={s} judge={s}",
        .{
            origin.toSlice(),
            memories.len,
            user_id,
            session_id orelse "-",
            if (judge != null) "on" else "off",
        },
    );

    for (memories) |m| {
        // Step 1: predicate blacklist
        if (isRejectedPredicate(m.predicate)) {
            log.warn("extraction.rejected_predicate predicate={s} subject={s}", .{ m.predicate, m.subject });
            result.skipped_blacklist += 1;
            continue;
        }

        // Step 1b (brain-leak Fix A): entity-name denylist. Reject the WHOLE
        // fact if its SUBJECT or OBJECT is a system-prompt scaffold artifact
        // (## Brain Architecture, Memory Link Types, "Working memory", …)
        // BEFORE any memory row / entity / edge is written. This is the
        // keystone gate that stops the #48 feedback loop at the write boundary.
        // Logged at warn for observability so recurrence is visible.
        if (isRejectedEntityName(m.subject) or isRejectedEntityName(m.object)) {
            log.warn(
                "extraction.rejected_scaffold_entity subject={s} predicate={s} object={s}",
                .{ m.subject, m.predicate, m.object },
            );
            result.skipped_scaffold += 1;
            continue;
        }

        // Step 2 (V1.6 5b.3 WR-1): SHA-256 content_hash dedup. Compaction
        // Pass C re-summarizes prior prose summaries on each trigger,
        // causing the LLM to re-emit the same atomic facts. Skip if a
        // memory with identical normalized content already exists for
        // this user. Cheap — uses idx_memories_hash directly.
        const content_hash = computeContentHashHex(allocator, m.text) catch |err| {
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

        // V1.14.12 (M2) — cardinality fast-path.
        //
        // Skip the LLM judge entirely for facts where (a) the predicate
        // is set-valued AND (b) the fact's text contains no explicit
        // negation language. Set-valued predicates (LIKES, USES,
        // IS_TYPE_OF, ATTENDED, etc.) are additive by default — the
        // same subject can have many of them. Treating a new
        // (subject, predicate, different_object) tuple as a
        // contradiction is the Captain Mochi misfire pattern.
        //
        // The judge STILL fires for:
        //   - single-valued predicates (LIVES_IN, MARRIED_TO, BIRTHDAY)
        //     where new value DOES supersede old
        //   - explicit negation in the fact text ("no longer", "stopped",
        //     "instead of"), even on set-valued predicates
        //   - unknown predicates (conservative: let judge decide)
        //
        // Effect post-deploy: judge invocation rate drops from ~50% to
        // <10% of writes. MD5 + canonical-key + coref dedup still
        // protect against duplicates; only the LLM contradiction step
        // is bypassed for the set-valued additive case.
        //
        // Reversibility: revert this commit. The set-valued prompt
        // section in buildResolvePrompt is intentionally kept during
        // soak window — if M2 is reverted, Llama still gets the SET-
        // VALUED guidance via the prompt (less effective but a safety
        // net).
        const cardinality = edge_resolution.classifyPredicate(m.predicate);
        const has_negation = edge_resolution.textHasExplicitNegation(m.text);
        // V1.14.12 (M2 review CRITICAL): read the fast-path flag from
        // the JudgeContext. Null judge → flag doesn't matter (no judge
        // to skip), but we conservatively treat null as flag=true.
        const fastpath_enabled = if (judge) |j| j.cardinality_fastpath_enabled else true;
        if (fastpath_enabled and cardinality == .set_valued and !has_negation) {
            log.info(
                "memory.write.cardinality_fastpath subject={s} predicate={s} reason=set_valued_no_negation",
                .{ m.subject, m.predicate },
            );
            // Skip judge entirely. Fall through to the write block below.
        } else if (judge) |j| {
            // Original judge invocation (single-valued OR explicit
            // negation OR unknown predicate — judge can add value).
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

            // V1.8-1 fix: apply contradictions BEFORE the is_duplicate
            // short-circuit. Previously, when judge returned BOTH
            // is_duplicate=true AND contradictions.len>0, the code
            // logged the duplicate and `continue`'d immediately,
            // discarding the contradictions. This meant: judge correctly
            // detected supersession, contradiction was LOGGED, but
            // applyContradictions NEVER RAN — the old fact remained
            // is_latest=true forever. Symptom: 0 supersede events in
            // memory_events despite "edge_resolution.contradiction"
            // logging. Confirmed by V1.8-1 eval run on preference_changes
            // corpus (3 contradictions detected, 0 applied).
            //
            // Apply order: contradictions FIRST (close out superseded
            // facts), then check is_duplicate (skip the new write since
            // semantically identical to an existing fact). Closing the
            // contradictions makes hybrid recall in the next iteration
            // of this same batch correctly skip the about-to-be-
            // superseded rows. Idempotent, safe even if subsequent
            // steps fail.
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

            if (outcome.is_duplicate) {
                log.info("extraction.semantic_dup_skipped subject={s} predicate={s}", .{
                    m.subject, m.predicate,
                });
                result.skipped_semantic_dup += 1;
                continue;
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

        const metadata_json = buildExtractionMetadata(allocator, m, origin) catch |err| {
            log.warn("extraction.metadata_build_failed err={s}", .{@errorName(err)});
            result.failed_count += 1;
            continue;
        };
        defer allocator.free(metadata_json);

        // P3 (memory-phase-0.5) — route the durable memory_type by what
        // the fact MEANS, not by who said it. Gated by the
        // semantic_type_routing_enabled flag (default ON), now threaded as an
        // explicit parameter that is ALWAYS present — independent of whether a
        // JudgeContext exists. Flag OFF → exact legacy categoryForAttribution
        // behavior on ALL tenants, including no-judge ones (P3 review fix:
        // the off-switch previously hardcoded `true` when judge == null).
        // `attributed_to` stays recorded as provenance in the metadata
        // (buildExtractionMetadata above), it just no longer routes the type.
        const category = if (semantic_type_routing_enabled)
            categoryForSemantics(classifyPredicate(m.predicate), m.attributed_to)
        else
            categoryForAttribution(m.attributed_to);

        // V1.14.12 (Memory audit Finding 6 fix, 2026-05-19) — route
        // through the event-typed variant so memory_events.event_type
        // = 'extraction' (not 'compose'). Matches the contract docstring
        // at extraction_persist.zig:34 and makes timeline / audit
        // analytics able to distinguish extraction-classifier writes
        // from compose-tool writes.
        state_mgr.upsertMemoryWithMetadataAndEventType(
            user_id,
            key,
            m.text,
            category,
            session_id,
            metadata_json,
            "extraction",
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
        // Speaker/self pseudo-entities can occur on either endpoint. They are
        // conversation participants, not durable graph entities, so keep the
        // memory fact but omit entity resolution and edge materialization.
        const target_key: ?[]u8 = if (isSelfPseudoSubject(m.object))
            null
        else
            resolveEntityKey(allocator, state_mgr, user_id, m.object, "PROPER", coref) catch |err| blk: {
                log.warn("extraction.entity_resolve_failed err={s} object={s}", .{ @errorName(err), m.object });
                // Final fallback: hash-only key so the edge still writes
                break :blk deriveEntityKey(allocator, m.object) catch null;
            };

        // P7 (CRM substrate) — resolve the SUBJECT to an entity node too, when
        // it is a named entity (e.g. a person), so "Tarek WORKS_AT Acme" makes
        // Tarek a first-class graph node — not just Acme. The pre-P7 path only
        // ever resolved the object, so a person-as-subject produced 0 typed
        // nodes. We skip the self/speaker pseudo-subjects ("user", "I", …):
        // those denote the conversation participants (the `user:<id>` speaker
        // hub), not entities. Best-effort: subject-resolution failure never
        // aborts the object edge below. `'PROPER'` here can only UPGRADE the
        // row (the no-clobber rule in upsertEntity protects a known type).
        const subject_key: ?[]u8 = if (isSelfPseudoSubject(m.subject))
            null
        else
            resolveEntityKey(allocator, state_mgr, user_id, m.subject, "PROPER", coref) catch |err| blk: {
                log.warn("extraction.subject_resolve_failed err={s} subject={s}", .{ @errorName(err), m.subject });
                break :blk null;
            };
        defer if (subject_key) |sk| allocator.free(sk);

        if (target_key) |tk| {
            defer allocator.free(tk);

            // P7 — emit the relationship edge between the two resolved
            // entities so the subject node is connected, not orphaned:
            //   subject_entity --predicate--> object_entity
            // (e.g. Tarek --WORKS_AT--> Acme). Keeps the same predicate +
            // provenance as the memory→object edge below. Best-effort.
            if (subject_key) |sk| {
                if (!std.mem.eql(u8, sk, tk)) {
                    state_mgr.upsertMemoryEdgeRich(
                        user_id,
                        sk,
                        tk,
                        m.predicate,
                        "extraction_classifier",
                        m.confidence,
                        m.text,
                        m.temporal_anchor_unix,
                        key,
                        originToExtractionPass(origin),
                        if (session_boundary_id == 0) null else session_boundary_id,
                    ) catch |err| {
                        log.warn("extraction.subject_edge_write_failed subject={s} target={s} predicate={s} err={s}", .{
                            sk, tk, m.predicate, @errorName(err),
                        });
                    };
                }
            }
            // V1.14 — call the rich variant. Pass:
            //   - fact = m.text (the full sentence the LLM produced)
            //   - temporal_anchor_unix = m.temporal_anchor_unix
            //     (parsed from the optional `valid_at` ISO-8601 in the
            //     extractor JSON; null when the fact has no temporal
            //     anchor — write-time falls back as `valid_from`)
            //   - episode_key = key (the memory row this edge derives
            //     from — first-class provenance, joins to messages
            //     and memory_events for full audit chain)
            state_mgr.upsertMemoryEdgeRich(
                user_id,
                key,
                tk,
                m.predicate,
                "extraction_classifier",
                m.confidence,
                m.text,
                m.temporal_anchor_unix,
                key,
                originToExtractionPass(origin), // P3: extraction pass label
                if (session_boundary_id == 0) null else session_boundary_id, // P3: boundary ID; null for non-boundary
            ) catch |err| {
                log.warn("extraction.edge_write_failed source={s} target={s} predicate={s} err={s}", .{
                    key, tk, m.predicate, @errorName(err),
                });
            };
        }

        // V1.8-2: index the new fact's content into the vector store.
        // Closes G-C (extraction_persist was the only S2 writer that
        // didn't index, leaving extracted_* memories un-vectorized →
        // /memory search vector_score=n/a for ALL hits, semantic recall
        // degraded to BM25-only). Best-effort: failure is logged inside
        // syncVectorAfterStore, doesn't affect the memory row.
        if (mem_rt) |rt| _ = rt.syncVectorAfterStore(allocator, key, m.text);

        // V1.13 Day 1 — Working Memory auto-promotion. When the
        // extracted fact's predicate signals an open loop / active
        // goal / decision / etc, promote it to a working-memory slot
        // so it surfaces in subsequent prompts without requiring
        // recall to find it. Failure-soft: any error logs and
        // continues — the canonical memory row is the source of truth.
        //
        // V1.14.8 C4: prefer LLM-tagged `m.slot_intent` (set by the
        // boundary extractor when the LLM identifies the working-memory
        // intent directly) over the predicate-derived mapping. The
        // predicate fallback still catches cases where the LLM didn't
        // tag intent but the predicate is on the legacy allowlist.
        if (session_id) |sid| {
            const slot_type_opt: ?[]const u8 =
                m.slot_intent orelse predicateToSlotType(m.predicate);
            if (slot_type_opt) |slot_type| {
                _ = working_memory.promoteSlot(
                    allocator,
                    state_mgr,
                    user_id,
                    sid,
                    slot_type,
                    m.text,
                    key,
                    @max(m.confidence, 0.5),
                    false, // pinned=false; only identity slots are pinned
                ) catch |err| blk: {
                    log.warn("extraction.wm_promote_failed err={s} predicate={s}", .{
                        @errorName(err), m.predicate,
                    });
                    break :blk null;
                };
            }
        }

        log.info("extraction.persisted key={s} subject={s} predicate={s} attributed_to={s}", .{
            key, m.subject, m.predicate, m.attributed_to,
        });
        result.written_count += 1;
    }

    // V1.14.12 (M1 review MEDIUM#2) — trailing summary log. Pairs with
    // the leading `memory.write.batch attempted=N` line to give the
    // baseline_analyzer.py histogram both attempted AND actually-
    // written counts per origin. M3/M5 redundancy gates compare the
    // WRITTEN counts (not attempted) to decide whether direct paths
    // are subsumed by extract paths.
    log.info(
        "memory.write.batch_done origin={s} attempted={d} written={d} skipped_md5={d} skipped_semantic={d} skipped_blacklist={d} skipped_scaffold={d} contradictions={d} failed={d}",
        .{
            origin.toSlice(),
            memories.len,
            result.written_count,
            result.skipped_md5_dup,
            result.skipped_semantic_dup,
            result.skipped_blacklist,
            result.skipped_scaffold,
            result.contradictions_resolved,
            result.failed_count,
        },
    );

    return result;
}

/// V1.13 Day 1 — map an extraction predicate to a Working Memory slot
/// type, or null if the predicate doesn't warrant promotion. Conservative
/// list — predicates that materially affect future turns get promoted;
/// ordinary attributive facts (e.g. WORKS_AT, LIVES_IN) don't take WM
/// slots because they live in canonical memory and are recalled by
/// hybrid search when relevant.
///
/// BIRTHDAY is the temporal-cluster exception: it IS promoted to the
/// `temporal` slot (see line below) because the working-memory countdown
/// surface needs upcoming dated events queryable without a hybrid recall
/// round-trip. Docstring corrected at v1.14.13 Step 5 (BIRTHDAY-DOC) —
/// previous docstring claimed BIRTHDAY did not promote; the code has
/// always promoted it. The code is correct; the doc lied.
///
/// P9: now a thin delegate to the shared `classifyPredicate` (via
/// `slotTypeForPredicate`). The allowlist moved into
/// `slotTypeForPredicate` (single source of truth shared with the
/// link_type map) so the two maps can never drift apart.
fn predicateToSlotType(predicate: []const u8) ?[]const u8 {
    return classifyPredicate(predicate).slot_type;
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
/// P7 — `entity_type` is the class to stamp on a freshly-minted entity
/// (`'PROPER'` for the object/subject endpoints of an extracted triple, which
/// carry no per-endpoint type in the triple JSON). Threaded into `upsertEntity`
/// so the no-clobber-PROPER rule applies: if the entity already exists with a
/// real type (from the entity_pipeline path), passing `'PROPER'` here will NOT
/// demote it.
fn resolveEntityKey(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    object: []const u8,
    entity_type: []const u8,
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
    const new_id = state_mgr.upsertEntity(allocator, user_id, object, entity_type, embedding) catch |err| {
        log.warn("extraction.entity_upsert_failed err={s} object={s} — using hash fallback", .{
            @errorName(err), object,
        });
        return deriveEntityKey(allocator, object);
    };
    log.info("extraction.entity_created object={s} entity_id={s}", .{ object, new_id });
    return new_id;
}

/// P7 — is this triple endpoint a speaker/self pseudo-entity rather than a
/// named graph entity? "user" / "assistant" / "I" / "me" / "you" denote the
/// conversation participants (the speaker hub `user:<id>`), NOT first-class
/// entity nodes. Everything else (a person's name like "Tarek", an org, …) is
/// a named entity that SHOULD become its own resolvable node so
/// "Tarek WORKS_AT Acme" makes Tarek a node — not just Acme. Case-insensitive.
fn isSelfPseudoSubject(endpoint: []const u8) bool {
    const self_terms = [_][]const u8{ "user", "assistant", "i", "me", "you", "we", "self" };
    for (self_terms) |t| {
        if (std.ascii.eqlIgnoreCase(t, endpoint)) return true;
    }
    return false;
}

/// Hash-fallback entity key for an `object` surface form.
///
/// Used by `resolveEntityKey` when no coreference embedding provider is
/// available, when an embed call fails, or when entity upsert fails — i.e.
/// the deterministic path that needs no DB round-trip. Returns
/// `entity_<hex>` where `<hex>` is the first 8 bytes of the SHA-256 of the
/// canonicalized object.
///
/// The `lowerForEntityKey` canonicalization is load-bearing: the PG cmt16
/// backfill SQL mirrors it so runtime extraction and backfill produce
/// byte-identical keys for the same surface form regardless of casing —
/// re-extraction then collides on the primary key (`ON CONFLICT DO NOTHING`)
/// instead of writing a duplicate row. Caller frees the slice.
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
/// entity-key hashing. `extraction_persist.deriveEntityKey` routes every
/// `object` string through this before SHA-256. The PG cmt16 backfill SQL
/// must also call PG's `lower(...)` (Unicode-aware) on the same input so
/// backfill and runtime extraction produce byte-identical hashes.
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
    try std.testing.expect(isRejectedPredicate("NO_CONNECTION_FOUND"));
    try std.testing.expect(isRejectedPredicate("DESCRIPTION"));
    try std.testing.expect(!isRejectedPredicate("PREFERS"));
    try std.testing.expect(!isRejectedPredicate("DEPLOYS_TO"));
    try std.testing.expect(!isRejectedPredicate("BIRTHDAY"));
}

// ── Brain-leak Fix A — entity-name denylist at the write boundary ──────
// The #48 leak persisted system-prompt scaffold section titles + body terms
// (## Brain Architecture, ## Memory Link Types, "Working memory", "Layer 0",
// …) as brain ENTITIES. There is a predicate denylist (REJECTED_PREDICATES)
// but no entity-name denylist. `isRejectedEntityName` is the write-time gate;
// it delegates to the KEYSTONE `context_builder.isScaffoldEntityName` so the
// list cannot drift from the prompt scaffold that produces the leak.

test "brain-leak A: isRejectedEntityName rejects scaffold names (subject OR object surface forms)" {
    // Section titles (the leaked entities Confirmed in zaki_bot.memory_entities).
    try std.testing.expect(isRejectedEntityName("Brain Architecture"));
    try std.testing.expect(isRejectedEntityName("Memory Link Types"));
    try std.testing.expect(isRejectedEntityName("Response Protocol"));
    try std.testing.expect(isRejectedEntityName("Channel Attachments"));
    try std.testing.expect(isRejectedEntityName("Task Decomposition"));
    // Case-insensitive + whitespace-normalized (the leak arrives in varied casings).
    try std.testing.expect(isRejectedEntityName("brain architecture"));
    try std.testing.expect(isRejectedEntityName("  Memory   Link   Types "));
    // Scaffold-body terms.
    try std.testing.expect(isRejectedEntityName("Working memory"));
    try std.testing.expect(isRejectedEntityName("Distillation extraction"));
    try std.testing.expect(isRejectedEntityName("Layer 0"));
    try std.testing.expect(isRejectedEntityName("Auto-promoted"));
}

test "brain-leak A: isRejectedEntityName does NOT over-filter real entities" {
    // Genuine user facts must survive — don't poison recall by rejecting them.
    try std.testing.expect(!isRejectedEntityName("Helix"));
    try std.testing.expect(!isRejectedEntityName("dark mode"));
    try std.testing.expect(!isRejectedEntityName("Acme"));
    try std.testing.expect(!isRejectedEntityName("Cairo"));
    // Generic words deliberately NOT on the denylist (exact-match only).
    try std.testing.expect(!isRejectedEntityName("Safety"));
    try std.testing.expect(!isRejectedEntityName("Tools"));
    try std.testing.expect(!isRejectedEntityName("Safety team"));
    try std.testing.expect(!isRejectedEntityName(""));
}

test "P7 predicate fix: renamed speaker hub (USER_MENTIONED) rejected; relationships still flow" {
    // The renamed speaker-hub predicate gets its OWN dedicated blacklist entry
    // so the dense user→entity hub stays out of the graph (no mention-flood),
    // while the meta-narrative "MENTIONED" ban remains independent.
    try std.testing.expect(isRejectedPredicate("USER_MENTIONED"));
    try std.testing.expect(isRejectedPredicate("MENTIONED")); // meta-narrative ban intact
    // Genuine relationship predicates are NOT blacklisted — they must flow so
    // person nodes connect (Tarek WORKS_AT Acme, Jack REPORTS_TO Tarek, …).
    try std.testing.expect(!isRejectedPredicate("KNOWS"));
    try std.testing.expect(!isRejectedPredicate("WORKS_AT"));
    try std.testing.expect(!isRejectedPredicate("REPORTS_TO"));
}

test "P7 isSelfPseudoSubject: speaker/self terms vs named entities" {
    // Self/speaker pseudo-subjects map to the user:<id> hub, NOT a graph node.
    try std.testing.expect(isSelfPseudoSubject("user"));
    try std.testing.expect(isSelfPseudoSubject("User")); // case-insensitive
    try std.testing.expect(isSelfPseudoSubject("I"));
    try std.testing.expect(isSelfPseudoSubject("me"));
    try std.testing.expect(isSelfPseudoSubject("assistant"));
    // Named entities (people, orgs) are NOT self — they SHOULD become nodes.
    try std.testing.expect(!isSelfPseudoSubject("Tarek"));
    try std.testing.expect(!isSelfPseudoSubject("Jack"));
    try std.testing.expect(!isSelfPseudoSubject("Acme"));
    try std.testing.expect(!isSelfPseudoSubject("")); // empty is not self
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

test "V1.14.11: deriveExtractionKey is case-insensitive on subject (Captain Mochi fix)" {
    // The Captain Mochi investigation (2026-05-18) found that the agent's
    // memory_store path wrote subject="user" (lowercase) while the
    // session-end extraction batch wrote subject="User" (capitalized) for
    // the same logical fact. Pre-fix these produced TWO different
    // extracted_<hash> keys, allowing duplicate rows that the contradiction
    // judge then cleaned up — wasteful and alarming-looking in logs.
    //
    // Post-fix: same fact → same key regardless of subject casing.
    // Primary-key collision on re-extraction prevents the duplicate write.
    const allocator = std.testing.allocator;
    const k1 = try deriveExtractionKey(allocator, "user", "LIKES", "Thai food");
    defer allocator.free(k1);
    const k2 = try deriveExtractionKey(allocator, "User", "LIKES", "Thai food");
    defer allocator.free(k2);
    const k3 = try deriveExtractionKey(allocator, "USER", "LIKES", "Thai food");
    defer allocator.free(k3);
    try std.testing.expectEqualStrings(k1, k2);
    try std.testing.expectEqualStrings(k2, k3);
}

test "V1.14.11: deriveExtractionKey is case-insensitive on object" {
    // Same canonicalization applied to object — "Thai food" vs "thai food"
    // vs "THAI FOOD" must produce the same extraction key for the same
    // logical fact. Mirrors deriveEntityKey behavior at line 1019 for the
    // target-side entity hashing.
    const allocator = std.testing.allocator;
    const k1 = try deriveExtractionKey(allocator, "user", "LIKES", "Thai food");
    defer allocator.free(k1);
    const k2 = try deriveExtractionKey(allocator, "user", "LIKES", "thai food");
    defer allocator.free(k2);
    const k3 = try deriveExtractionKey(allocator, "user", "LIKES", "THAI FOOD");
    defer allocator.free(k3);
    try std.testing.expectEqualStrings(k1, k2);
    try std.testing.expectEqualStrings(k2, k3);
}

test "V1.14.11: deriveExtractionKey distinguishes different subjects (no collision)" {
    // Sanity: canonicalization MUST NOT collapse genuinely-different facts.
    // user LIKES Thai food MUST differ from cat LIKES Thai food and from
    // user LIKES Indian food (set-valued objects ARE different facts, the
    // R3-prereq prompt change made the JUDGE understand this — the KEY
    // derivation must agree).
    const allocator = std.testing.allocator;
    const ka = try deriveExtractionKey(allocator, "user", "LIKES", "Thai food");
    defer allocator.free(ka);
    const kb = try deriveExtractionKey(allocator, "cat", "LIKES", "Thai food");
    defer allocator.free(kb);
    const kc = try deriveExtractionKey(allocator, "user", "LIKES", "Indian food");
    defer allocator.free(kc);
    const kd = try deriveExtractionKey(allocator, "user", "USES", "Thai food");
    defer allocator.free(kd);
    try std.testing.expect(!std.mem.eql(u8, ka, kb)); // different subject
    try std.testing.expect(!std.mem.eql(u8, ka, kc)); // different object
    try std.testing.expect(!std.mem.eql(u8, ka, kd)); // different predicate
}

test "V1.14.12 (M3 review HIGH#2): deriveExtractionKey is case-INSENSITIVE on predicate" {
    // Per M3 reviewer HIGH#2: agent's memory_store may write predicate
    // in any case (LLMs occasionally lowercase) while boundary extractor
    // may emit a different case. Pre-fix the keys diverged and M3's
    // coverage filter MISSED the duplicate. Post-fix all casings produce
    // the same key, so coverage filter catches the dup regardless of
    // which writer used which casing.
    const allocator = std.testing.allocator;
    const k_upper = try deriveExtractionKey(allocator, "user", "LIKES", "Thai food");
    defer allocator.free(k_upper);
    const k_lower = try deriveExtractionKey(allocator, "user", "likes", "Thai food");
    defer allocator.free(k_lower);
    const k_mixed = try deriveExtractionKey(allocator, "user", "Likes", "Thai food");
    defer allocator.free(k_mixed);
    try std.testing.expectEqualStrings(k_upper, k_lower);
    try std.testing.expectEqualStrings(k_upper, k_mixed);
}

test "V1.14.12 (M1): WriteOrigin tags are stable strings for log analyzers" {
    // Per-path telemetry pipeline depends on stable enum string names
    // (grep on `memory.write.batch origin=X` in gateway logs feeds the
    // baseline_analyzer.py histogram builder). Renaming an enum value
    // breaks downstream analyzer scripts silently. Lock the wire format.
    try std.testing.expectEqualStrings("memory_store_tool", WriteOrigin.memory_store_tool.toSlice());
    try std.testing.expectEqualStrings("pass_a_drop", WriteOrigin.pass_a_drop.toSlice());
    try std.testing.expectEqualStrings("pass_c_compaction_extract", WriteOrigin.pass_c_compaction_extract.toSlice());
    try std.testing.expectEqualStrings("session_end_extract", WriteOrigin.session_end_extract.toSlice());
    try std.testing.expectEqualStrings("test_wire", WriteOrigin.test_wire.toSlice());
}

test "originToExtractionPass maps all expected origins" {
    try std.testing.expectEqualStrings("pass_a",      originToExtractionPass(.pass_a_drop));
    try std.testing.expectEqualStrings("pass_c",      originToExtractionPass(.pass_c_compaction_extract));
    try std.testing.expectEqualStrings("session_end", originToExtractionPass(.session_end_extract));
    try std.testing.expectEqualStrings("tool",        originToExtractionPass(.memory_store_tool));
    try std.testing.expectEqualStrings("test",        originToExtractionPass(.test_wire));
    try std.testing.expectEqualStrings("unknown",     originToExtractionPass(.unknown));
}

test "V1.14.12 (M1 + Path A): WriteOrigin enum count guards against silent additions" {
    // 6 variants: 4 production callsites + 1 test wire + 1 .unknown
    // defensive fallback. Path A deleted the 2 legacy-direct variants
    // (pass_c_compaction_direct, session_end_durable_fact) along with
    // their callers. If a NEW persistExtracted callsite is added without
    // updating this count, the test fails — forces a conscious decision
    // about tagging for telemetry.
    //
    // Hygiene audit 2026-05-19: all 4 production callsites verified to set
    // an explicit, distinct WriteOrigin (memory_store.zig:175,
    // compaction.zig:470 + 707, commands.zig:1452). The `.unknown` default
    // on ExtractionContext.write_origin is the M1 review HIGH#1 loud-signal
    // pattern — do NOT change to a production tag. A forgotten field must
    // surface as `.unknown` so it appears in the histogram as an outlier,
    // not silently inflate the session_end bucket.
    //
    // Parallel write path: entity_pipeline (daemon.zig:1227,
    // tools/wiki_link.zig:115) writes edges with attribution="wiki_link"
    // and predicates MENTIONS/MENTIONED. Distinct from extraction
    // (attribution="extraction_classifier") by metadata alone. Not a
    // hygiene gap — different schema layer (memory_edges, not memories).
    try std.testing.expectEqual(@as(usize, 6), @typeInfo(WriteOrigin).@"enum".fields.len);
}

test "content-hash helper matches the stored content_hash algorithm (SHA-256, 64 hex)" {
    const a = std.testing.allocator;
    const h = try computeContentHashHex(a, "user lives in Hamburg");
    defer a.free(h);
    // SHA-256 produces a 32-byte digest → 64 hex chars.
    try std.testing.expectEqual(@as(usize, 64), h.len);
    // Must match what zaki_state stores in the content_hash column.
    // zaki_state.computeContentHash is private, so replicate it here.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("user lives in Hamburg", &digest, .{});
    const want = try a.alloc(u8, 64);
    defer a.free(want);
    _ = security_secrets.hexEncode(&digest, want);
    try std.testing.expectEqualStrings(want, h);
}
