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

/// V1.7a-4 review fix WR-01 / IN-01 + V1.6 review fix WR-03 — single source
/// of truth for UTF-8-safe length-bounded truncation. Replaces three diverged
/// copies that lived in `agent/extraction_persist.zig`,
/// `agent/memory_loader.zig`, and `agent/commands.zig`.
///
/// Returns a borrowed slice of `s` (no allocation), at most `max_len` bytes,
/// guaranteed to land on a UTF-8 codepoint boundary so the result is always
/// valid UTF-8 (never a dangling lead byte without its continuation bytes).
///
/// **Algorithm (two-step robust form):**
///   1. While `s[end-1]` is a continuation byte (0x80..0xBF), back up — we
///      know we're inside a multi-byte codepoint mid-sequence.
///   2. After step 1, `s[end-1]` is either ASCII (<0x80) or a lead byte
///      (>=0xC0). If it's a lead byte, the codepoint started but its
///      continuation bytes were truncated → drop the lead byte too.
///
/// The earlier draft of this helper checked `s[end] & 0xC0 == 0x80` (the
/// byte AFTER the cut). That was correct because `if (s.len <= max_len)
/// return s;` guaranteed `s[max_len]` was in-bounds, but it was fragile:
/// any future caller that managed to skip the early-return guard would
/// trigger a one-past-the-end read. The reviewer's suggested patch
/// (`s[end - 1] & 0xC0 == 0x80`) was safer against OOB but produced
/// INVALID UTF-8 by leaving trailing lead bytes (e.g., truncating "café"
/// to 4 bytes would return "caf" + 0xC3 — a lead byte without its 0xA9
/// continuation). The two-step form here is both safe AND correct.
///
/// Edge cases:
///   - `s.len <= max_len` → returns `s` unchanged (early exit)
///   - `max_len == 0` → returns `s[0..0]` (loop guard `end > 0` blocks any read)
///   - All preceding bytes are continuations (impossible in valid UTF-8) →
///     `end` walks to 0 and returns `s[0..0]`
///   - Truncation mid-multi-byte codepoint → returns the slice ending just
///     BEFORE that codepoint's lead byte
pub fn truncateUtf8(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    var end: usize = max_len;

    // Step 1: back up over trailing continuation bytes. This catches the
    // case where the cut lands inside a multi-byte sequence between the
    // lead byte and any of its continuations.
    while (end > 0 and (s[end - 1] & 0xC0) == 0x80) end -= 1;

    // Step 2: if `s[end - 1]` is a lead byte (high bit set, NOT a
    // continuation), the codepoint started but its continuations were
    // truncated. Back up past the lead too — leaving it would emit
    // invalid UTF-8 (an isolated lead byte).
    if (end > 0 and (s[end - 1] & 0x80) != 0) {
        end -= 1;
    }

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
    // max_len=4: end=4, s[3]=0xC3 (lead byte, NOT continuation) — step 1
    // exits. Step 2: 0xC3 has high bit set, drop it. end=3 → "caf".
    try std.testing.expectEqualStrings("caf", truncateUtf8("café", 4));
}

test "truncateUtf8: backs up across continuation bytes (V1.6/V1.7 review WR fix)" {
    // "🎉" = 0xF0 0x9F 0x8E 0x89 (4-byte). max_len=3: end=3, s[2]=0x8E
    // (continuation), back up. end=2, s[1]=0x9F (continuation), back up.
    // end=1, s[0]=0xF0 (lead, NOT continuation), step 1 exits. Step 2:
    // 0xF0 has high bit, drop. end=0 → "".
    try std.testing.expectEqualStrings("", truncateUtf8("🎉", 3));
}

test "truncateUtf8: max_len==0 returns empty without indexing" {
    try std.testing.expectEqualStrings("", truncateUtf8("café", 0));
}

test "truncateUtf8: 4-byte codepoint backed up cleanly" {
    try std.testing.expectEqualStrings("", truncateUtf8("🎉", 2));
    try std.testing.expectEqualStrings("🎉", truncateUtf8("🎉", 4));
}

test "truncateUtf8: mixed ASCII + multibyte (V1.6 WR-03 — never emits dangling lead)" {
    // "ab🎉cd" = 'a' 'b' 0xF0 0x9F 0x8E 0x89 'c' 'd' (8 bytes), max_len=4:
    // end=4, s[3]=0x9F (continuation), step 1 backs up. end=3, s[2]=0xF0
    // (lead, NOT continuation), step 1 exits. Step 2: 0xF0 has high bit,
    // drop. end=2 → "ab". The PREVIOUS reviewer-suggested form (`s[end-1]`
    // alone, no step 2) would have left end=3 → "ab\xF0" which is INVALID
    // UTF-8 (lead byte without continuations). The two-step form prevents this.
    try std.testing.expectEqualStrings("ab", truncateUtf8("ab🎉cd", 4));
}

test "truncateUtf8: ASCII byte at boundary preserved (no step-2 drop)" {
    // "hello" max_len=4: end=4, s[3]='l'=0x6C (ASCII, high bit clear).
    // Step 1: 0x6C & 0xC0 = 0x40, not 0x80, exit. Step 2: 0x6C & 0x80 = 0,
    // no drop. Return "hell". Verifies step 2 doesn't over-truncate ASCII.
    try std.testing.expectEqualStrings("hell", truncateUtf8("hello", 4));
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
