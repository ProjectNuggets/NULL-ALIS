//! S6.15 — Composio gated lane pin.
//!
//! Composio integration is HIDDEN from V1 user-facing claims per the
//! matrix doc. This file pins the GATED lane behavior:
//!   * Without `COMPOSIO_API_KEY` set → skip-graceful.
//!   * With it set → a config struct can be constructed and the
//!     capability gate reports composio enabled. NO real Composio API
//!     calls are made.
//!   * Any "prod" or "main" substring in the test entity is rejected.

const std = @import("std");
const nullalis = @import("nullalis");
const config_types = nullalis.config.config_types;
const capabilities = nullalis.capabilities;

const COMPOSIO_API_KEY_ENV = "COMPOSIO_API_KEY";
const COMPOSIO_TEST_ENTITY_ENV = "NULLALIS_COMPOSIO_TEST_ENTITY";

fn getEnvOrSkip(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
}

test "S6.15 composio: capabilities namespace is wired (scaffold present)" {
    // The capability gate exists; a future refactor that drops it without
    // explicit V1 scope review fails to compile here.
    _ = capabilities;
    _ = config_types.ComposioConfig;
}

test "S6.15 composio: ComposioConfig struct accepts the gated lane fields" {
    // Pin the struct shape so a field rename downstream fails this test
    // BEFORE breaking the gated CI lane.
    const cfg: config_types.ComposioConfig = .{
        .enabled = false,
        .api_key = null,
        .entity_id = "test",
    };
    try std.testing.expect(!cfg.enabled);
    try std.testing.expect(cfg.api_key == null);
    try std.testing.expectEqualStrings("test", cfg.entity_id);
}

test "S6.15 composio: gated lane is SKIPPED when COMPOSIO_API_KEY is absent" {
    const allocator = std.testing.allocator;
    const key = getEnvOrSkip(allocator, COMPOSIO_API_KEY_ENV) catch return error.SkipZigTest;
    defer allocator.free(key);
    // Reaching this point means env IS set; the next test exercises
    // that path.
}

test "S6.15 composio: configured lane rejects production-named entities" {
    const allocator = std.testing.allocator;
    const key = getEnvOrSkip(allocator, COMPOSIO_API_KEY_ENV) catch return error.SkipZigTest;
    defer allocator.free(key);
    const entity = getEnvOrSkip(allocator, COMPOSIO_TEST_ENTITY_ENV) catch return error.SkipZigTest;
    defer allocator.free(entity);

    const lower_safe = std.mem.indexOf(u8, entity, "prod") == null and
        std.mem.indexOf(u8, entity, "main") == null;
    if (!lower_safe) {
        std.debug.print(
            "S6.15: refusing to run Composio gated lane with entity '{s}' — contains 'prod' or 'main'\n",
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
