//! V1.7a-9b — Communities via edge-weight-weighted Label Propagation.
//!
//! Pure-data primitive consumed by `community_pipeline.zig` (V1.7a-9c).
//! Takes a slice of `CommunityEdge` (from listMemoryEdgesForCommunityCompute)
//! and returns a per-node "leader" mapping — each node's community is
//! identified by the lowest-keyed member it converges with. The pipeline
//! then re-maps leaders to stable community_ids based on top-K-importance
//! membership (V1.7a-9 plan D4: same logical community → same id across
//! recomputes).
//!
//! ## Algorithm
//!
//! Standard LPA with three modifications grounded in 2026-05-03 graph-
//! memory research synthesis (Nova):
//!
//!   1. **Vote weighting**: each edge's vote = `weight * attribution_mult
//!      * recency_decay`. User-declared edges (compose_memory, agent_tool)
//!      get attribution_mult=1.5; auto-extracted edges get 1.0; unknown
//!      attributions get 0.8. Recency decay applies an exp half-life of
//!      60 days against the edge's `valid_from_unix`. Implements the
//!      research's "user-declared > auto-extracted" + "decay over time"
//!      principles.
//!
//!   2. **Deterministic tie-break**: when two labels tie on summed vote
//!      weight, the lowest-string label wins. Ensures same input →
//!      same output across runs (test #4 in 9b verifies determinism over
//!      100 iterations).
//!
//!   3. **Convergence detection**: stop early when no node changes
//!      label in a full pass. Bounded by `config.max_iterations`
//!      (default 10) as a safety cap.
//!
//! ## Output
//!
//! `NodeLabels` = `StringHashMap([]const u8)` mapping node_key → leader_key.
//! The leader is the lowest-string-key node in the converged community.
//! Both keys borrow lifetime from the input edge slice — caller MUST
//! hold the edges alive while consuming the labels.
//!
//! ## Cost
//!
//! O(iterations * E) — each iteration walks all edges twice (once per
//! direction) and updates each node's label once. For typical V1
//! corpora (≤ 500 nodes, ≤ 2000 edges, ≤ 10 iterations) this is well
//! under 100K ops, sub-millisecond.
//!
//! ## Failure modes
//!
//! Empty edge slice → empty NodeLabels (no SQL needed in caller).
//! Every node ends up in a community of one or more — no NULL leaders.
//! Self-loops (source == target) ignored at vote time (no information).

const std = @import("std");
const log = std.log.scoped(.communities);

const memory_root = @import("../memory/root.zig");

/// Owned mapping node_key → leader_key. Keys + values borrow lifetime
/// from the input edge slice (no allocation per entry beyond the
/// hashmap's internal buckets). Caller deinits the hashmap; does NOT
/// free the borrowed key/value strings (they live in CommunityEdge).
pub const NodeLabels = std.StringHashMapUnmanaged([]const u8);

pub const LpaConfig = struct {
    /// Hard cap on LPA iterations. 10 is plenty for typical convergence
    /// (most graphs converge in 3-5); higher just wastes cycles when
    /// oscillation occurs (rare with deterministic tie-break).
    max_iterations: u8 = 10,
    /// Recency-decay half-life in seconds. 60 days = 5_184_000s.
    /// Anticipates V1.7b-5 edge decay; LPA already applies the soft
    /// version via vote weight.
    recency_half_life_secs: f64 = 60.0 * 86400.0,
    /// Reference "now" for recency decay. Caller passes std.time.timestamp()
    /// in production; tests pass a fixed value for determinism.
    now_unix: i64 = 0,
};

/// Compute per-node community leaders via vote-weighted LPA.
///
/// Returns a hashmap mapping every node that appears in the edge slice
/// to its converged leader (lowest-keyed member of its community).
/// Isolated nodes (no edges) are NOT in the result — caller treats
/// them as community_id=null (true orphans, surfaced by /brain/orphans).
///
/// Caller deinits the returned NodeLabels via `.deinit(allocator)`.
pub fn computeCommunityLeaders(
    allocator: std.mem.Allocator,
    edges: []const memory_root.CommunityEdge,
    config: LpaConfig,
) !NodeLabels {
    var labels: NodeLabels = .{};
    errdefer labels.deinit(allocator);

    if (edges.len == 0) return labels;

    // ── Init: every node starts as its own leader ────────────────
    // Discover the unique node set by scanning both endpoints.
    for (edges) |e| {
        const src_gop = try labels.getOrPut(allocator, e.source_key);
        if (!src_gop.found_existing) src_gop.value_ptr.* = e.source_key;
        const tgt_gop = try labels.getOrPut(allocator, e.target_key);
        if (!tgt_gop.found_existing) tgt_gop.value_ptr.* = e.target_key;
    }

    // ── Sort node keys DESCENDING for deterministic async update ─
    //
    // Why reverse-sorted async LPA (vs random-async or fully-synchronous):
    //   * Random-async is the textbook LPA but introduces non-determinism
    //     (we need byte-stable output across runs for cache + test
    //     reproducibility).
    //   * Fully synchronous LPA oscillates on perfectly-symmetric pairs
    //     (2-clique x-y: x sees y's label, y sees x's label, both flip
    //     simultaneously — never converges).
    //   * REVERSE-sorted async (largest key updates first, sees others'
    //     INITIAL labels; smallest key updates last, sees the merged
    //     state) provably converges toward the LOWEST-keyed leader in
    //     each connected component. Combined with lowest-string
    //     tie-break inside each vote tally, every recompute on the same
    //     input produces the same labels.
    var sorted_keys = try allocator.alloc([]const u8, labels.count());
    defer allocator.free(sorted_keys);
    {
        var i: usize = 0;
        var it = labels.keyIterator();
        while (it.next()) |k| : (i += 1) sorted_keys[i] = k.*;
    }
    std.mem.sort([]const u8, sorted_keys, {}, struct {
        fn gt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, b, a); // descending
        }
    }.gt);

    // ── Iterate until convergence or cap ─────────────────────────
    var iter: u8 = 0;
    while (iter < config.max_iterations) : (iter += 1) {
        var any_changed = false;

        for (sorted_keys) |node_key| {
            // Per-iteration vote tally: label → summed weight.
            var votes: std.StringHashMapUnmanaged(f64) = .{};
            defer votes.deinit(allocator);

            for (edges) |e| {
                // Self-loops carry no information.
                if (std.mem.eql(u8, e.source_key, e.target_key)) continue;
                const neighbor_key = if (std.mem.eql(u8, e.source_key, node_key))
                    e.target_key
                else if (std.mem.eql(u8, e.target_key, node_key))
                    e.source_key
                else
                    continue;
                const neighbor_label = (labels.get(neighbor_key)) orelse continue;
                const w = computeVoteWeight(e, config);
                const gop = votes.getOrPut(allocator, neighbor_label) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += w;
            }

            // Pick winner: highest vote, ties broken by LOWEST-string.
            // Initial best is the node's CURRENT label with weight 0 —
            // a node with no neighbor votes stays put.
            const current = labels.get(node_key) orelse node_key;
            var best_label: []const u8 = current;
            var best_weight: f64 = 0;
            var v_it = votes.iterator();
            while (v_it.next()) |v| {
                const cand = v.key_ptr.*;
                const w = v.value_ptr.*;
                if (w > best_weight) {
                    best_weight = w;
                    best_label = cand;
                } else if (w == best_weight) {
                    if (std.mem.lessThan(u8, cand, best_label)) best_label = cand;
                }
            }

            if (!std.mem.eql(u8, best_label, current)) {
                try labels.put(allocator, node_key, best_label);
                any_changed = true;
            }
        }

        if (!any_changed) {
            log.debug("communities.lpa converged iter={d} nodes={d}", .{ iter + 1, labels.count() });
            return labels;
        }
    }
    log.debug("communities.lpa hit cap iter={d} nodes={d}", .{ config.max_iterations, labels.count() });
    return labels;
}

/// Vote-weight formula. Documented at module docstring; isolated for
/// unit-test access.
///
///   weight × attribution_multiplier × recency_decay
///
/// recency_decay = 2 ^ -((now - valid_from) / half_life). When
/// `now_unix == 0` (test convenience for deterministic input), recency
/// decay is short-circuited to 1.0 — vote weight degenerates to
/// `weight × attribution_multiplier`.
pub fn computeVoteWeight(edge: memory_root.CommunityEdge, config: LpaConfig) f64 {
    const attr_mult = attributionMultiplier(edge.attribution);
    if (config.now_unix == 0) return edge.weight * attr_mult;
    const age_seconds: f64 = @floatFromInt(@max(0, config.now_unix - edge.valid_from_unix));
    // Use base-2 exponential for cleaner half-life semantics: at exactly
    // one half-life elapsed, recency = 0.5.
    const decay = std.math.pow(f64, 2.0, -(age_seconds / config.recency_half_life_secs));
    return edge.weight * attr_mult * decay;
}

/// Per-2026-05-03 research synthesis: user-declared > auto-extracted.
/// `compose_memory` and `agent_tool` represent explicit user intent;
/// `extraction_classifier` is the auto-pipeline. Unknowns get a slight
/// penalty (0.8) so legacy / mis-tagged edges are softer voters.
pub fn attributionMultiplier(attribution: []const u8) f64 {
    if (std.mem.eql(u8, attribution, "compose_memory")) return 1.5;
    if (std.mem.eql(u8, attribution, "agent_tool")) return 1.5;
    if (std.mem.eql(u8, attribution, "extraction_classifier")) return 1.0;
    return 0.8;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "computeCommunityLeaders — 3-clique + isolated → 2 components" {
    const allocator = std.testing.allocator;
    // 3-clique: a-b, b-c, a-c (one community)
    // Isolated: x-y (separate community)
    const edges = [_]memory_root.CommunityEdge{
        .{ .source_key = "a", .target_key = "b", .weight = 1.0, .attribution = "extraction_classifier", .valid_from_unix = 0 },
        .{ .source_key = "b", .target_key = "c", .weight = 1.0, .attribution = "extraction_classifier", .valid_from_unix = 0 },
        .{ .source_key = "a", .target_key = "c", .weight = 1.0, .attribution = "extraction_classifier", .valid_from_unix = 0 },
        .{ .source_key = "x", .target_key = "y", .weight = 1.0, .attribution = "extraction_classifier", .valid_from_unix = 0 },
    };
    var labels = try computeCommunityLeaders(allocator, &edges, .{});
    defer labels.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 5), labels.count()); // a, b, c, x, y
    // a/b/c all converge to same leader (the lowest-keyed in their component = "a")
    try std.testing.expectEqualStrings("a", labels.get("a").?);
    try std.testing.expectEqualStrings("a", labels.get("b").?);
    try std.testing.expectEqualStrings("a", labels.get("c").?);
    // x/y converge to "x"
    try std.testing.expectEqualStrings("x", labels.get("x").?);
    try std.testing.expectEqualStrings("x", labels.get("y").?);
}

test "computeCommunityLeaders — 5-clique → 1 community" {
    const allocator = std.testing.allocator;
    // Fully connected 5 nodes: 10 edges
    var edges_buf: [10]memory_root.CommunityEdge = undefined;
    const keys = [_][]const u8{ "a", "b", "c", "d", "e" };
    var i: usize = 0;
    for (keys, 0..) |s, si| {
        for (keys[si + 1 ..]) |t| {
            edges_buf[i] = .{
                .source_key = s,
                .target_key = t,
                .weight = 1.0,
                .attribution = "extraction_classifier",
                .valid_from_unix = 0,
            };
            i += 1;
        }
    }

    var labels = try computeCommunityLeaders(allocator, edges_buf[0..i], .{});
    defer labels.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 5), labels.count());
    // Everyone converges to "a" (lowest-keyed)
    for (keys) |k| try std.testing.expectEqualStrings("a", labels.get(k).?);
}

test "computeCommunityLeaders — vote weight: heavier attribution wins tie" {
    const allocator = std.testing.allocator;
    // Node "n" has two competing neighbors with equal raw weight but
    // different attributions. n-x via extraction_classifier (1.0).
    // n-y via compose_memory (1.5). y SHOULD win the vote.
    //
    // We need x and y to be in DIFFERENT communities for the tie test
    // to mean anything; otherwise both share the same label and there's
    // no competition. Add a second connection to each: x-x_friend,
    // y-y_friend so x and y already lead distinct micro-clusters.
    const edges = [_]memory_root.CommunityEdge{
        .{ .source_key = "n", .target_key = "x", .weight = 1.0, .attribution = "extraction_classifier", .valid_from_unix = 0 },
        .{ .source_key = "n", .target_key = "y", .weight = 1.0, .attribution = "compose_memory", .valid_from_unix = 0 },
        // give x and y their own clusters so they have distinct labels
        // before n picks
        .{ .source_key = "x", .target_key = "x_friend", .weight = 5.0, .attribution = "compose_memory", .valid_from_unix = 0 },
        .{ .source_key = "y", .target_key = "y_friend", .weight = 5.0, .attribution = "compose_memory", .valid_from_unix = 0 },
    };
    var labels = try computeCommunityLeaders(allocator, &edges, .{});
    defer labels.deinit(allocator);

    // n votes: x_label gets 1.0 * 1.0 = 1.0; y_label gets 1.0 * 1.5 = 1.5
    // → n adopts y's label.
    const n_label = labels.get("n").?;
    const y_label = labels.get("y").?;
    try std.testing.expectEqualStrings(y_label, n_label);
}

test "computeCommunityLeaders — determinism (100 runs same output)" {
    const allocator = std.testing.allocator;
    const edges = [_]memory_root.CommunityEdge{
        .{ .source_key = "alice", .target_key = "bob", .weight = 1.0, .attribution = "extraction_classifier", .valid_from_unix = 0 },
        .{ .source_key = "bob", .target_key = "carol", .weight = 1.0, .attribution = "extraction_classifier", .valid_from_unix = 0 },
        .{ .source_key = "carol", .target_key = "alice", .weight = 1.0, .attribution = "extraction_classifier", .valid_from_unix = 0 },
        .{ .source_key = "dave", .target_key = "eve", .weight = 2.0, .attribution = "compose_memory", .valid_from_unix = 0 },
    };
    var first_run_labels: ?std.StringHashMapUnmanaged([]const u8) = null;
    defer if (first_run_labels) |*m| m.deinit(allocator);

    var run: usize = 0;
    while (run < 100) : (run += 1) {
        var labels = try computeCommunityLeaders(allocator, &edges, .{});
        defer labels.deinit(allocator);
        if (first_run_labels == null) {
            // Snapshot first run
            var snap: std.StringHashMapUnmanaged([]const u8) = .{};
            var it = labels.iterator();
            while (it.next()) |kv| try snap.put(allocator, kv.key_ptr.*, kv.value_ptr.*);
            first_run_labels = snap;
        } else {
            // Compare every key matches first run
            var it = labels.iterator();
            while (it.next()) |kv| {
                const ref = first_run_labels.?.get(kv.key_ptr.*).?;
                try std.testing.expectEqualStrings(ref, kv.value_ptr.*);
            }
        }
    }
}

test "computeVoteWeight — recency decay" {
    const edge = memory_root.CommunityEdge{
        .source_key = "a",
        .target_key = "b",
        .weight = 1.0,
        .attribution = "extraction_classifier",
        .valid_from_unix = 0,
    };
    const half_life: f64 = 100.0;
    // At now_unix=0 (or = valid_from), no decay → vote = weight × 1.0
    const w0 = computeVoteWeight(edge, .{ .now_unix = 0, .recency_half_life_secs = half_life });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), w0, 0.001);
    // At now_unix == half_life seconds elapsed → vote = 0.5
    const w_half = computeVoteWeight(edge, .{ .now_unix = 100, .recency_half_life_secs = half_life });
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), w_half, 0.001);
    // At 2× half-life → vote = 0.25
    const w_2hl = computeVoteWeight(edge, .{ .now_unix = 200, .recency_half_life_secs = half_life });
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), w_2hl, 0.001);
}

test "attributionMultiplier — known and unknown" {
    try std.testing.expectEqual(@as(f64, 1.5), attributionMultiplier("compose_memory"));
    try std.testing.expectEqual(@as(f64, 1.5), attributionMultiplier("agent_tool"));
    try std.testing.expectEqual(@as(f64, 1.0), attributionMultiplier("extraction_classifier"));
    try std.testing.expectEqual(@as(f64, 0.8), attributionMultiplier("unknown_source"));
    try std.testing.expectEqual(@as(f64, 0.8), attributionMultiplier(""));
}

test "computeCommunityLeaders — empty edge slice returns empty labels" {
    const allocator = std.testing.allocator;
    const edges: [0]memory_root.CommunityEdge = .{};
    var labels = try computeCommunityLeaders(allocator, &edges, .{});
    defer labels.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), labels.count());
}

test "computeCommunityLeaders — self-loops ignored" {
    const allocator = std.testing.allocator;
    const edges = [_]memory_root.CommunityEdge{
        .{ .source_key = "a", .target_key = "a", .weight = 100.0, .attribution = "compose_memory", .valid_from_unix = 0 },
        .{ .source_key = "a", .target_key = "b", .weight = 1.0, .attribution = "extraction_classifier", .valid_from_unix = 0 },
    };
    var labels = try computeCommunityLeaders(allocator, &edges, .{});
    defer labels.deinit(allocator);
    // Self-loop carries no info; a and b still merge on the real edge
    try std.testing.expectEqualStrings("a", labels.get("a").?);
    try std.testing.expectEqualStrings("a", labels.get("b").?);
}
