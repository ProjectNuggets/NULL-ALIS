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

/// True iff `line` declares a `user_id` column with an FK to
/// `{schema}.users(user_id)`. Anchors to a COLUMN declaration so unrelated
/// names like `creating_user_id` or `deleted_user_id` paired with an
/// FK on the same line are NOT false-positives. Recognized shapes (both
/// seen in migrations/*.sql):
///   `    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON ...`
///   `    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON ...`
///   `    user_id BIGINT REFERENCES {schema}.users(user_id) ON ...`
fn lineIsUserIdFk(line: []const u8) bool {
    // Strip leading whitespace and anchor on the column-declaration token
    // `user_id BIGINT` (the canonical type for every owner-user FK in
    // src/migrations/*). A line like `creating_user_id BIGINT REFERENCES
    // {schema}.users(user_id) ON DELETE SET NULL` is correctly EXCLUDED
    // because the leading word is `creating_user_id`, not `user_id`.
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const trimmed = line[i..];
    if (!std.mem.startsWith(u8, trimmed, "user_id BIGINT") and
        !std.mem.startsWith(u8, trimmed, "user_id  BIGINT"))
    {
        return false;
    }
    return std.mem.indexOf(u8, trimmed, "REFERENCES") != null and
        std.mem.indexOf(u8, trimmed, "users(user_id)") != null;
}

test "S6.11 D25 unit: lineIsUserIdFk does not false-positive on prefixed column names" {
    // Negative pin: `creating_user_id` / `deleted_user_id` / etc. with
    // an FK on the SAME line must NOT register as a user_id-owner FK.
    try std.testing.expect(!lineIsUserIdFk("    creating_user_id BIGINT REFERENCES {schema}.users(user_id) ON DELETE SET NULL,"));
    try std.testing.expect(!lineIsUserIdFk("    deleted_user_id BIGINT REFERENCES {schema}.users(user_id) ON DELETE CASCADE,"));
    try std.testing.expect(!lineIsUserIdFk("    -- references {schema}.users(user_id) explanatory comment"));
}

test "S6.11 D25 unit: lineIsUserIdFk recognizes the canonical column declaration shapes" {
    try std.testing.expect(lineIsUserIdFk("    user_id BIGINT NOT NULL REFERENCES {schema}.users(user_id) ON DELETE CASCADE,"));
    try std.testing.expect(lineIsUserIdFk("    user_id BIGINT PRIMARY KEY REFERENCES {schema}.users(user_id) ON DELETE CASCADE,"));
    try std.testing.expect(lineIsUserIdFk("    user_id BIGINT REFERENCES {schema}.users(user_id) ON DELETE SET NULL,"));
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
    defer harness.dropAndDeinit(&mgr, "gdpr_cascade");

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

    // Pre-condition: BOTH seeded rows are present. (Closes the prior
    // coverage gap where working_memory was seeded but never read back.)
    const mem_before = try mgr.getMemory(allocator, uid, "d25-key");
    if (mem_before) |m| m.deinit(allocator);
    try std.testing.expect(mem_before != null);

    const wm_before = try mgr.listWorkingMemorySlots(allocator, uid, "d25-session");
    defer {
        for (wm_before) |*slot| slot.deinit(allocator);
        allocator.free(wm_before);
    }
    try std.testing.expect(wm_before.len >= 1);

    // Cascade trigger: DELETE FROM users.
    try mgr.deleteUser(uid);

    // Post-condition: EVERY seeded row is gone (cascade fired on BOTH
    // tables). A regression that drops CASCADE on either FK is caught
    // here even if the static line scan stays green.
    const mem_after = try mgr.getMemory(allocator, uid, "d25-key");
    if (mem_after) |m| m.deinit(allocator);
    if (mem_after != null) {
        std.debug.print("S6.11 D25 live: memories.d25-key SURVIVED user delete — cascade broken on memories\n", .{});
        return error.MemoryRowSurvivedUserDelete;
    }

    const wm_after = try mgr.listWorkingMemorySlots(allocator, uid, "d25-session");
    defer {
        for (wm_after) |*slot| slot.deinit(allocator);
        allocator.free(wm_after);
    }
    if (wm_after.len != 0) {
        std.debug.print("S6.11 D25 live: working_memory has {d} slot(s) for the deleted user — cascade broken on working_memory\n", .{wm_after.len});
        return error.WorkingMemorySlotSurvivedUserDelete;
    }
}
