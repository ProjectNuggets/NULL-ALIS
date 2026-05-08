//! V1.12 — Wiki-link entity pipeline.
//!
//! Forward-flow connectivity layer. Every 3 turns (configurable) we run a
//! single LLM call that scans the recent turn pair(s) for entity mentions
//! (people, organizations, projects, products, places, events, concepts) and
//! materializes them as graph nodes + co-occurrence edges.
//!
//! ## Design contract
//!
//! Multilingual by construction. The extractor prompt asks the LLM to find
//! entities **regardless of source language**, preserving canonical forms in
//! their native script. No surface-form pattern matching anywhere — language
//! agnosticism is delegated to Kimi K2.6's multilingual understanding.
//!
//! ## Pipeline (per turn or batch)
//!
//! 1. **extractMentions** — single LLM call, JSON output of EntityMentions.
//! 2. **resolveEntity** — for each mention: cosine-match canonical form
//!    against `memory_entities` (Mem0 0.95 threshold), or upsert as new.
//!    Reuses `state_mgr.findEntityByCosine` + `state_mgr.upsertEntity`.
//! 3. **emitCooccurrenceEdges** — for every pair of resolved entities in
//!    the same turn, upsert a `MENTIONS` edge in `memory_edges`. The
//!    existing `upsertMemoryEdge` ON CONFLICT logic increments weight,
//!    so re-mentions accumulate evidence over time.
//! 4. **emitSpeakerEdges** — every entity mentioned by the user-side of
//!    the turn gets an edge from `user:<id>` → entity. Self-as-hub is
//!    emergent from this — the user node is touched by every turn.
//!
//! ## Reuse map
//!
//! - `memory_entities` table: zaki_state.zig:1320 (live, ivfflat-indexed)
//! - `findEntityByCosine`: zaki_state.zig:6832 (Mem0 cosine 0.95)
//! - `upsertEntity`: zaki_state.zig:6887 (ON CONFLICT name_lower)
//! - `upsertMemoryEdge`: zaki_state.zig:6506 (ON CONFLICT triple, weight++)
//! - `EntityRow`: memory/root.zig:533
//! - LLM call pattern: providers/root.zig::Provider.chat
//! - Embedding: memory/vector/embeddings.zig::EmbeddingProvider.embed
//!
//! ## Failure modes
//!
//! - LLM call fails → log + return empty (turn continues; no extraction this round)
//! - JSON parse fails → log + return empty (don't crash; extractor occasionally hallucinates non-JSON)
//! - Per-mention failures (embed / resolve / edge) → log per-mention, continue with others
//! - Entire pipeline is async to user reply; no failure here blocks the chat path

const std = @import("std");
const log = std.log.scoped(.entity_pipeline);

const providers = @import("../providers/root.zig");
const ChatMessage = providers.ChatMessage;
const ChatRequest = providers.ChatRequest;
const Provider = providers.Provider;

const memory_root = @import("../memory/root.zig");
const EntityRow = memory_root.EntityRow;

const zaki_state = @import("../zaki_state.zig");
const embeddings = @import("../memory/vector/embeddings.zig");

/// Minimum cosine similarity for an entity mention to coreference an
/// existing entity. Mirrors Mem0's 0.95 threshold (matches the existing
/// findEntityByCosine default). Below this we mint a new entity.
pub const COREF_THRESHOLD: f64 = 0.85;

/// Max entity mentions to extract per turn. V1.13 lifted from 24 → 40
/// after audit found long multi-entity turns (e.g. user pasting a CV or
/// a meeting agenda) were getting clipped. Bounds blast radius against
/// LLM hallucination floods while leaving real conversation headroom.
pub const MAX_MENTIONS_PER_TURN: usize = 40;

/// Co-occurrence edge predicate. Free-form TEXT in memory_edges schema —
/// no enum extension needed. Distinct from the typed predicates emitted
/// by extraction_persist (PREFERS, WORKS_AT, etc.) so the brain page can
/// render them with different visual weight.
pub const COOCCURS_PREDICATE: []const u8 = "MENTIONS";

/// Speaker-mention predicate. Connects user_id → entity for every entity
/// the user surfaced in a turn. By construction, the user node is the
/// densest hub in the graph (touched by every turn the user authors).
pub const SPEAKER_PREDICATE: []const u8 = "MENTIONED";

/// Attribution tag stamped on every edge written by this pipeline. Lets
/// the hygiene job + brain page distinguish wiki-link edges from
/// extraction_classifier edges.
pub const WIKI_LINK_ATTRIBUTION: []const u8 = "wiki_link";

/// One entity mention, as parsed from the LLM JSON output. Canonical is
/// the surface form normalized for matching (LLM proposes; cosine
/// resolution finalizes). Type is one of the seven categories the prompt
/// emits.
pub const EntityMention = struct {
    surface: []const u8, // exact text as it appeared in the turn
    canonical: []const u8, // normalized form for matching
    entity_type: []const u8, // PERSON | ORG | PROJECT | PRODUCT | PLACE | EVENT | CONCEPT
    confidence: f64,

    pub fn deinit(self: *const EntityMention, allocator: std.mem.Allocator) void {
        allocator.free(self.surface);
        allocator.free(self.canonical);
        allocator.free(self.entity_type);
    }
};

pub fn freeMentions(allocator: std.mem.Allocator, mentions: []EntityMention) void {
    for (mentions) |m| m.deinit(allocator);
    allocator.free(mentions);
}

/// One resolved entity — the result of cosine-matching a mention against
/// memory_entities (or minting a new row). `entity_id` is the stable key
/// used as the target_key in memory_edges.
pub const ResolvedEntity = struct {
    entity_id: []u8, // owned: caller frees
    canonical_name: []const u8, // borrowed from mention; do not free here
    was_existing: bool, // true if cosine-matched, false if newly minted

    pub fn deinit(self: *const ResolvedEntity, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_id);
    }
};

pub fn freeResolved(allocator: std.mem.Allocator, resolved: []ResolvedEntity) void {
    for (resolved) |r| r.deinit(allocator);
    allocator.free(resolved);
}

/// Pipeline run statistics — emitted as a structured log line at end of
/// run, and returnable to callers (the wiki_link tool surfaces these to
/// the agent so it can report to the user).
///
/// REVIEW ME-03 fix (2026-05-08): outcome distinguishes the three
/// possible "no edges" terminal states so callers can tell:
///   - `.ok`: pipeline ran cleanly (may have 0 mentions if turn was
///     genuinely entity-free, e.g. "hi", "thanks")
///   - `.llm_failed`: LLM call errored (network / timeout / provider) —
///     no mentions because we never got a response
///   - `.parse_failed`: LLM responded but JSON was unparseable — the
///     model returned non-JSON or malformed output
/// Without this, `mentions=0` conflates "user said hi" with "the LLM
/// crashed", violating the no-silent-fallback policy from .planning/.
pub const RunOutcome = enum { ok, llm_failed, parse_failed };

pub const RunStats = struct {
    outcome: RunOutcome = .ok,
    mentions_extracted: usize = 0,
    entities_resolved: usize = 0,
    entities_minted: usize = 0,
    edges_emitted: usize = 0,
    /// REVIEW ME-01 fix: now assigned. Counts edge upserts that returned
    /// an error from upsertMemoryEdge (logged + skipped per failure-soft
    /// contract). Distinct from `failed_mentions` (resolve-time failures).
    edges_skipped: usize = 0,
    llm_latency_ms: i64 = 0,
    failed_mentions: usize = 0,
};

// ─────────────────────────────────────────────────────────────────────────
// Extractor prompt
// ─────────────────────────────────────────────────────────────────────────

/// System prompt for the entity-mention extractor. Multilingual by design
/// — examples include English, Arabic, Spanish, French, Mandarin to
/// signal the LLM to handle any language. NO pronoun lists. NO language
/// detection. The LLM identifies entities semantically.
pub const wiki_link_system =
    \\You are an entity mention extractor. Your job: find named entities mentioned in a conversation turn and return them as structured JSON.
    \\
    \\WHAT TO EXTRACT:
    \\- People (named individuals, e.g., "Alfred", "Mia", "أحمد", "李明")
    \\- Organizations (named companies, teams, brands, e.g., "Google", "KPMG", "스타벅스")
    \\- Projects, products, tools (named software, services, e.g., "nullALIS", "Figma", "Helix")
    \\- Places (named cities, countries, locations, e.g., "Riyadh", "東京", "São Paulo")
    \\- Events (named occasions, holidays, meetings, e.g., "Web Summit", "عيد الفطر", "MWC 2026")
    \\- Concepts (named ideas, frameworks, technologies, e.g., "RAG", "Web3", "JEPA")
    \\
    \\WHAT NOT TO EXTRACT:
    \\- Pronouns in any language (I, me, you, he, she, it, they, them, ana, yo, je, wo, etc.)
    \\- Generic nouns (a person, the project, the company, my dog, his car)
    \\- Common words used in their everyday sense (coffee, food, work)
    \\- Throwaway mentions ("I had some coffee" — coffee is generic; "Ethiopian Yirgacheffe" — that's a named product)
    \\
    \\MULTILINGUAL: Work in any language. Extract entities regardless of source language. Preserve the canonical form in its native script — do not transliterate Arabic names into Latin or Chinese names into Pinyin unless the entity is canonically known by that romanization. The cosine resolver downstream handles cross-script variants.
    \\
    \\OUTPUT FORMAT: A JSON array of objects, NOTHING ELSE. No prose. No explanation. If no entities found, return [].
    \\
    \\Schema (each object):
    \\{
    \\  "surface": "<exact text as it appeared in the turn>",
    \\  "canonical": "<canonical form for matching, normalized — strip honorifics, fix obvious case, expand common abbreviations>",
    \\  "type": "PERSON" | "ORG" | "PROJECT" | "PRODUCT" | "PLACE" | "EVENT" | "CONCEPT",
    \\  "confidence": <number 0.0-1.0>
    \\}
    \\
    \\Examples:
    \\Turn: "I had coffee with Alfred at Starbucks yesterday."
    \\Output: [{"surface":"Alfred","canonical":"Alfred","type":"PERSON","confidence":0.95},{"surface":"Starbucks","canonical":"Starbucks","type":"ORG","confidence":0.95}]
    \\
    \\Turn: "شفت ألفريد في ستاربكس امبارح" (Arabic for: I saw Alfred at Starbucks yesterday)
    \\Output: [{"surface":"ألفريد","canonical":"ألفريد","type":"PERSON","confidence":0.95},{"surface":"ستاربكس","canonical":"ستاربكس","type":"ORG","confidence":0.95}]
    \\
    \\Turn: "Trabajo en nullALIS con el equipo de Neptune."
    \\Output: [{"surface":"nullALIS","canonical":"nullALIS","type":"PROJECT","confidence":0.98},{"surface":"Neptune","canonical":"Neptune","type":"PROJECT","confidence":0.85}]
    \\
    \\Turn: "hi"
    \\Output: []
    \\
    \\Turn: "thanks!"
    \\Output: []
    \\
    \\Turn: "我和李明在北京的Google开会" (Mandarin: I had a meeting with Li Ming at Google in Beijing)
    \\Output: [{"surface":"李明","canonical":"李明","type":"PERSON","confidence":0.95},{"surface":"北京","canonical":"北京","type":"PLACE","confidence":0.97},{"surface":"Google","canonical":"Google","type":"ORG","confidence":0.99}]
;

// ─────────────────────────────────────────────────────────────────────────
// JSON parser (defensive — LLMs are inconsistent)
// ─────────────────────────────────────────────────────────────────────────

/// Parse the LLM JSON output into EntityMention slice. Defensive parsing
/// — the prompt asks for a bare JSON array, but LLMs occasionally wrap
/// in code fences or prefix prose. We strip wrappers, then parse.
///
/// Returns owned slice. Caller must `freeMentions`.
pub fn parseMentionsJson(allocator: std.mem.Allocator, raw: []const u8) ![]EntityMention {
    const trimmed = trimJsonWrapper(raw);
    if (trimmed.len == 0) return allocator.alloc(EntityMention, 0);
    if (std.mem.eql(u8, trimmed, "[]")) return allocator.alloc(EntityMention, 0);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch |err| {
        log.warn("entity_pipeline: JSON parse failed err={s} raw_len={d}", .{ @errorName(err), raw.len });
        return allocator.alloc(EntityMention, 0);
    };
    defer parsed.deinit();

    if (parsed.value != .array) {
        log.warn("entity_pipeline: top-level not an array (got {s})", .{@tagName(parsed.value)});
        return allocator.alloc(EntityMention, 0);
    }

    var out: std.ArrayListUnmanaged(EntityMention) = .{};
    errdefer {
        for (out.items) |m| m.deinit(allocator);
        out.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (out.items.len >= MAX_MENTIONS_PER_TURN) break;
        if (item != .object) continue;
        const obj = item.object;

        const surface_v = obj.get("surface") orelse continue;
        const canonical_v = obj.get("canonical") orelse continue;
        const type_v = obj.get("type") orelse continue;

        if (surface_v != .string or canonical_v != .string or type_v != .string) continue;

        const surface = surface_v.string;
        const canonical = canonical_v.string;
        const entity_type = type_v.string;

        // Reject obvious junk: empty strings, mentions over 200 chars (entity
        // names are short), and types not in our enum.
        if (surface.len == 0 or surface.len > 200) continue;
        if (canonical.len == 0 or canonical.len > 200) continue;
        if (!isValidEntityType(entity_type)) continue;

        // Reject pronoun-shaped surfaces in any common language as a
        // defensive backstop — the prompt says "no pronouns" but cheap
        // models occasionally slip. This is NOT a primary defense; the
        // semantic gate is the LLM. Just a bounded sanity filter.
        if (looksLikePronoun(canonical)) continue;

        const conf: f64 = blk: {
            const cv = obj.get("confidence") orelse break :blk 0.7;
            switch (cv) {
                .float => |f| break :blk std.math.clamp(f, 0.0, 1.0),
                .integer => |i| break :blk std.math.clamp(@as(f64, @floatFromInt(i)), 0.0, 1.0),
                else => break :blk 0.7,
            }
        };

        // REVIEW ME-02 fix (2026-05-08): the previous struct-literal
        // form leaked already-duped strings if a later dupe in the
        // same literal failed mid-construction (e.g. surface+canonical
        // duped, then OOM on entity_type → both prior dupes leaked
        // because the struct never reached the errdefer scope).
        // Fix: dupe each field into a local first, then build the
        // struct as the final non-failing step.
        const surface_owned = try allocator.dupe(u8, surface);
        errdefer allocator.free(surface_owned);
        const canonical_owned = try allocator.dupe(u8, canonical);
        errdefer allocator.free(canonical_owned);
        const type_owned = try allocator.dupe(u8, entity_type);
        errdefer allocator.free(type_owned);

        try out.append(allocator, .{
            .surface = surface_owned,
            .canonical = canonical_owned,
            .entity_type = type_owned,
            .confidence = conf,
        });
    }

    return try out.toOwnedSlice(allocator);
}

fn trimJsonWrapper(raw: []const u8) []const u8 {
    // Strip whitespace
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return s;

    // Strip ```json ... ``` or ``` ... ``` code fences if present
    if (std.mem.startsWith(u8, s, "```")) {
        // Find end of opening fence line
        const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
        s = s[nl + 1 ..];
        // Strip trailing fence
        if (std.mem.endsWith(u8, s, "```")) s = s[0 .. s.len - 3];
        s = std.mem.trim(u8, s, " \t\r\n");
    }

    // Find first '[' (the LLM may have prefixed prose like "Here's the JSON:")
    const start = std.mem.indexOfScalar(u8, s, '[') orelse return s;
    const end = std.mem.lastIndexOfScalar(u8, s, ']') orelse return s;
    if (end <= start) return s;
    return s[start .. end + 1];
}

fn isValidEntityType(t: []const u8) bool {
    return std.mem.eql(u8, t, "PERSON") or
        std.mem.eql(u8, t, "ORG") or
        std.mem.eql(u8, t, "PROJECT") or
        std.mem.eql(u8, t, "PRODUCT") or
        std.mem.eql(u8, t, "PLACE") or
        std.mem.eql(u8, t, "EVENT") or
        std.mem.eql(u8, t, "CONCEPT");
}

/// Defensive backstop — reject pronoun-shaped canonicals. NOT a primary
/// defense (the LLM prompt is the semantic gate). Just guards against
/// LLM slippage. Bounded to common pronouns in tier-1 languages.
///
/// REVIEW HI-02 fix (2026-05-08): the pronoun list was kept ASCII-only
/// because `std.ascii.toLower` no-ops above 0x7F (silently passes
/// "Él"/"ÉL" through unchanged, defeating the case-fold). For non-ASCII
/// pronouns we compare both the surface form and a manually-folded
/// uppercase variant. Removed bogus entries `"yo,"` and `"tu,"` that
/// had literal trailing commas (typo in initial implementation —
/// could never match anything).
fn looksLikePronoun(s: []const u8) bool {
    if (s.len == 0 or s.len > 6) return false;

    // ASCII-only fast path: lowercase via std.ascii then compare.
    var ascii_only = true;
    for (s) |ch| {
        if (ch > 0x7F) {
            ascii_only = false;
            break;
        }
    }
    if (ascii_only) {
        var buf: [8]u8 = undefined;
        if (s.len > buf.len) return false;
        for (s, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        const lower = buf[0..s.len];
        const ascii_tokens = [_][]const u8{
            "i",  "me",  "you",  "he",  "she", "it",  "we", "they",
            "us", "him", "her",  "yo",  "tu",  "je",  "wo", "ni",
            "ta", "ja",  "anche","mim", "ona", "esa",
        };
        for (ascii_tokens) |t| if (std.mem.eql(u8, lower, t)) return true;
        return false;
    }

    // Non-ASCII path: exact-form compare against both lower and upper
    // variants of common pronouns. We keep this list short — the
    // semantic gate is the LLM, not this backstop.
    const utf8_tokens = [_][]const u8{
        // Spanish/French/Portuguese with diacritics
        "él",  "Él",
        "tú",  "Tú",
        "à",   "À",
        "ô",   "Ô",
        // Arabic pronouns (commonly slipped by LLMs)
        "أنا", "نحن", "هو",  "هي",  "هم",
        // Mandarin (already short)
        "我",  "你",  "他",  "她",  "它",  "我们",
        // Hindi
        "मैं",
    };
    for (utf8_tokens) |t| if (std.mem.eql(u8, s, t)) return true;
    return false;
}

// ─────────────────────────────────────────────────────────────────────────
// LLM call
// ─────────────────────────────────────────────────────────────────────────

/// REVIEW ME-03 fix: extractMentions now returns an outcome alongside
/// the slice so callers can distinguish LLM failure / parse failure
/// from "genuinely no entities."
pub const ExtractResult = struct {
    mentions: []EntityMention,
    outcome: RunOutcome,
    llm_latency_ms: i64,

    pub fn deinit(self: *const ExtractResult, allocator: std.mem.Allocator) void {
        freeMentions(allocator, self.mentions);
    }
};

/// Run the wiki-link extractor LLM over a turn's text. Returns owned
/// EntityMention slice + outcome. Caller must deinit on the result.
///
/// `turn_text` should be the user message + assistant reply concatenated,
/// or a multi-turn batch — the prompt handles either. Length-cap the
/// input at ~4KB to bound prompt cost.
pub fn extractMentions(
    allocator: std.mem.Allocator,
    provider: Provider,
    model_name: []const u8,
    turn_text: []const u8,
    timeout_secs: u32,
) !ExtractResult {
    // V1.13 lifted 4KB → 16KB. Kimi K2.6 has 256K context window; the
    // prior 4KB cap was a pre-Kimi bottleneck that made the extractor
    // see only the most recent fragment of a multi-turn pair. With 16KB
    // the extractor sees the full last 4-6 turns including assistant
    // replies, which improves entity disambiguation (especially when
    // the same entity is discussed across multiple turns).
    const MAX_INPUT_BYTES: usize = 16 * 1024;
    const truncated = if (turn_text.len > MAX_INPUT_BYTES)
        turn_text[0..MAX_INPUT_BYTES]
    else
        turn_text;

    const user_msg = try std.fmt.allocPrint(
        allocator,
        "Extract entity mentions from this conversation turn. Return JSON array only.\n\n---\n{s}\n---",
        .{truncated},
    );
    defer allocator.free(user_msg);

    var msgs: [2]ChatMessage = .{
        .{ .role = .system, .content = wiki_link_system },
        .{ .role = .user, .content = user_msg },
    };

    const t_start = std.time.milliTimestamp();
    const resp = provider.chat(
        allocator,
        .{
            .messages = msgs[0..],
            .model = model_name,
            .temperature = 0.1, // low temperature → deterministic extraction
            .tools = null,
            .timeout_secs = timeout_secs,
        },
        model_name,
        0.1,
    ) catch |err| {
        const elapsed = std.time.milliTimestamp() - t_start;
        log.warn("entity_pipeline: LLM call failed err={s} latency_ms={d}", .{ @errorName(err), elapsed });
        // ME-03: explicit outcome instead of empty-mentions silence.
        return ExtractResult{
            .mentions = try allocator.alloc(EntityMention, 0),
            .outcome = .llm_failed,
            .llm_latency_ms = elapsed,
        };
    };
    const t_end = std.time.milliTimestamp();

    // Free response heap-allocated fields after we extract content.
    defer {
        if (resp.content) |cc| if (cc.len > 0) allocator.free(cc);
        if (resp.model.len > 0) allocator.free(resp.model);
        if (resp.reasoning_content) |rc| if (rc.len > 0) allocator.free(rc);
        for (resp.tool_calls) |tc| {
            if (tc.id.len > 0) allocator.free(tc.id);
            if (tc.name.len > 0) allocator.free(tc.name);
            if (tc.arguments.len > 0) allocator.free(tc.arguments);
        }
        if (resp.tool_calls.len > 0) allocator.free(resp.tool_calls);
    }

    const raw = resp.contentOrEmpty();
    const mentions = parseMentionsJson(allocator, raw) catch |err| {
        log.warn("entity_pipeline: parse failed err={s} raw_len={d}", .{ @errorName(err), raw.len });
        return ExtractResult{
            .mentions = try allocator.alloc(EntityMention, 0),
            .outcome = .parse_failed,
            .llm_latency_ms = t_end - t_start,
        };
    };

    log.info("entity_pipeline.extract count={d} latency_ms={d} raw_len={d}", .{
        mentions.len,
        t_end - t_start,
        raw.len,
    });
    return ExtractResult{
        .mentions = mentions,
        .outcome = .ok,
        .llm_latency_ms = t_end - t_start,
    };
}

// ─────────────────────────────────────────────────────────────────────────
// Entity resolution + edge emission
// ─────────────────────────────────────────────────────────────────────────

/// Resolve a single mention to an entity_id. Cosine-match the canonical
/// form against memory_entities; if no match >= COREF_THRESHOLD, mint a
/// new entity row.
///
/// Reuses zaki_state.findEntityByCosine + zaki_state.upsertEntity. The
/// embedder is required (to generate the cosine vector).
///
/// Returns owned ResolvedEntity. Caller must deinit.
pub fn resolveEntity(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    embedder: embeddings.EmbeddingProvider,
    user_id: i64,
    mention: *const EntityMention,
) !ResolvedEntity {
    // Embed canonical name (small text, fast call). Fail-soft: if embed
    // fails, skip this mention (caller filters out empty entity_id).
    const emb = try embedder.embed(allocator, mention.canonical);
    defer allocator.free(emb);

    // Try cosine match against existing entities for this user.
    if (try state_mgr.findEntityByCosine(allocator, user_id, emb, COREF_THRESHOLD)) |existing| {
        defer existing.deinit(allocator);
        const id_copy = try allocator.dupe(u8, existing.id);
        return .{
            .entity_id = id_copy,
            .canonical_name = mention.canonical,
            .was_existing = true,
        };
    }

    // No cosine match — mint new entity.
    const new_id = try state_mgr.upsertEntity(allocator, user_id, mention.canonical, emb);
    return .{
        .entity_id = new_id,
        .canonical_name = mention.canonical,
        .was_existing = false,
    };
}

/// Emit-result tuple — distinguishes successful upserts from skips
/// (REVIEW ME-01 fix: now we surface both counts to the caller).
pub const EmitResult = struct {
    emitted: usize = 0,
    skipped: usize = 0,
};

/// Emit COOCCURS edges for every pair of entities in the same turn.
/// Reuses zaki_state.upsertMemoryEdge — its ON CONFLICT logic increments
/// `weight` on duplicate triples, so re-mentions accumulate.
///
/// Edges are bidirectional in the conceptual model — we write the lex-
/// smallest direction to deduplicate (A→B and B→A become a single row).
pub fn emitCooccurrenceEdges(
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    resolved: []const ResolvedEntity,
    confidence: f64,
) !EmitResult {
    if (resolved.len < 2) return EmitResult{};

    var result = EmitResult{};
    for (resolved, 0..) |a, i| {
        if (a.entity_id.len == 0) continue;
        for (resolved[i + 1 ..]) |b| {
            if (b.entity_id.len == 0) continue;
            // Skip self-edges (same entity mentioned twice in turn)
            if (std.mem.eql(u8, a.entity_id, b.entity_id)) continue;

            // Lex-smallest first to dedupe direction.
            const src_id = if (std.mem.order(u8, a.entity_id, b.entity_id) == .lt) a.entity_id else b.entity_id;
            const tgt_id = if (std.mem.order(u8, a.entity_id, b.entity_id) == .lt) b.entity_id else a.entity_id;

            // V1.14 — emit a synthesized "fact" sentence for the
            // co-occurrence edge so brain page rendering becomes
            // scannable. Format: "<a.canonical_name> co-occurred with
            // <b.canonical_name> in this conversation". No temporal
            // anchor (co-occurrence is contextual, not time-anchored);
            // no episode key (entity_pipeline runs on prose snapshots
            // not memory rows — the memory key isn't in scope here).
            const fact_buf = std.fmt.allocPrint(
                std.heap.page_allocator,
                "{s} co-occurred with {s} in conversation",
                .{ a.canonical_name, b.canonical_name },
            ) catch null;
            defer if (fact_buf) |b_| std.heap.page_allocator.free(b_);

            state_mgr.upsertMemoryEdgeRich(
                user_id,
                src_id,
                tgt_id,
                COOCCURS_PREDICATE,
                WIKI_LINK_ATTRIBUTION,
                confidence,
                fact_buf,
                null, // co-occurrence has no temporal anchor
                null, // no episode key in this scope (V1.15 follow-up)
            ) catch |err| {
                log.warn("entity_pipeline: edge emit failed err={s} src={s} tgt={s}", .{
                    @errorName(err), src_id, tgt_id,
                });
                result.skipped += 1;
                continue;
            };
            result.emitted += 1;
        }
    }
    return result;
}

/// Emit speaker → entity edges. The user node is the synthetic key
/// `user:<user_id>` — this is the densest hub by construction (every
/// turn the user speaks touches it).
pub fn emitSpeakerEdges(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    resolved: []const ResolvedEntity,
    confidence: f64,
) !EmitResult {
    if (resolved.len == 0) return EmitResult{};

    const speaker_key = try std.fmt.allocPrint(allocator, "user:{d}", .{user_id});
    defer allocator.free(speaker_key);

    var result = EmitResult{};
    for (resolved) |r| {
        if (r.entity_id.len == 0) continue;
        // V1.14 — synthesize a "user mentioned X" fact for the speaker
        // edge so the brain page can render it scannably.
        const fact_buf = std.fmt.allocPrint(
            allocator,
            "user mentioned {s}",
            .{r.canonical_name},
        ) catch null;
        defer if (fact_buf) |b_| allocator.free(b_);

        state_mgr.upsertMemoryEdgeRich(
            user_id,
            speaker_key,
            r.entity_id,
            SPEAKER_PREDICATE,
            WIKI_LINK_ATTRIBUTION,
            confidence,
            fact_buf,
            null,
            null,
        ) catch |err| {
            log.warn("entity_pipeline: speaker edge failed err={s} entity={s}", .{
                @errorName(err), r.entity_id,
            });
            result.skipped += 1;
            continue;
        };
        result.emitted += 1;
    }
    return result;
}

// ─────────────────────────────────────────────────────────────────────────
// Orchestrator
// ─────────────────────────────────────────────────────────────────────────

/// End-to-end pipeline: extract → resolve → emit edges. Single entry
/// point for callers (per-3-turn trigger, session-end pass, Pass C
/// extension, user-invoked button, admin CLI).
///
/// Returns RunStats. All errors are non-fatal (logged); stats reflect
/// what actually happened.
pub fn runOnTurn(
    allocator: std.mem.Allocator,
    provider: Provider,
    model_name: []const u8,
    state_mgr: *zaki_state.Manager,
    embedder: embeddings.EmbeddingProvider,
    user_id: i64,
    turn_text: []const u8,
    timeout_secs: u32,
) RunStats {
    var stats = RunStats{};
    if (turn_text.len < 8) return stats; // skip trivial turns

    const extract_result = extractMentions(
        allocator,
        provider,
        model_name,
        turn_text,
        timeout_secs,
    ) catch |err| {
        log.warn("entity_pipeline.runOnTurn: extract OOM err={s}", .{@errorName(err)});
        stats.outcome = .llm_failed;
        return stats;
    };
    defer extract_result.deinit(allocator);

    stats.outcome = extract_result.outcome;
    stats.llm_latency_ms = extract_result.llm_latency_ms;
    stats.mentions_extracted = extract_result.mentions.len;
    const mentions = extract_result.mentions;

    if (mentions.len == 0) return stats;

    var resolved_list: std.ArrayListUnmanaged(ResolvedEntity) = .{};
    defer {
        for (resolved_list.items) |r| r.deinit(allocator);
        resolved_list.deinit(allocator);
    }

    for (mentions) |*m| {
        const r = resolveEntity(allocator, state_mgr, embedder, user_id, m) catch |err| {
            log.warn("entity_pipeline.runOnTurn: resolve failed err={s} canonical={s}", .{
                @errorName(err), m.canonical,
            });
            stats.failed_mentions += 1;
            continue;
        };
        if (r.was_existing) stats.entities_resolved += 1 else stats.entities_minted += 1;
        resolved_list.append(allocator, r) catch |err| {
            log.warn("entity_pipeline.runOnTurn: append failed err={s}", .{@errorName(err)});
            stats.failed_mentions += 1;
            r.deinit(allocator); // free entity_id immediately on OOM (LO-01 fix)
            continue;
        };
    }

    // Average confidence across mentions for edge weighting.
    var avg_conf: f64 = 0.0;
    if (mentions.len > 0) {
        var sum: f64 = 0.0;
        for (mentions) |m| sum += m.confidence;
        avg_conf = sum / @as(f64, @floatFromInt(mentions.len));
    }

    const cooccur = emitCooccurrenceEdges(
        state_mgr,
        user_id,
        resolved_list.items,
        avg_conf,
    ) catch |err| blk: {
        log.warn("entity_pipeline.runOnTurn: cooccur edges failed err={s}", .{@errorName(err)});
        break :blk EmitResult{};
    };
    const speaker = emitSpeakerEdges(
        allocator,
        state_mgr,
        user_id,
        resolved_list.items,
        avg_conf,
    ) catch |err| blk: {
        log.warn("entity_pipeline.runOnTurn: speaker edges failed err={s}", .{@errorName(err)});
        break :blk EmitResult{};
    };
    stats.edges_emitted = cooccur.emitted + speaker.emitted;
    stats.edges_skipped = cooccur.skipped + speaker.skipped;

    log.info(
        "entity_pipeline.runOnTurn user={d} outcome={s} mentions={d} resolved={d} minted={d} edges={d} skipped={d} failed={d} llm_ms={d}",
        .{
            user_id,
            @tagName(stats.outcome),
            stats.mentions_extracted,
            stats.entities_resolved,
            stats.entities_minted,
            stats.edges_emitted,
            stats.edges_skipped,
            stats.failed_mentions,
            stats.llm_latency_ms,
        },
    );
    return stats;
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

test "parseMentionsJson — empty array" {
    const allocator = std.testing.allocator;
    const out = try parseMentionsJson(allocator, "[]");
    defer freeMentions(allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "parseMentionsJson — single English entity" {
    const allocator = std.testing.allocator;
    const raw =
        \\[{"surface":"Alfred","canonical":"Alfred","type":"PERSON","confidence":0.95}]
    ;
    const out = try parseMentionsJson(allocator, raw);
    defer freeMentions(allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("Alfred", out[0].surface);
    try std.testing.expectEqualStrings("Alfred", out[0].canonical);
    try std.testing.expectEqualStrings("PERSON", out[0].entity_type);
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), out[0].confidence, 0.001);
}

test "parseMentionsJson — Arabic entity" {
    const allocator = std.testing.allocator;
    const raw =
        \\[{"surface":"ألفريد","canonical":"ألفريد","type":"PERSON","confidence":0.9}]
    ;
    const out = try parseMentionsJson(allocator, raw);
    defer freeMentions(allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("ألفريد", out[0].canonical);
}

test "parseMentionsJson — Mandarin + Latin mixed" {
    const allocator = std.testing.allocator;
    const raw =
        \\[{"surface":"李明","canonical":"李明","type":"PERSON","confidence":0.95},
        \\ {"surface":"Google","canonical":"Google","type":"ORG","confidence":0.99}]
    ;
    const out = try parseMentionsJson(allocator, raw);
    defer freeMentions(allocator, out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("李明", out[0].canonical);
    try std.testing.expectEqualStrings("Google", out[1].canonical);
}

test "parseMentionsJson — strips code fences" {
    const allocator = std.testing.allocator;
    const raw =
        \\```json
        \\[{"surface":"X","canonical":"X","type":"PERSON","confidence":0.8}]
        \\```
    ;
    const out = try parseMentionsJson(allocator, raw);
    defer freeMentions(allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "parseMentionsJson — strips prose prefix" {
    const allocator = std.testing.allocator;
    const raw =
        \\Here's the JSON:
        \\[{"surface":"X","canonical":"X","type":"PERSON","confidence":0.8}]
    ;
    const out = try parseMentionsJson(allocator, raw);
    defer freeMentions(allocator, out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
}

test "parseMentionsJson — rejects invalid type" {
    const allocator = std.testing.allocator;
    const raw =
        \\[{"surface":"X","canonical":"X","type":"INVALID","confidence":0.8}]
    ;
    const out = try parseMentionsJson(allocator, raw);
    defer freeMentions(allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "parseMentionsJson — rejects pronoun-shaped canonical (defensive)" {
    const allocator = std.testing.allocator;
    const raw =
        \\[{"surface":"I","canonical":"I","type":"PERSON","confidence":0.8},
        \\ {"surface":"yo","canonical":"yo","type":"PERSON","confidence":0.8}]
    ;
    const out = try parseMentionsJson(allocator, raw);
    defer freeMentions(allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "parseMentionsJson — rejects empty surface" {
    const allocator = std.testing.allocator;
    const raw =
        \\[{"surface":"","canonical":"X","type":"PERSON","confidence":0.8}]
    ;
    const out = try parseMentionsJson(allocator, raw);
    defer freeMentions(allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "parseMentionsJson — caps mentions per turn" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');
    var i: usize = 0;
    while (i < MAX_MENTIONS_PER_TURN + 5) : (i += 1) {
        if (i > 0) try buf.append(allocator, ',');
        const w = buf.writer(allocator);
        try w.print("{{\"surface\":\"E{d}\",\"canonical\":\"E{d}\",\"type\":\"CONCEPT\",\"confidence\":0.9}}", .{ i, i });
    }
    try buf.append(allocator, ']');
    const out = try parseMentionsJson(allocator, buf.items);
    defer freeMentions(allocator, out);
    try std.testing.expectEqual(MAX_MENTIONS_PER_TURN, out.len);
}

test "parseMentionsJson — handles non-array gracefully" {
    const allocator = std.testing.allocator;
    const raw = "{\"not\":\"an array\"}";
    const out = try parseMentionsJson(allocator, raw);
    defer freeMentions(allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "parseMentionsJson — handles malformed JSON gracefully" {
    const allocator = std.testing.allocator;
    const raw = "[not valid";
    const out = try parseMentionsJson(allocator, raw);
    defer freeMentions(allocator, out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "isValidEntityType — all canonical types" {
    try std.testing.expect(isValidEntityType("PERSON"));
    try std.testing.expect(isValidEntityType("ORG"));
    try std.testing.expect(isValidEntityType("PROJECT"));
    try std.testing.expect(isValidEntityType("PRODUCT"));
    try std.testing.expect(isValidEntityType("PLACE"));
    try std.testing.expect(isValidEntityType("EVENT"));
    try std.testing.expect(isValidEntityType("CONCEPT"));
    try std.testing.expect(!isValidEntityType("PERSO"));
    try std.testing.expect(!isValidEntityType("person"));
    try std.testing.expect(!isValidEntityType(""));
}

test "looksLikePronoun — common forms" {
    try std.testing.expect(looksLikePronoun("I"));
    try std.testing.expect(looksLikePronoun("me"));
    try std.testing.expect(looksLikePronoun("YOU"));
    try std.testing.expect(looksLikePronoun("yo"));
    try std.testing.expect(looksLikePronoun("je"));
    try std.testing.expect(looksLikePronoun("wo"));
    try std.testing.expect(!looksLikePronoun("Alfred"));
    try std.testing.expect(!looksLikePronoun("ألفريد"));
    try std.testing.expect(!looksLikePronoun("Microsoft"));
}

test "trimJsonWrapper — bare array passes through" {
    const out = trimJsonWrapper("[]");
    try std.testing.expectEqualStrings("[]", out);
}

test "trimJsonWrapper — strips fences with json hint" {
    const raw =
        \\```json
        \\[{"a":1}]
        \\```
    ;
    const out = trimJsonWrapper(raw);
    try std.testing.expectEqualStrings("[{\"a\":1}]", out);
}

test "trimJsonWrapper — finds array inside prose" {
    const out = trimJsonWrapper("here it is: [\"a\",\"b\"] thanks!");
    try std.testing.expectEqualStrings("[\"a\",\"b\"]", out);
}
