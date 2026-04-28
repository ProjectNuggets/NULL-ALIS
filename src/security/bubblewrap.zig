const std = @import("std");
const Sandbox = @import("sandbox.zig").Sandbox;

/// Bubblewrap (bwrap) sandbox backend.
/// Wraps commands with `bwrap` for user-namespace isolation.
pub const BubblewrapSandbox = struct {
    workspace_dir: []const u8,
    /// Allocator used by isAvailable() to spawn `bwrap --version`. Optional
    /// only because SandboxStorage default-initializes the struct before any
    /// allocator is known (mirrors DockerSandbox.allocator: undefined). Real
    /// callsites must populate it before calling isAvailable().
    allocator: ?std.mem.Allocator = null,

    pub const sandbox_vtable = Sandbox.VTable{
        .wrapCommand = wrapCommand,
        .isAvailable = isAvailable,
        .name = getName,
        .description = getDescription,
    };

    pub fn sandbox(self: *BubblewrapSandbox) Sandbox {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &sandbox_vtable,
        };
    }

    fn resolve(ptr: *anyopaque) *BubblewrapSandbox {
        return @ptrCast(@alignCast(ptr));
    }

    fn wrapCommand(ptr: *anyopaque, argv: []const []const u8, buf: [][]const u8) anyerror![]const []const u8 {
        const self = resolve(ptr);
        // bwrap --ro-bind /usr /usr --dev /dev --proc /proc --tmpfs /tmp --bind WORKSPACE /workspace --chdir /workspace --unshare-all --die-with-parent <argv...>
        //
        // `--chdir /workspace` is critical: the parent process sets cwd to the
        // host-side workspace path (e.g. /Users/.../workspace/<user>) before
        // execve. That path does NOT exist inside the new mount namespace —
        // only `/workspace` does. Without --chdir, bwrap inherits the parent's
        // cwd and the inner exec fails with ENOENT. Pinning cwd to the bound
        // sandbox path is what lets shell.zig:142 pass effective_cwd unchanged.
        //
        // `--tmpfs /tmp` (was `--bind /tmp /tmp`): each sandbox gets a fresh
        // ephemeral tmpfs at /tmp. Prior `--bind /tmp /tmp` shared the host's
        // /tmp into every tenant's sandbox, opening a cross-tenant leak —
        // User A could write `/tmp/foo` and User B's sandbox would see it
        // bound at the same path. tmpfs eliminates that vector and also
        // contains tmp-fill DOS attempts to the per-call sandbox lifetime.
        // Tradeoff: scripts that genuinely expect a persistent /tmp across
        // shell invocations break — but the agent's own per-turn /tmp use
        // (mktemp, etc.) still works within a single sandbox lifetime.
        const prefix = [_][]const u8{
            "bwrap",
            "--ro-bind",
            "/usr",
            "/usr",
            "--dev",
            "/dev",
            "--proc",
            "/proc",
            "--tmpfs",
            "/tmp",
            "--bind",
            self.workspace_dir,
            "/workspace",
            "--chdir",
            "/workspace",
            "--unshare-all",
            "--die-with-parent",
        };
        const prefix_len = prefix.len;

        if (buf.len < prefix_len + argv.len) return error.BufferTooSmall;

        for (prefix, 0..) |p, i| {
            buf[i] = p;
        }
        for (argv, 0..) |arg, i| {
            buf[prefix_len + i] = arg;
        }
        return buf[0 .. prefix_len + argv.len];
    }

    fn isAvailable(ptr: *anyopaque) bool {
        const builtin = @import("builtin");
        // OS gate first: bwrap only exists on Linux.
        if (comptime builtin.os.tag != .linux) return false;

        // Runtime binary probe: spawn `bwrap --version` and check exit 0.
        // Without this, selecting .bubblewrap on a Linux host where bwrap
        // is not installed would silently exec-fail at run time instead of
        // surfacing SandboxUnavailable up front. Matches docker.zig pattern.
        const self = resolve(ptr);
        const allocator = self.allocator orelse return false;
        var child = std.process.Child.init(&.{ "bwrap", "--version" }, allocator);
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
        return "bubblewrap";
    }

    fn getDescription(_: *anyopaque) []const u8 {
        return "User namespace sandbox (requires bwrap)";
    }
};

pub fn createBubblewrapSandbox(workspace_dir: []const u8) BubblewrapSandbox {
    return .{ .workspace_dir = workspace_dir };
}

/// Construct a BubblewrapSandbox with an allocator wired for the runtime
/// `bwrap --version` availability probe. Pass null only for tests that
/// don't exercise isAvailable.
pub fn createBubblewrapSandboxWithAllocator(
    workspace_dir: []const u8,
    allocator: ?std.mem.Allocator,
) BubblewrapSandbox {
    return .{ .workspace_dir = workspace_dir, .allocator = allocator };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "bubblewrap sandbox name" {
    var bw = createBubblewrapSandbox("/tmp/workspace");
    const sb = bw.sandbox();
    try std.testing.expectEqualStrings("bubblewrap", sb.name());
}

test "bubblewrap sandbox description mentions bwrap" {
    var bw = createBubblewrapSandbox("/tmp/workspace");
    const sb = bw.sandbox();
    const desc = sb.description();
    try std.testing.expect(std.mem.indexOf(u8, desc, "bwrap") != null);
}

test "bubblewrap sandbox wrap command prepends bwrap args" {
    var bw = createBubblewrapSandbox("/tmp/workspace");
    const sb = bw.sandbox();

    const argv = [_][]const u8{ "echo", "test" };
    var buf: [32][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    try std.testing.expectEqualStrings("bwrap", result[0]);
    try std.testing.expectEqualStrings("--ro-bind", result[1]);
    try std.testing.expectEqualStrings("/usr", result[2]);
    try std.testing.expectEqualStrings("/usr", result[3]);
    // Original command is at the end
    try std.testing.expectEqualStrings("echo", result[result.len - 2]);
    try std.testing.expectEqualStrings("test", result[result.len - 1]);
}

test "bubblewrap sandbox wrap includes unshare and die-with-parent" {
    var bw = createBubblewrapSandbox("/tmp/workspace");
    const sb = bw.sandbox();

    const argv = [_][]const u8{"ls"};
    var buf: [32][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    var has_unshare = false;
    var has_die = false;
    for (result) |arg| {
        if (std.mem.eql(u8, arg, "--unshare-all")) has_unshare = true;
        if (std.mem.eql(u8, arg, "--die-with-parent")) has_die = true;
    }
    try std.testing.expect(has_unshare);
    try std.testing.expect(has_die);
}

test "bubblewrap sandbox wrap empty argv" {
    var bw = createBubblewrapSandbox("/tmp/workspace");
    const sb = bw.sandbox();

    const argv = [_][]const u8{};
    var buf: [32][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    // Just the prefix args, no original command
    try std.testing.expectEqualStrings("bwrap", result[0]);
    // 17 prefix args: bwrap, --ro-bind /usr /usr (4), --dev /dev (2), --proc /proc (2),
    // --tmpfs /tmp (2), --bind WORKSPACE /workspace (3), --chdir /workspace (2),
    // --unshare-all, --die-with-parent. Total: 1 + 4 + 2 + 2 + 2 + 3 + 2 + 2 = ...
    // count: bwrap(1) + --ro-bind /usr /usr (3) + --dev /dev (2) + --proc /proc (2)
    //      + --tmpfs /tmp (2) + --bind WS /workspace (3) + --chdir /workspace (2)
    //      + --unshare-all (1) + --die-with-parent (1) = 17.
    try std.testing.expect(result.len == 17);
}

test "bubblewrap sandbox uses --tmpfs for /tmp (cross-tenant isolation)" {
    var bw = createBubblewrapSandbox("/tmp/workspace");
    const sb = bw.sandbox();

    const argv = [_][]const u8{"ls"};
    var buf: [32][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    // Critical: each sandbox MUST get a fresh ephemeral tmpfs at /tmp, not a
    // shared host /tmp bind. Without this, User A's `/tmp/foo` is visible to
    // User B (cross-tenant data leak). Also blocks tmp-fill DOS persisting
    // beyond the sandbox lifetime.
    var has_tmpfs = false;
    var has_tmp_value = false;
    var has_bind_tmp = false; // must NOT be present
    for (result, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--tmpfs")) {
            has_tmpfs = true;
            if (i + 1 < result.len and std.mem.eql(u8, result[i + 1], "/tmp")) {
                has_tmp_value = true;
            }
        }
        // Detect the old bug: --bind followed by /tmp /tmp.
        if (std.mem.eql(u8, arg, "--bind") and i + 2 < result.len and
            std.mem.eql(u8, result[i + 1], "/tmp") and std.mem.eql(u8, result[i + 2], "/tmp"))
        {
            has_bind_tmp = true;
        }
    }
    try std.testing.expect(has_tmpfs);
    try std.testing.expect(has_tmp_value);
    try std.testing.expect(!has_bind_tmp);
}

test "bubblewrap sandbox wrap includes --chdir /workspace" {
    var bw = createBubblewrapSandbox("/tmp/workspace");
    const sb = bw.sandbox();

    const argv = [_][]const u8{"ls"};
    var buf: [32][]const u8 = undefined;
    const result = try sb.wrapCommand(&argv, &buf);

    var has_chdir_flag = false;
    var has_chdir_value = false;
    for (result, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--chdir")) {
            has_chdir_flag = true;
            if (i + 1 < result.len and std.mem.eql(u8, result[i + 1], "/workspace")) {
                has_chdir_value = true;
            }
        }
    }
    try std.testing.expect(has_chdir_flag);
    try std.testing.expect(has_chdir_value);
}

test "bubblewrap buffer too small returns error" {
    var bw = createBubblewrapSandbox("/tmp/workspace");
    const sb = bw.sandbox();

    const argv = [_][]const u8{ "echo", "test" };
    var buf: [3][]const u8 = undefined;
    const result = sb.wrapCommand(&argv, &buf);
    try std.testing.expectError(error.BufferTooSmall, result);
}
