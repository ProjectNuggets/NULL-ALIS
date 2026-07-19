//! Approval policy — structured approval posture per tool + autonomy level.
//!
//! Replaces ad-hoc approval checks with a declarative policy that resolves
//! from tool metadata and the session's autonomy level. The ApprovalDecision
//! struct captures the full provenance of each approval outcome.

const std = @import("std");
const metadata = @import("../tools/metadata.zig");
const policy = @import("policy.zig");

pub const ApprovalPolicy = enum {
    auto_approve,
    confirm_once,
    confirm_always,
    deny,

    pub fn toSlice(self: ApprovalPolicy) []const u8 {
        return switch (self) {
            .auto_approve => "auto_approve",
            .confirm_once => "confirm_once",
            .confirm_always => "confirm_always",
            .deny => "deny",
        };
    }

    /// Resolve the approval policy for a tool based on its metadata and the
    /// current autonomy level.
    ///
    /// - full autonomy: always auto-approve
    /// - read_only autonomy: always deny
    /// - supervised: auto-approve read_only tools and explicitly whitelisted
    ///   local artifact writes, deny operator_only, confirm_once for all other
    ///   tools
    pub fn forTool(meta: metadata.ToolMetadata, autonomy: policy.AutonomyLevel) ApprovalPolicy {
        return switch (autonomy) {
            .full => .auto_approve,
            .read_only => .deny,
            .supervised => {
                if (meta.flags.operator_only) return .deny;
                if (meta.flags.read_only) return .auto_approve;
                if (meta.flags.supervised_auto_approve) return .auto_approve;
                if (meta.flags.mutating) return .confirm_once;
                return .confirm_once;
            },
        };
    }
};

// ── Provenance ──────────────────────────────────────────────────────
//
// The enum below is intended to attach provenance to an ApprovalDecision
// so observability can distinguish "auto-approved by policy" from "user
// explicitly OK'd" from (future) "user OK'd for the whole run — skip
// re-prompt." The prior shipped version carried a `session_cache` variant
// for that last case, but no code ever populated or consulted it: there
// was no /approve verb to set it and preflightToolPolicy never looked it
// up. P4_tools + P2_subagent_delegate + P3_relations all independently
// flagged the declaration as inert (S1.9).
//
// For Swiss-watch discipline the right move is to delete the pretend-
// feature and re-add it with full wiring when we build run-scoped
// approvals. A future implementation needs:
//   1. New verb: `/approve <id> allow-run` (commands.zig)
//   2. Session/run-scoped cache keyed by (tool_name, canonical arg hash)
//      with an explicit lifetime (clear on run end, on `/new`, on policy
//      change, on Agent.deinit)
//   3. preflightToolPolicy consults the cache before setPendingToolApproval
//   4. A new DecisionSource variant emitted on cache-hit approval
//   5. End-to-end test asserting the same tool+args second call bypasses
//      the approval gate only when the prior call used allow-run.
// See CLOSURE_CHECKLIST.md Sprint 4+ or Wave M for revival.
pub const DecisionSource = enum {
    auto_policy,
    user_approve,
    user_deny,

    pub fn toSlice(self: DecisionSource) []const u8 {
        return switch (self) {
            .auto_policy => "auto_policy",
            .user_approve => "user_approve",
            .user_deny => "user_deny",
        };
    }
};

pub const ApprovalDecision = struct {
    approval_policy: ApprovalPolicy,
    tool_name: []const u8,
    reason: []const u8,
    decided_at: i64,
    decided_by: DecisionSource,
};

// ── Tests ───────────────────────────────────────────────────────────

test "full autonomy always auto-approves" {
    const read_meta = metadata.ToolMetadata{ .name = "read", .flags = .{ .read_only = true } };
    const mutating_meta = metadata.ToolMetadata{ .name = "write", .flags = .{ .mutating = true } };
    try std.testing.expectEqual(ApprovalPolicy.auto_approve, ApprovalPolicy.forTool(read_meta, .full));
    try std.testing.expectEqual(ApprovalPolicy.auto_approve, ApprovalPolicy.forTool(mutating_meta, .full));
}

test "read_only autonomy always denies" {
    const read_meta = metadata.ToolMetadata{ .name = "read", .flags = .{ .read_only = true } };
    const mutating_meta = metadata.ToolMetadata{ .name = "write", .flags = .{ .mutating = true } };
    try std.testing.expectEqual(ApprovalPolicy.deny, ApprovalPolicy.forTool(read_meta, .read_only));
    try std.testing.expectEqual(ApprovalPolicy.deny, ApprovalPolicy.forTool(mutating_meta, .read_only));
}

test "supervised auto-approves read_only tools" {
    const meta = metadata.ToolMetadata{ .name = "file_read", .flags = .{ .read_only = true } };
    try std.testing.expectEqual(ApprovalPolicy.auto_approve, ApprovalPolicy.forTool(meta, .supervised));
}

test "supervised confirms mutating tools" {
    const meta = metadata.ToolMetadata{ .name = "shell", .flags = .{ .mutating = true } };
    try std.testing.expectEqual(ApprovalPolicy.confirm_once, ApprovalPolicy.forTool(meta, .supervised));
}

test "WP-SEC1: supervised confirms tools without a capability classification" {
    const meta = metadata.ToolMetadata{ .name = "unclassified" };
    try std.testing.expectEqual(ApprovalPolicy.confirm_once, ApprovalPolicy.forTool(meta, .supervised));
}

test "supervised auto-approves explicit local artifact writes" {
    const meta = metadata.ToolMetadata{
        .name = "artifact_create",
        .flags = .{ .mutating = true, .supervised_auto_approve = true },
        .risk_level = .low,
        .cost_class = .a,
    };
    try std.testing.expectEqual(ApprovalPolicy.auto_approve, ApprovalPolicy.forTool(meta, .supervised));
}

test "supervised denies operator_only tools" {
    const meta = metadata.ToolMetadata{ .name = "admin", .flags = .{ .operator_only = true } };
    try std.testing.expectEqual(ApprovalPolicy.deny, ApprovalPolicy.forTool(meta, .supervised));
}

test "ApprovalDecision captures source" {
    const decision = ApprovalDecision{
        .approval_policy = .auto_approve,
        .tool_name = "file_read",
        .reason = "read-only tool in supervised mode",
        .decided_at = 1234567890,
        .decided_by = .user_approve,
    };
    try std.testing.expectEqual(DecisionSource.user_approve, decision.decided_by);
    try std.testing.expectEqualStrings("file_read", decision.tool_name);
}

test "ApprovalPolicy toSlice returns correct strings" {
    try std.testing.expectEqualStrings("auto_approve", ApprovalPolicy.auto_approve.toSlice());
    try std.testing.expectEqualStrings("confirm_once", ApprovalPolicy.confirm_once.toSlice());
    try std.testing.expectEqualStrings("deny", ApprovalPolicy.deny.toSlice());
}

test "DecisionSource toSlice returns correct strings" {
    try std.testing.expectEqualStrings("auto_policy", DecisionSource.auto_policy.toSlice());
    try std.testing.expectEqualStrings("user_approve", DecisionSource.user_approve.toSlice());
    try std.testing.expectEqualStrings("user_deny", DecisionSource.user_deny.toSlice());
}
