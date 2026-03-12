const std = @import("std");

pub const IdentityKeys = struct {
    principal_key: []u8,
    scope_key: []u8,
    thread_key: ?[]u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.principal_key);
        allocator.free(self.scope_key);
        if (self.thread_key) |value| allocator.free(value);
    }
};

pub const BuildError = error{
    EmptyPrincipal,
    EmptyScope,
    OutOfMemory,
};

fn trimNonEmpty(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

pub fn build(
    allocator: std.mem.Allocator,
    channel: []const u8,
    principal_raw: []const u8,
    scope_raw: []const u8,
    thread_raw: ?[]const u8,
) BuildError!IdentityKeys {
    const principal = trimNonEmpty(principal_raw) orelse return error.EmptyPrincipal;
    const scope = trimNonEmpty(scope_raw) orelse return error.EmptyScope;
    const principal_key = try std.fmt.allocPrint(allocator, "{s}:principal:{s}", .{ channel, principal });
    errdefer allocator.free(principal_key);
    const scope_key = try std.fmt.allocPrint(allocator, "{s}:scope:{s}", .{ channel, scope });
    errdefer allocator.free(scope_key);
    const thread_key = if (thread_raw) |thread_value| blk: {
        const trimmed_thread = trimNonEmpty(thread_value) orelse break :blk null;
        break :blk try std.fmt.allocPrint(allocator, "{s}:thread:{s}", .{ channel, trimmed_thread });
    } else null;
    return .{
        .principal_key = principal_key,
        .scope_key = scope_key,
        .thread_key = thread_key,
    };
}

test "build creates deterministic principal and scope keys" {
    const allocator = std.testing.allocator;
    var keys = try build(allocator, "telegram", "123", "456", null);
    defer keys.deinit(allocator);
    try std.testing.expectEqualStrings("telegram:principal:123", keys.principal_key);
    try std.testing.expectEqualStrings("telegram:scope:456", keys.scope_key);
    try std.testing.expect(keys.thread_key == null);
}

test "build includes thread key when present" {
    const allocator = std.testing.allocator;
    var keys = try build(allocator, "slack", "U1", "C1", "1700.22");
    defer keys.deinit(allocator);
    try std.testing.expectEqualStrings("slack:thread:1700.22", keys.thread_key.?);
}

test "build rejects empty principal or scope" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.EmptyPrincipal, build(allocator, "telegram", " ", "1", null));
    try std.testing.expectError(error.EmptyScope, build(allocator, "telegram", "1", " ", null));
}
