//! set_execution_mode tool — lets the agent switch its own execution mode
//! (plan / execute / review / background) mid-turn without forcing the user
//! to type `/mode`. Mirrors Claude Code's EnterPlanModeTool / ExitPlanModeTool
//! pattern but unified since nullalis already has a 4-mode enum.

const std = @import("std");
const root = @import("root.zig");
const metadata = @import("metadata.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

pub const SetExecutionModeTool = struct {
    pub const tool_name = "set_execution_mode";
    pub const tool_description =
        "Switch your own execution mode. " ++
        "`plan` = read-only exploration before committing to an approach (mutating tools blocked). " ++
        "`execute` = default; all tools available. " ++
        "`review` = read-only verification after changes. " ++
        "`background` = only background-safe tools (for automated/heartbeat turns). " ++
        "Use proactively: switch to plan before a non-trivial implementation, back to execute when the approach is clear. " ++
        "Always include a short `reason` so the user sees why you switched.";
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

        if (root.getAgentController()) |ctrl| {
            // Dupe `before` because `getExecutionMode` may return a slice into
            // controller-owned storage that becomes stale once `setExecutionMode`
            // mutates the mode. The real Agent controller returns static strings
            // so this is defensive rather than load-bearing — but we don't want
            // to depend on implementation details of the vtable.
            const before_slice = ctrl.getExecutionMode();
            const before = try allocator.dupe(u8, before_slice);
            defer allocator.free(before);

            const ok = ctrl.setExecutionMode(mode);
            if (!ok) {
                return ToolResult.fail("Unknown mode. Use one of: plan, execute, review, background.");
            }
            const after = ctrl.getExecutionMode();
            const msg = try std.fmt.allocPrint(
                allocator,
                "Switched execution mode: {s} → {s}. Reason: {s}",
                .{ before, after, reason },
            );
            return ToolResult{ .success = true, .output = msg };
        }
        return ToolResult.fail("Agent controller unavailable; cannot switch mode from this context.");
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

test "set_execution_mode flips mode via controller" {
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
    try std.testing.expectEqualStrings("plan", tc.mode[0..tc.mode_len]);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "execute → plan") != null);
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

test "set_execution_mode fails when no controller is bound" {
    root.clearAgentController();
    var t = SetExecutionModeTool{};
    var args_parsed = try root.parseTestArgs("{\"mode\":\"plan\",\"reason\":\"testing\"}");
    defer args_parsed.deinit();
    const res = try t.execute(std.testing.allocator, args_parsed.value.object);
    try std.testing.expect(!res.success);
}
