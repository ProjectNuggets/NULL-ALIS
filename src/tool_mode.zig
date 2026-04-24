//! Tool-mode helper — parse the `agent.tool_dispatcher` config key into a
//! small enum describing serial vs parallel tool execution.
//!
//! **Not the dispatcher.** This file is ~70 LoC of parsing + mode
//! resolution. The real tool dispatcher lives at `src/agent/dispatcher.zig`
//! (handles tool-call parsing, preflight policy, dispatch, tool-result
//! formatting). Pre-S6.6 this file was named `tool_dispatcher.zig`, which
//! created a trap: readers grepping for "dispatcher" found both and
//! confused the small config helper with the real dispatch engine.
//! Renamed to `tool_mode.zig` to match actual responsibility. The
//! user-facing config key `agent.tool_dispatcher` was NOT renamed —
//! that would break every existing config.json. Only the internal file
//! + import paths moved.

const std = @import("std");

pub const Mode = enum {
    auto,
    serial,
    parallel,

    pub fn toSlice(self: Mode) []const u8 {
        return switch (self) {
            .auto => "auto",
            .serial => "serial",
            .parallel => "parallel",
        };
    }
};

pub const ParsedMode = struct {
    mode: Mode,
    supported: bool,
};

pub fn parseMode(raw: []const u8) ParsedMode {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .{ .mode = .auto, .supported = true };
    if (std.ascii.eqlIgnoreCase(trimmed, "auto")) return .{ .mode = .auto, .supported = true };
    if (std.ascii.eqlIgnoreCase(trimmed, "serial")) return .{ .mode = .serial, .supported = true };
    if (std.ascii.eqlIgnoreCase(trimmed, "parallel")) return .{ .mode = .parallel, .supported = true };
    return .{ .mode = .auto, .supported = false };
}

pub fn effectiveMode(parallel_tools: bool, configured_mode: Mode) Mode {
    return switch (configured_mode) {
        .auto => if (parallel_tools) .parallel else .serial,
        .serial => .serial,
        .parallel => .parallel,
    };
}

test "tool dispatcher parse supports known modes" {
    try std.testing.expectEqual(Mode.auto, parseMode("auto").mode);
    try std.testing.expect(parseMode("auto").supported);

    try std.testing.expectEqual(Mode.serial, parseMode("serial").mode);
    try std.testing.expect(parseMode("serial").supported);

    try std.testing.expectEqual(Mode.parallel, parseMode("parallel").mode);
    try std.testing.expect(parseMode("parallel").supported);
}

test "tool dispatcher parse is case-insensitive and trimmed" {
    const parsed = parseMode("  PaRaLlEl ");
    try std.testing.expectEqual(Mode.parallel, parsed.mode);
    try std.testing.expect(parsed.supported);
}

test "tool dispatcher parse falls back for unknown values" {
    const parsed = parseMode("xml");
    try std.testing.expectEqual(Mode.auto, parsed.mode);
    try std.testing.expect(!parsed.supported);
}

test "tool dispatcher effective mode honors auto and flag" {
    try std.testing.expectEqual(Mode.serial, effectiveMode(false, .auto));
    try std.testing.expectEqual(Mode.parallel, effectiveMode(true, .auto));
    try std.testing.expectEqual(Mode.serial, effectiveMode(true, .serial));
    try std.testing.expectEqual(Mode.parallel, effectiveMode(false, .parallel));
}
