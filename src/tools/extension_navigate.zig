//! `extension_navigate` — drive the user's REAL browser to a URL by
//! dispatching a `navigate` Command frame through the per-user
//! `ExtensionWsHub` to the connected nullalis browser extension.
//!
//! This is the FIRST of the Wave 3B `extension_*` tool family. Adding
//! the rest (click, type, fill_form, screenshot, get_text, get_dom,
//! wait_for, scroll, list_tabs) is a mechanical copy — see
//! `docs/extension-ws-contract.md` "Add another tool" recipe.
//!
//! Per `.spike/nullalis-extension/docs/ARCHITECTURE.md`, `navigate`
//! runs in the extension's background service worker (chrome.tabs.*).
//! Args: `{url: string, new_tab?: bool}`. Result on success:
//! `{tab_id, url}`. Result on failure: `{code, message}`.
//!
//! Approval gating: this tool is `.mutating + .risk_level=.high`. In
//! `.supervised` autonomy the agent's `preflightToolPolicy` raises the
//! approval prompt before the dispatcher reaches `execute`. In `.full`
//! autonomy the tool runs without prompt but is still logged via the
//! observability layer (same as any other mutating tool).

const std = @import("std");
const root = @import("root.zig");
const hub_mod = @import("../extension_ws/hub.zig");
const url_sanitize = @import("../extension_ws/url_sanitize.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

// WARN 2.B (v1.14.23): scoped logger for cross-boundary handoff
// failures. The hub-layer already metrics + logs timeouts / OOM /
// disconnects centrally; this logger adds signal for the local
// dispatch-error catch-all and malformed result frames.
const log = std.log.scoped(.extension_navigate);

/// Per-instance state: the hub handle is bound at `allTools` time
/// (conditional registration — see tools/root.zig), and the user_id is
/// bound per-call via `bindExtensionTools` from the chat-stream
/// dispatcher, mirroring how `bindStateMgrTenant` wires per-tenant
/// state into memory_*. A null hub is impossible by construction (the
/// tool is only registered when the hub is non-null), but null user_id
/// can happen during boot — we surface that as a clear error.
pub const ExtensionNavigateTool = struct {
    hub: *hub_mod.ExtensionWsHub,
    user_id: ?[]const u8 = null,
    timeout_ms: u64 = hub_mod.DEFAULT_COMMAND_TIMEOUT_MS,
    /// Operator-controlled SSRF allowlist. Default empty (deny all
    /// non-public hosts). Borrowed from `GatewayConfig.extension_browser_allowlist`
    /// at tool registration time. The slice's underlying storage must
    /// outlive every tool invocation — guaranteed by the gateway's
    /// long-lived config block.
    url_allowlist: []const []const u8 = &.{},

    pub const tool_name = "extension_navigate";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Drive the user's connected browser extension to navigate to a URL.",
        .use_when = &.{
            "User asks the agent to 'open <site>' or 'go to <url>' inside their already-running browser session",
            "Agent needs the user's logged-in cookies/extensions to load a page that public fetches cannot reach",
            "Following up an extension_* action (click, fill_form) with a navigation to the next step in a workflow",
        },
        .do_not_use_for = &.{
            "browser_open — for opening a URL in the user's default browser without the live extension session",
            "web_fetch — for reading public HTML from a URL without driving the browser",
            "web_search — for finding a URL from a query rather than navigating to a known one",
        },
        .cost_note = "Drives the user's real browser session — actions are visible to them and may affect logged-in state.",
        .completion_hint = "Returns the new tab id and the loaded URL when the extension confirms navigation.",
    };

    comptime {
        @import("lint.zig").lintToolDescription(
            "extension_navigate",
            tool_description_struct,
            &@import("lint.zig").ALL_TOOLS,
        );
    }

    pub const tool_description =
        "Drive the user's connected browser extension to navigate to a URL. " ++
        "Requires the nullalis browser extension to be connected to this gateway " ++
        "for the current user. Returns the loaded tab id + url on success, or a " ++
        "clear error if no extension is connected.";

    pub const tool_params =
        \\{"type":"object","properties":{"url":{"type":"string","description":"Absolute http/https URL to navigate to."},"new_tab":{"type":"boolean","description":"If true, open in a new tab; otherwise replace the current tab."}},"required":["url"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ExtensionNavigateTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn execute(self: *ExtensionNavigateTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const url = root.getString(args, "url") orelse return ToolResult.fail("missing 'url' parameter");
        if (url.len == 0) return ToolResult.fail("'url' must be a non-empty string");

        // SSRF defense FIRST — before any hub dispatch. Mirrors the
        // playwright-mcp sanitizer for the server-side browser; this
        // path closes the same bypass classes for the USER-side
        // browser (cloud metadata, RFC1918, loopback, IPv6 link-local,
        // IPv4-mapped IPv6, decimal/hex-encoded IPs, localhost.
        // trailing-dot aliases, etc.). Operator escape: a hostname in
        // `extension_browser_allowlist` skips the deny check.
        switch (url_sanitize.sanitize(url, self.url_allowlist)) {
            .ok => {},
            .reject => |rj| {
                // WARN 2.C + HIGH 2.A: operability signal — operators
                // need to see SSRF blocks on a chart and in logs to
                // tune `extension_browser_allowlist` for LAN-trusted
                // deployments. user_id is included so operators can
                // attribute blocks to a tenant when triaging "why is
                // my agent refusing to open localhost:3000?"
                const uid_label: []const u8 = self.user_id orelse "<unbound>";
                log.info("extension_ws.ssrf_block user_id='{s}' reason={s} detail={s}", .{ uid_label, rj.reason.toString(), rj.detail });
                @import("../observability.zig").recordMetricGlobal(.{ .extension_ws_ssrf_block_total = 1 });
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "url blocked by SSRF defense [{s}]: {s}",
                    .{ rj.reason.toString(), rj.detail },
                );
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
        }

        const user_id = self.user_id orelse return ToolResult.fail("extension_navigate not bound to a user (gateway-side wiring bug)");

        // Build the args JSON the extension expects. The contract puts
        // the new_tab flag inside the args object; we omit it when
        // false to keep the payload minimal and let the extension's
        // default (existing tab) apply.
        var args_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer args_buf.deinit(allocator);
        try args_buf.appendSlice(allocator, "{\"url\":");
        try writeJsonString(allocator, &args_buf, url);
        if (root.getBool(args, "new_tab")) |new_tab| {
            if (new_tab) try args_buf.appendSlice(allocator, ",\"new_tab\":true");
        }
        try args_buf.append(allocator, '}');

        // Hand off to the hub. The hub returns the raw CommandResult
        // JSON, which we then unwrap into a ToolResult.
        const result_json = self.hub.sendCommand(
            allocator,
            user_id,
            "navigate",
            args_buf.items,
            self.timeout_ms,
        ) catch |err| switch (err) {
            error.NoExtensionConnected => return ToolResult.fail("no extension connected for this user. Ask the user to open the nullalis extension popup and connect."),
            error.Timeout => return ToolResult.fail("extension did not respond within the timeout window. The user's browser may be unresponsive or the extension may have disconnected."),
            error.ConnectionClosed => return ToolResult.fail("extension connection closed before the navigation completed. Ask the user to reconnect the extension."),
            // META HIGH #3: distinguish OOM from connection-closed so
            // operators see the real cause in the surfaced error.
            error.ResultDeliveryOom => return ToolResult.fail("gateway ran out of memory delivering the extension result — please retry; if persistent, check the gateway's available RAM."),
            else => |e| {
                log.warn("extension_navigate dispatch failed user_id='{s}' err={s}", .{ user_id, @errorName(e) });
                const msg = try std.fmt.allocPrint(allocator, "extension_navigate dispatch failed: {s}", .{@errorName(e)});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            },
        };

        return interpretResultJson(allocator, result_json);
    }
};

/// Parse the CommandResult JSON and translate into a ToolResult. The
/// JSON is freed regardless of outcome. On `ok:true`, the `result`
/// object is rendered back as a JSON string for the agent to ingest;
/// on `ok:false` the `error.message` field becomes the ToolResult's
/// error_msg.
fn interpretResultJson(allocator: std.mem.Allocator, json: []u8) !ToolResult {
    defer allocator.free(json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch {
        log.warn("extension_navigate malformed result frame len={d}", .{json.len});
        return ToolResult.fail("extension returned malformed CommandResult JSON");
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            log.warn("extension_navigate non-object result frame", .{});
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

    // Success: re-serialize the `result` field so the agent sees a
    // single JSON object. If `result` is missing, return a default.
    if (obj.get("result")) |result_val| {
        const out = try std.json.Stringify.valueAlloc(allocator, result_val, .{});
        return ToolResult{ .success = true, .output = out };
    }
    const out = try allocator.dupe(u8, "{}");
    return ToolResult{ .success = true, .output = out };
}

/// Minimal JSON string escaper for URLs. Handles the small set of
/// characters that appear in real URLs (quote, backslash, control
/// chars). Full RFC 8259 escaping isn't needed here — the URL has
/// already been validated to start with http:// or https://, which
/// rules out the control chars JSON cares about; we only escape
/// quotes + backslashes defensively.
/// HI-05 (v1.14.22) — shared escaper. See src/tools/json_escape.zig
/// for the RFC 8259 §7-correct implementation that escapes all C0
/// control characters (the prior per-file inline version escaped only
/// the named escapes and let `\b` `\f` `\x01-\x07` etc. through, producing
/// invalid JSON for user-controlled selectors / text).
const writeJsonString = @import("json_escape.zig").writeJsonString;

// ── Tests ────────────────────────────────────────────────────────────

test "extension_navigate tool name + spec" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var nav = ExtensionNavigateTool{ .hub = &hub };
    const t = nav.tool();
    try std.testing.expectEqualStrings("extension_navigate", t.name());
    const s = t.spec();
    try std.testing.expect(std.mem.indexOf(u8, s.parameters_json, "url") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.parameters_json, "new_tab") != null);
}

test "extension_navigate missing url returns clear error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var nav = ExtensionNavigateTool{ .hub = &hub, .user_id = "alice" };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "url") != null);
}

test "extension_navigate rejects non-http scheme" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var nav = ExtensionNavigateTool{ .hub = &hub, .user_id = "alice" };
    const parsed = try root.parseTestArgs("{\"url\":\"file:///etc/passwd\"}");
    defer parsed.deinit();
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "scheme_blocked") != null);
}

// ── META CRITICAL #1 regression tests: SSRF defense at tool boundary ──
//
// Each of these used to be ACCEPTED by the prior `startsWith("http://")`
// check — the tool happily handed them to `hub.sendCommand` which
// would dispatch the navigation to the user's REAL browser. Now they
// hit the sanitizer first and surface a scheme-typed rejection.

test "META CRIT #1: extension_navigate blocks cloud metadata 169.254.169.254" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var nav = ExtensionNavigateTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"url\":\"http://169.254.169.254/latest/meta-data/\"}");
    defer parsed.deinit();
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "metadata_endpoint_blocked") != null);
}

test "META CRIT #1: extension_navigate blocks IPv4-mapped IPv6 metadata" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var nav = ExtensionNavigateTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"url\":\"http://[::ffff:169.254.169.254]/\"}");
    defer parsed.deinit();
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "metadata_endpoint_blocked") != null);
}

test "META CRIT #1: extension_navigate blocks 192.168.1.1 RFC1918" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var nav = ExtensionNavigateTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"url\":\"http://192.168.1.1/admin\"}");
    defer parsed.deinit();
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "private_ip_blocked") != null);
}

test "META CRIT #1: extension_navigate blocks localhost. trailing dot" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var nav = ExtensionNavigateTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"url\":\"http://localhost./admin\"}");
    defer parsed.deinit();
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "loopback_blocked") != null);
}

test "META CRIT #1: extension_navigate blocks decimal-encoded private IP" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var nav = ExtensionNavigateTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"url\":\"http://3232235521/\"}");
    defer parsed.deinit();
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "private_ip_blocked") != null);
}

test "META CRIT #1: extension_navigate blocks hex-encoded loopback" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var nav = ExtensionNavigateTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"url\":\"http://0x7F000001/\"}");
    defer parsed.deinit();
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "loopback_blocked") != null);
}

test "META CRIT #1: extension_navigate allowlist permits LAN service" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var nav = ExtensionNavigateTool{
        .hub = &hub,
        .user_id = "alice",
        .timeout_ms = 50,
        .url_allowlist = &.{"192.168.1.1"},
    };
    const parsed = try root.parseTestArgs("{\"url\":\"http://192.168.1.1/dashboard\"}");
    defer parsed.deinit();
    // No extension is connected so we expect "no extension connected" —
    // the URL itself made it past the sanitizer. That error is a
    // static literal from ToolResult.fail, so we MUST NOT free it.
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "no extension connected") != null);
}

test "extension_navigate without bound user returns wiring-bug error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var nav = ExtensionNavigateTool{ .hub = &hub }; // no user_id
    const parsed = try root.parseTestArgs("{\"url\":\"https://example.com\"}");
    defer parsed.deinit();
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not bound") != null);
}

test "extension_navigate with no extension connected returns user-facing error" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();
    var nav = ExtensionNavigateTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 50 };
    const parsed = try root.parseTestArgs("{\"url\":\"https://example.com\"}");
    defer parsed.deinit();
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "no extension connected") != null);
}

test "extension_navigate happy path with mock hub returns parsed result" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

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
    var stream = TestStream{ .allocator = std.testing.allocator };
    defer stream.deinit();
    const c1 = try hub.registerConn("alice", &stream, TestStream.writeText, &stream, TestStream.closeFn);

    // Worker thread that delivers a synthetic CommandResult once the
    // command frame appears on the test stream.
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
                "{{\"command_id\":\"{s}\",\"ok\":true,\"result\":{{\"tab_id\":42,\"url\":\"https://example.com/\"}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx{ .stream = &stream, .conn = c1 }});

    var nav = ExtensionNavigateTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"url\":\"https://example.com\"}");
    defer parsed.deinit();
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(result.output);

    thread.join();

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "tab_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "example.com") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}

test "extension_navigate surfaces extension-side error frame" {
    var hub = hub_mod.ExtensionWsHub.init(std.testing.allocator);
    defer hub.deinit();

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
    var stream = TestStream{ .allocator = std.testing.allocator };
    defer stream.deinit();
    const c1 = try hub.registerConn("alice", &stream, TestStream.writeText, &stream, TestStream.closeFn);

    const HelperCtx2 = struct {
        stream: *TestStream,
        conn: *hub_mod.ExtensionWsConn,
    };
    const Helper = struct {
        fn run(ctx: HelperCtx2) void {
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
                "{{\"command_id\":\"{s}\",\"ok\":false,\"error\":{{\"code\":\"navigation_blocked\",\"message\":\"chrome:// URL not allowed\"}}}}",
                .{id},
            ) catch return;
            defer std.testing.allocator.free(result_json);
            ctx.conn.deliverResult(result_json) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Helper.run, .{HelperCtx2{ .stream = &stream, .conn = c1 }});

    var nav = ExtensionNavigateTool{ .hub = &hub, .user_id = "alice", .timeout_ms = 2_000 };
    const parsed = try root.parseTestArgs("{\"url\":\"https://example.com\",\"new_tab\":true}");
    defer parsed.deinit();
    const result = try nav.execute(std.testing.allocator, parsed.value.object);
    defer if (result.error_msg) |m| std.testing.allocator.free(m);

    thread.join();

    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "navigation_blocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "chrome://") != null);

    try std.testing.expect(hub.unregister("alice"));
    hub.destroyConn(c1);
}
