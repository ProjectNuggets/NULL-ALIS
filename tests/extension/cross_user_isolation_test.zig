//! Sprint S4 — cross-user isolation test for the extension WS surface.
//!
//! Pins:
//!   1. Two paired users (alice, bob) each have their own conn.
//!   2. hub.sendCommand("alice", ...) writes to alice's socket only —
//!      bob's socket receives nothing.
//!   3. The auth validator ignores the frame's `user_id` and returns
//!      the mapped server-side user_id — token theft alone cannot
//!      cross-impersonate.
//!
//! These contracts are already individually tested inline in auth.zig
//! and hub.zig. This file is the SYSTEM-LEVEL pin: a regression in
//! either layer that leaked across users would fail here even if the
//! per-module tests were untouched.

const std = @import("std");
const nullalis = @import("nullalis");
const hub_mod = nullalis.extension_ws.hub;
const auth_mod = nullalis.extension_ws.auth;

const RecordingStream = struct {
    allocator: std.mem.Allocator,
    writes: std.ArrayListUnmanaged([]u8) = .empty,
    closed: bool = false,

    pub fn writeText(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *RecordingStream = @ptrCast(@alignCast(ctx));
        const copy = try self.allocator.dupe(u8, text);
        try self.writes.append(self.allocator, copy);
    }
    pub fn close(ctx: *anyopaque) void {
        const self: *RecordingStream = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
    pub fn deinit(self: *RecordingStream) void {
        for (self.writes.items) |w| self.allocator.free(w);
        self.writes.deinit(self.allocator);
    }
    pub fn writeCount(self: *RecordingStream) usize {
        return self.writes.items.len;
    }
};

test "isolation: hub.sendCommand for alice writes to alice's socket only" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var alice_stream = RecordingStream{ .allocator = std.testing.allocator };
    defer alice_stream.deinit();
    var bob_stream = RecordingStream{ .allocator = std.testing.allocator };
    defer bob_stream.deinit();

    const conn_a = try hub.registerConn("alice", @ptrCast(&alice_stream), RecordingStream.writeText, @ptrCast(&alice_stream), RecordingStream.close);
    defer hub.destroyConn(conn_a);
    const conn_b = try hub.registerConn("bob", @ptrCast(&bob_stream), RecordingStream.writeText, @ptrCast(&bob_stream), RecordingStream.close);
    defer hub.destroyConn(conn_b);

    // Spawn a deliverer that responds to whichever command alice's
    // socket received (parse command_id, echo it back via deliverResult).
    const DelivererCtx = struct {
        c: *hub_mod.ExtensionWsConn,
        stream: *RecordingStream,
        fn run(ctx: @This()) void {
            // Spin until alice's socket has at least one write.
            var attempts: usize = 0;
            while (attempts < 1000 and ctx.stream.writeCount() == 0) : (attempts += 1) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            if (ctx.stream.writeCount() == 0) return;
            const frame = ctx.stream.writes.items[0];
            // Parse `command_id` from the JSON.
            const needle = "\"command_id\":\"";
            const start_idx = std.mem.indexOf(u8, frame, needle) orelse return;
            const after = start_idx + needle.len;
            const end_idx = std.mem.indexOfScalarPos(u8, frame, after, '"') orelse return;
            const cmd_id = frame[after..end_idx];
            var reply_buf: [256]u8 = undefined;
            const reply = std.fmt.bufPrint(&reply_buf, "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{}}}}", .{cmd_id}) catch return;
            ctx.c.deliverResult(reply) catch {};
        }
    };
    var thread = try std.Thread.spawn(.{}, DelivererCtx.run, .{DelivererCtx{ .c = conn_a, .stream = &alice_stream }});
    defer thread.join();

    const result = try hub.sendCommand(std.testing.allocator, "alice", "navigate", "{\"url\":\"https://x\"}", 500);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), alice_stream.writeCount());
    try std.testing.expectEqual(@as(usize, 0), bob_stream.writeCount());
    try std.testing.expect(!bob_stream.closed);
}

test "isolation: hub.sendCommand for unregistered user returns NoExtensionConnected and writes nothing" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var alice_stream = RecordingStream{ .allocator = std.testing.allocator };
    defer alice_stream.deinit();
    const conn_a = try hub.registerConn("alice", @ptrCast(&alice_stream), RecordingStream.writeText, @ptrCast(&alice_stream), RecordingStream.close);
    defer hub.destroyConn(conn_a);

    const result = hub.sendCommand(std.testing.allocator, "carol", "click", "{}", 50);
    try std.testing.expectError(error.NoExtensionConnected, result);
    try std.testing.expectEqual(@as(usize, 0), alice_stream.writeCount());
}

test "isolation: auth validator ignores inbound user_id even with valid token (re-pinned at system level)" {
    const entries = [_]auth_mod.TokenEntry{
        .{ .token = "tok-alice", .user_id = "alice" },
        .{ .token = "tok-bob", .user_id = "bob" },
    };
    const v = auth_mod.AuthValidator{ .entries = &entries };
    // Holder of alice's token claims to be bob.
    const auth = "{\"type\":\"auth\",\"token\":\"tok-alice\",\"user_id\":\"bob\"}";
    const d = v.validate(auth);
    try std.testing.expect(d.ok);
    try std.testing.expectEqualStrings("alice", d.user_id.?);
    // The wrong user_id (bob) is NEVER returned.
    try std.testing.expect(!std.mem.eql(u8, d.user_id.?, "bob"));
}

test "isolation: empty entries list rejects every token (closed by default)" {
    const v = auth_mod.AuthValidator{ .entries = &.{} };
    const auth = "{\"type\":\"auth\",\"token\":\"any\",\"user_id\":\"alice\"}";
    const d = v.validate(auth);
    try std.testing.expect(!d.ok);
    try std.testing.expectEqualStrings("invalid_token", d.reason.?);
}
