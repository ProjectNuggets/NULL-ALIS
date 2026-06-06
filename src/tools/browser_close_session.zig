const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const client_mod = @import("../browser_backend/client.zig");

pub const BrowserCloseSessionTool = struct {
    client: *client_mod.OrchestratorClient,
    pub const tool_name = "browser_close_session";
    pub const tool_description = "Close a browser session and free its resources.";
    pub const tool_params =
        \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
    ;
    const vtable = root.ToolVTable(@This());
    pub fn tool(self: *BrowserCloseSessionTool) Tool { return .{ .ptr = @ptrCast(self), .vtable = &vtable }; }
    pub fn execute(self: *BrowserCloseSessionTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const sid = root.getString(args, "session_id") orelse return ToolResult.fail("missing 'session_id'");
        self.client.closeSession(allocator, sid) catch |e| {
            const msg = try std.fmt.allocPrint(allocator, "browser orchestrator could not close session: {s}", .{@errorName(e)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        return ToolResult{ .success = true, .output = try allocator.dupe(u8, "{\"status\":\"closed\"}") };
    }
};
