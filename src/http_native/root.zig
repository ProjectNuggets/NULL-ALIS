const std = @import("std");
pub const types = @import("types.zig");

pub const TransportMode = types.TransportMode;
pub const TransportSubsystem = types.TransportSubsystem;
pub const PoolConfig = types.PoolConfig;
pub const ResolverConfig = types.ResolverConfig;
pub const RequestOptions = types.RequestOptions;
pub const Response = types.Response;
pub const TransportConfig = types.TransportConfig;

pub const NotImplementedError = error{NotImplemented};

pub const TransportManager = struct {
    allocator: std.mem.Allocator,
    config: TransportConfig,

    pub fn init(allocator: std.mem.Allocator, config: TransportConfig) TransportManager {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *TransportManager) void {
        _ = self;
    }

    pub fn request(self: *TransportManager, allocator: std.mem.Allocator, options: RequestOptions) !Response {
        _ = self;
        _ = allocator;
        _ = options;
        return NotImplementedError.NotImplemented;
    }
};

test "transport manager init is stable" {
    var manager = TransportManager.init(std.testing.allocator, .{});
    defer manager.deinit();
    try std.testing.expectEqual(TransportMode.native_preferred, manager.config.mode);
}
