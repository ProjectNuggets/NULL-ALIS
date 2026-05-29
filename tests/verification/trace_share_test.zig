//! S6.8 — trace sharing contract pin.

const std = @import("std");
const nullalis = @import("nullalis");
const sanitizer = nullalis.artifacts.sanitizer;
const harness = @import("harness.zig");

test "S6.8 trace share: public-share route is documented in OpenAPI" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/share/") != null);
}

test "S6.8 trace share: durable migration declares user_id with ON DELETE CASCADE" {
    const sql = harness.migrationSql("0003_trace_shares") orelse return error.MigrationMissing;
    try std.testing.expect(std.mem.indexOf(u8, sql, "trace_shares") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "user_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ON DELETE CASCADE") != null);
}

test "S6.8 trace share: migration declares the share_code primary key" {
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
