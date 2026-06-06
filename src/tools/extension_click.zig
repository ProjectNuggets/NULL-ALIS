//! `extension_click` — click an element matching a CSS selector inside
//! the user's connected browser. Dispatches a `click` Command frame
//! through the per-user `ExtensionWsHub` and awaits a `CommandResult`.
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

// WARN 2.B (v1.14.23): scoped logger for failure-path operability.
// The hub-layer (`extension_ws/hub.zig`) already metrics + logs
// timeouts / OOM / disconnects via `sendCommand`; this logger adds
// signal for malformed extension-side result frames and dispatch
// errors that bubble out of the `else => |e|` catch-all in the
// hub-error switch (where the result class isn't a known sentinel).
const log = std.log.scoped(.extension_click);

pub const ExtensionClickTool = struct {
    hub: *hub_mod.ExtensionWsHub,
    user_id: ?[]const u8 = null,
    timeout_ms: u64 = hub_mod.DEFAULT_COMMAND_TIMEOUT_MS,

    pub const tool_name = "extension_click";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Click an element in the user's connected browser using a CSS selector.",
        .use_when = &.{
            "User asks the agent to 'click <button>' or 'press <link>' inside their already-running browser session",
            "Following extension_navigate or extension_fill_form with the next action in a workflow",
            "Activating a logged-in control that public scraping cannot reach (e.g. an in-app submit button)",
        },
        .do_not_use_for = &.{
            "extension_type — for typing characters into an input rather than clicking it",
            "extension_navigate — for following a link to a known URL without clicking",
            "browser_navigate — for loading a fresh URL in a remote agent_browser session instead of the user's live tab",
        },
        .cost_note = "Drives the user's real browser session — actions are visible and may affect logged-in state.",
        .completion_hint = "Returns the clicked selector when the extension confirms the click landed.",
    };

    comptime {
        @import("lint.zig").lintToolDescription(
            "extension_click",
            tool_description_struct,
            &@import("lint.zig").ALL_TOOLS,
        );
    }

    pub const tool_description =
        "Click an element in the user's connected browser using a CSS selector. " ++
        "Requires the nullalis browser extension to be connected to this gateway " ++
        "for the current user. Returns the clicked selector on success, or a " ++
        "clear error if no extension is connected.";

    pub const tool_params =
        \\{"type":"object","properties":{"selector":{"type":"string","description":"CSS selector for the element to click."},"timeout_ms":{"type":"integer","description":"Per-call timeout in milliseconds (default 30000)."}},"required":["selector"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ExtensionClickTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ExtensionClickTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const selector = root.getString(args, "selector") orelse return ToolResult.fail("missing 'selector' parameter");
        if (selector.len == 0) return ToolResult.fail("'selector' must be a non-empty string");

        const user_id = self.user_id orelse return ToolResult.fail("extension_click not bound to a user (gateway-side wiring bug)");

        var args_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer args_buf.deinit(allocator);
        try args_buf.appendSlice(allocator, "{\"selector\":");
        try writeJsonString(allocator, &args_buf, selector);
        if (root.getInt(args, "timeout_ms")) |t| {
            const t_str = try std.fmt.allocPrint(allocator, ",\"timeout_ms\":{d}", .{t});
            defer allocator.free(t_str);
            try args_buf.appendSlice(allocator, t_str);
        }
        try args_buf.append(allocator, '}');

        const result_json = self.hub.sendCommand(
            allocator,
            user_id,
            "click",
            args_buf.items,
            self.timeout_ms,
        ) catch |err| switch (err) {
            error.NoExtensionConnected => return ToolResult.fail("no extension connected for this user. Ask the user to open the nullalis extension popup and connect."),
            error.Timeout => return ToolResult.fail("extension did not respond within the timeout window. The user's browser may be unresponsive or the extension may have disconnected."),
            error.ConnectionClosed => return ToolResult.fail("extension connection closed before the click completed. Ask the user to reconnect the extension."),
            // HI-01 (v1.14.22): distinguish gateway OOM from connection-closed.
            error.ResultDeliveryOom => return ToolResult.fail("gateway ran out of memory delivering the extension result — please retry; if persistent, check the gateway available RAM."),
            else => |e| {
                log.warn("extension_click dispatch failed user_id='{s}' err={s}", .{ user_id, @errorName(e) });
                const msg = try std.fmt.allocPrint(allocator, "extension_click dispatch failed: {s}", .{@errorName(e)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
        };

        return interpretResultJson(allocator, result_json);
    }
};

fn interpretResultJson(allocator: std.mem.Allocator, json: []u8) !ToolResult {
    defer allocator.free(json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        log.warn("extension_click malformed result frame len={d}", .{json.len});
        return ToolResult.fail("extension returned malformed CommandResult JSON");
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            log.warn("extension_click non-object result frame", .{});
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

test "extension_click tool name + spec" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionClickTool{ .hub = &hub };
    const t = t_struct.tool();
    try std.testing.expectEqualStrings("extension_click", t.name());
    const s = t.spec();
    try std.testing.expect(std.mem.indexOf(u8, s.parameters_json, "selector") != null);
}

test "extension_click missing selector returns clear error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionClickTool{ .hub = &hub, .user_id = "alice" };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "selector") != null);
}

test "extension_click rejects empty selector" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionClickTool{ .hub = &hub, .user_id = "alice" };
    const parsed = try root.parseTestArgs("{\"selector\":\"\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "selector") != null);
}

test "extension_click without bound user returns wiring-bug error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionClickTool{ .hub = &hub };
    const parsed = try root.parseTestArgs("{\"selector\":\"button#submit\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not bound") != null);
}

test "extension_click with no extension connected returns user-facing error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionClickTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"selector\":\"button\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "no extension connected") != null);
}

test "extension_click happy path with mock hub returns parsed result" {
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
                "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{\"clicked\":\"button#submit\"}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &stream, .conn = c1 }});

    var t_struct = ExtensionClickTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"selector\":\"button#submit\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    thread.join();

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "clicked") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}

test "extension_click surfaces extension-side error frame" {
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
                "{{\"command_id\":\"{s}\",\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"no element matches button#nope\"}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &stream, .conn = c1 }});

    var t_struct = ExtensionClickTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"selector\":\"button#nope\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);

    thread.join();

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not_found") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}
