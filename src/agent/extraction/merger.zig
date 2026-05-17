//! V1.14.9 — Episode result merger with entity coref + structural dedup.
//!
//! The runner fans out one extraction call per episode (chunker.zig).
//! Each call returns its own ExtractionResult — entities + edges from
//! one coherent slice. This module folds N per-episode results into
//! ONE merged ExtractionResult ready for persistExtracted.
//!
//! Two layers of dedup:
//!   1. Entity coref — same entity may appear in multiple episodes
//!      under slightly different surface forms ("John" / "John Smith"
//!      / "john"). When an EntityResolution embed provider is
//!      available, we use cosine-similarity coref (matches the
//!      existing extraction_persist 0.95 Mem0 threshold). Without an
//!      embed provider we fall back to case-insensitive exact match.
//!   2. Structural edge dedup — after entities are canonicalized,
//!      duplicate (source, predicate, target) triples across episodes
//!      collapse to one. The downstream persistExtracted layer still
//!      runs MD5 + semantic-judge dedup on the merged result, so
//!      paraphrases of the same fact get caught there.
//!
//! Failure isolation: caller may pass `?ExtractionResult` per episode
//! (null = that episode's LLM call failed). Nulls are skipped without
//! aborting the merge — partial signal beats no signal.

const std = @import("std");
const log = std.log.scoped(.extraction_merger);
const schema = @import("schema.zig");
const memory_embeddings = @import("../../memory/vector/embeddings.zig");

const Entity = schema.Entity;
const Edge = schema.Edge;
const ExtractionResult = schema.ExtractionResult;

/// Coref settings. When `embed_provider` is null, fall back to
/// case-insensitive name match (cheap, no LLM call per merge).
pub const CorefCtx = struct {
    embed_provider: ?memory_embeddings.EmbeddingProvider = null,
    /// Cosine similarity threshold above which two entity names are
    /// considered coreferent. 0.95 = Mem0 / extraction_persist
    /// canonical default.
    threshold: f64 = 0.95,
};

/// Merge per-episode ExtractionResults into one. Caller owns the
/// returned ExtractionResult and must call `deinit(allocator)`.
///
/// `episode_results` may contain nulls (failed episodes). Nulls are
/// skipped silently. Returns an empty (but allocated) ExtractionResult
/// when all episodes are null or all empty — never returns null
/// itself so callers don't have to handle the no-signal case.
pub fn mergeEpisodeResults(
    allocator: std.mem.Allocator,
    episode_results: []const ?ExtractionResult,
    coref: ?CorefCtx,
) !ExtractionResult {
    // Count entities + edges so we can pre-size buffers.
    var total_entities: usize = 0;
    var total_edges: usize = 0;
    for (episode_results) |opt| {
        if (opt) |er| {
            total_entities += er.entities.len;
            total_edges += er.edges.len;
        }
    }

    if (total_entities == 0 and total_edges == 0) {
        return ExtractionResult.empty(allocator);
    }

    // Phase 1 — canonicalize entity names.
    // canonical_map: raw_name -> canonical_name (raw_name owned by us;
    //   canonical_name is a borrow into canonical_entities).
    // canonical_entities: canonical_name -> Entity (Entity.name owned).
    // Review fix M-01: the errdefer here MUST also free `raw_dup` keys
    // in canonical_map — pre-fix only the map's bucket storage was
    // freed, leaking the duplicated raw_name strings on any error
    // after phase 1 began.
    var canonical_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer {
        var it = canonical_map.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        canonical_map.deinit(allocator);
    }
    var canonical_entities: std.StringHashMapUnmanaged(Entity) = .empty;
    errdefer {
        var it = canonical_entities.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.deinit(allocator);
        }
        canonical_entities.deinit(allocator);
    }

    // Embed cache: canonical_name -> embedding vector (owned).
    // Only populated when embed_provider is available.
    var embeds: std.StringHashMapUnmanaged([]f32) = .empty;
    defer {
        var it = embeds.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.value_ptr.*);
        }
        embeds.deinit(allocator);
    }

    for (episode_results) |opt| {
        const er = opt orelse continue;
        for (er.entities) |e| {
            // Already seen this exact raw name? Reuse mapping.
            if (canonical_map.contains(e.name)) continue;

            // Find canonical via coref OR exact-case-insensitive match.
            const canonical = try findOrInsertCanonical(
                allocator,
                e,
                &canonical_entities,
                &canonical_map,
                &embeds,
                coref,
            );
            // Map this raw name to the canonical it resolved to.
            const raw_dup = try allocator.dupe(u8, e.name);
            try canonical_map.put(allocator, raw_dup, canonical);
        }
    }

    // Phase 2 — rewrite edges to canonical names + structural dedup.
    // Dedup key = source|predicate|target.
    var seen_edges: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen_edges.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen_edges.deinit(allocator);
    }
    var out_edges: std.ArrayListUnmanaged(Edge) = .empty;
    errdefer {
        for (out_edges.items) |*ed| ed.deinit(allocator);
        out_edges.deinit(allocator);
    }

    for (episode_results) |opt| {
        const er = opt orelse continue;
        for (er.edges) |ed| {
            const canon_src = canonical_map.get(ed.source_name) orelse ed.source_name;
            const canon_tgt = canonical_map.get(ed.target_name) orelse ed.target_name;

            // Build dedup key.
            const dedup_key = try std.fmt.allocPrint(
                allocator,
                "{s}|{s}|{s}",
                .{ canon_src, ed.relation_type, canon_tgt },
            );

            if (seen_edges.contains(dedup_key)) {
                allocator.free(dedup_key);
                continue;
            }
            try seen_edges.put(allocator, dedup_key, {});

            // Clone the edge under canonical names.
            const cloned = Edge{
                .source_name = try allocator.dupe(u8, canon_src),
                .target_name = try allocator.dupe(u8, canon_tgt),
                .relation_type = try allocator.dupe(u8, ed.relation_type),
                .fact = try allocator.dupe(u8, ed.fact),
                .slot_intent = ed.slot_intent,
                .confidence = ed.confidence,
                .valid_at = ed.valid_at,
            };
            try out_edges.append(allocator, cloned);
        }
    }

    // Phase 3 — collect canonical entities into a slice for the result.
    var out_entities: std.ArrayListUnmanaged(Entity) = .empty;
    errdefer {
        for (out_entities.items) |*e| e.deinit(allocator);
        out_entities.deinit(allocator);
    }
    var it = canonical_entities.iterator();
    while (it.next()) |kv| {
        try out_entities.append(allocator, kv.value_ptr.*);
    }
    canonical_entities.deinit(allocator);

    // Free the raw_name keys in canonical_map (canonical values are
    // pointers into canonical_entities so already moved).
    var map_it = canonical_map.iterator();
    while (map_it.next()) |kv| {
        allocator.free(kv.key_ptr.*);
    }
    canonical_map.deinit(allocator);
    // canonical_map already deinit'd; suppress the deferred deinit
    canonical_map = .empty;

    log.info(
        "merger.merged input_episodes={d} unique_entities={d} unique_edges={d} input_edges={d}",
        .{ countNonNull(episode_results), out_entities.items.len, out_edges.items.len, total_edges },
    );

    return ExtractionResult{
        .entities = try out_entities.toOwnedSlice(allocator),
        .edges = try out_edges.toOwnedSlice(allocator),
    };
}

fn countNonNull(results: []const ?ExtractionResult) usize {
    var n: usize = 0;
    for (results) |r| {
        if (r != null) n += 1;
    }
    return n;
}

/// Find an existing canonical entity for `e` or insert `e` as a new
/// canonical. Returns the canonical name (pointer into
/// canonical_entities; valid for the lifetime of that map).
fn findOrInsertCanonical(
    allocator: std.mem.Allocator,
    e: Entity,
    canonical_entities: *std.StringHashMapUnmanaged(Entity),
    canonical_map: *std.StringHashMapUnmanaged([]const u8),
    embeds: *std.StringHashMapUnmanaged([]f32),
    coref: ?CorefCtx,
) ![]const u8 {
    _ = canonical_map;

    // Try cosine coref first if embed provider is available.
    if (coref) |c| {
        if (c.embed_provider) |ep| {
            // Embed the candidate.
            const candidate_embed = ep.embed(allocator, e.name) catch null;
            if (candidate_embed) |ce| {
                defer allocator.free(ce);
                var it = canonical_entities.iterator();
                while (it.next()) |kv| {
                    const cn = kv.value_ptr.name;
                    const cn_embed = embeds.get(cn) orelse continue;
                    const sim = cosine(ce, cn_embed);
                    if (sim >= c.threshold) {
                        return cn;
                    }
                }
                // No match — insert and cache embed.
                // Review fix M-02: errdefer covers the OOM-after-dupe
                // window where `name`/`owned_embed` would otherwise
                // leak if `put` itself fails (allocates its own bucket
                // storage; can OOM independently).
                const name_owned = try allocator.dupe(u8, e.name);
                errdefer allocator.free(name_owned);
                const owned_embed = try allocator.dupe(f32, ce);
                errdefer allocator.free(owned_embed);
                const new_entity = Entity{
                    .name = name_owned,
                    .entity_type = e.entity_type,
                };
                try canonical_entities.put(allocator, new_entity.name, new_entity);
                // From here on, canonical_entities owns name_owned via
                // new_entity.name. embeds put failure still leaks the
                // embed only — minor and behind a `put` error path.
                try embeds.put(allocator, new_entity.name, owned_embed);
                return new_entity.name;
            }
            // Embed failed — fall through to case-insensitive match.
        }
    }

    // Case-insensitive exact match fallback.
    var it = canonical_entities.iterator();
    while (it.next()) |kv| {
        if (std.ascii.eqlIgnoreCase(kv.value_ptr.name, e.name)) {
            return kv.value_ptr.name;
        }
    }
    // Insert as new canonical. Same M-02 errdefer guard as above.
    const name_owned = try allocator.dupe(u8, e.name);
    errdefer allocator.free(name_owned);
    const new_entity = Entity{
        .name = name_owned,
        .entity_type = e.entity_type,
    };
    try canonical_entities.put(allocator, new_entity.name, new_entity);
    return new_entity.name;
}

fn cosine(a: []const f32, b: []const f32) f64 {
    if (a.len != b.len or a.len == 0) return 0;
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a, b) |x, y| {
        dot += @as(f64, x) * @as(f64, y);
        na += @as(f64, x) * @as(f64, x);
        nb += @as(f64, y) * @as(f64, y);
    }
    if (na == 0 or nb == 0) return 0;
    return dot / (@sqrt(na) * @sqrt(nb));
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

fn makeResult(
    allocator: std.mem.Allocator,
    entities: []const struct { name: []const u8, t: Entity.EntityType },
    edges: []const struct {
        s: []const u8,
        t: []const u8,
        p: []const u8,
        f: []const u8,
    },
) !ExtractionResult {
    var es = try allocator.alloc(Entity, entities.len);
    for (entities, 0..) |spec, i| {
        es[i] = Entity{
            .name = try allocator.dupe(u8, spec.name),
            .entity_type = spec.t,
        };
    }
    var eds = try allocator.alloc(Edge, edges.len);
    for (edges, 0..) |spec, i| {
        eds[i] = Edge{
            .source_name = try allocator.dupe(u8, spec.s),
            .target_name = try allocator.dupe(u8, spec.t),
            .relation_type = try allocator.dupe(u8, spec.p),
            .fact = try allocator.dupe(u8, spec.f),
        };
    }
    return ExtractionResult{ .entities = es, .edges = eds };
}

test "mergeEpisodeResults all-null input returns empty result" {
    const allocator = std.testing.allocator;
    const inputs: []const ?ExtractionResult = &.{ null, null, null };
    const merged = try mergeEpisodeResults(allocator, inputs, null);
    defer merged.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), merged.entities.len);
    try std.testing.expectEqual(@as(usize, 0), merged.edges.len);
}

test "mergeEpisodeResults single non-null episode passes through" {
    const allocator = std.testing.allocator;
    const r = try makeResult(
        allocator,
        &.{ .{ .name = "Sam", .t = .person } },
        &.{ .{ .s = "Sam", .t = "Vault", .p = "RUNS", .f = "Sam runs Vault" } },
    );
    defer r.deinit(allocator);
    const merged = try mergeEpisodeResults(allocator, &.{r}, null);
    defer merged.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), merged.entities.len);
    try std.testing.expectEqual(@as(usize, 1), merged.edges.len);
    try std.testing.expectEqualStrings("Sam", merged.entities[0].name);
}

test "mergeEpisodeResults dedups identical edges across episodes" {
    const allocator = std.testing.allocator;
    const r1 = try makeResult(
        allocator,
        &.{ .{ .name = "Sam", .t = .person } },
        &.{ .{ .s = "Sam", .t = "Vault", .p = "RUNS", .f = "Sam runs Vault" } },
    );
    defer r1.deinit(allocator);
    const r2 = try makeResult(
        allocator,
        &.{ .{ .name = "Sam", .t = .person } },
        &.{ .{ .s = "Sam", .t = "Vault", .p = "RUNS", .f = "Sam runs Vault (mentioned again)" } },
    );
    defer r2.deinit(allocator);
    const merged = try mergeEpisodeResults(allocator, &.{ r1, r2 }, null);
    defer merged.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), merged.entities.len);
    try std.testing.expectEqual(@as(usize, 1), merged.edges.len);
}

test "mergeEpisodeResults case-insensitive entity coref fallback" {
    const allocator = std.testing.allocator;
    const r1 = try makeResult(
        allocator,
        &.{
            .{ .name = "John", .t = .person },
            .{ .name = "Nike", .t = .organization },
        },
        &.{ .{ .s = "John", .t = "Nike", .p = "SIGNED_DEAL_WITH", .f = "John signed with Nike" } },
    );
    defer r1.deinit(allocator);
    const r2 = try makeResult(
        allocator,
        &.{
            .{ .name = "JOHN", .t = .person },
            .{ .name = "Seattle", .t = .place },
        },
        &.{ .{ .s = "JOHN", .t = "Seattle", .p = "PLAYED_IN", .f = "JOHN played in Seattle" } },
    );
    defer r2.deinit(allocator);
    const merged = try mergeEpisodeResults(allocator, &.{ r1, r2 }, null);
    defer merged.deinit(allocator);
    // "John" + "JOHN" collapse case-insensitive → 1 canonical. Nike + Seattle distinct.
    try std.testing.expectEqual(@as(usize, 3), merged.entities.len);
    try std.testing.expectEqual(@as(usize, 2), merged.edges.len);
    // Both edges should have "John" as source (the first canonical seen).
    try std.testing.expectEqualStrings("John", merged.edges[0].source_name);
    try std.testing.expectEqualStrings("John", merged.edges[1].source_name);
}

test "mergeEpisodeResults nulls are skipped, partial signal preserved" {
    const allocator = std.testing.allocator;
    const r1 = try makeResult(
        allocator,
        &.{
            .{ .name = "Alice", .t = .person },
            .{ .name = "Bob", .t = .person },
        },
        &.{ .{ .s = "Alice", .t = "Bob", .p = "KNOWS", .f = "A knows B" } },
    );
    defer r1.deinit(allocator);
    const inputs: []const ?ExtractionResult = &.{ null, r1, null };
    const merged = try mergeEpisodeResults(allocator, inputs, null);
    defer merged.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), merged.entities.len);
    try std.testing.expectEqual(@as(usize, 1), merged.edges.len);
}

test "mergeEpisodeResults distinct edges with different predicates both kept" {
    const allocator = std.testing.allocator;
    const r = try makeResult(
        allocator,
        &.{ .{ .name = "Sam", .t = .person }, .{ .name = "Vault", .t = .organization } },
        &.{
            .{ .s = "Sam", .t = "Vault", .p = "RUNS", .f = "Sam runs Vault" },
            .{ .s = "Sam", .t = "Vault", .p = "FOUNDED", .f = "Sam founded Vault" },
        },
    );
    defer r.deinit(allocator);
    const merged = try mergeEpisodeResults(allocator, &.{r}, null);
    defer merged.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), merged.edges.len);
}

test "cosine handles zero / mismatched / normal vectors" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 1.0, 0.0, 0.0 };
    const c = [_]f32{ 0.0, 1.0, 0.0 };
    const empty = [_]f32{};
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), cosine(&a, &b), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cosine(&a, &c), 1e-6);
    try std.testing.expectEqual(@as(f64, 0.0), cosine(&a, &empty));
    try std.testing.expectEqual(@as(f64, 0.0), cosine(&empty, &empty));
}
