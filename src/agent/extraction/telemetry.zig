//! V1.14.9 P5 / R1 — Graph-density telemetry for boundary extraction.
//!
//! Direct response to the 2026-05-10 "entities=0 edges=0" failure
//! mode: we shipped V1.14.8 with zero observability on whether the
//! unified extractor was actually populating the graph. Tonight's
//! F5 rerun produced 199 questions of bench output before we knew
//! the graph layer was empty. That's the gap this module closes.
//!
//! Per-boundary metrics emitted as a single structured log line:
//!   boundary.metrics kind=session_end window_msgs=N window_bytes=B
//!                    episodes=E episodes_ok=Eo episodes_failed=Ef
//!                    entities=N edges=M edges_per_1k_tokens=R.RR
//!                    extraction_ms=T total_ms=Tt
//!
//! Alerts (emitted as warn so they grep-find easily):
//!   boundary.zero_density   — substantive window (>5K bytes) returned 0 edges
//!   boundary.episode_failure_high — >30% of episodes failed extraction

const std = @import("std");
const log = std.log.scoped(.extraction_telemetry);

pub const BoundaryKind = enum {
    pass_a,
    pass_c,
    session_end,
    other,

    pub fn name(self: BoundaryKind) []const u8 {
        return switch (self) {
            .pass_a => "pass_a",
            .pass_c => "pass_c",
            .session_end => "session_end",
            .other => "other",
        };
    }
};

pub const BoundaryMetrics = struct {
    kind: BoundaryKind,
    window_msg_count: u32,
    window_byte_total: u64,
    episodes_chunked: u32,
    episodes_extracted_success: u32,
    episodes_extracted_failed: u32,
    entities_extracted: u32,
    edges_extracted: u32,
    hydration_present: bool,
    extraction_ms_total: u64,
    hydration_ms: u64,

    /// edges per 1000 input tokens. ~0 on substantive sessions → R1
    /// alert. >100 = exceptionally dense (e.g., dense factual content).
    /// Token estimate uses chars/4.
    pub fn edgesPer1kTokens(self: BoundaryMetrics) f64 {
        const tokens = @as(f64, @floatFromInt(self.window_byte_total)) / 4.0;
        if (tokens < 1.0) return 0;
        return (@as(f64, @floatFromInt(self.edges_extracted)) * 1000.0) / tokens;
    }
};

/// Single entry point. Emits one info-level metrics line + 0-2 warns
/// for any tripped alerts. Failure-soft — logging errors swallowed.
pub fn recordBoundary(metrics: BoundaryMetrics) void {
    const density = metrics.edgesPer1kTokens();
    log.info(
        "boundary.metrics kind={s} window_msgs={d} window_bytes={d} episodes={d} episodes_ok={d} episodes_failed={d} entities={d} edges={d} edges_per_1k_tokens={d:.2} extraction_ms={d} hydration_ms={d}",
        .{
            metrics.kind.name(),
            metrics.window_msg_count,
            metrics.window_byte_total,
            metrics.episodes_chunked,
            metrics.episodes_extracted_success,
            metrics.episodes_extracted_failed,
            metrics.entities_extracted,
            metrics.edges_extracted,
            density,
            metrics.extraction_ms_total,
            metrics.hydration_ms,
        },
    );

    // Alert 1: substantive window with no edges — almost always an
    // extraction quality issue (wrong model, prompt failure, etc.).
    // Threshold 5KB ≈ 1.25K tokens — clearly enough content to expect
    // at least one fact. The window=0/edges=0 case is the failure
    // mode we lived through tonight; this catches it within the
    // first boundary fire next time.
    if (metrics.window_byte_total > 5_000 and metrics.edges_extracted == 0) {
        log.warn(
            "boundary.zero_density kind={s} window_bytes={d} episodes={d} — investigate extractor model + prompt",
            .{ metrics.kind.name(), metrics.window_byte_total, metrics.episodes_chunked },
        );
    }

    // Alert 2: high episode failure rate — indicates provider
    // contention, rate limits, or systemic LLM call problems. >30%
    // failure on a multi-episode boundary means the parallel path is
    // overloaded; downstream operator can dial concurrency back.
    if (metrics.episodes_chunked > 2) {
        const failure_pct = (@as(u64, metrics.episodes_extracted_failed) * 100) / metrics.episodes_chunked;
        if (failure_pct > 30) {
            log.warn(
                "boundary.episode_failure_high kind={s} failed={d}/{d} ({d}%) — provider contention or rate limit",
                .{ metrics.kind.name(), metrics.episodes_extracted_failed, metrics.episodes_chunked, failure_pct },
            );
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "edgesPer1kTokens computes density" {
    // 4000 bytes ≈ 1000 tokens, 10 edges → 10 edges per 1k
    const m = BoundaryMetrics{
        .kind = .session_end,
        .window_msg_count = 5,
        .window_byte_total = 4000,
        .episodes_chunked = 1,
        .episodes_extracted_success = 1,
        .episodes_extracted_failed = 0,
        .entities_extracted = 5,
        .edges_extracted = 10,
        .hydration_present = true,
        .extraction_ms_total = 0,
        .hydration_ms = 0,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), m.edgesPer1kTokens(), 0.01);
}

test "edgesPer1kTokens handles tiny windows safely" {
    const m = BoundaryMetrics{
        .kind = .session_end,
        .window_msg_count = 0,
        .window_byte_total = 0,
        .episodes_chunked = 0,
        .episodes_extracted_success = 0,
        .episodes_extracted_failed = 0,
        .entities_extracted = 0,
        .edges_extracted = 0,
        .hydration_present = false,
        .extraction_ms_total = 0,
        .hydration_ms = 0,
    };
    try std.testing.expectEqual(@as(f64, 0.0), m.edgesPer1kTokens());
}

test "recordBoundary does not crash on zero-density path" {
    // Triggers the zero_density alert (window > 5KB, edges = 0).
    const m = BoundaryMetrics{
        .kind = .session_end,
        .window_msg_count = 100,
        .window_byte_total = 12_000,
        .episodes_chunked = 3,
        .episodes_extracted_success = 3,
        .episodes_extracted_failed = 0,
        .entities_extracted = 0,
        .edges_extracted = 0,
        .hydration_present = true,
        .extraction_ms_total = 5000,
        .hydration_ms = 800,
    };
    recordBoundary(m); // Logs a warn — test passes if no crash.
}

test "recordBoundary does not crash on high failure rate" {
    const m = BoundaryMetrics{
        .kind = .pass_c,
        .window_msg_count = 100,
        .window_byte_total = 20_000,
        .episodes_chunked = 10,
        .episodes_extracted_success = 4,
        .episodes_extracted_failed = 6, // 60% failure
        .entities_extracted = 8,
        .edges_extracted = 5,
        .hydration_present = true,
        .extraction_ms_total = 30_000,
        .hydration_ms = 2_000,
    };
    recordBoundary(m); // Logs episode_failure_high warn.
}
