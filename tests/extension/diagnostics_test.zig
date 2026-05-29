//! Sprint S4 — diagnostics route shape + auth-gate tests.
//!
//! Each test exercises the payload renderer directly with a real hub
//! + simulated state. The auth-gate predicates (validateInternalServiceToken,
//! extensionUserDiagnosticsSelfAllowed) are tested in gateway.zig inline.
//! This file pins the rendered JSON shape and the per-user state
//! reflection.

const std = @import("std");
const nullalis = @import("nullalis");
const hub_mod = nullalis.extension_ws.hub;
const gateway = nullalis.gateway;

const RecordingStream = struct {
    allocator: std.mem.Allocator,
    pub fn writeText(_: *anyopaque, _: []const u8) anyerror!void {}
    pub fn close(_: *anyopaque) void {}
};

test "diagnostics status: enabled=false when hub is null" {
    const input: gateway.ExtensionDiagnosticInput = .{
        .hub = null,
        .connections_total = 0,
        .auth_failed_total = 0,
    };
    const json = try gateway.extensionStatusPayload(std.testing.allocator, input);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":false") != null);
}

test "diagnostics status: total_active reflects paired count" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var s_a = RecordingStream{ .allocator = std.testing.allocator };
    var s_b = RecordingStream{ .allocator = std.testing.allocator };
    const c_a = try hub.registerConn("alice", @ptrCast(&s_a), RecordingStream.writeText, @ptrCast(&s_a), RecordingStream.close);
    defer hub.destroyConn(c_a);
    const c_b = try hub.registerConn("bob", @ptrCast(&s_b), RecordingStream.writeText, @ptrCast(&s_b), RecordingStream.close);
    defer hub.destroyConn(c_b);

    const input: gateway.ExtensionDiagnosticInput = .{
        .hub = &hub,
        .connections_total = 7,
        .auth_failed_total = 2,
    };
    const json = try gateway.extensionStatusPayload(std.testing.allocator, input);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_active\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"connections_total\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"auth_failed_total\":2") != null);
}

test "diagnostics per-user: paired=false when no conn" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    const input: gateway.ExtensionDiagnosticInput = .{
        .hub = &hub,
        .connections_total = 0,
        .auth_failed_total = 0,
    };
    const json = try gateway.extensionUserStatusPayload(std.testing.allocator, input, "alice");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"user_id\":\"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"paired\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"last_command_tool\":\"\"") != null);
}

test "diagnostics per-user: paired=true with connected_at populated" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var s = RecordingStream{ .allocator = std.testing.allocator };
    const c = try hub.registerConn("alice", @ptrCast(&s), RecordingStream.writeText, @ptrCast(&s), RecordingStream.close);
    defer hub.destroyConn(c);
    const input: gateway.ExtensionDiagnosticInput = .{
        .hub = &hub,
        .connections_total = 1,
        .auth_failed_total = 0,
    };
    const json = try gateway.extensionUserStatusPayload(std.testing.allocator, input, "alice");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"paired\":true") != null);
    // connected_at_unix is in seconds since epoch; must be >0 since
    // registerConn just stamped it from std.time.nanoTimestamp.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"connected_at_unix\":0") == null);
}
