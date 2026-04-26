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
    secret_mutations_ok_total.store(0, .monotonic);
    secret_mutations_fail_total.store(0, .monotonic);
    gdpr_purge_ok_total.store(0, .monotonic);
    gdpr_purge_partial_total.store(0, .monotonic);
    gdpr_purge_fail_total.store(0, .monotonic);
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

// ─── Secret-mutation outcomes (D13, 2026-04-26) ──────────────────────
// D8 (Sprint 2) shipped the `zaki_bot.secret_mutations` audit table.
// Audit rows give per-tenant forensics ("who tried what when"); these
// counters give operators the rolling-rate signal ("are mutations
// failing more than usual right now?") without scanning the table.
//
// Wired at the central `zaki_state.Manager.recordSecretMutation` site
// so every call path (handlePrepare, handleSet, handleDelete, ...)
// updates the counter without touching each gateway.zig site.
//
// Outcome classification: outcome strings starting with "rejected_",
// "prepare_failed", "consumed_failed", or containing "_failed" → fail;
// everything else (prepare_issued, consumed) → ok. Conservative —
// prefer to over-count fails (visible operator signal) than under-count
// (silent degradation).

var secret_mutations_ok_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var secret_mutations_fail_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn recordSecretMutationOk() void {
    _ = secret_mutations_ok_total.fetchAdd(1, .monotonic);
}

pub fn recordSecretMutationFail() void {
    _ = secret_mutations_fail_total.fetchAdd(1, .monotonic);
}

pub fn secretMutationsOkTotal() u64 {
    return secret_mutations_ok_total.load(.monotonic);
}

pub fn secretMutationsFailTotal() u64 {
    return secret_mutations_fail_total.load(.monotonic);
}

/// Classify a secret-mutation outcome string and increment the matching
/// counter. Centralizes the ok/fail split so callers don't reimplement
/// the rule.
pub fn classifyAndRecordSecretMutation(outcome: []const u8) void {
    const is_fail = std.mem.startsWith(u8, outcome, "rejected_") or
        std.mem.startsWith(u8, outcome, "prepare_failed") or
        std.mem.startsWith(u8, outcome, "consume_failed") or
        std.mem.indexOf(u8, outcome, "_failed") != null or
        std.mem.indexOf(u8, outcome, "_invalid") != null;
    if (is_fail) recordSecretMutationFail() else recordSecretMutationOk();
}

test "recordSecretMutation ok/fail counters are independent + monotonic" {
    resetForTest();
    try std.testing.expectEqual(@as(u64, 0), secretMutationsOkTotal());
    try std.testing.expectEqual(@as(u64, 0), secretMutationsFailTotal());

    recordSecretMutationOk();
    recordSecretMutationOk();
    recordSecretMutationFail();

    try std.testing.expectEqual(@as(u64, 2), secretMutationsOkTotal());
    try std.testing.expectEqual(@as(u64, 1), secretMutationsFailTotal());
}

test "classifyAndRecordSecretMutation routes outcomes by string" {
    resetForTest();

    classifyAndRecordSecretMutation("prepare_issued");
    classifyAndRecordSecretMutation("consumed");
    classifyAndRecordSecretMutation("rejected_no_token");
    classifyAndRecordSecretMutation("prepare_failed");
    classifyAndRecordSecretMutation("token_invalid");
    classifyAndRecordSecretMutation("delete_failed");

    try std.testing.expectEqual(@as(u64, 2), secretMutationsOkTotal());
    try std.testing.expectEqual(@as(u64, 4), secretMutationsFailTotal());
}

// ─── GDPR purge outcomes (D27, 2026-04-26) ───────────────────────────
// Sprint 7B shipped the gdpr.purgeUser orchestrator with structured
// PurgeReport accounting. Audit-trail per-user lives in the report;
// these counters give operators the rolling-rate signal across all
// purge requests.
//
// Three-way classification matches PurgeReport semantics:
//   ok      → fullySucceeded (errors.items.len == 0)
//   partial → some surface succeeded but errors recorded
//   fail    → no surface succeeded, only errors

var gdpr_purge_ok_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var gdpr_purge_partial_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var gdpr_purge_fail_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn recordGdprPurgeOk() void {
    _ = gdpr_purge_ok_total.fetchAdd(1, .monotonic);
}

pub fn recordGdprPurgePartial() void {
    _ = gdpr_purge_partial_total.fetchAdd(1, .monotonic);
}

pub fn recordGdprPurgeFail() void {
    _ = gdpr_purge_fail_total.fetchAdd(1, .monotonic);
}

pub fn gdprPurgeOkTotal() u64 {
    return gdpr_purge_ok_total.load(.monotonic);
}

pub fn gdprPurgePartialTotal() u64 {
    return gdpr_purge_partial_total.load(.monotonic);
}

pub fn gdprPurgeFailTotal() u64 {
    return gdpr_purge_fail_total.load(.monotonic);
}

test "recordGdprPurge counters are independent + monotonic" {
    resetForTest();

    recordGdprPurgeOk();
    recordGdprPurgeOk();
    recordGdprPurgeOk();
    recordGdprPurgePartial();
    recordGdprPurgeFail();
    recordGdprPurgeFail();

    try std.testing.expectEqual(@as(u64, 3), gdprPurgeOkTotal());
    try std.testing.expectEqual(@as(u64, 1), gdprPurgePartialTotal());
    try std.testing.expectEqual(@as(u64, 2), gdprPurgeFailTotal());
}
