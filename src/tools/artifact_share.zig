//! `artifact_share` — agent-side wrapper over
//! `POST /api/v1/users/:id/artifacts/:id/share`.
//!
//! Closes the §14.5-borderline gap where the prompt previously
//! instructed the agent to NARRATE the share endpoint URL to the user
//! (because no tool existed). Now the agent can actually mint the
//! share URL itself when asked "please share this for me", returning
//! the public URL inline.
//!
//! Mirrors `handleArtifactShareCreate` in gateway.zig: validates
//! `expires_in_hours` against the same `SHARE_MAX_EXPIRY_HOURS` cap
//! (720 hours / 30 days), defaults to `DEFAULT_SHARE_EXPIRY_HOURS`
//! (168 hours / 7 days). Per-tenant ownership is enforced at the
//! `setArtifactShare` SQL level (`WHERE user_id = ...`) — same
//! posture as artifact_get/update.
//!
//! Risk-level: medium. Publishes to the public web; the share URL is
//! unauthenticated. In `.supervised` autonomy the agent's preflight
//! policy raises an approval prompt before this tool runs.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const zaki_state = @import("../zaki_state.zig");
const artifacts_store = @import("../artifacts/store.zig");

pub const ArtifactShareTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "artifact_share";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Mint a public share URL for an artifact you authored on the canvas.",
        .use_when = &.{
            "User asks 'please share this' or 'send me a link to that document' referring to an artifact",
            "Handing a deliverable off to a recipient outside the chat (email, Slack, anywhere)",
            "Granting time-bounded read-only access to a side-panel document for review",
        },
        .do_not_use_for = &.{
            "artifact_get — for reading an artifact's content rather than publishing it",
            "artifact_revoke_share — for taking a live share down rather than creating one",
            "produce_document — for rendering a downloadable file rather than a hosted URL",
        },
        .cost_note = "Publishes a publicly-accessible URL. The URL is unauthenticated for its lifetime.",
        .completion_hint = "Returns share_code, share_url, and expires_at_unix.",
        .see_also = &.{
            "artifact_revoke_share — revoke a previously-minted share",
            "artifact_get — read the artifact content before sharing it",
            "artifact_list — discover artifact ids when you don't know which to share",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("artifact_share", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Mint a public share URL for an artifact. Returns a URL the user can send to " ++
        "anyone (no auth required to view). Expiry defaults to 7 days; max 30 days.";

    pub const tool_params =
        \\{"type":"object","properties":{"artifact_id":{"type":"string","description":"UUID of the artifact to share."},"expires_in_hours":{"type":"integer","description":"Lifetime of the share in hours (default 168 / 7 days, max 720 / 30 days)."}},"required":["artifact_id"]}
    ;

    pub const tool_metadata: @import("metadata.zig").ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .medium,
        .cost_class = .a,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ArtifactShareTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ArtifactShareTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const artifact_id = root.getString(args, "artifact_id") orelse return ToolResult.fail("Missing 'artifact_id' parameter");
        if (artifact_id.len == 0) return ToolResult.fail("'artifact_id' must not be empty");

        // Validate hours BEFORE state_mgr lookup so the argument-shape
        // error surface is testable without a live Postgres — mirrors
        // handleArtifactShareCreate's ordering.
        var hours: i64 = artifacts_store.DEFAULT_SHARE_EXPIRY_HOURS;
        if (root.getInt(args, "expires_in_hours")) |h| {
            if (h <= 0) return ToolResult.fail("'expires_in_hours' must be a positive integer");
            if (h > artifacts_store.SHARE_MAX_EXPIRY_HOURS) {
                const msg = try std.fmt.allocPrint(
                    allocator,
                    "'expires_in_hours' exceeds maximum ({d}). Pick a value between 1 and {d}.",
                    .{ artifacts_store.SHARE_MAX_EXPIRY_HOURS, artifacts_store.SHARE_MAX_EXPIRY_HOURS },
                );
                return ToolResult{ .success = false, .error_msg = msg, .output = "" };
            }
            hours = h;
        }

        const smgr = self.state_mgr orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "artifact_share unavailable: state manager not bound (postgres not configured)"),
                .output = "",
            };
        };
        const uid = self.user_id orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "artifact_share unavailable: tenant user not bound"),
                .output = "",
            };
        };

        // Ownership check before minting a code — match the HTTP
        // handler's posture (404 on a foreign or missing artifact, no
        // existence leak).
        var existing_opt = smgr.getArtifactById(allocator, uid, artifact_id) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "artifact_share: ownership lookup failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };
        if (existing_opt == null) {
            return ToolResult{
                .success = false,
                .error_msg = try std.fmt.allocPrint(allocator, "artifact not found (id={s})", .{artifact_id}),
                .output = "",
            };
        }
        var existing = existing_opt.?;
        existing.deinit(allocator);
        _ = &existing_opt;

        const now_unix = std.time.timestamp();
        const expires_at_unix = now_unix + hours * 3600;

        const share_code = artifacts_store.generateShareCode(allocator) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "artifact_share: share code generation failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };
        defer allocator.free(share_code);

        smgr.setArtifactShare(uid, artifact_id, share_code, expires_at_unix) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "artifact_share: persistence failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };

        const msg = try std.fmt.allocPrint(
            allocator,
            "{{\"share_code\":\"{s}\",\"share_url\":\"/api/v1/share/artifact/{s}\",\"expires_at_unix\":{d},\"expires_in_hours\":{d}}}",
            .{ share_code, share_code, expires_at_unix, hours },
        );
        return ToolResult{ .success = true, .output = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "artifact_share tool name" {
    var t = ArtifactShareTool{};
    try std.testing.expectEqualStrings("artifact_share", t.tool().name());
}

test "artifact_share schema requires artifact_id" {
    var t = ArtifactShareTool{};
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "artifact_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "expires_in_hours") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"artifact_id\"]") != null);
}

test "artifact_share rejects missing artifact_id" {
    var t = ArtifactShareTool{};
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "artifact_id") != null);
}

test "artifact_share rejects non-positive expires_in_hours" {
    var t = ArtifactShareTool{};
    const parsed = try root.parseTestArgs("{\"artifact_id\":\"abc\",\"expires_in_hours\":0}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "positive integer") != null);
}

test "artifact_share rejects expires_in_hours over the cap" {
    var t = ArtifactShareTool{};
    const oversized = artifacts_store.SHARE_MAX_EXPIRY_HOURS + 1;
    const arg_str = try std.fmt.allocPrint(std.testing.allocator, "{{\"artifact_id\":\"abc\",\"expires_in_hours\":{d}}}", .{oversized});
    defer std.testing.allocator.free(arg_str);
    const parsed = try root.parseTestArgs(arg_str);
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);

    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "exceeds maximum") != null);
}

test "artifact_share reports unavailable without state_mgr" {
    var t = ArtifactShareTool{};
    const parsed = try root.parseTestArgs("{\"artifact_id\":\"abc\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);

    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "state manager not bound") != null);
}

test "artifact_share metadata is mutating + medium risk" {
    try std.testing.expect(ArtifactShareTool.tool_metadata.flags.mutating);
    try std.testing.expect(!ArtifactShareTool.tool_metadata.flags.read_only);
    try std.testing.expectEqual(@import("metadata.zig").RiskLevel.medium, ArtifactShareTool.tool_metadata.risk_level);
}
