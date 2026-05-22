//! Context-token resolution for agent compaction.
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

pub const DEFAULT_CONTEXT_TOKENS: u64 = config_types.DEFAULT_AGENT_TOKEN_LIMIT;

/// Look up context window size for a model reference. Returns null for unknown models.
pub fn lookupContextTokens(model_ref_raw: []const u8) ?u64 {
    return if (model_caps.lookupCapabilities(model_ref_raw)) |c| c.context_window else null;
}

/// Bench-only context-window cap.
///
/// When `NULLALIS_BENCH_CONTEXT_LIMIT` is set to a positive integer, it forces
/// the resolved context window to that value — overriding the explicit config
/// override, the model-capabilities table, and the default. This exists so a
/// benchmark harness (LoCoMo, D44) can shrink the effective window below the
/// size of a test conversation, making the transcript overflow → triggering
/// compaction → extraction → memory retrieval. Without it, a single LoCoMo
/// conversation (~30K tokens) fits entirely inside K2.6's 262K window and the
/// memory engine is never exercised.
///
/// Absent, unparseable, or zero → returns null → fully inert. Production is
/// unaffected: this var must never be set in a production environment.
fn benchContextLimit() ?u64 {
    const raw = std.posix.getenv("NULLALIS_BENCH_CONTEXT_LIMIT") orelse return null;
    const parsed = std.fmt.parseInt(u64, raw, 10) catch return null;
    return if (parsed > 0) parsed else null;
}

/// Resolve context window: bench cap → explicit override → table → DEFAULT_CONTEXT_TOKENS.
pub fn resolveContextTokens(token_limit_override: ?u64, model_ref: []const u8) u64 {
    if (benchContextLimit()) |cap| return cap;
    return model_caps.resolveContextTokens(token_limit_override, model_ref);
}

test "resolveContextTokens honors explicit override first" {
    const resolved = resolveContextTokens(42_000, "openai/gpt-4.1-mini");
    try std.testing.expectEqual(@as(u64, 42_000), resolved);
}

test "lookupContextTokens resolves known model ids" {
    try std.testing.expectEqual(@as(?u64, 128_000), lookupContextTokens("openai/gpt-4.1-mini"));
    try std.testing.expectEqual(@as(?u64, 200_000), lookupContextTokens("claude-sonnet-4.6"));
    try std.testing.expectEqual(@as(?u64, 32_768), lookupContextTokens("mixtral-8x7b-32768"));
    try std.testing.expectEqual(@as(?u64, 262_144), lookupContextTokens("moonshotai/Kimi-K2.5"));
}

test "lookupContextTokens handles nested provider refs" {
    try std.testing.expectEqual(
        @as(?u64, 200_000),
        lookupContextTokens("openrouter/anthropic/claude-sonnet-4.6"),
    );
    try std.testing.expectEqual(
        @as(?u64, 262_144),
        lookupContextTokens("openrouter/moonshotai/kimi-k2.5"),
    );
    try std.testing.expectEqual(
        @as(?u64, 262_144),
        lookupContextTokens("together-ai/moonshotai/kimi-k2.5"),
    );
}

test "lookupContextTokens strips date suffixes" {
    try std.testing.expectEqual(
        @as(?u64, 200_000),
        lookupContextTokens("anthropic/claude-sonnet-4.6-20260219"),
    );
}

test "lookupContextTokens falls back to provider defaults" {
    try std.testing.expectEqual(@as(?u64, 98_304), lookupContextTokens("qianfan/custom-model"));
    try std.testing.expectEqual(@as(?u64, 200_000), lookupContextTokens("openrouter/inception/mercury"));
}

test "resolveContextTokens falls back to global default" {
    const resolved = resolveContextTokens(null, "unknown-provider/unknown-model");
    try std.testing.expectEqual(DEFAULT_CONTEXT_TOKENS, resolved);
}

test "benchContextLimit is inert when env var is unset (production default)" {
    // The CI environment never sets NULLALIS_BENCH_CONTEXT_LIMIT, so the
    // bench cap must be null and resolution must fall through to the normal
    // override → table → default chain.
    try std.testing.expectEqual(@as(?u64, null), benchContextLimit());
    try std.testing.expectEqual(@as(u64, 42_000), resolveContextTokens(42_000, "openai/gpt-4.1-mini"));
}
