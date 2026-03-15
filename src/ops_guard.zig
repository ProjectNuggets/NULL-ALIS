const std = @import("std");
const json_util = @import("json_util.zig");

const MAX_TRACKED_KEYS: usize = 4096;
const MAX_EVENTS: usize = 64;
const EVENT_FIELD_CAP: usize = 72;
const DEFAULT_DEDUPE_WINDOW_SECS: i64 = 120;
const DEFAULT_RATE_WINDOW_SECS: i64 = 300;
const DEFAULT_PROACTIVE_RATE_LIMIT_PER_WINDOW: u32 = 12;
const MIN_DEDUPE_WINDOW_SECS: i64 = 5;
const MAX_DEDUPE_WINDOW_SECS: i64 = 600;
const MIN_RATE_WINDOW_SECS: i64 = 30;
const MAX_RATE_WINDOW_SECS: i64 = 3600;
const MIN_RATE_LIMIT_PER_WINDOW: u32 = 1;
const MAX_RATE_LIMIT_PER_WINDOW: u32 = 1000;

const EventAction = enum {
    sent,
    blocked_rate,
    blocked_dedupe,
    blocked_cooldown,
    blocked_burst,
    send_error,
};

const Event = struct {
    ts_s: i64 = 0,
    action: EventAction = .sent,
    source_len: u8 = 0,
    source: [EVENT_FIELD_CAP]u8 = [_]u8{0} ** EVENT_FIELD_CAP,
    user_len: u8 = 0,
    user: [EVENT_FIELD_CAP]u8 = [_]u8{0} ** EVENT_FIELD_CAP,
    channel_len: u8 = 0,
    channel: [EVENT_FIELD_CAP]u8 = [_]u8{0} ** EVENT_FIELD_CAP,
    chat_len: u8 = 0,
    chat: [EVENT_FIELD_CAP]u8 = [_]u8{0} ** EVENT_FIELD_CAP,
    reason_len: u8 = 0,
    reason: [EVENT_FIELD_CAP]u8 = [_]u8{0} ** EVENT_FIELD_CAP,
};

const RateBucket = struct {
    window_start_s: i64,
    count: u32,
};

const GuardState = struct {
    mutex: std.Thread.Mutex = .{},
    dedupe: std.StringHashMapUnmanaged(i64) = .empty,
    rate: std.StringHashMapUnmanaged(RateBucket) = .empty,
    proactive_sent_total: u64 = 0,
    proactive_blocked_rate_total: u64 = 0,
    proactive_blocked_dedupe_total: u64 = 0,
    proactive_send_errors_total: u64 = 0,
    scheduler_executed_total: u64 = 0,
    scheduler_blocked_burst_total: u64 = 0,
    scheduler_blocked_cooldown_total: u64 = 0,
    events: [MAX_EVENTS]Event = [_]Event{.{}} ** MAX_EVENTS,
    event_head: usize = 0,
    event_len: usize = 0,
};

var g_state = GuardState{};
const GuardPolicy = struct {
    dedupe_window_secs: i64 = DEFAULT_DEDUPE_WINDOW_SECS,
    rate_window_secs: i64 = DEFAULT_RATE_WINDOW_SECS,
    proactive_rate_limit_per_window: u32 = DEFAULT_PROACTIVE_RATE_LIMIT_PER_WINDOW,
};
var g_policy = GuardPolicy{};

fn clampI64(value: i64, min: i64, max: i64) i64 {
    return std.math.clamp(value, min, max);
}

fn clampU32(value: u32, min: u32, max: u32) u32 {
    return std.math.clamp(value, min, max);
}

pub fn configureProactivePolicy(
    dedupe_window_secs: u32,
    rate_window_secs: u32,
    rate_limit_per_window: u32,
) void {
    g_state.mutex.lock();
    defer g_state.mutex.unlock();
    g_policy = .{
        .dedupe_window_secs = clampI64(@intCast(dedupe_window_secs), MIN_DEDUPE_WINDOW_SECS, MAX_DEDUPE_WINDOW_SECS),
        .rate_window_secs = clampI64(@intCast(rate_window_secs), MIN_RATE_WINDOW_SECS, MAX_RATE_WINDOW_SECS),
        .proactive_rate_limit_per_window = clampU32(rate_limit_per_window, MIN_RATE_LIMIT_PER_WINDOW, MAX_RATE_LIMIT_PER_WINDOW),
    };
}

fn copyField(dest: []u8, src: []const u8) u8 {
    const n: usize = @min(dest.len, src.len);
    if (n > 0) @memcpy(dest[0..n], src[0..n]);
    if (n < dest.len) @memset(dest[n..], 0);
    return @intCast(n);
}

fn proactiveUserKeyBuf(buf: []u8, user_id_opt: ?[]const u8, channel: []const u8, chat_id: []const u8) []const u8 {
    if (user_id_opt) |user_id| {
        return std.fmt.bufPrint(buf, "u:{s}", .{user_id}) catch "u:unknown";
    }
    return std.fmt.bufPrint(buf, "p:{s}:{s}", .{ channel, chat_id }) catch "p:unknown";
}

fn dedupeKeyBuf(buf: []u8, explicit: ?[]const u8, source: []const u8, channel: []const u8, chat_id: []const u8, content: []const u8) []const u8 {
    if (explicit) |value| return value;
    const hash = std.hash.Wyhash.hash(0, content);
    return std.fmt.bufPrint(buf, "{s}:{s}:{s}:{x}", .{ source, channel, chat_id, hash }) catch "dedupe";
}

fn putOwnedRateKeyLocked(key: []const u8, value: RateBucket) void {
    if (g_state.rate.getPtr(key)) |existing| {
        existing.* = value;
        return;
    }
    if (g_state.rate.count() >= MAX_TRACKED_KEYS) return;
    const key_copy = std.heap.c_allocator.dupe(u8, key) catch return;
    g_state.rate.put(std.heap.c_allocator, key_copy, value) catch {
        std.heap.c_allocator.free(key_copy);
    };
}

fn putOwnedDedupeKeyLocked(key: []const u8, now_s: i64) void {
    if (g_state.dedupe.getPtr(key)) |existing| {
        existing.* = now_s;
        return;
    }
    if (g_state.dedupe.count() >= MAX_TRACKED_KEYS) return;
    const key_copy = std.heap.c_allocator.dupe(u8, key) catch return;
    g_state.dedupe.put(std.heap.c_allocator, key_copy, now_s) catch {
        std.heap.c_allocator.free(key_copy);
    };
}

fn actionName(action: EventAction) []const u8 {
    return switch (action) {
        .sent => "sent",
        .blocked_rate => "blocked_rate",
        .blocked_dedupe => "blocked_dedupe",
        .blocked_cooldown => "blocked_cooldown",
        .blocked_burst => "blocked_burst",
        .send_error => "send_error",
    };
}

fn addEventLocked(now_s: i64, source: []const u8, user_id: []const u8, channel: []const u8, chat_id: []const u8, action: EventAction, reason: []const u8) void {
    const idx = g_state.event_head;
    g_state.events[idx].ts_s = now_s;
    g_state.events[idx].action = action;
    g_state.events[idx].source_len = copyField(&g_state.events[idx].source, source);
    g_state.events[idx].user_len = copyField(&g_state.events[idx].user, user_id);
    g_state.events[idx].channel_len = copyField(&g_state.events[idx].channel, channel);
    g_state.events[idx].chat_len = copyField(&g_state.events[idx].chat, chat_id);
    g_state.events[idx].reason_len = copyField(&g_state.events[idx].reason, reason);
    g_state.event_head = (g_state.event_head + 1) % MAX_EVENTS;
    if (g_state.event_len < MAX_EVENTS) g_state.event_len += 1;
}

pub fn isProactiveSource(source_opt: ?[]const u8) bool {
    const source = source_opt orelse return false;
    return std.mem.eql(u8, source, "cron") or
        std.mem.eql(u8, source, "heartbeat") or
        std.mem.eql(u8, source, "spawn") or
        std.mem.eql(u8, source, "tool") or
        std.mem.eql(u8, source, "reminder");
}

pub const ProactiveDecision = enum {
    allow,
    blocked_rate,
    blocked_dedupe,
};

pub fn allowProactive(
    source: []const u8,
    user_id_opt: ?[]const u8,
    channel: []const u8,
    chat_id: []const u8,
    content: []const u8,
    dedupe_key_opt: ?[]const u8,
    now_s: i64,
) ProactiveDecision {
    var user_key_buf: [192]u8 = undefined;
    const user_key = proactiveUserKeyBuf(&user_key_buf, user_id_opt, channel, chat_id);
    var dedupe_key_tmp: [256]u8 = undefined;
    const dedupe_key = dedupeKeyBuf(&dedupe_key_tmp, dedupe_key_opt, source, channel, chat_id, content);

    g_state.mutex.lock();
    defer g_state.mutex.unlock();

    if (g_state.dedupe.get(dedupe_key)) |last_s| {
        if (now_s - last_s <= g_policy.dedupe_window_secs and now_s >= last_s) {
            g_state.proactive_blocked_dedupe_total += 1;
            addEventLocked(now_s, source, user_key, channel, chat_id, .blocked_dedupe, "dedupe_window");
            return .blocked_dedupe;
        }
    }

    var bucket: RateBucket = g_state.rate.get(user_key) orelse .{
        .window_start_s = now_s,
        .count = 0,
    };
    if (now_s - bucket.window_start_s >= g_policy.rate_window_secs or now_s < bucket.window_start_s) {
        bucket.window_start_s = now_s;
        bucket.count = 0;
    }
    if (bucket.count >= g_policy.proactive_rate_limit_per_window) {
        g_state.proactive_blocked_rate_total += 1;
        addEventLocked(now_s, source, user_key, channel, chat_id, .blocked_rate, "rate_limit");
        return .blocked_rate;
    }
    bucket.count += 1;
    putOwnedRateKeyLocked(user_key, bucket);
    putOwnedDedupeKeyLocked(dedupe_key, now_s);
    return .allow;
}

pub fn recordProactiveSent(source: []const u8, user_id_opt: ?[]const u8, channel: []const u8, chat_id: []const u8, now_s: i64) void {
    var user_key_buf: [192]u8 = undefined;
    const user_key = proactiveUserKeyBuf(&user_key_buf, user_id_opt, channel, chat_id);

    g_state.mutex.lock();
    defer g_state.mutex.unlock();
    g_state.proactive_sent_total += 1;
    addEventLocked(now_s, source, user_key, channel, chat_id, .sent, "sent");
}

pub fn recordProactiveSendError(source: []const u8, user_id_opt: ?[]const u8, channel: []const u8, chat_id: []const u8, reason: []const u8, now_s: i64) void {
    var user_key_buf: [192]u8 = undefined;
    const user_key = proactiveUserKeyBuf(&user_key_buf, user_id_opt, channel, chat_id);

    g_state.mutex.lock();
    defer g_state.mutex.unlock();
    g_state.proactive_send_errors_total += 1;
    addEventLocked(now_s, source, user_key, channel, chat_id, .send_error, reason);
}

pub fn recordSchedulerExecuted() void {
    g_state.mutex.lock();
    defer g_state.mutex.unlock();
    g_state.scheduler_executed_total += 1;
}

pub fn recordSchedulerBlockedBurst(user_id_opt: ?[]const u8, job_id: []const u8) void {
    const user_id = user_id_opt orelse "unknown";
    g_state.mutex.lock();
    defer g_state.mutex.unlock();
    g_state.scheduler_blocked_burst_total += 1;
    addEventLocked(std.time.timestamp(), "cron", user_id, "scheduler", job_id, .blocked_burst, "burst_guard");
}

pub fn recordSchedulerBlockedCooldown(user_id_opt: ?[]const u8, job_id: []const u8) void {
    const user_id = user_id_opt orelse "unknown";
    g_state.mutex.lock();
    defer g_state.mutex.unlock();
    g_state.scheduler_blocked_cooldown_total += 1;
    addEventLocked(std.time.timestamp(), "cron", user_id, "scheduler", job_id, .blocked_cooldown, "cooldown_guard");
}

pub fn diagnosticsJson(allocator: std.mem.Allocator) ![]u8 {
    g_state.mutex.lock();
    defer g_state.mutex.unlock();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonInt(&buf, allocator, "proactive_sent_total", @intCast(g_state.proactive_sent_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "proactive_blocked_rate_total", @intCast(g_state.proactive_blocked_rate_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "proactive_blocked_dedupe_total", @intCast(g_state.proactive_blocked_dedupe_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "proactive_send_errors_total", @intCast(g_state.proactive_send_errors_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "scheduler_executed_total", @intCast(g_state.scheduler_executed_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "scheduler_blocked_burst_total", @intCast(g_state.scheduler_blocked_burst_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "scheduler_blocked_cooldown_total", @intCast(g_state.scheduler_blocked_cooldown_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "proactive_policy");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonInt(&buf, allocator, "dedupe_window_secs", g_policy.dedupe_window_secs);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "rate_window_secs", g_policy.rate_window_secs);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "rate_limit_per_window", g_policy.proactive_rate_limit_per_window);
    try buf.appendSlice(allocator, "}");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "last_event");
    if (g_state.event_len == 0) {
        try buf.appendSlice(allocator, "null");
    } else {
        const last_idx = (g_state.event_head + MAX_EVENTS - 1) % MAX_EVENTS;
        const last = g_state.events[last_idx];
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonInt(&buf, allocator, "ts_s", last.ts_s);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "action", actionName(last.action));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "source", last.source[0..last.source_len]);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "user", last.user[0..last.user_len]);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "channel", last.channel[0..last.channel_len]);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "chat", last.chat[0..last.chat_len]);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "reason", last.reason[0..last.reason_len]);
        try buf.appendSlice(allocator, "}");
    }
    try buf.appendSlice(allocator, ",\"recent_events\":[");

    var idx: usize = if (g_state.event_len == MAX_EVENTS) g_state.event_head else 0;
    var remaining = g_state.event_len;
    var wrote_any = false;
    while (remaining > 0) : (remaining -= 1) {
        if (wrote_any) try buf.appendSlice(allocator, ",");
        const event = g_state.events[idx];
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonInt(&buf, allocator, "ts_s", event.ts_s);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "action", actionName(event.action));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "source", event.source[0..event.source_len]);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "user", event.user[0..event.user_len]);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "channel", event.channel[0..event.channel_len]);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "chat", event.chat[0..event.chat_len]);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "reason", event.reason[0..event.reason_len]);
        try buf.appendSlice(allocator, "}");
        wrote_any = true;
        idx = (idx + 1) % MAX_EVENTS;
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

test "ops guard blocks duplicate proactive message in dedupe window" {
    const now_s = std.time.timestamp();
    try std.testing.expectEqual(ProactiveDecision.allow, allowProactive("cron", "1", "telegram", "100", "hello", null, now_s));
    try std.testing.expectEqual(ProactiveDecision.blocked_dedupe, allowProactive("cron", "1", "telegram", "100", "hello", null, now_s + 1));
}

test "ops guard blocks proactive message on rate limit" {
    const base = std.time.timestamp();
    var i: u32 = 0;
    while (i < g_policy.proactive_rate_limit_per_window) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "msg-{d}", .{i}) catch "msg";
        try std.testing.expectEqual(ProactiveDecision.allow, allowProactive("cron", "2", "telegram", "200", key, key, base));
    }
    try std.testing.expectEqual(ProactiveDecision.blocked_rate, allowProactive("cron", "2", "telegram", "200", "overflow", "overflow", base));
}

test "ops guard configureProactivePolicy clamps values" {
    configureProactivePolicy(1, 9_999, 0);

    const payload = try diagnosticsJson(std.testing.allocator);
    defer std.testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const policy = parsed.value.object.get("proactive_policy") orelse return error.TestUnexpectedResult;
    try std.testing.expect(policy == .object);
    try std.testing.expectEqual(@as(i64, MIN_DEDUPE_WINDOW_SECS), policy.object.get("dedupe_window_secs").?.integer);
    try std.testing.expectEqual(@as(i64, MAX_RATE_WINDOW_SECS), policy.object.get("rate_window_secs").?.integer);
    try std.testing.expectEqual(@as(i64, MIN_RATE_LIMIT_PER_WINDOW), policy.object.get("rate_limit_per_window").?.integer);

    configureProactivePolicy(
        @intCast(DEFAULT_DEDUPE_WINDOW_SECS),
        @intCast(DEFAULT_RATE_WINDOW_SECS),
        DEFAULT_PROACTIVE_RATE_LIMIT_PER_WINDOW,
    );
}

test "diagnosticsJson includes last_event summary" {
    const now_s = std.time.timestamp();
    const decision = allowProactive("heartbeat", "diag-user", "telegram", "diag-chat", "diag-content", "diag-key", now_s);
    try std.testing.expectEqual(ProactiveDecision.allow, decision);
    recordProactiveSent("heartbeat", "diag-user", "telegram", "diag-chat", now_s);

    const payload = try diagnosticsJson(std.testing.allocator);
    defer std.testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const last_event = obj.get("last_event") orelse return error.TestUnexpectedResult;
    try std.testing.expect(last_event == .object);
    try std.testing.expectEqualStrings("heartbeat", last_event.object.get("source").?.string);
    try std.testing.expectEqualStrings("sent", last_event.object.get("action").?.string);
    try std.testing.expectEqualStrings("telegram", last_event.object.get("channel").?.string);
}
