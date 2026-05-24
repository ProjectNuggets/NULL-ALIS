//! Wave 2C — canvas/artifacts backend: public-share sanitizer.
//!
//! When an artifact is served via `GET /api/v1/share/artifact/:share_code`
//! (no auth, CORS-open), the payload MUST exclude every internal
//! identifier so the share link can't be used to enumerate users,
//! sessions, or storage IDs.
//!
//! Stripped fields (vs. the auth'd JSON shape):
//!   * user_id          — user enumeration surface
//!   * session_id       — session enumeration surface
//!   * metadata_jsonb   — operator-stash; may contain anything
//!   * id (UUID)        — artifact enumeration surface (replaced with share_code)
//!   * share_code       — leaks the URL back in the body (redundant)
//!   * created_at_unix  — fingerprint-style metadata; kept-out by default
//!   * current_version  — internal counter; the public view only sees content
//!
//! Kept fields (the only surface a public reader needs):
//!   * title
//:   * kind
//!   * content (rendered from the latest version)
//!   * updated_at_unix — "last edited" is meaningful for share readers
//!
//! Design choice (conservative + user-protective): the sanitizer takes
//! the FIELDS it KEEPS, not the fields it strips. Adding a new field on
//! the auth'd path can't accidentally leak into the public payload —
//! it only appears if a future commit explicitly extends the keep-list
//! here. This is the same shape Wave 2B uses for trace sharing.

const std = @import("std");
const types = @import("types.zig");

/// Render a public-share JSON view of an artifact + its latest content.
/// Caller owns the returned buffer.
pub fn renderPublicShareJson(
    allocator: std.mem.Allocator,
    title: []const u8,
    kind: types.ArtifactKind,
    content: []const u8,
    updated_at_unix: i64,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.writeAll("{\"title\":\"");
    try jsonEscape(w, title);
    try w.writeAll("\",\"kind\":\"");
    try jsonEscape(w, kind.toSlice());
    try w.writeAll("\",\"content\":\"");
    try jsonEscape(w, content);
    try w.print("\",\"updated_at_unix\":{d}}}", .{updated_at_unix});
    return out.toOwnedSlice(allocator);
}

/// Returns true iff `field_name` is on the public-share allowlist.
/// Used by tests to lock the keep-list down so a future contributor
/// can't quietly widen it.
pub fn isPublicField(field_name: []const u8) bool {
    return std.mem.eql(u8, field_name, "title") or
        std.mem.eql(u8, field_name, "kind") or
        std.mem.eql(u8, field_name, "content") or
        std.mem.eql(u8, field_name, "updated_at_unix");
}

fn jsonEscape(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "sanitizer keeps allowed fields only" {
    try std.testing.expect(isPublicField("title"));
    try std.testing.expect(isPublicField("kind"));
    try std.testing.expect(isPublicField("content"));
    try std.testing.expect(isPublicField("updated_at_unix"));
    // Forbidden fields — must stay forbidden.
    try std.testing.expect(!isPublicField("user_id"));
    try std.testing.expect(!isPublicField("session_id"));
    try std.testing.expect(!isPublicField("metadata_jsonb"));
    try std.testing.expect(!isPublicField("id"));
    try std.testing.expect(!isPublicField("share_code"));
    try std.testing.expect(!isPublicField("created_at_unix"));
    try std.testing.expect(!isPublicField("current_version"));
}

test "renderPublicShareJson excludes user_id and session_id" {
    const a = std.testing.allocator;
    const out = try renderPublicShareJson(
        a,
        "Quarterly plan",
        .markdown,
        "# Title\n\nbody here",
        1_770_000_000,
    );
    defer a.free(out);
    // Must include the keep-list.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\":\"Quarterly plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"markdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"content\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"updated_at_unix\":1770000000") != null);
    // Must NOT include the strip-list.
    try std.testing.expect(std.mem.indexOf(u8, out, "user_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "session_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "metadata_jsonb") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "share_code") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "current_version") == null);
}

test "renderPublicShareJson escapes content" {
    const a = std.testing.allocator;
    const out = try renderPublicShareJson(a, "t", .markdown, "line\"with\\quotes\n", 0);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\n") != null);
}
