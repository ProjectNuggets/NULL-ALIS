//! Wave 2C — agent-facing `artifact_get` tool.
//!
//! Reads the latest version of an artifact (or a specific version if
//! `version` is provided). Read-only; safe in every execution mode.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const zaki_state = @import("../zaki_state.zig");

const log = std.log.scoped(.artifact_get);

/// Per-result cap on the content slice we surface to the agent. Same
/// rationale as memory_recall: the underlying artifact still HAS the
/// full content; this cap is on the in-context PROJECTION. The agent
/// can re-call with a specific version field to read more if needed.
const ARTIFACT_GET_CONTENT_CAP: usize = 4096;

pub const ArtifactGetTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "artifact_get";
    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Read an artifact's latest version (or a specific historical version).",
        .use_when = &.{
            "Refreshing memory of what you wrote into a prior artifact before revising it",
            "Comparing prior content against incoming user feedback",
            "Quoting from a previously-authored side-panel document",
        },
        .do_not_use_for = &.{
            "artifact_list — when you don't know the artifact id yet",
            "file_read — for workspace filesystem files",
            "memory_recall — for stored facts and preferences",
        },
        .cost_note = "Single Postgres read; no external API.",
        .completion_hint = "Returns content (capped at 4096 chars in tool output; full body via HTTP).",
        .see_also = &.{
            "artifact_list — discover artifact ids by recency or kind",
            "artifact_update — append a new version after reading the current one",
            "artifact_create — start a new artifact",
        },
    };
    comptime {
        @import("lint.zig").lintToolDescription("artifact_get", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Read an artifact's latest version (or a specific historical version). Use this " ++
        "before artifact_update when you need to see the current content to make a " ++
        "considered revision.";
    pub const tool_params =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Artifact UUID."},"version":{"type":"integer","description":"Optional historical version number; latest when omitted."}},"required":["id"]}
    ;

    pub const tool_metadata: @import("metadata.zig").ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .read_only = true, .background_safe = true, .concurrency_safe = true },
        .risk_level = .low,
        .cost_class = .a,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ArtifactGetTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ArtifactGetTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const artifact_id = root.getString(args, "id") orelse return ToolResult.fail("Missing 'id' parameter");
        if (artifact_id.len == 0) return ToolResult.fail("'id' must not be empty");

        const version_opt: ?u64 = if (root.getInt(args, "version")) |v| (if (v > 0) @intCast(v) else null) else null;

        const smgr = self.state_mgr orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "artifact_get unavailable: state manager not bound (postgres not configured)"),
                .output = "",
            };
        };
        const uid = self.user_id orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "artifact_get unavailable: tenant user not bound"),
                .output = "",
            };
        };

        const ver_opt = smgr.getArtifactVersion(allocator, uid, artifact_id, version_opt) catch |err| {
            log.warn("artifact_get read failed user_id={d} artifact_id={s} err={s}", .{ uid, artifact_id, @errorName(err) });
            const msg = try std.fmt.allocPrint(allocator, "Failed to read artifact: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };
        if (ver_opt == null) {
            return ToolResult{
                .success = false,
                .error_msg = try std.fmt.allocPrint(allocator, "No artifact version found (id={s})", .{artifact_id}),
                .output = "",
            };
        }
        var ver = ver_opt.?;
        defer ver.deinit(allocator);

        // Cap the projection. The full body is still available via the
        // HTTP endpoint; the tool message is a context-projection, not
        // a data dump.
        const cap = ARTIFACT_GET_CONTENT_CAP;
        const truncated = ver.content.len > cap;
        const body = if (truncated) ver.content[0..cap] else ver.content;
        const tail = if (truncated) " […content truncated; fetch via HTTP for full body]" else "";

        const msg = try std.fmt.allocPrint(
            allocator,
            "Artifact {s} version {d} (author={s}, created_at={d}):\n{s}{s}",
            .{ artifact_id, ver.version, ver.author, ver.created_at_unix, body, tail },
        );
        return ToolResult{ .success = true, .output = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "artifact_get tool name" {
    var t = ArtifactGetTool{};
    try std.testing.expectEqualStrings("artifact_get", t.tool().name());
}

test "artifact_get schema requires id and accepts version" {
    var t = ArtifactGetTool{};
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"version\"") != null);
}

test "artifact_get rejects missing id" {
    var t = ArtifactGetTool{};
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "artifact_get reports unavailable without state_mgr" {
    var t = ArtifactGetTool{};
    const parsed = try root.parseTestArgs("{\"id\":\"abc\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "state manager not bound") != null);
}
