const std = @import("std");
const builtin = @import("builtin");

/// Result of a child process execution.
pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    success: bool,
    exit_code: ?u32 = null,
    timed_out: bool = false,

    /// Free both stdout and stderr buffers.
    pub fn deinit(self: *const RunResult, allocator: std.mem.Allocator) void {
        if (self.stdout.len > 0) allocator.free(self.stdout);
        if (self.stderr.len > 0) allocator.free(self.stderr);
    }
};

/// Options for running a child process.
pub const RunOptions = struct {
    cwd: ?[]const u8 = null,
    env_map: ?*std.process.EnvMap = null,
    max_output_bytes: usize = 1_048_576,
    timeout_ns: ?u64 = null,
};

const PROCESS_POLL_SLICE_NS: u64 = 10 * std.time.ns_per_ms;
const PROCESS_TERM_GRACE_NS: u64 = 100 * std.time.ns_per_ms;

/// Run a child process, capture stdout and stderr, and return the result.
///
/// The caller owns the returned stdout and stderr buffers.
/// Use `result.deinit(allocator)` to free them.
pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    opts: RunOptions,
) !RunResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (opts.cwd) |cwd| child.cwd = cwd;
    if (opts.env_map) |env| child.env_map = env;

    try child.spawn();
    errdefer _ = child.kill() catch {};

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const wait_result = if (comptime builtin.os.tag == .windows)
        try collectOutputAndWaitFallback(allocator, &child, &stdout_buf, &stderr_buf, opts.max_output_bytes)
    else
        try collectOutputAndWaitPosix(allocator, &child, &stdout_buf, &stderr_buf, opts.max_output_bytes, opts.timeout_ns);

    const stdout = try stdout_buf.toOwnedSlice(allocator);
    errdefer allocator.free(stdout);
    const stderr = try stderr_buf.toOwnedSlice(allocator);
    errdefer allocator.free(stderr);

    return switch (wait_result.term) {
        .Exited => |code| .{
            .stdout = stdout,
            .stderr = stderr,
            .success = !wait_result.timed_out and code == 0,
            .exit_code = code,
            .timed_out = wait_result.timed_out,
        },
        else => .{
            .stdout = stdout,
            .stderr = stderr,
            .success = false,
            .exit_code = null,
            .timed_out = wait_result.timed_out,
        },
    };
}

const WaitResult = struct {
    term: std.process.Child.Term,
    timed_out: bool = false,
};

fn collectOutputAndWaitFallback(
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    stdout_buf: *std.ArrayList(u8),
    stderr_buf: *std.ArrayList(u8),
    max_output_bytes: usize,
) !WaitResult {
    try child.collectOutput(allocator, stdout_buf, stderr_buf, max_output_bytes);
    return .{ .term = try child.wait() };
}

fn collectOutputAndWaitPosix(
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    stdout_buf: *std.ArrayList(u8),
    stderr_buf: *std.ArrayList(u8),
    max_output_bytes: usize,
    timeout_ns: ?u64,
) !WaitResult {
    try child.waitForSpawn();

    var stdout_file = child.stdout.?;
    var stderr_file = child.stderr.?;
    child.stdout = null;
    child.stderr = null;
    defer stdout_file.close();
    defer stderr_file.close();

    var poller = std.Io.poll(allocator, enum { stdout, stderr }, .{
        .stdout = stdout_file,
        .stderr = stderr_file,
    });
    defer poller.deinit();

    const stdout_r = poller.reader(.stdout);
    stdout_r.buffer = stdout_buf.allocatedSlice();
    stdout_r.seek = 0;
    stdout_r.end = stdout_buf.items.len;

    const stderr_r = poller.reader(.stderr);
    stderr_r.buffer = stderr_buf.allocatedSlice();
    stderr_r.seek = 0;
    stderr_r.end = stderr_buf.items.len;

    defer {
        stdout_buf.* = .{
            .items = stdout_r.buffer[0..stdout_r.end],
            .capacity = stdout_r.buffer.len,
        };
        stderr_buf.* = .{
            .items = stderr_r.buffer[0..stderr_r.end],
            .capacity = stderr_r.buffer.len,
        };
        stdout_r.buffer = &.{};
        stderr_r.buffer = &.{};
    }

    const start_ns = std.time.nanoTimestamp();
    var term: ?std.process.Child.Term = null;
    var streams_open = true;
    var timed_out = false;
    var sent_term = false;
    var sent_kill = false;
    var term_sent_at: i128 = 0;

    while (term == null or streams_open) {
        const now_ns = std.time.nanoTimestamp();
        if (timeout_ns) |limit_ns| {
            if (!timed_out and now_ns - start_ns >= @as(i128, @intCast(limit_ns))) {
                timed_out = true;
                sent_term = true;
                term_sent_at = now_ns;
                std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
            } else if (timed_out and sent_term and !sent_kill and now_ns - term_sent_at >= @as(i128, @intCast(PROCESS_TERM_GRACE_NS))) {
                sent_kill = true;
                std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
            }
        }

        if (streams_open) {
            streams_open = try poller.pollTimeout(PROCESS_POLL_SLICE_NS);
            if (stdout_r.bufferedLen() > max_output_bytes)
                return error.StdoutStreamTooLong;
            if (stderr_r.bufferedLen() > max_output_bytes)
                return error.StderrStreamTooLong;
        } else {
            std.Thread.sleep(std.time.ns_per_ms);
        }

        if (term == null) {
            const wait_res = std.posix.waitpid(child.id, std.posix.W.NOHANG);
            if (wait_res.pid != 0) {
                const reaped_term = statusToTerm(wait_res.status);
                term = reaped_term;
                // Codex-branch review fix (2026-05-21): mirror the reaped
                // status onto child.term BEFORE invalidating child.id. If a
                // later poll slice returns error.Std{out,err}StreamTooLong,
                // run()'s `errdefer child.kill()` fires — and killPosix
                // early-returns when .term is already set, instead of
                // posix.kill()-ing the now-`undefined` child.id (a garbage
                // PID). Without this, the errdefer signals an arbitrary
                // process. (child.term is ?(SpawnError!Term); a plain Term
                // value coerces in.)
                child.term = reaped_term;
                child.id = undefined;
            }
        }
    }

    return .{ .term = term.?, .timed_out = timed_out };
}

fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        std.process.Child.Term{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        std.process.Child.Term{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        std.process.Child.Term{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        std.process.Child.Term{ .Unknown = status };
}

// ── Tests ───────────────────────────────────────────────────────────

test "run echo returns stdout" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const result = try run(allocator, &.{ "echo", "hello" }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 0), result.exit_code.?);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello") != null);
}

test "run failing command returns exit code" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const result = try run(allocator, &.{ "ls", "/nonexistent_dir_xyz_42" }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.exit_code.? != 0);
    try std.testing.expect(result.stderr.len > 0);
}

test "run with cwd" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const result = try run(allocator, &.{"pwd"}, .{ .cwd = "/tmp" });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    // /tmp may resolve to /private/tmp on macOS
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "tmp") != null);
}

test "run drains stderr while waiting for stdout" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const result = try run(
        allocator,
        &.{ "sh", "-c", "dd if=/dev/zero bs=1024 count=128 1>&2 2>/dev/null; printf done" },
        .{ .max_output_bytes = 256 * 1024 },
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("done", result.stdout);
    try std.testing.expect(result.stderr.len >= 128 * 1024);
}

test "run enforces timeout" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const result = try run(
        allocator,
        &.{ "sh", "-c", "sleep 2; printf late" },
        .{ .timeout_ns = 50 * std.time.ns_per_ms },
    );
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expect(result.timed_out);
    try std.testing.expect(result.exit_code == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "late") == null);
}

test "RunResult deinit frees buffers" {
    const allocator = std.testing.allocator;
    const stdout = try allocator.dupe(u8, "output");
    const stderr = try allocator.dupe(u8, "error");
    const result = RunResult{
        .stdout = stdout,
        .stderr = stderr,
        .success = true,
        .exit_code = 0,
    };
    result.deinit(allocator);
}

test "RunResult deinit with empty buffers" {
    const allocator = std.testing.allocator;
    const result = RunResult{
        .stdout = "",
        .stderr = "",
        .success = true,
        .exit_code = 0,
    };
    result.deinit(allocator); // should not crash or attempt to free ""
}
