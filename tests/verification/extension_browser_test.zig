//! S6.9 — extension browser surface pin.

const std = @import("std");
const nullalis = @import("nullalis");
const url_sanitize = nullalis.extension_ws.url_sanitize;
const harness = @import("harness.zig");

test "S6.9 extension: WS endpoint is documented in OpenAPI" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/api/v1/extension/ws") != null);
}

test "S6.9 extension: per-user token auth is the documented contract" {
    const allocator = std.testing.allocator;
    const contract = try harness.loadProjectFile(allocator, "docs/extension-ws-contract.md");
    defer allocator.free(contract);
    try std.testing.expect(std.mem.indexOf(u8, contract, "token") != null);
}

test "S6.9 extension: diagnostics routes are documented" {
    const allocator = std.testing.allocator;
    const yaml = try harness.loadProjectFile(allocator, "docs/openapi-v1.yaml");
    defer allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/diagnostics/extension") != null);
}

test "S6.9 extension: every shipped extension_* tool name is mentioned in the WS contract" {
    const allocator = std.testing.allocator;
    const contract = try harness.loadProjectFile(allocator, "docs/extension-ws-contract.md");
    defer allocator.free(contract);

    // The 10 shipped extension_* tools — one file per name in
    // src/tools/extension_*.zig. Pair / status are gateway routes,
    // not tools, so they're not in this list. A rename of any of
    // these to a different name fails the test.
    const tool_names = [_][]const u8{
        "extension_navigate",
        "extension_click",
        "extension_type",
        "extension_screenshot",
        "extension_get_dom",
        "extension_get_text",
        "extension_list_tabs",
        "extension_fill_form",
        "extension_scroll",
        "extension_wait_for",
    };
    for (tool_names) |name| {
        if (std.mem.indexOf(u8, contract, name) == null) {
            std.debug.print("S6.9: extension tool '{s}' missing from extension-ws-contract.md\n", .{name});
            return error.ExtensionToolNotDocumented;
        }
    }
}

test "S6.9 extension: url_sanitize rejects loopback addresses (SSRF defense)" {
    // The S4 SSRF surface. The real API is `sanitize(url, allowlist) SanitizeResult`
    // returning `.ok` or `.reject = .{ .reason, .detail }`.
    const empty_allowlist: []const []const u8 = &.{};
    const cases = [_]struct {
        url: []const u8,
        expect_reason: url_sanitize.RejectionReason,
    }{
        .{ .url = "http://127.0.0.1/admin", .expect_reason = .loopback_blocked },
        .{ .url = "http://localhost:8080/internal", .expect_reason = .loopback_blocked },
        .{ .url = "http://[::1]/admin", .expect_reason = .loopback_blocked },
    };
    for (cases) |c| {
        const result = url_sanitize.sanitize(c.url, empty_allowlist);
        switch (result) {
            .ok => {
                std.debug.print("S6.9: SSRF gate let through '{s}'\n", .{c.url});
                return error.SsrfGateRegressed;
            },
            .reject => |r| {
                if (r.reason != c.expect_reason) {
                    std.debug.print("S6.9: '{s}' rejected with {s}, expected {s}\n", .{
                        c.url,
                        r.reason.toString(),
                        c.expect_reason.toString(),
                    });
                    return error.WrongRejectionReason;
                }
            },
        }
    }
}

test "S6.9 extension: url_sanitize accepts a benign public URL" {
    // Negative-of-negative: a benign URL must NOT be rejected by the SSRF
    // gate. Catches over-aggressive deny patterns.
    const empty_allowlist: []const []const u8 = &.{};
    const result = url_sanitize.sanitize("https://example.com/path?q=1", empty_allowlist);
    switch (result) {
        .ok => {},
        .reject => |r| {
            std.debug.print("S6.9: SSRF gate rejected benign URL with {s}: {s}\n", .{ r.reason.toString(), r.detail });
            return error.SsrfGateOverbroad;
        },
    }
}

test "S6.9 extension: url_sanitize rejects non-http(s) schemes" {
    const empty_allowlist: []const []const u8 = &.{};
    const result = url_sanitize.sanitize("javascript:alert(1)", empty_allowlist);
    switch (result) {
        .ok => return error.SsrfGateMissedJavaScriptScheme,
        .reject => |r| try std.testing.expect(r.reason == .scheme_blocked),
    }
}
