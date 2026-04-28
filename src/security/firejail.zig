const std = @import("std");
const Sandbox = @import("sandbox.zig").Sandbox;

/// Firejail sandbox backend for Linux.
/// Wraps commands with `firejail` for user-space sandboxing.
pub const FirejailSandbox = struct {
    workspace_dir: []const u8,
    /// Allocator used by isAvailable() to spawn `firejail --version`. Optional
    /// only because SandboxStorage default-initializes the struct before any
    /// allocator is known (mirrors DockerSandbox.allocator: undefined). Real
    /// callsites must populate it before calling isAvailable().
    allocator: ?std.mem.Allocator = null,
    private_arg_buf: [256]u8 = undefined,
    private_arg_len: usize = 0,

    pub const sandbox_vtable = Sandbox.VTable{
        .wrapCommand = wrapCommand,
        .isAvailable = isAvailable,
        .name = getName,
        .description = getDescription,
    };

    pub fn sandbox(self: *FirejailSandbox) Sandbox {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &sandbox_vtable,
        };
    }

    fn resolve(ptr: *anyopaque) *FirejailSandbox {
        return @ptrCast(@alignCast(ptr));
    }

    fn wrapCommand(ptr: *anyopaque, argv: []const []const u8, buf: [][]const u8) anyerror![]const []const u8 {
        const self = resolve(ptr);
        // firejail --private=WORKSPACE --net=none --quiet --noprofile <original argv...>
        const prefix_len: usize = 5;
        if (buf.len < prefix_len + argv.len) return error.BufferTooSmall;

        buf[0] = "firejail";
        buf[1] = self.private_arg_buf[0..self.private_arg_len];
        buf[2] = "--net=none";
        buf[3] = "--quiet";
        buf[4] = "--noprofile";

        for (argv, 0..) |arg, i| {
            buf[prefix_len + i] = arg;
        }
        return buf[0 .. prefix_len + argv.len];
    }

    fn isAvailable(ptr: *anyopaque) bool {
        const builtin = @import("builtin");
        // OS gate first: firejail only exists on Linux.
        if (comptime builtin.os.tag != .linux) return false;

        // Runtime binary probe: spawn `firejail --version` and check exit 0.
        // Without this check, selecting .firejail on a Linux host where the
        // binary is not installed would silently exec-fail at run time
        // instead of surfacing SandboxUnavailable up front. Matches docker.zig
        // isAvailable pattern.
        const self = resolve(ptr);
        const allocator = self.allocator orelse return false;
        var child = std.process.Child.init(&.{ "firejail", "--version" }, allocator);
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stdin_behavior = .Ignore;
        child.spawn() catch return false;
        const term = child.wait() catch return false;
        return switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }

    fn getName(_: *anyopaque) []const u8 {
        return "firejail";
    }

    fn getDescription(_: *anyopaque) []const u8 {
        return "Linux user-space sandbox (requires firejail to be installed)";
    }
};

pub fn createFirejailSandbox(workspace_dir: []const u8) FirejailSandbox {
    return createFirejailSandboxWithAllocator(workspace_dir, null);
}

/// Construct a FirejailSandbox with an allocator wired for the runtime
/// `firejail --version` availability probe. Pass null only for tests that
/// don't exercise isAvailable.
pub fn createFirejailSandboxWithAllocator(
    workspace_dir: []const u8,
    allocator: ?std.mem.Allocator,
) FirejailSandbox {
    var result = FirejailSandbox{ .workspace_dir = workspace_dir, .allocator = allocator };
    const written = std.fmt.bufPrint(&result.private_arg_buf, "--private={s}", .{workspace_dir}) catch {
        // Path too long for buffer; fall back to bare --private
        @memcpy(result.private_arg_buf[0..9], "--private");
        result.private_arg_len = 9;
        return result;
    };
    result.private_arg_len = written.len;
    return result;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "firejail sandbox name" {
    var fj = createFirejailSandbox("/tmp/workspace");
    const sb = fj.sandbox();
    try std.testing.expectEqualStrings("firejail", sb.name());
}

test "firejail sandbox wrap command prepends firejail args" {
    var fj = createFirejailSandbox("/tmp/workspace");
    const sb = fj.sandbox();

    const argv = [_][]const u8{ "echo", "hello" };
    var buf: [16][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    // Should start with firejail
    try std.testing.expectEqualStrings("firejail", result[0]);
    try std.testing.expectEqualStrings("--private=/tmp/workspace", result[1]);
    try std.testing.expectEqualStrings("--net=none", result[2]);
    try std.testing.expectEqualStrings("--quiet", result[3]);
    try std.testing.expectEqualStrings("--noprofile", result[4]);
    // Original command follows
    try std.testing.expectEqualStrings("echo", result[5]);
    try std.testing.expectEqualStrings("hello", result[6]);
    try std.testing.expectEqual(@as(usize, 7), result.len);
}

test "firejail sandbox wrap empty argv" {
    var fj = createFirejailSandbox("/tmp/workspace");
    const sb = fj.sandbox();

    const argv = [_][]const u8{};
    var buf: [16][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("firejail", result[0]);
}

test "firejail sandbox wrap single arg" {
    var fj = createFirejailSandbox("/tmp/workspace");
    const sb = fj.sandbox();

    const argv = [_][]const u8{"ls"};
    var buf: [16][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    try std.testing.expectEqual(@as(usize, 6), result.len);
    try std.testing.expectEqualStrings("ls", result[5]);
}

test "firejail buffer too small returns error" {
    var fj = createFirejailSandbox("/tmp/workspace");
    const sb = fj.sandbox();

    const argv = [_][]const u8{ "echo", "test" };
    var buf: [3][]const u8 = undefined;
    const result = sb.wrapCommand(&argv, &buf);
    try std.testing.expectError(error.BufferTooSmall, result);
}
