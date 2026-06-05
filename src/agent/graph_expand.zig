//! V1.6 commit 10 — graph-expand retrieval primitive.
//!
//! Per memory pipeline handoff (2026-05-02): "Graphmemory needs recall to
//! return a subgraph: seed from vector similarity, expand one or two hops
//! along edges, score by centrality + recency + vector similarity combined.
//! The 4KB context injection becomes a graph neighborhood, not a flat list."
//!
//! This module ships the EXPANSION primitive — given a list of seed memory
//! keys (typically from a vector-similarity recall), BFS-expand 1-2 hops
//! along memory_edges, score the resulting nodes, and return a
//! `GraphNeighborhood` payload. The CONSUMER (memory_recall enhancement,
//! /brain/expand endpoint) is a follow-up commit; this primitive is the
//! foundation it sits on.
//!
//! ## Algorithm
//!
//! BFS from seed_keys, batching each frontier into a single
//! `findEdgesByKeys` SQL call (one round trip per hop, not per node).
//! At each hop:
//!   - Pull all active edges where source_key OR target_key is in the frontier
//!   - For each new key discovered, record hop_distance + the originating edge
//!   - Cap nodes per hop at `max_nodes_per_hop` (drop lowest-weight edges
//!     beyond the cap to prevent neighborhood explosion on hub nodes)
//!
//! ## Scoring
//!
//! Each node in the neighborhood gets a composite score in [0, 1]:
//!
//!   score = 0.4 * recency_decay(now - created_at, half_life=30d)
//!         + 0.3 * centrality_norm(edge_count)
//!         + 0.3 * hop_distance_decay(distance)
//!
//! recency_decay + centrality_norm: identical to importance.zig (single
//! source of truth). hop_distance_decay: 1.0 / (1 + distance) — seeds
//! score 1.0, 1-hop neighbors 0.5, 2-hop 0.33.
//!
//! Vector similarity is NOT in this scoring formula — the seed selection
//! upstream already used it. Adding it again would double-weight the
//! seed origin. The CONSUMER can layer vector-similarity scoring on
//! top of the returned neighborhood if needed.
//!
//! ## Cost
//!
//! O(hops) round trips. For typical max_hops=2 + max_nodes_per_hop=20,
//! that's 2 SQL calls returning ≤40 edges each. Bounded + cheap.
//!
//! ## Failure modes
//!
//! Empty seed → returns empty neighborhood (no SQL).
//! findEdgesByKeys failure → propagates the error (caller decides).
//! No edges around seeds → returns just the seed nodes with hop=0.

const std = @import("std");
const log = std.log.scoped(.graph_expand);

const zaki_state = @import("../zaki_state.zig");
const memory_root = @import("../memory/root.zig");
const importance = @import("../memory/importance.zig");
const edge_resolution = @import("edge_resolution.zig");

// ── P2: Algorithm selection ─────────────────────────────────────────────────

/// Graph traversal algorithm. PPR is default; BFS is the legacy path and
/// the fallback when PPR fails (e.g. non-postgres builds, PG timeout).
pub const GraphAlgorithm = enum { ppr, bfs };

/// Read algorithm from env. Default: .ppr.
/// Set NULLALIS_GRAPH_ALGORITHM=bfs to force BFS (e.g. for A/B comparison).
pub fn readGraphAlgorithm() GraphAlgorithm {
    const val = std.posix.getenv("NULLALIS_GRAPH_ALGORITHM") orelse return .ppr;
    if (std.mem.eql(u8, val, "bfs")) return .bfs;
    return .ppr;
}

/// One node in the expanded neighborhood with its hop distance from the
/// nearest seed and its composite score.
pub const ScoredNode = struct {
    key: []const u8,
    /// Hops from the nearest seed (0 for seeds, 1 for 1-hop neighbors, …).
    hop_distance: u8,
    /// Composite score in [0, 1] — recency + centrality + hop-decay.
    /// Higher = more relevant to the seed neighborhood.
    score: f64,

    pub fn deinit(self: *const ScoredNode, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

/// Result of expanding a seed set into the graph neighborhood.
/// Owns all returned slices; caller frees via `deinit`.
pub const GraphNeighborhood = struct {
    /// All nodes reachable within `max_hops` of the seeds, sorted by
    /// score DESC. Includes the seeds themselves at hop=0.
    nodes: []ScoredNode,
    /// All edges traversed during the expansion. May contain duplicates
    /// across hops if the same edge bridges multiple frontiers.
    edges: []memory_root.TypedEdge,

    pub fn deinit(self: *const GraphNeighborhood, allocator: std.mem.Allocator) void {
        for (self.nodes) |*n| n.deinit(allocator);
        allocator.free(self.nodes);
        for (self.edges) |*e| e.deinit(allocator);
        allocator.free(self.edges);
    }
};

pub const ExpandConfig = struct {
    /// Maximum BFS hops from the seeds. Typical: 1 (immediate neighbors)
    /// or 2 (friend-of-friend). Higher quickly explodes the neighborhood
    /// on dense graphs.
    max_hops: u8 = 2,
    /// Hard cap on new nodes admitted per hop. When the frontier produces
    /// more candidates, the lowest-weight edges' targets are dropped.
    /// Prevents hub-node explosion (e.g. a "user" entity with 100+ edges).
    max_nodes_per_hop: usize = 20,
    /// Recency half-life in days for the score's recency component.
    /// Mirrors importance.zig default.
    recency_half_life_days: f64 = 30.0,
};

/// Expand a seed set into a scored graph neighborhood.
///
/// Dispatches to PPR (default) or BFS based on NULLALIS_GRAPH_ALGORITHM env.
/// PPR falls back to BFS automatically on any error (e.g. non-postgres build).
pub fn expandFromSeeds(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    seed_keys: []const []const u8,
    config: ExpandConfig,
) !GraphNeighborhood {
    return switch (readGraphAlgorithm()) {
        .ppr => expandFromSeedsPPR(allocator, state_mgr, user_id, seed_keys, config),
        .bfs => expandFromSeedsBFS(allocator, state_mgr, user_id, seed_keys, config),
    };
}

/// P2 — Personalized PageRank expansion. Falls back to BFS on any error.
///
/// Runs a single recursive CTE in Postgres that propagates score from seeds
/// along typed edges with predicate-type priors (1.0/0.5/0.7) × 0.85 damping.
/// After scoring, fetches edges via findEdgesByKeys so that buildGraphNeighborsBlock
/// can render the "via <predicate>" context for each neighbor.
fn expandFromSeedsPPR(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    seed_keys: []const []const u8,
    config: ExpandConfig,
) !GraphNeighborhood {
    if (seed_keys.len == 0) return .{
        .nodes = try allocator.alloc(ScoredNode, 0),
        .edges = try allocator.alloc(memory_root.TypedEdge, 0),
    };

    const limit = config.max_hops * config.max_nodes_per_hop + seed_keys.len;
    const ppr_nodes = state_mgr.findEdgesPPR(allocator, user_id, seed_keys, config.max_hops, limit) catch |err| {
        log.warn("ppr.fetch_failed err={s} — falling back to BFS", .{@errorName(err)});
        return expandFromSeedsBFS(allocator, state_mgr, user_id, seed_keys, config);
    };
    defer {
        for (ppr_nodes) |n| n.deinit(allocator);
        allocator.free(ppr_nodes);
    }

    if (ppr_nodes.len == 0) return .{
        .nodes = try allocator.alloc(ScoredNode, 0),
        .edges = try allocator.alloc(memory_root.TypedEdge, 0),
    };

    // Normalise PPR scores → [0, 1] so scoreFromComponents can use ppr as centrality.
    var max_ppr: f64 = 0.0;
    for (ppr_nodes) |n| if (n.ppr_score > max_ppr) {
        max_ppr = n.ppr_score;
    };

    var scored: std.ArrayListUnmanaged(ScoredNode) = .{};
    errdefer {
        for (scored.items) |*n| n.deinit(allocator);
        scored.deinit(allocator);
    }

    for (ppr_nodes) |n| {
        // Recency: PPR row has no created_at — default to 1.0 (no decay).
        // A follow-up can JOIN memories.created_at in findEdgesPPR.
        const ppr_norm: f64 = if (max_ppr > 0.0) n.ppr_score / max_ppr else 0.0;
        try scored.append(allocator, .{
            .key = try allocator.dupe(u8, n.key),
            .hop_distance = n.min_depth,
            .score = scoreFromComponents(1.0, ppr_norm, n.min_depth),
        });
    }

    std.sort.pdq(ScoredNode, scored.items, {}, scoredNodeDesc);

    // CRITICAL: buildGraphNeighborsBlock silently skips every node when
    // edges is empty (memory_loader.zig line ~1482). Fetch edges for all
    // discovered nodes so the "via <predicate>" context renders correctly.
    const all_keys = try allocator.alloc([]const u8, scored.items.len);
    defer allocator.free(all_keys);
    for (scored.items, 0..) |n, i| all_keys[i] = n.key;

    const edges = state_mgr.findEdgesByKeys(allocator, user_id, all_keys) catch |err| blk: {
        log.warn("ppr.edges_fetch_failed err={s} — neighbors render without 'via' context", .{@errorName(err)});
        break :blk try allocator.alloc(memory_root.TypedEdge, 0);
    };
    errdefer {
        for (edges) |*e| e.deinit(allocator);
        allocator.free(edges);
    }

    const nodes = try scored.toOwnedSlice(allocator);
    return .{ .nodes = nodes, .edges = edges };
}

/// BFS expansion (legacy path, also the PPR fallback).
///
/// `seed_keys` are typically the top-N vector-similarity hits from a
/// memory_recall query. Caller is responsible for choosing those upstream;
/// this function only walks the edges.
///
/// Returns an empty neighborhood when seed_keys is empty.
fn expandFromSeedsBFS(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    seed_keys: []const []const u8,
    config: ExpandConfig,
) !GraphNeighborhood {
    if (seed_keys.len == 0) {
        return .{
            .nodes = try allocator.alloc(ScoredNode, 0),
            .edges = try allocator.alloc(memory_root.TypedEdge, 0),
        };
    }

    // Track every discovered key with its hop distance (smallest wins on
    // collision via min-update). StringHashMapUnmanaged with owned keys.
    var node_hops: std.StringHashMapUnmanaged(u8) = .{};
    defer {
        var it = node_hops.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        node_hops.deinit(allocator);
    }

    // Seeds at hop=0. Dedup the input.
    for (seed_keys) |sk| {
        const owned_key = try allocator.dupe(u8, sk);
        const gop = try node_hops.getOrPut(allocator, owned_key);
        if (gop.found_existing) {
            allocator.free(owned_key);
        } else {
            gop.value_ptr.* = 0;
        }
    }

    // Accumulate edges across hops.
    var all_edges: std.ArrayListUnmanaged(memory_root.TypedEdge) = .{};
    errdefer {
        for (all_edges.items) |*e| e.deinit(allocator);
        all_edges.deinit(allocator);
    }

    // BFS frontier — initially seeds.
    var frontier: std.ArrayListUnmanaged([]const u8) = .{};
    defer frontier.deinit(allocator);
    for (seed_keys) |sk| try frontier.append(allocator, sk);

    var hop: u8 = 0;
    while (hop < config.max_hops) : (hop += 1) {
        if (frontier.items.len == 0) break;

        // Batched edge fetch: one SQL round trip per hop.
        const hop_edges = state_mgr.findEdgesByKeys(allocator, user_id, frontier.items) catch |err| {
            log.warn("graph_expand.fetch_failed hop={d} frontier_size={d} err={s}", .{
                hop, frontier.items.len, @errorName(err),
            });
            break;
        };

        // V1.7a-4 review fix WR-02 + V1.6 review fix WR-05 — partial-move
        // leak hardening AND ownership-contract documentation.
        //
        // **Contract assumed of `findEdgesByKeys`:** each returned TypedEdge
        // is INDEPENDENTLY ALLOCATED — its three string fields
        // (source_key, target_key, predicate) point into separately-allocated
        // heap regions, NOT into a shared arena/slab. The current Postgres
        // backend honors this (libpq row pattern: each PQgetvalue returns
        // a separate copy via dupeResultValue). If a future backend (e.g.
        // arena-style) violated this, the per-edge `e.deinit(allocator)`
        // calls below would either no-op or fault — the contract is
        // load-bearing.
        //
        // **Partial-move leak guard:** each TypedEdge in hop_edges owns
        // 3 strings. The loop below MOVES edges one-by-one into all_edges
        // via `try ... append(...)`. If append fails mid-loop (OOM during
        // ArrayList growth), the moved prefix is now owned by all_edges
        // (cleaned by the outer errdefer) but the NOT-YET-MOVED tail
        // [moved_count..] is still in hop_edges with its owned strings.
        // A bare `defer allocator.free(hop_edges)` would only free the
        // slice header — the per-edge strings would leak.
        //
        // Track moved_count and have the defer deinit the unmoved tail
        // before freeing the outer slice. On normal completion,
        // moved_count == hop_edges.len, the tail is empty, and only the
        // slice header gets freed (no double-deinit).
        var moved_count: usize = 0;
        defer {
            for (hop_edges[moved_count..]) |*e| e.deinit(allocator);
            allocator.free(hop_edges);
        }

        // V1.14.11 (R3) — predicate-aware edge weighting via sort-time
        // comparator (NOT in-place mutation). Single-valued predicates
        // (LIVES_IN, MARRIED_TO, BIRTHDAY) propagate at full weight —
        // they ARE the canonical truth. Set-valued predicates (LIKES,
        // USES, IS_TYPE_OF, ATTENDED) propagate at 0.5x — many edges
        // per node, each carries less semantic weight. Mirrors the
        // cardinality split documented in
        // src/agent/edge_resolution.zig::buildResolvePrompt.
        //
        // BUG FIX (post-review): the original implementation mutated
        // `e.weight *= prior` in place. That leaked into
        // gateway.zig:13767 which emits `e.weight` to the /brain/graph
        // FE, surfacing priored weights (0.5 / 1.0) instead of true
        // DB-stored weights. Sort with an adjusted-weight comparator
        // instead so edge.weight stays intact for downstream readers.
        std.sort.pdq(memory_root.TypedEdge, hop_edges, {}, edgeAdjustedWeightDesc);

        // R3 per-hop telemetry: emits the frontier size + edge count
        // per hop. Lets us see in production whether depth-2 expansion
        // is actually producing additional reach on Cat 3 queries.
        log.info("graph_expand.hop hop={d} frontier_size={d} edges={d} admitted_cap={d}", .{
            hop, frontier.items.len, hop_edges.len, config.max_nodes_per_hop,
        });

        // Build next frontier from edge targets that are NEW.
        var next_frontier: std.ArrayListUnmanaged([]const u8) = .{};
        defer next_frontier.deinit(allocator);
        var admitted: usize = 0;

        for (hop_edges) |e| {
            // Take ownership of edge into all_edges, regardless of admission.
            try all_edges.append(allocator, e);
            moved_count += 1;

            if (admitted >= config.max_nodes_per_hop) continue;

            // Each edge has two endpoints; the new key is the one NOT in node_hops.
            const candidates = [_][]const u8{ e.source_key, e.target_key };
            for (candidates) |cand| {
                if (node_hops.contains(cand)) continue;
                // Structural hubs (`user:<id>`, `session:<id>`) are
                // non-discriminative — never admit them to the frontier, or the
                // next hop fans out to every memory the hub touches. Mirrors the
                // findEdgesPPR exclusion so the BFS fallback path (and the
                // explicit NULLALIS_GRAPH_ALGORITHM=bfs path) is hub-safe too.
                if (std.mem.startsWith(u8, cand, "user:") or std.mem.startsWith(u8, cand, "session:")) continue;
                const owned_cand = try allocator.dupe(u8, cand);
                try node_hops.put(allocator, owned_cand, hop + 1);
                try next_frontier.append(allocator, owned_cand);
                admitted += 1;
                if (admitted >= config.max_nodes_per_hop) break;
            }
        }

        // Move next frontier into the loop variable.
        frontier.clearRetainingCapacity();
        for (next_frontier.items) |k| try frontier.append(allocator, k);
    }

    // ── Score every discovered node ────────────────────────────────
    const now = std.time.timestamp();
    var scored: std.ArrayListUnmanaged(ScoredNode) = .{};
    errdefer {
        for (scored.items) |*n| n.deinit(allocator);
        scored.deinit(allocator);
    }

    var it = node_hops.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const hop_dist = entry.value_ptr.*;

        // Centrality: count this node's incidences in the collected edges.
        // O(N*M) but bounded (≤ max_hops * max_nodes_per_hop nodes × similar edges).
        var degree: usize = 0;
        for (all_edges.items) |e| {
            if (std.mem.eql(u8, e.source_key, key) or std.mem.eql(u8, e.target_key, key)) {
                degree += 1;
            }
        }

        // Recency: we don't have created_at on the node here (would require
        // an additional getMemory round trip). Approximation: assume "now"
        // for nodes we just discovered. Caller can re-score with real
        // created_at if they care — `recallMemoriesAsGraph` does exactly
        // that via `getMemoryTimestamps` post-expansion. Acceptable
        // placeholder for the standalone primitive.
        const recency = importance.recencyDecay(now, now);
        const centrality = importance.edgeCountNormalized(degree);

        try scored.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .hop_distance = hop_dist,
            .score = scoreFromComponents(recency, centrality, hop_dist),
        });
    }

    // Sort by score DESC; ties broken by hop_distance ASC then key ASC.
    std.sort.pdq(ScoredNode, scored.items, {}, scoredNodeDesc);

    return .{
        .nodes = try scored.toOwnedSlice(allocator),
        .edges = try all_edges.toOwnedSlice(allocator),
    };
}

fn edgeWeightDesc(_: void, a: memory_root.TypedEdge, b: memory_root.TypedEdge) bool {
    return a.weight > b.weight;
}

/// V1.14.11 (R3) — predicate-aware comparator. Computes the priored
/// weight at compare-time without touching the underlying edge struct,
/// so callers downstream (e.g. /brain/graph JSON emission at
/// gateway.zig:13767) still see the true DB-stored weight, not the
/// prior-multiplied value used internally for cap-eviction ordering.
fn edgeAdjustedWeightDesc(_: void, a: memory_root.TypedEdge, b: memory_root.TypedEdge) bool {
    return a.weight * predicateTypePrior(a.predicate) > b.weight * predicateTypePrior(b.predicate);
}

/// V1.14.11 (R3) — predicate-type prior for PPR-style edge weighting.
///
/// Set-valued predicates (a node can have many of them — IS_TYPE_OF,
/// LIKES, USES, ATTENDED, etc.) propagate at 0.5x because each
/// individual edge carries less semantic weight when many coexist.
/// Single-valued predicates (LIVES_IN, MARRIED_TO, BIRTHDAY) propagate
/// at full 1.0 because each IS the canonical fact for that subject.
///
/// Default for unknown predicates is 0.7 — a middle value that doesn't
/// over-penalize unmapped vocab.
///
/// V1.14.12 (M2) — refactored to delegate to
/// `edge_resolution.classifyPredicate` (single source of truth for
/// cardinality vocab). Pre-M2 this function maintained an inline copy
/// of the same predicate list as `buildResolvePrompt`'s SET-VALUED
/// section; drift between them weakened correctness. Now both consult
/// the same enum-returning helper.
///
/// Reference: HippoRAG (Gutiérrez et al. 2024) uses 0.5 / 0.85 as the
/// propagation prior; we widened the gap (0.5 / 1.0) to amplify the
/// signal on this corpus's predicate distribution.
pub fn predicateTypePrior(predicate: []const u8) f64 {
    return switch (edge_resolution.classifyPredicate(predicate)) {
        .single_valued => 1.0,
        .set_valued => 0.5,
        .unknown => 0.7,
    };
}

fn scoredNodeDesc(_: void, a: ScoredNode, b: ScoredNode) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.hop_distance != b.hop_distance) return a.hop_distance < b.hop_distance;
    return std.mem.lessThan(u8, a.key, b.key);
}

/// Composite score formula used by both `expandFromSeeds` (placeholder
/// recency) and `recallMemoriesAsGraph` (real recency from
/// `getMemoryTimestamps`). Single source of truth so the rescoring path
/// can't drift from the primitive's formula.
///
///   score = 0.4 * recency_decay + 0.3 * centrality + 0.3 * hop_decay
///
/// Same weights as the docstring at the top of this module. `hop_distance`
/// of 0 (seed) gives hop_decay=1.0; hop=1 gives 0.5; hop=2 gives 0.33.
pub fn scoreFromComponents(recency_decay: f64, centrality: f64, hop_distance: u8) f64 {
    const hop_decay = 1.0 / (1.0 + @as(f64, @floatFromInt(hop_distance)));
    return 0.4 * recency_decay + 0.3 * centrality + 0.3 * hop_decay;
}

/// V1.7a-2 — recall + graph expansion in one call.
///
/// Composes the existing `recallMemories` (BM25 + key + content seeds) with
/// `expandFromSeeds` (BFS along memory_edges) and re-scores the resulting
/// neighborhood with REAL recency derived from `getMemoryTimestamps`.
///
/// Owns the returned slices (`seeds` MemoryEntries + `neighborhood` nodes
/// and edges); caller frees via `RecallGraph.deinit`.
///
/// **Rollout knob:** `config.max_hops == 0` short-circuits past the
/// expansion entirely — returns just the recall seeds with an empty
/// neighborhood. memory_loader uses this to gate graph mode behind an
/// env flag for ship-safe rollout (default 1, set 0 to disable).
///
/// **Performance:** worst case is recallMemories (1 SQL) + expandFromSeeds
/// (≤ max_hops SQL) + getMemoryTimestamps (1 SQL) = max_hops + 2 round
/// trips. For default max_hops=1: 3 round trips total per recall.
pub const RecallGraph = struct {
    /// Top-K memory entries from the seed recall pass — already in the
    /// neighborhood (at hop_distance=0). Kept separately so callers that
    /// only want the canonical "matched memory" content can read it
    /// without crawling the neighborhood.
    seeds: []memory_root.MemoryEntry,
    /// All nodes (including the seed keys at hop=0) and edges discovered
    /// during BFS expansion. Re-scored with real recency.
    neighborhood: GraphNeighborhood,

    pub fn deinit(self: *const RecallGraph, allocator: std.mem.Allocator) void {
        memory_root.freeEntries(allocator, self.seeds);
        self.neighborhood.deinit(allocator);
    }
};

pub fn recallMemoriesAsGraph(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    query: []const u8,
    max_seeds: usize,
    config: ExpandConfig,
    session_id: ?[]const u8,
) !RecallGraph {
    const seeds = try state_mgr.recallMemories(allocator, user_id, query, max_seeds, session_id);
    errdefer memory_root.freeEntries(allocator, seeds);

    if (config.max_hops == 0 or seeds.len == 0) {
        return .{
            .seeds = seeds,
            .neighborhood = .{
                .nodes = try allocator.alloc(ScoredNode, 0),
                .edges = try allocator.alloc(memory_root.TypedEdge, 0),
            },
        };
    }

    // Borrow seed key slices into a flat array for expandFromSeeds.
    var seed_keys = try allocator.alloc([]const u8, seeds.len);
    defer allocator.free(seed_keys);
    for (seeds, 0..) |s, i| seed_keys[i] = s.key;

    var neighborhood = try expandFromSeeds(allocator, state_mgr, user_id, seed_keys, config);
    errdefer neighborhood.deinit(allocator);

    // ── Re-score with REAL recency (cmt10 INFO closure) ────────────────
    // Collect all node keys, batch-fetch timestamps, recompute scores
    // using the same scoreFromComponents formula. Centrality is recomputed
    // from the local edge set so it matches what expandFromSeeds saw.
    if (neighborhood.nodes.len > 0) {
        var keys = try allocator.alloc([]const u8, neighborhood.nodes.len);
        defer allocator.free(keys);
        for (neighborhood.nodes, 0..) |n, i| keys[i] = n.key;

        const timestamps = state_mgr.getMemoryTimestamps(allocator, user_id, keys) catch |err| blk: {
            log.warn("graph_expand.recall.rescore_failed err={s} — keeping placeholder scores", .{@errorName(err)});
            break :blk null;
        };
        if (timestamps) |ts_slice| {
            defer allocator.free(ts_slice);
            const now = std.time.timestamp();
            for (neighborhood.nodes, 0..) |*n, i| {
                // Real recency when we have created_at; else fall back to
                // now-as-now (matches placeholder semantics, never errors).
                const recency = if (ts_slice[i]) |ts|
                    importance.recencyDecay(now, ts)
                else
                    importance.recencyDecay(now, now);

                // Recompute centrality locally from the same edge set.
                var degree: usize = 0;
                for (neighborhood.edges) |e| {
                    if (std.mem.eql(u8, e.source_key, n.key) or std.mem.eql(u8, e.target_key, n.key)) {
                        degree += 1;
                    }
                }
                const centrality = importance.edgeCountNormalized(degree);
                n.score = scoreFromComponents(recency, centrality, n.hop_distance);
            }
            // Re-sort: scores changed.
            std.sort.pdq(ScoredNode, neighborhood.nodes, {}, scoredNodeDesc);
        }
    }

    return .{ .seeds = seeds, .neighborhood = neighborhood };
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// Pure-logic unit tests only — anything requiring `*zaki_state.Manager`
// must use the PG smoke harness at zaki_state.zig::"V1.6 commit 10
// graph-expand — 3-node chain expansion" (covers expandFromSeeds + the
// findEdgesByKeys batched lookup end-to-end).

test "scoredNodeDesc sorts by score descending then hop ascending" {
    const a: ScoredNode = .{ .key = "a", .hop_distance = 0, .score = 0.9 };
    const b: ScoredNode = .{ .key = "b", .hop_distance = 1, .score = 0.5 };
    const c: ScoredNode = .{ .key = "c", .hop_distance = 0, .score = 0.5 };
    try std.testing.expect(scoredNodeDesc({}, a, b)); // score wins
    try std.testing.expect(scoredNodeDesc({}, c, b)); // tie on score, hop wins
    try std.testing.expect(!scoredNodeDesc({}, b, a)); // reverse
}

test "edgeWeightDesc orders by weight descending" {
    const a: memory_root.TypedEdge = .{ .source_key = "x", .target_key = "y", .predicate = "P", .weight = 0.9 };
    const b: memory_root.TypedEdge = .{ .source_key = "x", .target_key = "z", .predicate = "P", .weight = 0.5 };
    try std.testing.expect(edgeWeightDesc({}, a, b));
    try std.testing.expect(!edgeWeightDesc({}, b, a));
}

test "predicateTypePrior: single-valued identity predicates propagate at full weight" {
    try std.testing.expectEqual(@as(f64, 1.0), predicateTypePrior("LIVES_IN"));
    try std.testing.expectEqual(@as(f64, 1.0), predicateTypePrior("MARRIED_TO"));
    try std.testing.expectEqual(@as(f64, 1.0), predicateTypePrior("BIRTHDAY"));
    try std.testing.expectEqual(@as(f64, 1.0), predicateTypePrior("REPLACES"));
}

test "predicateTypePrior: set-valued predicates dampen to 0.5x" {
    try std.testing.expectEqual(@as(f64, 0.5), predicateTypePrior("LIKES"));
    try std.testing.expectEqual(@as(f64, 0.5), predicateTypePrior("USES"));
    try std.testing.expectEqual(@as(f64, 0.5), predicateTypePrior("IS_TYPE_OF"));
    try std.testing.expectEqual(@as(f64, 0.5), predicateTypePrior("ATTENDED"));
    try std.testing.expectEqual(@as(f64, 0.5), predicateTypePrior("KNOWS"));
}

test "predicateTypePrior: case-insensitive lookup" {
    try std.testing.expectEqual(@as(f64, 1.0), predicateTypePrior("lives_in"));
    try std.testing.expectEqual(@as(f64, 0.5), predicateTypePrior("Likes"));
}

test "predicateTypePrior: unmapped predicates get sensible middle prior" {
    try std.testing.expectEqual(@as(f64, 0.7), predicateTypePrior("CUSTOM_UNMAPPED"));
    try std.testing.expectEqual(@as(f64, 0.7), predicateTypePrior(""));
    // Oversize predicate — falls through without panic.
    const big = "X" ** 100;
    try std.testing.expectEqual(@as(f64, 0.7), predicateTypePrior(big));
}

test "predicateTypePrior: amplification ratio between single and set-valued is 2x" {
    // R3 design invariant: single-valued predicates should propagate
    // at 2x the weight of set-valued ones. If this ratio shifts, the
    // PPR scoring intuition (canonical facts dominate over set members)
    // breaks. Catches accidental weight changes during tuning.
    const ratio = predicateTypePrior("LIVES_IN") / predicateTypePrior("LIKES");
    try std.testing.expectEqual(@as(f64, 2.0), ratio);
}

test "edgeAdjustedWeightDesc: ranks single-valued above set-valued at equal raw weight" {
    // The whole point of the predicate-aware sort. Two edges with
    // identical DB-stored weight but different predicate cardinality
    // should rank with the single-valued one first.
    const single: memory_root.TypedEdge = .{ .source_key = "x", .target_key = "y", .predicate = "LIVES_IN", .weight = 1.0 };
    const set_val: memory_root.TypedEdge = .{ .source_key = "x", .target_key = "z", .predicate = "LIKES", .weight = 1.0 };
    try std.testing.expect(edgeAdjustedWeightDesc({}, single, set_val));
    try std.testing.expect(!edgeAdjustedWeightDesc({}, set_val, single));
}

test "edgeAdjustedWeightDesc: does NOT mutate edge.weight (regression for /brain/graph leak)" {
    // V1.14.11 post-review bug fix. Original implementation multiplied
    // e.weight *= predicateTypePrior(...) in place, which leaked
    // priored weights into gateway.zig:13767's /brain/graph JSON
    // emission, surfacing 0.5 / 1.0 instead of true DB values.
    // Now the prior applies only at compare-time. This test asserts
    // the compare itself does not mutate.
    const a: memory_root.TypedEdge = .{ .source_key = "x", .target_key = "y", .predicate = "LIKES", .weight = 0.8 };
    const b: memory_root.TypedEdge = .{ .source_key = "x", .target_key = "z", .predicate = "LIVES_IN", .weight = 0.6 };
    _ = edgeAdjustedWeightDesc({}, a, b);
    _ = edgeAdjustedWeightDesc({}, b, a);
    // Weights must be untouched after compare calls.
    try std.testing.expectEqual(@as(f64, 0.8), a.weight);
    try std.testing.expectEqual(@as(f64, 0.6), b.weight);
}
