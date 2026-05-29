//! S6.11 — GDPR D25 cascade pin.

const std = @import("std");
const nullalis = @import("nullalis");
const migrations = nullalis.migrations;
const harness = @import("harness.zig");

const CASCADE_NEEDLE = "REFERENCES {schema}.users(user_id) ON DELETE CASCADE";

test "S6.11 D25: 0001_initial_schema declares ≥17 user_id cascade FKs" {
    const sql = harness.migrationSql("0001_initial_schema") orelse return error.MigrationMissing;
    const cascades = std.mem.count(u8, sql, CASCADE_NEEDLE);
    if (cascades < 17) {
        std.debug.print("S6.11 D25: only {d} user_id cascade FKs in 0001 (expected ≥ 17)\n", .{cascades});
        return error.MissingUserCascade;
    }
}

test "S6.11 D25: total user_id cascade FKs across ALL shipped migrations is ≥19" {
    // Cross-migration floor — pins the cascade contract at the WHOLE-schema
    // level so a legitimate refactor that moves one table from 0001 into a
    // new 0004 migration (and the cascade rides along) does NOT regress
    // this assertion. The minimum count across all migrations only drops
    // if a cascade was REMOVED, which is the actual contract violation.
    var total: usize = 0;
    for (migrations.MIGRATIONS) |m| {
        total += std.mem.count(u8, m.sql, CASCADE_NEEDLE);
    }
    if (total < 19) {
        std.debug.print("S6.11 D25: total user_id cascade FKs across all migrations = {d} (expected ≥ 19)\n", .{total});
        return error.MissingTotalUserCascade;
    }
}

test "S6.11 D25: artifacts migration declares user_id cascade FK" {
    const sql = harness.migrationSql("0002_artifacts") orelse return error.MigrationMissing;
    try std.testing.expect(std.mem.indexOf(
        u8,
        sql,
        "REFERENCES {schema}.users(user_id) ON DELETE CASCADE",
    ) != null);
}

test "S6.11 D25: trace_shares migration declares user_id cascade FK" {
    const sql = harness.migrationSql("0003_trace_shares") orelse return error.MigrationMissing;
    try std.testing.expect(std.mem.indexOf(
        u8,
        sql,
        "REFERENCES {schema}.users(user_id) ON DELETE CASCADE",
    ) != null);
}

fn checkUserIdLineHas(sql: []const u8, forbidden_suffix: []const u8) bool {
    // Walk the SQL line by line. A "user_id FK line" is any line that
    // contains BOTH `user_id` and `REFERENCES`. If such a line ALSO
    // contains `forbidden_suffix`, the cascade contract is violated.
    var lines = std.mem.splitScalar(u8, sql, '\n');
    while (lines.next()) |line| {
        const has_user = std.mem.indexOf(u8, line, "user_id") != null;
        const has_ref = std.mem.indexOf(u8, line, "REFERENCES") != null;
        const has_forbidden = std.mem.indexOf(u8, line, forbidden_suffix) != null;
        if (has_user and has_ref and has_forbidden) return true;
    }
    return false;
}

test "S6.11 D25: no user_id FK line declares ON DELETE SET NULL" {
    // SET NULL is legitimate on non-user FKs (e.g. session_id, where
    // sessions can be deleted independently of users) but GDPR-violating
    // on user_id where the row would survive the user's deletion. The
    // line-precise check tolerates SET NULL on the next line for a
    // different column (which is exactly the legitimate session_id
    // case in 0001_initial_schema.sql).
    const names = [_][]const u8{ "0001_initial_schema", "0002_artifacts", "0003_trace_shares" };
    for (names) |n| {
        const sql = harness.migrationSql(n) orelse return error.MigrationMissing;
        if (checkUserIdLineHas(sql, "ON DELETE SET NULL")) {
            std.debug.print("S6.11: user_id FK with ON DELETE SET NULL in {s}\n", .{n});
            return error.UserIdSetNullViolation;
        }
    }
}

test "S6.11 D25: no user_id FK line declares ON DELETE NO ACTION" {
    const names = [_][]const u8{ "0001_initial_schema", "0002_artifacts", "0003_trace_shares" };
    for (names) |n| {
        const sql = harness.migrationSql(n) orelse return error.MigrationMissing;
        if (checkUserIdLineHas(sql, "ON DELETE NO ACTION")) {
            std.debug.print("S6.11: user_id FK with ON DELETE NO ACTION in {s}\n", .{n});
            return error.UserIdNoActionViolation;
        }
    }
}
