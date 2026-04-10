//! Channel Health Aggregation — collects state from health.zig registry
//! and ChannelManager entries into a unified JSON-serializable structure.
//!
//! This is a pure computation module with no gateway or commands.zig coupling.
//! Wired into slash commands and API endpoints in Plan 04.

const std = @import("std");
const health = @import("health.zig");
const channel_manager = @import("channel_manager.zig");
const dispatch = @import("channels/dispatch.zig");

/// Overall health status derived from channel states.
pub const OverallStatus = enum {
    healthy,
    degraded,
    unhealthy,

    /// Determine overall status from channel entries.
    /// Any gave_up => unhealthy. Any restarting => degraded. Otherwise healthy.
    pub fn fromChannels(entries: []const ChannelHealthEntry) OverallStatus {
        var worst: OverallStatus = .healthy;
        for (entries) |e| {
            switch (e.state) {
                .gave_up => return .unhealthy,
                .restarting => worst = .degraded,
                else => {},
            }
        }
        return worst;
    }

    pub fn toSlice(self: OverallStatus) []const u8 {
        return switch (self) {
            .healthy => "healthy",
            .degraded => "degraded",
            .unhealthy => "unhealthy",
        };
    }
};

/// Per-channel health entry with supervision state, listener info, and error details.
pub const ChannelHealthEntry = struct {
    name: []const u8,
    listener_type: []const u8,
    state: dispatch.SupervisedChannel.State,
    failure_count: u32,
    backoff_ms: u64,
    last_error: ?[]const u8,
    component_status: ?[]const u8,
};

/// Aggregate health data from a ChannelManager into ChannelHealthEntry slices.
/// Caller owns the returned slice.
pub fn aggregateChannelHealth(allocator: std.mem.Allocator, mgr: *const channel_manager.ChannelManager) ![]ChannelHealthEntry {
    const items = mgr.entries.items;
    if (items.len == 0) return &.{};

    const entries = try allocator.alloc(ChannelHealthEntry, items.len);
    for (items, 0..) |entry, i| {
        const component_status: ?[]const u8 = blk: {
            const comp = health.getComponentHealth(entry.name);
            if (comp) |c| break :blk c.status;
            break :blk null;
        };

        entries[i] = .{
            .name = entry.name,
            .listener_type = listenerTypeString(entry.listener_type),
            .state = entry.supervised.state,
            .failure_count = entry.supervised.restart_count,
            .backoff_ms = entry.supervised.backoff_ms,
            .last_error = if (entry.supervised.state == .gave_up or entry.supervised.state == .restarting)
                (health.getComponentHealth(entry.name) orelse health.ComponentHealth{ .status = "unknown" }).last_error
            else
                null,
            .component_status = component_status,
        };
    }
    return entries;
}

fn listenerTypeString(lt: channel_manager.ListenerType) []const u8 {
    return switch (lt) {
        .polling => "polling",
        .gateway_loop => "gateway_loop",
        .webhook_only => "webhook_only",
        .send_only => "send_only",
        .not_implemented => "not_implemented",
    };
}

fn stateString(s: dispatch.SupervisedChannel.State) []const u8 {
    return switch (s) {
        .idle => "idle",
        .running => "running",
        .restarting => "restarting",
        .gave_up => "gave_up",
    };
}

/// Serialize channel health entries to JSON.
/// Output shape: {"status":"...","uptime_seconds":N,"channels":[...]}
/// Caller owns the returned memory.
pub fn formatHealthJson(allocator: std.mem.Allocator, entries: []const ChannelHealthEntry, uptime_seconds: i64) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    const status = OverallStatus.fromChannels(entries);
    try w.print("{{\"status\":\"{s}\",\"uptime_seconds\":{d},\"channels\":[", .{ status.toSlice(), uptime_seconds });

    for (entries, 0..) |entry, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"name\":\"{s}\",\"listener_type\":\"{s}\",\"state\":\"{s}\",\"failure_count\":{d},\"backoff_ms\":{d}", .{
            entry.name,
            entry.listener_type,
            stateString(entry.state),
            entry.failure_count,
            entry.backoff_ms,
        });
        if (entry.last_error) |err_msg| {
            try w.print(",\"last_error\":\"{s}\"", .{err_msg});
        }
        if (entry.component_status) |cs| {
            try w.print(",\"component_status\":\"{s}\"", .{cs});
        }
        try w.writeByte('}');
    }

    try w.writeAll("]}");
    return try allocator.dupe(u8, buf.items);
}

/// Format channel health as human-readable text for slash commands.
/// Caller owns the returned memory.
pub fn formatHealthText(allocator: std.mem.Allocator, entries: []const ChannelHealthEntry) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("Channel Health:\n");

    if (entries.len == 0) {
        try w.writeAll("  (no channels configured)\n");
    } else {
        for (entries) |entry| {
            try w.print("  {s}: {s} ({s})", .{
                entry.name,
                stateString(entry.state),
                entry.listener_type,
            });
            if (entry.failure_count > 0) {
                try w.print(" - {d} failures", .{entry.failure_count});
                if (entry.backoff_ms > 1000) {
                    try w.print(", backoff {d}ms", .{entry.backoff_ms});
                }
            } else {
                try w.print(" - 0 failures", .{});
            }
            try w.writeByte('\n');
        }
    }

    const status = OverallStatus.fromChannels(entries);
    try w.print("Overall: {s}\n", .{status.toSlice()});

    return try allocator.dupe(u8, buf.items);
}

// ── Tests ────────────────────────────────────────────────────────

test "ChannelHealthEntry struct has required fields" {
    const entry = ChannelHealthEntry{
        .name = "telegram",
        .listener_type = "polling",
        .state = .running,
        .failure_count = 0,
        .backoff_ms = 1000,
        .last_error = null,
        .component_status = "ok",
    };
    try std.testing.expectEqualStrings("telegram", entry.name);
    try std.testing.expectEqualStrings("polling", entry.listener_type);
    try std.testing.expectEqual(dispatch.SupervisedChannel.State.running, entry.state);
    try std.testing.expectEqual(@as(u32, 0), entry.failure_count);
    try std.testing.expectEqual(@as(u64, 1000), entry.backoff_ms);
    try std.testing.expect(entry.last_error == null);
    try std.testing.expectEqualStrings("ok", entry.component_status.?);
}

test "OverallStatus.fromChannels returns healthy when all running" {
    const entries = [_]ChannelHealthEntry{
        .{ .name = "telegram", .listener_type = "polling", .state = .running, .failure_count = 0, .backoff_ms = 1000, .last_error = null, .component_status = null },
        .{ .name = "discord", .listener_type = "gateway_loop", .state = .running, .failure_count = 0, .backoff_ms = 1000, .last_error = null, .component_status = null },
    };
    try std.testing.expectEqual(OverallStatus.healthy, OverallStatus.fromChannels(&entries));
}

test "OverallStatus.fromChannels returns degraded when any restarting" {
    const entries = [_]ChannelHealthEntry{
        .{ .name = "telegram", .listener_type = "polling", .state = .running, .failure_count = 0, .backoff_ms = 1000, .last_error = null, .component_status = null },
        .{ .name = "discord", .listener_type = "gateway_loop", .state = .restarting, .failure_count = 2, .backoff_ms = 4000, .last_error = "connection lost", .component_status = null },
    };
    try std.testing.expectEqual(OverallStatus.degraded, OverallStatus.fromChannels(&entries));
}

test "OverallStatus.fromChannels returns unhealthy when any gave_up" {
    const entries = [_]ChannelHealthEntry{
        .{ .name = "telegram", .listener_type = "polling", .state = .running, .failure_count = 0, .backoff_ms = 1000, .last_error = null, .component_status = null },
        .{ .name = "discord", .listener_type = "gateway_loop", .state = .gave_up, .failure_count = 5, .backoff_ms = 60000, .last_error = "max restarts exceeded", .component_status = null },
    };
    try std.testing.expectEqual(OverallStatus.unhealthy, OverallStatus.fromChannels(&entries));
}

test "formatHealthJson produces valid JSON with status and channels" {
    const entries = [_]ChannelHealthEntry{
        .{ .name = "telegram", .listener_type = "polling", .state = .running, .failure_count = 0, .backoff_ms = 1000, .last_error = null, .component_status = "ok" },
    };
    const json = try formatHealthJson(std.testing.allocator, &entries, 3600);
    defer std.testing.allocator.free(json);

    // Verify JSON structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"uptime_seconds\":3600") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"channels\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"telegram\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"component_status\":\"ok\"") != null);
}

test "formatHealthText produces human-readable output" {
    const entries = [_]ChannelHealthEntry{
        .{ .name = "telegram", .listener_type = "polling", .state = .running, .failure_count = 0, .backoff_ms = 1000, .last_error = null, .component_status = null },
        .{ .name = "discord", .listener_type = "gateway_loop", .state = .restarting, .failure_count = 3, .backoff_ms = 8000, .last_error = "connection lost", .component_status = null },
    };
    const text = try formatHealthText(std.testing.allocator, &entries);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Channel Health:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "telegram: running (polling)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "discord: restarting (gateway_loop)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "3 failures") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "backoff 8000ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Overall: degraded") != null);
}

test "empty channel list produces valid output" {
    const entries = [_]ChannelHealthEntry{};

    const json = try formatHealthJson(std.testing.allocator, &entries, 0);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"status\":\"healthy\",\"uptime_seconds\":0,\"channels\":[]}", json);

    const text = try formatHealthText(std.testing.allocator, &entries);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Channel Health:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Overall: healthy") != null);
}

test "OverallStatus.toSlice returns correct strings" {
    try std.testing.expectEqualStrings("healthy", OverallStatus.healthy.toSlice());
    try std.testing.expectEqualStrings("degraded", OverallStatus.degraded.toSlice());
    try std.testing.expectEqualStrings("unhealthy", OverallStatus.unhealthy.toSlice());
}

test "formatHealthJson includes last_error when present" {
    const entries = [_]ChannelHealthEntry{
        .{ .name = "slack", .listener_type = "gateway_loop", .state = .restarting, .failure_count = 2, .backoff_ms = 4000, .last_error = "timeout", .component_status = null },
    };
    const json = try formatHealthJson(std.testing.allocator, &entries, 100);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"last_error\":\"timeout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"degraded\"") != null);
}

test "formatHealthText with no failures shows 0 failures" {
    const entries = [_]ChannelHealthEntry{
        .{ .name = "matrix", .listener_type = "polling", .state = .idle, .failure_count = 0, .backoff_ms = 1000, .last_error = null, .component_status = null },
    };
    const text = try formatHealthText(std.testing.allocator, &entries);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "matrix: idle (polling) - 0 failures") != null);
}
