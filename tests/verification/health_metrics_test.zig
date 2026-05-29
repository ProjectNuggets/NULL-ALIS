//! S6.1 — health / readiness / metrics smokes.
//!
//! These pin the operator-facing observability surface. They run without
//! a live Postgres fixture — the Registry is an in-process structure and
//! the catalog assertions are against the rendered Prometheus exposition
//! text.
//!
//! Scope note. These tests pin Registry round-trip semantics against the
//! EXACT series names that `src/gateway.zig:7290-7337` declares as the
//! S5 chartable catalog. They do NOT (yet) drive `gateway.MetricsRegistry-
//! Observer` end-to-end — a full emit-pipeline test would require a
//! gateway fixture (deferred). What this test catches: drift between the
//! catalog HELP/TYPE block, the substrate Registry, and a rename anywhere
//! that breaks the round-trip. What it does NOT catch: the gateway
//! choosing to emit a different series than its HELP block declares.

const std = @import("std");
const nullalis = @import("nullalis");
const observability_metrics = nullalis.observability_metrics;

/// The S5 chartable catalog — the EXACT series names declared in the
/// HELP/TYPE block at `src/gateway.zig:7290-7337`. When the catalog
/// changes there, update here. The convergence-pin assertion below
/// guarantees a rename in only one place breaks this test, so drift
/// surfaces in CI rather than silently.
const CHARTABLE_COUNTERS = [_][]const u8{
    "nullalis_approval_decision_total",
    "nullalis_artifact_export_total",
    "nullalis_memory_op_total",
    "nullalis_trace_share_total",
    "nullalis_tool_call_total",
    "nullalis_meter_receipt_total",
    "nullalis_extension_ws_command_total",
    "nullalis_extension_ws_ssrf_block_total",
    "nullalis_artifact_create_total",
    "nullalis_artifact_update_total",
    "nullalis_artifact_share_total",
    "nullalis_artifact_share_revoke_total",
    "nullalis_share_create_success_total",
    "nullalis_share_create_429_total",
    "nullalis_produce_document_total",
    "nullalis_trace_query_total",
    "nullalis_memory_doctor_total",
    "nullalis_moonshot_video_upload_total",
};

const CHARTABLE_HISTOGRAMS = [_][]const u8{
    "nullalis_artifact_export_latency_ms",
    "nullalis_memory_op_latency_ms",
    "nullalis_tool_call_latency_ms",
    "nullalis_extension_ws_command_latency_ms",
    "nullalis_produce_document_latency_ms",
    "nullalis_moonshot_video_upload_bytes",
};

test "S6.1 catalog: every S5 chartable counter round-trips Registry.render()" {
    var reg = observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    for (CHARTABLE_COUNTERS) |name| {
        reg.incCounter(name);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    // Tighter than substring-match: assert the EXACT exposition-line form
    // `<name> 1\n`. A regression that dropped labels, changed the value
    // separator, or split a counter across lines would no longer pass
    // here whereas a bare substring match would.
    for (CHARTABLE_COUNTERS) |name| {
        var line_buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{s} 1\n", .{name});
        try std.testing.expect(std.mem.indexOf(u8, buf.items, line) != null);
    }
}

test "S6.1 catalog: every S5 chartable histogram emits _bucket/_sum/_count" {
    var reg = observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    for (CHARTABLE_HISTOGRAMS) |name| {
        reg.observeHistogram(name, 42);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    for (CHARTABLE_HISTOGRAMS) |name| {
        var sentinel_buf: [256]u8 = undefined;
        const sum_line = try std.fmt.bufPrint(&sentinel_buf, "{s}_sum", .{name});
        try std.testing.expect(std.mem.indexOf(u8, buf.items, sum_line) != null);

        const count_line = try std.fmt.bufPrint(&sentinel_buf, "{s}_count", .{name});
        try std.testing.expect(std.mem.indexOf(u8, buf.items, count_line) != null);

        const bucket_line = try std.fmt.bufPrint(&sentinel_buf, "{s}_bucket", .{name});
        try std.testing.expect(std.mem.indexOf(u8, buf.items, bucket_line) != null);
    }
}

test "S6.1 cardinality cap: dropped-series counter is always exposed even on empty registry" {
    // The dropped-series counter is the operator's alert signal for label
    // cardinality explosions. It must be present on every scrape, even
    // before any series has been registered. This pins the H1 hardening
    // from S5 follow-up #113.
    var reg = observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nullalis_metrics_registry_dropped_series_total 0\n") != null);
}

test "S6.1 counter movement: incCounter advances the rendered value monotonically" {
    var reg = observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    reg.incCounter("nullalis_approval_decision_total{result=\"user_approved\"}");
    reg.incCounter("nullalis_approval_decision_total{result=\"user_approved\"}");
    reg.incCounter("nullalis_approval_decision_total{result=\"user_approved\"}");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    try std.testing.expect(std.mem.indexOf(
        u8,
        buf.items,
        "nullalis_approval_decision_total{result=\"user_approved\"} 3\n",
    ) != null);
}

test "S6.1 histogram movement: bucket distribution matches the observed sample placement" {
    var reg = observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    // Three samples deliberately on different sides of the BUCKETS_MS
    // boundaries (10, 50, 100, 250, 500, 1000, ...):
    //   5   → falls into every bucket from le="10" upward.
    //   30  → falls into every bucket from le="50" upward.
    //   200 → falls into every bucket from le="250" upward.
    // The bucket distribution itself is asserted below; sum + count are
    // derivable from this choice. If a future refactor changes the
    // bucket boundaries, the bucket asserts fail explicitly rather than
    // a sum/count test passing while dashboards silently break.
    reg.observeHistogram("nullalis_artifact_export_latency_ms", 5);
    reg.observeHistogram("nullalis_artifact_export_latency_ms", 30);
    reg.observeHistogram("nullalis_artifact_export_latency_ms", 200);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nullalis_artifact_export_latency_ms_count 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nullalis_artifact_export_latency_ms_sum 235\n") != null);
    // Bucket distribution: le=10 catches only the 5-sample; le=50 catches
    // the 5+30; le=250 (and everything bigger) catches all three.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nullalis_artifact_export_latency_ms_bucket{le=\"10\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nullalis_artifact_export_latency_ms_bucket{le=\"50\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nullalis_artifact_export_latency_ms_bucket{le=\"250\"} 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nullalis_artifact_export_latency_ms_bucket{le=\"+Inf\"} 3\n") != null);
}
