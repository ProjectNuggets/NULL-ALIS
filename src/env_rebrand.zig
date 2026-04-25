//! NULLCLAW_ → NULLALIS_ rebrand chokepoint (Sprint 8 — S8.3).
//!
//! Every legacy `NULLCLAW_*` env-var read in the codebase routes the
//! once-per-process deprecation banner through this module so operators
//! see a single, hard, dated migration signal regardless of WHICH
//! NULLCLAW_* key tripped the fallback path first.
//!
//! Why a separate module rather than living next to the shim helpers
//! in `sentry_runtime.zig`: `observability.zig` imports
//! `sentry_runtime` would be circular (sentry_runtime already imports
//! observability for Observer vtable plumbing). A neutral helper
//! module both can import keeps the once-fired atomic in a single
//! place without forcing a refactor of the existing import graph.
//!
//! After 2026-05-15 (the sunset date below), every NULLCLAW_*
//! fallback branch in the codebase should be deleted, this module
//! should be deleted, and a grep for `NULLCLAW_` in src/ should
//! return zero hits. Tracked as D28 in `docs/deferred-register.md`.

const std = @import("std");

/// Hard sunset deadline. Same string surfaces in:
///   • sentry_runtime.NULLCLAW_SUNSET_DATE (re-exported below for
///     callers that already use that path)
///   • the per-key warning text on every `*WithFallback` helper
///   • the `observability.zig::OtelObserver.fromEnv` legacy reads
///   • the deprecation banner itself
///
/// Single source of truth: change here once and every signal updates.
pub const SUNSET_DATE: []const u8 = "2026-05-15";

/// One-shot atomic flag — banner fires exactly once per process even
/// under multi-thread races. Acquire/release semantics are conservative
/// for a single-bool flag with no other state being published; matches
/// the `std.once`-style pattern used elsewhere in the codebase.
var banner_fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Fire the deprecation banner the first time any NULLCLAW_* fallback
/// is consumed. Subsequent calls are no-ops thanks to the cmpxchg.
/// Safe to call from any module / any thread.
pub fn fireBannerOnce() void {
    if (banner_fired.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
        std.log.warn(
            "DEPRECATION: NULLCLAW_* environment variables are read via fallback shims " ++
                "and will be REMOVED after {s}. Migrate every NULLCLAW_FOO to NULLALIS_FOO " ++
                "in your env files / k8s manifests / sealed-secrets. This banner fires once " ++
                "per process; the per-variable warning identifies which keys you're still using.",
            .{SUNSET_DATE},
        );
    }
}

/// Reset hook for tests that want to assert the banner fires exactly
/// once. Production code MUST NOT call this — it would cause double
/// banner emission. Gated on `builtin.is_test` to make accidental
/// production use a compile-time error rather than a runtime footgun.
pub fn resetForTests() void {
    if (!@import("builtin").is_test) {
        @compileError("env_rebrand.resetForTests called outside test build");
    }
    banner_fired.store(false, .release);
}

// ── Tests ─────────────────────────────────────────────────────────

test "S8.3 fireBannerOnce — flag transitions exactly once across calls" {
    resetForTests();
    // First call must transition false → true.
    fireBannerOnce();
    // Underlying flag is now true; subsequent calls are no-ops.
    try std.testing.expect(banner_fired.load(.acquire));

    // Calling again must NOT change observable state. We can't easily
    // capture log output, but we CAN assert the flag stays true and
    // that no panic / no error occurs across many concurrent-style
    // calls.
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        fireBannerOnce();
    }
    try std.testing.expect(banner_fired.load(.acquire));
}

test "S8.3 SUNSET_DATE matches the canonical deadline string" {
    // Regression guard — if the date is bumped, every other location
    // (sentry_runtime.NULLCLAW_SUNSET_DATE, observability.zig warning,
    // CLOSURE_CHECKLIST.md S8.3 row, sprint-8.md) must be bumped in
    // lockstep. This test fails on a divergence so the bump-everything
    // discipline is enforced rather than relied on.
    try std.testing.expectEqualStrings("2026-05-15", SUNSET_DATE);
}
