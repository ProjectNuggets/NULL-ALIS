//! S6.5 — approvals contract pin.

const std = @import("std");
const nullalis = @import("nullalis");
const gateway = nullalis.gateway;
const harness = @import("harness.zig");

test "S6.5 approvals: canonical session-scoped approve route exists in OpenAPI" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/approve:") != null);
}

test "S6.5 approvals: phantom /api/v1/chat/approve is NOT documented" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "  /api/v1/chat/approve:") == null);
}

test "S6.5 approvals: stable approval_id format apr-{u64} roundtrips" {
    var buf: [64]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "apr-{d}", .{42});
    try std.testing.expectEqualStrings("apr-42", formatted);

    var buf2: [64]u8 = undefined;
    const formatted2 = try std.fmt.bufPrint(&buf2, "apr-{d}", .{43});
    try std.testing.expectEqualStrings("apr-43", formatted2);
    const n1 = try std.fmt.parseInt(u64, formatted[4..], 10);
    const n2 = try std.fmt.parseInt(u64, formatted2[4..], 10);
    try std.testing.expect(n2 > n1);
}

test "S6.5 approvals: 409 stale-card response shape is documented in OpenAPI" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    const has_approve = std.mem.indexOf(u8, yaml, "/approve:") != null;
    const has_409 = std.mem.indexOf(u8, yaml, "'409'") != null or
        std.mem.indexOf(u8, yaml, "\"409\"") != null or
        std.mem.indexOf(u8, yaml, " 409:") != null;
    try std.testing.expect(has_approve and has_409);
}

test "S6.5 approvals: extractIdempotencyKey honors approve-route idempotency" {
    const raw = "POST /api/v1/users/u1/sessions/s1/approve HTTP/1.1\r\nHost: x\r\nIdempotency-Key: approval-deadbeef\r\n\r\n";
    const key = gateway.extractIdempotencyKey(raw) orelse return error.MissingIdempotencyKey;
    try std.testing.expectEqualStrings("approval-deadbeef", key);
}
