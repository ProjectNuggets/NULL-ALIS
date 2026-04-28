const std = @import("std");
const builtin = @import("builtin");
const Sandbox = @import("sandbox.zig").Sandbox;

/// Landlock sandbox backend for Linux kernel 5.13+ LSM.
/// Restricts filesystem access using the Landlock kernel interface.
/// On non-Linux platforms, returns error.UnsupportedPlatform.
pub const LandlockSandbox = struct {
    workspace_dir: []const u8,

    pub const sandbox_vtable = Sandbox.VTable{
        .wrapCommand = wrapCommand,
        .isAvailable = isAvailable,
        .name = getName,
        .description = getDescription,
    };

    pub fn sandbox(self: *LandlockSandbox) Sandbox {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &sandbox_vtable,
        };
    }

    fn wrapCommand(_: *anyopaque, argv: []const []const u8, _: [][]const u8) anyerror![]const []const u8 {
        // Landlock applies restrictions via syscalls on the spawning process
        // before exec() — not by prepending a wrapper to the command (unlike
        // firejail/bubblewrap). The required syscall layer
        // (landlock_create_ruleset → landlock_add_rule → landlock_restrict_self
        // on the current thread before spawning the child) is NOT yet wired in
        // this codebase. Returning argv unchanged here would mean selecting
        // `.landlock` applies zero isolation while the sandbox API reports
        // success — a security trap.
        //
        // FAIL-CLOSED: refuse the wrap. `isAvailable()` already returns false,
        // so callsites should fall back to noop (which then surfaces
        // SandboxUnavailable when sandbox.enabled=true). This branch only
        // executes if a caller bypasses the availability gate.
        _ = argv;
        return error.SandboxUnavailable;
    }

    fn isAvailable(_: *anyopaque) bool {
        // FAIL-CLOSED until the landlock syscall layer is implemented.
        // The vtable variant exists so the SandboxBackend enum stays stable,
        // but selecting `.landlock` today must NOT silently produce a
        // pass-through wrapper — that would let operators believe they have
        // isolation when they have none. Flip back to `os.tag == .linux`
        // ONLY after landlock_create_ruleset/add_rule/restrict_self are wired
        // and exercised by tests.
        return false;
    }

    fn getName(_: *anyopaque) []const u8 {
        return "landlock";
    }

    fn getDescription(_: *anyopaque) []const u8 {
        if (comptime builtin.os.tag == .linux) {
            return "Linux kernel LSM sandboxing (filesystem access control)";
        } else {
            return "Linux kernel LSM sandboxing (not available on this platform)";
        }
    }
};

pub fn createLandlockSandbox(workspace_dir: []const u8) LandlockSandbox {
    return .{ .workspace_dir = workspace_dir };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "landlock sandbox name" {
    var ll = createLandlockSandbox("/tmp/workspace");
    const sb = ll.sandbox();
    try std.testing.expectEqualStrings("landlock", sb.name());
}

test "landlock sandbox is fail-closed (always unavailable until syscall layer wired)" {
    var ll = createLandlockSandbox("/tmp/workspace");
    const sb = ll.sandbox();
    // Until landlock_create_ruleset/add_rule/restrict_self are implemented and
    // exercised, isAvailable MUST return false on every platform — including
    // Linux — so .auto detection skips it and explicit selection of .landlock
    // falls back to noop (and then SandboxUnavailable when sandbox is enabled).
    try std.testing.expect(!sb.isAvailable());
}

test "landlock sandbox wrap command refuses (fail-closed)" {
    var ll = createLandlockSandbox("/tmp/workspace");
    const sb = ll.sandbox();
    const argv = [_][]const u8{ "echo", "test" };
    var buf: [16][]const u8 = undefined;
    const result = sb.wrapCommand(&argv, &buf);
    // Even if a caller bypasses isAvailable, wrapCommand surfaces
    // SandboxUnavailable rather than returning argv unchanged (which would be
    // a silent zero-isolation pass-through).
    try std.testing.expectError(error.SandboxUnavailable, result);
}
