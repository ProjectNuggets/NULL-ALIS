//! S6.15 — Composio gated lane pin.
//!
//! Composio integration is HIDDEN from V1 user-facing claims per the
//! matrix doc. This file pins the GATED lane behavior:
//!   * Without `COMPOSIO_API_KEY` set → skip-graceful (the documented CI
//!     default).
//!   * With it set → the production-name guard rejects any test entity
//!     whose ASCII-lowercased name CONTAINS the substring `prod` or
//!     `main`. The guard is case-insensitive (closes the original bug
//!     where `"PROD"` and `"Production"` passed a case-sensitive
//!     substring check) and intentionally over-conservative: a false
//!     positive (`reprod-12`) is fixable by renaming the test fixture;
//!     a false negative (accidentally hitting prod) is not.

const std = @import("std");
const nullalis = @import("nullalis");
const config_types = nullalis.config.config_types;

const COMPOSIO_API_KEY_ENV = "COMPOSIO_API_KEY";
const COMPOSIO_TEST_ENTITY_ENV = "NULLALIS_COMPOSIO_TEST_ENTITY";

fn getEnvOrSkip(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
}

/// True iff `haystack` contains `needle` after ASCII-lowercasing both.
/// Used by the production-safety guard below. Caller-provided `lower_buf`
/// must be ≥ haystack.len bytes so we can avoid heap allocation in the
/// guard path.
fn containsCaseInsensitive(haystack: []const u8, needle: []const u8, lower_buf: []u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    std.debug.assert(lower_buf.len >= haystack.len);
    const lower = std.ascii.lowerString(lower_buf[0..haystack.len], haystack);
    return std.mem.indexOf(u8, lower, needle) != null;
}

/// The shipping production-safety check. Returns true if `entity` looks
/// production-ish under case-insensitive substring match.
fn looksProductionish(entity: []const u8) bool {
    if (entity.len > 256) return true; // suspiciously long → reject conservatively
    var buf: [256]u8 = undefined;
    return containsCaseInsensitive(entity, "prod", &buf) or
        containsCaseInsensitive(entity, "main", &buf);
}

// ── Pin the production-name guard's case-insensitivity ───────────────
// The original case-sensitive substring guard had a bug: `"PROD"` and
// `"Production"` passed. These tests pin the fix.

test "S6.15 composio guard: case-insensitive match on 'prod' variants" {
    try std.testing.expect(looksProductionish("prod"));
    try std.testing.expect(looksProductionish("PROD"));
    try std.testing.expect(looksProductionish("Production"));
    try std.testing.expect(looksProductionish("prod-fixture"));
    try std.testing.expect(looksProductionish("acme-prod-001"));
}

test "S6.15 composio guard: case-insensitive match on 'main' variants" {
    try std.testing.expect(looksProductionish("main"));
    try std.testing.expect(looksProductionish("MAIN"));
    try std.testing.expect(looksProductionish("Main-canary"));
    try std.testing.expect(looksProductionish("the-main-branch"));
}

test "S6.15 composio guard: accepts genuinely safe fixture names" {
    try std.testing.expect(!looksProductionish("qa-sandbox"));
    try std.testing.expect(!looksProductionish("e2e-staging"));
    try std.testing.expect(!looksProductionish("dev"));
    try std.testing.expect(!looksProductionish("test-fixture"));
}

test "S6.15 composio guard: overly-long entity name is conservatively rejected" {
    // A 257-byte all-safe-looking name still rejects to prevent buffer
    // overrun or operator confusion. Pin the >256-byte cliff.
    const long = [_]u8{'a'} ** 257;
    try std.testing.expect(looksProductionish(&long));
}

// ── Env-gated lane ────────────────────────────────────────────────────

test "S6.15 composio: configured lane rejects production-named entities" {
    const allocator = std.testing.allocator;
    const key = getEnvOrSkip(allocator, COMPOSIO_API_KEY_ENV) catch return error.SkipZigTest;
    defer allocator.free(key);
    const entity = getEnvOrSkip(allocator, COMPOSIO_TEST_ENTITY_ENV) catch return error.SkipZigTest;
    defer allocator.free(entity);

    if (looksProductionish(entity)) {
        std.debug.print(
            "S6.15: refusing to run Composio gated lane with entity '{s}' — case-insensitive substring match on 'prod' or 'main'\n",
            .{entity},
        );
        return error.UnsafeComposioTestEntity;
    }

    const cfg: config_types.ComposioConfig = .{
        .enabled = true,
        .api_key = key,
        .entity_id = entity,
    };
    try std.testing.expect(cfg.enabled);
    try std.testing.expect(cfg.api_key != null);
    try std.testing.expect(cfg.entity_id.len > 0);
}
