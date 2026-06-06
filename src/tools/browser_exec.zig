const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const client_mod = @import("../browser_backend/client.zig");
const BrowserNewSessionTool = @import("browser_new_session.zig").BrowserNewSessionTool;
const BrowserNavigateTool = @import("browser_navigate.zig").BrowserNavigateTool;
const BrowserSnapshotTool = @import("browser_snapshot.zig").BrowserSnapshotTool;
const BrowserCloseSessionTool = @import("browser_close_session.zig").BrowserCloseSessionTool;

/// Turn an orchestrator /exec Response into a ToolResult.
pub fn interpretExecResponse(allocator: std.mem.Allocator, resp: client_mod.Response) !ToolResult {
    defer allocator.free(resp.body);
    if (resp.status_code == 403) return ToolResult.fail("browser command not allowed by the orchestrator policy");
    if (resp.status_code != 200) {
        const msg = try std.fmt.allocPrint(allocator, "browser orchestrator error (status {d}): {s}", .{ resp.status_code, resp.body });
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch return ToolResult.fail("orchestrator returned malformed JSON");
    defer parsed.deinit();
    const obj = switch (parsed.value) { .object => |o| o, else => return ToolResult.fail("orchestrator returned non-object") };
    // 200: agent-browser ran. exit_code != 0 means the command ran but failed
    // (e.g. selector not found, wait timeout) — surface it as a tool failure so
    // the agent doesn't act on a phantom success.
    const exit_code: i64 = if (obj.get("exit_code")) |v| switch (v) { .integer => |i| i, else => 0 } else 0;
    const stdout = if (obj.get("stdout")) |v| switch (v) { .string => |s| s, else => "" } else "";
    const stderr = if (obj.get("stderr")) |v| switch (v) { .string => |s| s, else => "" } else "";
    if (exit_code != 0) {
        const detail = if (stderr.len > 0) stderr else if (stdout.len > 0) stdout else "no output";
        const msg = try std.fmt.allocPrint(allocator, "browser command failed (exit {d}): {s}", .{ exit_code, detail });
        return ToolResult{ .success = false, .output = "", .error_msg = msg };
    }
    return ToolResult{ .success = true, .output = try allocator.dupe(u8, stdout) };
}

pub const BrowserExecTool = struct {
    client: *client_mod.OrchestratorClient,
    pub const tool_name = "browser_exec";
    pub const tool_description = "Run a low-level agent-browser command in a browser session (passthrough). The orchestrator enforces an allowlist; eval/connect/raw-CDP are denied. Use for click/type/get/etc., e.g. args [\"click\",\"@e1\"].";
    pub const tool_params =
        \\{"type":"object","properties":{"session_id":{"type":"string"},"args":{"type":"array","items":{"type":"string"},"description":"agent-browser argv."}},"required":["session_id","args"]}
    ;
    const vtable = root.ToolVTable(@This());
    pub fn tool(self: *BrowserExecTool) Tool { return .{ .ptr = @ptrCast(self), .vtable = &vtable }; }
    pub fn execute(self: *BrowserExecTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const sid = root.getString(args, "session_id") orelse return ToolResult.fail("missing 'session_id'");
        const args_val = args.get("args") orelse return ToolResult.fail("missing 'args'");
        const args_json = try std.json.Stringify.valueAlloc(allocator, args_val, .{});
        defer allocator.free(args_json);
        const resp = self.client.exec(allocator, sid, args_json) catch |e| {
            const msg = try std.fmt.allocPrint(allocator, "browser orchestrator unreachable: {s}", .{@errorName(e)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        return interpretExecResponse(allocator, resp);
    }
};

test "browser_exec returns stdout on 200" {
    var tt = client_mod.TestTransportPub{ .body = "{\"stdout\":\"- heading [ref=e1]\",\"exit_code\":0}" };
    var cl = client_mod.OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    var et = BrowserExecTool{ .client = &cl };
    const parsed = try root.parseTestArgs("{\"session_id\":\"s1\",\"args\":[\"snapshot\"]}");
    defer parsed.deinit();
    const r = try et.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "ref=e1") != null);
}
test "browser_exec non-zero exit on 200 is a failure" {
    var tt = client_mod.TestTransportPub{ .body = "{\"stdout\":\"\",\"stderr\":\"no element @e99\",\"exit_code\":1}" };
    var cl = client_mod.OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    var et = BrowserExecTool{ .client = &cl };
    const parsed = try root.parseTestArgs("{\"session_id\":\"s1\",\"args\":[\"click\",\"@e99\"]}");
    defer parsed.deinit();
    const r = try et.execute(std.testing.allocator, parsed.value.object);
    defer if (r.error_msg) |m| std.testing.allocator.free(m);
    try std.testing.expect(!r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.error_msg.?, "@e99") != null);
}
test "live: browser_* tools drive a session end to end" {
    if (std.posix.getenv("NULLALIS_BROWSER_LIVE_TEST") == null) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var client = client_mod.OrchestratorClient{ .base_url = "http://localhost:8080", .timeout_ms = 120_000 };

    // browser_new_session (bound to a user, like the gateway does)
    var ns = BrowserNewSessionTool{ .client = &client, .user_id = "e2e-tools" };
    const ns_args = try root.parseTestArgs("{}");
    defer ns_args.deinit();
    const ns_res = try ns.execute(allocator, ns_args.value.object);
    defer if (ns_res.output.len > 0) allocator.free(ns_res.output);
    defer if (ns_res.error_msg) |m| allocator.free(m);
    try std.testing.expect(ns_res.success);
    // parse session_id out of {"session_id":"..."}
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, ns_res.output, .{});
    defer parsed.deinit();
    const sid = parsed.value.object.get("session_id").?.string;

    // browser_navigate
    var nav = BrowserNavigateTool{ .client = &client };
    const nav_json = try std.fmt.allocPrint(allocator, "{{\"session_id\":\"{s}\",\"url\":\"https://example.com\"}}", .{sid});
    defer allocator.free(nav_json);
    const nav_args = try root.parseTestArgs(nav_json);
    defer nav_args.deinit();
    const nav_res = try nav.execute(allocator, nav_args.value.object);
    defer if (nav_res.output.len > 0) allocator.free(nav_res.output);
    defer if (nav_res.error_msg) |m| allocator.free(m);
    try std.testing.expect(nav_res.success);

    // browser_snapshot -> @eN
    var snap = BrowserSnapshotTool{ .client = &client };
    const snap_json = try std.fmt.allocPrint(allocator, "{{\"session_id\":\"{s}\"}}", .{sid});
    defer allocator.free(snap_json);
    const snap_args = try root.parseTestArgs(snap_json);
    defer snap_args.deinit();
    const snap_res = try snap.execute(allocator, snap_args.value.object);
    defer if (snap_res.output.len > 0) allocator.free(snap_res.output);
    defer if (snap_res.error_msg) |m| allocator.free(m);
    try std.testing.expect(snap_res.success);
    try std.testing.expect(std.mem.indexOf(u8, snap_res.output, "ref=e") != null);

    // browser_close_session
    var close = BrowserCloseSessionTool{ .client = &client };
    const close_args = try root.parseTestArgs(snap_json);
    defer close_args.deinit();
    const close_res = try close.execute(allocator, close_args.value.object);
    defer if (close_res.output.len > 0) allocator.free(close_res.output);
    defer if (close_res.error_msg) |m| allocator.free(m);
    try std.testing.expect(close_res.success);
}

test "browser_exec maps 403 to a clear denial" {
    var tt = client_mod.TestTransportPub{ .body = "{}", .status = 403 };
    var cl = client_mod.OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    var et = BrowserExecTool{ .client = &cl };
    const parsed = try root.parseTestArgs("{\"session_id\":\"s1\",\"args\":[\"eval\",\"x\"]}");
    defer parsed.deinit();
    const r = try et.execute(std.testing.allocator, parsed.value.object);
    // NOTE (deviation from spec test): the 403 path returns
    // `ToolResult.fail(<string literal>)`, whose `error_msg` is a static
    // literal — NOT heap-allocated. The spec's `defer ...allocator.free(m)`
    // freed that literal, which bus-errors under the testing allocator.
    // The literal is unowned, so there is nothing to free here.
    try std.testing.expect(!r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.error_msg.?, "not allowed") != null);
}
