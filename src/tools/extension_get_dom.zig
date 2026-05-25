//! `extension_get_dom` — read HTML structure from the user's connected
//! browser. Dispatches a `get_dom` Command frame through the per-user
//! `ExtensionWsHub` and awaits a `CommandResult`.
//!
//! Pattern mirrors `extension_navigate.zig` (see Wave 3B recipe in
//! `docs/extension-ws-contract.md`). Runs in the content script per
//! `.spike/nullalis-extension/docs/ARCHITECTURE.md`. Cap: 1 MB of HTML
//! per call; the extension returns `truncated:true` when capped.

const std = @import("std");
const root = @import("root.zig");
const hub_mod = @import("../extension_ws/hub.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

pub const ExtensionGetDomTool = struct {
    hub: *hub_mod.ExtensionWsHub,
    user_id: ?[]const u8 = null,
    timeout_ms: u64 = hub_mod.DEFAULT_COMMAND_TIMEOUT_MS,

    pub const tool_name = "extension_get_dom";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Read HTML structure from the user's connected browser page or selector.",
        .use_when = &.{
            "Agent needs the raw HTML structure of a logged-in page (attributes, tag tree, hidden fields)",
            "Finding selectors for follow-up extension_click or extension_type by inspecting markup",
            "Diagnosing why an extension_get_text or extension_click failed by reading the surrounding DOM",
        },
        .do_not_use_for = &.{
            "extension_get_text — for rendered text rather than HTML markup",
            "extension_screenshot — for a visual capture rather than HTML",
            "web_fetch — for fetching public HTML where no login is required",
        },
        .cost_note = "Returns up to 1 MB of HTML; the extension truncates beyond that and sets truncated:true.",
        .completion_hint = "Returns {html, truncated} where truncated indicates the 1 MB cap was hit.",
    };

    comptime {
        @import("lint.zig").lintToolDescription(
            "extension_get_dom",
            tool_description_struct,
            &@import("lint.zig").ALL_TOOLS,
        );
    }

    pub const tool_description =
        "Read HTML structure from the user's connected browser page (or a specific " ++
        "selector) via the nullalis extension. Cap: 1 MB; truncated:true when the " ++
        "cap is hit. Returns {html, truncated} on success, or a clear error if no " ++
        "extension is connected.";

    pub const tool_params =
        \\{"type":"object","properties":{"selector":{"type":"string","description":"Optional CSS selector to scope extraction; omit for whole-page HTML."}}}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ExtensionGetDomTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ExtensionGetDomTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const user_id = self.user_id orelse return ToolResult.fail("extension_get_dom not bound to a user (gateway-side wiring bug)");

        var args_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer args_buf.deinit(allocator);
        try args_buf.append(allocator, '{');
        if (root.getString(args, "selector")) |sel| {
            if (sel.len > 0) {
                try args_buf.appendSlice(allocator, "\"selector\":");
                try writeJsonString(allocator, &args_buf, sel);
            }
        }
        try args_buf.append(allocator, '}');

        const result_json = self.hub.sendCommand(
            allocator,
            user_id,
            "get_dom",
            args_buf.items,
            self.timeout_ms,
        ) catch |err| switch (err) {
            error.NoExtensionConnected => return ToolResult.fail("no extension connected for this user. Ask the user to open the nullalis extension popup and connect."),
            error.Timeout => return ToolResult.fail("extension did not respond within the timeout window. The user's browser may be unresponsive or the extension may have disconnected."),
            error.ConnectionClosed => return ToolResult.fail("extension connection closed before get_dom completed. Ask the user to reconnect the extension."),
            else => |e| {
                const msg = try std.fmt.allocPrint(allocator, "extension_get_dom dispatch failed: {s}", .{@errorName(e)});
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

test "extension_get_dom tool name + spec" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionGetDomTool{ .hub = &hub };
    const t = t_struct.tool();
    try std.testing.expectEqualStrings("extension_get_dom", t.name());
    const s = t.spec();
    try std.testing.expect(std.mem.indexOf(u8, s.parameters_json, "selector") != null);
}

test "extension_get_dom rejects non-string selector silently (defaults to whole page)" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionGetDomTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"selector\":42}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "no extension connected") != null);
}

test "extension_get_dom without bound user returns wiring-bug error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionGetDomTool{ .hub = &hub };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not bound") != null);
}

test "extension_get_dom with no extension connected returns user-facing error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionGetDomTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "no extension connected") != null);
}

test "extension_get_dom happy path with mock hub returns parsed result" {
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
                "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{\"html\":\"<div>hi</div>\",\"truncated\":false}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &stream, .conn = c1 }});

    var t_struct = ExtensionGetDomTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"selector\":\"#main\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    thread.join();

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "html") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "truncated") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}

test "extension_get_dom surfaces extension-side error frame" {
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
                "{{\"command_id\":\"{s}\",\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"no element matches #missing\"}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &stream, .conn = c1 }});

    var t_struct = ExtensionGetDomTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"selector\":\"#missing\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);

    thread.join();

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not_found") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}
