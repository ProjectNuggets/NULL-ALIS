const std = @import("std");
const builtin = @import("builtin");
const config_types = @import("../config_types.zig");
const security = @import("../security/root.zig");
const process_util = @import("process_util.zig");
const log = std.log.scoped(.tool_sandbox_v1);

pub const SandboxExecConfig = struct {
    enabled: bool = false,
    backend: config_types.SandboxBackend = .auto,
    workspace_dir: []const u8 = ".",
    allowed_roots: []const []const u8 = &.{},
    /// When `enabled = true` but the resolved sandbox is `noop` (no real
    /// backend available on the host), control behavior. The fail-open
    /// path is **double-gated** as of V8 (v1.14.13 Step 0): a misconfigured
    /// prod deploy with this field stuck at `true` used to silently ship
    /// unsandboxed shell to users — that was the security hole.
    ///
    /// To fall through to unsandboxed argv ALL of the following must hold:
    ///   1. `fail_open_on_dev = true` (this field, set in config)
    ///   2. env var `NULLALIS_ALLOW_UNSANDBOXED_DEV=1` at process start
    ///   3. resolved sandbox name is `"none"` (no real backend installed)
    ///
    /// Missing #1 or #2 → `error.SandboxUnavailable`. The double-gate
    /// means a single misconfigured config OR a single missing env var
    /// closes the hole — no single point of failure.
    ///
    /// The matching `log.err` (not warn) when bypass fires is the audit
    /// trail; surface it in alerting.
    fail_open_on_dev: bool = false,
};

pub const MAX_WRAPPED_ARGV: usize = 160;

/// Env var that authorizes the unsandboxed fall-through path. Operators
/// who deliberately want to run tools without isolation on a dev host
/// MUST set this AND `fail_open_on_dev=true` in config. Either alone is
/// insufficient — see `SandboxExecConfig.fail_open_on_dev` doc.
pub const UNSANDBOXED_DEV_ENV_VAR = "NULLALIS_ALLOW_UNSANDBOXED_DEV";

/// Test seam. Production code keeps this `null` and the helper falls
/// through to `std.posix.getenv`. Tests assign `true`/`false` directly
/// to gate the dev-bypass path without mutating the process env (which
/// is racy under parallel test runners and lacks a portable Zig stdlib
/// API in 0.15.2). The runtime checks this BEFORE consulting the env.
///
/// MUST remain `null` outside test scope. There is no production code
/// path that writes to this.
pub var unsandboxed_dev_env_test_override: ?bool = null;

fn unsandboxedDevEnvAuthorized() bool {
    if (unsandboxed_dev_env_test_override) |v| return v;
    const val = std.posix.getenv(UNSANDBOXED_DEV_ENV_VAR) orelse return false;
    return std.mem.eql(u8, val, "1");
}

/// Emit a large warning banner at process startup if the operator has
/// set `NULLALIS_ALLOW_UNSANDBOXED_DEV=1`. This pairs with the
/// double-gate in `resolve_sandboxed_argv` so the dev-bypass condition
/// is visible in both the boot log and in alerting (log.err level).
///
/// Idempotency is the caller's responsibility — call this once at
/// daemon/main startup, not per-request.
pub fn logUnsandboxedDevBannerIfEnabled() void {
    if (!unsandboxedDevEnvAuthorized()) return;
    // AGENTS.md §3.6: log.err during tests causes the default test runner
    // to fail the test; the banner is a runtime audit signal so we gate
    // it on `!is_test`. Tests exercising the gate verify behavior, not
    // the log line itself.
    if (builtin.is_test) return;
    log.err(
        "\n" ++
            "  ======================================================================\n" ++
            "  ==  SECURITY: NULLALIS_ALLOW_UNSANDBOXED_DEV=1 IS SET               ==\n" ++
            "  ==                                                                  ==\n" ++
            "  ==  Tool execution MAY fall through to the host unsandboxed when   ==\n" ++
            "  ==  the resolved backend is 'none' AND fail_open_on_dev=true in    ==\n" ++
            "  ==  config. This is a DEVELOPMENT-ONLY escape hatch — NEVER ship   ==\n" ++
            "  ==  this env var to production. Install bwrap/firejail/docker.     ==\n" ++
            "  ======================================================================",
        .{},
    );
}

const WorkspaceValidationReason = enum(u8) {
    none = 0,
    empty,
    not_absolute,
    is_root,
    traversal,
    dangerous_mount,
    null_bytes,
    path_too_long,
    not_in_allowed_roots,

    fn fromValidationResult(result: security.ValidationResult) WorkspaceValidationReason {
        return switch (result) {
            .valid => .none,
            .empty => .empty,
            .not_absolute => .not_absolute,
            .is_root => .is_root,
            .traversal => .traversal,
            .dangerous_mount => .dangerous_mount,
            .null_bytes => .null_bytes,
            .path_too_long => .path_too_long,
            .not_in_allowed_roots => .not_in_allowed_roots,
        };
    }

    fn toString(self: WorkspaceValidationReason) []const u8 {
        return switch (self) {
            .none => "none",
            .empty => "empty",
            .not_absolute => "not_absolute",
            .is_root => "is_root",
            .traversal => "traversal",
            .dangerous_mount => "dangerous_mount",
            .null_bytes => "null_bytes",
            .path_too_long => "path_too_long",
            .not_in_allowed_roots => "not_in_allowed_roots",
        };
    }
};

pub const SandboxDiagnosticsSnapshot = struct {
    workspace_validation_failed_total: u64,
    workspace_fallback_none_total: u64,
    workspace_validation_last_reason: []const u8,
};

var workspace_validation_failed_total = std.atomic.Value(u64).init(0);
var workspace_fallback_none_total = std.atomic.Value(u64).init(0);
var workspace_validation_last_reason = std.atomic.Value(u8).init(@intFromEnum(WorkspaceValidationReason.none));

pub fn diagnosticsSnapshot() SandboxDiagnosticsSnapshot {
    const reason_code = workspace_validation_last_reason.load(.monotonic);
    const reason: WorkspaceValidationReason = @enumFromInt(reason_code);
    return .{
        .workspace_validation_failed_total = workspace_validation_failed_total.load(.monotonic),
        .workspace_fallback_none_total = workspace_fallback_none_total.load(.monotonic),
        .workspace_validation_last_reason = reason.toString(),
    };
}

// ── Active-state snapshot (for /api/v1/status sandbox UI badge) ──
//
// Single process-global snapshot of the resolved sandbox state. Populated
// once at agent init (tools/root.zig:detectBest path) and read by the
// gateway status handler so the frontend can render a "Shell sandboxed
// (bwrap)" badge without re-probing the host on every status call.

pub const SandboxStateSnapshot = struct {
    enabled: bool = false,
    backend: config_types.SandboxBackend = .auto,
    fail_open_on_dev: bool = false,
    has_real_backend: bool = false,
    avail_firejail: bool = false,
    avail_bubblewrap: bool = false,
    avail_docker: bool = false,
    initialized: bool = false,
};

var state_snapshot_mutex = std.Thread.Mutex{};
var state_snapshot: SandboxStateSnapshot = .{};

pub fn setStateSnapshot(snap: SandboxStateSnapshot) void {
    state_snapshot_mutex.lock();
    defer state_snapshot_mutex.unlock();
    var copy = snap;
    copy.initialized = true;
    state_snapshot = copy;
}

pub fn currentStateSnapshot() SandboxStateSnapshot {
    state_snapshot_mutex.lock();
    defer state_snapshot_mutex.unlock();
    return state_snapshot;
}

fn recordWorkspaceValidationFailure(reason: WorkspaceValidationReason) void {
    _ = workspace_validation_failed_total.fetchAdd(1, .monotonic);
    workspace_validation_last_reason.store(@intFromEnum(reason), .monotonic);
}

fn shouldValidateDockerWorkspacePath(backend: config_types.SandboxBackend) bool {
    return switch (backend) {
        .auto, .docker => true,
        else => false,
    };
}

/// Resolve the sandboxed argv. The caller MUST own `sandbox_storage` for the
/// lifetime of the returned slice — `wrapCommand` for backends like docker
/// returns a slice that points into `sandbox_storage.<backend>.mount_arg_buf`
/// (e.g. the docker `-v WORKSPACE:WORKSPACE` mount argument lives inside the
/// DockerSandbox struct, NOT in `wrapped_buf`). Returning the slice past a
/// stack-frame that owned the storage produces undefined bytes —
/// historically docker stderr'd `invalid empty volume spec` because the
/// dangling buf was zeroed by the next frame's stack use. See
/// `run_with_optional_sandbox` for the canonical lifetime pattern.
pub fn resolve_sandboxed_argv(
    allocator: std.mem.Allocator,
    exec_cfg: SandboxExecConfig,
    argv: []const []const u8,
    wrapped_buf: *[MAX_WRAPPED_ARGV][]const u8,
    sandbox_storage: *security.SandboxStorage,
) ![]const []const u8 {
    if (!exec_cfg.enabled) return argv;

    if (shouldValidateDockerWorkspacePath(exec_cfg.backend)) {
        const allowed_roots_opt: ?[]const []const u8 = if (exec_cfg.allowed_roots.len > 0) exec_cfg.allowed_roots else null;
        const validation = security.validateWorkspaceMount(exec_cfg.workspace_dir, allowed_roots_opt);
        if (!validation.isValid()) {
            const reason = WorkspaceValidationReason.fromValidationResult(validation);
            recordWorkspaceValidationFailure(reason);
            log.warn("sandbox workspace validation failed backend={s} reason={s}; refusing execution", .{
                @tagName(exec_cfg.backend),
                reason.toString(),
            });
            return error.SandboxUnavailable;
        }
    }

    const sandbox = security.createSandbox(
        allocator,
        to_detect_backend(exec_cfg.backend),
        exec_cfg.workspace_dir,
        sandbox_storage,
    );
    if (std.mem.eql(u8, sandbox.name(), "none")) {
        // V8 (v1.14.13 Step 0): double-gate the dev-bypass. Both
        // `fail_open_on_dev=true` AND env `NULLALIS_ALLOW_UNSANDBOXED_DEV=1`
        // must hold. Logged at err level (not warn) so alerting picks it up.
        if (exec_cfg.fail_open_on_dev and unsandboxedDevEnvAuthorized()) {
            _ = workspace_fallback_none_total.fetchAdd(1, .monotonic);
            // AGENTS.md §3.6: gate the audit log on `!is_test`. The bypass
            // path is intentionally exercised by tests; the log line is a
            // runtime audit signal, not a test assertion.
            if (!builtin.is_test) {
                log.err(
                    "SANDBOX BYPASS: no real backend available; falling through " ++
                        "unsandboxed because fail_open_on_dev=true AND " ++
                        "NULLALIS_ALLOW_UNSANDBOXED_DEV=1. Dev-host behavior only — " ++
                        "if you see this on a production host, fix the config or " ++
                        "install bwrap/firejail/docker immediately.",
                    .{},
                );
            }
            return argv;
        }
        return error.SandboxUnavailable;
    }

    return sandbox.wrapCommand(argv, wrapped_buf) catch |err| switch (err) {
        error.BufferTooSmall => error.SandboxArgvTooLong,
        else => err,
    };
}

fn to_detect_backend(backend: config_types.SandboxBackend) security.SandboxBackend {
    return switch (backend) {
        .auto => .auto,
        .none => .none,
        .landlock => .landlock,
        .firejail => .firejail,
        .bubblewrap => .bubblewrap,
        .docker => .docker,
    };
}

pub fn run_with_optional_sandbox(
    allocator: std.mem.Allocator,
    exec_cfg: SandboxExecConfig,
    argv: []const []const u8,
    opts: process_util.RunOptions,
) !process_util.RunResult {
    var wrapped_buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
    // sandbox_storage MUST live until process_util.run finishes — the
    // wrapped argv slice (e.g. docker's `-v WORKSPACE:WORKSPACE` mount
    // argument) points into this struct's per-backend buffers. Previously
    // declared inside resolve_sandboxed_argv, which destroyed it on return
    // and let docker read garbage bytes for the mount spec → recurring
    // `docker: invalid empty volume spec` errors on every shell call.
    var sandbox_storage: security.SandboxStorage = .{};
    const effective_argv = try resolve_sandboxed_argv(allocator, exec_cfg, argv, &wrapped_buf, &sandbox_storage);
    return process_util.run(allocator, effective_argv, opts);
}

test "resolve_sandboxed_argv disabled passthrough" {
    var buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
    var storage: security.SandboxStorage = .{};
    const argv = &[_][]const u8{ "echo", "hello" };
    const resolved = try resolve_sandboxed_argv(
        std.testing.allocator,
        .{ .enabled = false, .workspace_dir = "/tmp" },
        argv,
        &buf,
        &storage,
    );
    try std.testing.expectEqual(@as(usize, argv.len), resolved.len);
    try std.testing.expectEqualStrings("echo", resolved[0]);
    try std.testing.expectEqualStrings("hello", resolved[1]);
}

test "resolve_sandboxed_argv enabled none backend fails closed" {
    var buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
    var storage: security.SandboxStorage = .{};
    const argv = &[_][]const u8{ "echo", "hello" };
    const result = resolve_sandboxed_argv(
        std.testing.allocator,
        .{
            .enabled = true,
            .backend = .none,
            .workspace_dir = "/tmp",
        },
        argv,
        &buf,
        &storage,
    );
    try std.testing.expectError(error.SandboxUnavailable, result);
}

test "resolve_sandboxed_argv invalid docker workspace fails closed and records diagnostics" {
    var buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
    var storage: security.SandboxStorage = .{};
    const argv = &[_][]const u8{ "echo", "hello" };
    const before = diagnosticsSnapshot();
    const result = resolve_sandboxed_argv(
        std.testing.allocator,
        .{
            .enabled = true,
            .backend = .docker,
            .workspace_dir = "/etc",
        },
        argv,
        &buf,
        &storage,
    );
    const after = diagnosticsSnapshot();
    try std.testing.expectError(error.SandboxUnavailable, result);
    try std.testing.expect(after.workspace_validation_failed_total >= before.workspace_validation_failed_total + 1);
    try std.testing.expectEqual(before.workspace_fallback_none_total, after.workspace_fallback_none_total);
    try std.testing.expectEqualStrings("dangerous_mount", after.workspace_validation_last_reason);
}

test "resolve_sandboxed_argv docker wrapper composition" {
    var buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
    var storage: security.SandboxStorage = .{};
    const argv = &[_][]const u8{ "echo", "hello" };
    const resolved = try resolve_sandboxed_argv(
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
    try std.testing.expectEqualStrings("docker", resolved[0]);
    try std.testing.expectEqualStrings("run", resolved[1]);
    try std.testing.expectEqualStrings("echo", resolved[resolved.len - 2]);
    try std.testing.expectEqualStrings("hello", resolved[resolved.len - 1]);
}
