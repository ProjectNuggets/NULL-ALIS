//! S6.5 — approvals contract pin.

const std = @import("std");
const nullalis = @import("nullalis");
const gateway = nullalis.gateway;
const harness = @import("harness.zig");

test "S6.5 approvals: canonical session-scoped approve route exists in OpenAPI" {
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/approve:") != null);
}

test "S6.5 approvals: phantom /api/v1/chat/approve is NOT documented" {
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    try std.testing.expect(std.mem.indexOf(u8, yaml, "  /api/v1/chat/approve:") == null);
}

test "S6.5 approvals: stable approval_id format apr-{u64} roundtrips" {
    var buf: [64]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "apr-{d}", .{42});
    try std.testing.expectEqualStrings("apr-42", formatted);

    var buf2: [64]u8 = undefined;
    const formatted2 = try std.fmt.bufPrint(&buf2, "apr-{d}", .{43});
    try std.testing.expectEqualStrings("apr-43", formatted2);
    const n1 = try std.fmt.parseInt(u64, formatted[4..], 10);
    const n2 = try std.fmt.parseInt(u64, formatted2[4..], 10);
    try std.testing.expect(n2 > n1);
}

test "S6.5 approvals: 409 stale-card response shape is declared INSIDE the /approve path block" {
    // Path-scoped: the 409 must live in the /approve route's block, not
    // just anywhere in the OpenAPI doc (which would pass vacuously on
    // any 409 declared elsewhere).
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    const block = harness.openApiPathBlock(yaml, "/approve:") orelse {
        std.debug.print("S6.5: /approve path block not found in OpenAPI\n", .{});
        return error.ApproveBlockMissing;
    };
    const has_409 = std.mem.indexOf(u8, block, "'409'") != null or
        std.mem.indexOf(u8, block, "\"409\"") != null or
        std.mem.indexOf(u8, block, " 409:") != null;
    if (!has_409) {
        std.debug.print("S6.5: /approve block does NOT declare a 409 response — UI cannot bind stale-card surface\n", .{});
        return error.ApproveNo409;
    }
}

test "S6.5 approvals: extractIdempotencyKey honors approve-route idempotency" {
    const raw = "POST /api/v1/users/u1/sessions/s1/approve HTTP/1.1\r\nHost: x\r\nIdempotency-Key: approval-deadbeef\r\n\r\n";
    const key = gateway.extractIdempotencyKey(raw) orelse return error.MissingIdempotencyKey;
    try std.testing.expectEqualStrings("approval-deadbeef", key);
}

test "S6.5 approvals: full decision vocabulary (issued|auto_approved|user_approved|user_denied|blocked|expired) is documented in source" {
    const gateway_src = try harness.loadProjectFile("src/gateway.zig");
    const decision_vocabulary = [_][]const u8{
        "issued",
        "auto_approved",
        "user_approved",
        "user_denied",
        "blocked",
        "expired",
    };
    for (decision_vocabulary) |outcome| {
        if (std.mem.indexOf(u8, gateway_src, outcome) == null) {
            std.debug.print("S6.5: approval decision outcome '{s}' missing from src/gateway.zig\n", .{outcome});
            return error.ApprovalDecisionVocabularyDrift;
        }
    }
}

test "S6.5 approvals: irreversible-action surface is documented as requiring approval" {
    const contract = try harness.loadProjectFile("docs/online-agent-contract.md");
    try std.testing.expect(std.mem.indexOf(u8, contract, "supervised_mutating_requires_approval") != null);
}

test "S6.5 approvals: local artifact edit exception is documented without exempting public share" {
    const contract = try harness.loadProjectFile("docs/online-agent-contract.md");
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    try std.testing.expect(std.mem.indexOf(u8, contract, "artifact_create") != null);
    try std.testing.expect(std.mem.indexOf(u8, contract, "artifact_update") != null);
    try std.testing.expect(std.mem.indexOf(u8, contract, "artifact_share` remains approval-gated") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "artifact_create") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "artifact_share") != null);
}

test "S6.5 approvals: approval_id_mismatch error code is documented in OpenAPI" {
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    if (std.mem.indexOf(u8, yaml, "approval_id_mismatch") == null) {
        std.debug.print("S6.5: 'approval_id_mismatch' missing from docs/openapi-v1.yaml — UI cannot bind the 409 response\n", .{});
        return error.ApprovalIdMismatchNotDocumented;
    }
}
