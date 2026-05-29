//! S6.7 — artifacts contract pin.

const std = @import("std");
const nullalis = @import("nullalis");
const sanitizer = nullalis.artifacts.sanitizer;
const types = nullalis.artifacts.types;
const harness = @import("harness.zig");

test "S6.7 artifacts: route surface is documented in OpenAPI" {
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/artifacts") != null);
}

test "S6.7 artifacts: public-share whitelist is tightly bounded" {
    try std.testing.expect(sanitizer.isPublicField("title"));
    try std.testing.expect(sanitizer.isPublicField("kind"));
    try std.testing.expect(sanitizer.isPublicField("content"));
    try std.testing.expect(sanitizer.isPublicField("updated_at_unix"));

    try std.testing.expect(!sanitizer.isPublicField("user_id"));
    try std.testing.expect(!sanitizer.isPublicField("session_id"));
    try std.testing.expect(!sanitizer.isPublicField("metadata_jsonb"));
    try std.testing.expect(!sanitizer.isPublicField("metadata"));
    try std.testing.expect(!sanitizer.isPublicField("id"));
    try std.testing.expect(!sanitizer.isPublicField("share_code"));
    try std.testing.expect(!sanitizer.isPublicField("created_at_unix"));
    try std.testing.expect(!sanitizer.isPublicField("current_version"));
    try std.testing.expect(!sanitizer.isPublicField("internal_secret"));
}

test "S6.7 artifacts: renderPublicShareJson excludes every non-whitelisted field" {
    const allocator = std.testing.allocator;
    const json = try sanitizer.renderPublicShareJson(
        allocator,
        "My Public Title",
        types.ArtifactKind.markdown,
        "# Hello, world.",
        1_716_000_000,
    );
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"title\":\"My Public Title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"markdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"content\":\"# Hello, world.\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"updated_at_unix\":1716000000") != null);

    const stripped_keys = [_][]const u8{
        "\"user_id\":",
        "\"session_id\":",
        "\"metadata\":",
        "\"metadata_jsonb\":",
        "\"id\":",
        "\"share_code\":",
        "\"created_at_unix\":",
        "\"current_version\":",
    };
    for (stripped_keys) |k| {
        if (std.mem.indexOf(u8, json, k) != null) {
            std.debug.print("S6.7: sanitizer leaked key '{s}' in:\n{s}\n", .{ k, json });
            return error.SanitizerLeak;
        }
    }
}

test "S6.7 artifacts: renderPublicShareJson escapes embedded JSON metacharacters" {
    const allocator = std.testing.allocator;
    const json = try sanitizer.renderPublicShareJson(
        allocator,
        "He said \"hi\" \\ here",
        types.ArtifactKind.plaintext,
        "line1\nline2",
        0,
    );
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "He said \\\"hi\\\" \\\\ here") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "line1\\nline2") != null);
}

test "S6.7 artifacts: every shipped ArtifactKind serializes via toSlice" {
    inline for (@typeInfo(types.ArtifactKind).@"enum".fields) |f| {
        const k = @field(types.ArtifactKind, f.name);
        const wire = k.toSlice();
        try std.testing.expect(wire.len > 0);
    }
}

test "S6.7 artifacts: export route uses the unsafe-filename guard (path-traversal pin)" {
    // Wave 2A (#107) shipped artifact export. The download path at
    // `gateway.zig:19623` rejects filenames that contain `..`, leading
    // dots, or path separators via `isSafeAttachmentFilename`. The guard
    // is file-private (lowercase fn) so we cannot call it directly from
    // tests/verification — instead, pin its INVOCATION at the route
    // handler. A rename that loses the guard call surfaces here.
    const gateway_src = try harness.loadProjectFile("src/gateway.zig");
    if (std.mem.indexOf(u8, gateway_src, "isSafeAttachmentFilename") == null) {
        std.debug.print("S6.7: `isSafeAttachmentFilename` guard absent from src/gateway.zig — path traversal regression\n", .{});
        return error.UnsafeFilenameGuardMissing;
    }
    // The guard must be CALLED, not just defined. Look for the canonical
    // rejection body the route returns when the guard fails.
    if (std.mem.indexOf(u8, gateway_src, "unsafe_filename") == null) {
        std.debug.print("S6.7: `unsafe_filename` error response absent from src/gateway.zig — guard may be unwired\n", .{});
        return error.UnsafeFilenameResponseMissing;
    }
}
