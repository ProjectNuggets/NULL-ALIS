//! V1.6 commit 4 — Importance scoring (M1 from spec §4.3).
//!
//! Computes a 0..1 score for each memory that drives node sizing on the
//! /brain/graph FE. Larger value = more important = bigger node.
//!
//! Formula (V1 — kept simple; V1.7 may refine):
//!
//!   importance = 0.5 * recency_decay(created_at, half_life=30d)
//!              + 0.5 * normalized(edge_count, scale=8)
//!
//! Why this formula for V1:
//!   - recency_decay: a memory the user added recently is more relevant
//!     to their current mental model. exp(-(now - ts) / half_life) is the
//!     standard half-life curve. 30-day half-life means a 30-day-old
//!     memory contributes half what a fresh one does.
//!   - edge_count: a memory connected to many other memories is a hub
//!     in the user's brain — naturally more important. Normalized via
//!     sigmoid-ish saturation (1 - 1/(1 + edge_count/scale)) so a node
//!     with 0 edges gets 0, a node with 8 edges gets ~0.5, and the
//!     curve flattens above ~30 edges.
//!
//! Components NOT yet included in V1 (gap analysis):
//!   - confidence_score: column exists but no writer populates it as of
//!     V1.6 commit 4. V1.6 commit 5 (extraction) emits it. After that
//!     lands, V1.7 can extend the formula.
//!   - access_count: column exists, bumped on every getMemory hit.
//!     Not used here because /brain/graph doesn't trigger access bumps,
//!     so two equally-important memories would diverge based on agent-
//!     retrieval flux. Defer.
//!
//! All weights sum to 1.0; output is bounded in [0, 1].

const std = @import("std");

/// Half-life for recency decay, in seconds. 30 days = 30 * 86400.
pub const RECENCY_HALF_LIFE_SECONDS: f64 = 30.0 * 86400.0;

/// Edge-count scale for sigmoid-ish saturation. A node with this many
/// edges gets ~0.5 on the edge-count component; doubling edges past
/// this point produces diminishing returns.
pub const EDGE_COUNT_SCALE: f64 = 8.0;

/// Pure recency decay: 1.0 at created_at == now, falling off
/// exponentially with half-life RECENCY_HALF_LIFE_SECONDS.
///
/// Future timestamps clamp to 1.0 (treat as "just created"). Negative
/// ages can occur briefly when system clocks differ between writer and
/// reader; the test pins this behavior.
pub fn recencyDecay(created_at: i64, now: i64) f64 {
    const age_seconds: f64 = @floatFromInt(@max(0, now - created_at));
    // exp(-age * ln(2) / half_life) — standard half-life curve
    return std.math.exp(-age_seconds * std.math.ln2 / RECENCY_HALF_LIFE_SECONDS);
}

/// Edge-count saturation: 0 → 0, EDGE_COUNT_SCALE → 0.5, large → ~1.
/// Formula: 1 - 1/(1 + n/scale) — equivalent to n/(n+scale).
pub fn edgeCountNormalized(edge_count: usize) f64 {
    const n: f64 = @floatFromInt(edge_count);
    return n / (n + EDGE_COUNT_SCALE);
}

/// Composite importance score in [0, 1].
pub fn computeImportance(created_at: i64, now: i64, edge_count: usize) f64 {
    const recency = recencyDecay(created_at, now);
    const edges = edgeCountNormalized(edge_count);
    return 0.5 * recency + 0.5 * edges;
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "recencyDecay 1.0 at now, ~0.5 at half-life, ~0.0 at age >> half-life" {
    const now: i64 = 1_777_700_000;

    // At now (age 0), decay = 1.0
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), recencyDecay(now, now), 1e-6);

    // At one half-life ago (30 days), decay = 0.5
    const one_hl_ago = now - 30 * 86400;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), recencyDecay(one_hl_ago, now), 1e-6);

    // At three half-lives ago (90 days), decay = 0.125
    const three_hl_ago = now - 90 * 86400;
    try std.testing.expectApproxEqAbs(@as(f64, 0.125), recencyDecay(three_hl_ago, now), 1e-6);

    // Future timestamps clamp to 1.0 (clock skew tolerance)
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), recencyDecay(now + 100, now), 1e-6);
}

test "edgeCountNormalized monotonic + saturating" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), edgeCountNormalized(0), 1e-9);
    // At scale (8 edges), exactly 0.5
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), edgeCountNormalized(8), 1e-9);
    // At 4x scale, ~0.8
    try std.testing.expectApproxEqAbs(@as(f64, 32.0 / 40.0), edgeCountNormalized(32), 1e-9);
    // Monotonic
    try std.testing.expect(edgeCountNormalized(1) < edgeCountNormalized(2));
    try std.testing.expect(edgeCountNormalized(50) < edgeCountNormalized(100));
    // Bounded under 1
    try std.testing.expect(edgeCountNormalized(10_000) < 1.0);
}

test "computeImportance ranks fresh+connected over old+isolated" {
    const now: i64 = 1_777_700_000;
    const fresh_connected = computeImportance(now, now, 10);
    const old_isolated = computeImportance(now - 90 * 86400, now, 0);
    try std.testing.expect(fresh_connected > old_isolated);

    // Output bounded
    try std.testing.expect(computeImportance(now, now, 100) < 1.0);
    try std.testing.expect(computeImportance(now - 365 * 86400, now, 0) >= 0.0);
}

test "computeImportance equal-recency rank reflects edge count" {
    const now: i64 = 1_777_700_000;
    const isolated = computeImportance(now, now, 0);
    const hub = computeImportance(now, now, 20);
    try std.testing.expect(hub > isolated);
}
