//! Process-wide Prometheus-counter/histogram registry for the S5
//! chartable signals (approvals, artifact_export, extension_command,
//! memory_op, trace_share, tool_call, meter_receipt).
//!
//! Design:
//!   - Single hashmap keyed by full Prometheus line key
//!     (`name{label="value",...}`). Atomic u64 per series.
//!   - Bucket boundaries are fixed across all latency families to
//!     keep the alert PromQL uniform (10, 50, 100, 250, 500, 1000,
//!     2500, 5000, 10000 ms + +Inf).
//!   - Per family we also keep `_sum_ms` (for averages) and `_count`
//!     (sample count) atomics.
//!
//! Thread-safety:
//!   - `incCounter` warm path (slot exists) takes the mutex only for
//!     the hashmap lookup; the +1 is a lock-free atomic add on the
//!     stable Counter pointer. Cold path (first sample of a series)
//!     initializes the new Counter with `.raw = 1` and commits it
//!     under the lock — so a concurrent `render()` sees either no
//!     entry or `name 1`, never `name 0`. (S5 review-fix F6.)
//!   - `observeHistogram` takes the mutex through the entire update
//!     (sum_ms, count, bucket_counts all bumped under the lock). This
//!     is stricter than the original "warm path is lock-free" design
//!     because a torn snapshot between the three atomic adds could
//!     show `sum > 0, count = 0` — NaN in PromQL averages. The mutex
//!     critical section is short (hashmap lookup + 12 atomic adds);
//!     contention is bounded. (S5 review-fix F5.)
//!   - `render()` takes the lock for the duration of a snapshot.
//!   - `deinit()` takes the lock for the duration of teardown. This
//!     blocks late emit-site callers until the maps are freed; the
//!     gateway-level shutdown protocol detaches the global observer
//!     and sleeps a brief grace period BEFORE calling deinit so the
//!     late-caller window stays bounded. (S5 review-fix F4 — see
//!     `GatewayState.deinit` in src/gateway.zig.)

const std = @import("std");

pub const BUCKETS_MS: [10]u64 = .{ 10, 50, 100, 250, 500, 1000, 2500, 5000, 10000, std.math.maxInt(u64) };
pub const BUCKET_LABELS: [10][]const u8 = .{ "10", "50", "100", "250", "500", "1000", "2500", "5000", "10000", "+Inf" };

const Counter = struct { value: std.atomic.Value(u64) };

const Histogram = struct {
    bucket_counts: [10]std.atomic.Value(u64),
    sum_ms: std.atomic.Value(u64),
    count: std.atomic.Value(u64),
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    counters: std.StringHashMapUnmanaged(*Counter) = .{},
    histograms: std.StringHashMapUnmanaged(*Histogram) = .{},

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        // S5 review-fix F4 (2026-05-29) — hold the registry mutex for
        // the full teardown so a concurrent incCounter/observeHistogram/
        // render is guaranteed to either:
        //   (a) finish its critical section BEFORE this lock acquires
        //       (and write into the still-valid hashmap), or
        //   (b) block on `self.mutex.lock()` until teardown completes.
        //
        // Case (b) is still a use-after-free in absolute terms — the
        // Registry struct itself is freed by the caller after deinit
        // returns, and the late thread will lock a freed mutex. The
        // gateway-level shutdown protocol mitigates this by:
        //   1. Detaching the global observer via setGlobalObserver(null),
        //   2. Sleeping ~10ms for in-flight emits to drain,
        //   3. Clearing the global registry pointer,
        //   4. THEN calling this deinit + freeing the registry.
        // See GatewayState.deinit for the full shutdown sequence.
        self.mutex.lock();
        defer self.mutex.unlock();
        var c_it = self.counters.iterator();
        while (c_it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.destroy(e.value_ptr.*);
        }
        self.counters.deinit(self.allocator);
        var h_it = self.histograms.iterator();
        while (h_it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.destroy(e.value_ptr.*);
        }
        self.histograms.deinit(self.allocator);
    }

    /// Increment counter `series_key`. Silently drops the sample on
    /// allocator failure (registry inserts are unbounded; OOM here is
    /// fatal-class — we prefer to keep emitting on warm series over
    /// crashing the runtime).
    ///
    /// S5 review-fix F6 (2026-05-29) — the first-sample-of-new-counter
    /// case is now atomic with the insert. Previously the inserted
    /// Counter was initialized to `.raw = 0` and the `+1` happened
    /// outside the lock, so a render() between insert and fetchAdd
    /// would emit `name 0` instead of `name 1`. The cold path now
    /// initializes the new Counter with `.value = .{ .raw = 1 }` and
    /// commits it under the lock — no post-lock fetchAdd on the insert
    /// path. The warm path (slot already exists) still does the
    /// fetchAdd, but it is safe to do so outside the lock because the
    /// existing pointer is stable for the registry's lifetime.
    pub fn incCounter(self: *Registry, series_key: []const u8) void {
        const warm: ?*Counter = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.counters.get(series_key)) |existing| break :blk existing;
            // Cold path — insert with value=1 already counted. The
            // first sample is committed atomically with the insert,
            // so a concurrent render() either sees no entry or sees
            // `name 1`, never `name 0`.
            const owned_key = self.allocator.dupe(u8, series_key) catch break :blk null;
            const new_c = self.allocator.create(Counter) catch {
                self.allocator.free(owned_key);
                break :blk null;
            };
            new_c.* = .{ .value = .{ .raw = 1 } };
            self.counters.put(self.allocator, owned_key, new_c) catch {
                self.allocator.free(owned_key);
                self.allocator.destroy(new_c);
                break :blk null;
            };
            break :blk null; // cold path returns; do NOT fetchAdd below.
        };
        if (warm) |c| _ = c.value.fetchAdd(1, .monotonic);
    }

    /// Record one sample into histogram family `family_key`. Silently
    /// drops the sample on allocator failure (same rationale as
    /// incCounter).
    ///
    /// S5 review-fix F5 (2026-05-29) — the entire (sum, count, bucket)
    /// update happens under `self.mutex`. Previously the lookup-or-
    /// insert was guarded but the three fetchAdds happened lock-free,
    /// so a render() interleaved between them could observe
    /// `sum > 0, count = 0` (NaN in PromQL averages, broken histogram
    /// quantiles). The mutex critical section here is short (hashmap
    /// lookup + 12 atomic adds), so contention is bounded.
    ///
    /// First-sample insert (F6 analog): when we create the Histogram
    /// here, we initialize sum_ms / count / appropriate bucket_counts
    /// to reflect THIS sample, then we DO NOT issue post-lock fetchAdds
    /// on the insert path. The warm path (slot already existed) still
    /// does the fetchAdds, but under the same locked critical section.
    pub fn observeHistogram(self: *Registry, family_key: []const u8, value_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.histograms.get(family_key)) |existing| {
            _ = existing.sum_ms.fetchAdd(value_ms, .monotonic);
            _ = existing.count.fetchAdd(1, .monotonic);
            for (BUCKETS_MS, 0..) |bound, i| {
                if (value_ms <= bound) {
                    _ = existing.bucket_counts[i].fetchAdd(1, .monotonic);
                }
            }
            return;
        }
        const owned_key = self.allocator.dupe(u8, family_key) catch return;
        const new_h = self.allocator.create(Histogram) catch {
            self.allocator.free(owned_key);
            return;
        };
        new_h.* = .{
            .bucket_counts = .{
                .{ .raw = 0 }, .{ .raw = 0 }, .{ .raw = 0 }, .{ .raw = 0 }, .{ .raw = 0 },
                .{ .raw = 0 }, .{ .raw = 0 }, .{ .raw = 0 }, .{ .raw = 0 }, .{ .raw = 0 },
            },
            .sum_ms = .{ .raw = value_ms },
            .count = .{ .raw = 1 },
        };
        // Pre-populate the bucket counts that THIS sample falls into so
        // the first render() after the insert sees a consistent snapshot.
        for (BUCKETS_MS, 0..) |bound, i| {
            if (value_ms <= bound) {
                new_h.bucket_counts[i].raw = 1;
            }
        }
        self.histograms.put(self.allocator, owned_key, new_h) catch {
            self.allocator.free(owned_key);
            self.allocator.destroy(new_h);
            return;
        };
    }

    /// Render the entire registry as Prometheus text exposition.
    /// The registry mutex is held for the duration of the snapshot —
    /// callers MUST pass a non-blocking writer (typically an in-memory
    /// buffer like ArrayList). A socket writer would stall every emit
    /// site while the scrape is in flight.
    pub fn render(self: *Registry, allocator: std.mem.Allocator, writer: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var c_it = self.counters.iterator();
        while (c_it.next()) |entry| {
            try writer.print("{s} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.*.value.load(.monotonic) });
        }
        var h_it = self.histograms.iterator();
        while (h_it.next()) |entry| {
            const family = entry.key_ptr.*;
            const h = entry.value_ptr.*;
            const split = std.mem.indexOfScalar(u8, family, '{') orelse family.len;
            const name = family[0..split];
            const labels_with_brace = family[split..];
            std.debug.assert(labels_with_brace.len == 0 or
                (labels_with_brace[0] == '{' and labels_with_brace[labels_with_brace.len - 1] == '}'));
            for (BUCKET_LABELS, 0..) |le, i| {
                const bucket_line = if (labels_with_brace.len == 0)
                    try std.fmt.allocPrint(allocator, "{s}_bucket{{le=\"{s}\"}}", .{ name, le })
                else blk: {
                    const trimmed = labels_with_brace[1 .. labels_with_brace.len - 1];
                    break :blk try std.fmt.allocPrint(allocator, "{s}_bucket{{{s},le=\"{s}\"}}", .{ name, trimmed, le });
                };
                defer allocator.free(bucket_line);
                try writer.print("{s} {d}\n", .{ bucket_line, h.bucket_counts[i].load(.monotonic) });
            }
            try writer.print("{s}_sum{s} {d}\n", .{ name, if (labels_with_brace.len == 0) "" else labels_with_brace, h.sum_ms.load(.monotonic) });
            try writer.print("{s}_count{s} {d}\n", .{ name, if (labels_with_brace.len == 0) "" else labels_with_brace, h.count.load(.monotonic) });
        }
    }
};

var global_registry: ?*Registry = null;
var global_registry_inflight: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn setGlobalRegistry(reg: ?*Registry) void {
    @atomicStore(?*Registry, &global_registry, reg, .release);
}

pub fn globalRegistry() ?*Registry {
    return @atomicLoad(?*Registry, &global_registry, .acquire);
}

/// Borrow the process-wide registry for a render. Callers must pair a
/// non-null return with `releaseGlobalRegistry()`.
pub fn borrowGlobalRegistry() ?*Registry {
    if (globalRegistry()) |reg| {
        _ = global_registry_inflight.fetchAdd(1, .acq_rel);
        if (globalRegistry()) |current| {
            if (current == reg) return reg;
        }
        releaseGlobalRegistry();
    }
    return null;
}

pub fn releaseGlobalRegistry() void {
    _ = global_registry_inflight.fetchSub(1, .acq_rel);
}

/// Clear the global registry pointer when it still points at `expected`,
/// then wait for all active `borrowGlobalRegistry()` users to finish.
pub fn detachGlobalRegistryAndWait(expected: *Registry) void {
    if (globalRegistry() == expected) {
        setGlobalRegistry(null);
    }
    while (global_registry_inflight.load(.acquire) != 0) {
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

test "Registry: counter increments accumulate" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    reg.incCounter("foo_total{result=\"ok\"}");
    reg.incCounter("foo_total{result=\"ok\"}");
    reg.incCounter("foo_total{result=\"err\"}");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "foo_total{result=\"ok\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "foo_total{result=\"err\"} 1") != null);
}

test "Registry: histogram bucket counts and sum/count" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    reg.observeHistogram("lat_ms{tool=\"x\"}", 5);
    reg.observeHistogram("lat_ms{tool=\"x\"}", 30);
    reg.observeHistogram("lat_ms{tool=\"x\"}", 700);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "lat_ms_bucket{tool=\"x\",le=\"10\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "lat_ms_bucket{tool=\"x\",le=\"50\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "lat_ms_bucket{tool=\"x\",le=\"1000\"} 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "lat_ms_sum{tool=\"x\"} 735") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "lat_ms_count{tool=\"x\"} 3") != null);
}

test "Registry: first-sample insert is atomic with the increment" {
    // S5 review-fix F6 (2026-05-29) — the very first incCounter call on
    // a new series MUST be visible in the very next render(), not as
    // `name 0`. The cold path initializes the Counter with .raw = 1
    // under the registry mutex so the insert commits the +1 atomically.
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    reg.incCounter("first_total");
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "first_total 1") != null);

    // Histogram analog — first observation must populate sum/count/buckets.
    reg.observeHistogram("first_lat_ms", 30);
    buf.clearRetainingCapacity();
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "first_lat_ms_sum 30") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "first_lat_ms_count 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "first_lat_ms_bucket{le=\"50\"} 1") != null);
}

test "Registry: render is stable under concurrent counter increments" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    const T = struct {
        fn run(r: *Registry) void {
            var i: usize = 0;
            while (i < 100) : (i += 1) r.incCounter("c_total{r=\"x\"}");
        }
    };
    var t1 = try std.Thread.spawn(.{}, T.run, .{&reg});
    var t2 = try std.Thread.spawn(.{}, T.run, .{&reg});
    t1.join();
    t2.join();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try reg.render(std.testing.allocator, buf.writer(std.testing.allocator));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "c_total{r=\"x\"} 200") != null);
}
