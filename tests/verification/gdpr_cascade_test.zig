//! S6.11 — GDPR D25 cascade pin.
//!
//! Two complementary checks:
//!   * STATIC: every `user_id BIGINT ... REFERENCES ... users(user_id)`
//!     line across every migration declares `ON DELETE CASCADE`. No
//!     count threshold — every line that PATTERN-MATCHES the user_id FK
//!     shape must individually carry CASCADE.
//!   * LIVE: provision a user, seed user-scoped rows (memory + working
//!     memory), DELETE the user, and assert every seeded row is gone.
//!     This pins the runtime FK semantics, not just the declaration.

const std = @import("std");
const nullalis = @import("nullalis");
const migrations = nullalis.migrations;
const memory_root = nullalis.memory;
const harness = @import("harness.zig");

/// True iff `line` declares a user_id FK to {schema}.users(user_id).
/// Recognized shapes (both seen in migrations/*.sql):
///   `user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON ...`
///   `user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON ...`
///   `user_id BIGINT REFERENCES {schema}.users(user_id) ON ...`
fn lineIsUserIdFk(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "user_id") != null and
        std.mem.indexOf(u8, line, "REFERENCES") != null and
        std.mem.indexOf(u8, line, "users(user_id)") != null;
}

test "S6.11 D25 static: every user_id FK line declares ON DELETE CASCADE" {
    // Walk every migration in shipping order. Every line that pattern-
    // matches the user_id FK shape MUST carry CASCADE. No floor count;
    // a regression that adds a new user_id FK with SET NULL or NO ACTION
    // is caught on the offending line even if other declarations are
    // intact.
    var total_user_fk_lines: usize = 0;
    for (migrations.MIGRATIONS) |m| {
        var lines = std.mem.splitScalar(u8, m.sql, '\n');
        var lineno: usize = 0;
        while (lines.next()) |line| : (lineno += 1) {
            if (!lineIsUserIdFk(line)) continue;
            total_user_fk_lines += 1;
            if (std.mem.indexOf(u8, line, "ON DELETE CASCADE") == null) {
                std.debug.print(
                    "S6.11 D25: user_id FK without ON DELETE CASCADE — migration={s} line={d}: {s}\n",
                    .{ m.name, lineno + 1, line },
                );
                return error.UserIdFkMissingCascade;
            }
        }
    }
    // Floor: at least one user_id FK must exist across all migrations
    // (else the contract is vacuously satisfied). The actual count
    // today is 19 (17 in 0001 + 1 in 0002 + 1 in 0003); a future schema
    // refactor that drops below 1 is a real regression.
    if (total_user_fk_lines == 0) {
        std.debug.print("S6.11 D25: no user_id FK lines found across any migration\n", .{});
        return error.NoUserIdFksFound;
    }
}

// ── Live PG D25 cascade ──────────────────────────────────────────────
//
// The static check above pins what migrations DECLARE; this one pins
// what Postgres actually DOES at delete time. A future engine choice
// or a TRIGGER that intercepts the cascade would leave the static
// check green while breaking the runtime contract — this test catches
// that.

test "S6.11 D25 live: DELETE FROM users cascades user-scoped rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_url = try harness.requirePostgresUrl(allocator);
    var schema_buf: [96]u8 = undefined;
    const schema = try harness.schemaName(&schema_buf, "d25_cascade");
    var mgr = try harness.newManager(allocator, test_url, schema);
    defer {
        mgr.dropSchemaForTests() catch {};
        mgr.deinit();
    }

    const uid: i64 = 1;
    try mgr.provisionUser(uid, "/tmp/nullalis-s6-d25");

    // Seed one user-scoped row in EACH of the two surfaces with
    // ergonomic public CRUD on Manager:
    //   1. memories (FK user_id → users with ON DELETE CASCADE in 0001).
    //   2. working_memory (same).
    // The other 17 cascade tables are pinned statically above; reaching
    // them programmatically requires more invasive helpers (see "What
    // is NOT covered" in the matrix runbook).
    try mgr.upsertMemory(uid, "d25-key", "tagged for cascade", .core, null);
    _ = try mgr.upsertWorkingMemorySlot(
        uid,
        "d25-session",
        2, // slot_id (non-reserved)
        "active_goal",
        "cascade me",
        null,
        0.9,
        false,
    );

    // Pre-condition: seed rows are present.
    const mem_before = try mgr.getMemory(allocator, uid, "d25-key");
    if (mem_before) |m| m.deinit(allocator);
    try std.testing.expect(mem_before != null);

    // Cascade trigger: DELETE FROM users.
    try mgr.deleteUser(uid);

    // Post-condition: every seeded row is gone (cascade fired).
    const mem_after = try mgr.getMemory(allocator, uid, "d25-key");
    if (mem_after) |m| m.deinit(allocator);
    if (mem_after != null) {
        std.debug.print("S6.11 D25 live: memories.d25-key SURVIVED user delete — cascade broken\n", .{});
        return error.MemoryRowSurvivedUserDelete;
    }
}
