//! S6.3 — session cancel contract pin.

const std = @import("std");
const nullalis = @import("nullalis");
const gateway = nullalis.gateway;
const harness = @import("harness.zig");

test "S6.3 cancel: canonical session-scoped path exists in OpenAPI" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/cancel:") != null);
}

test "S6.3 cancel: phantom /api/v1/chat/cancel is NOT documented" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "  /api/v1/chat/cancel:") == null);
}

test "S6.3 cancel: idle-cancel response shape token is documented" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "was_active") != null);
}

test "S6.3 cancel: extractIdempotencyKey returns the header value verbatim" {
    const raw = "POST /api/v1/users/u1/sessions/s1/cancel HTTP/1.1\r\nHost: x\r\nIdempotency-Key: cancel-1234\r\n\r\n";
    const key = gateway.extractIdempotencyKey(raw) orelse return error.MissingIdempotencyKey;
    try std.testing.expectEqualStrings("cancel-1234", key);
}

test "S6.3 cancel: extractIdempotencyKey returns null when header is absent" {
    const raw = "POST /api/v1/users/u1/sessions/s1/cancel HTTP/1.1\r\nHost: x\r\n\r\n";
    try std.testing.expect(gateway.extractIdempotencyKey(raw) == null);
}

test "S6.3 cancel: extractIdempotencyKey is case-insensitive on header name" {
    const raw = "POST /api/v1/users/u1/sessions/s1/cancel HTTP/1.1\r\nHost: x\r\nIDEMPOTENCY-KEY: lower-case-fail\r\n\r\n";
    const key = gateway.extractIdempotencyKey(raw) orelse return error.MissingIdempotencyKey;
    try std.testing.expectEqualStrings("lower-case-fail", key);
}
