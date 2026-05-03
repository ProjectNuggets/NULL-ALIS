//! V1.7a-9c — Community pipeline: orchestrates LPA + assignment + naming.
//!
//! End-to-end recompute for a single user's communities. Combines:
//!   1. Pull edges  → state_mgr.listMemoryEdgesForCommunityCompute
//!   2. Run LPA    → communities.computeCommunityLeaders
//!   3. Group by leader → top-K importance per community
//!   4. Stable ID  → FNV hash of sorted top-K member keys → i32
//!   5. Write IDs  → state_mgr.setMemoryCommunityIds (batch)
//!   6. Name each  → optional LLM namer callback OR fallback "Cluster N"
//!
//! ## LLM-naming as injectable callback
//!
//! The pipeline takes an OPTIONAL `LlmNamer` — a struct holding a context
//! pointer + function pointer. When provided, the pipeline calls it with
//! the top-K member content snippets and gets back a name. When null
//! (tests, no-provider builds, V1 cold-start), every community gets a
//! fallback name "Cluster <id>". V1.7a-9d wires the concrete callback
//! that calls the agent's LLM provider.
//!
//! Why a callback (not a hard import of providers/root.zig):
//!   * Pipeline stays testable WITHOUT provider mock plumbing.
//!   * Pipeline doesn't grow a dependency on the (heavy) providers module.
//!   * 9d's endpoint owns provider selection; the pipeline owns the
//!     naming protocol (top-K members → name string).
//!
//! ## Stable community_id
//!
//! Per V1.7a-9 plan D4: same logical community → same id across recomputes.
//! Implementation: FNV-1a 32-bit hash of sorted top-K-by-importance
//! member keys, joined with '\n'. Same membership → same hash → same ID.
//! Membership churn (top-K changes) yields a new ID — the previous
//! community's name in memory_communities is stale but harmless (LEFT
//! JOIN in listCommunities drops 0-member rows from member_count).
//!
//! ## Cost
//!
//! O(LPA) + O(N log N) sort + O(C × K × LLM_call). For typical V1
//! corpora (≤500 nodes, ≤2000 edges, 5-20 communities): ~50ms LPA +
//! ~1s LLM (when present, parallelizable in future). Bounded by
//! `RecomputeConfig.max_llm_calls` to cap cost.

const std = @import("std");
const log = std.log.scoped(.community_pipeline);

const memory_root = @import("../memory/root.zig");
const zaki_state = @import("../zaki_state.zig");
const communities = @import("communities.zig");
const importance = @import("../memory/importance.zig");

/// One member of a community used as input to the LLM namer.
/// `key` and `content` are owned by `getMemoriesByKeys` results upstream;
/// the LlmNamer must NOT free them.
pub const NamerMember = struct {
    key: []const u8,
    content: []const u8,
    importance: f64,
};

/// Opaque LLM-naming callback. When supplied to recomputeCommunitiesForUser,
/// the pipeline invokes `name_fn(ctx, members, allocator) → name` for each
/// community whose member-set hash differs from the cached one.
///
/// `name_fn` returns an OWNED slice (allocator passed in); pipeline frees
/// after writing to PG. On error, pipeline falls back to "Cluster N".
pub const LlmNamer = struct {
    ctx: *anyopaque,
    name_fn: *const fn (ctx: *anyopaque, members: []const NamerMember, allocator: std.mem.Allocator) anyerror![]u8,

    pub fn invoke(self: LlmNamer, members: []const NamerMember, allocator: std.mem.Allocator) anyerror![]u8 {
        return self.name_fn(self.ctx, members, allocator);
    }
};

pub const RecomputeConfig = struct {
    /// LPA convergence cap (forwarded to communities.LpaConfig).
    max_iterations: u8 = 10,
    /// Top-K members used for stable-ID hashing AND LLM naming.
    /// Smaller = more sensitive to membership churn (id changes more often);
    /// larger = more stable but blunter snapshot.
    top_k_members: usize = 5,
    /// Communities below this size are still assigned an id but skip LLM
    /// naming (fallback "Cluster N"). 1-member communities are very small
    /// orphan-like clusters; LLM-naming them is wasteful.
    min_size_for_llm_name: usize = 2,
    /// Cap LLM calls per recompute. Once exceeded, remaining communities
    /// get fallback names. Cost guard.
    max_llm_calls: u32 = 50,
    /// Recency half-life forwarded to LPA + importance scoring.
    recency_half_life_seconds: f64 = 60.0 * 86400.0,
    /// Reference "now" for recency. Production: std.time.timestamp().
    /// Tests pass fixed value for determinism.
    now_unix: i64 = 0,
};

pub const RecomputeStats = struct {
    edges_loaded: usize = 0,
    nodes_in_lpa: usize = 0,
    communities_found: usize = 0,
    members_assigned: usize = 0,
    llm_calls_succeeded: u32 = 0,
    llm_calls_failed: u32 = 0,
    fallback_names_written: u32 = 0,
};

/// Run the full recompute for one user. See module docstring for
/// pipeline shape. Idempotent: re-running on unchanged corpus produces
/// the same community_ids + names.
///
/// Returns RecomputeStats on success. On a top-level error (e.g. PG
/// unreachable) bubbles the error; partial communities are NOT rolled
/// back (per-community writes are independent and idempotent — next
/// recompute heals).
pub fn recomputeCommunitiesForUser(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
    user_id: i64,
    namer: ?LlmNamer,
    config: RecomputeConfig,
) !RecomputeStats {
    var stats: RecomputeStats = .{};

    // ── 1. Pull edges ──────────────────────────────────────────────
    const edges = try state_mgr.listMemoryEdgesForCommunityCompute(allocator, user_id);
    defer memory_root.freeCommunityEdges(allocator, edges);
    stats.edges_loaded = edges.len;
    if (edges.len == 0) {
        log.info("communities.recompute user={d} no_edges → no_op", .{user_id});
        return stats;
    }

    // ── 2. Run LPA ────────────────────────────────────────────────
    var labels = try communities.computeCommunityLeaders(allocator, edges, .{
        .max_iterations = config.max_iterations,
        .recency_half_life_seconds = config.recency_half_life_seconds,
        .now_unix = config.now_unix,
    });
    defer labels.deinit(allocator);
    stats.nodes_in_lpa = labels.count();
    if (labels.count() == 0) return stats;

    // ── 3. Group nodes by leader ──────────────────────────────────
    // leader_to_members: leader_key → list of member keys (borrowed from
    // labels' keys, which borrow from edges).
    var leader_to_members: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .{};
    defer {
        var it = leader_to_members.iterator();
        while (it.next()) |kv| kv.value_ptr.*.deinit(allocator);
        leader_to_members.deinit(allocator);
    }
    {
        var it = labels.iterator();
        while (it.next()) |kv| {
            const member_key = kv.key_ptr.*;
            const leader_key = kv.value_ptr.*;
            const gop = try leader_to_members.getOrPut(allocator, leader_key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.*.append(allocator, member_key);
        }
    }
    stats.communities_found = leader_to_members.count();

    // ── 4. Materialize member rows for importance scoring + naming ─
    // One batched fetch covers ALL members across ALL communities.
    var all_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_keys.deinit(allocator);
    {
        var it = labels.keyIterator();
        while (it.next()) |k| try all_keys.append(allocator, k.*);
    }
    const member_rows = try state_mgr.getMemoriesByKeys(allocator, user_id, all_keys.items);
    defer memory_root.freeEntries(allocator, member_rows);

    // Index by key for O(1) lookup during naming + importance.
    var rows_by_key: std.StringHashMapUnmanaged(*const memory_root.MemoryEntry) = .{};
    defer rows_by_key.deinit(allocator);
    for (member_rows) |*r| try rows_by_key.put(allocator, r.key, r);

    // ── 5. For each community: stable_id + write assignments + name ─
    var llm_calls_made: u32 = 0;
    var assignments_buf: std.ArrayListUnmanaged(memory_root.CommunityAssignment) = .empty;
    defer assignments_buf.deinit(allocator);

    var ci = leader_to_members.iterator();
    while (ci.next()) |kv| {
        const members = kv.value_ptr.*.items;
        if (members.len == 0) continue;

        // Top-K members by importance (recency × edge_count). edge_count
        // approximated by counting how many community edges touch the key
        // — cheaper than another PG round trip.
        const top_k = try selectTopKByImportance(
            allocator,
            members,
            rows_by_key,
            edges,
            config.top_k_members,
            config.now_unix,
            config.recency_half_life_seconds,
        );
        defer allocator.free(top_k);

        const stable_id = computeStableCommunityId(top_k);

        // Queue assignments (batch-write at the end)
        for (members) |mk| {
            try assignments_buf.append(allocator, .{ .key = mk, .community_id = stable_id });
            stats.members_assigned += 1;
        }

        // Compute member_set_hash for cache check
        const set_hash = try computeMemberSetHash(allocator, top_k);
        defer allocator.free(set_hash);

        // Cache lookup: re-name only when membership changed
        const cached = try state_mgr.getCommunityName(allocator, user_id, stable_id);
        defer if (cached) |c| c.deinit(allocator);
        const needs_naming = if (cached) |c|
            !std.mem.eql(u8, c.member_set_hash, set_hash)
        else
            true;

        if (!needs_naming) continue;

        // Build NamerMember snapshot for LLM
        var namer_members = try allocator.alloc(NamerMember, top_k.len);
        defer allocator.free(namer_members);
        for (top_k, 0..) |k, i| {
            const row = rows_by_key.get(k);
            namer_members[i] = .{
                .key = k,
                .content = if (row) |r| r.content else k, // fallback: use key when row missing
                .importance = if (row) |r|
                    importance.computeImportance(
                        std.fmt.parseInt(i64, r.timestamp, 10) catch 0,
                        config.now_unix,
                        countEdgesForKey(k, edges),
                    )
                else
                    0.0,
            };
        }

        // Try LLM if available + budget allows + community big enough
        var name_owned: ?[]u8 = null;
        var name_source: []const u8 = "fallback";
        if (namer != null and members.len >= config.min_size_for_llm_name and llm_calls_made < config.max_llm_calls) {
            llm_calls_made += 1;
            if (namer.?.invoke(namer_members, allocator)) |n| {
                name_owned = n;
                name_source = "llm";
                stats.llm_calls_succeeded += 1;
            } else |err| {
                log.warn("communities.llm_name failed user={d} community={d} err={s} → fallback", .{
                    user_id, stable_id, @errorName(err),
                });
                stats.llm_calls_failed += 1;
            }
        }
        if (name_owned == null) {
            name_owned = try std.fmt.allocPrint(allocator, "Cluster {d}", .{stable_id});
            stats.fallback_names_written += 1;
        }
        defer if (name_owned) |n| allocator.free(n);

        try state_mgr.setCommunityName(
            user_id,
            stable_id,
            name_owned.?,
            name_source,
            @intCast(members.len),
            set_hash,
        );
    }

    // ── 6. Batch-write community_id assignments ───────────────────
    if (assignments_buf.items.len > 0) {
        try state_mgr.setMemoryCommunityIds(user_id, assignments_buf.items);
    }

    log.info("communities.recompute user={d} edges={d} nodes={d} comms={d} llm_ok={d} llm_fail={d} fallback={d}", .{
        user_id, stats.edges_loaded, stats.nodes_in_lpa, stats.communities_found,
        stats.llm_calls_succeeded, stats.llm_calls_failed, stats.fallback_names_written,
    });
    return stats;
}

/// Count how many community edges touch this key. Cheap proxy for
/// graph-degree centrality (the V1.6 cmt4 importance-score input).
fn countEdgesForKey(key: []const u8, edges: []const memory_root.CommunityEdge) usize {
    var n: usize = 0;
    for (edges) |e| {
        if (std.mem.eql(u8, e.source_key, key) or std.mem.eql(u8, e.target_key, key)) n += 1;
    }
    return n;
}

/// Pick top-K members by computed importance. Returns owned slice of
/// borrowed key pointers; caller frees the slice (NOT the keys).
fn selectTopKByImportance(
    allocator: std.mem.Allocator,
    members: []const []const u8,
    rows_by_key: std.StringHashMapUnmanaged(*const memory_root.MemoryEntry),
    edges: []const memory_root.CommunityEdge,
    k: usize,
    now: i64,
    _: f64, // recency_half_life — importance.computeImportance has its own constant; reserved for future tuning
) ![][]const u8 {
    // Pair members with their importance scores
    const Scored = struct { key: []const u8, score: f64 };
    var scored = try allocator.alloc(Scored, members.len);
    defer allocator.free(scored);
    for (members, 0..) |mk, i| {
        const row = rows_by_key.get(mk);
        const created_at: i64 = if (row) |r| std.fmt.parseInt(i64, r.timestamp, 10) catch 0 else 0;
        const deg = countEdgesForKey(mk, edges);
        scored[i] = .{
            .key = mk,
            .score = importance.computeImportance(created_at, now, deg),
        };
    }
    std.mem.sort(Scored, scored, {}, struct {
        fn gt(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            // Deterministic tie-break: lowest-string key wins
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.gt);

    const take = @min(k, scored.len);
    const out = try allocator.alloc([]const u8, take);
    for (scored[0..take], 0..) |s, i| out[i] = s.key;
    return out;
}

/// Stable community_id: FNV-1a 32-bit hash of sorted top-K member keys
/// joined with '\n'. Same top-K → same id across recomputes (assuming
/// the K most-important members are stable). Member-set churn yields
/// a new id — old community's name is left in memory_communities until
/// listCommunities filters on member_count > 0.
///
/// Returns a non-zero i32 (we mask the high bit so values stay positive
/// and never collide with PG NULL semantics on integer-equality checks).
fn computeStableCommunityId(top_k_keys: []const []const u8) i32 {
    var hash: u32 = 2166136261; // FNV-1a 32-bit offset basis
    const FNV_PRIME: u32 = 16777619;
    // top_k_keys is already in importance-sorted order; sort by key for
    // stability across runs that produced the same set in different
    // importance order (rare but possible with score ties).
    var sorted_buf: [128][]const u8 = undefined;
    const n = @min(top_k_keys.len, sorted_buf.len);
    for (top_k_keys[0..n], 0..) |k, i| sorted_buf[i] = k;
    std.mem.sort([]const u8, sorted_buf[0..n], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (sorted_buf[0..n]) |k| {
        for (k) |b| {
            hash ^= b;
            hash *%= FNV_PRIME;
        }
        hash ^= '\n';
        hash *%= FNV_PRIME;
    }
    // Mask high bit → guarantee positive i32, and OR with 1 to skip 0
    // (so we never collide with the "unassigned" NULL state in PG).
    const masked: u32 = (hash & 0x7FFFFFFF) | 1;
    return @intCast(masked);
}

/// Hex-encoded FNV hash of the sorted top-K key set, used as the
/// LLM-name cache key. Different from the community_id (which is a
/// 31-bit int) — this is a string for direct PG storage in the
/// `member_set_hash` column.
fn computeMemberSetHash(allocator: std.mem.Allocator, top_k_keys: []const []const u8) ![]u8 {
    const id = computeStableCommunityId(top_k_keys);
    return std.fmt.allocPrint(allocator, "fnv32:{x:0>8}", .{@as(u32, @intCast(id))});
}

// ── Tests ───────────────────────────────────────────────────────────────

test "computeStableCommunityId — same input produces same id" {
    const keys_a = [_][]const u8{ "a", "b", "c" };
    const keys_b = [_][]const u8{ "a", "b", "c" };
    try std.testing.expectEqual(
        computeStableCommunityId(&keys_a),
        computeStableCommunityId(&keys_b),
    );
}

test "computeStableCommunityId — order-independent (same SET → same id)" {
    const ordered = [_][]const u8{ "a", "b", "c" };
    const reordered = [_][]const u8{ "c", "a", "b" };
    try std.testing.expectEqual(
        computeStableCommunityId(&ordered),
        computeStableCommunityId(&reordered),
    );
}

test "computeStableCommunityId — different sets produce different ids" {
    const set_a = [_][]const u8{ "a", "b", "c" };
    const set_b = [_][]const u8{ "a", "b", "d" };
    try std.testing.expect(computeStableCommunityId(&set_a) != computeStableCommunityId(&set_b));
}

test "computeStableCommunityId — always positive + non-zero" {
    // Stress with diverse inputs to make sure mask + |1 produces valid
    // i32 (no negative + no zero collision with PG NULL).
    const inputs = [_][]const []const u8{
        &.{"single"},
        &.{ "alpha", "beta" },
        &.{ "lots", "of", "different", "keys", "here" },
        &.{""},
    };
    for (inputs) |input| {
        const id = computeStableCommunityId(input);
        try std.testing.expect(id > 0);
    }
}

test "computeMemberSetHash — round-trip format" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{ "a", "b" };
    const h = try computeMemberSetHash(allocator, &keys);
    defer allocator.free(h);
    try std.testing.expect(std.mem.startsWith(u8, h, "fnv32:"));
    try std.testing.expectEqual(@as(usize, "fnv32:".len + 8), h.len);
}

test "countEdgesForKey — counts incident edges" {
    const edges = [_]memory_root.CommunityEdge{
        .{ .source_key = "a", .target_key = "b", .weight = 1, .attribution = "extraction_classifier", .valid_from_unix = 0 },
        .{ .source_key = "b", .target_key = "c", .weight = 1, .attribution = "extraction_classifier", .valid_from_unix = 0 },
        .{ .source_key = "c", .target_key = "a", .weight = 1, .attribution = "extraction_classifier", .valid_from_unix = 0 },
    };
    try std.testing.expectEqual(@as(usize, 2), countEdgesForKey("a", &edges));
    try std.testing.expectEqual(@as(usize, 2), countEdgesForKey("b", &edges));
    try std.testing.expectEqual(@as(usize, 2), countEdgesForKey("c", &edges));
    try std.testing.expectEqual(@as(usize, 0), countEdgesForKey("x", &edges));
}
