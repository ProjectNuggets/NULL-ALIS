//! S6.11 — GDPR D25 cascade pin.

const std = @import("std");
const harness = @import("harness.zig");

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i <= haystack.len) {
        const remaining = haystack[i..];
        const found = std.mem.indexOf(u8, remaining, needle) orelse break;
        n += 1;
        i += found + needle.len;
    }
    return n;
}

test "S6.11 D25: 0001_initial_schema declares ≥17 user_id cascade FKs" {
    const sql = harness.migrationSql("0001_initial_schema") orelse return error.MigrationMissing;
    const cascades = countOccurrences(sql, "REFERENCES {schema}.users(user_id) ON DELETE CASCADE");
    if (cascades < 17) {
        std.debug.print("S6.11 D25: only {d} user_id cascade FKs in 0001 (expected ≥ 17)\n", .{cascades});
        return error.MissingUserCascade;
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
