//! Vector operations — cosine similarity and f32 vector serialization.
//!
//! Mirrors ZeroClaw's vector module for semantic search support.
//!
//! NOTE (v1.14.18, HYBRID-MERGE-DECISION): the legacy weighted-fusion
//! `hybridMerge` (plus its `ScoredResult` / `IdScore` types) was removed
//! here. It was fully superseded by Reciprocal Rank Fusion in
//! `retrieval/rrf.zig::rrfMerge`, which is the production fusion stage of
//! the documented pipeline (keyword → vector → RRF → min_relevance →
//! temporal_decay → MMR → LLM_rerank → limit, see `retrieval/llm_reranker.zig`).
//! `hybridMerge` had zero production callers — only its own tests and a
//! dead re-export in `memory/root.zig`.

const std = @import("std");

// ── Cosine similarity ─────────────────────────────────────────────

/// Cosine similarity between two vectors. Returns 0.0–1.0.
/// Returns 0.0 for empty, mismatched, or degenerate inputs.
pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len or a.len == 0) return 0.0;

    var dot: f64 = 0.0;
    var norm_a: f64 = 0.0;
    var norm_b: f64 = 0.0;

    for (a, b) |x_raw, y_raw| {
        const x: f64 = @floatCast(x_raw);
        const y: f64 = @floatCast(y_raw);
        dot += x * y;
        norm_a += x * x;
        norm_b += y * y;
    }

    const denom = @sqrt(norm_a) * @sqrt(norm_b);
    if (!std.math.isFinite(denom) or denom < std.math.floatEps(f64)) {
        return 0.0;
    }

    const raw = dot / denom;
    if (!std.math.isFinite(raw)) {
        return 0.0;
    }

    // Clamp to [0, 1] — embeddings are typically positive
    const clamped = @max(0.0, @min(1.0, raw));
    return @floatCast(clamped);
}

// ── Serialization ─────────────────────────────────────────────────

/// Serialize f32 vector to bytes (little-endian). Caller owns result.
pub fn vecToBytes(allocator: std.mem.Allocator, v: []const f32) ![]u8 {
    const bytes = try allocator.alloc(u8, v.len * 4);
    for (v, 0..) |f, i| {
        const le: [4]u8 = @bitCast(f);
        @memcpy(bytes[i * 4 ..][0..4], &le);
    }
    return bytes;
}

/// Deserialize bytes to f32 vector (little-endian). Caller owns result.
pub fn bytesToVec(allocator: std.mem.Allocator, bytes: []const u8) ![]f32 {
    const count = bytes.len / 4;
    const result = try allocator.alloc(f32, count);
    for (0..count) |i| {
        const chunk = bytes[i * 4 ..][0..4];
        result[i] = @bitCast(chunk.*);
    }
    return result;
}

// ── Tests ─────────────────────────────────────────────────────────

test "cosine identical vectors" {
    const v = [_]f32{ 1.0, 2.0, 3.0 };
    const sim = cosineSimilarity(&v, &v);
    try std.testing.expect(@abs(sim - 1.0) < 0.001);
}

test "cosine orthogonal vectors" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0 };
    const sim = cosineSimilarity(&a, &b);
    try std.testing.expect(@abs(sim) < 0.001);
}

test "cosine similar vectors" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 1.1, 2.1, 3.1 };
    const sim = cosineSimilarity(&a, &b);
    try std.testing.expect(sim > 0.99);
}

test "cosine empty returns zero" {
    const empty: []const f32 = &.{};
    try std.testing.expectEqual(@as(f32, 0.0), cosineSimilarity(empty, empty));
}

test "cosine mismatched lengths" {
    const a = [_]f32{1.0};
    const b = [_]f32{ 1.0, 2.0 };
    try std.testing.expectEqual(@as(f32, 0.0), cosineSimilarity(&a, &b));
}

test "cosine zero vector" {
    const a = [_]f32{ 0.0, 0.0, 0.0 };
    const b = [_]f32{ 1.0, 2.0, 3.0 };
    try std.testing.expectEqual(@as(f32, 0.0), cosineSimilarity(&a, &b));
}

test "cosine opposite vectors clamped to zero" {
    const a = [_]f32{ 1.0, 0.0 };
    const b = [_]f32{ -1.0, 0.0 };
    const sim = cosineSimilarity(&a, &b);
    try std.testing.expect(@abs(sim) < std.math.floatEps(f32));
}

test "cosine both zero vectors" {
    const a = [_]f32{ 0.0, 0.0 };
    const b = [_]f32{ 0.0, 0.0 };
    try std.testing.expect(@abs(cosineSimilarity(&a, &b)) < std.math.floatEps(f32));
}

test "cosine single element" {
    const a = [_]f32{5.0};
    const b = [_]f32{5.0};
    try std.testing.expect(@abs(cosineSimilarity(&a, &b) - 1.0) < 0.001);

    const c = [_]f32{-5.0};
    try std.testing.expect(@abs(cosineSimilarity(&a, &c)) < std.math.floatEps(f32));
}

test "vec bytes roundtrip" {
    const original = [_]f32{ 1.0, -2.5, 3.14, 0.0 };
    const bytes = try vecToBytes(std.testing.allocator, &original);
    defer std.testing.allocator.free(bytes);

    const restored = try bytesToVec(std.testing.allocator, bytes);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqual(@as(usize, 4), restored.len);
    for (original, restored) |a, b| {
        try std.testing.expect(@abs(a - b) < std.math.floatEps(f32));
    }
}

test "vec bytes empty" {
    const empty: []const f32 = &.{};
    const bytes = try vecToBytes(std.testing.allocator, empty);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);

    const restored = try bytesToVec(std.testing.allocator, bytes);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqual(@as(usize, 0), restored.len);
}

test "bytes to vec non-aligned truncates" {
    // 5 bytes -> only first 4 used (1 float), last byte dropped
    const bytes = [_]u8{ 0, 0, 0, 0, 0xFF };
    const result = try bytesToVec(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(@abs(result[0]) < std.math.floatEps(f32));
}

test "bytes to vec three bytes returns empty" {
    const bytes = [_]u8{ 1, 2, 3 };
    const result = try bytesToVec(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// ── R3 regression tests ───────────────────────────────────────────

test "cosine zero vector returns 0.0 r3" {
    const zero = [_]f32{ 0.0, 0.0, 0.0 };
    const other = [_]f32{ 1.0, 2.0, 3.0 };
    try std.testing.expectEqual(@as(f32, 0.0), cosineSimilarity(&zero, &other));
    try std.testing.expectEqual(@as(f32, 0.0), cosineSimilarity(&other, &zero));
    try std.testing.expectEqual(@as(f32, 0.0), cosineSimilarity(&zero, &zero));
}

test "cosine identical vectors returns 1.0 r3" {
    const v = [_]f32{ 0.5, -0.3, 0.8, 0.1 };
    const sim = cosineSimilarity(&v, &v);
    try std.testing.expect(@abs(sim - 1.0) < 0.0001);
}

test "cosine orthogonal vectors returns 0.0 r3" {
    const a = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 0.0, 1.0, 0.0 };
    const sim = cosineSimilarity(&a, &b);
    try std.testing.expect(@abs(sim) < 0.0001);
}

test "cosine NaN in vector returns 0.0 not NaN" {
    const a = [_]f32{ 1.0, std.math.nan(f32), 3.0 };
    const b = [_]f32{ 1.0, 2.0, 3.0 };
    const sim = cosineSimilarity(&a, &b);
    // Must not propagate NaN — should return 0.0
    try std.testing.expect(!std.math.isNan(sim));
    try std.testing.expectEqual(@as(f32, 0.0), sim);
}

test "cosine inf in vector returns 0.0" {
    const a = [_]f32{ std.math.inf(f32), 1.0 };
    const b = [_]f32{ 1.0, 1.0 };
    const sim = cosineSimilarity(&a, &b);
    try std.testing.expect(!std.math.isNan(sim));
    try std.testing.expectEqual(@as(f32, 0.0), sim);
}
