//! S6.4 — chat mode switching contract pin.

const std = @import("std");
const harness = @import("harness.zig");

test "S6.4 mode: canonical session-scoped mode route exists in OpenAPI" {
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/mode:") != null);
}

test "S6.4 mode: ui-handoff doc mentions the mode surface" {
    const ui_handoff = try harness.loadProjectFile("docs/ui-handoff.md");
    try std.testing.expect(std.mem.indexOf(u8, ui_handoff, "mode") != null);
}

test "S6.4 mode: invalid-transition failure surface is documented" {
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    const has_mode = std.mem.indexOf(u8, yaml, "/mode:") != null;
    const has_4xx = std.mem.indexOf(u8, yaml, "'400'") != null or
        std.mem.indexOf(u8, yaml, "\"400\"") != null or
        std.mem.indexOf(u8, yaml, " 400:") != null or
        std.mem.indexOf(u8, yaml, " 422:") != null;
    try std.testing.expect(has_mode and has_4xx);
}
