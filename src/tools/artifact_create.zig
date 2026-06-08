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

const log = std.log.scoped(.artifact_create);

pub const ArtifactCreateTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "artifact_create";
    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Create a share-ready, versioned side-panel artifact for substantial user deliverables.",
        .use_when = &.{
            "The user asks for a document, brief, report, deck outline, spreadsheet-like table, HTML page, diagram, or other shareable deliverable",
            "Your answer would otherwise be a long polished artifact rather than conversational guidance",
            "Subsequent turns may revise the same work and need stable version history",
            "You can produce a complete first draft now with real content, assumptions, and no placeholders",
        },
        .do_not_use_for = &.{
            "produce_document — for one-shot rendered PDF/DOCX/PPTX/XLSX/HTML files instead of an editable canvas",
            "memory_store — for durable facts and preferences instead of authored documents",
            "file_write — for files inside the workspace filesystem instead of side-panel docs",
            "compose_memory — for synthesizing existing memory rows into a consolidated fact",
        },
        .cost_note = "Local Postgres write; no external API cost.",
        .completion_hint = "Returns the artifact id and URL; tell the user the canvas is open.",
        .see_also = &.{
            "artifact_update — append a new version to an existing artifact",
            "artifact_get — read the latest or a specific version",
            "artifact_list — list this user's artifacts",
            "artifact_share — mint a public URL after the artifact is ready",
        },
    };
    comptime {
        @import("lint.zig").lintToolDescription("artifact_create", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Create a share-ready, versioned side-panel artifact. Use this when your output is a " ++
        "substantial deliverable (brief, report, deck outline, spreadsheet-like table, HTML page, code, or diagram) " ++
        "that the user will read, refine, share, or export. The first draft must be complete: clear title, strong " ++
        "opening answer, useful headings, concise sections, tables where helpful, explicit assumptions when inputs " ++
        "are sparse, and no placeholders, lorem ipsum, or meta commentary. Valid kinds are markdown, code, html, " ++
        "svg, json, mermaid, and plaintext. Use markdown for prose and deck outlines, html for complete pages, " ++
        "mermaid for diagrams, and plaintext or code for CSV-like spreadsheet sources; XLSX export happens through produce_document.";
    pub const tool_params =
        \\{"type":"object","properties":{"title":{"type":"string","description":"Short human-readable title for the artifact panel."},"kind":{"type":"string","enum":["markdown","code","html","svg","json","mermaid","plaintext"],"description":"Render kind. Use markdown for prose/reports/deck outlines, html for complete pages, mermaid for diagrams, json for structured data, and plaintext/code for CSV-like spreadsheet sources. There is no csv kind."},"content":{"type":"string","description":"The full share-ready content body (becomes version 1). Must be complete, with no placeholders or meta commentary."}},"required":["title","kind","content"]}
    ;

    pub const tool_metadata: @import("metadata.zig").ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .mutating = true, .supervised_auto_approve = true },
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
                .error_msg = try allocator.dupe(u8, "artifact_create unavailable: state manager not bound (postgres not configured)"),
                .output = "",
            };
        };
        const uid = self.user_id orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "artifact_create unavailable: tenant user not bound"),
                .output = "",
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
            log.warn("artifact_create persistence failed user_id={d} kind={s} err={s}", .{ uid, kind.toSlice(), @errorName(err) });
            const msg = try std.fmt.allocPrint(allocator, "Failed to create artifact: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
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
        // HIGH 2.A: counter on every successful create. Global emit; if
        // no observer is wired, falls through to a scoped log line.
        observability.recordMetricGlobal(.{ .artifact_create_total = 1 });

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

test "artifact_create guidance pins share-ready valid kind behavior" {
    var t = ArtifactCreateTool{};
    const desc = t.tool().description();
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, desc, "share-ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "no placeholders") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "produce_document") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "XLSX") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "There is no csv kind") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"csv\"") == null);
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
    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "state manager not bound") != null);
}
