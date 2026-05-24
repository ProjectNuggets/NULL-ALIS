//! context_snapshot tool — lets the agent read its own state (execution
//! mode, pending tool approvals, verbose/reasoning modes, current session
//! key) as structured JSON. Purely read-only self-inspection.
//!
//! Mirrors Claude Code's self-state introspection pattern. Enables flows
//! like: "check if a tool approval is pending before proposing another
//! tool call" or "verify I'm in execute mode before editing files."

const std = @import("std");
const root = @import("root.zig");
const metadata = @import("metadata.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

pub const ContextSnapshotTool = struct {
    pub const tool_name = "context_snapshot";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Read agent self-state JSON: execution mode, pending approvals, verbose flags, active session key.",
        .use_when = &.{
            "Self-inspecting before suggesting edits to confirm execution mode (plan vs execute)",
            "Checking whether a pending tool approval is blocking progress this turn",
            "Verifying the active session key before referencing it in tool calls",
        },
        .do_not_use_for = &.{
            "runtime_info — for system-wide runtime state rather than this agent's own context",
            "set_execution_mode — for changing the mode rather than just reading it",
            "memory_recall — for stored user facts rather than agent self-state",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("context_snapshot", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description =
        "Read your own agent-state snapshot as JSON: current execution mode, pending tool approvals, verbose/reasoning settings, active session key. " ++
        "Use when you want to self-inspect before deciding on an approach (e.g. check if you're in plan mode before suggesting edits).";
    pub const tool_params =
        \\{"type":"object","properties":{}}
    ;

    pub const tool_metadata: metadata.ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ContextSnapshotTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ContextSnapshotTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        _ = self;
        _ = args;
        if (root.getAgentController()) |ctrl| {
            const json = try ctrl.snapshotJson(allocator);
            return ToolResult{ .success = true, .output = json };
        }
        return ToolResult.fail("Agent controller unavailable; cannot snapshot context from this scope.");
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const TestCtrl = struct {
    fn set(_: *anyopaque, _: []const u8) bool {
        return true;
    }
    fn get(_: *anyopaque) []const u8 {
        return "execute";
    }
    fn snapshot(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return try allocator.dupe(u8, "{\"execution_mode\":\"execute\",\"pending_tool_approval\":null}");
    }
};

test "context_snapshot returns controller-provided JSON" {
    var stub: u8 = 0;
    const ctrl = root.AgentController{
        .ptr = @ptrCast(&stub),
        .vtable = &.{
            .set_execution_mode = TestCtrl.set,
            .get_execution_mode = TestCtrl.get,
            .snapshot_json = TestCtrl.snapshot,
        },
    };
    root.setAgentController(ctrl);
    defer root.clearAgentController();

    var t = ContextSnapshotTool{};
    var args_parsed = try root.parseTestArgs("{}");
    defer args_parsed.deinit();
    const res = try t.execute(std.testing.allocator, args_parsed.value.object);
    defer std.testing.allocator.free(res.output);
    try std.testing.expect(res.success);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "execution_mode") != null);
}

test "context_snapshot fails when no controller is bound" {
    root.clearAgentController();
    var t = ContextSnapshotTool{};
    var args_parsed = try root.parseTestArgs("{}");
    defer args_parsed.deinit();
    const res = try t.execute(std.testing.allocator, args_parsed.value.object);
    try std.testing.expect(!res.success);
}
