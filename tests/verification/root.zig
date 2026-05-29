//! S6 verification matrix — single aggregation root.
//!
//! HARD GATE: when built without `-Dengines=...,postgres`, this file
//! fails to compile via `@compileError`. The `test-postgres` step
//! therefore FAILS (not skips) under `zig build test-postgres
//! -Dengines=base,sqlite` — the matrix is intentionally PG-only, and
//! a missing engine is a build misconfiguration, not a runtime skip.

const std = @import("std");
const build_options = @import("build_options");

comptime {
    if (!build_options.enable_postgres) {
        @compileError(
            "test-postgres requires -Dengines=...,postgres — " ++
                "the S6 verification matrix is the live-PG lane. " ++
                "Remove `-Dengines=base,sqlite` (or similar) and rebuild.",
        );
    }
}

test {
    _ = @import("harness.zig");
    _ = @import("live_pg_test.zig");
    _ = @import("health_metrics_test.zig");
    _ = @import("chat_stream_test.zig");
    _ = @import("mode_switch_test.zig");
    _ = @import("session_cancel_test.zig");
    _ = @import("approvals_test.zig");
    _ = @import("attachments_test.zig");
    _ = @import("artifacts_test.zig");
    _ = @import("trace_share_test.zig");
    _ = @import("extension_browser_test.zig");
    _ = @import("memory_tools_test.zig");
    _ = @import("gdpr_cascade_test.zig");
    _ = @import("schema_static_test.zig");
    _ = @import("observability_test.zig");
    _ = @import("startup_fail_loud_test.zig");
    _ = @import("composio_gated_test.zig");
}
