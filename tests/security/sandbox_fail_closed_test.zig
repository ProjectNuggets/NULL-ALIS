//! V8 — Sandbox fail-closed by default (v1.14.13 Step 0).
//!
//! Audit ledger row V8 (`docs/audits/2026-05-19-file-by-file-audit-ledger.md`)
//! flagged a security hole at `src/tools/tool_sandbox_v1.zig:162-168`: when
//! the resolved sandbox backend was `none` (no bwrap/firejail/docker on
//! host) AND `fail_open_on_dev=true` in config, tool execution silently
//! fell through to the host *unsandboxed*. A misconfigured prod deploy
//! shipped raw shell.
//!
//! The fix double-gates the bypass:
//!   1. `fail_open_on_dev=true` in config (existing flag)
//!   2. env var `NULLALIS_ALLOW_UNSANDBOXED_DEV=1` at process start
//!   3. resolved backend is "none"
//! Missing #1 OR #2 → `error.SandboxUnavailable`, no raw argv.
//!
//! These tests pin that contract. They use the `unsandboxed_dev_env_test_override`
//! seam to avoid mutating the process env (Zig 0.15.2 stdlib has no portable
//! setenv; the seam is documented in tool_sandbox_v1.zig).

const std = @import("std");
const nullalis = @import("nullalis");
const tool_sandbox = nullalis.tools.tool_sandbox_v1;
const SandboxStorage = nullalis.security.SandboxStorage;

const MAX_WRAPPED_ARGV = tool_sandbox.MAX_WRAPPED_ARGV;

test "V8 fail-closed: none backend + fail_open_on_dev=true + env UNSET → SandboxUnavailable" {
    // Belt-and-suspenders: even if the host CI box has the env var set
    // for an Agent D run, the test must remain deterministic.
    tool_sandbox.unsandboxed_dev_env_test_override = false;
    defer tool_sandbox.unsandboxed_dev_env_test_override = null;

    var buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
    var storage: SandboxStorage = .{};
    const argv = &[_][]const u8{ "echo", "hello" };
    const result = tool_sandbox.resolve_sandboxed_argv(
        std.testing.allocator,
        .{
            .enabled = true,
            .backend = .none,
            .workspace_dir = "/tmp",
            .fail_open_on_dev = true, // single gate — must NOT be enough
        },
        argv,
        &buf,
        &storage,
    );
    try std.testing.expectError(error.SandboxUnavailable, result);
}

test "V8 fail-open path: none backend + fail_open_on_dev=true + env SET → returns argv unchanged" {
    tool_sandbox.unsandboxed_dev_env_test_override = true;
    defer tool_sandbox.unsandboxed_dev_env_test_override = null;

    var buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
    var storage: SandboxStorage = .{};
    const argv = &[_][]const u8{ "echo", "hello" };
    const resolved = try tool_sandbox.resolve_sandboxed_argv(
        std.testing.allocator,
        .{
            .enabled = true,
            .backend = .none,
            .workspace_dir = "/tmp",
            .fail_open_on_dev = true,
        },
        argv,
        &buf,
        &storage,
    );
    // This is the only authorized unsandboxed path. log.err fires
    // alongside (see runtime), making it auditable.
    try std.testing.expectEqual(@as(usize, argv.len), resolved.len);
    try std.testing.expectEqualStrings("echo", resolved[0]);
    try std.testing.expectEqualStrings("hello", resolved[1]);
}

test "V8 fail-closed: none backend + fail_open_on_dev=FALSE + env SET → SandboxUnavailable" {
    // Env var alone must not be sufficient — config flag is the second gate.
    tool_sandbox.unsandboxed_dev_env_test_override = true;
    defer tool_sandbox.unsandboxed_dev_env_test_override = null;

    var buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
    var storage: SandboxStorage = .{};
    const argv = &[_][]const u8{ "echo", "hello" };
    const result = tool_sandbox.resolve_sandboxed_argv(
        std.testing.allocator,
        .{
            .enabled = true,
            .backend = .none,
            .workspace_dir = "/tmp",
            .fail_open_on_dev = false, // gate missing
        },
        argv,
        &buf,
        &storage,
    );
    try std.testing.expectError(error.SandboxUnavailable, result);
}

test "V8 real backend: docker resolves to wrapped argv regardless of env var" {
    // Real backend must be wrapped whether the dev env var is set or not.
    // We exercise both states; docker's createSandbox always returns a
    // sandbox named "docker" on this host (no binary probe at construct).
    inline for ([_]?bool{ false, true }) |override| {
        tool_sandbox.unsandboxed_dev_env_test_override = override;
        defer tool_sandbox.unsandboxed_dev_env_test_override = null;

        var buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
        var storage: SandboxStorage = .{};
        const argv = &[_][]const u8{ "echo", "hello" };
        const resolved = try tool_sandbox.resolve_sandboxed_argv(
            std.testing.allocator,
            .{
                .enabled = true,
                .backend = .docker,
                .workspace_dir = "/tmp",
            },
            argv,
            &buf,
            &storage,
        );
        // First arg of the wrapped argv must be the real backend's
        // command, not the original "echo". Wrapping happened.
        try std.testing.expectEqualStrings("docker", resolved[0]);
        try std.testing.expect(resolved.len > argv.len);
    }
}
