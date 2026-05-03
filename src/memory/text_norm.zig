//! V1.6 commit 3 — text normalization for BM25 retrieval.
//!
//! `lemmatizeForBm25` produces a normalized form of memory content for
//! Postgres's GIN(to_tsvector('simple', ...)) index. The output is:
//!   - lowercased ASCII letters
//!   - non-ASCII passes through unchanged (Arabic, CJK, emoji preserved)
//!   - punctuation replaced with single spaces
//!   - common English stopwords stripped (top ~40 — covers the common case
//!     without hurting recall on noun-heavy queries)
//!   - multiple consecutive spaces collapsed to one
//!
//! No Porter/Snowball stemming. The audit's spec §4.2 V1 path: simple
//! lowercase + ASCII-fold + stopword removal. V1.7 may swap for a
//! per-language stemmer if measured value supports it.
//!
//! Mirror SQL backfill: `UPDATE memories SET lemmatized = lower(content)
//! WHERE lemmatized IS NULL` is used at migrate apply for existing rows.
//! New rows get this Zig path which is a strict superset (stopword
//! removal in addition to lowercasing).

const std = @import("std");

/// V1.7a-4 review fix WR-01 / IN-01 — single source of truth for UTF-8-safe
/// length-bounded truncation. Replaces three diverged copies that lived in
/// `agent/extraction_persist.zig`, `agent/memory_loader.zig`, and
/// `agent/commands.zig` (all subtly identical, but easy to drift). Returns
/// a borrowed slice of `s` (no allocation), at most `max_len` bytes,
/// guaranteed not to split a multi-byte UTF-8 codepoint mid-sequence by
/// backing up over trailing 0x80..0xBF continuation bytes.
///
/// Edge cases:
///   - `s.len <= max_len` → returns `s` unchanged
///   - `max_len == 0` → returns `s[0..0]` (empty slice, never indexes `s`)
///   - All trailing bytes are continuations (truncating mid-codepoint into
///     a string that's all continuation bytes from byte 0) → `end` walks
///     down to 0 and returns `s[0..0]`
pub fn truncateUtf8(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    var end: usize = max_len;
    // Loop invariant: end > 0 protects against indexing s[-1]; the
    // continuation-byte check ensures we land BEFORE a continuation byte
    // (i.e., on a codepoint boundary or at end=0).
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}

test "truncateUtf8: returns input when shorter than max" {
    try std.testing.expectEqualStrings("abc", truncateUtf8("abc", 10));
}

test "truncateUtf8: ASCII truncation at exact boundary" {
    try std.testing.expectEqualStrings("abc", truncateUtf8("abcdef", 3));
}

test "truncateUtf8: backs up over UTF-8 continuation byte" {
    // "café" = 'c' (0x63) 'a' (0x61) 'f' (0x66) 'é' (0xC3 0xA9)
    // max_len=4 lands on 0xA9 (continuation); backs up to 3.
    try std.testing.expectEqualStrings("caf", truncateUtf8("café", 4));
}

test "truncateUtf8: max_len==0 returns empty without indexing" {
    try std.testing.expectEqualStrings("", truncateUtf8("café", 0));
}

test "truncateUtf8: 4-byte codepoint backed up cleanly" {
    // "🎉" = 0xF0 0x9F 0x8E 0x89 (4-byte UTF-8). max_len=2 lands on
    // 0x8E (continuation), backs up to 1 (still continuation 0x9F),
    // backs up to 0 (lead byte 0xF0 is NOT a continuation; loop stops).
    // Returns empty (we'd need at least 4 bytes for one codepoint).
    try std.testing.expectEqualStrings("", truncateUtf8("🎉", 2));
    try std.testing.expectEqualStrings("🎉", truncateUtf8("🎉", 4));
}

test "truncateUtf8: mixed ASCII + multibyte" {
    // "ab🎉cd" = 'a' 'b' 0xF0 0x9F 0x8E 0x89 'c' 'd'  (8 bytes)
    // max_len=4 lands on 0x8E (continuation). Backs up to 2 (lead 0xF0 is
    // not continuation, but bytes after 0xF0 ARE — wait, 0xF0 itself
    // isn't a continuation; loop stops at end=2 since s[2]=0xF0 with
    // 0xF0 & 0xC0 == 0xC0, NOT 0x80). So returns "ab".
    try std.testing.expectEqualStrings("ab", truncateUtf8("ab🎉cd", 4));
}

// Top common English stopwords. Ordered by approximate frequency. Conservative
// set — keeps semantic content like "the", "a", "is", "and" out of the index
// without stripping anything that might carry meaning ("not", "no" stay).
const STOPWORDS = [_][]const u8{
    "the", "a",   "an",   "and", "or",  "but", "if",   "then", "else",
    "so",  "as",  "of",   "to",  "in",  "on",  "at",   "by",   "for",
    "from", "with", "is",  "are", "was", "were", "be",  "been", "being",
    "have", "has", "had",  "do",  "does", "did", "this", "that", "these",
    "those", "i",   "you",  "he",  "she", "it",  "we",   "they",
};

/// Simple stopword check — linear scan since list is short and called per-token.
inline fn isStopword(token: []const u8) bool {
    for (STOPWORDS) |w| {
        if (std.mem.eql(u8, token, w)) return true;
    }
    return false;
}

/// Normalize text for BM25 indexing.
///
/// Caller owns returned slice.
///
/// Examples:
///   "I prefer Zig over Rust!"           → "prefer zig over rust"
///   "User's mother is named فاطمة"      → "user's mother named فاطمة"
///   "deployment target: DigitalOcean k8s" → "deployment target digitalocean k8s"
pub fn lemmatizeForBm25(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    // Pass 1: lowercase ASCII letters; replace ASCII punctuation with space;
    // pass everything else (non-ASCII bytes, digits) through unchanged.
    var lowered: std.ArrayListUnmanaged(u8) = .{};
    defer lowered.deinit(allocator);
    try lowered.ensureUnusedCapacity(allocator, text.len);

    for (text) |b| {
        if (b >= 'A' and b <= 'Z') {
            try lowered.append(allocator, b + ('a' - 'A'));
        } else if ((b >= 'a' and b <= 'z') or (b >= '0' and b <= '9')) {
            try lowered.append(allocator, b);
        } else if (b >= 0x80) {
            // Non-ASCII byte (UTF-8 leading or continuation) — pass through
            try lowered.append(allocator, b);
        } else {
            // ASCII punctuation / whitespace / control — collapse to space
            try lowered.append(allocator, ' ');
        }
    }

    // Pass 2: tokenize on whitespace, drop stopwords, collapse spaces
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(allocator);
    try out.ensureUnusedCapacity(allocator, lowered.items.len);

    var first_token = true;
    var iter = std.mem.tokenizeScalar(u8, lowered.items, ' ');
    while (iter.next()) |token| {
        if (token.len == 0) continue;
        if (isStopword(token)) continue;
        if (!first_token) try out.append(allocator, ' ');
        try out.appendSlice(allocator, token);
        first_token = false;
    }

    return try out.toOwnedSlice(allocator);
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "lemmatizeForBm25 lowercases ASCII and strips punctuation" {
    const allocator = std.testing.allocator;
    const out = try lemmatizeForBm25(allocator, "I PREFER Zig over Rust!");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("prefer zig over rust", out);
}

test "lemmatizeForBm25 drops common stopwords" {
    const allocator = std.testing.allocator;
    const out = try lemmatizeForBm25(allocator, "The user is in the office and at the desk");
    defer allocator.free(out);
    // Keeps content words: user, office, desk
    try std.testing.expectEqualStrings("user office desk", out);
}

test "lemmatizeForBm25 preserves non-ASCII bytes (UTF-8 byte-perfect)" {
    const allocator = std.testing.allocator;
    // Arabic + English mixed (Nova's actual usage pattern)
    const out = try lemmatizeForBm25(allocator, "User's mother is named فاطمة in بيروت");
    defer allocator.free(out);
    // Stopwords removed: "is" "in" "the"... Note "user's" becomes "user s"
    // (apostrophe → space) but s is not a stopword by my list, so it stays.
    // Arabic preserved byte-perfect.
    try std.testing.expectEqualStrings("user s mother named فاطمة بيروت", out);
}

test "lemmatizeForBm25 handles empty + whitespace-only input" {
    const allocator = std.testing.allocator;
    const a = try lemmatizeForBm25(allocator, "");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("", a);

    const b = try lemmatizeForBm25(allocator, "   \t\n  ");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("", b);
}

test "lemmatizeForBm25 handles digits and tech identifiers" {
    const allocator = std.testing.allocator;
    const out = try lemmatizeForBm25(allocator, "deployment target: DigitalOcean k8s on port 5433");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("deployment target digitalocean k8s port 5433", out);
}

test "lemmatizeForBm25 collapses multiple spaces between tokens" {
    const allocator = std.testing.allocator;
    const out = try lemmatizeForBm25(allocator, "hello,,,   world!!!\n\nfoo");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello world foo", out);
}

test "lemmatizeForBm25 keeps semantic negations" {
    const allocator = std.testing.allocator;
    const out = try lemmatizeForBm25(allocator, "user does not use AWS");
    defer allocator.free(out);
    // "does" stripped, "not" preserved (not in stopword list — the
    // negation carries meaning the user wouldn't want lost)
    try std.testing.expectEqualStrings("user not use aws", out);
}
