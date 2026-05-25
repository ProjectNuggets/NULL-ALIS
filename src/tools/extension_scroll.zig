//! `extension_scroll` — scroll the user's active browser tab.
//! Dispatches a `scroll` Command frame through the per-user
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

// WARN 2.B (v1.14.23): scoped logger for cross-boundary handoff
// failures. Timeouts / OOM / disconnects are metricked + logged at the
// hub layer; this catches the dispatch catch-all and malformed frames.
const log = std.log.scoped(.extension_scroll);

pub const ExtensionScrollTool = struct {
    hub: *hub_mod.ExtensionWsHub,
    user_id: ?[]const u8 = null,
    timeout_ms: u64 = hub_mod.DEFAULT_COMMAND_TIMEOUT_MS,

    pub const tool_name = "extension_scroll";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Scroll the user's active browser tab up, down, to top, or to bottom.",
        .use_when = &.{
            "Revealing content below the fold before reading it with extension_get_text or extension_screenshot",
            "User asks the agent to 'scroll down' or 'go to the bottom' inside their browser",
            "Triggering lazy-loaded UI (infinite scroll, deferred images) before subsequent extension_* calls",
        },
        .do_not_use_for = &.{
            "extension_navigate — for changing the page URL rather than scrolling within one",
            "extension_click — for activating a control rather than scrolling",
            "extension_wait_for — for waiting on an element to appear rather than scrolling to it",
        },
        .cost_note = "Drives the user's real browser session — the scroll may trigger network requests for lazy-loaded content.",
        .completion_hint = "Returns the scrolled direction when the extension confirms the scroll landed.",
    };

    comptime {
        @import("lint.zig").lintToolDescription(
            "extension_scroll",
            tool_description_struct,
            &@import("lint.zig").ALL_TOOLS,
        );
    }

    pub const tool_description =
        "Scroll the user's active browser tab via the nullalis extension. Returns " ++
        "the scrolled direction on success, or a clear error if no extension is " ++
        "connected.";

    pub const tool_params =
        \\{"type":"object","properties":{"direction":{"type":"string","enum":["up","down","top","bottom"],"description":"Scroll direction."},"pixels":{"type":"integer","description":"Optional pixel amount for up/down (default 800)."}},"required":["direction"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ExtensionScrollTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ExtensionScrollTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const direction = root.getString(args, "direction") orelse return ToolResult.fail("missing 'direction' parameter");
        const dir_ok = std.mem.eql(u8, direction, "up") or std.mem.eql(u8, direction, "down") or std.mem.eql(u8, direction, "top") or std.mem.eql(u8, direction, "bottom");
        if (!dir_ok) return ToolResult.fail("'direction' must be one of: up, down, top, bottom");

        const user_id = self.user_id orelse return ToolResult.fail("extension_scroll not bound to a user (gateway-side wiring bug)");

        var args_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer args_buf.deinit(allocator);
        try args_buf.appendSlice(allocator, "{\"direction\":");
        try writeJsonString(allocator, &args_buf, direction);
        if (root.getInt(args, "pixels")) |p| {
            const s = try std.fmt.allocPrint(allocator, ",\"pixels\":{d}", .{p});
            defer allocator.free(s);
            try args_buf.appendSlice(allocator, s);
        }
        try args_buf.append(allocator, '}');

        const result_json = self.hub.sendCommand(
            allocator,
            user_id,
            "scroll",
            args_buf.items,
            self.timeout_ms,
        ) catch |err| switch (err) {
            error.NoExtensionConnected => return ToolResult.fail("no extension connected for this user. Ask the user to open the nullalis extension popup and connect."),
            error.Timeout => return ToolResult.fail("extension did not respond within the timeout window. The user's browser may be unresponsive or the extension may have disconnected."),
            error.ConnectionClosed => return ToolResult.fail("extension connection closed before scroll completed. Ask the user to reconnect the extension."),
            // HI-01 (v1.14.22): distinguish gateway OOM from connection-closed.
            error.ResultDeliveryOom => return ToolResult.fail("gateway ran out of memory delivering the extension result — please retry; if persistent, check the gateway available RAM."),
            else => |e| {
                log.warn("extension_scroll dispatch failed user_id='{s}' err={s}", .{ user_id, @errorName(e) });
                const msg = try std.fmt.allocPrint(allocator, "extension_scroll dispatch failed: {s}", .{@errorName(e)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
        };

        return interpretResultJson(allocator, result_json);
    }
};

fn interpretResultJson(allocator: std.mem.Allocator, json: []u8) !ToolResult {
    defer allocator.free(json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        log.warn("extension_scroll malformed result frame len={d}", .{json.len});
        return ToolResult.fail("extension returned malformed CommandResult JSON");
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            log.warn("extension_scroll non-object result frame", .{});
            return ToolResult.fail("extension returned non-object CommandResult");
        },
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

/// HI-05 (v1.14.22) — shared escaper. See src/tools/json_escape.zig
/// for the RFC 8259 §7-correct implementation that escapes all C0
/// control characters (the prior per-file inline version escaped only
/// the named escapes and let `\b` `\f` `\x01-\x07` etc. through, producing
/// invalid JSON for user-controlled selectors / text).
const writeJsonString = @import("json_escape.zig").writeJsonString;

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

test "extension_scroll tool name + spec" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionScrollTool{ .hub = &hub };
    const t = t_struct.tool();
    try std.testing.expectEqualStrings("extension_scroll", t.name());
    const s = t.spec();
    try std.testing.expect(std.mem.indexOf(u8, s.parameters_json, "direction") != null);
}

test "extension_scroll missing direction returns clear error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionScrollTool{ .hub = &hub, .user_id = "alice" };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "direction") != null);
}

test "extension_scroll rejects invalid direction" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionScrollTool{ .hub = &hub, .user_id = "alice" };
    const parsed = try root.parseTestArgs("{\"direction\":\"sideways\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "direction") != null);
}

test "extension_scroll without bound user returns wiring-bug error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionScrollTool{ .hub = &hub };
    const parsed = try root.parseTestArgs("{\"direction\":\"down\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not bound") != null);
}

test "extension_scroll with no extension connected returns user-facing error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionScrollTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"direction\":\"down\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "no extension connected") != null);
}

test "extension_scroll happy path with mock hub returns parsed result" {
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
                "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{\"scrolled\":\"down\"}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &stream, .conn = c1 }});

    var t_struct = ExtensionScrollTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"direction\":\"down\",\"pixels\":400}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    thread.join();

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "scrolled") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}

test "extension_scroll surfaces extension-side error frame" {
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
                "{{\"command_id\":\"{s}\",\"ok\":false,\"error\":{{\"code\":\"page_unloaded\",\"message\":\"the tab navigated away mid-scroll\"}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &stream, .conn = c1 }});

    var t_struct = ExtensionScrollTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"direction\":\"bottom\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);

    thread.join();

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "page_unloaded") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}
