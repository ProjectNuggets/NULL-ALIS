const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const client_mod = @import("../browser_backend/client.zig");
const interpretExecResponse = @import("browser_exec.zig").interpretExecResponse;
const writeJsonString = @import("json_escape.zig").writeJsonString;

const EXEC_PATH = "/usr/local/bin/chromium-ns";

pub const BrowserNavigateTool = struct {
    client: *client_mod.OrchestratorClient,
    pub const tool_name = "browser_navigate";
    pub const tool_description = "Navigate a browser session to a URL (headless, in-cluster). Call browser_snapshot afterward for @eN refs.";
    pub const tool_params =
        \\{"type":"object","properties":{"session_id":{"type":"string"},"url":{"type":"string"}},"required":["session_id","url"]}
    ;
    const vtable = root.ToolVTable(@This());
    pub fn tool(self: *BrowserNavigateTool) Tool { return .{ .ptr = @ptrCast(self), .vtable = &vtable }; }
    pub fn execute(self: *BrowserNavigateTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const sid = root.getString(args, "session_id") orelse return ToolResult.fail("missing 'session_id'");
        const url = root.getString(args, "url") orelse return ToolResult.fail("missing 'url'");
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return ToolResult.fail("url must be http(s)");
        var aj: std.ArrayListUnmanaged(u8) = .empty;
        defer aj.deinit(allocator);
        try aj.appendSlice(allocator, "[\"--executable-path\",\"" ++ EXEC_PATH ++ "\",\"open\",");
        try writeJsonString(allocator, &aj, url);
        try aj.append(allocator, ']');
        const resp = self.client.exec(allocator, sid, aj.items) catch |e| {
            const msg = try std.fmt.allocPrint(allocator, "browser orchestrator unreachable: {s}", .{@errorName(e)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        return interpretExecResponse(allocator, resp);
    }
};

test "browser_navigate rejects non-http url" {
    var cl = client_mod.OrchestratorClient{ .base_url = "http://x" };
    var nt = BrowserNavigateTool{ .client = &cl };
    const parsed = try root.parseTestArgs("{\"session_id\":\"s1\",\"url\":\"file:///etc/passwd\"}");
    defer parsed.deinit();
    const r = try nt.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!r.success);
}
