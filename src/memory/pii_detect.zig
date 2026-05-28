//! PII detection — conservative pattern matching for the D52 Pillar 2
//! "tag PII on persist" feature.
//!
//! Goal: when the agent stores user-volunteered personal info (per the
//! D52 Pillar 1 system-prompt directive at `src/agent/prompt.zig:668`),
//! tag the row with the *category* of PII it contains so the V1.1
//! `memory_purge_pii` tool can offer category-scoped delete.
//!
//! ## Categories
//!
//! Two high-precision categories ship in V1:
//!
//!   * **`phone`** — international or national phone number (≥ 7 digits,
//!     standard separator vocabulary). Country-code prefix accepted.
//!   * **`email`** — standard `local@domain.tld` shape.
//!
//! Address detection is deliberately omitted in V1 — natural-language
//! addresses ("123 Main St" vs "Karim's address is the third floor of
//! the blue building on Karl-Marx-Str") have a recall/precision tradeoff
//! we'd rather not ship as a default-on tag. Same call for names: too
//! ambiguous without NER. Credit-card numbers do NOT need a tag here —
//! Pillar 1 routes those to the secret vault directly.
//!
//! ## Design constraints
//!
//! * Detection runs on every persist call — must be allocation-free in
//!   the hot path (the typical write is single-fact). Return is a
//!   bit-flag set, not allocated strings.
//! * No regex engine. Manual byte scanning keeps the dep surface zero.
//! * False positives cost the user a marked-PII tag on a benign memory
//!   (mild). False negatives let real PII slip past the purge tool
//!   (worse). Bias is toward sensitive — err on detection.
//!
//! ## Caller pattern
//!
//! ```zig
//! const flags = detect(content);
//! if (flags.any()) {
//!     // Append `,"pii_tags":[...]` into the metadata JSON.
//!     try writeTagsJsonArray(writer, flags);
//! }
//! ```

const std = @import("std");

/// Bit-flag set of detected PII categories. Packed for stack-only use
/// in the hot persist path.
pub const Flags = packed struct(u8) {
    phone: bool = false,
    email: bool = false,
    _padding: u6 = 0,

    /// True when at least one category fired. Use to gate the
    /// metadata-JSON append.
    pub fn any(self: Flags) bool {
        return self.phone or self.email;
    }

    /// Count of categories detected — useful for telemetry but not
    /// part of the persist contract.
    pub fn count(self: Flags) usize {
        var c: usize = 0;
        if (self.phone) c += 1;
        if (self.email) c += 1;
        return c;
    }
};

/// Detect PII categories in `content`. Allocation-free, single-pass
/// over the text (each detector is independent so they each pass once
/// but the total cost is O(n) bytes for n ≤ content.len).
pub fn detect(content: []const u8) Flags {
    return .{
        .phone = detectPhone(content),
        .email = detectEmail(content),
    };
}

/// Emit the metadata JSON fragment `"pii_tags":["phone","email"]` for
/// the given flags. Writes nothing when no flags fire — caller should
/// gate on `flags.any()` to avoid emitting an empty `pii_tags` array.
///
/// The leading comma is the caller's responsibility (this matches the
/// pattern used by `buildExtractionMetadata` — every field there starts
/// with `,"name":...`).
pub fn writeTagsJson(writer: anytype, flags: Flags) !void {
    try writer.writeAll("\"pii_tags\":[");
    var first = true;
    if (flags.phone) {
        try writer.writeAll("\"phone\"");
        first = false;
    }
    if (flags.email) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll("\"email\"");
    }
    try writer.writeAll("]");
}

/// Parse a tag name into a flag set with that one bit set. Used by
/// the purge tool to translate `category="phone"` into a flag for the
/// SQL filter. Returns null on unknown category.
pub fn flagsForCategory(category: []const u8) ?Flags {
    if (std.mem.eql(u8, category, "phone")) return Flags{ .phone = true };
    if (std.mem.eql(u8, category, "email")) return Flags{ .email = true };
    if (std.mem.eql(u8, category, "all")) return Flags{ .phone = true, .email = true };
    return null;
}

// ── Phone detection ────────────────────────────────────────────────

/// True when `content` contains a phone-number-shaped run.
///
/// Definition: a digit-and-separator run that satisfies AT LEAST ONE
/// of these structural hints:
///
///   * **leading `+`** — international country-code prefix
///   * **>= 10 digits total** — full national-format number (US 10,
///     international 11-15)
///
/// Standard separators allowed between digits: `-` ` ` `(` `)` `.` `/`.
/// The run terminates on the first non-{digit,separator} character.
///
/// ## Why the dual-criterion gate
///
/// The original "7+ digit" rule produced false positives on common
/// non-phone tokens that V1 prod-readiness audit flagged:
///   * `2026-05-28` (date, 8 digits)
///   * `2026-05-28T14:30:00` (date prefix, 8 digits before `T`)
///   * `version 1.2.3.4567890` (long version, 10 digits — STILL caught
///     but that's acceptable since version strings in personal-memory
///     content are rare)
///   * `pi 3.14159265` (math constant, 9 digits)
///
/// Bumping to 10 digits eliminates dates (max 8 digits in standard
/// formats) and most version numbers. Phones written with country
/// code (`+` prefix) bypass the digit floor entirely so short
/// dial-out forms still tag (e.g. `+1 555 0100` = 7 digits + `+`).
///
/// The tradeoff: pure 7-digit US-local numbers without area code
/// (`555-0100`) MISS detection. This is acceptable in V1 because:
///   * Modern US numbers include area code (10 digits)
///   * `memory_purge_pii(dry_run=true)` lets the user inspect before
///     deletion if they're concerned
///   * False negatives on detection just mean those memories don't
///     get the auto-purge UX; manual `forget` by key still works.
fn detectPhone(content: []const u8) bool {
    var i: usize = 0;
    while (i < content.len) {
        // Find the start of a potential phone run.
        // Accept leading `+` (international prefix) or digit.
        const has_plus = content[i] == '+';
        const has_digit = isDigit(content[i]);
        if (!has_plus and !has_digit) {
            i += 1;
            continue;
        }

        // Walk the run: count digits, allow separators between them.
        // The run ends on first non-{digit,separator,plus} char.
        var digit_count: usize = 0;
        var j: usize = if (has_plus) i + 1 else i;
        while (j < content.len) {
            const c = content[j];
            if (isDigit(c)) {
                digit_count += 1;
                j += 1;
            } else if (isPhoneSeparator(c)) {
                j += 1;
            } else {
                break;
            }
        }

        // V1 heuristic: '+' prefix is the strongest phone signal; for
        // run-without-+, require 10+ digits to filter dates/versions.
        if (has_plus and digit_count >= 7) return true;
        if (!has_plus and digit_count >= 10) return true;

        // Move past this run before trying again — avoids quadratic
        // re-scans of the same digit cluster.
        i = if (j > i) j else i + 1;
    }
    return false;
}

inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

inline fn isPhoneSeparator(c: u8) bool {
    return switch (c) {
        '-', ' ', '(', ')', '.', '/' => true,
        else => false,
    };
}

// ── Email detection ────────────────────────────────────────────────

/// True when `content` contains an email-shaped run.
///
/// Definition: substring matching `<local>@<domain>.<tld>` where
///   * local: 1+ chars from `[A-Za-z0-9._%+-]`
///   * domain: 1+ chars from `[A-Za-z0-9.-]`
///   * `.<tld>`: at least one dot in the domain part, followed by
///     2+ letters
///
/// Strict enough that `x@y` doesn't match (no TLD) but loose enough
/// that internationalized domain forms still surface as PII.
fn detectEmail(content: []const u8) bool {
    var i: usize = 0;
    while (i < content.len) {
        // Find the next `@`.
        const at_idx_rel = std.mem.indexOf(u8, content[i..], "@");
        if (at_idx_rel == null) return false;
        const at_idx = i + at_idx_rel.?;

        // Need at least 1 char of local before `@`.
        if (at_idx == 0) {
            i = at_idx + 1;
            continue;
        }
        if (!isEmailLocalChar(content[at_idx - 1])) {
            i = at_idx + 1;
            continue;
        }

        // Walk backward as far as local chars allow — just need the
        // first valid char before `@`. Already confirmed above.

        // Walk forward through domain.
        var j: usize = at_idx + 1;
        var dot_seen: bool = false;
        while (j < content.len) {
            const c = content[j];
            if (c == '.') {
                dot_seen = true;
                j += 1;
            } else if (isEmailDomainChar(c)) {
                j += 1;
            } else {
                break;
            }
        }

        // Need at least one dot, and 2+ letters after the LAST dot.
        if (dot_seen) {
            // Find the last dot in the domain run [at_idx+1, j).
            var last_dot: usize = at_idx + 1;
            var k: usize = at_idx + 1;
            while (k < j) : (k += 1) {
                if (content[k] == '.') last_dot = k;
            }
            const tld = content[last_dot + 1 .. j];
            if (tld.len >= 2 and allLetters(tld)) {
                return true;
            }
        }

        i = j;
    }
    return false;
}

inline fn isEmailLocalChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '_' or c == '%' or c == '+' or c == '-';
}

inline fn isEmailDomainChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-';
}

inline fn isLetter(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

fn allLetters(s: []const u8) bool {
    for (s) |c| {
        if (!isLetter(c)) return false;
    }
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────

test "detect phone — international with + prefix (7+ digits)" {
    try std.testing.expect(detect("My brother Karim: +49 30 12345 67").phone);
    try std.testing.expect(detect("+1-555-867-5309").phone);
}

test "detect phone — national 10-digit US format" {
    try std.testing.expect(detect("Call 555-867-5309 for support").phone);
    try std.testing.expect(detect("5558675309").phone);
    try std.testing.expect(detect("Call (415) 555-2671 tomorrow").phone);
}

test "detect phone — rejects ISO dates (false-positive guard)" {
    // V1 audit found these were the most common false positives.
    try std.testing.expect(!detect("I joined on 2026-05-28").phone);
    try std.testing.expect(!detect("Born 1985-03-15").phone);
    try std.testing.expect(!detect("ts 2026-05-28T14:30:00").phone);
}

test "detect phone — rejects short national numbers (V1 tradeoff)" {
    // V1 misses pure 7-9 digit numbers without country code or +.
    // Tradeoff documented in detectPhone() docstring. Most US numbers
    // include area code so coverage stays high.
    try std.testing.expect(!detect("Call 555-0100 for support").phone);
    try std.testing.expect(!detect("5550100").phone);
}

test "detect phone — rejects too-short and non-phone digit runs" {
    try std.testing.expect(!detect("I'm 42 years old").phone);
    try std.testing.expect(!detect("Zip 12345").phone);
    try std.testing.expect(!detect("year 2026 month 05").phone);
    try std.testing.expect(!detect("pi 3.14159").phone);
}

test "detect phone — handles surrounding text" {
    try std.testing.expect(detect("call me at 555-867-5309 thanks").phone);
    try std.testing.expect(detect("Phone: +49 30 12345 67 (Berlin)").phone);
}

test "detect email — basic shape" {
    try std.testing.expect(detect("write to alaa@nullalis.dev").email);
    try std.testing.expect(detect("user@example.co.uk works too").email);
    try std.testing.expect(detect("Customer: jane.doe+billing@example.com").email);
}

test "detect email — rejects no TLD" {
    try std.testing.expect(!detect("ping x@y").email);
    try std.testing.expect(!detect("ssh user@host").email);
}

test "detect email — rejects no local part" {
    try std.testing.expect(!detect("just @symbol here").email);
}

test "detect email — rejects 1-letter TLD" {
    try std.testing.expect(!detect("foo@bar.x is too short").email);
}

test "detect multiple — both fire" {
    const flags = detect("Karim +49 30 12345 67 — karim@example.com");
    try std.testing.expect(flags.phone);
    try std.testing.expect(flags.email);
    try std.testing.expectEqual(@as(usize, 2), flags.count());
    try std.testing.expect(flags.any());
}

test "detect — date adjacent to email does not promote date to phone" {
    // Regression guard for the V1 fix — content that has both a date
    // (which would have been a false-positive phone) and a real email
    // tags only email, not phone.
    const flags = detect("Onboarded 2026-05-28; contact alaa@nullalis.dev");
    try std.testing.expect(!flags.phone);
    try std.testing.expect(flags.email);
}

test "detect — clean text reports nothing" {
    const flags = detect("User prefers Helix over VSCode for editing Zig code.");
    try std.testing.expect(!flags.any());
    try std.testing.expectEqual(@as(usize, 0), flags.count());
}

test "writeTagsJson — phone only" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try writeTagsJson(buf.writer(std.testing.allocator), .{ .phone = true });
    try std.testing.expectEqualStrings("\"pii_tags\":[\"phone\"]", buf.items);
}

test "writeTagsJson — email only" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try writeTagsJson(buf.writer(std.testing.allocator), .{ .email = true });
    try std.testing.expectEqualStrings("\"pii_tags\":[\"email\"]", buf.items);
}

test "writeTagsJson — both categories ordered phone,email" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try writeTagsJson(buf.writer(std.testing.allocator), .{ .phone = true, .email = true });
    try std.testing.expectEqualStrings("\"pii_tags\":[\"phone\",\"email\"]", buf.items);
}

test "flagsForCategory" {
    try std.testing.expect(flagsForCategory("phone").?.phone);
    try std.testing.expect(!flagsForCategory("phone").?.email);
    try std.testing.expect(flagsForCategory("email").?.email);
    try std.testing.expect(flagsForCategory("all").?.phone);
    try std.testing.expect(flagsForCategory("all").?.email);
    try std.testing.expectEqual(@as(?Flags, null), flagsForCategory("xyz"));
}

test "detect — does not allocate" {
    // Sanity: no allocator parameter, structural guarantee.
    _ = detect("alaa@nullalis.dev +49 30 12345 67");
}
