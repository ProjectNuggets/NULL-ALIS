const std = @import("std");
const builtin = @import("builtin");

const LOCK_FILE_NAME = ".nullalis-owner.lock";
const LOCK_FILE_MAX_BYTES: usize = 1024;

const LockRecord = struct {
    owner_id: []u8,
    expires_at: i64,
    lock_token: []u8,
};

pub const UserOwnershipLock = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    owner_id: []const u8,
    lock_token: []const u8,
    held: bool = true,

    pub fn release(self: *UserOwnershipLock) void {
        if (!self.held) return;

        const record = readRecordOwned(self.allocator, self.path) catch {
            self.held = false;
            return;
        };
        defer self.allocator.free(record.owner_id);
        defer self.allocator.free(record.lock_token);

        if (std.mem.eql(u8, record.owner_id, self.owner_id) and std.mem.eql(u8, record.lock_token, self.lock_token)) {
            std.fs.deleteFileAbsolute(self.path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => {},
            };
        }
        self.held = false;
    }

    pub fn deinit(self: *UserOwnershipLock) void {
        self.release();
        self.allocator.free(self.path);
        self.allocator.free(self.lock_token);
    }
};

var owner_id_mutex = std.Thread.Mutex{};
var owner_id_cache: [128]u8 = undefined;
var owner_id_cache_len: usize = 0;
var owner_id_cache_ready: bool = false;

pub fn resolveOwnerId(allocator: std.mem.Allocator) ![]u8 {
    if (try readTrimmedEnvVar(allocator, "NULLCLAW_OWNER_ID")) |value| return value;
    if (try readTrimmedEnvVar(allocator, "HOSTNAME")) |value| return value;

    owner_id_mutex.lock();
    defer owner_id_mutex.unlock();
    if (owner_id_cache_ready) {
        return allocator.dupe(u8, owner_id_cache[0..owner_id_cache_len]);
    }

    const pid: u32 = if (builtin.os.tag == .linux)
        @intCast(std.os.linux.getpid())
    else if (builtin.os.tag == .macos)
        @intCast(std.c.getpid())
    else
        0;
    const ts: i64 = std.time.timestamp();
    const cached = try std.fmt.bufPrint(&owner_id_cache, "pid-{d}-{d}", .{ pid, ts });
    owner_id_cache_len = cached.len;
    owner_id_cache_ready = true;
    return allocator.dupe(u8, owner_id_cache[0..owner_id_cache_len]);
}

pub fn acquireUserOwnershipLock(
    allocator: std.mem.Allocator,
    user_root: []const u8,
    owner_id: []const u8,
    lease_secs: u64,
) !UserOwnershipLock {
    if (owner_id.len == 0) return error.InvalidOwnerId;

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ user_root, LOCK_FILE_NAME });
    errdefer allocator.free(lock_path);

    const now = std.time.timestamp();
    const lease: i64 = @intCast(@max(@as(u64, 1), lease_secs));
    const expires_at = now + lease;
    const lock_token = try generateLockToken(allocator);
    errdefer allocator.free(lock_token);

    if (try createRecordExclusive(lock_path, owner_id, expires_at, lock_token)) {
        return .{
            .allocator = allocator,
            .path = lock_path,
            .owner_id = owner_id,
            .lock_token = lock_token,
            .held = true,
        };
    }

    const existing = readRecordOwned(allocator, lock_path) catch null;
    defer if (existing) |record| allocator.free(record.owner_id);
    defer if (existing) |record| allocator.free(record.lock_token);

    if (existing) |record| {
        if (std.mem.eql(u8, record.owner_id, owner_id)) {
            try writeRecord(lock_path, owner_id, expires_at, lock_token);
            return .{
                .allocator = allocator,
                .path = lock_path,
                .owner_id = owner_id,
                .lock_token = lock_token,
                .held = true,
            };
        }
        if (record.expires_at > now) return error.LockHeld;
    }

    std.fs.deleteFileAbsolute(lock_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };

    if (try createRecordExclusive(lock_path, owner_id, expires_at, lock_token)) {
        return .{
            .allocator = allocator,
            .path = lock_path,
            .owner_id = owner_id,
            .lock_token = lock_token,
            .held = true,
        };
    }

    const after_race = readRecordOwned(allocator, lock_path) catch null;
    defer if (after_race) |record| allocator.free(record.owner_id);
    defer if (after_race) |record| allocator.free(record.lock_token);
    if (after_race) |record| {
        if (std.mem.eql(u8, record.owner_id, owner_id)) {
            try writeRecord(lock_path, owner_id, expires_at, lock_token);
            return .{
                .allocator = allocator,
                .path = lock_path,
                .owner_id = owner_id,
                .lock_token = lock_token,
                .held = true,
            };
        }
    }

    return error.LockHeld;
}

fn readTrimmedEnvVar(allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    const raw = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn createRecordExclusive(path: []const u8, owner_id: []const u8, expires_at: i64, lock_token: []const u8) !bool {
    const file = std.fs.createFileAbsolute(path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => return err,
    };
    defer file.close();
    try writeRecordToFile(file, owner_id, expires_at, lock_token);
    return true;
}

fn writeRecord(path: []const u8, owner_id: []const u8, expires_at: i64, lock_token: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try writeRecordToFile(file, owner_id, expires_at, lock_token);
}

fn writeRecordToFile(file: std.fs.File, owner_id: []const u8, expires_at: i64, lock_token: []const u8) !void {
    var buf: [384]u8 = undefined;
    const payload = try std.fmt.bufPrint(&buf, "{s}\n{d}\n{s}\n", .{ owner_id, expires_at, lock_token });
    try file.writeAll(payload);
}

fn generateLockToken(allocator: std.mem.Allocator) ![]u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var random_bytes: [20]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var out: [20]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        out[i] = alphabet[@as(usize, b) % alphabet.len];
    }
    return allocator.dupe(u8, out[0..]);
}

fn readRecordOwned(allocator: std.mem.Allocator, path: []const u8) !LockRecord {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, LOCK_FILE_MAX_BYTES);
    defer allocator.free(content);
    return parseRecord(allocator, content);
}

fn parseRecord(allocator: std.mem.Allocator, content: []const u8) !LockRecord {
    const first_nl = std.mem.indexOfScalar(u8, content, '\n') orelse return error.InvalidLockRecord;
    const owner_raw = std.mem.trim(u8, content[0..first_nl], " \t\r");
    if (owner_raw.len == 0) return error.InvalidLockRecord;

    const after_first = content[first_nl + 1 ..];
    const second_nl = std.mem.indexOfScalar(u8, after_first, '\n') orelse return error.InvalidLockRecord;
    const expires_raw = std.mem.trim(u8, after_first[0..second_nl], " \t\r\n");
    if (expires_raw.len == 0) return error.InvalidLockRecord;

    const after_second = after_first[second_nl + 1 ..];
    const token_raw = if (std.mem.indexOfScalar(u8, after_second, '\n')) |third_nl|
        std.mem.trim(u8, after_second[0..third_nl], " \t\r\n")
    else
        std.mem.trim(u8, after_second, " \t\r\n");

    const expires_at = std.fmt.parseInt(i64, expires_raw, 10) catch return error.InvalidLockRecord;
    return .{
        .owner_id = try allocator.dupe(u8, owner_raw),
        .expires_at = expires_at,
        .lock_token = try allocator.dupe(u8, token_raw),
    };
}

test "acquireUserOwnershipLock blocks other owner while active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("user_a");
    const user_root = try tmp.dir.realpathAlloc(std.testing.allocator, "user_a");
    defer std.testing.allocator.free(user_root);

    var lock_a = try acquireUserOwnershipLock(std.testing.allocator, user_root, "pod-a", 120);
    defer lock_a.deinit();

    try std.testing.expectError(
        error.LockHeld,
        acquireUserOwnershipLock(std.testing.allocator, user_root, "pod-b", 120),
    );
}

test "acquireUserOwnershipLock reclaims expired lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("user_b");
    const user_root = try tmp.dir.realpathAlloc(std.testing.allocator, "user_b");
    defer std.testing.allocator.free(user_root);

    const lock_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ user_root, LOCK_FILE_NAME });
    defer std.testing.allocator.free(lock_path);
    try writeRecord(lock_path, "old-owner", std.time.timestamp() - 10, "legacy-token");

    var lock_b = try acquireUserOwnershipLock(std.testing.allocator, user_root, "pod-b", 120);
    defer lock_b.deinit();

    const record = try readRecordOwned(std.testing.allocator, lock_path);
    defer std.testing.allocator.free(record.owner_id);
    defer std.testing.allocator.free(record.lock_token);
    try std.testing.expectEqualStrings("pod-b", record.owner_id);
}

test "acquireUserOwnershipLock allows same owner refresh" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("user_c");
    const user_root = try tmp.dir.realpathAlloc(std.testing.allocator, "user_c");
    defer std.testing.allocator.free(user_root);

    var lock_first = try acquireUserOwnershipLock(std.testing.allocator, user_root, "pod-a", 120);
    defer lock_first.deinit();
    var lock_second = try acquireUserOwnershipLock(std.testing.allocator, user_root, "pod-a", 120);
    defer lock_second.deinit();
}

test "release from stale same-owner lock does not drop active lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("user_d");
    const user_root = try tmp.dir.realpathAlloc(std.testing.allocator, "user_d");
    defer std.testing.allocator.free(user_root);

    var lock_first = try acquireUserOwnershipLock(std.testing.allocator, user_root, "pod-a", 120);
    defer lock_first.deinit();
    var lock_second = try acquireUserOwnershipLock(std.testing.allocator, user_root, "pod-a", 120);
    defer lock_second.deinit();

    lock_first.release();
    try std.testing.expectError(
        error.LockHeld,
        acquireUserOwnershipLock(std.testing.allocator, user_root, "pod-b", 120),
    );
}

test "resolveOwnerId returns non-empty value" {
    const owner = try resolveOwnerId(std.testing.allocator);
    defer std.testing.allocator.free(owner);
    try std.testing.expect(owner.len > 0);
}
