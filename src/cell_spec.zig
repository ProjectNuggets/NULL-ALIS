const std = @import("std");

pub const CellTemplate = struct {
    namespace: []const u8 = "default",
    service_port: u16 = 3000,
    pod_prefix: []const u8 = "nullalis-cell",
    service_prefix: []const u8 = "nullalis-cell",
};

pub const DesiredCellSpec = struct {
    user_id: []u8,
    namespace: []u8,
    pod_name: []u8,
    service_name: []u8,
    advertise_url: []u8,
    service_port: u16,

    pub fn deinit(self: *DesiredCellSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.user_id);
        allocator.free(self.namespace);
        allocator.free(self.pod_name);
        allocator.free(self.service_name);
        allocator.free(self.advertise_url);
        self.* = undefined;
    }
};

fn appendSanitizedUserId(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, user_id: []const u8) !void {
    var wrote_any = false;
    var last_dash = false;
    for (user_id) |c| {
        var mapped: u8 = c;
        if (mapped >= 'A' and mapped <= 'Z') mapped = mapped + ('a' - 'A');
        const is_alnum = (mapped >= 'a' and mapped <= 'z') or (mapped >= '0' and mapped <= '9');
        if (is_alnum) {
            try out.append(allocator, mapped);
            wrote_any = true;
            last_dash = false;
            continue;
        }
        if (!wrote_any or last_dash) continue;
        try out.append(allocator, '-');
        last_dash = true;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    if (out.items.len == 0) {
        try out.appendSlice(allocator, "user");
    }
}

fn buildDnsLabel(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    user_id: []const u8,
) ![]u8 {
    var sanitized: std.ArrayListUnmanaged(u8) = .empty;
    defer sanitized.deinit(allocator);
    try appendSanitizedUserId(&sanitized, allocator, user_id);

    const max_total_len: usize = 63;
    const reserved = prefix.len + 1;
    if (reserved >= max_total_len) return error.InvalidCellSpecPrefix;

    if (reserved + sanitized.items.len <= max_total_len) {
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, sanitized.items });
    }

    const hash_value = std.hash.Wyhash.hash(0, user_id);
    const hash_suffix = try std.fmt.allocPrint(allocator, "{x:0>8}", .{hash_value & 0xffffffff});
    defer allocator.free(hash_suffix);

    const max_user_len = max_total_len - reserved - 1 - hash_suffix.len;
    const trimmed_len = @min(max_user_len, sanitized.items.len);
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ prefix, sanitized.items[0..trimmed_len], hash_suffix });
}

pub fn desiredSpec(
    allocator: std.mem.Allocator,
    template: CellTemplate,
    user_id: []const u8,
) !DesiredCellSpec {
    const owned_user_id = try allocator.dupe(u8, user_id);
    errdefer allocator.free(owned_user_id);
    const owned_namespace = try allocator.dupe(u8, template.namespace);
    errdefer allocator.free(owned_namespace);
    const pod_name = try buildDnsLabel(allocator, template.pod_prefix, user_id);
    errdefer allocator.free(pod_name);
    const service_name = try buildDnsLabel(allocator, template.service_prefix, user_id);
    errdefer allocator.free(service_name);
    const advertise_url = try std.fmt.allocPrint(
        allocator,
        "http://{s}.{s}.svc.cluster.local:{d}",
        .{ service_name, template.namespace, template.service_port },
    );
    errdefer allocator.free(advertise_url);

    return .{
        .user_id = owned_user_id,
        .namespace = owned_namespace,
        .pod_name = pod_name,
        .service_name = service_name,
        .advertise_url = advertise_url,
        .service_port = template.service_port,
    };
}

test "desiredSpec builds stable service dns from user id" {
    var spec = try desiredSpec(std.testing.allocator, .{
        .namespace = "nullalis-cells-standard",
        .service_port = 3000,
    }, "42");
    defer spec.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("42", spec.user_id);
    try std.testing.expectEqualStrings("nullalis-cells-standard", spec.namespace);
    try std.testing.expectEqualStrings("nullalis-cell-42", spec.pod_name);
    try std.testing.expectEqualStrings("nullalis-cell-42", spec.service_name);
    try std.testing.expectEqualStrings(
        "http://nullalis-cell-42.nullalis-cells-standard.svc.cluster.local:3000",
        spec.advertise_url,
    );
}

test "desiredSpec sanitizes and truncates long user ids" {
    var spec = try desiredSpec(std.testing.allocator, .{}, "User.With/Complex+Characters-And-A-Very-Long-Identifier-That-Keeps-Going");
    defer spec.deinit(std.testing.allocator);

    try std.testing.expect(spec.pod_name.len <= 63);
    try std.testing.expect(spec.service_name.len <= 63);
    try std.testing.expect(std.mem.startsWith(u8, spec.pod_name, "nullalis-cell-"));
    try std.testing.expect(std.mem.indexOfScalar(u8, spec.pod_name, '/') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, spec.service_name, '+') == null);
}
