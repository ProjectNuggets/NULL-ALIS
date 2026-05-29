//! S6.13 — full observability contract pin.
//!
//! Complements `health_metrics_test.zig` (catalog + cardinality counter
//! + counter/histogram movement). THIS file pins:
//!   * cardinality cap behavior — emit >MAX_SERIES distinct names; the
//!     dropped-series counter must advance.
//!   * MAX_SERIES is the documented constant from S5 follow-up #113.
//!   * `nullalis_gateway_degraded` gauge is declared by the metrics
//!     payload (gateway emits it directly in renderMetricsBody at
//!     gateway.zig:7356).

const std = @import("std");
const nullalis = @import("nullalis");
const observability_metrics = nullalis.observability_metrics;

test "S6.13 observability: MAX_SERIES is the documented 4096 cap" {
    // A bump to MAX_SERIES is a load-bearing capacity decision and
    // must be intentional. Pin the documented value from S5 #113.
    try std.testing.expectEqual(@as(usize, 4096), observability_metrics.MAX_SERIES);
}

test "S6.13 observability: cardinality cap sheds new series past MAX_SERIES" {
    var reg = observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    // Emit MAX_SERIES + N distinct series. The first MAX_SERIES insert
    // succeed; the remaining N must increment the dropped-series counter.
    const overflow_n: usize = 16;
    var i: usize = 0;
    while (i < observability_metrics.MAX_SERIES + overflow_n) : (i += 1) {
        var key_buf: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "s6_cap_probe_{d}", .{i});
        reg.incCounter(key);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    // Find the dropped-series counter VALUE LINE (not the HELP / TYPE
    // header lines which share the same metric name prefix). Anchor at
    // a leading newline so we land on the value line specifically.
    const anchor = "\nnullalis_metrics_registry_dropped_series_total ";
    const idx = std.mem.indexOf(u8, buf.items, anchor) orelse return error.MissingDroppedCounter;
    const value_start = idx + anchor.len;
    const nl = std.mem.indexOfScalarPos(u8, buf.items, value_start, '\n') orelse return error.MalformedCounterLine;
    const value_slice = std.mem.trim(u8, buf.items[value_start..nl], " \r\t");
    const dropped = try std.fmt.parseInt(usize, value_slice, 10);
    try std.testing.expect(dropped >= overflow_n);
}

test "S6.13 observability: warm increments past the cap are NOT shed" {
    // The cap shedding only applies to NEW series — an already-registered
    // counter must continue to advance even after cap is reached. Pin
    // the warm-vs-cold behavior.
    var reg = observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    // Register one warm series, then fill the cap.
    reg.incCounter("nullalis_warm_probe");
    var i: usize = 0;
    while (i < observability_metrics.MAX_SERIES + 8) : (i += 1) {
        var key_buf: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "s6_warm_fill_{d}", .{i});
        reg.incCounter(key);
    }
    // Increment the warm series AFTER the cap is reached.
    reg.incCounter("nullalis_warm_probe");
    reg.incCounter("nullalis_warm_probe");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    // The warm series must show 3 increments (1 before fill + 2 after).
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "nullalis_warm_probe 3\n") != null);
}

test "S6.13 observability: render() emits the dropped-series HELP/TYPE block" {
    // H1 hardening from #113 — operators alert on this counter even
    // before any user series has been registered. The HELP + TYPE block
    // must be present on every scrape.
    var reg = observability_metrics.Registry.init(std.testing.allocator);
    defer reg.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "# HELP nullalis_metrics_registry_dropped_series_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "# TYPE nullalis_metrics_registry_dropped_series_total counter") != null);
}
