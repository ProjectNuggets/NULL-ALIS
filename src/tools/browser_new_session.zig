const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const client_mod = @import("../browser_backend/client.zig");
const writeJsonString = @import("json_escape.zig").writeJsonString;

pub const BrowserNewSessionTool = struct {
    client: *client_mod.OrchestratorClient,
    user_id: ?[]const u8 = null,
    pub const tool_name = "browser_new_session";
    pub const tool_description = "Open a new headless browser session; returns a session_id to pass to the other browser_* tools.";
    pub const tool_params =
        \\{"type":"object","properties":{"auth_profile":{"type":"string","description":"Optional saved-login profile to inject."}}}
    ;
    const vtable = root.ToolVTable(@This());
    pub fn tool(self: *BrowserNewSessionTool) Tool { return .{ .ptr = @ptrCast(self), .vtable = &vtable }; }
    pub fn execute(self: *BrowserNewSessionTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const uid = self.user_id orelse return ToolResult.fail("browser_new_session not bound to a user (gateway-side wiring bug)");
        const profile = root.getString(args, "auth_profile") orelse "";
        const sid = self.client.newSession(allocator, uid, profile) catch |e| {
            const msg = switch (e) {
                error.OrchestratorRateLimited => try allocator.dupe(u8, "browser session limit reached — close an existing session (browser_close_session) and retry."),
                else => try std.fmt.allocPrint(allocator, "browser orchestrator could not create a session: {s}", .{@errorName(e)}),
            };
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer allocator.free(sid);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "{\"session_id\":");
        try writeJsonString(allocator, &out, sid);
        try out.append(allocator, '}');
        return ToolResult{ .success = true, .output = try out.toOwnedSlice(allocator) };
    }
};

test "browser_new_session without bound user errors" {
    var cl = client_mod.OrchestratorClient{ .base_url = "http://x" };
    var nt = BrowserNewSessionTool{ .client = &cl, .user_id = null };
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const r = try nt.execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!r.success);
}
test "browser_new_session returns session_id with mock transport" {
    var tt = client_mod.TestTransportPub{ .body = "{\"session_id\":\"sess-xyz\"}" };
    var cl = client_mod.OrchestratorClient{ .base_url = "http://x", .transport = tt.transport() };
    var nt = BrowserNewSessionTool{ .client = &cl, .user_id = "alice" };
    const parsed = try root.parseTestArgs("{\"auth_profile\":\"demo\"}");
    defer parsed.deinit();
    const r = try nt.execute(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.success);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "sess-xyz") != null);
}
