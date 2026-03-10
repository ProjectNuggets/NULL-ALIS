const std = @import("std");
const types = @import("../types.zig");

const TelegramState = struct {
    connected: ?bool = null,
    account_id: ?[]u8 = null,
    chat_id: ?i64 = null,

    fn deinit(self: *TelegramState, allocator: std.mem.Allocator) void {
        if (self.account_id) |value| allocator.free(value);
    }
};

pub fn resolveTelegramDeliveryContext(
    allocator: std.mem.Allocator,
    input: types.DeliveryResolveInput,
) anyerror!types.DeliveryResolvedContext {
    if (input.tenant_ctx.expect_postgres_state and (input.tenant_ctx.state_mgr == null or input.tenant_ctx.numeric_user_id == null) and input.user_root == null) {
        return error.MissingTenantContext;
    }

    var out = types.DeliveryResolvedContext{
        .channel = "telegram",
        .data_source = if (input.tenant_ctx.expect_postgres_state) "context_missing" else "file_fallback",
        .context_incomplete = input.tenant_ctx.expect_postgres_state and (input.tenant_ctx.state_mgr == null or input.tenant_ctx.numeric_user_id == null),
    };
    errdefer out.deinit(allocator);

    if (input.target_hint) |hint| {
        const target_text = std.mem.trim(u8, hint, " \t\r\n");
        if (target_text.len == 0) return error.InvalidTarget;
        _ = std.fmt.parseInt(i64, target_text, 10) catch return error.InvalidTarget;
        out.target_id = try allocator.dupe(u8, target_text);
    }

    var state = try resolveState(allocator, input);
    defer state.deinit(allocator);

    if (out.account_id == null) {
        if (state.account_id) |value| {
            out.account_id = try allocator.dupe(u8, value);
        } else if (input.account_id_hint) |hint| {
            const trimmed = std.mem.trim(u8, hint, " \t\r\n");
            if (trimmed.len > 0) out.account_id = try allocator.dupe(u8, trimmed);
        } else {
            out.account_id = try allocator.dupe(u8, "main");
        }
    }

    if (out.target_id == null) {
        if (state.chat_id) |chat_id| {
            out.target_id = try std.fmt.allocPrint(allocator, "{d}", .{chat_id});
        }
    }

    out.connected = blk: {
        if (out.target_id != null) break :blk true;
        if (state.connected) |connected| break :blk connected;
        break :blk false;
    };

    if (resolveCredential(allocator, input)) |token| {
        out.credential_token = token;
    } else |_| {}

    if (out.target_id != null) {
        const chat_id_text = out.target_id.?;
        const parsed_chat_id = std.fmt.parseInt(i64, std.mem.trim(u8, chat_id_text, " \t\r\n"), 10) catch return error.InvalidTarget;
        if (parsed_chat_id == 0) return error.InvalidTarget;
    }

    out.data_source = stateSourceLabel(input);
    return out;
}

fn stateSourceLabel(input: types.DeliveryResolveInput) []const u8 {
    if (input.tenant_ctx.state_mgr != null and input.tenant_ctx.numeric_user_id != null) return "postgres";
    if (input.user_root != null) return "file_fallback";
    return "context_missing";
}

fn resolveState(
    allocator: std.mem.Allocator,
    input: types.DeliveryResolveInput,
) anyerror!TelegramState {
    if (input.tenant_ctx.state_mgr) |state_mgr| {
        if (input.tenant_ctx.numeric_user_id) |numeric_user_id| {
            const raw = state_mgr.getTelegramStateJson(allocator, numeric_user_id) catch return TelegramState{};
            defer allocator.free(raw);
            return try parseTelegramStateJson(allocator, raw);
        }
    }

    if (input.user_root) |user_root| {
        const path = try std.fmt.allocPrint(allocator, "{s}/channel_state.json", .{user_root});
        defer allocator.free(path);
        const file = std.fs.openFileAbsolute(path, .{}) catch return TelegramState{};
        defer file.close();
        const raw = try file.readToEndAlloc(allocator, 128 * 1024);
        defer allocator.free(raw);
        return try parseTelegramStateJson(allocator, raw);
    }

    return TelegramState{};
}

fn resolveCredential(
    allocator: std.mem.Allocator,
    input: types.DeliveryResolveInput,
) anyerror![]u8 {
    if (input.tenant_ctx.state_mgr) |state_mgr| {
        if (input.tenant_ctx.numeric_user_id) |numeric_user_id| {
            const secret = state_mgr.getSecret(allocator, numeric_user_id, "telegram_bot_token") catch null;
            if (secret) |token_owned| {
                errdefer allocator.free(token_owned);
                const trimmed = std.mem.trim(u8, token_owned, " \t\r\n");
                if (trimmed.len > 0) {
                    if (trimmed.ptr == token_owned.ptr and trimmed.len == token_owned.len) {
                        return token_owned;
                    }
                    const dupe = try allocator.dupe(u8, trimmed);
                    allocator.free(token_owned);
                    return dupe;
                }
                allocator.free(token_owned);
            }
        }
    }

    if (input.user_root) |user_root| {
        const path = try std.fmt.allocPrint(allocator, "{s}/secrets/telegram_bot_token", .{user_root});
        defer allocator.free(path);
        const file = std.fs.openFileAbsolute(path, .{}) catch return error.MissingCredential;
        defer file.close();
        const raw = try file.readToEndAlloc(allocator, 32 * 1024);
        errdefer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return error.MissingCredential;
        if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;
        const dupe = try allocator.dupe(u8, trimmed);
        allocator.free(raw);
        return dupe;
    }

    return error.MissingCredential;
}

fn parseTelegramStateJson(allocator: std.mem.Allocator, raw: []const u8) anyerror!TelegramState {
    var state = TelegramState{};
    errdefer state.deinit(allocator);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return state;

    const telegram_obj = blk: {
        if (parsed.value.object.get("telegram")) |telegram_value| {
            if (telegram_value == .object) break :blk telegram_value.object;
        }
        break :blk parsed.value.object;
    };

    if (telegram_obj.get("connected")) |connected_value| {
        if (connected_value == .bool) state.connected = connected_value.bool;
    }
    if (telegram_obj.get("account_id")) |account_value| {
        if (account_value == .string and account_value.string.len > 0) {
            state.account_id = try allocator.dupe(u8, account_value.string);
        }
    }
    if (telegram_obj.get("chat_id")) |chat_value| {
        state.chat_id = switch (chat_value) {
            .integer => chat_value.integer,
            .string => try std.fmt.parseInt(i64, std.mem.trim(u8, chat_value.string, " \t\r\n"), 10),
            else => null,
        };
    }

    return state;
}

test "telegram resolver fallback reads channel state and token files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("tenant/secrets");

    const user_root = try tmp.dir.realpathAlloc(std.testing.allocator, "tenant");
    defer std.testing.allocator.free(user_root);

    const state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/channel_state.json", .{user_root});
    defer std.testing.allocator.free(state_path);
    const state_file = try std.fs.createFileAbsolute(state_path, .{ .truncate = true });
    defer state_file.close();
    try state_file.writeAll("{\"telegram\":{\"connected\":true,\"account_id\":\"main\",\"chat_id\":-100777}}");

    const token_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/secrets/telegram_bot_token", .{user_root});
    defer std.testing.allocator.free(token_path);
    const token_file = try std.fs.createFileAbsolute(token_path, .{ .truncate = true });
    defer token_file.close();
    try token_file.writeAll("123456:ABCDEF\n");

    var resolved = try resolveTelegramDeliveryContext(std.testing.allocator, .{
        .channel = "telegram",
        .tenant_ctx = .{},
        .user_root = user_root,
    });
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expect(resolved.connected);
    try std.testing.expectEqualStrings("main", resolved.account_id.?);
    try std.testing.expectEqualStrings("-100777", resolved.target_id.?);
    try std.testing.expectEqualStrings("123456:ABCDEF", resolved.credential_token.?);
    try std.testing.expectEqualStrings("file_fallback", resolved.data_source);
    try std.testing.expect(!resolved.context_incomplete);
}

test "telegram resolver uses target hint precedence and validates target" {
    var resolved = try resolveTelegramDeliveryContext(std.testing.allocator, .{
        .channel = "telegram",
        .tenant_ctx = .{},
        .target_hint = "1110331014",
        .account_id_hint = "hint-account",
    });
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expect(resolved.connected);
    try std.testing.expectEqualStrings("1110331014", resolved.target_id.?);
    try std.testing.expectEqualStrings("hint-account", resolved.account_id.?);
    try std.testing.expectEqualStrings("context_missing", resolved.data_source);
}

test "telegram resolver requires tenant context when postgres expected and no fallback path" {
    try std.testing.expectError(error.MissingTenantContext, resolveTelegramDeliveryContext(std.testing.allocator, .{
        .channel = "telegram",
        .tenant_ctx = .{
            .expect_postgres_state = true,
        },
    }));
}
