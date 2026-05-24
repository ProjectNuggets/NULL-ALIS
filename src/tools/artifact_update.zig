//! Wave 2C — agent-facing `artifact_update` tool.
//!
//! Appends a new version to an existing artifact. The new version
//! becomes the artifact's `current_version`; older versions stay
//! retrievable via `artifact_get` with an explicit version param so
//! the FE can render a full revision history.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const zaki_state = @import("../zaki_state.zig");
const artifact_types = @import("../artifacts/types.zig");
const observability = @import("../observability.zig");

pub const ArtifactUpdateTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "artifact_update";
    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Append a new version to an existing artifact, becoming its current version.",
        .use_when = &.{
            "Revising an artifact the user (or a prior turn) created",
            "Incorporating user feedback into a side-panel document",
            "Producing a follow-up draft of a plan/report/code listing",
        },
        .do_not_use_for = &.{
            "artifact_create — when no prior artifact exists yet",
            "file_edit — for in-place edits to workspace files",
            "memory_edit — for revising stored knowledge graph facts",
        },
        .cost_note = "Local Postgres write; one row appended to artifact_versions.",
        .completion_hint = "Returns the new version number.",
        .see_also = &.{
            "artifact_create — start a new artifact",
            "artifact_get — read the latest or a historical version",
            "artifact_list — discover existing artifacts by kind",
        },
    };
    comptime {
        @import("lint.zig").lintToolDescription("artifact_update", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Append a new version to an existing artifact. Use after artifact_create when the " ++
        "user asks for revisions; the artifact stays at the same id, just gains a new " ++
        "current_version with the new content.";
    pub const tool_params =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Artifact UUID returned by artifact_create."},"content":{"type":"string","description":"Full replacement content for the new version."},"change_summary":{"type":"string","description":"Optional 1-line summary of what changed (rendered in the version history)."}},"required":["id","content"]}
    ;

    pub const tool_metadata: @import("metadata.zig").ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .low,
        .cost_class = .a,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ArtifactUpdateTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ArtifactUpdateTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const artifact_id = root.getString(args, "id") orelse return ToolResult.fail("Missing 'id' parameter");
        if (artifact_id.len == 0) return ToolResult.fail("'id' must not be empty");

        const content = root.getString(args, "content") orelse return ToolResult.fail("Missing 'content' parameter");
        if (content.len == 0) return ToolResult.fail("'content' must not be empty");

        const change_summary = root.getString(args, "change_summary");

        const smgr = self.state_mgr orelse {
            return ToolResult{
                .success = false,
                .output = try allocator.dupe(u8, "artifact_update unavailable: state manager not bound (postgres not configured)"),
            };
        };
        const uid = self.user_id orelse {
            return ToolResult{
                .success = false,
                .output = try allocator.dupe(u8, "artifact_update unavailable: tenant user not bound"),
            };
        };

        // Fetch the artifact first so we can echo title/kind into the SSE
        // event AND assert ownership before we attempt the version
        // append. Two round trips on the happy path; cheap.
        const existing_opt = smgr.getArtifactById(allocator, uid, artifact_id) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to look up artifact: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        if (existing_opt == null) {
            return ToolResult{
                .success = false,
                .output = try std.fmt.allocPrint(allocator, "No artifact found with id={s} for this user", .{artifact_id}),
            };
        }
        var existing = existing_opt.?;
        defer existing.deinit(allocator);

        const content_hash = try artifact_types.computeContentHash(allocator, content);
        defer allocator.free(content_hash);
        const now_unix = std.time.timestamp();

        const new_version = smgr.appendArtifactVersion(
            allocator,
            uid,
            artifact_id,
            content,
            content_hash,
            "agent",
            change_summary,
            now_unix,
        ) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to update artifact: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };

        const url = try std.fmt.allocPrint(allocator, "/api/v1/users/{d}/artifacts/{s}", .{ uid, artifact_id });
        defer allocator.free(url);

        if (root.getToolObserver()) |obs| {
            const evt = observability.ObserverEvent{
                .artifact_event = .{
                    .op = "updated",
                    .artifact_id = artifact_id,
                    .title = existing.title,
                    .kind = existing.kind,
                    .version = new_version,
                    .url = url,
                    .change_summary = change_summary,
                },
            };
            obs.recordEvent(&evt);
        }

        const msg = try std.fmt.allocPrint(
            allocator,
            "Updated artifact {s} → version {d} (url={s})",
            .{ artifact_id, new_version, url },
        );
        return ToolResult{ .success = true, .output = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "artifact_update tool name" {
    var t = ArtifactUpdateTool{};
    try std.testing.expectEqualStrings("artifact_update", t.tool().name());
}

test "artifact_update schema requires id and content" {
    var t = ArtifactUpdateTool{};
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"content\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"change_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"id\",\"content\"]") != null);
}

test "artifact_update rejects missing id" {
    var t = ArtifactUpdateTool{};
    const parsed = try root.parseTestArgs("{\"content\":\"x\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "artifact_update rejects empty content" {
    var t = ArtifactUpdateTool{};
    const parsed = try root.parseTestArgs("{\"id\":\"abc\",\"content\":\"\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "artifact_update reports unavailable without state_mgr" {
    var t = ArtifactUpdateTool{};
    const parsed = try root.parseTestArgs("{\"id\":\"abc\",\"content\":\"hello\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "state manager not bound") != null);
}
