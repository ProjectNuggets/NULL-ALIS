//! `artifact_history` — agent-side wrapper over
//! `GET /api/v1/users/:id/artifacts/:id/history`.
//!
//! Lists every revision of an artifact (version, author, created_at,
//! change_summary, content_hash) so the agent can answer "how many
//! revisions has this had?" / "when was v3 written?" without
//! scraping the canvas REST. Mirrors `handleArtifactHistory` in
//! gateway.zig.
//!
//! Cost class A — single Postgres scan over `artifact_versions`
//! filtered by `(user_id, artifact_id)`. Risk low.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const zaki_state = @import("../zaki_state.zig");

/// Hard cap on the version list — keeps response size predictable
/// even if a runaway agent created hundreds of versions.
const ARTIFACT_HISTORY_MAX_LIMIT: usize = 100;
const ARTIFACT_HISTORY_DEFAULT_LIMIT: usize = 20;

pub const ArtifactHistoryTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "artifact_history";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "List the version history of a canvas artifact (newest version first).",
        .use_when = &.{
            "User asks 'how many revisions does this have?' or 'when was the last edit?'",
            "Before artifact_diff to discover which version numbers are valid",
            "Auditing who edited an artifact (author column distinguishes 'agent' from 'user' edits)",
        },
        .do_not_use_for = &.{
            "artifact_get — for one version's full content rather than the version metadata list",
            "artifact_diff — for content differences between two specific versions",
            "artifact_list — for discovering artifact ids across the whole user's canvas",
        },
        .cost_note = "Single Postgres scan over artifact_versions; cheap.",
        .completion_hint = "Returns a list of {version, author, created_at_unix, change_summary, content_hash} records.",
        .see_also = &.{
            "artifact_get — read a specific version's content",
            "artifact_diff — see what changed between two versions",
            "artifact_list — find artifact ids before querying history",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("artifact_history", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "List every version of an artifact with author, timestamp, change summary, and " ++
        "content hash. Use it to discover valid version numbers before artifact_diff or " ++
        "artifact_get, or to audit who edited what when.";

    pub const tool_params =
        \\{"type":"object","properties":{"artifact_id":{"type":"string","description":"UUID of the artifact."},"limit":{"type":"integer","description":"Max number of versions to return (default 20, max 100). Newest-first."}},"required":["artifact_id"]}
    ;

    pub const tool_metadata: @import("metadata.zig").ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ArtifactHistoryTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ArtifactHistoryTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const artifact_id = root.getString(args, "artifact_id") orelse return ToolResult.fail("Missing 'artifact_id' parameter");
        if (artifact_id.len == 0) return ToolResult.fail("'artifact_id' must not be empty");

        var limit: usize = ARTIFACT_HISTORY_DEFAULT_LIMIT;
        if (root.getInt(args, "limit")) |v| {
            if (v <= 0) return ToolResult.fail("'limit' must be a positive integer");
            limit = @intCast(@min(v, @as(i64, @intCast(ARTIFACT_HISTORY_MAX_LIMIT))));
        }

        const smgr = self.state_mgr orelse {
            return ToolResult{
                .success = false,
                .output = try allocator.dupe(u8, "artifact_history unavailable: state manager not bound (postgres not configured)"),
            };
        };
        const uid = self.user_id orelse {
            return ToolResult{
                .success = false,
                .output = try allocator.dupe(u8, "artifact_history unavailable: tenant user not bound"),
            };
        };

        // Ownership / existence check first — matches the HTTP handler
        // posture (404 on missing or foreign artifact, no existence
        // leak via empty list).
        var artifact_opt = smgr.getArtifactById(allocator, uid, artifact_id) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "artifact_history: ownership lookup failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        if (artifact_opt == null) {
            return ToolResult{
                .success = false,
                .output = try std.fmt.allocPrint(allocator, "artifact not found (id={s})", .{artifact_id}),
            };
        }
        var artifact = artifact_opt.?;
        artifact.deinit(allocator);
        _ = &artifact_opt;

        const history = smgr.listArtifactVersionHistory(allocator, uid, artifact_id) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "artifact_history: read failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer zaki_state.freeArtifactHistoryRows(allocator, history);

        // The Manager returns versions in chronological order (oldest
        // first). The agent wants newest-first so the most recent
        // version shows up at the top of the response — iterate in
        // reverse, capped at `limit`.
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);
        const total = history.len;
        const take = @min(limit, total);
        try w.print("{{\"artifact_id\":\"{s}\",\"total_versions\":{d},\"returned\":{d},\"history\":[", .{ artifact_id, total, take });

        var emitted: usize = 0;
        var i: usize = total;
        while (i > 0 and emitted < take) {
            i -= 1;
            const h = history[i];
            if (emitted > 0) try w.writeAll(",");
            try w.print("{{\"version\":{d}", .{h.version});
            if (h.parent_version) |pv| try w.print(",\"parent_version\":{d}", .{pv});
            try w.writeAll(",\"author\":\"");
            try jsonEscapeInto(w, h.author);
            try w.print("\",\"created_at_unix\":{d},\"content_hash\":\"", .{h.created_at_unix});
            try jsonEscapeInto(w, h.content_hash);
            try w.writeAll("\"");
            if (h.change_summary) |cs| {
                try w.writeAll(",\"change_summary\":\"");
                try jsonEscapeInto(w, cs);
                try w.writeAll("\"");
            }
            try w.writeAll("}");
            emitted += 1;
        }
        try w.writeAll("]}");
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

test "artifact_history tool name" {
    var t = ArtifactHistoryTool{};
    try std.testing.expectEqualStrings("artifact_history", t.tool().name());
}

test "artifact_history schema requires artifact_id, accepts limit" {
    var t = ArtifactHistoryTool{};
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "artifact_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"artifact_id\"]") != null);
}

test "artifact_history rejects missing artifact_id" {
    var t = ArtifactHistoryTool{};
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "artifact_id") != null);
}

test "artifact_history rejects non-positive limit" {
    var t = ArtifactHistoryTool{};
    const parsed = try root.parseTestArgs("{\"artifact_id\":\"abc\",\"limit\":-1}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "positive integer") != null);
}

test "artifact_history reports unavailable without state_mgr" {
    var t = ArtifactHistoryTool{};
    const parsed = try root.parseTestArgs("{\"artifact_id\":\"abc\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "state manager not bound") != null);
}

test "artifact_history metadata is read_only background_safe" {
    try std.testing.expect(ArtifactHistoryTool.tool_metadata.flags.read_only);
    try std.testing.expect(ArtifactHistoryTool.tool_metadata.flags.background_safe);
    try std.testing.expectEqual(@import("metadata.zig").CostClass.a, ArtifactHistoryTool.tool_metadata.cost_class);
}
