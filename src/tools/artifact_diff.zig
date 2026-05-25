//! `artifact_diff` — agent-side wrapper over
//! `GET /api/v1/users/:id/artifacts/:id/diff/:from/:to`.
//!
//! Closes the audit gap that the agent today CANNOT answer "what
//! changed since v3?" questions without manually fetching two
//! versions and diffing them mentally. Computes a unified line diff
//! between two versions of an artifact using
//! `artifacts/diff.unifiedLineDiff` — the same routine the HTTP
//! handler uses, so the agent's view matches the FE canvas view.
//!
//! Cost class A — two Postgres reads + an in-process diff. Risk low.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const zaki_state = @import("../zaki_state.zig");
const artifacts_diff = @import("../artifacts/diff.zig");

pub const ArtifactDiffTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "artifact_diff";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Compute a unified diff between two versions of a canvas artifact.",
        .use_when = &.{
            "User asks 'what changed between v3 and v5' or 'show me the diff since the last revision'",
            "Reviewing your own prior edit before composing a new revision — diff against the parent",
            "Producing a concise change-summary before asking the user to approve a sweep of edits",
        },
        .do_not_use_for = &.{
            "artifact_get — for reading one version's full content rather than a diff",
            "artifact_history — for the list of versions rather than content differences",
            "git_operations — for filesystem-file diffs rather than canvas-artifact diffs",
        },
        .cost_note = "Two Postgres reads + in-process unified-diff compute; no provider calls.",
        .completion_hint = "Returns artifact_id, from_version, to_version, and a unified diff text.",
        .see_also = &.{
            "artifact_history — discover which version numbers exist before diffing",
            "artifact_get — read either side of the diff in full when context is needed",
            "artifact_update — append a new version after deciding what to change",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("artifact_diff", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Compute the diff between two versions of an artifact on the canvas. Returns a " ++
        "unified-format diff suitable for answering 'what changed since v3?' questions.";

    pub const tool_params =
        \\{"type":"object","properties":{"artifact_id":{"type":"string","description":"UUID of the artifact."},"from_version":{"type":"integer","description":"Older version number (the 'before' side)."},"to_version":{"type":"integer","description":"Newer version number (the 'after' side)."}},"required":["artifact_id","from_version","to_version"]}
    ;

    pub const tool_metadata: @import("metadata.zig").ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ArtifactDiffTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ArtifactDiffTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const artifact_id = root.getString(args, "artifact_id") orelse return ToolResult.fail("Missing 'artifact_id' parameter");
        if (artifact_id.len == 0) return ToolResult.fail("'artifact_id' must not be empty");

        const from_v_i = root.getInt(args, "from_version") orelse return ToolResult.fail("Missing 'from_version' parameter");
        const to_v_i = root.getInt(args, "to_version") orelse return ToolResult.fail("Missing 'to_version' parameter");
        if (from_v_i <= 0 or to_v_i <= 0) return ToolResult.fail("version numbers must be positive integers");
        const from_v: u64 = @intCast(from_v_i);
        const to_v: u64 = @intCast(to_v_i);

        const smgr = self.state_mgr orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "artifact_diff unavailable: state manager not bound (postgres not configured)"),
                .output = "",
            };
        };
        const uid = self.user_id orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "artifact_diff unavailable: tenant user not bound"),
                .output = "",
            };
        };

        var before_opt = smgr.getArtifactVersion(allocator, uid, artifact_id, from_v) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "artifact_diff: from_version read failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };
        if (before_opt == null) {
            return ToolResult{
                .success = false,
                .error_msg = try std.fmt.allocPrint(allocator, "from_version {d} not found for artifact {s}", .{ from_v, artifact_id }),
                .output = "",
            };
        }
        var before = before_opt.?;
        defer before.deinit(allocator);
        _ = &before_opt;

        var after_opt = smgr.getArtifactVersion(allocator, uid, artifact_id, to_v) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "artifact_diff: to_version read failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };
        if (after_opt == null) {
            return ToolResult{
                .success = false,
                .error_msg = try std.fmt.allocPrint(allocator, "to_version {d} not found for artifact {s}", .{ to_v, artifact_id }),
                .output = "",
            };
        }
        var after = after_opt.?;
        defer after.deinit(allocator);
        _ = &after_opt;

        const diff_text = artifacts_diff.unifiedLineDiff(allocator, before.content, after.content) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "artifact_diff: diff compute failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };
        defer allocator.free(diff_text);

        // Build a JSON object so the diff text is machine-parseable
        // while remaining single-blob-ready for the agent to surface.
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        try w.print("{{\"artifact_id\":\"{s}\",\"from_version\":{d},\"to_version\":{d},\"diff\":\"", .{ artifact_id, from_v, to_v });
        try jsonEscapeInto(w, diff_text);
        try w.writeAll("\"}");
        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }
};

fn jsonEscapeInto(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "artifact_diff tool name" {
    var t = ArtifactDiffTool{};
    try std.testing.expectEqualStrings("artifact_diff", t.tool().name());
}

test "artifact_diff schema requires all three params" {
    var t = ArtifactDiffTool{};
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "artifact_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "from_version") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "to_version") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"artifact_id\",\"from_version\",\"to_version\"]") != null);
}

test "artifact_diff rejects missing artifact_id" {
    var t = ArtifactDiffTool{};
    const parsed = try root.parseTestArgs("{\"from_version\":1,\"to_version\":2}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "artifact_id") != null);
}

test "artifact_diff rejects missing from_version" {
    var t = ArtifactDiffTool{};
    const parsed = try root.parseTestArgs("{\"artifact_id\":\"abc\",\"to_version\":2}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "from_version") != null);
}

test "artifact_diff rejects non-positive versions" {
    var t = ArtifactDiffTool{};
    const parsed = try root.parseTestArgs("{\"artifact_id\":\"abc\",\"from_version\":0,\"to_version\":1}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "positive integers") != null);
}

test "artifact_diff reports unavailable without state_mgr" {
    var t = ArtifactDiffTool{};
    const parsed = try root.parseTestArgs("{\"artifact_id\":\"abc\",\"from_version\":1,\"to_version\":2}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);

    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "state manager not bound") != null);
}

test "artifact_diff metadata is read_only" {
    try std.testing.expect(ArtifactDiffTool.tool_metadata.flags.read_only);
    try std.testing.expect(ArtifactDiffTool.tool_metadata.flags.background_safe);
    try std.testing.expectEqual(@import("metadata.zig").CostClass.a, ArtifactDiffTool.tool_metadata.cost_class);
}
