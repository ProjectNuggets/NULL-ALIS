//! `extension_type` — type text into an element in the user's connected
//! browser. Dispatches a `type` Command frame through the per-user
//! `ExtensionWsHub` and awaits a `CommandResult`.
//!
//! Pattern mirrors `extension_navigate.zig` (see Wave 3B recipe in
//! `docs/extension-ws-contract.md`). Runs in the content script per
//! `.spike/nullalis-extension/docs/ARCHITECTURE.md`.

const std = @import("std");
const root = @import("root.zig");
const hub_mod = @import("../extension_ws/hub.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// Cap text payload at 10 KB. Anything bigger is almost certainly a
/// mistake (the agent meant to upload a file, not type a paragraph),
/// and shipping 1 MB to a content script's `dispatchEvent` loop is a
/// reliability hazard.
pub const MAX_TYPE_TEXT_LEN: usize = 10_000;

/// Cap per-keystroke delay at 1 s. Anything bigger turns "type Hello"
/// into a multi-minute operation — the per-call timeout would fire
/// before the second character lands.
pub const MAX_TYPE_DELAY_MS: i64 = 1_000;

pub const ExtensionTypeTool = struct {
    hub: *hub_mod.ExtensionWsHub,
    user_id: ?[]const u8 = null,
    timeout_ms: u64 = hub_mod.DEFAULT_COMMAND_TIMEOUT_MS,

    pub const tool_name = "extension_type";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Type text into a focused input in the user's connected browser.",
        .use_when = &.{
            "User asks the agent to 'type <text> into <field>' inside their already-running browser session",
            "Filling a single input as a follow-up to extension_click or extension_navigate",
            "Entering credentials or messages a public scraper cannot supply (e.g. an in-app reply box)",
        },
        .do_not_use_for = &.{
            "extension_fill_form — for filling multiple fields atomically in one round-trip",
            "extension_click — for activating a button rather than typing characters",
            "shell — for piping text into a local CLI rather than a browser input",
        },
        .cost_note = "Drives the user's real browser session — actions are visible and may submit logged-in forms.",
        .completion_hint = "Returns the typed selector when the extension confirms the characters landed.",
    };

    comptime {
        @import("lint.zig").lintToolDescription(
            "extension_type",
            tool_description_struct,
            &@import("lint.zig").ALL_TOOLS,
        );
    }

    pub const tool_description =
        "Type text into a focused input in the user's connected browser via the " ++
        "nullalis extension. Cap: 10 KB of text per call, per-key delay ≤ 1000 ms. " ++
        "Returns the typed selector on success, or a clear error if no extension " ++
        "is connected.";

    pub const tool_params =
        \\{"type":"object","properties":{"selector":{"type":"string","description":"CSS selector for the input element."},"text":{"type":"string","description":"Text to type (cap 10000 chars)."},"delay_ms":{"type":"integer","description":"Optional per-keystroke delay in ms (cap 1000)."},"timeout_ms":{"type":"integer","description":"Per-call timeout in ms (default 30000)."}},"required":["selector","text"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ExtensionTypeTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ExtensionTypeTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const selector = root.getString(args, "selector") orelse return ToolResult.fail("missing 'selector' parameter");
        if (selector.len == 0) return ToolResult.fail("'selector' must be a non-empty string");

        const text = root.getString(args, "text") orelse return ToolResult.fail("missing 'text' parameter");
        if (text.len > MAX_TYPE_TEXT_LEN) {
            return ToolResult.fail("'text' exceeds 10000-character cap; split into multiple calls or use a file_write + paste workflow");
        }

        if (root.getInt(args, "delay_ms")) |d| {
            if (d < 0 or d > MAX_TYPE_DELAY_MS) {
                return ToolResult.fail("'delay_ms' must be between 0 and 1000");
            }
        }

        const user_id = self.user_id orelse return ToolResult.fail("extension_type not bound to a user (gateway-side wiring bug)");

        var args_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer args_buf.deinit(allocator);
        try args_buf.appendSlice(allocator, "{\"selector\":");
        try writeJsonString(allocator, &args_buf, selector);
        try args_buf.appendSlice(allocator, ",\"text\":");
        try writeJsonString(allocator, &args_buf, text);
        if (root.getInt(args, "delay_ms")) |d| {
            const s = try std.fmt.allocPrint(allocator, ",\"delay_ms\":{d}", .{d});
            defer allocator.free(s);
            try args_buf.appendSlice(allocator, s);
        }
        if (root.getInt(args, "timeout_ms")) |t| {
            const s = try std.fmt.allocPrint(allocator, ",\"timeout_ms\":{d}", .{t});
            defer allocator.free(s);
            try args_buf.appendSlice(allocator, s);
        }
        try args_buf.append(allocator, '}');

        const result_json = self.hub.sendCommand(
            allocator,
            user_id,
            "type",
            args_buf.items,
            self.timeout_ms,
        ) catch |err| switch (err) {
            error.NoExtensionConnected => return ToolResult.fail("no extension connected for this user. Ask the user to open the nullalis extension popup and connect."),
            error.Timeout => return ToolResult.fail("extension did not respond within the timeout window. The user's browser may be unresponsive or the extension may have disconnected."),
            error.ConnectionClosed => return ToolResult.fail("extension connection closed before the type completed. Ask the user to reconnect the extension."),
            else => |e| {
                const msg = try std.fmt.allocPrint(allocator, "extension_type dispatch failed: {s}", .{@errorName(e)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
        };

        return interpretResultJson(allocator, result_json);
    }
};

fn interpretResultJson(allocator: std.mem.Allocator, json: []u8) !ToolResult {
    defer allocator.free(json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        return ToolResult.fail("extension returned malformed CommandResult JSON");
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return ToolResult.fail("extension returned non-object CommandResult"),
    };

    const ok = if (obj.get("ok")) |v| switch (v) {
        .bool => |b| b,
        else => false,
    } else false;

    if (!ok) {
        const err_obj = if (obj.get("error")) |v| switch (v) {
            .object => |o| o,
            else => null,
        } else null;
        const code = if (err_obj) |eo| if (eo.get("code")) |c| switch (c) {
            .string => |s| s,
            else => "unknown_error",
        } else "unknown_error" else "unknown_error";
        const message = if (err_obj) |eo| if (eo.get("message")) |m| switch (m) {
            .string => |s| s,
            else => "no message",
        } else "no message" else "no message";

        const msg = try std.fmt.allocPrint(allocator, "extension reported error [{s}]: {s}", .{ code, message });
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }

    if (obj.get("result")) |result_val| {
        const out = try std.json.Stringify.valueAlloc(allocator, result_val, .{});
        return ToolResult{ .success = true, .output = out };
    }
    const out = try allocator.dupe(u8, "{}");
    return ToolResult{ .success = true, .output = out };
}

fn writeJsonString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

// ── Tests ────────────────────────────────────────────────────────────

const TestStream = struct {
    written: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,
    pub fn writeText(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        try self.written.appendSlice(self.allocator, text);
    }
    pub fn closeFn(_: *anyopaque) void {}
    pub fn deinit(self: *@This()) void {
        self.written.deinit(self.allocator);
    }
};

test "extension_type tool name + spec" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionTypeTool{ .hub = &hub };
    const t = t_struct.tool();
    try std.testing.expectEqualStrings("extension_type", t.name());
    const s = t.spec();
    try std.testing.expect(std.mem.indexOf(u8, s.parameters_json, "selector") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.parameters_json, "text") != null);
}

test "extension_type missing selector returns clear error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionTypeTool{ .hub = &hub, .user_id = "alice" };
    const parsed = try root.parseTestArgs("{\"text\":\"hi\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "selector") != null);
}

test "extension_type missing text returns clear error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionTypeTool{ .hub = &hub, .user_id = "alice" };
    const parsed = try root.parseTestArgs("{\"selector\":\"#in\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "text") != null);
}

test "extension_type rejects oversized text" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionTypeTool{ .hub = &hub, .user_id = "alice" };

    const oversized = try std.testing.allocator.alloc(u8, MAX_TYPE_TEXT_LEN + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"selector\":\"#in\",\"text\":\"{s}\"}}", .{oversized});
    defer std.testing.allocator.free(json);

    const parsed = try root.parseTestArgs(json);
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "10000") != null);
}

test "extension_type without bound user returns wiring-bug error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionTypeTool{ .hub = &hub };
    const parsed = try root.parseTestArgs("{\"selector\":\"#in\",\"text\":\"hi\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not bound") != null);
}

test "extension_type with no extension connected returns user-facing error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionTypeTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"selector\":\"#in\",\"text\":\"hi\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "no extension connected") != null);
}

test "extension_type happy path with mock hub returns parsed result" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var stream = TestStream{ .allocator = std.testing.allocator };
    defer stream.deinit();
    const c1 = try hub.registerConn("alice", &stream, TestStream.writeText, &stream, TestStream.closeFn);

    const HelperCtx = struct {
        stream: *TestStream,
        conn: *hub_mod.ExtensionWsConn,
    };
    const Helper = struct {
        fn run(ctx: HelperCtx) void {
            var attempts: usize = 0;
            while (attempts < 1000) : (attempts += 1) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                if (ctx.stream.written.items.len > 0) break;
            }
            const written = ctx.stream.written.items;
            const id_marker = "\"command_id\":\"";
            const id_start = std.mem.indexOf(u8, written, id_marker).?;
            const after = written[id_start + id_marker.len ..];
            const id_end = std.mem.indexOfScalar(u8, after, '"').?;
            const id = after[0..id_end];
            const result_json = std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{\"typed\":\"#in\"}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &stream, .conn = c1 }});

    var t_struct = ExtensionTypeTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"selector\":\"#in\",\"text\":\"hello\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    thread.join();

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "typed") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}

test "extension_type surfaces extension-side error frame" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

    var stream = TestStream{ .allocator = std.testing.allocator };
    defer stream.deinit();
    const c1 = try hub.registerConn("alice", &stream, TestStream.writeText, &stream, TestStream.closeFn);

    const HelperCtx = struct {
        stream: *TestStream,
        conn: *hub_mod.ExtensionWsConn,
    };
    const Helper = struct {
        fn run(ctx: HelperCtx) void {
            var attempts: usize = 0;
            while (attempts < 1000) : (attempts += 1) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                if (ctx.stream.written.items.len > 0) break;
            }
            const written = ctx.stream.written.items;
            const id_marker = "\"command_id\":\"";
            const id_start = std.mem.indexOf(u8, written, id_marker).?;
            const after = written[id_start + id_marker.len ..];
            const id_end = std.mem.indexOfScalar(u8, after, '"').?;
            const id = after[0..id_end];
            const result_json = std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"command_id\":\"{s}\",\"ok\":false,\"error\":{{\"code\":\"not_editable\",\"message\":\"element is not an input\"}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &stream, .conn = c1 }});

    var t_struct = ExtensionTypeTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"selector\":\"div\",\"text\":\"x\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);

    thread.join();

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not_editable") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}
