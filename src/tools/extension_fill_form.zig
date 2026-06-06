//! `extension_fill_form` — fill multiple form fields atomically in the
//! user's connected browser. Dispatches a `fill_form` Command frame
//! through the per-user `ExtensionWsHub` and awaits a `CommandResult`.
//!
//! Pattern mirrors `extension_navigate.zig` (see Wave 3B recipe in
//! `docs/extension-ws-contract.md`). Runs in the content script per
//! `clients/extension/docs/ARCHITECTURE.md`.

const std = @import("std");
const root = @import("root.zig");
const hub_mod = @import("../extension_ws/hub.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

// WARN 2.B (v1.14.23): scoped logger for cross-boundary handoff
// failures. The hub-layer already metrics + logs timeouts / OOM /
// disconnects centrally; this logger adds signal for the local
// dispatch-error catch-all and malformed result frames.
const log = std.log.scoped(.extension_fill_form);

/// Cap the number of fields per call. 50 is enough for any realistic
/// form (long surveys average 20–30 fields); anything bigger is almost
/// certainly an agent loop or a misuse.
pub const MAX_FILL_FORM_FIELDS: usize = 50;

/// Per-field text cap shared with extension_type — same reliability
/// envelope (10 KB per field, 50 fields ⇒ ~500 KB max payload).
pub const MAX_FILL_FIELD_TEXT_LEN: usize = 10_000;

pub const ExtensionFillFormTool = struct {
    hub: *hub_mod.ExtensionWsHub,
    user_id: ?[]const u8 = null,
    timeout_ms: u64 = hub_mod.DEFAULT_COMMAND_TIMEOUT_MS,

    pub const tool_name = "extension_fill_form";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Fill multiple form fields atomically in the user's connected browser.",
        .use_when = &.{
            "User asks the agent to fill in a multi-field form (signup, profile, checkout) in their browser session",
            "Several inputs need values set before a single submit (more efficient than per-field extension_type calls)",
            "Replaying a known form layout where the selectors and values are determined ahead of time",
        },
        .do_not_use_for = &.{
            "extension_type — for typing into a single field rather than a batch",
            "extension_click — for activating the submit button after the form is filled",
            "shell — for sending data to a local CLI rather than a browser form",
        },
        .cost_note = "Drives the user's real browser session — actions are visible and may submit logged-in forms.",
        .completion_hint = "Returns the count of filled fields when the extension confirms each value landed.",
    };

    comptime {
        @import("lint.zig").lintToolDescription(
            "extension_fill_form",
            tool_description_struct,
            &@import("lint.zig").ALL_TOOLS,
        );
    }

    pub const tool_description =
        "Fill multiple form fields atomically in the user's connected browser via " ++
        "the nullalis extension. Cap: 50 fields per call, 10 KB per field. " ++
        "Returns the filled-field count on success, or a clear error if no " ++
        "extension is connected.";

    pub const tool_params =
        \\{"type":"object","properties":{"fields":{"type":"array","description":"Array of {selector,text} objects (cap 50 fields, 10000 chars per field).","items":{"type":"object","properties":{"selector":{"type":"string"},"text":{"type":"string"}},"required":["selector","text"]}}},"required":["fields"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ExtensionFillFormTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ExtensionFillFormTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const fields = root.getArray(args, "fields") orelse return ToolResult.fail("missing 'fields' parameter (expected array of {selector,text})");
        if (fields.len == 0) return ToolResult.fail("'fields' must contain at least one entry");
        if (fields.len > MAX_FILL_FORM_FIELDS) {
            return ToolResult.fail("'fields' exceeds 50-entry cap; split into multiple fill_form calls");
        }

        // Pre-validate each entry. We do this BEFORE the hub roundtrip so
        // a malformed batch fails fast rather than after a remote call.
        for (fields) |entry| {
            const obj = switch (entry) {
                .object => |o| o,
                else => return ToolResult.fail("'fields' entries must be objects with 'selector' and 'text'"),
            };
            const sel = obj.get("selector") orelse return ToolResult.fail("'fields' entry missing 'selector'");
            const sel_str = switch (sel) {
                .string => |s| s,
                else => return ToolResult.fail("'fields[].selector' must be a string"),
            };
            if (sel_str.len == 0) return ToolResult.fail("'fields[].selector' must be non-empty");
            const txt = obj.get("text") orelse return ToolResult.fail("'fields' entry missing 'text'");
            const txt_str = switch (txt) {
                .string => |s| s,
                else => return ToolResult.fail("'fields[].text' must be a string"),
            };
            if (txt_str.len > MAX_FILL_FIELD_TEXT_LEN) {
                return ToolResult.fail("'fields[].text' exceeds 10000-character per-field cap");
            }
        }

        const user_id = self.user_id orelse return ToolResult.fail("extension_fill_form not bound to a user (gateway-side wiring bug)");

        var args_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer args_buf.deinit(allocator);
        try args_buf.appendSlice(allocator, "{\"fields\":[");
        for (fields, 0..) |entry, i| {
            if (i > 0) try args_buf.append(allocator, ',');
            const obj = entry.object;
            const sel = obj.get("selector").?.string;
            const txt = obj.get("text").?.string;
            try args_buf.appendSlice(allocator, "{\"selector\":");
            try writeJsonString(allocator, &args_buf, sel);
            try args_buf.appendSlice(allocator, ",\"text\":");
            try writeJsonString(allocator, &args_buf, txt);
            try args_buf.append(allocator, '}');
        }
        try args_buf.appendSlice(allocator, "]}");

        const result_json = self.hub.sendCommand(
            allocator,
            user_id,
            "fill_form",
            args_buf.items,
            self.timeout_ms,
        ) catch |err| switch (err) {
            error.NoExtensionConnected => return ToolResult.fail("no extension connected for this user. Ask the user to open the nullalis extension popup and connect."),
            error.Timeout => return ToolResult.fail("extension did not respond within the timeout window. The user's browser may be unresponsive or the extension may have disconnected."),
            error.ConnectionClosed => return ToolResult.fail("extension connection closed before fill_form completed. Ask the user to reconnect the extension."),
            // HI-01 (v1.14.22): distinguish gateway OOM from connection-closed.
            error.ResultDeliveryOom => return ToolResult.fail("gateway ran out of memory delivering the extension result — please retry; if persistent, check the gateway available RAM."),
            else => |e| {
                log.warn("extension_fill_form dispatch failed user_id='{s}' err={s}", .{ user_id, @errorName(e) });
                const msg = try std.fmt.allocPrint(allocator, "extension_fill_form dispatch failed: {s}", .{@errorName(e)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
        };

        return interpretResultJson(allocator, result_json);
    }
};

fn interpretResultJson(allocator: std.mem.Allocator, json: []u8) !ToolResult {
    defer allocator.free(json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        log.warn("extension_fill_form malformed result frame len={d}", .{json.len});
        return ToolResult.fail("extension returned malformed CommandResult JSON");
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            log.warn("extension_fill_form non-object result frame", .{});
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

test "extension_fill_form tool name + spec" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionFillFormTool{ .hub = &hub };
    const t = t_struct.tool();
    try std.testing.expectEqualStrings("extension_fill_form", t.name());
    const s = t.spec();
    try std.testing.expect(std.mem.indexOf(u8, s.parameters_json, "fields") != null);
}

test "extension_fill_form missing fields returns clear error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionFillFormTool{ .hub = &hub, .user_id = "alice" };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "fields") != null);
}

test "extension_fill_form rejects non-array fields" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionFillFormTool{ .hub = &hub, .user_id = "alice" };
    const parsed = try root.parseTestArgs("{\"fields\":\"oops\"}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "fields") != null);
}

test "extension_fill_form rejects oversized batch" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionFillFormTool{ .hub = &hub, .user_id = "alice" };

    // Build a JSON array with 51 entries to trip the 50-cap.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"fields\":[");
    var i: usize = 0;
    while (i < MAX_FILL_FORM_FIELDS + 1) : (i += 1) {
        if (i > 0) try buf.append(std.testing.allocator, ',');
        try buf.appendSlice(std.testing.allocator, "{\"selector\":\"#x\",\"text\":\"y\"}");
    }
    try buf.appendSlice(std.testing.allocator, "]}");

    const parsed = try root.parseTestArgs(buf.items);
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "50") != null);
}

test "extension_fill_form without bound user returns wiring-bug error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionFillFormTool{ .hub = &hub };
    const parsed = try root.parseTestArgs("{\"fields\":[{\"selector\":\"#a\",\"text\":\"b\"}]}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not bound") != null);
}

test "extension_fill_form with no extension connected returns user-facing error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var t_struct = ExtensionFillFormTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"fields\":[{\"selector\":\"#a\",\"text\":\"b\"}]}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "no extension connected") != null);
}

test "extension_fill_form happy path with mock hub returns parsed result" {
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
                "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{\"filled\":2}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &stream, .conn = c1 }});

    var t_struct = ExtensionFillFormTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"fields\":[{\"selector\":\"#a\",\"text\":\"x\"},{\"selector\":\"#b\",\"text\":\"y\"}]}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    thread.join();

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "filled") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}

test "extension_fill_form surfaces extension-side error frame" {
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

    var t_struct = ExtensionFillFormTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"fields\":[{\"selector\":\"#missing\",\"text\":\"x\"}]}");
    defer parsed.deinit();
    const result = try t_struct.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);

    thread.join();

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not_found") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}
