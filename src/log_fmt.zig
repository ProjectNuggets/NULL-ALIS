//! Structured logging — custom std.log.logFn that can emit either the
//! default text format (human-readable, dev) or JSON lines (shippable to
//! Loki/Axiom/Cloudwatch, prod).
//!
//! Format is selected once at process start via the env:
//!   NULLALIS_LOG_FORMAT=json    -> one JSON object per line on stderr
//!   NULLALIS_LOG_FORMAT=text    -> default Zig text format
//!   (unset)                     -> text
//!
//! Legacy NULLCLAW_LOG_FORMAT still honored with a deprecation warn, per
//! the rebrand chokepoint convention established in S1.1.
//!
//! JSON shape:
//!   {"ts":"2026-04-21T12:34:56.789Z","lvl":"warn","scope":"memory","msg":"..."}
//!
//! Times are RFC3339 UTC with millisecond precision. Message strings are
//! JSON-escaped. The writer falls back to the plain text default if
//! anything goes wrong during JSON formatting.

const std = @import("std");
const builtin = @import("builtin");

pub const Format = enum { text, json };

var current_format: Format = .text;

pub fn init() void {
    current_format = resolveFormatFromEnv();
}

pub fn format() Format {
    return current_format;
}

fn resolveFormatFromEnv() Format {
    // getEnvVarOwned can't be called with an allocator here because logFn
    // itself must be allocation-free. Fall back to std.posix.getenv which
    // returns a borrowed slice; no allocation.
    if (std.posix.getenv("NULLALIS_LOG_FORMAT")) |raw| {
        return parseFormat(raw);
    }
    if (std.posix.getenv("NULLCLAW_LOG_FORMAT")) |raw| {
        // Can't log.warn here — we're still bootstrapping logging itself.
        // Emit to stderr directly so operators see the deprecation at boot.
        // D28 (sunset 2026-05-15): drop the fallback after the date.
        writeStderrDirect("NULLCLAW_LOG_FORMAT is deprecated; use NULLALIS_LOG_FORMAT (remove after 2026-05-15)\n");
        return parseFormat(raw);
    }
    return .text;
}

fn parseFormat(raw: []const u8) Format {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "json")) return .json;
    return .text;
}

fn writeStderrDirect(msg: []const u8) void {
    const stderr = std.fs.File.stderr();
    _ = stderr.writeAll(msg) catch {};
}

/// Install as `std_options.logFn`. Routes to JSON or text based on the
/// process-level format captured at init().
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    switch (current_format) {
        .text => std.log.defaultLog(message_level, scope, fmt, args),
        .json => jsonLog(message_level, scope, fmt, args),
    }
}

fn jsonLog(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    // Render the user message into a bounded buffer. Anything larger than
    // MAX_MSG is truncated with an ellipsis — structured-log backends hate
    // jumbo lines more than they hate truncation.
    var msg_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch blk: {
        const suffix = "...[truncated]";
        @memcpy(msg_buf[msg_buf.len - suffix.len ..], suffix);
        break :blk msg_buf[0..];
    };

    // Build the JSON line in a second buffer. 8KiB accommodates the escaped
    // message + metadata with comfortable headroom.
    var line_buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&line_buf);
    const w = stream.writer();

    writeJsonLine(w, message_level, scope, msg) catch {
        // JSON writer overflowed or errored — fall back to default text.
        std.log.defaultLog(message_level, scope, fmt, args);
        return;
    };

    const stderr = std.fs.File.stderr();
    _ = stderr.writeAll(stream.getWritten()) catch {};
}

fn writeJsonLine(
    w: anytype,
    message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    msg: []const u8,
) !void {
    try w.writeAll("{\"ts\":\"");
    try writeTimestampRfc3339(w);
    try w.writeAll("\",\"lvl\":\"");
    try w.writeAll(@tagName(message_level));
    try w.writeAll("\",\"scope\":\"");
    try w.writeAll(@tagName(scope));
    try w.writeAll("\",\"msg\":");
    try writeJsonString(w, msg);
    try w.writeAll("}\n");
}

fn writeTimestampRfc3339(w: anytype) !void {
    const now_ns = std.time.nanoTimestamp();
    const now_ms = @as(i64, @intCast(@divFloor(now_ns, std.time.ns_per_ms)));
    const epoch_s = @divFloor(now_ms, std.time.ms_per_s);
    const ms_part: u16 = @intCast(@mod(now_ms, std.time.ms_per_s));

    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_s) };
    const day_secs = epoch_secs.getDaySeconds();
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u32, year_day.year),
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        ms_part,
    });
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{ch}),
            else => try w.writeByte(ch),
        }
    }
    try w.writeByte('"');
}

test "parseFormat recognizes json case-insensitively" {
    try std.testing.expectEqual(Format.json, parseFormat("json"));
    try std.testing.expectEqual(Format.json, parseFormat("JSON"));
    try std.testing.expectEqual(Format.json, parseFormat("  Json  "));
    try std.testing.expectEqual(Format.text, parseFormat("plain"));
    try std.testing.expectEqual(Format.text, parseFormat(""));
}

test "writeJsonString escapes control chars + quotes" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonString(fbs.writer(), "hello \"world\"\nline\t");
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nline\\t\"", fbs.getWritten());
}
