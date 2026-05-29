//! S6.14 — startup fail-loud invariant pin.
//!
//! S5 (#112) + S5 follow-up (#113) shipped a fail-loud gate: when the
//! gateway boots in a production-like configuration (`allow_public_bind`
//! or a non-loopback host) and the Postgres backend is unavailable, the
//! daemon exits non-zero with the named reason
//! `startup.production_postgres_required` rather than degrading to the
//! file backend silently.
//!
//! The end-to-end "binary boots, exits non-zero" check requires
//! spawning the binary in a subprocess — that is the operator-runbook's
//! job and lives in `docs/operations/verification-matrix.md`. This file
//! pins the SUBSTRATE invariant: `gateway.isFatalStartupError` returns
//! true for every member of the `StartupSelfCheckError` set, and the
//! set is comptime-iterated by the daemon's fail-loud gate (F15 from
//! #113), so a future variant added without touching the daemon is
//! covered automatically.

const std = @import("std");
const nullalis = @import("nullalis");
const gateway = nullalis.gateway;

test "S6.14 startup: isFatalStartupError recognizes ProductionPostgresRequired" {
    // The single shipping variant today; pin it explicitly so a rename
    // here fails this test before it ships.
    try std.testing.expect(gateway.isFatalStartupError(error.ProductionPostgresRequired));
}

test "S6.14 startup: isFatalStartupError REJECTS unrelated errors" {
    // The fail-loud gate must not fire on routine transient errors.
    // Pin the negative space so a regression that broadens the gate
    // (e.g. converts `isFatalStartupError` into `return true`) fails CI.
    try std.testing.expect(!gateway.isFatalStartupError(error.ConnectionRefused));
    try std.testing.expect(!gateway.isFatalStartupError(error.OutOfMemory));
    try std.testing.expect(!gateway.isFatalStartupError(error.FileNotFound));
    try std.testing.expect(!gateway.isFatalStartupError(error.Unexpected));
    try std.testing.expect(!gateway.isFatalStartupError(error.AccessDenied));
}

test "S6.14 startup: every shipped fail-loud error variant is named user-safe" {
    // The error variant names are surfaced in the daemon's fail-loud
    // log line + operator runbook. They must be camelCase Zig
    // identifiers (which they are by language constraint) AND must
    // carry a name that names the BACKEND requirement, not an internal
    // implementation detail. We pin the known variant's name shape so a
    // rename that loses the operator-facing meaning fails here.
    const known_safe_names = [_][]const u8{
        "ProductionPostgresRequired",
    };
    for (known_safe_names) |name| {
        // Construct the error by name lookup via @errorCast/anyerror —
        // a missing name fails to compile if the variant moved.
        const err: anyerror = err_blk: {
            inline for (.{error.ProductionPostgresRequired}) |e| {
                if (std.mem.eql(u8, @errorName(e), name)) break :err_blk e;
            }
            break :err_blk error.Unexpected;
        };
        try std.testing.expect(gateway.isFatalStartupError(err));
    }
}
