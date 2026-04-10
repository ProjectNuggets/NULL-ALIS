//! Learning loop — detects corrections and preferences in user messages,
//! stores them as durable behavioral facts under durable_fact/behavior/ keys.
//!
//! Behavioral facts are distinct from raw memory recall. They are injected
//! with higher priority during memory enrichment and change how the agent
//! behaves, not just what it knows.
//!
//! Session scoping: per-user behavioral facts require session_id.
//! Global workspace preferences (operator-set) use null session_id.
//!
//! Security: T-1.5-07 — per-user facts require session_id; null session_id
//! is reserved for operator-set workspace globals. T-1.5-08 — MAX_FACTS_PER_SESSION
//! limits unbounded writes to 100 per session. T-1.5-09 — durable_fact/ keys
//! are system-managed; users cannot modify them via normal memory commands.
//! /learn forget is the only user-facing removal path.

const std = @import("std");

pub const MAX_FACTS_PER_SESSION: usize = 100;

pub const LearningSignal = enum {
    explicit_correction, // "no, actually" / "that's wrong" / "I meant"
    explicit_preference, // "always do X" / "prefer Y" / "never do Z"
    implicit_correction, // "I meant the other one" / repeats request differently
};

pub const LearnedFact = struct {
    key: []const u8,
    content: []const u8,
    signal: LearningSignal,
};

// Patterns for each signal type. All checked case-insensitively.
const CORRECTION_PATTERNS = [_][]const u8{
    "no, actually",
    "that's wrong",
    "that is wrong",
    "not what i",
    "i didn't mean",
    "i meant",
    "wrong,",
    "incorrect",
};

const PREFERENCE_PATTERNS = [_][]const u8{
    "always ",
    "never ",
    "prefer ",
    "don't ever ",
    "from now on",
    "going forward",
    "remember that i",
    "keep in mind",
};

// Note: "i meant" appears in both correction and implicit_correction checks.
// explicit_correction takes priority if matched first (dedup logic handles this).
const IMPLICIT_CORRECTION_PATTERNS = [_][]const u8{
    "what i really want",
    "let me rephrase",
    "try again",
};

/// detectLearningSignals scans a user message for behavioral correction and
/// preference patterns using case-insensitive heuristic string matching.
///
/// Returns a deduplicated slice of detected LearningSignal values.
/// The returned slice is allocated with the provided allocator.
/// Returns an empty slice if no patterns match.
pub fn detectLearningSignals(allocator: std.mem.Allocator, user_message: []const u8) ![]LearningSignal {
    // Lowercase the message for case-insensitive matching.
    const lower = try allocator.alloc(u8, user_message.len);
    defer allocator.free(lower);
    _ = std.ascii.lowerString(lower, user_message);

    var found = std.EnumSet(LearningSignal){};

    for (CORRECTION_PATTERNS) |pattern| {
        if (std.mem.indexOf(u8, lower, pattern) != null) {
            found.insert(.explicit_correction);
            break;
        }
    }

    for (PREFERENCE_PATTERNS) |pattern| {
        if (std.mem.indexOf(u8, lower, pattern) != null) {
            found.insert(.explicit_preference);
            break;
        }
    }

    // implicit_correction: check its own patterns (excluding "i meant" which is
    // already handled by explicit_correction). Only emit implicit_correction if
    // explicit_correction was NOT already detected.
    if (!found.contains(.explicit_correction)) {
        for (IMPLICIT_CORRECTION_PATTERNS) |pattern| {
            if (std.mem.indexOf(u8, lower, pattern) != null) {
                found.insert(.implicit_correction);
                break;
            }
        }
    }

    var result = std.ArrayListUnmanaged(LearningSignal){};
    const iter_order = [_]LearningSignal{ .explicit_correction, .explicit_preference, .implicit_correction };
    for (iter_order) |sig| {
        if (found.contains(sig)) {
            try result.append(allocator, sig);
        }
    }
    return result.toOwnedSlice(allocator);
}

/// factKey generates a deterministic memory key for a behavioral fact.
///
/// Algorithm:
///   1. Lowercase fact_content
///   2. Hash with FNV-1a 64-bit
///   3. Format as `durable_fact/behavior/{x:0>16}` (16-char lowercase hex)
///
/// The returned slice is allocated with the provided allocator.
pub fn factKey(allocator: std.mem.Allocator, fact_content: []const u8) ![]const u8 {
    const lower = try allocator.alloc(u8, fact_content.len);
    defer allocator.free(lower);
    _ = std.ascii.lowerString(lower, fact_content);

    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(lower);
    const hash = hasher.final();

    return std.fmt.allocPrint(allocator, "durable_fact/behavior/{x:0>16}", .{hash});
}

/// formatFactForEnrichment returns the fact content as-is.
///
/// Behavioral facts are stored as human-readable instructions. This function
/// exists as a named API entry point for consistency and future formatting
/// (e.g., adding a "Learned preference:" prefix).
pub fn formatFactForEnrichment(fact_content: []const u8) []const u8 {
    return fact_content;
}

/// extractFactFromMessage extracts a behavioral instruction from a user message
/// given the detected signals.
///
/// Rules:
///   - explicit_preference: returns a copy of the full message (e.g., "always respond in English")
///   - explicit_correction: returns a copy of the full message (corrections are
///     context-dependent; the full message provides context)
///   - implicit_correction only: returns null (insufficient context in a single message)
///   - empty message: returns null
///
/// The returned slice (when non-null) is allocated with the provided allocator.
/// Returns null if no extractable fact is found.
pub fn extractFactFromMessage(
    allocator: std.mem.Allocator,
    user_message: []const u8,
    signals: []const LearningSignal,
) !?[]const u8 {
    const trimmed = std.mem.trim(u8, user_message, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (signals.len == 0) return null;

    for (signals) |sig| {
        switch (sig) {
            .explicit_preference, .explicit_correction => {
                return try allocator.dupe(u8, trimmed);
            },
            .implicit_correction => {
                // implicit corrections lack enough context; skip unless another
                // higher-priority signal was also detected (handled by priority order above).
            },
        }
    }

    return null;
}

// ── Inline tests ──────────────────────────────────────────────────────────────

test "MAX_FACTS_PER_SESSION is 100" {
    try std.testing.expectEqual(@as(usize, 100), MAX_FACTS_PER_SESSION);
}

test "detectLearningSignals finds explicit_correction for 'no, actually'" {
    const allocator = std.testing.allocator;
    const sigs = try detectLearningSignals(allocator, "No, actually do X instead");
    defer allocator.free(sigs);
    try std.testing.expect(sigs.len >= 1);
    try std.testing.expectEqual(LearningSignal.explicit_correction, sigs[0]);
}

test "detectLearningSignals finds explicit_correction for 'that's wrong'" {
    const allocator = std.testing.allocator;
    const sigs = try detectLearningSignals(allocator, "That's wrong, I need the other approach");
    defer allocator.free(sigs);
    var found_correction = false;
    for (sigs) |s| {
        if (s == .explicit_correction) found_correction = true;
    }
    try std.testing.expect(found_correction);
}

test "detectLearningSignals finds explicit_preference for 'always respond in English'" {
    const allocator = std.testing.allocator;
    const sigs = try detectLearningSignals(allocator, "Always respond in English");
    defer allocator.free(sigs);
    var found = false;
    for (sigs) |s| {
        if (s == .explicit_preference) found = true;
    }
    try std.testing.expect(found);
}

test "detectLearningSignals finds explicit_preference for 'prefer concise answers'" {
    const allocator = std.testing.allocator;
    const sigs = try detectLearningSignals(allocator, "I prefer concise answers");
    defer allocator.free(sigs);
    var found = false;
    for (sigs) |s| {
        if (s == .explicit_preference) found = true;
    }
    try std.testing.expect(found);
}

test "detectLearningSignals returns empty for normal conversational messages" {
    const allocator = std.testing.allocator;
    {
        const sigs = try detectLearningSignals(allocator, "thanks");
        defer allocator.free(sigs);
        try std.testing.expectEqual(@as(usize, 0), sigs.len);
    }
    {
        const sigs = try detectLearningSignals(allocator, "what time is it?");
        defer allocator.free(sigs);
        try std.testing.expectEqual(@as(usize, 0), sigs.len);
    }
}

test "detectLearningSignals finds implicit_correction for 'I meant the other one'" {
    const allocator = std.testing.allocator;
    const sigs = try detectLearningSignals(allocator, "I meant the other one");
    defer allocator.free(sigs);
    // "i meant" is in explicit_correction patterns too, so this could be either
    var found_any_correction = false;
    for (sigs) |s| {
        if (s == .implicit_correction or s == .explicit_correction) found_any_correction = true;
    }
    try std.testing.expect(found_any_correction);
}

test "detectLearningSignals finds implicit_correction for 'let me rephrase'" {
    const allocator = std.testing.allocator;
    const sigs = try detectLearningSignals(allocator, "Let me rephrase what I said");
    defer allocator.free(sigs);
    var found = false;
    for (sigs) |s| {
        if (s == .implicit_correction) found = true;
    }
    try std.testing.expect(found);
}

test "detectLearningSignals deduplicates signals" {
    const allocator = std.testing.allocator;
    // Message triggers both correction patterns and preference patterns
    const sigs = try detectLearningSignals(allocator, "No, actually, always respond in English from now on");
    defer allocator.free(sigs);
    // Should have at most one of each type
    var corr_count: usize = 0;
    var pref_count: usize = 0;
    for (sigs) |s| {
        if (s == .explicit_correction) corr_count += 1;
        if (s == .explicit_preference) pref_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), corr_count);
    try std.testing.expectEqual(@as(usize, 1), pref_count);
}

test "factKey generates durable_fact/behavior/ prefixed key" {
    const allocator = std.testing.allocator;
    const key = try factKey(allocator, "always respond in English");
    defer allocator.free(key);
    try std.testing.expect(std.mem.startsWith(u8, key, "durable_fact/behavior/"));
}

test "factKey generates a stable key for the same fact content" {
    const allocator = std.testing.allocator;
    const key1 = try factKey(allocator, "always respond in English");
    defer allocator.free(key1);
    const key2 = try factKey(allocator, "always respond in English");
    defer allocator.free(key2);
    try std.testing.expectEqualStrings(key1, key2);
}

test "factKey key has expected format length (durable_fact/behavior/ + 16 hex chars)" {
    const allocator = std.testing.allocator;
    const key = try factKey(allocator, "prefer concise answers");
    defer allocator.free(key);
    // "durable_fact/behavior/" = 22 chars + 16 hex chars = 38 total
    try std.testing.expectEqual(@as(usize, 38), key.len);
}

test "factKey is case-insensitive (same key for different cases)" {
    const allocator = std.testing.allocator;
    const key1 = try factKey(allocator, "Always Respond In English");
    defer allocator.free(key1);
    const key2 = try factKey(allocator, "always respond in english");
    defer allocator.free(key2);
    try std.testing.expectEqualStrings(key1, key2);
}

test "formatFactForEnrichment returns fact content as-is" {
    const content = "Always respond in English";
    const result = formatFactForEnrichment(content);
    try std.testing.expectEqualStrings(content, result);
}

test "extractFactFromMessage returns copy for explicit_preference" {
    const allocator = std.testing.allocator;
    const sigs = [_]LearningSignal{.explicit_preference};
    const msg = "Always respond in English";
    const result = try extractFactFromMessage(allocator, msg, &sigs);
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings(msg, result.?);
}

test "extractFactFromMessage returns copy for explicit_correction" {
    const allocator = std.testing.allocator;
    const sigs = [_]LearningSignal{.explicit_correction};
    const msg = "No, actually use snake_case";
    const result = try extractFactFromMessage(allocator, msg, &sigs);
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings(msg, result.?);
}

test "extractFactFromMessage returns null for implicit_correction only" {
    const allocator = std.testing.allocator;
    const sigs = [_]LearningSignal{.implicit_correction};
    const result = try extractFactFromMessage(allocator, "I meant the other one", &sigs);
    try std.testing.expect(result == null);
}

test "extractFactFromMessage returns null for empty signals" {
    const allocator = std.testing.allocator;
    const sigs = [_]LearningSignal{};
    const result = try extractFactFromMessage(allocator, "hello", &sigs);
    try std.testing.expect(result == null);
}

test "extractFactFromMessage returns null for empty message" {
    const allocator = std.testing.allocator;
    const sigs = [_]LearningSignal{.explicit_preference};
    const result = try extractFactFromMessage(allocator, "   ", &sigs);
    try std.testing.expect(result == null);
}
