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

const log = std.log.scoped(.artifact_update);

pub const ArtifactUpdateTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "artifact_update";
    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Revise an existing artifact by appending a complete new current version.",
        .use_when = &.{
            "Revising an artifact the user (or a prior turn) created",
            "Incorporating user feedback into a side-panel document",
            "Polishing a draft into a more share-ready report, brief, deck outline, table, page, or diagram",
            "The same artifact id should remain open while version history records the change",
        },
        .do_not_use_for = &.{
            "artifact_create — when no prior artifact exists yet",
            "artifact_get — when you need to read the current body before revising it",
            "file_edit — for in-place edits to workspace files",
            "memory_edit — for revising stored knowledge graph facts",
        },
        .cost_note = "Local Postgres write; one row appended to artifact_versions.",
        .completion_hint = "Returns the new version number; summarize what changed.",
        .see_also = &.{
            "artifact_create — start a new artifact",
            "artifact_get — read the latest or a historical version",
            "artifact_list — discover existing artifacts by kind",
            "artifact_diff — review what changed between two artifact versions",
        },
    };
    comptime {
        @import("lint.zig").lintToolDescription("artifact_update", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Append a complete new version to an existing artifact. Use after artifact_create when the " ++
        "user asks for revisions, polish, restructuring, or follow-up edits; keep the same artifact id so the canvas " ++
        "and public/share/export lifecycle stay attached. The content field is a full replacement body, not a patch " ++
        "fragment. Preserve the artifact kind, improve the whole draft, and make the result share-ready: clear opening " ++
        "answer, useful headings, concise sections, tables where helpful, explicit assumptions when context is sparse, " ++
        "and no placeholders, lorem ipsum, or meta commentary. If you have not seen the current body, call artifact_get first.";
    pub const tool_params =
        \\{"type":"object","properties":{"id":{"type":"string","description":"Artifact UUID returned by artifact_create or artifact_list."},"content":{"type":"string","description":"Full replacement content for the new version, not a diff or partial patch. Must be complete and share-ready."},"change_summary":{"type":"string","description":"Optional 1-line summary of what changed (rendered in the version history)."}},"required":["id","content"]}
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
                .error_msg = try allocator.dupe(u8, "artifact_update unavailable: state manager not bound (postgres not configured)"),
                .output = "",
            };
        };
        const uid = self.user_id orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "artifact_update unavailable: tenant user not bound"),
                .output = "",
            };
        };

        // Fetch the artifact first so we can echo title/kind into the SSE
        // event AND assert ownership before we attempt the version
        // append. Two round trips on the happy path; cheap.
        const existing_opt = smgr.getArtifactById(allocator, uid, artifact_id) catch |err| {
            log.warn("artifact_update lookup failed user_id={d} artifact_id={s} err={s}", .{ uid, artifact_id, @errorName(err) });
            const msg = try std.fmt.allocPrint(allocator, "Failed to look up artifact: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };
        if (existing_opt == null) {
            return ToolResult{
                .success = false,
                .error_msg = try std.fmt.allocPrint(allocator, "No artifact found with id={s} for this user", .{artifact_id}),
                .output = "",
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
            log.warn("artifact_update append failed user_id={d} artifact_id={s} err={s}", .{ uid, artifact_id, @errorName(err) });
            const msg = try std.fmt.allocPrint(allocator, "Failed to update artifact: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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
        // HIGH 2.A — counter on every successful version append.
        observability.recordMetricGlobal(.{ .artifact_update_total = 1 });

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

test "artifact_update guidance pins same-artifact full replacement behavior" {
    var t = ArtifactUpdateTool{};
    const desc = t.tool().description();
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, desc, "same artifact id should remain open") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "complete new current version") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "artifact_get") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "share-ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "not a diff or partial patch") != null);
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
    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "state manager not bound") != null);
}
