//! Wave 2C — agent-facing `artifact_list` tool.
//!
//! Returns a recency-sorted list of the calling user's artifacts.
//! Read-only; safe in every execution mode.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const zaki_state = @import("../zaki_state.zig");
const artifact_types = @import("../artifacts/types.zig");

const log = std.log.scoped(.artifact_list);

pub const ArtifactListTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "artifact_list";
    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "List the user's artifacts, newest first, optionally filtered by kind.",
        .use_when = &.{
            "Discovering whether a relevant artifact already exists before creating a new one",
            "Surfacing the user's recent side-panel documents to reason about",
            "Confirming an artifact's id and version before calling artifact_update",
        },
        .do_not_use_for = &.{
            "artifact_get — when you already know the artifact id",
            "memory_list — for listing stored memory rows",
            "file_read — for listing workspace files",
        },
        .cost_note = "Single Postgres read; no external API.",
        .completion_hint = "Returns up to `limit` rows ordered by updated_at DESC.",
        .see_also = &.{
            "artifact_get — read a specific artifact's content",
            "artifact_create — start a new artifact",
            "artifact_update — append a revision to an existing artifact",
        },
    };
    comptime {
        @import("lint.zig").lintToolDescription("artifact_list", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "List this user's artifacts. Returns a recency-sorted slice of {id, title, kind, " ++
        "current_version, updated_at}. Use to discover existing artifacts before creating a " ++
        "new one or to surface side-panel docs.";
    pub const tool_params =
        \\{"type":"object","properties":{"kind":{"type":"string","enum":["markdown","code","html","svg","json","mermaid","plaintext"],"description":"Optional kind filter."},"limit":{"type":"integer","description":"Max rows to return (default 50, capped at 200)."}}}
    ;

    pub const tool_metadata: @import("metadata.zig").ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ArtifactListTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ArtifactListTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const kind_filter_raw = root.getString(args, "kind");
        // Validate kind if provided — fail fast on typos rather than
        // silently returning empty results.
        if (kind_filter_raw) |k| {
            if (artifact_types.ArtifactKind.fromSlice(k) == null) {
                return ToolResult.fail("Invalid 'kind' filter — see schema for the allowed set");
            }
        }
        const limit_raw = root.getInt(args, "limit") orelse 50;
        const limit: u32 = if (limit_raw <= 0) 50 else if (limit_raw > 200) 200 else @intCast(limit_raw);

        const smgr = self.state_mgr orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "artifact_list unavailable: state manager not bound (postgres not configured)"),
                .output = "",
            };
        };
        const uid = self.user_id orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "artifact_list unavailable: tenant user not bound"),
                .output = "",
            };
        };

        const rows = smgr.listArtifactsForUser(allocator, uid, kind_filter_raw, null, limit) catch |err| {
            log.warn("artifact_list query failed user_id={d} err={s}", .{ uid, @errorName(err) });
            const msg = try std.fmt.allocPrint(allocator, "Failed to list artifacts: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };
        defer zaki_state.freeArtifactRows(allocator, rows);

        if (rows.len == 0) {
            return ToolResult{
                .success = true,
                .output = try allocator.dupe(u8, "No artifacts found."),
            };
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);
        try w.print("Found {d} artifact(s):\n", .{rows.len});
        for (rows, 0..) |r, i| {
            try w.print("{d}. [{s}] {s} (id={s}, version={d}, updated_at={d})\n", .{
                i + 1,
                r.kind,
                r.title,
                r.id,
                r.current_version,
                r.updated_at_unix,
            });
        }
        return ToolResult{ .success = true, .output = try out.toOwnedSlice(allocator) };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "artifact_list tool name" {
    var t = ArtifactListTool{};
    try std.testing.expectEqualStrings("artifact_list", t.tool().name());
}

test "artifact_list schema accepts optional kind and limit" {
    var t = ArtifactListTool{};
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"kind\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"limit\"") != null);
}

test "artifact_list rejects invalid kind" {
    var t = ArtifactListTool{};
    const parsed = try root.parseTestArgs("{\"kind\":\"typescript\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "artifact_list reports unavailable without state_mgr" {
    var t = ArtifactListTool{};
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "state manager not bound") != null);
}
