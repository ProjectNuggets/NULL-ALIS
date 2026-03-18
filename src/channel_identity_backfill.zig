const std = @import("std");
const channel_identity_key = @import("channel_identity_key.zig");
const inbound_canonicalizer = @import("inbound_canonicalizer.zig");
const zaki_state = @import("zaki_state.zig");

pub const BackfillRow = struct {
    user_id: i64,
    account_id: []u8,
    chat_id: i64,
    reason: []u8,
    binding_id: ?[]u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.account_id);
        allocator.free(self.reason);
        if (self.binding_id) |value| allocator.free(value);
    }
};

pub const BackfillReport = struct {
    migrated: []BackfillRow,
    ambiguous: []BackfillRow,
    missing: []BackfillRow,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.migrated) |*row| row.deinit(allocator);
        for (self.ambiguous) |*row| row.deinit(allocator);
        for (self.missing) |*row| row.deinit(allocator);
        allocator.free(self.migrated);
        allocator.free(self.ambiguous);
        allocator.free(self.missing);
    }
};

fn appendRow(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(BackfillRow),
    user_id: i64,
    account_id: []const u8,
    chat_id: i64,
    reason: []const u8,
    binding_id: ?[]const u8,
) !void {
    try list.append(allocator, .{
        .user_id = user_id,
        .account_id = try allocator.dupe(u8, account_id),
        .chat_id = chat_id,
        .reason = try allocator.dupe(u8, reason),
        .binding_id = if (binding_id) |value| try allocator.dupe(u8, value) else null,
    });
}

fn buildTelegramCandidateKey(
    allocator: std.mem.Allocator,
    account_id: []const u8,
    chat_id: i64,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ account_id, chat_id });
}

pub fn runTelegramBackfill(
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state.Manager,
) !BackfillReport {
    const candidates = try state_mgr.listTelegramBackfillCandidates(allocator);
    defer {
        for (candidates) |*candidate| candidate.deinit(allocator);
        allocator.free(candidates);
    }

    var migrated: std.ArrayListUnmanaged(BackfillRow) = .empty;
    errdefer {
        for (migrated.items) |*row| row.deinit(allocator);
        migrated.deinit(allocator);
    }
    var ambiguous: std.ArrayListUnmanaged(BackfillRow) = .empty;
    errdefer {
        for (ambiguous.items) |*row| row.deinit(allocator);
        ambiguous.deinit(allocator);
    }
    var missing: std.ArrayListUnmanaged(BackfillRow) = .empty;
    errdefer {
        for (missing.items) |*row| row.deinit(allocator);
        missing.deinit(allocator);
    }

    var seen_user_by_key = std.StringHashMapUnmanaged(i64).empty;
    defer {
        var it = seen_user_by_key.iterator();
        while (it.next()) |entry| allocator.free(@constCast(entry.key_ptr.*));
        seen_user_by_key.deinit(allocator);
    }

    for (candidates) |candidate| {
        const account = std.mem.trim(u8, candidate.account_id, " \t\r\n");
        if (account.len == 0) {
            try appendRow(allocator, &missing, candidate.user_id, candidate.account_id, candidate.chat_id, "missing_account_id", null);
            continue;
        }
        if (candidate.chat_id <= 0) {
            try appendRow(allocator, &ambiguous, candidate.user_id, account, candidate.chat_id, "non_private_chat_scope", null);
            continue;
        }

        const key = try buildTelegramCandidateKey(allocator, account, candidate.chat_id);
        defer allocator.free(key);

        if (seen_user_by_key.get(key)) |existing_user_id| {
            if (existing_user_id != candidate.user_id) {
                try appendRow(allocator, &ambiguous, candidate.user_id, account, candidate.chat_id, "conflicting_candidate_users", null);
                continue;
            }
        } else {
            try seen_user_by_key.put(allocator, try allocator.dupe(u8, key), candidate.user_id);
        }

        var chat_buf: [32]u8 = undefined;
        const chat_text = try std.fmt.bufPrint(&chat_buf, "{d}", .{candidate.chat_id});
        var identity_keys = try channel_identity_key.build(
            allocator,
            "telegram",
            chat_text,
            chat_text,
            null,
        );
        defer identity_keys.deinit(allocator);

        const existing_user = try state_mgr.resolveUserByChannelIdentity(
            "telegram",
            account,
            identity_keys.principal_key,
            identity_keys.scope_key,
            null,
        );
        if (existing_user) |resolved_user_id| {
            if (resolved_user_id != candidate.user_id) {
                try appendRow(allocator, &ambiguous, candidate.user_id, account, candidate.chat_id, "binding_conflict_existing_user", null);
                continue;
            }
        }

        const binding_id = try state_mgr.upsertChannelIdentityBinding(
            allocator,
            candidate.user_id,
            "telegram",
            account,
            identity_keys.principal_key,
            identity_keys.scope_key,
            null,
            "direct",
            chat_text,
            "{\"source\":\"telegram_backfill\"}",
        );
        defer allocator.free(binding_id);
        inbound_canonicalizer.invalidateCacheForIdentity(.{
            .channel = "telegram",
            .account_id = account,
            .principal_key = identity_keys.principal_key,
            .scope_key = identity_keys.scope_key,
            .fallback_session_key = "",
        });
        try appendRow(allocator, &migrated, candidate.user_id, account, candidate.chat_id, "migrated", binding_id);
    }

    return .{
        .migrated = try migrated.toOwnedSlice(allocator),
        .ambiguous = try ambiguous.toOwnedSlice(allocator),
        .missing = try missing.toOwnedSlice(allocator),
    };
}

test "buildTelegramCandidateKey is deterministic" {
    const key = try buildTelegramCandidateKey(std.testing.allocator, "default", 12345);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("default:12345", key);
}

fn hasBackfillRow(
    rows: []const BackfillRow,
    account_id: []const u8,
    chat_id: i64,
    reason: []const u8,
) bool {
    for (rows) |row| {
        if (!std.mem.eql(u8, row.account_id, account_id)) continue;
        if (row.chat_id != chat_id) continue;
        if (!std.mem.eql(u8, row.reason, reason)) continue;
        return true;
    }
    return false;
}

fn countBindingsForAccount(
    allocator: std.mem.Allocator,
    mgr: *zaki_state.Manager,
    user_id: i64,
    account_id: []const u8,
) !usize {
    const bindings = try mgr.listChannelIdentityBindings(allocator, user_id, "telegram");
    defer {
        for (bindings) |*row| row.deinit(allocator);
        allocator.free(bindings);
    }
    var count: usize = 0;
    for (bindings) |row| {
        if (std.mem.eql(u8, row.account_id, account_id)) count += 1;
    }
    return count;
}

fn initTestStateManager() !zaki_state.Manager {
    return zaki_state.Manager.init(std.testing.allocator, .{}) catch |err| {
        const err_name = @errorName(err);
        if (std.mem.eql(u8, err_name, "PostgresNotEnabled") or
            std.mem.eql(u8, err_name, "MissingConnectionString"))
        {
            return error.SkipZigTest;
        }
        return err;
    };
}

test "runTelegramBackfill flags conflicting candidate users as ambiguous" {
    var mgr = try initTestStateManager();
    defer mgr.deinit();

    const account_id = "bf-ambiguous-conflict";
    const chat_id: i64 = 990201;
    try mgr.recordTelegramChat(9902011, account_id, chat_id);
    try mgr.recordTelegramChat(9902012, account_id, chat_id);

    var report = try runTelegramBackfill(std.testing.allocator, &mgr);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(hasBackfillRow(report.ambiguous, account_id, chat_id, "conflicting_candidate_users"));
}

test "runTelegramBackfill flags existing binding conflict as ambiguous" {
    var mgr = try initTestStateManager();
    defer mgr.deinit();

    const account_id = "bf-existing-binding-conflict";
    const chat_id: i64 = 990202;
    var chat_buf: [32]u8 = undefined;
    const chat_text = try std.fmt.bufPrint(&chat_buf, "{d}", .{chat_id});
    var identity_keys = try channel_identity_key.build(
        std.testing.allocator,
        "telegram",
        chat_text,
        chat_text,
        null,
    );
    defer identity_keys.deinit(std.testing.allocator);

    const owner_user_id: i64 = 9902021;
    const candidate_user_id: i64 = 9902022;
    const binding_id = try mgr.upsertChannelIdentityBinding(
        std.testing.allocator,
        owner_user_id,
        "telegram",
        account_id,
        identity_keys.principal_key,
        identity_keys.scope_key,
        null,
        "direct",
        chat_text,
        "{\"source\":\"backfill_test\"}",
    );
    defer std.testing.allocator.free(binding_id);

    try mgr.recordTelegramChat(candidate_user_id, account_id, chat_id);

    var report = try runTelegramBackfill(std.testing.allocator, &mgr);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(hasBackfillRow(report.ambiguous, account_id, chat_id, "binding_conflict_existing_user"));
}

test "runTelegramBackfill remains idempotent for migrated bindings" {
    var mgr = try initTestStateManager();
    defer mgr.deinit();

    const account_id = "bf-idempotent";
    const chat_id: i64 = 990203;
    const user_id: i64 = 9902031;
    try mgr.recordTelegramChat(user_id, account_id, chat_id);

    var first = try runTelegramBackfill(std.testing.allocator, &mgr);
    defer first.deinit(std.testing.allocator);
    var second = try runTelegramBackfill(std.testing.allocator, &mgr);
    defer second.deinit(std.testing.allocator);

    const binding_count = try countBindingsForAccount(std.testing.allocator, &mgr, user_id, account_id);
    try std.testing.expectEqual(@as(usize, 1), binding_count);
}
