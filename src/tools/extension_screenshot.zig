//! `extension_screenshot` — capture a PNG screenshot of the user's
//! active tab. Dispatches a `screenshot` Command frame through the
//! per-user `ExtensionWsHub` and awaits a `CommandResult`.
//!
//! Pattern mirrors `extension_navigate.zig` (see Wave 3B recipe in
//! `docs/extension-ws-contract.md`). Runs in the background service
//! worker per `.spike/nullalis-extension/docs/ARCHITECTURE.md`.

const std = @import("std");
const root = @import("root.zig");
const hub_mod = @import("../extension_ws/hub.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

pub const ExtensionScreenshotTool = struct {
    hub: *hub_mod.ExtensionWsHub,
    user_id: ?[]const u8 = null,
    timeout_ms: u64 = hub_mod.DEFAULT_COMMAND_TIMEOUT_MS,

    pub const tool_name = "extension_screenshot";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Capture a PNG screenshot of the user's active browser tab.",
        .use_when = &.{
            "Agent needs to visually inspect the page state the user is currently looking at",
            "Verifying that a previous extension_click or extension_fill_form produced the expected UI",
            "User asks 'what does my screen look like right now?' or wants a snapshot of a logged-in view",
        },
        .do_not_use_for = &.{
            "extension_get_text — for extracting page text rather than a visual capture",
            "extension_get_dom — for inspecting the HTML structure rather than a visual capture",
            "screenshot — for capturing the operator's local terminal rather than the user's browser",
        },
        .cost_note = "Returns up to ~6 MB base64-encoded PNG; the per-turn weight budget should account for that. The 6 MB advertised cap reserves headroom under the hub's 8 MB WebSocket frame ceiling for JSON envelope overhead.",
        .completion_hint = "Returns a base64 data URL of the captured PNG plus the full_page flag.",
    };

    comptime {
        @import("lint.zig").lintToolDescription(
            "extension_screenshot",
            tool_description_struct,
            &@import("lint.zig").ALL_TOOLS,
        );
    }

    pub const tool_description =
        "Capture a PNG screenshot of the user's active browser tab via the nullalis " ++
        "extension. Returns a base64 data URL (cap ~6 MB base64-encoded PNG; the " ++
        "transport ceiling is 8 MB and the JSON envelope eats the difference) on " ++
        "success, or a clear error if no extension is connected. Larger screenshots " ++
        "are rejected by the transport — crop or split the capture.";

    pub const tool_params =
        \\{"type":"object","properties":{"full_page":{"type":"boolean","description":"If true, capture the full scrollable page (extension v1 may fall back to viewport)."}}}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ExtensionScreenshotTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ExtensionScreenshotTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const user_id = self.user_id orelse return ToolResult.fail("extension_screenshot not bound to a user (gateway-side wiring bug)");

        var args_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer args_buf.deinit(allocator);
        try args_buf.append(allocator, '{');
        if (root.getBool(args, "full_page")) |fp| {
            if (fp) try args_buf.appendSlice(allocator, "\"full_page\":true") else try args_buf.appendSlice(allocator, "\"full_page\":false");
        }
        try args_buf.append(allocator, '}');

        const result_json = self.hub.sendCommand(
            allocator,
            user_id,
            "screenshot",
            args_buf.items,
            self.timeout_ms,
        ) catch |err| switch (err) {
            error.NoExtensionConnected => return ToolResult.fail("no extension connected for this user. Ask the user to open the nullalis extension popup and connect."),
            error.Timeout => return ToolResult.fail("extension did not respond within the timeout window. The user's browser may be unresponsive or the extension may have disconnected."),
            error.ConnectionClosed => return ToolResult.fail("extension connection closed before screenshot completed — this may indicate the screenshot exceeded the 8 MB WebSocket frame cap. Try full_page:false, crop the viewport, or split the capture into multiple regions; otherwise ask the user to reconnect the extension."),
            // HI-01 (v1.14.22): distinguish gateway OOM from connection-closed.
            error.ResultDeliveryOom => return ToolResult.fail("gateway ran out of memory delivering the extension result — please retry; if persistent, check the gateway available RAM."),
            else => |e| {
                const msg = try std.fmt.allocPrint(allocator, "extension_screenshot dispatch failed: {s}", .{@errorName(e)});
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

test "extension_screenshot tool name + spec" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionScreenshotTool{ .hub = &hub };
    const t = t_struct.tool();
    try std.testing.expectEqualStrings("extension_screenshot", t.name());
    const s = t.spec();
    try std.testing.expect(std.mem.indexOf(u8, s.parameters_json, "full_page") != null);
}

test "extension_screenshot without bound user returns wiring-bug error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionScreenshotTool{ .hub = &hub };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not bound") != null);
}

test "extension_screenshot rejects non-bool full_page silently (defaults to false)" {
    // Non-bool values are simply ignored — getBool returns null and the
    // arg is omitted from the wire payload. We assert this by checking
    // we still reach the no-extension-connected path (no early reject).
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionScreenshotTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"full_page\":\"yes\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "no extension connected") != null);
}

test "extension_screenshot with no extension connected returns user-facing error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionScreenshotTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "no extension connected") != null);
}

test "extension_screenshot happy path with mock hub returns parsed result" {
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
                "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{\"data_url\":\"data:image/png;base64,iVBORw0KGgo=\",\"full_page\":false}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &stream, .conn = c1 }});

    var t_struct = ExtensionScreenshotTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"full_page\":false}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    thread.join();

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data_url") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "iVBORw0") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}

test "extension_screenshot surfaces extension-side error frame" {
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
                "{{\"command_id\":\"{s}\",\"ok\":false,\"error\":{{\"code\":\"capture_failed\",\"message\":\"chrome.tabs.captureVisibleTab denied\"}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &stream, .conn = c1 }});

    var t_struct = ExtensionScreenshotTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);

    thread.join();

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "capture_failed") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}
