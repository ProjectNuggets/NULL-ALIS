//! Max-token resolution for generation limits.
//!
//! Delegates to model_capabilities.zig — the single source of truth for
//! per-model context window and max-output tokens.
//!
//! Follows the runtime fallback chain:
//!   1) explicit config override
//!   2) best-effort lookup by model/provider id (via model_capabilities table)
//!   3) default fallback

const std = @import("std");
const config_types = @import("../config_types.zig");
const model_caps = @import("model_capabilities.zig");

pub const DEFAULT_MODEL_MAX_TOKENS: u32 = config_types.DEFAULT_MODEL_MAX_TOKENS;

/// Look up max output tokens for a model reference. Returns null for unknown models.
pub fn lookupModelMaxTokens(model_ref_raw: []const u8) ?u32 {
    return if (model_caps.lookupCapabilities(model_ref_raw)) |c| c.max_output else null;
}

/// Resolve max output tokens: explicit override → table → DEFAULT_MODEL_MAX_TOKENS.
pub fn resolveMaxTokens(max_tokens_override: ?u32, model_ref: []const u8) u32 {
    return model_caps.resolveMaxTokens(max_tokens_override, model_ref);
}

test "resolveMaxTokens honors explicit override first" {
    const resolved = resolveMaxTokens(512, "openai/gpt-4.1-mini");
    try std.testing.expectEqual(@as(u32, 512), resolved);
}

test "lookupModelMaxTokens resolves model and nested provider refs" {
    try std.testing.expectEqual(@as(?u32, 8192), lookupModelMaxTokens("openai/gpt-4.1-mini"));
    try std.testing.expectEqual(@as(?u32, 8192), lookupModelMaxTokens("openrouter/anthropic/claude-sonnet-4.6"));
    try std.testing.expectEqual(@as(?u32, 32_768), lookupModelMaxTokens("qianfan/custom-model"));
}

test "lookupModelMaxTokens strips date suffixes and latest aliases" {
    try std.testing.expectEqual(@as(?u32, 8192), lookupModelMaxTokens("anthropic/claude-sonnet-4.6-20260219"));
    try std.testing.expectEqual(@as(?u32, 8192), lookupModelMaxTokens("openai/gpt-4.1-latest"));
}

test "lookupModelMaxTokens provider fallback handles lower ceilings" {
    try std.testing.expectEqual(@as(?u32, 4096), lookupModelMaxTokens("nvidia/custom-model"));
}

test "resolveMaxTokens falls back to global default" {
    const resolved = resolveMaxTokens(null, "unknown-provider/unknown-model");
    try std.testing.expectEqual(DEFAULT_MODEL_MAX_TOKENS, resolved);
}
