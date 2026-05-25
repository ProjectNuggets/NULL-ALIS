//! Minimal JSON-string escaper used by the extension_* tools.
//!
//! HI-05 (v1.14.22, 2026-05-25): the prior per-tool inline `writeJsonString`
//! escaped only `\n \r \t \" \\` and passed every other byte through
//! verbatim. JSON RFC 8259 §7 mandates ALL U+0000–U+001F characters be
//! escaped — control bytes like `\b` (0x08), `\f` (0x0C), `\x01`-`\x07`,
//! `\x0B`, `\x0E`-`\x1F`, and NUL must use either named-escape (`\b`,
//! `\f`) or `\uXXXX` form. A user-controlled selector / text containing
//! any of those produced invalid JSON; the extension's `JSON.parse`
//! rejected it and the agent burnt a turn on a self-inflicted parse
//! failure.
//!
//! This module is the SINGLE escaper for all extension_* tools so a future
//! escape-rule change (e.g. `<`/`>` for JSON-embedded-in-HTML safety)
//! lands in one file.

const std = @import("std");

/// Write `s` to `buf` as a JSON-string literal (including surrounding
/// double-quotes). Every control char and the canonical escapes are
/// emitted per RFC 8259 §7. Caller owns the buf.
pub fn writeJsonString(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    s: []const u8,
) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            // Named escapes the RFC singles out — keeping these
            // separately makes the output marginally smaller than
            // emitting backspace/formfeed via \\u0008/\\u000c.
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    // \uXXXX form for every remaining C0 control.
                    var hex_buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try buf.appendSlice(allocator, hex);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

/// Writer-variant: emit the escaped CONTENT (no surrounding quotes) to a
/// `std.io.Writer`-shaped target. Some callers (`brain_graph`, `task_list`,
/// `task_get`, `todo`) build JSON via a streaming writer rather than an
/// `ArrayListUnmanaged` and wrap their own quotes around the call site.
/// This variant matches that pattern so they can drop their broken inline
/// `\n \r \t \" \\`-only escapers without changing the call shape.
///
/// HI-05 follow-up (2026-05-25): brain_graph still shipped the broken
/// inline escaper after HI-05 was filed. Consolidating the writer-flavored
/// callers behind THIS function closes that drift.
pub fn writeJsonStringContent(writer: anytype, s: []const u8) !void {
    for (s) |c| {
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
                    var hex_buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try writer.writeAll(hex);
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "escapes named C0 controls (\\n \\r \\t \\b \\f)" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeJsonString(std.testing.allocator, &buf, "a\nb\rc\td\x08e\x0Cf");
    try std.testing.expectEqualStrings("\"a\\nb\\rc\\td\\be\\ff\"", buf.items);
}

test "escapes every C0 control via \\u00XX form" {
    // Every byte in 0x00..=0x1F except the named ones must produce
    // \u00XX. Confirm a sample.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    // 0x01 (SOH), 0x07 (BEL), 0x0B (VT), 0x1F (US) — all C0 but
    // not RFC-named.
    try writeJsonString(std.testing.allocator, &buf, "\x01\x07\x0B\x1F");
    try std.testing.expectEqualStrings("\"\\u0001\\u0007\\u000b\\u001f\"", buf.items);
}

test "NUL byte is escaped (not silently truncated)" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeJsonString(std.testing.allocator, &buf, "a\x00b");
    try std.testing.expectEqualStrings("\"a\\u0000b\"", buf.items);
}

test "escapes quote + backslash" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeJsonString(std.testing.allocator, &buf, "a\"b\\c");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\"", buf.items);
}

test "ASCII letters/digits pass through verbatim" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeJsonString(std.testing.allocator, &buf, "hello123");
    try std.testing.expectEqualStrings("\"hello123\"", buf.items);
}

test "UTF-8 multibyte sequences pass through verbatim (>0x7F is fine)" {
    // The RFC only mandates escaping for C0 (0x00..=0x1F). UTF-8
    // continuation bytes are 0x80..=0xBF and lead bytes are 0xC0+;
    // these MUST pass through so the resulting JSON is still valid
    // UTF-8.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeJsonString(std.testing.allocator, &buf, "café Москва");
    try std.testing.expectEqualStrings("\"café Москва\"", buf.items);
}

test "empty string yields just the quotes" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeJsonString(std.testing.allocator, &buf, "");
    try std.testing.expectEqualStrings("\"\"", buf.items);
}

test "writer variant: escapes every C0 control + canonical quotes" {
    // HI-05 follow-up regression — matches the writer-anytype shape
    // brain_graph + task_list + task_get + todo use.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeJsonStringContent(buf.writer(std.testing.allocator), "a\x01b\nc\"d\\e\x00f");
    try std.testing.expectEqualStrings("a\\u0001b\\nc\\\"d\\\\e\\u0000f", buf.items);
}

test "writer variant: NUL byte does not silently truncate" {
    // The original broken brain_graph escaper passed NUL through, which
    // produced JSON that downstream parsers either rejected or treated
    // as a string terminator.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeJsonStringContent(buf.writer(std.testing.allocator), "before\x00after");
    try std.testing.expectEqualStrings("before\\u0000after", buf.items);
}
