//! Canonical memory-edge relationship categories.
//!
//! Kept as a leaf module so prompt/context policy can share the vocabulary
//! without importing the full memory backend graph.

const std = @import("std");

/// High-level relationship category for a memory edge, distinct from the
/// specific predicate verb. Unknown predicates default to `.attribute` at
/// the classifier callsite.
pub const LinkType = enum {
    /// User likes, dislikes, values, or avoids something.
    preference,
    /// Descriptive properties and the default category.
    attribute,
    /// A fact replaces or supersedes another fact.
    supersession,
    /// A relationship between two named entities.
    relationship,
    /// Uses, owns, consumes, or depends on something.
    usage,
    /// A synthesized memory consolidating multiple sources.
    synthesis,
    /// Event-shaped memories.
    episode,

    pub fn toString(self: LinkType) []const u8 {
        return switch (self) {
            .preference => "preference",
            .attribute => "attribute",
            .supersession => "supersession",
            .relationship => "relationship",
            .usage => "usage",
            .synthesis => "synthesis",
            .episode => "episode",
        };
    }

    /// Parse a link_type string (case-insensitive on ASCII). Returns null
    /// for unknown values. Caller decides default-fallback policy.
    pub fn fromString(s: []const u8) ?LinkType {
        if (s.len == 0) return null;
        var buf: [16]u8 = undefined;
        if (s.len > buf.len) return null;
        for (s, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        const norm = buf[0..s.len];
        if (std.mem.eql(u8, norm, "preference")) return .preference;
        if (std.mem.eql(u8, norm, "attribute")) return .attribute;
        if (std.mem.eql(u8, norm, "supersession")) return .supersession;
        if (std.mem.eql(u8, norm, "relationship")) return .relationship;
        if (std.mem.eql(u8, norm, "usage")) return .usage;
        if (std.mem.eql(u8, norm, "synthesis")) return .synthesis;
        if (std.mem.eql(u8, norm, "episode")) return .episode;
        return null;
    }
};

/// Comptime vocabulary shared by extraction, prompts, tools, and graph APIs.
pub const ALL_LINK_TYPES = [_][]const u8{
    "preference",
    "attribute",
    "supersession",
    "relationship",
    "usage",
    "synthesis",
    "episode",
};

test "LinkType.toString round-trips through fromString" {
    inline for (ALL_LINK_TYPES) |s| {
        const parsed = LinkType.fromString(s) orelse return error.UnexpectedNull;
        try std.testing.expectEqualStrings(s, parsed.toString());
    }
}

test "LinkType.fromString handles case insensitivity" {
    try std.testing.expectEqual(LinkType.preference, LinkType.fromString("PREFERENCE").?);
    try std.testing.expectEqual(LinkType.preference, LinkType.fromString("Preference").?);
    try std.testing.expectEqual(LinkType.attribute, LinkType.fromString("aTTRibute").?);
}

test "LinkType.fromString returns null for unknowns" {
    try std.testing.expect(LinkType.fromString("") == null);
    try std.testing.expect(LinkType.fromString("unknown") == null);
    try std.testing.expect(LinkType.fromString("preferences") == null);
    try std.testing.expect(LinkType.fromString("aaaaaaaaaaaaaaaaaaa") == null);
}
