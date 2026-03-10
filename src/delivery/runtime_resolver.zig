const std = @import("std");
const telegram_adapter = @import("adapters/telegram_adapter.zig");
const types = @import("types.zig");

pub const DeliveryResolveInput = types.DeliveryResolveInput;
pub const DeliveryResolvedContext = types.DeliveryResolvedContext;
pub const DeliveryResolveError = types.DeliveryResolveError;
pub const DeliveryTenantContext = types.DeliveryTenantContext;

pub fn resolveRuntimeDeliveryContext(
    allocator: std.mem.Allocator,
    input: DeliveryResolveInput,
) anyerror!DeliveryResolvedContext {
    if (std.ascii.eqlIgnoreCase(input.channel, "telegram")) {
        return telegram_adapter.resolveTelegramDeliveryContext(allocator, input);
    }
    return error.UnsupportedChannel;
}

pub fn requireConnectedTarget(ctx: *const DeliveryResolvedContext) DeliveryResolveError!void {
    return types.requireConnectedTarget(ctx);
}

pub fn requireCredential(ctx: *const DeliveryResolvedContext) DeliveryResolveError![]const u8 {
    return types.requireCredential(ctx);
}

pub fn parseResolvedTargetChatId(ctx: *const DeliveryResolvedContext) DeliveryResolveError!i64 {
    return types.parseResolvedTargetChatId(ctx);
}

test "runtime resolver rejects unsupported channels explicitly" {
    try std.testing.expectError(error.UnsupportedChannel, resolveRuntimeDeliveryContext(std.testing.allocator, .{
        .channel = "slack",
    }));
}
