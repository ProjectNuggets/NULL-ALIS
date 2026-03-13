const std = @import("std");
const config_types = @import("../config_types.zig");
const security = @import("../security/root.zig");
const process_util = @import("process_util.zig");

pub const SandboxExecConfig = struct {
    enabled: bool = false,
    backend: config_types.SandboxBackend = .auto,
    workspace_dir: []const u8 = ".",
};

pub const MAX_WRAPPED_ARGV: usize = 160;

pub fn resolve_sandboxed_argv(
    allocator: std.mem.Allocator,
    exec_cfg: SandboxExecConfig,
    argv: []const []const u8,
    wrapped_buf: *[MAX_WRAPPED_ARGV][]const u8,
) ![]const []const u8 {
    if (!exec_cfg.enabled) return argv;

    var sandbox_storage: security.SandboxStorage = .{};
    const sandbox = security.createSandbox(
        allocator,
        to_detect_backend(exec_cfg.backend),
        exec_cfg.workspace_dir,
        &sandbox_storage,
    );
    if (std.mem.eql(u8, sandbox.name(), "none")) return error.SandboxUnavailable;

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
