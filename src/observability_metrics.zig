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
//!   - The hashmap itself is guarded by a `std.Thread.Mutex` for
//!     insert-or-get. Once a slot exists, increment is a lock-free
//!     atomic add. We expect the registry's static set of keys to
//!     warm up early (every label combo touched on first emit), so
//!     the lock is contended only briefly at startup.
//!   - `render()` takes the lock for the duration of a snapshot.

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

    pub fn incCounter(self: *Registry, series_key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.counters.get(series_key)) |c| {
            _ = c.value.fetchAdd(1, .monotonic);
            return;
        }
        const owned_key = self.allocator.dupe(u8, series_key) catch return;
        const c = self.allocator.create(Counter) catch {
            self.allocator.free(owned_key);
            return;
        };
        c.* = .{ .value = .{ .raw = 1 } };
        self.counters.put(self.allocator, owned_key, c) catch {
            self.allocator.free(owned_key);
            self.allocator.destroy(c);
            return;
        };
    }

    pub fn observeHistogram(self: *Registry, family_key: []const u8, value_ms: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const h = self.histograms.get(family_key) orelse blk: {
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
                .sum_ms = .{ .raw = 0 },
                .count = .{ .raw = 0 },
            };
            self.histograms.put(self.allocator, owned_key, new_h) catch {
                self.allocator.free(owned_key);
                self.allocator.destroy(new_h);
                return;
            };
            break :blk new_h;
        };
        _ = h.sum_ms.fetchAdd(value_ms, .monotonic);
        _ = h.count.fetchAdd(1, .monotonic);
        for (BUCKETS_MS, 0..) |bound, i| {
            if (value_ms <= bound) {
                _ = h.bucket_counts[i].fetchAdd(1, .monotonic);
            }
        }
    }

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

pub fn setGlobalRegistry(reg: ?*Registry) void {
    @atomicStore(?*Registry, &global_registry, reg, .release);
}

pub fn globalRegistry() ?*Registry {
    return @atomicLoad(?*Registry, &global_registry, .acquire);
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
