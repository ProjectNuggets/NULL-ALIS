//! S6.2 — chat stream contract pin.
//!
//! V1 chat surface is HTTP+SSE. This file pins the contract against
//! the two existing sources of truth: `docs/openapi-v1.yaml` and
//! `docs/online-agent-contract.md`.

const std = @import("std");
const harness = @import("harness.zig");

test "S6.2 chat: V1 hides /api/v1/chat/cancel as a top-level route" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "  /api/v1/chat/cancel:") == null);
}

test "S6.2 chat: V1 hides /api/v1/chat/resume as a top-level route" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "  /api/v1/chat/resume:") == null);
}

test "S6.2 chat: V1 hides /api/v1/chat/approve as a top-level route" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "  /api/v1/chat/approve:") == null);
}

test "S6.2 chat: canonical session-scoped routes are declared in OpenAPI" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/sessions/") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/cancel:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/approve:") != null);
}

test "S6.2 chat: stream entrypoint is documented" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/api/v1/chat/stream") != null);
}

test "S6.2 chat: SSE event-name surface is documented" {
    const allocator = std.testing.allocator;
    const contract = try harness.loadProjectFile(allocator, "docs/online-agent-contract.md");
    defer allocator.free(contract);

    // The shipping SSE event vocabulary in the online-agent contract:
    // chunk (delta payload), done (turn boundary), message (full text),
    // turn (turn lifecycle). A rename here that drops any of these
    // breaks the UI binding silently.
    const expected_event_fragments = [_][]const u8{
        "chunk",
        "done",
        "message",
        "turn",
    };
    for (expected_event_fragments) |evt| {
        if (std.mem.indexOf(u8, contract, evt) == null) {
            std.debug.print("S6.2: SSE event name '{s}' missing from online-agent-contract.md\n", .{evt});
            return error.SseEventNameNotDocumented;
        }
    }
}
