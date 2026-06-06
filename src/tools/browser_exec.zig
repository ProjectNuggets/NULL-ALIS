const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const client_mod = @import("../browser_backend/client.zig");

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
    const stdout = if (obj.get("stdout")) |v| switch (v) { .string => |s| s, else => "" } else "";
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
