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
const text_norm = @import("../memory/text_norm.zig");

const log = std.log.scoped(.artifact_get);

/// Default per-result content slice surfaced to the agent.
///
/// The underlying artifact still has the full body; this is an in-context
/// projection. Long document work can request larger pages or walk the body
/// with offset/next_offset without relying on a silent excerpt.
const DEFAULT_ARTIFACT_GET_CONTENT_CHARS: usize = 16_384;
const MAX_ARTIFACT_GET_CONTENT_CHARS: usize = 200_000;

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
        .completion_hint = "Returns artifact content with offset/max_chars paging for long bodies.",
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
        \\{"type":"object","properties":{"id":{"type":"string","description":"Artifact UUID."},"version":{"type":"integer","description":"Optional historical version number; latest when omitted."},"offset":{"type":"integer","default":0,"description":"Zero-based byte offset into the artifact body for long-document paging."},"max_chars":{"type":"integer","default":16384,"description":"Maximum body characters/bytes to return in this call. Max 200000."}},"required":["id"]}
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

        const page = artifactPage(args, ver.content);
        const remaining = ver.content[page.offset..];
        const body = text_norm.truncateUtf8(remaining, page.max_chars);
        const next_offset = page.offset + body.len;
        const partial = next_offset < ver.content.len;
        var next_buf: [32]u8 = undefined;
        const next_offset_text = if (partial)
            std.fmt.bufPrint(&next_buf, "{d}", .{next_offset}) catch "unknown"
        else
            "null";

        const msg = try std.fmt.allocPrint(
            allocator,
            "Artifact {s} version {d} (author={s}, created_at={d}, content_bytes={d}, offset={d}, shown_bytes={d}, partial={s}, next_offset={s}):\n{s}{s}",
            .{
                artifact_id,
                ver.version,
                ver.author,
                ver.created_at_unix,
                ver.content.len,
                page.offset,
                body.len,
                if (partial) "true" else "false",
                next_offset_text,
                body,
                if (partial) "\n\n[content partial: call artifact_get again with offset=next_offset and max_chars up to 200000 to continue; do not assume omitted content was visible]" else "",
            },
        );
        return ToolResult{ .success = true, .output = msg };
    }
};

const ArtifactPage = struct {
    offset: usize,
    max_chars: usize,
};

fn artifactPage(args: JsonObjectMap, content: []const u8) ArtifactPage {
    var offset: usize = 0;
    if (root.getInt(args, "offset")) |raw| {
        if (raw > 0) offset = @as(usize, @intCast(raw));
    }
    const content_len = content.len;
    if (offset > content_len) offset = content_len;

    var max_chars = DEFAULT_ARTIFACT_GET_CONTENT_CHARS;
    if (root.getInt(args, "max_chars")) |raw| {
        if (raw > 0) {
            max_chars = @as(usize, @intCast(raw));
        }
    }
    max_chars = @min(max_chars, MAX_ARTIFACT_GET_CONTENT_CHARS);

    return .{ .offset = utf8StartOffset(content, offset), .max_chars = max_chars };
}

fn utf8StartOffset(content: []const u8, offset: usize) usize {
    if (offset >= content.len) return content.len;
    var i = offset;
    while (i < content.len and (content[i] & 0xC0) == 0x80) : (i += 1) {}
    return i;
}

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
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"offset\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"max_chars\"") != null);
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

test "artifact_get page defaults and clamps max chars" {
    const parsed = try root.parseTestArgs("{\"id\":\"abc\",\"max_chars\":999999}");
    defer parsed.deinit();
    const page = artifactPage(parsed.value.object, "hello");
    try std.testing.expectEqual(@as(usize, 0), page.offset);
    try std.testing.expectEqual(@as(usize, MAX_ARTIFACT_GET_CONTENT_CHARS), page.max_chars);
}

test "artifact_get page honors positive offset and skips utf8 continuation bytes" {
    const parsed = try root.parseTestArgs("{\"id\":\"abc\",\"offset\":4,\"max_chars\":12}");
    defer parsed.deinit();
    const content = "abc🎉def";
    const page = artifactPage(parsed.value.object, content);
    try std.testing.expectEqual(@as(usize, 7), page.offset);
    try std.testing.expectEqual(@as(usize, 12), page.max_chars);
}
