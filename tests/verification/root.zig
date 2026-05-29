//! S6 verification matrix — single aggregation root.
//!
//! Every per-surface file is a test container; this file pulls them in so
//! `build.zig` only needs one `addTest` artifact for the entire matrix.
//!
//! Default `zig build test` does NOT run this — the matrix is wired into
//! the dedicated `zig build test-postgres` step. Postgres-gated tests skip
//! cleanly when NULLALIS_POSTGRES_TEST_URL is unset, so the step is safe to
//! run locally without a fixture.

const std = @import("std");

test {
    _ = @import("harness.zig");
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
