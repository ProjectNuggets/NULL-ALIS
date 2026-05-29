//! S6.1 — health / readiness / metrics smokes.
//!
//! These are the "does the operator-facing observability surface exist and
//! move correctly" pins. They run without a live Postgres fixture — the
//! Registry is an in-process structure and the catalog assertions are
//! against the rendered Prometheus exposition text.

const std = @import("std");
const nullalis = @import("nullalis");
const observability_metrics = nullalis.observability_metrics;

/// The S5 chartable metric series that `docs/operations/SLOs.md` §2 catalog
/// publishes. Touching one of every family below ensures `render()` emits a
/// line for it. The S5 follow-up (#113 D1) made the catalog and the
/// `metricsPayload()` emit sites converge — this test pins that convergence
/// so future drift fails CI rather than silently regressing.
const CHARTABLE_SERIES = [_][]const u8{
    "approvals_issued_total",
    "approvals_resolved_total",
    "artifact_export_total",
    "artifact_create_total",
    "artifact_update_total",
    "artifact_share_total",
    "artifact_revoke_total",
    "extension_ws_command_total",
    "memory_op_total",
    "trace_share_create_total",
    "trace_share_revoke_total",
};

test "S6.1 metrics catalog: every S5 chartable counter is emittable + present in render()" {
    var reg = observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    // Touch one of every chartable family. The label values are arbitrary —
    // we are pinning that the SERIES NAME survives a render(), not the
    // specific label.
    for (CHARTABLE_SERIES) |name| {
        reg.incCounter(name);
    }

    // Histogram families that ship in the S5 catalog.
    reg.observeHistogram("artifact_export_latency_ms{result=\"ok\"}", 42);
    reg.observeHistogram("extension_ws_command_latency_ms{result=\"ok\"}", 12);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    for (CHARTABLE_SERIES) |name| {
        if (std.mem.indexOf(u8, buf.items, name) == null) {
            std.debug.print("S6.1: missing chartable series in render(): {s}\n", .{name});
            return error.MissingMetricSeries;
        }
    }
    // Histogram sentinels — the `_bucket`, `_sum`, `_count` lines must all
    // appear once render() has snapshotted.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "artifact_export_latency_ms_bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "artifact_export_latency_ms_sum") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "artifact_export_latency_ms_count") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nullalis_metrics_registry_dropped_series_total") != null);
    // On a fresh registry the value must be 0.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nullalis_metrics_registry_dropped_series_total 0") != null);
}

test "S6.1 counter movement: incCounter advances the rendered value monotonically" {
    var reg = observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    reg.incCounter("approvals_issued_total");
    reg.incCounter("approvals_issued_total");
    reg.incCounter("approvals_issued_total");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    // Look for the exposition line `approvals_issued_total 3`.
    const target = "approvals_issued_total 3";
    if (std.mem.indexOf(u8, buf.items, target) == null) {
        std.debug.print("S6.1: counter did not advance to 3.\nrender():\n{s}\n", .{buf.items});
        return error.CounterMovementBroken;
    }
}

test "S6.1 histogram movement: observeHistogram emits _bucket/_sum/_count with correct count" {
    var reg = observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    reg.observeHistogram("artifact_export_latency_ms", 5);
    reg.observeHistogram("artifact_export_latency_ms", 30);
    reg.observeHistogram("artifact_export_latency_ms", 200);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    // Three samples → _count must be 3 and _sum must be 235.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "artifact_export_latency_ms_count 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "artifact_export_latency_ms_sum 235") != null);
}
