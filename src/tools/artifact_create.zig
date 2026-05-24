//! Wave 2C — agent-facing `artifact_create` tool.
//!
//! When the agent produces a substantial deliverable (a report, plan,
//! code block, diagram, slides outline), it should call this tool
//! instead of dumping inline in chat. The FE renders the result as a
//! named, versioned, editable side-panel document — the "agent
//! produces real work" UX shape.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const zaki_state = @import("../zaki_state.zig");
const artifact_types = @import("../artifacts/types.zig");
const observability = @import("../observability.zig");

pub const ArtifactCreateTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "artifact_create";
    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Create a named, versioned side-panel artifact (markdown, code, html, svg, json, mermaid).",
        .use_when = &.{
            "Output is a substantial deliverable (>300 words, a plan, a report, code, a diagram, slides outline)",
            "User asked for a document, write-up, or rendered code/diagram they will read or edit",
            "Subsequent turns may need to revise the same document — artifacts give you stable revision history",
        },
        .do_not_use_for = &.{
            "memory_store — for durable facts and preferences instead of authored documents",
            "file_write — for files inside the workspace filesystem instead of side-panel docs",
            "compose_memory — for synthesizing existing memory rows into a consolidated fact",
        },
        .cost_note = "Local Postgres write; no external API cost.",
        .completion_hint = "Returns the artifact id and its absolute URL.",
        .see_also = &.{
            "artifact_update — append a new version to an existing artifact",
            "artifact_get — read the latest or a specific version",
            "artifact_list — list this user's artifacts",
        },
    };
    comptime {
        @import("lint.zig").lintToolDescription("artifact_create", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Create a named, versioned side-panel artifact. Use this when your output is a " ++
        "substantial deliverable (a plan, report, code, diagram, slides outline). The user " ++
        "sees it as a separate editable panel with full revision history.";
    pub const tool_params =
        \\{"type":"object","properties":{"title":{"type":"string","description":"Short human-readable title for the artifact panel."},"kind":{"type":"string","enum":["markdown","code","html","svg","json","mermaid","plaintext"],"description":"Render kind. markdown for prose, code for source listings, mermaid for diagrams, etc."},"content":{"type":"string","description":"The full content body (becomes version 1)."}},"required":["title","kind","content"]}
    ;

    pub const tool_metadata: @import("metadata.zig").ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .low,
        .cost_class = .a,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ArtifactCreateTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ArtifactCreateTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const title = root.getString(args, "title") orelse return ToolResult.fail("Missing 'title' parameter");
        if (title.len == 0 or title.len > 200) return ToolResult.fail("'title' must be 1..200 chars");

        const kind_str = root.getString(args, "kind") orelse return ToolResult.fail("Missing 'kind' parameter");
        const kind = artifact_types.ArtifactKind.fromSlice(kind_str) orelse
            return ToolResult.fail("Invalid 'kind' — expected one of: markdown, code, html, svg, json, mermaid, plaintext");

        const content = root.getString(args, "content") orelse return ToolResult.fail("Missing 'content' parameter");
        if (content.len == 0) return ToolResult.fail("'content' must not be empty");

        const smgr = self.state_mgr orelse {
            return ToolResult{
                .success = false,
                .output = try allocator.dupe(u8, "artifact_create unavailable: state manager not bound (postgres not configured)"),
            };
        };
        const uid = self.user_id orelse {
            return ToolResult{
                .success = false,
                .output = try allocator.dupe(u8, "artifact_create unavailable: tenant user not bound"),
            };
        };

        const session_id_opt = root.getTurnContext().session_key;
        const content_hash = try artifact_types.computeContentHash(allocator, content);
        defer allocator.free(content_hash);
        const now_unix = std.time.timestamp();

        var artifact = smgr.createArtifact(
            allocator,
            uid,
            session_id_opt,
            title,
            kind.toSlice(),
            content,
            content_hash,
            now_unix,
        ) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to create artifact: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .output = msg };
        };
        defer artifact.deinit(allocator);

        // Build the canonical URL so the FE can fetch the content
        // synchronously after the SSE event arrives.
        const url = try std.fmt.allocPrint(allocator, "/api/v1/users/{d}/artifacts/{s}", .{ uid, artifact.id });
        defer allocator.free(url);

        // Fire the artifact_event observer hook so the SSE side-panel
        // refreshes in real time. Best-effort — observers can be null
        // (CLI / test paths) and we never block the tool on a missing
        // observer.
        if (root.getToolObserver()) |obs| {
            const evt = observability.ObserverEvent{
                .artifact_event = .{
                    .op = "created",
                    .artifact_id = artifact.id,
                    .title = artifact.title,
                    .kind = artifact.kind,
                    .version = artifact.current_version,
                    .url = url,
                },
            };
            obs.recordEvent(&evt);
        }

        const msg = try std.fmt.allocPrint(
            allocator,
            "Created artifact '{s}' (id={s}, kind={s}, version={d}, url={s})",
            .{ artifact.title, artifact.id, artifact.kind, artifact.current_version, url },
        );
        return ToolResult{ .success = true, .output = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "artifact_create tool name" {
    var t = ArtifactCreateTool{};
    try std.testing.expectEqualStrings("artifact_create", t.tool().name());
}

test "artifact_create schema has title, kind, content" {
    var t = ArtifactCreateTool{};
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "title") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "kind") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "content") != null);
}

test "artifact_create rejects invalid kind" {
    var t = ArtifactCreateTool{};
    const parsed = try root.parseTestArgs("{\"title\":\"x\",\"kind\":\"typescript\",\"content\":\"y\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Invalid 'kind'") != null);
}

test "artifact_create rejects empty title" {
    var t = ArtifactCreateTool{};
    const parsed = try root.parseTestArgs("{\"title\":\"\",\"kind\":\"markdown\",\"content\":\"y\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "artifact_create rejects missing content" {
    var t = ArtifactCreateTool{};
    const parsed = try root.parseTestArgs("{\"title\":\"x\",\"kind\":\"markdown\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
}

test "artifact_create reports unavailable without state_mgr" {
    var t = ArtifactCreateTool{};
    const parsed = try root.parseTestArgs("{\"title\":\"x\",\"kind\":\"markdown\",\"content\":\"hello\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "state manager not bound") != null);
}
