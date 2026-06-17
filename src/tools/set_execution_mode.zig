//! set_execution_mode tool — legacy self-control surface.
//!
//! V1 user-owned modes make normal mode changes explicit user actions via
//! `/mode` or the session mode API. The tool is kept so older prompts/tool
//! lists fail closed with a useful suggestion instead of silently mutating the
//! live session mode.

const std = @import("std");
const root = @import("root.zig");
const metadata = @import("metadata.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

pub const SetExecutionModeTool = struct {
    pub const tool_name = "set_execution_mode";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Suggest an execution-mode change without mutating the user's current mode.",
        .use_when = &.{
            "You believe plan, review, or execute mode would be better for the next step",
            "You need to tell the user which mode to choose explicitly",
        },
        .do_not_use_for = &.{
            "runtime_info — for inspecting current runtime/mode rather than changing it",
            "context_snapshot — for the agent's conversational context rather than execution mode",
            "memory_store — for persisting facts rather than runtime mode changes",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("set_execution_mode", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "Suggest an execution-mode change without changing it. " ++
        "`plan` = read-only exploration before committing to an approach (mutating tools blocked). " ++
        "`execute` = default; all tools available. " ++
        "`review` = read-only verification after changes. " ++
        "`background` = only background-safe tools (for automated/heartbeat turns). " ++
        "Mode changes are user-owned in V1: ask the user to switch modes through the UI or `/mode`; do not silently flip modes. " ++
        "Always include a short `reason` so the user sees why you are suggesting the change.";
    pub const tool_params =
        \\{"type":"object","properties":{"mode":{"type":"string","enum":["plan","execute","review","background"],"description":"Target execution mode"},"reason":{"type":"string","description":"One-line rationale shown back to the user"}},"required":["mode","reason"]}
    ;

    pub const tool_metadata: metadata.ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = false },
        .risk_level = .low,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *SetExecutionModeTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *SetExecutionModeTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        _ = self;
        const mode = root.getString(args, "mode") orelse
            return ToolResult.fail("Missing 'mode'. Use one of: plan, execute, review, background.");
        const reason = root.getString(args, "reason") orelse
            return ToolResult.fail("Missing 'reason'. Give a one-line rationale so the user sees why you switched.");
        if (reason.len == 0) return ToolResult.fail("'reason' must not be empty.");

        if (!std.mem.eql(u8, mode, "plan") and
            !std.mem.eql(u8, mode, "execute") and
            !std.mem.eql(u8, mode, "review") and
            !std.mem.eql(u8, mode, "background"))
        {
            return ToolResult.fail("Unknown mode. Use one of: plan, execute, review, background.");
        }

        if (root.getAgentController()) |ctrl| {
            const current = ctrl.getExecutionMode();
            const msg = try std.fmt.allocPrint(
                allocator,
                "Mode unchanged ({s}). Mode changes are user-owned; suggest that the user switch to {s} mode via the UI or `/mode {s}`. Reason: {s}",
                .{ current, mode, mode, reason },
            );
            return ToolResult{ .success = true, .output = msg };
        }
        const msg = try std.fmt.allocPrint(
            allocator,
            "Mode unchanged. Mode changes are user-owned; suggest that the user switch to {s} mode via the UI or `/mode {s}`. Reason: {s}",
            .{ mode, mode, reason },
        );
        return ToolResult{ .success = true, .output = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const TestController = struct {
    mode: [16]u8 = undefined,
    mode_len: usize = 0,

    fn set(ptr: *anyopaque, new_mode: []const u8) bool {
        const self: *TestController = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, new_mode, "plan") and
            !std.mem.eql(u8, new_mode, "execute") and
            !std.mem.eql(u8, new_mode, "review") and
            !std.mem.eql(u8, new_mode, "background")) return false;
        @memcpy(self.mode[0..new_mode.len], new_mode);
        self.mode_len = new_mode.len;
        return true;
    }

    fn get(ptr: *anyopaque) []const u8 {
        const self: *TestController = @ptrCast(@alignCast(ptr));
        return self.mode[0..self.mode_len];
    }

    fn snapshot(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return try allocator.dupe(u8, "{}");
    }
};

test "set_execution_mode suggests mode via controller without mutating" {
    var tc = TestController{};
    @memcpy(tc.mode[0..7], "execute");
    tc.mode_len = 7;
    const ctrl = root.AgentController{
        .ptr = @ptrCast(&tc),
        .vtable = &.{
            .set_execution_mode = TestController.set,
            .get_execution_mode = TestController.get,
            .snapshot_json = TestController.snapshot,
        },
    };
    root.setAgentController(ctrl);
    defer root.clearAgentController();

    var t = SetExecutionModeTool{};
    var args_parsed = try root.parseTestArgs("{\"mode\":\"plan\",\"reason\":\"exploring before editing\"}");
    defer args_parsed.deinit();
    const res = try t.execute(std.testing.allocator, args_parsed.value.object);
    defer std.testing.allocator.free(res.output);
    try std.testing.expect(res.success);
    try std.testing.expectEqualStrings("execute", tc.mode[0..tc.mode_len]);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "Mode unchanged (execute)") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "/mode plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "exploring before editing") != null);
}

test "set_execution_mode rejects unknown mode" {
    var tc = TestController{};
    @memcpy(tc.mode[0..7], "execute");
    tc.mode_len = 7;
    const ctrl = root.AgentController{
        .ptr = @ptrCast(&tc),
        .vtable = &.{
            .set_execution_mode = TestController.set,
            .get_execution_mode = TestController.get,
            .snapshot_json = TestController.snapshot,
        },
    };
    root.setAgentController(ctrl);
    defer root.clearAgentController();

    var t = SetExecutionModeTool{};
    var args_parsed = try root.parseTestArgs("{\"mode\":\"wombat\",\"reason\":\"why not\"}");
    defer args_parsed.deinit();
    const res = try t.execute(std.testing.allocator, args_parsed.value.object);
    try std.testing.expect(!res.success);
    try std.testing.expectEqualStrings("execute", tc.mode[0..tc.mode_len]);
}

test "set_execution_mode requires reason" {
    var t = SetExecutionModeTool{};
    var args_parsed = try root.parseTestArgs("{\"mode\":\"plan\"}");
    defer args_parsed.deinit();
    const res = try t.execute(std.testing.allocator, args_parsed.value.object);
    try std.testing.expect(!res.success);
}

test "set_execution_mode returns suggestion when no controller is bound" {
    root.clearAgentController();
    var t = SetExecutionModeTool{};
    var args_parsed = try root.parseTestArgs("{\"mode\":\"plan\",\"reason\":\"testing\"}");
    defer args_parsed.deinit();
    const res = try t.execute(std.testing.allocator, args_parsed.value.object);
    defer std.testing.allocator.free(res.output);
    try std.testing.expect(res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "/mode plan") != null);
}
