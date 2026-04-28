const std = @import("std");
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
    /// backend available on the host), control behavior:
    /// - `false` (default, production-safe): return error.SandboxUnavailable.
    ///   Shell tool refuses. Forces operators to fix the missing-backend
    ///   condition rather than silently shipping unsandboxed shell to users.
    /// - `true` (dev-friendly): log.warn + return argv unchanged. Shell tool
    ///   runs the command without isolation. The warn is the audit trail
    ///   that operators can grep for.
    fail_open_on_dev: bool = false,
};

pub const MAX_WRAPPED_ARGV: usize = 160;

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

fn recordWorkspaceValidationFailure(reason: WorkspaceValidationReason) void {
    _ = workspace_validation_failed_total.fetchAdd(1, .monotonic);
    _ = workspace_fallback_none_total.fetchAdd(1, .monotonic);
    workspace_validation_last_reason.store(@intFromEnum(reason), .monotonic);
}

fn shouldValidateDockerWorkspacePath(backend: config_types.SandboxBackend) bool {
    return switch (backend) {
        .auto, .docker => true,
        else => false,
    };
}

pub fn resolve_sandboxed_argv(
    allocator: std.mem.Allocator,
    exec_cfg: SandboxExecConfig,
    argv: []const []const u8,
    wrapped_buf: *[MAX_WRAPPED_ARGV][]const u8,
) ![]const []const u8 {
    if (!exec_cfg.enabled) return argv;

    if (shouldValidateDockerWorkspacePath(exec_cfg.backend)) {
        const allowed_roots_opt: ?[]const []const u8 = if (exec_cfg.allowed_roots.len > 0) exec_cfg.allowed_roots else null;
        const validation = security.validateWorkspaceMount(exec_cfg.workspace_dir, allowed_roots_opt);
        if (!validation.isValid()) {
            const reason = WorkspaceValidationReason.fromValidationResult(validation);
            recordWorkspaceValidationFailure(reason);
            log.warn("sandbox workspace validation failed backend={s} reason={s}; falling back to none", .{
                @tagName(exec_cfg.backend),
                reason.toString(),
            });
            return argv;
        }
    }

    var sandbox_storage: security.SandboxStorage = .{};
    const sandbox = security.createSandbox(
        allocator,
        to_detect_backend(exec_cfg.backend),
        exec_cfg.workspace_dir,
        &sandbox_storage,
    );
    if (std.mem.eql(u8, sandbox.name(), "none")) {
        if (exec_cfg.fail_open_on_dev) {
            log.warn("sandbox: no real backend available, falling through unsandboxed (fail_open_on_dev=true). This is acceptable on dev hosts; on production hosts install bwrap/firejail/docker and set fail_open_on_dev=false.", .{});
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
    const effective_argv = try resolve_sandboxed_argv(allocator, exec_cfg, argv, &wrapped_buf);
    return process_util.run(allocator, effective_argv, opts);
}

test "resolve_sandboxed_argv disabled passthrough" {
    var buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
    const argv = &[_][]const u8{ "echo", "hello" };
    const resolved = try resolve_sandboxed_argv(
        std.testing.allocator,
        .{ .enabled = false, .workspace_dir = "/tmp" },
        argv,
        &buf,
    );
    try std.testing.expectEqual(@as(usize, argv.len), resolved.len);
    try std.testing.expectEqualStrings("echo", resolved[0]);
    try std.testing.expectEqualStrings("hello", resolved[1]);
}

test "resolve_sandboxed_argv enabled none backend fails closed" {
    var buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
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
    );
    try std.testing.expectError(error.SandboxUnavailable, result);
}

test "resolve_sandboxed_argv invalid docker workspace falls back to passthrough and records diagnostics" {
    var buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
    const argv = &[_][]const u8{ "echo", "hello" };
    const before = diagnosticsSnapshot();
    const resolved = try resolve_sandboxed_argv(
        std.testing.allocator,
        .{
            .enabled = true,
            .backend = .docker,
            .workspace_dir = "/etc",
        },
        argv,
        &buf,
    );
    const after = diagnosticsSnapshot();
    try std.testing.expectEqual(@as(usize, argv.len), resolved.len);
    try std.testing.expectEqualStrings("echo", resolved[0]);
    try std.testing.expect(after.workspace_validation_failed_total >= before.workspace_validation_failed_total + 1);
    try std.testing.expect(after.workspace_fallback_none_total >= before.workspace_fallback_none_total + 1);
    try std.testing.expectEqualStrings("dangerous_mount", after.workspace_validation_last_reason);
}

test "resolve_sandboxed_argv docker wrapper composition" {
    var buf: [MAX_WRAPPED_ARGV][]const u8 = undefined;
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
    );
    try std.testing.expectEqualStrings("docker", resolved[0]);
    try std.testing.expectEqualStrings("run", resolved[1]);
    try std.testing.expectEqualStrings("echo", resolved[resolved.len - 2]);
    try std.testing.expectEqualStrings("hello", resolved[resolved.len - 1]);
}
