const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const client_mod = @import("../browser_backend/client.zig");
const interpretExecResponse = @import("browser_exec.zig").interpretExecResponse;

pub const BrowserSnapshotTool = struct {
    client: *client_mod.OrchestratorClient,
    pub const tool_name = "browser_snapshot";
    pub const tool_description = "Return the accessibility tree of the current page with @eN refs for the agent to act on via browser_exec.";
    pub const tool_params =
        \\{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}
    ;
    const vtable = root.ToolVTable(@This());
    pub fn tool(self: *BrowserSnapshotTool) Tool { return .{ .ptr = @ptrCast(self), .vtable = &vtable }; }
    pub fn execute(self: *BrowserSnapshotTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const sid = root.getString(args, "session_id") orelse return ToolResult.fail("missing 'session_id'");
        const resp = self.client.exec(allocator, sid, "[\"snapshot\"]") catch |e| {
            const msg = try std.fmt.allocPrint(allocator, "browser orchestrator unreachable: {s}", .{@errorName(e)});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        return interpretExecResponse(allocator, resp);
    }
};
