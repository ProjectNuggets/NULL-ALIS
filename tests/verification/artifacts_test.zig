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

test "S6.7 artifacts: handleArtifactExportDownload calls isSafeAttachmentFilename + returns unsafe_filename" {
    // Tighter than a global substring scan: locate the actual handler
    // function body and assert the guard call lives INSIDE it. A
    // regression that moves the call elsewhere (or wires the route to
    // a handler that bypasses the guard) would fail this assertion.
    const gateway_src = try harness.loadProjectFile("src/gateway.zig");

    const fn_anchor = "fn handleArtifactExportDownload(";
    const fn_start = std.mem.indexOf(u8, gateway_src, fn_anchor) orelse {
        std.debug.print("S6.7: handleArtifactExportDownload symbol absent — route may be unwired\n", .{});
        return error.ExportDownloadHandlerMissing;
    };

    // Bound the handler body at the canonical column-0 close-brace
    // (`\n}\n`). This is more robust than a `\nfn ` next-fn scan:
    //   * works for any function regardless of `fn` / `pub fn` /
    //     `inline fn` prefix on the FOLLOWING declaration;
    //   * doesn't false-match a `\nfn ` substring buried in a string
    //     literal inside the handler;
    //   * stops at the END of the function body itself, not at the
    //     start of an arbitrary later function.
    // A Zig top-level function's terminating `}` is at column 0,
    // followed by a newline. Anything inside the function body is
    // indented at least 4 spaces, so `\n}\n` is unambiguous.
    const body_end_rel = std.mem.indexOfPos(u8, gateway_src, fn_start, "\n}\n") orelse {
        std.debug.print("S6.7: handleArtifactExportDownload body terminator not found within 8 KB\n", .{});
        return error.ExportDownloadHandlerBodyUnbounded;
    };
    const fn_body = gateway_src[fn_start .. body_end_rel + 3]; // include the `\n}\n`

    if (std.mem.indexOf(u8, fn_body, "isSafeAttachmentFilename") == null) {
        std.debug.print("S6.7: handleArtifactExportDownload does NOT call isSafeAttachmentFilename — path-traversal guard bypassed\n", .{});
        return error.UnsafeFilenameGuardBypassed;
    }
    if (std.mem.indexOf(u8, fn_body, "unsafe_filename") == null) {
        std.debug.print("S6.7: handleArtifactExportDownload does NOT return the unsafe_filename error code\n", .{});
        return error.UnsafeFilenameResponseMissing;
    }
}

// ── LIVE PG: artifact CRUD roundtrip ─────────────────────────────────

test "S6.7 artifacts live: create + get round-trip pins the V1 artifact storage path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_url = try harness.requirePostgresUrl(allocator);
    var prov = try harness.provisionTestUser(allocator, test_url, "artifact_crud", "/tmp/nullalis-s6-artifact");
    defer harness.dropAndDeinit(&prov.mgr, "artifact_crud");
    const uid = prov.uid;
    const mgr = &prov.mgr;

    const session_id = "artifact-test-session";
    const created = try mgr.createArtifact(
        allocator,
        uid,
        session_id,
        "Verification Smoke Doc",
        "markdown",
        "# Hello from S6\n\nbody",
        "sha256:test", // content_hash
        1_716_000_000,
    );
    defer {
        allocator.free(created.id);
        allocator.free(created.title);
        allocator.free(created.kind);
        if (created.session_id) |s| allocator.free(s);
        if (created.share_code) |s| allocator.free(s);
        allocator.free(created.metadata_jsonb);
    }

    try std.testing.expectEqualStrings("Verification Smoke Doc", created.title);
    try std.testing.expectEqualStrings("markdown", created.kind);
    // `current_version` is `u64` (src/zaki_state.zig:250); using i32 here
    // would coerce fine for value=1 but fail latently for values > i32 max.
    try std.testing.expectEqual(@as(u64, 1), created.current_version);

    // Read back by id — must match the create response.
    const fetched = try mgr.getArtifactById(allocator, uid, created.id) orelse {
        std.debug.print("S6.7 artifact live: createArtifact returned id '{s}' but getArtifactById found nothing\n", .{created.id});
        return error.ArtifactNotPersisted;
    };
    defer {
        allocator.free(fetched.id);
        allocator.free(fetched.title);
        allocator.free(fetched.kind);
        if (fetched.session_id) |s| allocator.free(s);
        if (fetched.share_code) |s| allocator.free(s);
        allocator.free(fetched.metadata_jsonb);
    }
    try std.testing.expectEqualStrings(created.id, fetched.id);
    try std.testing.expectEqualStrings(created.title, fetched.title);
}
