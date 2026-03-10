const std = @import("std");
const zaki_state = @import("../zaki_state.zig");

pub const DeliveryResolveError = error{
    MissingTenantContext,
    NotConnected,
    MissingCredential,
    InvalidTarget,
    UnsupportedChannel,
};

pub const DeliveryTenantContext = struct {
    state_mgr: ?*zaki_state.Manager = null,
    numeric_user_id: ?i64 = null,
    expect_postgres_state: bool = false,
};

pub const DeliveryResolveInput = struct {
    channel: []const u8,
    tenant_ctx: DeliveryTenantContext = .{},
    user_root: ?[]const u8 = null,
    account_id_hint: ?[]const u8 = null,
    target_hint: ?[]const u8 = null,
};

pub const DeliveryResolvedContext = struct {
    channel: []const u8,
    connected: bool = false,
    account_id: ?[]u8 = null,
    target_id: ?[]u8 = null,
    credential_token: ?[]u8 = null,
    data_source: []const u8 = "context_missing",
    context_incomplete: bool = false,

    pub fn deinit(self: *DeliveryResolvedContext, allocator: std.mem.Allocator) void {
        if (self.account_id) |value| allocator.free(value);
        if (self.target_id) |value| allocator.free(value);
        if (self.credential_token) |value| allocator.free(value);
    }
};

pub fn requireConnectedTarget(ctx: *const DeliveryResolvedContext) DeliveryResolveError!void {
    if (ctx.target_id == null) return error.InvalidTarget;
    if (!ctx.connected) return error.NotConnected;
}

pub fn requireCredential(ctx: *const DeliveryResolvedContext) DeliveryResolveError![]const u8 {
    const token = ctx.credential_token orelse return error.MissingCredential;
    if (token.len == 0) return error.MissingCredential;
    return token;
}

pub fn parseResolvedTargetChatId(ctx: *const DeliveryResolvedContext) DeliveryResolveError!i64 {
    const raw = ctx.target_id orelse return error.InvalidTarget;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.fmt.parseInt(i64, trimmed, 10) catch error.InvalidTarget;
}
