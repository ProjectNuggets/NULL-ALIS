//! Hooks — config-driven shell commands triggered on agent lifecycle events.
//!
//! Inspired by Claude Code's hook system. Hooks are shell commands configured
//! per event type in config.json under "hooks". They execute best-effort
//! and do not block the agent loop on failure.
//!
//! Supported events:
//!   - turn_start:  before the agent processes a user message
//!   - turn_end:    after the agent produces a final response
//!   - tool_start:  before a tool executes (receives tool name via $HOOK_TOOL)
//!   - tool_end:    after a tool completes (receives tool name + success via env)
//!   - session_start: when a new session is created
//!   - compact:     after history compaction occurs

const std = @import("std");
const platform = @import("platform.zig");
const log = std.log.scoped(.hooks);

/// A configured hook — one shell command bound to one event.
pub const Hook = struct {
    event: Event,
    command: []const u8,
    /// Optional: only trigger for this specific tool name (tool_start/tool_end only).
    tool_filter: ?[]const u8 = null,
    /// Timeout in milliseconds (default 10s — hooks should be fast).
    timeout_ms: u32 = 10_000,
};

/// Lifecycle events that can trigger hooks.
pub const Event = enum {
    turn_start,
    turn_end,
    tool_start,
    tool_end,
    session_start,
    compact,

    pub fn toString(self: Event) []const u8 {
        return switch (self) {
            .turn_start => "turn_start",
            .turn_end => "turn_end",
            .tool_start => "tool_start",
            .tool_end => "tool_end",
            .session_start => "session_start",
            .compact => "compact",
        };
    }

    pub fn fromString(s: []const u8) ?Event {
        if (std.mem.eql(u8, s, "turn_start")) return .turn_start;
        if (std.mem.eql(u8, s, "turn_end")) return .turn_end;
        if (std.mem.eql(u8, s, "tool_start")) return .tool_start;
        if (std.mem.eql(u8, s, "tool_end")) return .tool_end;
        if (std.mem.eql(u8, s, "session_start")) return .session_start;
        if (std.mem.eql(u8, s, "compact")) return .compact;
        return null;
    }
};

/// Run all hooks matching the given event. Best-effort — failures are logged.
/// Environment variables are set based on event context.
pub fn runHooks(
    allocator: std.mem.Allocator,
    hooks: []const Hook,
    event: Event,
    context: HookContext,
) void {
    for (hooks) |hook| {
        if (hook.event != event) continue;

        // tool_filter: skip if hook is tool-specific and doesn't match
        if (hook.tool_filter) |filter| {
            const tool_name = context.tool_name orelse continue;
            if (!std.mem.eql(u8, filter, tool_name)) continue;
        }

        runSingleHook(allocator, hook, context);
    }
}

/// Context passed to hooks via environment variables.
pub const HookContext = struct {
    tool_name: ?[]const u8 = null,
    tool_success: ?bool = null,
    session_key: ?[]const u8 = null,
    workspace_dir: ?[]const u8 = null,
};

fn runSingleHook(allocator: std.mem.Allocator, hook: Hook, context: HookContext) void {
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();

    // Inherit PATH for the hook to find commands
    if (platform.getEnvOrNull(allocator, "PATH")) |val| {
        defer allocator.free(val);
        env.put("PATH", val) catch {};
    }
    if (platform.getEnvOrNull(allocator, "HOME")) |val| {
        defer allocator.free(val);
        env.put("HOME", val) catch {};
    }

    // Set hook-specific environment
    env.put("HOOK_EVENT", hook.event.toString()) catch {};
    if (context.tool_name) |name| env.put("HOOK_TOOL", name) catch {};
    if (context.tool_success) |success| env.put("HOOK_TOOL_SUCCESS", if (success) "true" else "false") catch {};
    if (context.session_key) |key| env.put("HOOK_SESSION", key) catch {};
    if (context.workspace_dir) |dir| env.put("HOOK_WORKSPACE", dir) catch {};

    const cwd = context.workspace_dir orelse ".";

    var child = std.process.Child.init(
        &.{ platform.getShell(), platform.getShellFlag(), hook.command },
        allocator,
    );
    child.cwd = cwd;
    child.env_map = &env;
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch |err| {
        log.warn("hook '{s}' ({s}) failed to spawn: {}", .{ hook.event.toString(), hook.command, err });
        return;
    };

    _ = child.wait() catch |err| {
        log.warn("hook '{s}' ({s}) failed to wait: {}", .{ hook.event.toString(), hook.command, err });
        return;
    };
}

/// Parse hooks from a JSON array of hook objects.
/// Expected format: [{"event": "turn_start", "command": "echo hi"}, ...]
pub fn parseHooks(allocator: std.mem.Allocator, json_str: []const u8) ![]Hook {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return allocator.alloc(Hook, 0);
    defer parsed.deinit();

    const array = switch (parsed.value) {
        .array => |a| a,
        else => return allocator.alloc(Hook, 0),
    };

    var hooks: std.ArrayListUnmanaged(Hook) = .empty;
    errdefer hooks.deinit(allocator);

    for (array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const event_str = switch (obj.get("event") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const event = Event.fromString(event_str) orelse continue;

        const command = switch (obj.get("command") orelse continue) {
            .string => |s| s,
            else => continue,
        };

        const tool_filter = if (obj.get("tool_filter")) |tf| switch (tf) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        } else null;

        const timeout_ms: u32 = if (obj.get("timeout_ms")) |tm| switch (tm) {
            .integer => |i| @intCast(@max(0, @min(i, 60_000))),
            else => 10_000,
        } else 10_000;

        try hooks.append(allocator, .{
            .event = event,
            .command = try allocator.dupe(u8, command),
            .tool_filter = tool_filter,
            .timeout_ms = timeout_ms,
        });
    }

    return hooks.toOwnedSlice(allocator);
}

/// Free hooks allocated by parseHooks.
pub fn freeHooks(allocator: std.mem.Allocator, hooks: []Hook) void {
    for (hooks) |hook| {
        allocator.free(hook.command);
        if (hook.tool_filter) |f| allocator.free(f);
    }
    allocator.free(hooks);
}

// ── Tests ─────────────────────────────────────────────────────

test "Event fromString roundtrip" {
    const events = [_]Event{ .turn_start, .turn_end, .tool_start, .tool_end, .session_start, .compact };
    for (events) |event| {
        const str = event.toString();
        const parsed = Event.fromString(str);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(event, parsed.?);
    }
}

test "Event fromString unknown returns null" {
    try std.testing.expect(Event.fromString("invalid_event") == null);
    try std.testing.expect(Event.fromString("") == null);
}

test "parseHooks valid JSON" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"event": "turn_start", "command": "echo start"},
        \\ {"event": "tool_end", "command": "notify.sh", "tool_filter": "shell"}]
    ;
    const hooks = try parseHooks(allocator, json);
    defer freeHooks(allocator, hooks);

    try std.testing.expectEqual(@as(usize, 2), hooks.len);
    try std.testing.expectEqual(Event.turn_start, hooks[0].event);
    try std.testing.expectEqualStrings("echo start", hooks[0].command);
    try std.testing.expect(hooks[0].tool_filter == null);

    try std.testing.expectEqual(Event.tool_end, hooks[1].event);
    try std.testing.expectEqualStrings("notify.sh", hooks[1].command);
    try std.testing.expectEqualStrings("shell", hooks[1].tool_filter.?);
}

test "parseHooks empty/invalid JSON returns empty" {
    const allocator = std.testing.allocator;

    const hooks1 = try parseHooks(allocator, "");
    defer allocator.free(hooks1);
    try std.testing.expectEqual(@as(usize, 0), hooks1.len);

    const hooks2 = try parseHooks(allocator, "not json");
    defer allocator.free(hooks2);
    try std.testing.expectEqual(@as(usize, 0), hooks2.len);

    const hooks3 = try parseHooks(allocator, "42");
    defer allocator.free(hooks3);
    try std.testing.expectEqual(@as(usize, 0), hooks3.len);
}

test "parseHooks skips unknown events" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"event": "unknown_event", "command": "skip me"},
        \\ {"event": "turn_end", "command": "keep me"}]
    ;
    const hooks = try parseHooks(allocator, json);
    defer freeHooks(allocator, hooks);

    try std.testing.expectEqual(@as(usize, 1), hooks.len);
    try std.testing.expectEqual(Event.turn_end, hooks[0].event);
}

test "runHooks filters by event type" {
    // This test just verifies the filter logic doesn't crash;
    // actual shell execution is not tested (platform-dependent).
    const hooks = [_]Hook{
        .{ .event = .turn_start, .command = "true" },
        .{ .event = .turn_end, .command = "true" },
    };
    // Calling with turn_start should not crash
    runHooks(std.testing.allocator, &hooks, .turn_start, .{});
}

test "runHooks tool_filter skips non-matching tools" {
    const hooks = [_]Hook{
        .{ .event = .tool_start, .command = "true", .tool_filter = "shell" },
    };
    // No tool_name in context → should skip (tool_filter set but no match)
    runHooks(std.testing.allocator, &hooks, .tool_start, .{});
    // Wrong tool name → should skip
    runHooks(std.testing.allocator, &hooks, .tool_start, .{ .tool_name = "file_read" });
}
