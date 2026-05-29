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

test "S6.4 mode: invalid-transition 4xx is declared INSIDE the /mode path block" {
    // Path-scoped: the 400/422 declaration must live in the /mode route's
    // own response section. A global substring would pass even if no 4xx
    // response was declared under /mode itself.
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    const block = harness.openApiPathBlock(yaml, "/mode:") orelse {
        std.debug.print("S6.4: /mode path block not found in OpenAPI\n", .{});
        return error.ModeBlockMissing;
    };
    const has_4xx = std.mem.indexOf(u8, block, "'400'") != null or
        std.mem.indexOf(u8, block, "\"400\"") != null or
        std.mem.indexOf(u8, block, " 400:") != null or
        std.mem.indexOf(u8, block, " 422:") != null or
        std.mem.indexOf(u8, block, "'422'") != null;
    if (!has_4xx) {
        std.debug.print("S6.4: /mode block does NOT declare a 4xx response — invalid-transition contract not documented\n", .{});
        return error.ModeNo4xxDeclared;
    }
}
