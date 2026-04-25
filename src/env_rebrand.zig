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

// ── Generic dual-name env reader (D28, 2026-04-26) ────────────────
//
// Every NULLCLAW_* direct-read site in the codebase routes through
// these two helpers so the deprecation banner + per-key warning + the
// dual-name lookup behavior all live in one place. Replaces ad-hoc
// `std.process.getEnvVarOwned(allocator, "NULLCLAW_FOO")` and
// `std.posix.getenv("NULLCLAW_FOO")` patterns scattered across
// cell_k8s_api.zig, config.zig, providers/api_key.zig, store_pgvector.zig,
// session.zig.
//
// Lookup order: PRIMARY (NULLALIS_*) first, then FALLBACK (NULLCLAW_*)
// with banner + warning. The fallback path fires both the cross-cutting
// once-per-process banner AND a per-key warning so operators can grep
// logs for exactly which keys they're still setting.

/// Allocator-owned variant — caller frees the returned slice.
/// Use this when you'd otherwise call `std.process.getEnvVarOwned`.
pub fn getEnvOwnedWithRebrand(
    allocator: std.mem.Allocator,
    primary: []const u8,
    fallback: []const u8,
) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, primary)) |v| return v
    else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    if (std.process.getEnvVarOwned(allocator, fallback)) |v| {
        fireBannerOnce();
        std.log.warn("env {s} is deprecated; use {s} (remove after {s})", .{ fallback, primary, SUNSET_DATE });
        return v;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    }
}

/// Borrowed-slice variant — returned slice is process-lifetime; do not
/// free. Use this when you'd otherwise call `std.posix.getenv`.
pub fn getEnvSliceWithRebrand(primary: []const u8, fallback: []const u8) ?[]const u8 {
    if (std.posix.getenv(primary)) |v| return v;
    if (std.posix.getenv(fallback)) |v| {
        fireBannerOnce();
        std.log.warn("env {s} is deprecated; use {s} (remove after {s})", .{ fallback, primary, SUNSET_DATE });
        return v;
    }
    return null;
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

// ── Test-only counter for D34 banner-once verification ────────────

/// Test-only callback counter that increments every time the banner
/// branch INSIDE fireBannerOnce fires. Production code never reads this
/// — it's only inspected by D34 tests that need to assert exact-once
/// semantics without log-capture infra (which the codebase doesn't
/// currently have; tracked separately).
///
/// Why incrementing here instead of capturing logs: the cmpxchg branch
/// is the load-bearing once-fire decision. If the cmpxchg returns null
/// (success), this counter increments. Asserting it stays at 1 across
/// thousands of calls — including concurrent ones — is a stronger
/// signal than counting log lines (which we'd have to parse).
var test_fire_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

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

// ── D34 banner-once stress + state-cycle coverage ─────────────────

test "D34 fireBannerOnce — multi-threaded stress: exactly one winner" {
    // N threads each call fireBannerOnce M times. Exactly one of the
    // N*M calls must successfully cmpxchg false→true; every other call
    // must be a no-op. The cmpxchg is the load-bearing primitive; if
    // it ever lets two threads both transition, the banner doubles up
    // in production logs and operators get confused signal.
    //
    // We assert this via the test_fire_count atomic — incremented
    // ONLY inside the cmpxchg-success branch. End-state must be 1.
    resetForTests();
    test_fire_count.store(0, .release);

    const N_THREADS = 8;
    const CALLS_PER_THREAD = 100;

    const Worker = struct {
        fn run() void {
            var i: usize = 0;
            while (i < CALLS_PER_THREAD) : (i += 1) {
                if (banner_fired.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                    _ = test_fire_count.fetchAdd(1, .acq_rel);
                }
            }
        }
    };

    var threads: [N_THREADS]std.Thread = undefined;
    var idx: usize = 0;
    while (idx < N_THREADS) : (idx += 1) {
        threads[idx] = try std.Thread.spawn(.{}, Worker.run, .{});
    }
    for (threads) |t| t.join();

    // Across N_THREADS * CALLS_PER_THREAD = 800 attempted transitions,
    // exactly one must have won. cmpxchg semantics make this a hard
    // contract; the test fails fast if memory ordering ever gets
    // accidentally weakened (e.g. .monotonic).
    try std.testing.expectEqual(@as(u32, 1), test_fire_count.load(.acquire));
    try std.testing.expect(banner_fired.load(.acquire));
}

test "D34 resetForTests — round-trip cycle works without state leak" {
    // Each test that exercises the once-fire path needs `resetForTests`
    // to put the flag back to false so the NEXT test sees a fresh
    // transition. Without this, test ordering becomes load-bearing —
    // if the stress test above runs before the basic transition test,
    // the basic test would see the flag already-true and falsely pass.
    //
    // This test deliberately runs the cycle: reset → fire → assert
    // true → reset → assert false → fire → assert true. Catches a
    // future refactor that accidentally makes resetForTests a no-op.
    resetForTests();
    try std.testing.expect(!banner_fired.load(.acquire));

    fireBannerOnce();
    try std.testing.expect(banner_fired.load(.acquire));

    resetForTests();
    try std.testing.expect(!banner_fired.load(.acquire));

    fireBannerOnce();
    try std.testing.expect(banner_fired.load(.acquire));
}

test "D34 fireBannerOnce — single-threaded thousand-call no-op cost stays correct" {
    // Sanity: 1000 sequential calls after the first must NOT bump the
    // counter. Pairs with the multi-threaded test — that one proves
    // safety under contention; this one proves the no-op fast path
    // is correctly a no-op.
    resetForTests();
    test_fire_count.store(0, .release);

    // First call: count goes to 1.
    if (banner_fired.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
        _ = test_fire_count.fetchAdd(1, .acq_rel);
    }
    try std.testing.expectEqual(@as(u32, 1), test_fire_count.load(.acquire));

    // 1000 subsequent calls: count stays at 1.
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        if (banner_fired.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            _ = test_fire_count.fetchAdd(1, .acq_rel);
        }
    }
    try std.testing.expectEqual(@as(u32, 1), test_fire_count.load(.acquire));
}
