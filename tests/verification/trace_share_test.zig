//! S6.8 — trace sharing contract pin.

const std = @import("std");
const nullalis = @import("nullalis");
const sanitizer = nullalis.artifacts.sanitizer;
const harness = @import("harness.zig");

// ── STATIC pins ──────────────────────────────────────────────────────

test "S6.8 trace share: public-share route is documented in OpenAPI" {
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/share/") != null);
}

test "S6.8 trace share: durable migration declares user_id with ON DELETE CASCADE" {
    const sql = harness.migrationSql("0003_trace_shares") orelse return error.MigrationMissing;
    try std.testing.expect(std.mem.indexOf(u8, sql, "trace_shares") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "user_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ON DELETE CASCADE") != null);
}

test "S6.8 trace share: migration declares the share_code column" {
    const sql = harness.migrationSql("0003_trace_shares") orelse return error.MigrationMissing;
    try std.testing.expect(std.mem.indexOf(u8, sql, "share_code") != null);
}

test "S6.8 trace share: migration carries the durability-preserving JSON snapshot column" {
    const sql = harness.migrationSql("0003_trace_shares") orelse return error.MigrationMissing;
    try std.testing.expect(std.mem.indexOf(u8, sql, "events_json") != null);
}

test "S6.8 trace share: sanitizer keep-list is bounded (redundant pin with artifacts)" {
    try std.testing.expect(!sanitizer.isPublicField("user_id"));
    try std.testing.expect(!sanitizer.isPublicField("session_id"));
    try std.testing.expect(!sanitizer.isPublicField("metadata_jsonb"));
    try std.testing.expect(sanitizer.isPublicField("title"));
    try std.testing.expect(sanitizer.isPublicField("content"));
}

// ── LIVE PG: durability across Manager reopen ────────────────────────
//
// S3 (#110) made trace shares Postgres-backed. The durability invariant:
// a share minted by Manager A, after A deinit + B init against the SAME
// Postgres URL + schema, is still readable by B's `getTraceByShareCode`.

test "S6.8 trace share live: share survives Manager-deinit-and-reopen" {
    // Two-phase test — uses the same schema across two Manager
    // lifecycles, so it can't go through the openLiveFixture helper.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_url = try harness.requirePostgresUrl(allocator);
    var schema_buf: [96]u8 = undefined;
    const schema = try harness.schemaName(&schema_buf, "share_durable");

    const uid = harness.testUid();
    const run_id = "run-durability-1";
    const share_code = "shr-durable-AAAA1111";
    const events_json = "[{\"kind\":\"turn.start\"},{\"kind\":\"turn.end\"}]";
    const created_unix: i64 = 1_716_000_000;
    const expires_unix: i64 = 1_716_999_999;

    // Phase 1: open Manager, install identity bypass, mint share, close.
    {
        var mgr = try harness.newManager(allocator, test_url, schema);
        defer mgr.deinit();
        mgr.skipExternalIdentityForTests();
        try mgr.provisionUser(uid, "/tmp/nullalis-s6-share");
        try mgr.setTraceShare(uid, run_id, share_code, events_json, created_unix, expires_unix);
    }

    // Phase 2: reopen on the SAME schema. The minted share must persist.
    var mgr2 = try harness.newManager(allocator, test_url, schema);
    defer harness.dropAndDeinit(&mgr2, "trace_share_phase2");

    const row = try mgr2.getTraceByShareCode(allocator, share_code, created_unix + 1) orelse {
        std.debug.print("S6.8 trace share live: share '{s}' DID NOT survive Manager reopen\n", .{share_code});
        return error.TraceShareLostOnReopen;
    };
    defer allocator.free(row.share_code);
    defer allocator.free(row.run_id);
    defer allocator.free(row.events_json);

    try std.testing.expectEqualStrings(share_code, row.share_code);
    try std.testing.expectEqualStrings(run_id, row.run_id);
    try std.testing.expectEqual(uid, row.user_id);
    try std.testing.expectEqualStrings(events_json, row.events_json);
}

test "S6.8 trace share live: cascade fires when the owning user is deleted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_url = try harness.requirePostgresUrl(allocator);
    var prov = try harness.provisionTestUser(allocator, test_url, "share_cascade", "/tmp/nullalis-s6-share-cascade");
    defer harness.dropAndDeinit(&prov.mgr, "share_cascade");
    const uid = prov.uid;
    const mgr = &prov.mgr;

    const run_id = "run-cascade-1";
    const share_code = "shr-cascade-BBBB2222";
    try mgr.setTraceShare(uid, run_id, share_code, "[]", 1_716_000_000, 1_716_999_999);

    // DELETE FROM users — the trace_shares row must cascade away.
    try mgr.deleteUser(uid);

    const row = try mgr.getTraceByShareCode(allocator, share_code, 1_716_000_001);
    if (row) |r| {
        allocator.free(r.share_code);
        allocator.free(r.run_id);
        allocator.free(r.events_json);
        std.debug.print("S6.8 trace share live: share '{s}' SURVIVED user delete — CASCADE broken\n", .{share_code});
        return error.TraceShareSurvivedUserDelete;
    }
}
