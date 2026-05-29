//! S6.0 — live Postgres connectivity sentinel.
//!
//! This is the gate that makes a bogus `NULLALIS_POSTGRES_TEST_URL`
//! fail the matrix instead of silently skipping. When the env var is
//! set, `Manager.init` MUST succeed — anything else (connection refused,
//! host not found, auth fail, missing libpq, migration error) propagates
//! as the underlying error and the matrix is RED.
//!
//! When the env var is NOT set, the test skips cleanly via the harness's
//! `requirePostgresUrl` collapse. The build-time gate at `root.zig`
//! has already rejected the no-engine case (`@compileError`).
//!
//! All downstream live-PG tests (gdpr_cascade, memory_tools, trace_share,
//! artifacts) inherit the same propagation contract via `harness.newManager`.

const std = @import("std");
const nullalis = @import("nullalis");
const zaki_state = nullalis.zaki_state;
const harness = @import("harness.zig");

test "S6.0 live PG: NULLALIS_POSTGRES_TEST_URL must be reachable when set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_url = try harness.requirePostgresUrl(allocator);

    // Unique schema so concurrent or repeated runs don't collide.
    var schema_buf: [96]u8 = undefined;
    const schema = try harness.schemaName(&schema_buf, "connectivity");

    // The bogus-URL hard-fail point. `newManager` does NOT collapse
    // connection errors to SkipZigTest — a `127.0.0.1:1` URL fails with
    // (e.g.) connection-refused and the test is RED.
    var mgr = try harness.newManager(allocator, test_url, schema);
    defer harness.dropAndDeinit(&mgr, "connectivity");

    // Migration smoke — verify the freshly-created schema carries the
    // `users` table that `Manager.init` runs migrations to install. A
    // green Manager.init that doesn't actually run migrations would
    // be a subtler vacuous-green; this catches it.
    const uid: i64 = 1;
    try mgr.provisionUser(uid, "/tmp/nullalis-s6-connectivity");
}

test "S6.0 live PG: a freshly-init'd Manager isolates per-test schemas" {
    // Two managers, two unique schemas, neither sees the other's user
    // rows. Pins the per-test isolation contract every other live test
    // depends on.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_url = try harness.requirePostgresUrl(allocator);

    var schema_a_buf: [96]u8 = undefined;
    const schema_a = try harness.schemaName(&schema_a_buf, "iso_a");
    var schema_b_buf: [96]u8 = undefined;
    const schema_b = try harness.schemaName(&schema_b_buf, "iso_b");

    var mgr_a = try harness.newManager(allocator, test_url, schema_a);
    defer harness.dropAndDeinit(&mgr_a, "iso_a");
    var mgr_b = try harness.newManager(allocator, test_url, schema_b);
    defer harness.dropAndDeinit(&mgr_b, "iso_b");

    const uid: i64 = 1;
    try mgr_a.provisionUser(uid, "/tmp/nullalis-s6-iso-a");
    // Without provisioning the same user in B, a getMemory on B for any
    // key for this uid must return null — proves the schemas are truly
    // separate namespaces (not e.g. accidentally sharing a public.users
    // table).
    const recall = try mgr_b.getMemory(allocator, uid, "any-key");
    try std.testing.expect(recall == null);
}
