//! S6.6 — attachments contract pin.

const std = @import("std");
const nullalis = @import("nullalis");
const gateway = nullalis.gateway;
const harness = @import("harness.zig");

test "S6.6 attachments: route is documented in OpenAPI" {
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/attachments") != null);
}

test "S6.6 attachments: Idempotency-Key parser yields the verbatim value" {
    const raw = "POST /api/v1/users/u1/attachments HTTP/1.1\r\nHost: x\r\nIdempotency-Key: upload-uuid-1\r\n\r\n";
    const key = gateway.extractIdempotencyKey(raw) orelse return error.MissingIdempotencyKey;
    try std.testing.expectEqualStrings("upload-uuid-1", key);
}

test "S6.6 attachments: missing Idempotency-Key is soft mode (returns null)" {
    const raw = "POST /api/v1/users/u1/attachments HTTP/1.1\r\nHost: x\r\n\r\n";
    try std.testing.expect(gateway.extractIdempotencyKey(raw) == null);
}

test "S6.6 attachments: empty Idempotency-Key value parses as zero-length slice" {
    const raw = "POST /api/v1/users/u1/attachments HTTP/1.1\r\nHost: x\r\nIdempotency-Key: \r\n\r\n";
    const key = gateway.extractIdempotencyKey(raw) orelse return error.MissingIdempotencyKey;
    try std.testing.expectEqualStrings("", key);
}

test "S6.6 attachments: failure-state surface is documented" {
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    const has_attachments = std.mem.indexOf(u8, yaml, "/attachments") != null;
    const has_4xx = std.mem.indexOf(u8, yaml, "invalid_idempotency_key") != null or
        std.mem.indexOf(u8, yaml, "'400'") != null or
        std.mem.indexOf(u8, yaml, " 400:") != null;
    try std.testing.expect(has_attachments and has_4xx);
}
