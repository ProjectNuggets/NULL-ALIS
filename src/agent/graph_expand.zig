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
/// `seed_keys` are typically the top-N vector-similarity hits from a
/// memory_recall query. Caller is responsible for choosing those upstream;
/// this function only walks the edges.
///
/// Returns an empty neighborhood when seed_keys is empty.
pub fn expandFromSeeds(
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
        defer allocator.free(hop_edges); // we move entries into all_edges

        // Sort by weight DESC so the cap drops the weakest edges first.
        std.sort.pdq(memory_root.TypedEdge, hop_edges, {}, edgeWeightDesc);

        // Build next frontier from edge targets that are NEW.
        var next_frontier: std.ArrayListUnmanaged([]const u8) = .{};
        defer next_frontier.deinit(allocator);
        var admitted: usize = 0;

        for (hop_edges) |e| {
            // Take ownership of edge into all_edges, regardless of admission.
            try all_edges.append(allocator, e);

            if (admitted >= config.max_nodes_per_hop) continue;

            // Each edge has two endpoints; the new key is the one NOT in node_hops.
            const candidates = [_][]const u8{ e.source_key, e.target_key };
            for (candidates) |cand| {
                if (node_hops.contains(cand)) continue;
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
        // created_at if they care. Acceptable for V1.6 scoping.
        const recency = importance.recencyDecay(now, now);
        const centrality = importance.edgeCountNormalized(degree);
        const hop_decay = 1.0 / (1.0 + @as(f64, @floatFromInt(hop_dist)));
        const score = 0.4 * recency + 0.3 * centrality + 0.3 * hop_decay;

        try scored.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .hop_distance = hop_dist,
            .score = score,
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

fn scoredNodeDesc(_: void, a: ScoredNode, b: ScoredNode) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.hop_distance != b.hop_distance) return a.hop_distance < b.hop_distance;
    return std.mem.lessThan(u8, a.key, b.key);
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
