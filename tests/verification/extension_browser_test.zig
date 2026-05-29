//! S6.9 — extension browser surface pin.

const std = @import("std");
const nullalis = @import("nullalis");
const url_sanitize = nullalis.extension_ws.url_sanitize;
const lint = nullalis.tools.lint;
const harness = @import("harness.zig");

test "S6.9 extension: WS endpoint is documented in OpenAPI" {
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/api/v1/extension/ws") != null);
}

test "S6.9 extension: per-user token auth is the documented contract" {
    const contract = try harness.loadProjectFile("docs/extension-ws-contract.md");
    try std.testing.expect(std.mem.indexOf(u8, contract, "token") != null);
}

test "S6.9 extension: diagnostics routes are documented" {
    const yaml = try harness.loadProjectFile("docs/openapi-v1.yaml");
    try std.testing.expect(std.mem.indexOf(u8, yaml, "/diagnostics/extension") != null);
}

test "S6.9 extension: every shipped extension_* tool in the lint registry is mentioned in the WS contract" {
    // Two-sided pin: the canonical tool list lives in `src/tools/lint.zig`
    // `ALL_TOOLS` (comptime-tested for alphabetical ordering). We iterate
    // it here so adding a new `extension_*` tool only requires updating the
    // lint registry — this test picks up the new name automatically.
    // The contract doc must mention every such name.
    const contract = try harness.loadProjectFile("docs/extension-ws-contract.md");

    var checked: usize = 0;
    for (lint.ALL_TOOLS) |name| {
        if (!std.mem.startsWith(u8, name, "extension_")) continue;
        checked += 1;
        if (std.mem.indexOf(u8, contract, name) == null) {
            std.debug.print("S6.9: extension tool '{s}' (from lint.ALL_TOOLS) missing from extension-ws-contract.md\n", .{name});
            return error.ExtensionToolNotDocumented;
        }
    }
    // Floor pin — there must be SOME extension tools in the lint registry,
    // otherwise the filter loop was vacuously true.
    if (checked == 0) {
        std.debug.print("S6.9: no extension_* tools in lint.ALL_TOOLS — likely registry regression\n", .{});
        return error.ExtensionToolsRegistryEmpty;
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
