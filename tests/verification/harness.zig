//! S6 verification matrix shared helpers.
//!
//! Smokes call the established in-process fixture patterns proven elsewhere
//! in the suite:
//!   * postgres URL resolver via env_rebrand (canonical + legacy fallback)
//!   * unique per-test schema name (microsecond timestamp + slug)
//!   * skip-graceful semantics when the live PG fixture is absent
//!
//! Heavier per-surface fixtures (zaki_state.Manager init, gateway fixtures)
//! live in the per-surface test files because their config shape varies.

const std = @import("std");
const nullalis = @import("nullalis");
const build_options = @import("build_options");
const env_rebrand = nullalis.env_rebrand;

pub const PG_URL_CANONICAL = "NULLALIS_POSTGRES_TEST_URL";
pub const PG_URL_LEGACY = "NULLCLAW_POSTGRES_TEST_URL";

/// Resolve the postgres test URL. Returns SkipZigTest if either:
///   * the build was compiled without `-Dengines=...,postgres`, or
///   * neither env var is set.
/// Caller owns the returned slice.
pub fn requirePostgresUrl(allocator: std.mem.Allocator) ![]u8 {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    const maybe_url = env_rebrand.getEnvOwnedWithRebrand(
        allocator,
        PG_URL_CANONICAL,
        PG_URL_LEGACY,
    ) catch return error.SkipZigTest;
    return maybe_url orelse error.SkipZigTest;
}

/// Build a unique schema name keyed on microsecond timestamp + a short slug.
/// `buf` must be ≥ 96 bytes. The name is lowercase ASCII safe for raw SQL.
pub fn schemaName(buf: []u8, slug: []const u8) ![]const u8 {
    const stamp = std.time.microTimestamp();
    return try std.fmt.bufPrint(buf, "nullalis_s6_{s}_{d}", .{ slug, stamp });
}

test "harness: requirePostgresUrl returns SkipZigTest when env is absent" {
    if (!build_options.enable_postgres) return error.SkipZigTest;
    // Save & clear both env vars for this test.
    const allocator = std.testing.allocator;
    const had_primary = std.process.getEnvVarOwned(allocator, PG_URL_CANONICAL) catch null;
    defer if (had_primary) |v| allocator.free(v);
    const had_legacy = std.process.getEnvVarOwned(allocator, PG_URL_LEGACY) catch null;
    defer if (had_legacy) |v| allocator.free(v);
    // Only assert the absence path when both are genuinely unset in the
    // current environment — we don't mutate process env here.
    if (had_primary != null or had_legacy != null) return error.SkipZigTest;

    const result = requirePostgresUrl(allocator);
    try std.testing.expectError(error.SkipZigTest, result);
}

test "harness: schemaName builds a unique lowercase identifier" {
    var buf: [96]u8 = undefined;
    const name = try schemaName(&buf, "demo");
    try std.testing.expect(std.mem.startsWith(u8, name, "nullalis_s6_demo_"));
    try std.testing.expect(name.len > "nullalis_s6_demo_".len);
}
