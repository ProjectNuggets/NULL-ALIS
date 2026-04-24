const std = @import("std");

const LAST_JOB_ID_MAX: usize = 160;

var background_main_reroutes_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var metrics_mutex: std.Thread.Mutex = .{};
var background_main_reroutes_last_job_id_buf: [LAST_JOB_ID_MAX]u8 = undefined;
var background_main_reroutes_last_job_id_len: usize = 0;

pub const BackgroundMainRerouteSnapshot = struct {
    total: u64,
    last_job_id: ?[]u8 = null,

    pub fn deinit(self: *BackgroundMainRerouteSnapshot, allocator: std.mem.Allocator) void {
        if (self.last_job_id) |value| allocator.free(value);
        self.last_job_id = null;
    }
};

pub fn recordBackgroundMainReroute(job_id: []const u8) void {
    _ = background_main_reroutes_total.fetchAdd(1, .monotonic);

    metrics_mutex.lock();
    defer metrics_mutex.unlock();

    const n = @min(job_id.len, background_main_reroutes_last_job_id_buf.len);
    if (n > 0) @memcpy(background_main_reroutes_last_job_id_buf[0..n], job_id[0..n]);
    background_main_reroutes_last_job_id_len = n;
}

pub fn snapshotBackgroundMainReroutes(allocator: std.mem.Allocator) !BackgroundMainRerouteSnapshot {
    var snapshot = BackgroundMainRerouteSnapshot{
        .total = background_main_reroutes_total.load(.monotonic),
        .last_job_id = null,
    };

    metrics_mutex.lock();
    defer metrics_mutex.unlock();

    if (background_main_reroutes_last_job_id_len > 0) {
        snapshot.last_job_id = try allocator.dupe(
            u8,
            background_main_reroutes_last_job_id_buf[0..background_main_reroutes_last_job_id_len],
        );
    }
    return snapshot;
}

pub fn resetForTest() void {
    background_main_reroutes_total.store(0, .monotonic);
    completion_event_delete_failures_total.store(0, .monotonic);
    metrics_mutex.lock();
    defer metrics_mutex.unlock();
    background_main_reroutes_last_job_id_len = 0;
}

test "recordBackgroundMainReroute increments total and stores last job id" {
    resetForTest();
    recordBackgroundMainReroute("job-1");
    recordBackgroundMainReroute("job-2");

    var snap = try snapshotBackgroundMainReroutes(std.testing.allocator);
    defer snap.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 2), snap.total);
    try std.testing.expect(snap.last_job_id != null);
    try std.testing.expectEqualStrings("job-2", snap.last_job_id.?);
}

// ─── Completion-event delete failures (S4.6) ─────────────────────────
// Failure to delete a completion_event row after successful delivery
// causes two visible problems: duplicate delivery on reconnect, and
// unbounded growth of the completion_events table. Silent-catching
// hides both; this counter lets operators see the count in a health
// snapshot even when error-level logs are filtered.

var completion_event_delete_failures_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn recordCompletionEventDeleteFailure() void {
    _ = completion_event_delete_failures_total.fetchAdd(1, .monotonic);
}

pub fn completionEventDeleteFailuresTotal() u64 {
    return completion_event_delete_failures_total.load(.monotonic);
}

test "recordCompletionEventDeleteFailure increments total monotonically" {
    resetForTest();
    try std.testing.expectEqual(@as(u64, 0), completionEventDeleteFailuresTotal());
    recordCompletionEventDeleteFailure();
    recordCompletionEventDeleteFailure();
    recordCompletionEventDeleteFailure();
    try std.testing.expectEqual(@as(u64, 3), completionEventDeleteFailuresTotal());
}
