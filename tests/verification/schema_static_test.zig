//! S6.12 — D33-equivalent static schema invariants.

const std = @import("std");
const nullalis = @import("nullalis");
const migrations = nullalis.migrations;
const harness = @import("harness.zig");

fn requireCreateTable(sql: []const u8, table: []const u8) !void {
    var buf: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "CREATE TABLE IF NOT EXISTS {{schema}}.{s}", .{table});
    if (std.mem.indexOf(u8, sql, needle) == null) {
        var buf2: [128]u8 = undefined;
        const needle2 = try std.fmt.bufPrint(&buf2, "CREATE TABLE {{schema}}.{s}", .{table});
        if (std.mem.indexOf(u8, sql, needle2) == null) {
            std.debug.print("S6.12: missing CREATE TABLE for '{s}'\n", .{table});
            return error.MissingTable;
        }
    }
}

test "S6.12 schema: every V1-critical user-scoped table is created in the migrations" {
    const sql_0001 = harness.migrationSql("0001_initial_schema") orelse return error.MigrationMissing;
    const tables_0001 = [_][]const u8{
        "users",
        "user_config",
        "sessions",
        "messages",
        "memories",
        "memory_events",
        "jobs",
        "tasks",
        "channel_state",
        "onboarding",
    };
    for (tables_0001) |t| try requireCreateTable(sql_0001, t);

    const sql_0002 = harness.migrationSql("0002_artifacts") orelse return error.MigrationMissing;
    const tables_0002 = [_][]const u8{
        "artifacts",
        "artifact_versions",
    };
    for (tables_0002) |t| try requireCreateTable(sql_0002, t);

    const sql_0003 = harness.migrationSql("0003_trace_shares") orelse return error.MigrationMissing;
    try requireCreateTable(sql_0003, "trace_shares");
}

test "S6.12 schema: migrations.MIGRATIONS list is monotonically versioned starting at 1" {
    var prev: u32 = 0;
    for (migrations.MIGRATIONS) |m| {
        if (m.version <= prev) {
            std.debug.print("S6.12: migration versions out of order: {d} ≤ {d}\n", .{ m.version, prev });
            return error.NonMonotonicMigrations;
        }
        prev = m.version;
    }
    try std.testing.expect(migrations.MIGRATIONS[0].version == 1);
}

test "S6.12 schema: every migration carries a non-empty SQL body" {
    for (migrations.MIGRATIONS) |m| {
        try std.testing.expect(m.sql.len > 0);
        try std.testing.expect(m.name.len > 0);
    }
}

test "S6.12 schema: artifacts migration declares the artifact_versions index (D62)" {
    const sql = harness.migrationSql("0002_artifacts") orelse return error.MigrationMissing;
    try std.testing.expect(std.mem.indexOf(u8, sql, "idx_artifact_versions") != null);
}

test "S6.12 schema: trace_shares migration declares the share_code lookup column with uniqueness" {
    const sql = harness.migrationSql("0003_trace_shares") orelse return error.MigrationMissing;
    const has_pk = std.mem.indexOf(u8, sql, "share_code") != null and
        (std.mem.indexOf(u8, sql, "PRIMARY KEY") != null or
            std.mem.indexOf(u8, sql, "UNIQUE") != null);
    try std.testing.expect(has_pk);
}

test "S6.12 schema: every migration version maps to a unique name" {
    var i: usize = 0;
    while (i < migrations.MIGRATIONS.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < migrations.MIGRATIONS.len) : (j += 1) {
            try std.testing.expect(!std.mem.eql(u8, migrations.MIGRATIONS[i].name, migrations.MIGRATIONS[j].name));
        }
    }
}

test "WP-12 schema rollback: every migration declares a compatibility phase" {
    try std.testing.expectEqual(migrations.CompatibilityPhase.baseline, migrations.MIGRATIONS[0].phase);
    for (migrations.MIGRATIONS[1..]) |migration| {
        try std.testing.expect(migration.phase != .baseline);
    }
}

test "WP-12 schema rollback: expand migrations reject destructive SQL" {
    for (migrations.MIGRATIONS) |migration| {
        if (migration.phase == .expand) {
            try migrations.validateExpandMigration(migration);
        }
    }
}

test "WP-12 schema rollback: 0010 is the sole audited data-delete exception" {
    var exception_count: usize = 0;
    for (migrations.MIGRATIONS) |migration| {
        if (!migration.allow_expand_data_delete) continue;
        exception_count += 1;
        try std.testing.expectEqual(@as(u32, 10), migration.version);
        try std.testing.expectEqualStrings("0010_brain_scaffold_purge", migration.name);
    }
    try std.testing.expectEqual(@as(usize, 1), exception_count);
}

test "WP-12 schema rollback: destructive expand fixtures fail closed" {
    const forbidden = [_][]const u8{
        "ALTER TABLE {schema}.messages DROP COLUMN content",
        "DROP TABLE {schema}.messages",
        "ALTER TABLE {schema}.messages RENAME COLUMN content TO body",
        "ALTER TABLE {schema}.messages ALTER COLUMN content TYPE JSONB",
        "ALTER TABLE {schema}.messages ALTER COLUMN content SET NOT NULL",
        "ALTER TABLE {schema}.messages DROP CONSTRAINT messages_user_id_fkey",
        "TRUNCATE TABLE {schema}.messages",
        "TRUNCATE {schema}.messages",
        "ALTER TABLE {schema}.messages ADD COLUMN required_value TEXT NOT NULL",
        "DROP INDEX CONCURRENTLY IF EXISTS {schema}.messages_lookup_idx",
        "DELETE FROM {schema}.messages",
        "CREATE OR REPLACE TRIGGER messages_before_insert BEFORE INSERT ON {schema}.messages FOR EACH ROW EXECUTE FUNCTION {schema}.audit_message()",
    };
    for (forbidden) |sql| {
        try std.testing.expectError(error.DestructiveExpandMigration, migrations.validateExpandSql(sql));
    }
}
