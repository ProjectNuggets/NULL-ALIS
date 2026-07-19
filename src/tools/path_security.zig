//! Path security helpers shared by file_read, file_write, file_edit, file_append,
//! shell, and git tools.
//!
//! Extracted from file_edit.zig to eliminate cross-imports between tool files.

const std = @import("std");

/// System-critical prefixes (Unix) — always blocked even if they match allowed_paths.
const SYSTEM_BLOCKED_PREFIXES_UNIX = [_][]const u8{
    "/System",
    "/Library",
    "/bin",
    "/sbin",
    "/usr/bin",
    "/usr/sbin",
    "/usr/lib",
    "/usr/libexec",
    "/etc",
    "/private/etc",
    "/private/var",
    "/dev",
    "/boot",
    "/proc",
    "/sys",
};

/// System-critical prefixes (Windows).
const SYSTEM_BLOCKED_PREFIXES_WINDOWS = [_][]const u8{
    "C:\\Windows",
    "C:\\Program Files",
    "C:\\Program Files (x86)",
    "C:\\ProgramData",
    "C:\\System32",
    "C:\\Recovery",
};

/// Platform-selected system blocked prefixes.
pub const SYSTEM_BLOCKED_PREFIXES: []const []const u8 = if (@import("builtin").os.tag == .windows)
    &SYSTEM_BLOCKED_PREFIXES_WINDOWS
else
    &SYSTEM_BLOCKED_PREFIXES_UNIX;

/// Agent control-plane directories that live INSIDE the agent's own writable workspace.
///
/// In the user-cell pod shape HOME is `{workspace}/.home` (gateway.zig), so `~/.nullalis/cron.json`
/// and `~/.nullalis/auth.json` resolve *under the workspace prefix* — which the check below would
/// otherwise allow outright. Writing those is not a file edit, it is a privilege change:
///   - `cron.json` installs durable jobs the scheduler re-reads every tick and runs as agent turns,
///     i.e. a self-retriggering foothold that outlives the session;
///   - `auth.json` holds provider credentials.
/// That is precisely the persistence threat the `cron_add`/`schedule` approval gate exists to stop,
/// reachable without the cron tool at all. Deny it at the path layer so it holds for every tool and
/// every autonomy level, rather than depending on which tools happen to be approval-gated today.
const WORKSPACE_CONTROL_PLANE_DIRS = [_][]const u8{ ".nullalis", ".home" };

/// True when a resolved path lands inside the agent's control plane within its own workspace.
fn isWorkspaceControlPlanePath(resolved: []const u8, ws_resolved: []const u8) bool {
    if (!pathStartsWith(resolved, ws_resolved)) return false;
    var rel = resolved[ws_resolved.len..];
    while (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) rel = rel[1..];
    for (WORKSPACE_CONTROL_PLANE_DIRS) |dir| {
        if (pathStartsWith(rel, dir)) return true;
    }
    return false;
}

/// Check whether a directory-style prefix matches (exact or followed by a path separator).
pub fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    const c = path[prefix.len];
    return c == '/' or c == '\\';
}

/// Check whether a **resolved** absolute path is allowed by the policy:
///  1. System blocklist always rejects.
///  1b. Agent control plane inside the workspace always rejects (see WORKSPACE_CONTROL_PLANE_DIRS).
///  2. Workspace prefix matches → allowed.
///  3. Any allowed_path prefix matches (resolved on the fly) → allowed.
pub fn isResolvedPathAllowed(
    allocator: std.mem.Allocator,
    resolved: []const u8,
    ws_resolved: []const u8,
    allowed_paths: []const []const u8,
) bool {
    // 1. System blocklist
    for (SYSTEM_BLOCKED_PREFIXES) |prefix| {
        if (pathStartsWith(resolved, prefix)) return false;
    }
    // 1b. Control plane — MUST precede the workspace allow below, because these dirs live inside
    // the workspace and would otherwise be allowed by prefix match.
    if (isWorkspaceControlPlanePath(resolved, ws_resolved)) return false;
    // 2. Workspace
    if (pathStartsWith(resolved, ws_resolved)) return true;
    // 3. Allowed paths (resolve each to handle symlinks)
    for (allowed_paths) |ap| {
        const ap_resolved = std.fs.cwd().realpathAlloc(allocator, ap) catch continue;
        defer allocator.free(ap_resolved);
        if (pathStartsWith(resolved, ap_resolved)) return true;
    }
    return false;
}

/// Check if a relative path is safe (no traversal, no absolute path).
pub fn isPathSafe(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var iter = std.mem.splitAny(u8, path, "/\\");
    while (iter.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    // Block URL-encoded traversal (..%2f, %2f.., ..%5c, %5c..)
    {
        var lower: [4096]u8 = undefined;
        if (path.len > lower.len) return false; // reject rather than silently truncate
        const len = path.len;
        for (path[0..len], 0..) |c, i| {
            lower[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const lp = lower[0..len];
        if (std.mem.indexOf(u8, lp, "..%2f") != null or
            std.mem.indexOf(u8, lp, "%2f..") != null or
            std.mem.indexOf(u8, lp, "..%5c") != null or
            std.mem.indexOf(u8, lp, "%5c..") != null) return false;
    }
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────

test "isPathSafe blocks null bytes" {
    try std.testing.expect(!isPathSafe("file\x00.txt"));
}

test "isPathSafe allows relative" {
    try std.testing.expect(isPathSafe("file.txt"));
    try std.testing.expect(isPathSafe("src/main.zig"));
}

test "isPathSafe blocks traversal" {
    try std.testing.expect(!isPathSafe("../../etc/passwd"));
    try std.testing.expect(!isPathSafe("foo/../../../bar"));
}

test "isPathSafe blocks absolute" {
    try std.testing.expect(!isPathSafe("/etc/passwd"));
}

test "isPathSafe blocks URL-encoded traversal" {
    try std.testing.expect(!isPathSafe("..%2fetc/passwd"));
    try std.testing.expect(!isPathSafe("%2f..%2fetc/passwd"));
    try std.testing.expect(!isPathSafe("..%5c..%5cwindows"));
    try std.testing.expect(!isPathSafe("%5c..%5csecret"));
    // Case-insensitive
    try std.testing.expect(!isPathSafe("..%2Fetc/passwd"));
    try std.testing.expect(!isPathSafe("..%2fetc/passwd"));
}

test "isPathSafe allows percent in non-traversal context" {
    try std.testing.expect(isPathSafe("file%20name.txt"));
    try std.testing.expect(isPathSafe("100%25done.txt"));
}

test "isResolvedPathAllowed allows workspace path" {
    try std.testing.expect(isResolvedPathAllowed(
        std.testing.allocator,
        "/home/user/workspace/file.txt",
        "/home/user/workspace",
        &.{},
    ));
}

test "isResolvedPathAllowed allows exact workspace" {
    try std.testing.expect(isResolvedPathAllowed(
        std.testing.allocator,
        "/home/user/workspace",
        "/home/user/workspace",
        &.{},
    ));
}

test "isResolvedPathAllowed rejects outside workspace" {
    try std.testing.expect(!isResolvedPathAllowed(
        std.testing.allocator,
        "/home/user/other/file.txt",
        "/home/user/workspace",
        &.{},
    ));
}

test "isResolvedPathAllowed rejects partial prefix match" {
    try std.testing.expect(!isResolvedPathAllowed(
        std.testing.allocator,
        "/home/user/workspace-evil/file.txt",
        "/home/user/workspace",
        &.{},
    ));
}

test "isResolvedPathAllowed blocks system paths" {
    if (comptime @import("builtin").os.tag == .windows) {
        try std.testing.expect(!isResolvedPathAllowed(
            std.testing.allocator,
            "C:\\Windows\\system32\\cmd.exe",
            "C:\\Users\\ws",
            &.{},
        ));
        try std.testing.expect(!isResolvedPathAllowed(
            std.testing.allocator,
            "C:\\Program Files\\app\\evil.exe",
            "C:\\Users\\ws",
            &.{},
        ));
    } else {
        try std.testing.expect(!isResolvedPathAllowed(
            std.testing.allocator,
            "/etc/passwd",
            "/etc",
            &.{},
        ));
        try std.testing.expect(!isResolvedPathAllowed(
            std.testing.allocator,
            "/System/Library/something",
            "/home/ws",
            &.{"/System"},
        ));
        try std.testing.expect(!isResolvedPathAllowed(
            std.testing.allocator,
            "/bin/sh",
            "/home/ws",
            &.{"/bin"},
        ));
    }
}

test "isResolvedPathAllowed allows via allowed_paths" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    try tmp_dir.dir.writeFile(.{ .sub_path = "test.txt", .data = "" });
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "test.txt" });
    defer std.testing.allocator.free(file_path);

    try std.testing.expect(isResolvedPathAllowed(
        std.testing.allocator,
        file_path,
        "/nonexistent-workspace",
        &.{tmp_path},
    ));
}

test "pathStartsWith exact match" {
    try std.testing.expect(pathStartsWith("/foo/bar", "/foo/bar"));
}

test "pathStartsWith with trailing component" {
    try std.testing.expect(pathStartsWith("/foo/bar/baz", "/foo/bar"));
}

test "pathStartsWith rejects partial" {
    try std.testing.expect(!pathStartsWith("/foo/barbaz", "/foo/bar"));
}

// ── WP-SEC1: agent control plane inside the workspace ────────────────────────────────
//
// Regression cover for the hole opened by widening `supervised_auto_approve` to the file_* tools.
// In the user-cell pod shape HOME is `{workspace}/.home`, so the scheduler's job file and the
// credential store resolve UNDER the workspace prefix. Without the control-plane denylist an
// auto-approved `file_write` installs a durable self-retriggering cron job and rewrites provider
// credentials with no prompt — reaching the exact persistence threat the cron approval gate exists
// to stop, without using the cron tool at all.

test "isResolvedPathAllowed rejects the scheduler job file inside the workspace" {
    try std.testing.expect(!isResolvedPathAllowed(
        std.testing.allocator,
        "/workspace/.nullalis/cron.json",
        "/workspace",
        &.{},
    ));
}

test "isResolvedPathAllowed rejects the credential store inside the workspace" {
    try std.testing.expect(!isResolvedPathAllowed(
        std.testing.allocator,
        "/workspace/.nullalis/auth.json",
        "/workspace",
        &.{},
    ));
}

test "isResolvedPathAllowed rejects the user-cell HOME tree" {
    try std.testing.expect(!isResolvedPathAllowed(
        std.testing.allocator,
        "/workspace/.home/.nullalis/cron.json",
        "/workspace",
        &.{},
    ));
}

test "isResolvedPathAllowed rejects the control-plane dir itself" {
    try std.testing.expect(!isResolvedPathAllowed(
        std.testing.allocator,
        "/workspace/.nullalis",
        "/workspace",
        &.{},
    ));
}

test "isResolvedPathAllowed rejects control plane even when listed in allowed_paths" {
    // An operator-configured allowed_path must not be able to re-open the control plane.
    try std.testing.expect(!isResolvedPathAllowed(
        std.testing.allocator,
        "/workspace/.nullalis/cron.json",
        "/workspace",
        &.{"/workspace/.nullalis"},
    ));
}

test "isResolvedPathAllowed still allows ordinary workspace files" {
    // The denylist must not turn into a general workspace lockout — this is what keeps supervised
    // mode free of approval fatigue for normal file work.
    try std.testing.expect(isResolvedPathAllowed(
        std.testing.allocator,
        "/workspace/notes/todo.md",
        "/workspace",
        &.{},
    ));
}

test "isResolvedPathAllowed allows lookalike names that are not the control plane" {
    // `.nullalis-notes` must not be caught by a naive startsWith.
    try std.testing.expect(isResolvedPathAllowed(
        std.testing.allocator,
        "/workspace/.nullalis-notes/file.md",
        "/workspace",
        &.{},
    ));
    try std.testing.expect(isResolvedPathAllowed(
        std.testing.allocator,
        "/workspace/src/.homeward/x.txt",
        "/workspace",
        &.{},
    ));
}
