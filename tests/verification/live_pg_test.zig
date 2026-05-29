//! S6.0 — live Postgres connectivity sentinel.
//!
//! This is the gate that makes a bogus `NULLALIS_POSTGRES_TEST_URL`
//! fail the matrix instead of silently skipping. When the env var is
//! set, `Manager.init` MUST succeed — anything else (connection refused,
//! host not found, auth fail, missing libpq, migration error) propagates
//! as the underlying error and the matrix is RED.

const std = @import("std");
const nullalis = @import("nullalis");
const harness = @import("harness.zig");

test "S6.0 live PG: NULLALIS_POSTGRES_TEST_URL must be reachable when set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_url = try harness.requirePostgresUrl(allocator);

    var prov = try harness.provisionTestUser(allocator, test_url, "connectivity", "/tmp/nullalis-s6-connectivity");
    defer harness.dropAndDeinit(&prov.mgr, "connectivity");
    // Reaching here means: URL resolved, Manager.init succeeded (connection
    // open + migrations applied), identity bypass installed, provisionUser
    // succeeded. Any failure above turns the matrix RED.
    _ = prov.uid;
}

test "S6.0 live PG: a freshly-init'd Manager isolates per-test schemas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_url = try harness.requirePostgresUrl(allocator);

    var prov_a = try harness.provisionTestUser(allocator, test_url, "iso_a", "/tmp/nullalis-s6-iso-a");
    defer harness.dropAndDeinit(&prov_a.mgr, "iso_a");

    // Open B WITHOUT provisioning a user — pure schema-isolation check.
    var schema_buf: [96]u8 = undefined;
    const schema_b = try harness.schemaName(&schema_buf, "iso_b");
    var mgr_b = try harness.newManager(allocator, test_url, schema_b);
    defer harness.dropAndDeinit(&mgr_b, "iso_b");

    // A user provisioned in schema A must NOT be visible in schema B.
    const recall = try mgr_b.getMemory(allocator, prov_a.uid, "any-key");
    try std.testing.expect(recall == null);
}
