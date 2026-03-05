const std = @import("std");

const MAX_QUEUE: usize = 128;

pub const WakeRequest = struct {
    user_id: ?[]u8 = null,
    reason: []u8,
    requested_at_s: i64,

    pub fn deinit(self: *WakeRequest) void {
        if (self.user_id) |value| std.heap.c_allocator.free(value);
        std.heap.c_allocator.free(self.reason);
        self.* = .{
            .reason = "",
            .requested_at_s = 0,
        };
    }
};

const WakeQueue = struct {
    mutex: std.Thread.Mutex = .{},
    head: usize = 0,
    len: usize = 0,
    dropped_total: u64 = 0,
    coalesced_total: u64 = 0,
    items: [MAX_QUEUE]WakeRequest = [_]WakeRequest{.{
        .reason = "",
        .requested_at_s = 0,
    }} ** MAX_QUEUE,
};

var g_queue = WakeQueue{};

fn queueIndex(offset: usize) usize {
    return (g_queue.head + offset) % MAX_QUEUE;
}

fn dropOldestLocked() void {
    if (g_queue.len == 0) return;
    const idx = g_queue.head;
    var req = g_queue.items[idx];
    req.deinit();
    g_queue.items[idx] = .{
        .reason = "",
        .requested_at_s = 0,
    };
    g_queue.head = (g_queue.head + 1) % MAX_QUEUE;
    g_queue.len -= 1;
    g_queue.dropped_total += 1;
}

fn wakeTargetsEqual(a: WakeRequest, b_user_id: ?[]const u8) bool {
    if (a.user_id == null and b_user_id == null) return true;
    if (a.user_id == null or b_user_id == null) return false;
    return std.mem.eql(u8, a.user_id.?, b_user_id.?);
}

pub fn enqueue(user_id_opt: ?[]const u8, reason: []const u8) !void {
    const reason_owned = try std.heap.c_allocator.dupe(u8, reason);
    errdefer std.heap.c_allocator.free(reason_owned);
    const user_id_owned = if (user_id_opt) |value|
        try std.heap.c_allocator.dupe(u8, value)
    else
        null;
    errdefer if (user_id_owned) |value| std.heap.c_allocator.free(value);

    g_queue.mutex.lock();
    defer g_queue.mutex.unlock();

    var i: usize = 0;
    while (i < g_queue.len) : (i += 1) {
        const idx = queueIndex(i);
        if (!wakeTargetsEqual(g_queue.items[idx], user_id_owned)) continue;
        std.heap.c_allocator.free(g_queue.items[idx].reason);
        g_queue.items[idx].reason = reason_owned;
        g_queue.items[idx].requested_at_s = std.time.timestamp();
        if (user_id_owned) |value| std.heap.c_allocator.free(value);
        g_queue.coalesced_total += 1;
        return;
    }

    if (g_queue.len >= MAX_QUEUE) {
        dropOldestLocked();
    }

    const insert_idx = queueIndex(g_queue.len);
    g_queue.items[insert_idx] = .{
        .user_id = user_id_owned,
        .reason = reason_owned,
        .requested_at_s = std.time.timestamp(),
    };
    g_queue.len += 1;
}

pub fn dequeue() ?WakeRequest {
    g_queue.mutex.lock();
    defer g_queue.mutex.unlock();

    if (g_queue.len == 0) return null;

    const idx = g_queue.head;
    const out = g_queue.items[idx];
    g_queue.items[idx] = .{
        .reason = "",
        .requested_at_s = 0,
    };
    g_queue.head = (g_queue.head + 1) % MAX_QUEUE;
    g_queue.len -= 1;
    return out;
}

pub fn pendingCount() usize {
    g_queue.mutex.lock();
    defer g_queue.mutex.unlock();
    return g_queue.len;
}

pub fn droppedCount() u64 {
    g_queue.mutex.lock();
    defer g_queue.mutex.unlock();
    return g_queue.dropped_total;
}

pub fn coalescedCount() u64 {
    g_queue.mutex.lock();
    defer g_queue.mutex.unlock();
    return g_queue.coalesced_total;
}

pub fn clearForTest() void {
    if (!@import("builtin").is_test) return;
    while (dequeue()) |req| {
        var mutable_req = req;
        mutable_req.deinit();
    }
    g_queue.mutex.lock();
    defer g_queue.mutex.unlock();
    g_queue.head = 0;
    g_queue.len = 0;
    g_queue.dropped_total = 0;
    g_queue.coalesced_total = 0;
}

test "heartbeat wake queue enqueue and dequeue preserves order" {
    clearForTest();
    try enqueue("1", "wake-one");
    try enqueue("2", "wake-two");

    var first = dequeue().?;
    defer first.deinit();
    var second = dequeue().?;
    defer second.deinit();

    try std.testing.expectEqualStrings("1", first.user_id.?);
    try std.testing.expectEqualStrings("wake-one", first.reason);
    try std.testing.expectEqualStrings("2", second.user_id.?);
    try std.testing.expectEqualStrings("wake-two", second.reason);
}

test "heartbeat wake queue supports broadcast wake request" {
    clearForTest();
    try enqueue(null, "wake-all");
    var req = dequeue().?;
    defer req.deinit();
    try std.testing.expect(req.user_id == null);
    try std.testing.expectEqualStrings("wake-all", req.reason);
}

test "heartbeat wake queue coalesces duplicate user wake requests" {
    clearForTest();
    try enqueue("42", "first");
    try enqueue("42", "second");
    try std.testing.expectEqual(@as(usize, 1), pendingCount());
    try std.testing.expectEqual(@as(u64, 1), coalescedCount());
    var req = dequeue().?;
    defer req.deinit();
    try std.testing.expectEqualStrings("42", req.user_id.?);
    try std.testing.expectEqualStrings("second", req.reason);
}

test "heartbeat wake queue coalesces duplicate broadcast wake requests" {
    clearForTest();
    try enqueue(null, "wake-a");
    try enqueue(null, "wake-b");
    try std.testing.expectEqual(@as(usize, 1), pendingCount());
    try std.testing.expectEqual(@as(u64, 1), coalescedCount());
    var req = dequeue().?;
    defer req.deinit();
    try std.testing.expect(req.user_id == null);
    try std.testing.expectEqualStrings("wake-b", req.reason);
}
