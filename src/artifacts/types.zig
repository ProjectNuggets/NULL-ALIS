//! Wave 2C — canvas/artifacts backend: types.
//!
//! Pure data structs + ArtifactKind enum, no I/O. Keep this file dep-free
//! so it can be imported anywhere (gateway, tools, tests) without dragging
//! Postgres or build_options.

const std = @import("std");

/// The agent-facing kind enum. Wire form (TEXT) matches the SQL CHECK
/// constraint in `migrations/0002_artifacts.sql`. Keep these in lockstep —
/// adding a kind requires (a) extending this enum, (b) updating the CHECK
/// in a new migration, (c) updating the lint test in this file.
pub const ArtifactKind = enum {
    markdown,
    code,
    html,
    svg,
    json,
    mermaid,
    plaintext,

    pub fn toSlice(self: ArtifactKind) []const u8 {
        return switch (self) {
            .markdown => "markdown",
            .code => "code",
            .html => "html",
            .svg => "svg",
            .json => "json",
            .mermaid => "mermaid",
            .plaintext => "plaintext",
        };
    }

    /// Parse a wire string into an ArtifactKind. Returns null for unknown
    /// values — callers fail-fast with an explicit error rather than
    /// silently coercing to a default (would mask agent typos).
    pub fn fromSlice(s: []const u8) ?ArtifactKind {
        if (std.mem.eql(u8, s, "markdown")) return .markdown;
        if (std.mem.eql(u8, s, "code")) return .code;
        if (std.mem.eql(u8, s, "html")) return .html;
        if (std.mem.eql(u8, s, "svg")) return .svg;
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "mermaid")) return .mermaid;
        if (std.mem.eql(u8, s, "plaintext")) return .plaintext;
        return null;
    }
};

/// Author of an artifact_versions row. Two-valued for v1 — the agent
/// wrote it, or the user did. Future extension (e.g. .system for
/// automated migrations) would need a new SQL CHECK + a successor doc.
pub const Author = enum {
    agent,
    user,

    pub fn toSlice(self: Author) []const u8 {
        return switch (self) {
            .agent => "agent",
            .user => "user",
        };
    }

    pub fn fromSlice(s: []const u8) ?Author {
        if (std.mem.eql(u8, s, "agent")) return .agent;
        if (std.mem.eql(u8, s, "user")) return .user;
        return null;
    }
};

// MEDIUM #4 from Wave 2 code review (2026-05-24): the Artifact /
// ArtifactVersion / VersionHistoryEntry types previously lived here
// AND in `zaki_state.zig` (ArtifactRow / ArtifactVersionRow /
// ArtifactHistoryRow). Two parallel struct families for the same
// concept — silent drift waiting to happen.
//
// Resolution per §14.2 (archaeology — wire or delete): DELETED here;
// the zaki_state row types are the single source of truth because
// they're the type the Postgres CRUD actually returns. New code that
// needs an artifact-row shape should import:
//
//     const ArtifactRow = @import("../zaki_state.zig").ArtifactRow;
//     const ArtifactVersionRow = @import("../zaki_state.zig").ArtifactVersionRow;
//     const ArtifactHistoryRow = @import("../zaki_state.zig").ArtifactHistoryRow;
//
// What stays in this file: `ArtifactKind` + `Author` enums (the
// vocabulary the CHECK constraints + the agent prompt share), and
// `computeContentHash` (the dedup hash used at write time + by the
// /diff endpoint). Neither has a zaki_state counterpart; both are
// canonical here.

/// SHA-256 of `content` as a 64-char lowercase hex string. Caller
/// owns the returned slice and must free it.
pub fn computeContentHash(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(content);
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    var out = try allocator.alloc(u8, 64);
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

// ── Tests ───────────────────────────────────────────────────────────

test "ArtifactKind round-trip" {
    const kinds = [_]ArtifactKind{ .markdown, .code, .html, .svg, .json, .mermaid, .plaintext };
    for (kinds) |k| {
        const wire = k.toSlice();
        const parsed = ArtifactKind.fromSlice(wire) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(k, parsed);
    }
}

test "ArtifactKind.fromSlice rejects unknown" {
    try std.testing.expect(ArtifactKind.fromSlice("typescript") == null);
    try std.testing.expect(ArtifactKind.fromSlice("") == null);
    try std.testing.expect(ArtifactKind.fromSlice("MARKDOWN") == null); // case-sensitive
}

test "Author round-trip" {
    try std.testing.expectEqual(@as(?Author, .agent), Author.fromSlice("agent"));
    try std.testing.expectEqual(@as(?Author, .user), Author.fromSlice("user"));
    try std.testing.expect(Author.fromSlice("system") == null);
}

test "computeContentHash matches known sha256 vector" {
    const a = std.testing.allocator;
    // SHA-256("hello") known digest.
    const expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    const got = try computeContentHash(a, "hello");
    defer a.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

test "computeContentHash empty produces sha256 of empty string" {
    const a = std.testing.allocator;
    const expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const got = try computeContentHash(a, "");
    defer a.free(got);
    try std.testing.expectEqualStrings(expected, got);
}
