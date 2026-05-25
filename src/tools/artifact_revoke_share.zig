//! `artifact_revoke_share` — agent-side wrapper over
//! `DELETE /api/v1/users/:id/artifacts/:id/share`.
//!
//! Mirrors `handleArtifactShareRevoke` in gateway.zig: a single
//! `clearArtifactShare` call that sets `is_shared = FALSE` and nulls
//! the share_code + expiry on the row. The HTTP path returns
//! `{"status":"revoked"}` regardless of whether a share was active —
//! we surface the same idempotent shape so re-revoking is a no-op,
//! not an error.
//!
//! Cost class A — single Postgres UPDATE. Risk low: revocation
//! removes public access (can never widen). No approval needed even
//! in `.supervised` autonomy.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const zaki_state = @import("../zaki_state.zig");
const observability = @import("../observability.zig");

const log = std.log.scoped(.artifact_revoke_share);

pub const ArtifactRevokeShareTool = struct {
    state_mgr: ?*zaki_state.Manager = null,
    user_id: ?i64 = null,

    pub const tool_name = "artifact_revoke_share";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Revoke a previously-minted public share URL for an artifact (idempotent).",
        .use_when = &.{
            "User asks to 'unshare', 'revoke', or 'take down' a shared artifact",
            "A shared document leaked or contains an error and needs immediate de-publication",
            "Routine cleanup of long-lived shares the user no longer wants public",
        },
        .do_not_use_for = &.{
            "artifact_share — for creating a share rather than revoking one",
            "artifact_update — for editing the artifact's content rather than its share state",
            "memory_forget — for purging stored facts rather than share URLs",
        },
        .cost_note = "Single Postgres UPDATE; idempotent (re-revoking returns success).",
        .completion_hint = "Returns {\"status\":\"revoked\"} regardless of prior share state.",
        .see_also = &.{
            "artifact_share — mint a new share after revoking the old one",
            "artifact_get — read the artifact content; revocation only affects public access",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("artifact_revoke_share", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }

    pub const tool_description =
        "Revoke the public share URL for an artifact. The URL stops working immediately. " ++
        "Idempotent — calling on an already-revoked artifact returns success.";

    pub const tool_params =
        \\{"type":"object","properties":{"artifact_id":{"type":"string","description":"UUID of the artifact whose share should be revoked."}},"required":["artifact_id"]}
    ;

    pub const tool_metadata: @import("metadata.zig").ToolMetadata = .{
        .name = tool_name,
        .flags = .{ .mutating = true },
        .risk_level = .low,
        .cost_class = .a,
    };

    pub const vtable = root.ToolVTable(@This());

    pub fn tool(self: *ArtifactRevokeShareTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ArtifactRevokeShareTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const artifact_id = root.getString(args, "artifact_id") orelse return ToolResult.fail("Missing 'artifact_id' parameter");
        if (artifact_id.len == 0) return ToolResult.fail("'artifact_id' must not be empty");

        const smgr = self.state_mgr orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "artifact_revoke_share unavailable: state manager not bound (postgres not configured)"),
                .output = "",
            };
        };
        const uid = self.user_id orelse {
            return ToolResult{
                .success = false,
                .error_msg = try allocator.dupe(u8, "artifact_revoke_share unavailable: tenant user not bound"),
                .output = "",
            };
        };

        // The SQL `WHERE id = ... AND user_id = ...` clause handles
        // cross-user safety inside `clearArtifactShare`. A row that
        // doesn't exist for this user is a silent no-op (idempotent),
        // matching the HTTP handler's contract — we do NOT leak
        // existence by surfacing a "not found" error here.
        smgr.clearArtifactShare(uid, artifact_id) catch |err| {
            log.warn("artifact_revoke_share persistence failed user_id={d} artifact_id={s} err={s}", .{ uid, artifact_id, @errorName(err) });
            const msg = try std.fmt.allocPrint(allocator, "artifact_revoke_share: persistence failed: {s}", .{@errorName(err)});
            return ToolResult{ .success = false, .error_msg = msg, .output = "" };
        };

        // Counter on every successful revoke (which includes idempotent
        // no-op revokes since the SQL UPDATE itself succeeded). Counted
        // as a "revoke attempted" rather than a "share-existed-and-was-
        // revoked" — the latter would require a row-count read-back
        // which the current store API doesn't expose.
        observability.recordMetricGlobal(.{ .artifact_share_revoke_total = 1 });

        return ToolResult{
            .success = true,
            .output = try allocator.dupe(u8, "{\"status\":\"revoked\"}"),
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "artifact_revoke_share tool name" {
    var t = ArtifactRevokeShareTool{};
    try std.testing.expectEqualStrings("artifact_revoke_share", t.tool().name());
}

test "artifact_revoke_share schema requires artifact_id" {
    var t = ArtifactRevokeShareTool{};
    const schema = t.tool().parametersJson();
    try std.testing.expect(std.mem.indexOf(u8, schema, "artifact_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"artifact_id\"]") != null);
}

test "artifact_revoke_share rejects missing artifact_id" {
    var t = ArtifactRevokeShareTool{};
    const parsed = try root.parseTestArgs("{}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "artifact_id") != null);
}

test "artifact_revoke_share rejects empty artifact_id" {
    var t = ArtifactRevokeShareTool{};
    const parsed = try root.parseTestArgs("{\"artifact_id\":\"\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "must not be empty") != null);
}

test "artifact_revoke_share reports unavailable without state_mgr" {
    var t = ArtifactRevokeShareTool{};
    const parsed = try root.parseTestArgs("{\"artifact_id\":\"abc\"}");
    defer parsed.deinit();
    const result = try t.tool().execute(std.testing.allocator, parsed.value.object);
    defer if (result.output.len > 0) std.testing.allocator.free(result.output);

    defer if (result.error_msg) |em| std.testing.allocator.free(em);
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.error_msg.?, "state manager not bound") != null);
}

test "artifact_revoke_share metadata is mutating + low risk + cost A" {
    try std.testing.expect(ArtifactRevokeShareTool.tool_metadata.flags.mutating);
    try std.testing.expectEqual(@import("metadata.zig").RiskLevel.low, ArtifactRevokeShareTool.tool_metadata.risk_level);
    try std.testing.expectEqual(@import("metadata.zig").CostClass.a, ArtifactRevokeShareTool.tool_metadata.cost_class);
}
