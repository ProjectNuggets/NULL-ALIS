//! HTTP Gateway — lightweight HTTP server for nullalis.
//!
//! Mirrors ZeroClaw's axum-based gateway with:
//!   - Sliding-window rate limiting (per-key)
//!   - Idempotency store (deduplicates webhook requests)
//!   - Body size limits (64KB max)
//!   - Request timeouts (30s)
//!   - Bearer token authentication (PairingGuard)
//!   - Endpoints: /health, /ready, /pair, /webhook, /whatsapp, /telegram, /line, /lark, /slack/events
//!
//! Uses std.http.Server (built-in, no external deps).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const health = @import("health.zig");
const Config = @import("config.zig").Config;
const config_types = @import("config_types.zig");
const session_mod = @import("session.zig");
const providers = @import("providers/root.zig");
const tools_mod = @import("tools/root.zig");
const memory_mod = @import("memory/root.zig");
const zaki_dual_memory = @import("memory/engines/zaki_dual.zig");
const zaki_postgres_memory = @import("memory/engines/zaki_postgres.zig");
const subagent_mod = @import("subagent.zig");
const observability = @import("observability.zig");
const Observer = observability.Observer;
const ObserverEvent = observability.ObserverEvent;
const agent_routing = @import("agent_routing.zig");
const agent_prompt = @import("agent/prompt.zig");
const security = @import("security/policy.zig");
const http_util = @import("http_util.zig");
const http_native = @import("http_native/root.zig");
const json_util = @import("json_util.zig");
const tenant_lock = @import("tenant_lock.zig");
const onboard = @import("onboard.zig");
const zaki_state_mod = @import("zaki_state.zig");
const zaki_session = @import("zaki_session.zig");
const ops_guard = @import("ops_guard.zig");
const heartbeat_wake = @import("heartbeat_wake.zig");
const tool_dispatcher = @import("tool_dispatcher.zig");
const inbound_canonicalizer = @import("inbound_canonicalizer.zig");
const channel_identity_key = @import("channel_identity_key.zig");
const multimodal = @import("multimodal.zig");
const voice = @import("voice.zig");
const telegram_token = @import("telegram_token.zig");
const user_settings = @import("user_settings.zig");
const tool_sandbox_v1 = @import("tools/tool_sandbox_v1.zig");
const lane_metrics = @import("lane_metrics.zig");
const PairingGuard = @import("security/pairing.zig").PairingGuard;
const channels = @import("channels/root.zig");
const channel_manager = @import("channel_manager.zig");
const channel_dispatch = @import("channels/dispatch.zig");
const bus_mod = @import("bus.zig");
const log = std.log.scoped(.gateway);

/// Maximum request body size (64KB) — prevents memory exhaustion.
pub const MAX_BODY_SIZE: usize = 65_536;

/// Request timeout (30s) — prevents slow-loris attacks.
pub const REQUEST_TIMEOUT_SECS: u64 = 30;

/// Sliding window for rate limiting (60s).
pub const RATE_LIMIT_WINDOW_SECS: u64 = 60;

/// How often the rate limiter sweeps stale IP entries (5 min).
const RATE_LIMITER_SWEEP_INTERVAL_SECS: u64 = 300;

/// Hard cap for full HTTP request bytes (headers + body).
const MAX_HEADER_SIZE: usize = 16_384;
const MAX_HTTP_REQUEST_SIZE: usize = MAX_HEADER_SIZE + MAX_BODY_SIZE;

/// Default per-user data root for tenant mode.
const DEFAULT_TENANT_DATA_ROOT: []const u8 = "/data/users";

/// Ownership lock TTL for per-user writer fencing in tenant mode.
const TENANT_OWNERSHIP_LOCK_LEASE_SECS: u64 = 300;
const TENANT_OWNERSHIP_LOCK_LEASE_SECS_MIN: u32 = 30;
const TENANT_OWNERSHIP_LOCK_LEASE_SECS_MAX: u32 = 900;
const TENANT_OWNERSHIP_LOCK_WAIT_MS_DEFAULT: u32 = 750;
const TENANT_OWNERSHIP_LOCK_WAIT_MS_MIN: u32 = 50;
const TENANT_OWNERSHIP_LOCK_WAIT_MS_MAX: u32 = 5000;
const TENANT_OWNERSHIP_LOCK_RETRY_MS_MIN_DEFAULT: u32 = 20;
const TENANT_OWNERSHIP_LOCK_RETRY_MS_MAX_DEFAULT: u32 = 80;
const TENANT_OWNERSHIP_LOCK_RETRY_MS_MIN: u32 = 5;
const TENANT_OWNERSHIP_LOCK_RETRY_MS_MAX: u32 = 250;
const INTERNAL_TOKEN_MIN_LEN: usize = 16;
const INTERNAL_TOKEN_DENYLIST = [_][]const u8{
    "test-internal-token",
    "dev-internal-token",
    "changeme",
    "change-me",
    "default",
};

const TELEGRAM_REQUIRED_INPUTS = [_][]const u8{
    "bot_token",
};
const TELEGRAM_CONNECT_INSTRUCTIONS = [_][]const u8{
    "Create a bot with @BotFather and copy the bot token.",
    "Paste the bot token in Connect Telegram in the app.",
    "ZAKI configures the Telegram webhook automatically for you.",
    "Send /start to the bot once to bind and verify delivery.",
};
const SLACK_REQUIRED_INPUTS = [_][]const u8{
    "workspace_bot_installation",
    "events_subscription",
};
const SLACK_CONNECT_INSTRUCTIONS = [_][]const u8{
    "Install the workspace bot and enable Events API with /slack/events.",
    "Invite the bot to a channel or open a DM.",
    "Send a first message to establish user routing/binding.",
};
const DISCORD_REQUIRED_INPUTS = [_][]const u8{
    "bot_invite",
    "message_content_intent",
};
const DISCORD_CONNECT_INSTRUCTIONS = [_][]const u8{
    "Invite the bot to your server with message permissions.",
    "Enable Message Content intent in the Discord developer portal.",
    "Send a DM or mention the bot in the target channel.",
};

// ── Rate Limiter ─────────────────────────────────────────────────

/// Sliding-window rate limiter. Tracks timestamps per key.
/// Not thread-safe by itself; callers must hold a lock.
pub const SlidingWindowRateLimiter = struct {
    mutex: std.Thread.Mutex = .{},
    limit_per_window: u32,
    window_ns: i128,
    /// Map of key -> list of request timestamps (as nanoTimestamp values).
    entries: std.StringHashMapUnmanaged(std.ArrayList(i128)),
    last_sweep: i128,

    pub fn init(limit_per_window: u32, window_secs: u64) SlidingWindowRateLimiter {
        return .{
            .limit_per_window = limit_per_window,
            .window_ns = @as(i128, @intCast(window_secs)) * 1_000_000_000,
            .entries = .empty,
            .last_sweep = std.time.nanoTimestamp(),
        };
    }

    pub fn deinit(self: *SlidingWindowRateLimiter, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            allocator.free(@constCast(entry.key_ptr.*));
            entry.value_ptr.deinit(allocator);
        }
        self.entries.deinit(allocator);
    }

    /// Returns true if the request is allowed, false if rate-limited.
    pub fn allow(self: *SlidingWindowRateLimiter, allocator: std.mem.Allocator, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.limit_per_window == 0) return true;

        const now = std.time.nanoTimestamp();
        const cutoff = now - self.window_ns;

        // Periodic sweep
        if (now - self.last_sweep > @as(i128, RATE_LIMITER_SWEEP_INTERVAL_SECS) * 1_000_000_000) {
            self.sweep(allocator, cutoff);
            self.last_sweep = now;
        }

        var timestamps_ptr = self.entries.getPtr(key);
        if (timestamps_ptr == null) {
            const key_copy = allocator.dupe(u8, key) catch return true;
            self.entries.put(allocator, key_copy, .empty) catch {
                allocator.free(key_copy);
                return true;
            };
            timestamps_ptr = self.entries.getPtr(key_copy);
            if (timestamps_ptr == null) return true;
        }

        // Remove expired entries
        var timestamps = timestamps_ptr.?;
        var i: usize = 0;
        while (i < timestamps.items.len) {
            if (timestamps.items[i] <= cutoff) {
                _ = timestamps.swapRemove(i);
            } else {
                i += 1;
            }
        }

        if (timestamps.items.len >= self.limit_per_window) return false;

        timestamps.append(allocator, now) catch return true;
        return true;
    }

    fn sweep(self: *SlidingWindowRateLimiter, allocator: std.mem.Allocator, cutoff: i128) void {
        var iter = self.entries.iterator();
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(allocator);

        while (iter.next()) |entry| {
            var timestamps = entry.value_ptr;
            var i: usize = 0;
            while (i < timestamps.items.len) {
                if (timestamps.items[i] <= cutoff) {
                    _ = timestamps.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            if (timestamps.items.len == 0) {
                to_remove.append(allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                allocator.free(@constCast(kv.key));
                var list = kv.value;
                list.deinit(allocator);
            }
        }
    }
};

// ── Gateway Rate Limiter ─────────────────────────────────────────

pub const GatewayRateLimiter = struct {
    pair: SlidingWindowRateLimiter,
    webhook: SlidingWindowRateLimiter,

    pub fn init(pair_per_minute: u32, webhook_per_minute: u32) GatewayRateLimiter {
        return .{
            .pair = SlidingWindowRateLimiter.init(pair_per_minute, RATE_LIMIT_WINDOW_SECS),
            .webhook = SlidingWindowRateLimiter.init(webhook_per_minute, RATE_LIMIT_WINDOW_SECS),
        };
    }

    pub fn deinit(self: *GatewayRateLimiter, allocator: std.mem.Allocator) void {
        self.pair.deinit(allocator);
        self.webhook.deinit(allocator);
    }

    pub fn allowPair(self: *GatewayRateLimiter, allocator: std.mem.Allocator, key: []const u8) bool {
        return self.pair.allow(allocator, key);
    }

    pub fn allowWebhook(self: *GatewayRateLimiter, allocator: std.mem.Allocator, key: []const u8) bool {
        return self.webhook.allow(allocator, key);
    }
};

// ── Idempotency Store ────────────────────────────────────────────

pub const IdempotencyStore = struct {
    mutex: std.Thread.Mutex = .{},
    ttl_ns: i128,
    /// Map of key -> timestamp when recorded.
    keys: std.StringHashMapUnmanaged(i128),

    pub fn init(ttl_secs: u64) IdempotencyStore {
        return .{
            .ttl_ns = @as(i128, @intCast(@max(ttl_secs, 1))) * 1_000_000_000,
            .keys = .empty,
        };
    }

    pub fn deinit(self: *IdempotencyStore, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.keys.iterator();
        while (it.next()) |entry| {
            allocator.free(@constCast(entry.key_ptr.*));
        }
        self.keys.deinit(allocator);
    }

    /// Returns true if this key is new and is now recorded.
    /// Returns false if this is a duplicate.
    pub fn recordIfNew(self: *IdempotencyStore, allocator: std.mem.Allocator, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.nanoTimestamp();
        const cutoff = now - self.ttl_ns;

        // Clean expired keys (simple sweep)
        var iter = self.keys.iterator();
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(allocator);
        while (iter.next()) |entry| {
            if (entry.value_ptr.* < cutoff) {
                to_remove.append(allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |k| {
            if (self.keys.fetchRemove(k)) |removed| {
                allocator.free(@constCast(removed.key));
            }
        }

        // Check if already present
        if (self.keys.get(key)) |_| return false;

        // Record new key
        const key_copy = allocator.dupe(u8, key) catch return true;
        self.keys.put(allocator, key_copy, now) catch {
            allocator.free(key_copy);
            return true;
        };
        return true;
    }
};

// ── Gateway server ───────────────────────────────────────────────

const TENANT_TELEGRAM_ASYNC_QUEUE_CAPACITY: usize = 256;
const USER_CELL_REGISTRATION_REFRESH_SECS: u64 = 5;
const TENANT_RUNTIME_MAINTENANCE_INTERVAL_SECS: i64 = 1;
const GATEWAY_SESSION_LOCK_WAIT_STAGE: []const u8 = "session_lock_wait";

pub const GatewayRole = enum {
    shared,
    broker,
    user_cell,
};

fn gatewayRoleNeedsLocalAgent(role: GatewayRole, has_event_bus: bool) bool {
    if (has_event_bus) return false;
    return switch (role) {
        .shared => true,
        .user_cell => false,
        .broker => false,
    };
}

fn gatewayRoleOwnsTenantExecution(role: GatewayRole) bool {
    return switch (role) {
        .shared, .user_cell => true,
        .broker => false,
    };
}

fn appendSubagentCompletionToGatewaySession(
    ctx: ?*anyopaque,
    session_key: []const u8,
    content: []const u8,
) anyerror!void {
    const router: *SubagentCompletionRouter = @ptrCast(@alignCast(ctx.?));
    var origin = try router.session_mgr.captureOriginSnapshot(session_key);
    defer origin.deinit(router.session_mgr.allocator);

    try router.session_mgr.appendAssistantMessage(session_key, content);
    const completion_event_id = try router.session_mgr.saveCompletionEvent(session_key, origin.channel, origin.account_id, origin.chat_id, content);
    defer if (completion_event_id) |value| router.session_mgr.allocator.free(value);

    if (origin.channel) |channel_name| {
        if (std.mem.eql(u8, channel_name, "zaki_app")) {
            if (completion_event_id) |event_id| {
                const user_scope = zaki_session.parseUserIdFromSessionKey(session_key) orelse "";
                _ = router.state.app_event_subscribers.publish(event_id, user_scope, session_key, content) catch false;
            }
            return;
        }
    }

    if (!shouldEmitSubagentCompletionOutbound(origin.channel, origin.chat_id)) return;

    const user_id = zaki_session.parseUserIdFromSessionKey(session_key);
    const source_tag = if (completion_event_id) |event_id|
        try std.fmt.allocPrint(router.session_mgr.allocator, "subagent_completion:{s}", .{event_id})
    else
        null;
    defer if (source_tag) |value| router.session_mgr.allocator.free(value);
    var outbound = if (origin.account_id) |account_id|
        try bus_mod.makeOutboundWithAccountAnnotated(
            router.session_mgr.allocator,
            origin.channel.?,
            account_id,
            origin.chat_id.?,
            content,
            source_tag orelse "subagent",
            user_id,
            null,
        )
    else
        try bus_mod.makeOutboundAnnotated(
            router.session_mgr.allocator,
            origin.channel.?,
            origin.chat_id.?,
            content,
            source_tag orelse "subagent",
            user_id,
            null,
        );
    var outbound_transferred = false;
    defer if (!outbound_transferred) outbound.deinit(router.session_mgr.allocator);

    if (router.event_bus) |event_bus| {
        event_bus.publishOutbound(outbound) catch |err| {
            if (err != error.Closed) {
                try dispatchSubagentCompletionLocally(router.session_mgr.allocator, router.config, &outbound);
                if (completion_event_id) |event_id| {
                    try router.session_mgr.deleteCompletionEvent(event_id);
                }
            }
            return;
        };
        outbound_transferred = true;
        return;
    }

    try dispatchSubagentCompletionLocally(router.session_mgr.allocator, router.config, &outbound);
    if (completion_event_id) |event_id| {
        try router.session_mgr.deleteCompletionEvent(event_id);
    }
}

const SubagentCompletionRouter = struct {
    session_mgr: *session_mod.SessionManager,
    event_bus: ?*bus_mod.Bus,
    config: *const Config,
    state: *GatewayState,
};

fn shouldEmitSubagentCompletionOutbound(channel: ?[]const u8, chat_id: ?[]const u8) bool {
    const resolved_channel = channel orelse return false;
    _ = chat_id orelse return false;
    return !std.mem.eql(u8, resolved_channel, "agent") and
        !std.mem.eql(u8, resolved_channel, "system") and
        !std.mem.eql(u8, resolved_channel, "zaki_app");
}

fn dispatchSubagentCompletionLocally(
    allocator: std.mem.Allocator,
    cfg: *const Config,
    outbound: *const bus_mod.OutboundMessage,
) !void {
    var registry = channel_dispatch.ChannelRegistry.init(allocator);
    defer registry.deinit();

    const mgr = try channel_manager.ChannelManager.init(allocator, cfg, &registry);
    defer mgr.deinit();
    try mgr.collectConfiguredChannels();

    var stats = channel_dispatch.DispatchStats{};
    var tenant_ctx = channel_dispatch.TenantDispatchContext{
        .enabled = cfg.tenant.enabled,
        .data_root = cfg.tenant.data_root,
        .allow_telegram_fallback = cfg.tenant.enabled,
    };
    channel_dispatch.dispatchOutboundMessage(allocator, null, &registry, &stats, &tenant_ctx, outbound);
}

const TenantTelegramAsyncJobQueue = struct {
    buf: [TENANT_TELEGRAM_ASYNC_QUEUE_CAPACITY]*anyopaque = undefined,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    closed: bool = false,
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},

    fn push(self: *TenantTelegramAsyncJobQueue, job: *anyopaque) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return false;
        if (self.len == TENANT_TELEGRAM_ASYNC_QUEUE_CAPACITY) return false;
        self.buf[self.tail] = job;
        self.tail = (self.tail + 1) % TENANT_TELEGRAM_ASYNC_QUEUE_CAPACITY;
        self.len += 1;
        self.not_empty.signal();
        return true;
    }

    fn pop(self: *TenantTelegramAsyncJobQueue) ?*anyopaque {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.len == 0 and !self.closed) {
            self.not_empty.wait(&self.mutex);
        }
        if (self.len == 0) return null;

        const job = self.buf[self.head];
        self.head = (self.head + 1) % TENANT_TELEGRAM_ASYNC_QUEUE_CAPACITY;
        self.len -= 1;
        return job;
    }

    fn close(self: *TenantTelegramAsyncJobQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.not_empty.broadcast();
    }
};

const LiveAppCompletionEvent = struct {
    id: []u8,
    session_key: []u8,
    content: []u8,

    fn initOwned(allocator: std.mem.Allocator, event_id: []const u8, session_key: []const u8, content: []const u8) !LiveAppCompletionEvent {
        return .{
            .id = try allocator.dupe(u8, event_id),
            .session_key = try allocator.dupe(u8, session_key),
            .content = try allocator.dupe(u8, content),
        };
    }

    fn deinit(self: *LiveAppCompletionEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_key);
        allocator.free(self.content);
    }
};

const AppEventsSubscriber = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: std.ArrayListUnmanaged(LiveAppCompletionEvent) = .empty,
    delivered_ids: std.StringHashMapUnmanaged(void) = .empty,
    closed: bool = false,

    const WaitResult = union(enum) {
        event: LiveAppCompletionEvent,
        timeout,
        closed,
    };

    fn close(self: *AppEventsSubscriber) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }

    fn deinit(self: *AppEventsSubscriber, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.queue.items.len > 0) {
            var event = self.queue.pop().?;
            event.deinit(allocator);
        }
        self.queue.deinit(allocator);
        var it = self.delivered_ids.iterator();
        while (it.next()) |entry| {
            allocator.free(@constCast(entry.key_ptr.*));
        }
        self.delivered_ids.deinit(allocator);
    }

    fn enqueue(self: *AppEventsSubscriber, allocator: std.mem.Allocator, event_id: []const u8, session_key: []const u8, content: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return false;
        if (self.delivered_ids.contains(event_id)) return false;
        for (self.queue.items) |queued| {
            if (std.mem.eql(u8, queued.id, event_id)) return false;
        }
        try self.queue.append(allocator, try LiveAppCompletionEvent.initOwned(allocator, event_id, session_key, content));
        self.cond.signal();
        return true;
    }

    fn removeQueuedEventLocked(self: *AppEventsSubscriber, allocator: std.mem.Allocator, event_id: []const u8) void {
        var idx: usize = 0;
        while (idx < self.queue.items.len) {
            if (std.mem.eql(u8, self.queue.items[idx].id, event_id)) {
                var event = self.queue.orderedRemove(idx);
                event.deinit(allocator);
                continue;
            }
            idx += 1;
        }
    }

    fn markDelivered(self: *AppEventsSubscriber, allocator: std.mem.Allocator, event_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.delivered_ids.contains(event_id)) {
            const owned = try allocator.dupe(u8, event_id);
            errdefer allocator.free(owned);
            try self.delivered_ids.put(allocator, owned, {});
        }
        self.removeQueuedEventLocked(allocator, event_id);
    }

    fn waitForEvent(self: *AppEventsSubscriber, wait_ns: u64) WaitResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.queue.items.len == 0 and !self.closed) {
            self.cond.timedWait(&self.mutex, wait_ns) catch |err| switch (err) {
                error.Timeout => return .timeout,
            };
        }
        if (self.queue.items.len == 0) return .closed;
        return .{ .event = self.queue.orderedRemove(0) };
    }
};

const AppEventSubscriberRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    subscribers: std.StringHashMapUnmanaged(*AppEventsSubscriber) = .empty,

    fn init(allocator: std.mem.Allocator) AppEventSubscriberRegistry {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *AppEventSubscriberRegistry) void {
        self.closeAll();
        var it = self.subscribers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(@constCast(entry.key_ptr.*));
        }
        self.subscribers.deinit(self.allocator);
    }

    fn keyFor(allocator: std.mem.Allocator, user_id: []const u8, session_key: []const u8) ![]u8 {
        _ = user_id;
        return allocator.dupe(u8, session_key);
    }

    fn register(self: *AppEventSubscriberRegistry, user_id: []const u8, session_key: []const u8, subscriber: *AppEventsSubscriber) !void {
        const key = try keyFor(self.allocator, user_id, session_key);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (try self.subscribers.fetchPut(self.allocator, key, subscriber)) |previous| {
            previous.value.close();
            self.allocator.free(@constCast(previous.key));
        }
    }

    fn unregister(self: *AppEventSubscriberRegistry, user_id: []const u8, session_key: []const u8, subscriber: *AppEventsSubscriber) void {
        const key = keyFor(self.allocator, user_id, session_key) catch return;
        defer self.allocator.free(key);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.subscribers.getEntry(key)) |entry| {
            if (entry.value_ptr.* == subscriber) {
                const removed = self.subscribers.fetchRemove(key).?;
                self.allocator.free(@constCast(removed.key));
            }
        }
    }

    fn publish(self: *AppEventSubscriberRegistry, event_id: []const u8, user_id: []const u8, session_key: []const u8, content: []const u8) !bool {
        const key = try keyFor(self.allocator, user_id, session_key);
        defer self.allocator.free(key);
        self.mutex.lock();
        const subscriber = self.subscribers.get(key);
        self.mutex.unlock();
        if (subscriber == null) return false;
        return try subscriber.?.enqueue(self.allocator, event_id, session_key, content);
    }

    fn closeAll(self: *AppEventSubscriberRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.subscribers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.close();
        }
    }
};

const UserPreparationGate = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    active: std.StringHashMapUnmanaged(void) = .empty,

    const Guard = struct {
        gate: *UserPreparationGate,
        key: []const u8,
        held: bool = true,

        fn release(self: *Guard) void {
            if (!self.held) return;
            self.gate.mutex.lock();
            defer self.gate.mutex.unlock();
            if (self.gate.active.fetchRemove(self.key)) |kv| {
                self.gate.allocator.free(@constCast(kv.key));
            }
            self.held = false;
            self.gate.cond.broadcast();
        }

        fn deinit(self: *Guard) void {
            self.release();
        }
    };

    fn init(allocator: std.mem.Allocator) UserPreparationGate {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *UserPreparationGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.active.iterator();
        while (it.next()) |entry| {
            self.allocator.free(@constCast(entry.key_ptr.*));
        }
        self.active.deinit(self.allocator);
    }

    fn acquire(self: *UserPreparationGate, user_id: []const u8) !Guard {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.active.contains(user_id)) {
            self.cond.wait(&self.mutex);
        }

        const owned = try self.allocator.dupe(u8, user_id);
        errdefer self.allocator.free(owned);
        try self.active.put(self.allocator, owned, {});
        return .{
            .gate = self,
            .key = owned,
        };
    }
};

/// Gateway server state, shared across request handlers.
pub const GatewayState = struct {
    allocator: std.mem.Allocator,
    role: GatewayRole = .shared,
    controller_url: ?[]const u8 = null,
    advertise_url: ?[]const u8 = null,
    advertise_url_owned: bool = false,
    pinned_user_id: ?[]const u8 = null,
    pinned_user_id_owned: bool = false,
    rate_limiter: GatewayRateLimiter,
    idempotency: IdempotencyStore,
    whatsapp_verify_token: []const u8,
    whatsapp_app_secret: []const u8,
    whatsapp_access_token: []const u8,
    whatsapp_account_id: []const u8 = "default",
    telegram_bot_token: []const u8,
    telegram_account_id: []const u8 = "default",
    telegram_webhook_secret_token: []const u8 = "",
    telegram_allow_from: []const []const u8 = &.{},
    whatsapp_allow_from: []const []const u8 = &.{},
    whatsapp_group_allow_from: []const []const u8 = &.{},
    whatsapp_groups: []const []const u8 = &.{},
    whatsapp_group_policy: []const u8 = "allowlist",
    line_channel_secret: []const u8 = "",
    line_access_token: []const u8 = "",
    line_account_id: []const u8 = "default",
    line_allow_from: []const []const u8 = &.{},
    lark_verification_token: []const u8 = "",
    lark_app_id: []const u8 = "",
    lark_app_secret: []const u8 = "",
    lark_account_id: []const u8 = "default",
    lark_allow_from: []const []const u8 = &.{},
    internal_service_tokens: []const []const u8 = &.{},
    internal_auth_required: bool = false,
    internal_token_configured: bool = false,
    internal_token_policy_ok: bool = true,
    internal_token_policy_reason: []const u8 = "",
    tenant_enabled: bool = false,
    tenant_data_root: []const u8 = DEFAULT_TENANT_DATA_ROOT,
    workspace_dir: []const u8 = ".",
    tenant_runtime_cache_max_users: u32 = 2048,
    tenant_runtime_idle_ttl_secs: u32 = 1800,
    ownership_lock_enabled: bool = false,
    ownership_lock_lease_secs: u64 = TENANT_OWNERSHIP_LOCK_LEASE_SECS,
    ownership_lock_wait_ms: u32 = TENANT_OWNERSHIP_LOCK_WAIT_MS_DEFAULT,
    ownership_lock_retry_min_ms: u32 = TENANT_OWNERSHIP_LOCK_RETRY_MS_MIN_DEFAULT,
    ownership_lock_retry_max_ms: u32 = TENANT_OWNERSHIP_LOCK_RETRY_MS_MAX_DEFAULT,
    owner_instance_id: []const u8 = "",
    owner_instance_id_owned: bool = false,
    user_preparation_gate: UserPreparationGate,
    app_event_subscribers: AppEventSubscriberRegistry,
    tenant_runtime_mutex: std.Thread.Mutex = .{},
    tenant_runtimes: std.StringHashMapUnmanaged(*TenantRuntime) = .empty,
    tenant_telegram_queue: TenantTelegramAsyncJobQueue = .{},
    tenant_telegram_worker_mutex: std.Thread.Mutex = .{},
    tenant_telegram_worker: ?std.Thread = null,
    draining: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    requests_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    chat_stream_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    chat_stream_errors_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    telegram_webhook_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    telegram_webhook_rejected_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    require_explicit_chat_stream_session_key: bool = true,
    tenant_lock_conflicts_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tenant_lock_conflicts_chat_stream_sse_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tenant_lock_conflicts_chat_stream_http_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tenant_lock_conflicts_webhook_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tenant_lock_conflicts_daemon_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tenant_lock_conflicts_api_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tenant_lock_conflict_retries_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tenant_runtime_policy_attached: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    chat_stream_lane_main_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    chat_stream_lane_thread_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    chat_stream_lane_task_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    chat_stream_lane_cron_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    chat_stream_session_key_missing_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    chat_stream_session_key_invalid_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    chat_stream_session_key_wrong_user_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    chat_stream_session_key_invalid_lane_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    in_flight_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    drain_rejected_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    overload_rejected_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    state_backend_configured: []const u8 = "file",
    state_backend_effective: []const u8 = "file",
    scheduler_backend: []const u8 = "file",
    webhook_mode: []const u8 = "none",
    heartbeat_enabled: bool = false,
    heartbeat_interval_minutes: u32 = 0,
    tenant_enabled_configured: bool = false,
    postgres_port: u16 = 0,
    postgres_host_buf: [64]u8 = [_]u8{0} ** 64,
    postgres_host_len: usize = 0,
    postgres_schema_buf: [64]u8 = [_]u8{0} ** 64,
    postgres_schema_len: usize = 0,
    config_path_buf: [160]u8 = [_]u8{0} ** 160,
    config_path_len: usize = 0,
    state_degraded: bool = false,
    state_degraded_reason_buf: [64]u8 = [_]u8{0} ** 64,
    state_degraded_reason_len: usize = 0,
    chat_provider_effective: []const u8 = "unknown",
    embedding_provider_effective: []const u8 = "none",
    provider_data_source: []const u8 = "config",
    chat_fallback_chain_buf: [256]u8 = [_]u8{0} ** 256,
    chat_fallback_chain_len: usize = 0,
    last_degraded_warn_s: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    pairing_guard: ?PairingGuard,
    event_bus: ?*bus_mod.Bus = null,
    zaki_state: ?*zaki_state_mod.Manager = null,
    lifecycle_metrics: LifecycleMetrics = .{},

    pub fn init(allocator: std.mem.Allocator) GatewayState {
        return initWithVerifyToken(allocator, "");
    }

    pub fn initWithVerifyToken(allocator: std.mem.Allocator, verify_token: []const u8) GatewayState {
        return .{
            .allocator = allocator,
            .rate_limiter = GatewayRateLimiter.init(10, 30),
            .idempotency = IdempotencyStore.init(300),
            .whatsapp_verify_token = verify_token,
            .whatsapp_app_secret = "",
            .whatsapp_access_token = "",
            .telegram_bot_token = "",
            .user_preparation_gate = UserPreparationGate.init(allocator),
            .app_event_subscribers = AppEventSubscriberRegistry.init(allocator),
            .pairing_guard = null,
        };
    }

    pub fn deinit(self: *GatewayState) void {
        self.app_event_subscribers.deinit();
        self.tenant_telegram_queue.close();
        if (self.tenant_telegram_worker) |worker| {
            worker.join();
        }
        self.rate_limiter.deinit(self.allocator);
        self.idempotency.deinit(self.allocator);
        self.user_preparation_gate.deinit();
        self.tenant_runtime_mutex.lock();
        defer self.tenant_runtime_mutex.unlock();
        var rt_it = self.tenant_runtimes.iterator();
        while (rt_it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.tenant_runtimes.deinit(self.allocator);
        if (self.pairing_guard) |*guard| {
            guard.deinit();
        }
        if (self.owner_instance_id_owned and self.owner_instance_id.len > 0) {
            self.allocator.free(self.owner_instance_id);
        }
        if (self.advertise_url_owned) {
            if (self.advertise_url) |value| self.allocator.free(value);
        }
        if (self.pinned_user_id_owned) {
            if (self.pinned_user_id) |value| self.allocator.free(value);
        }
        if (self.zaki_state) |mgr| {
            mgr.deinit();
            self.allocator.destroy(mgr);
        }
    }

    fn postgresHost(self: *const GatewayState) []const u8 {
        return self.postgres_host_buf[0..self.postgres_host_len];
    }

    fn postgresSchema(self: *const GatewayState) []const u8 {
        return self.postgres_schema_buf[0..self.postgres_schema_len];
    }

    fn degradedReason(self: *const GatewayState) []const u8 {
        return self.state_degraded_reason_buf[0..self.state_degraded_reason_len];
    }

    fn configPath(self: *const GatewayState) []const u8 {
        return self.config_path_buf[0..self.config_path_len];
    }

    fn chatFallbackChain(self: *const GatewayState) []const u8 {
        return self.chat_fallback_chain_buf[0..self.chat_fallback_chain_len];
    }

    fn closeAppEventSubscribers(self: *GatewayState) void {
        self.app_event_subscribers.closeAll();
    }
};

/// Exported lifecycle tax metrics for gateway-hosted agent work.
/// These series are intentionally coarse and stable so operators can separate
/// turn latency from lock wait, compaction, continuity refresh, and pruning.
const LifecycleMetrics = struct {
    lock_wait_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    lock_wait_duration_ms_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    compaction_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    compaction_duration_ms_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    continuity_refresh_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    continuity_refresh_duration_ms_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pruning_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pruning_duration_ms_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tenant_runtime_pruned_idle_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tenant_runtime_pruned_capacity_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn recordLifecycleStage(self: *LifecycleMetrics, stage: []const u8, duration_ms: u64) void {
        if (std.mem.eql(u8, stage, GATEWAY_SESSION_LOCK_WAIT_STAGE)) {
            _ = self.lock_wait_total.fetchAdd(1, .monotonic);
            _ = self.lock_wait_duration_ms_total.fetchAdd(duration_ms, .monotonic);
            return;
        }
        if (std.mem.eql(u8, stage, "turn_auto_compaction") or
            std.mem.eql(u8, stage, "post_reply_compaction") or
            std.mem.eql(u8, stage, "compact_trim"))
        {
            _ = self.compaction_total.fetchAdd(1, .monotonic);
            _ = self.compaction_duration_ms_total.fetchAdd(duration_ms, .monotonic);
            return;
        }
        if (std.mem.eql(u8, stage, "continuity_refresh")) {
            _ = self.continuity_refresh_total.fetchAdd(1, .monotonic);
            _ = self.continuity_refresh_duration_ms_total.fetchAdd(duration_ms, .monotonic);
            return;
        }
    }

    fn recordPruning(self: *LifecycleMetrics, duration_ms: u64, idle_removed: usize, capacity_removed: usize) void {
        const total_removed = idle_removed + capacity_removed;
        if (total_removed == 0) return;
        _ = self.pruning_total.fetchAdd(@intCast(total_removed), .monotonic);
        _ = self.pruning_duration_ms_total.fetchAdd(duration_ms, .monotonic);
        _ = self.tenant_runtime_pruned_idle_total.fetchAdd(@intCast(idle_removed), .monotonic);
        _ = self.tenant_runtime_pruned_capacity_total.fetchAdd(@intCast(capacity_removed), .monotonic);
    }
};

const LifecycleMetricsObserver = struct {
    metrics: *LifecycleMetrics,

    const vtable = Observer.VTable{
        .record_event = recordEvent,
        .record_metric = recordMetric,
        .flush = flush,
        .name = name,
    };

    fn observer(self: *LifecycleMetricsObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn resolve(ptr: *anyopaque) *LifecycleMetricsObserver {
        return @ptrCast(@alignCast(ptr));
    }

    fn recordEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
        const self = resolve(ptr);
        switch (event.*) {
            .turn_stage => |stage| {
                const duration_ms = stage.duration_ms orelse return;
                self.metrics.recordLifecycleStage(stage.stage, duration_ms);
            },
            else => {},
        }
    }

    fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn flush(_: *anyopaque) void {}
    fn name(_: *anyopaque) []const u8 {
        return "gateway_lifecycle_metrics";
    }
};

const UserContext = struct {
    user_id: []const u8,
    user_root: []const u8,
    workspace_path: []const u8,
    memory_db_path: []const u8,
    cron_path: []const u8,
    config_path: []const u8,
    heartbeat_path: []const u8,
    channel_state_path: []const u8,
    telegram_path: []const u8,
    secrets_dir: []const u8,

    fn deinit(self: *const UserContext, allocator: std.mem.Allocator) void {
        allocator.free(self.user_root);
        allocator.free(self.workspace_path);
        allocator.free(self.memory_db_path);
        allocator.free(self.cron_path);
        allocator.free(self.config_path);
        allocator.free(self.heartbeat_path);
        allocator.free(self.channel_state_path);
        allocator.free(self.telegram_path);
        allocator.free(self.secrets_dir);
    }
};

const USER_CELL_STATE_DIR = ".nullalis";

const TenantRuntime = struct {
    const TENANT_SEED_SCHEMA_VERSION: []const u8 = "2026-03-18-v1";

    allocator: std.mem.Allocator,
    user_id: []u8,
    workspace_path: []u8,
    config: Config,
    provider_bundle: providers.runtime_bundle.RuntimeProviderBundle,
    tools: []const tools_mod.Tool,
    mem_rt: ?memory_mod.MemoryRuntime,
    pg_session_store: ?*zaki_state_mod.Manager.UserSessionStore,
    state_mgr: ?*zaki_state_mod.Manager,
    subagent_manager: ?*subagent_mod.SubagentManager,
    completion_router: ?*SubagentCompletionRouter,
    sec_tracker: ?security.RateTracker,
    sec_policy: ?security.SecurityPolicy,
    log_obs: *observability.LogObserver,
    metrics_obs: LifecycleMetricsObserver,
    observer_slots: [2]Observer,
    observer_multi: observability.MultiObserver,
    session_mgr: session_mod.SessionManager,
    last_used_s: std.atomic.Value(i64),
    effective_config_source: []const u8,
    effective_config_hash: u64,
    resolved_settings: user_settings.ProductSettings,
    ignored_tenant_override_count: usize,

    fn configHash(payload: []const u8) u64 {
        return std.hash.Wyhash.hash(0, payload);
    }

    fn hashConfigFileBestEffort(allocator: std.mem.Allocator, path: []const u8) u64 {
        const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
        defer file.close();
        const raw = file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch return 0;
        defer allocator.free(raw);
        return configHash(raw);
    }

    fn buildSeedConfigJsonFromFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const raw = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
        defer allocator.free(raw);
        const normalized = try user_settings.normalizeTenantConfigJson(allocator, raw);
        return normalized.json;
    }

    fn init(
        allocator: std.mem.Allocator,
        base_config: *const Config,
        user_ctx: *const UserContext,
        event_bus: ?*bus_mod.Bus,
        state_mgr: ?*zaki_state_mod.Manager,
        gateway_state: *GatewayState,
        lifecycle_metrics: *LifecycleMetrics,
    ) !*TenantRuntime {
        const runtime = try allocator.create(TenantRuntime);
        errdefer allocator.destroy(runtime);

        const owned_user_id = try allocator.dupe(u8, user_ctx.user_id);
        errdefer allocator.free(owned_user_id);
        const owned_workspace = try allocator.dupe(u8, user_ctx.workspace_path);
        errdefer allocator.free(owned_workspace);

        runtime.* = .{
            .allocator = allocator,
            .user_id = owned_user_id,
            .workspace_path = owned_workspace,
            .config = base_config.*,
            .provider_bundle = undefined,
            .tools = &.{},
            .mem_rt = null,
            .pg_session_store = null,
            .state_mgr = state_mgr,
            .subagent_manager = null,
            .completion_router = null,
            .sec_tracker = null,
            .sec_policy = null,
            .log_obs = undefined,
            .metrics_obs = .{ .metrics = lifecycle_metrics },
            .observer_slots = undefined,
            .observer_multi = .{ .observers = &.{} },
            .session_mgr = undefined,
            .last_used_s = std.atomic.Value(i64).init(std.time.timestamp()),
            .effective_config_source = "file_config",
            .effective_config_hash = hashConfigFileBestEffort(allocator, base_config.config_path),
            .resolved_settings = user_settings.defaults(),
            .ignored_tenant_override_count = 0,
        };
        runtime.config.workspace_dir = runtime.workspace_path;
        if (state_mgr != null) {
            const numeric_user_id = std.fmt.parseInt(i64, user_ctx.user_id, 10) catch return error.InvalidTenantUserId;
            const user_config_json = state_mgr.?.getConfigJson(allocator, numeric_user_id) catch null;
            if (user_config_json) |json| {
                defer allocator.free(json);
                const trimmed = std.mem.trim(u8, json, " \t\r\n");
                if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "{}")) {
                    const normalized = user_settings.normalizeTenantConfigJson(allocator, trimmed) catch null;
                    runtime.effective_config_source = "postgres_user_config";
                    runtime.effective_config_hash = configHash(trimmed);
                    if (normalized) |snapshot| {
                        defer allocator.free(snapshot.json);
                        runtime.effective_config_hash = configHash(snapshot.json);
                        runtime.resolved_settings = snapshot.settings;
                        runtime.ignored_tenant_override_count = snapshot.ignored_override_count;
                        runtime.config.parseJson(snapshot.json) catch |err| {
                            log.warn("tenant config parse failed for user {s}: {s}", .{ user_ctx.user_id, @errorName(err) });
                        };
                    } else {
                        log.warn("tenant config normalize failed for user {s}", .{user_ctx.user_id});
                    }
                    runtime.config.applyProfileDefaults() catch {};
                    runtime.config.memory.applyProfileDefaults();
                    user_settings.applySettingsToConfig(&runtime.config, runtime.resolved_settings);
                } else {
                    const seed_json = buildSeedConfigJsonFromFile(allocator, base_config.config_path) catch null;
                    if (seed_json) |seed| {
                        defer allocator.free(seed);
                        if (state_mgr.?.putConfigJson(numeric_user_id, seed)) |_| {
                            runtime.effective_config_source = "postgres_seeded_from_file";
                            runtime.effective_config_hash = configHash(seed);
                            const normalized = user_settings.normalizeTenantConfigJson(allocator, seed) catch null;
                            log.info("tenant.config.seeded user={s} schema_version={s} hash={x}", .{
                                user_ctx.user_id,
                                TENANT_SEED_SCHEMA_VERSION,
                                runtime.effective_config_hash,
                            });
                            if (normalized) |snapshot| {
                                defer allocator.free(snapshot.json);
                                runtime.effective_config_hash = configHash(snapshot.json);
                                runtime.resolved_settings = snapshot.settings;
                                runtime.ignored_tenant_override_count = snapshot.ignored_override_count;
                                runtime.config.parseJson(snapshot.json) catch |err| {
                                    log.warn("tenant seeded config parse failed for user {s}: {s}", .{ user_ctx.user_id, @errorName(err) });
                                };
                            }
                            runtime.config.applyProfileDefaults() catch {};
                            runtime.config.memory.applyProfileDefaults();
                            user_settings.applySettingsToConfig(&runtime.config, runtime.resolved_settings);
                        } else |err| {
                            runtime.effective_config_source = "file_config_fallback";
                            log.warn("tenant config seed failed for user {s}: {s}", .{ user_ctx.user_id, @errorName(err) });
                        }
                    } else {
                        runtime.effective_config_source = "file_config_fallback";
                    }
                }
            } else {
                runtime.effective_config_source = "file_config_fallback";
            }
            if (std.mem.eql(u8, runtime.config.state.backend, "postgres")) {
                // Use a ZAKI BOT-specific canonical memory backend instead of the generic
                // Postgres engine, which targets a different table shape.
                runtime.config.memory.backend = "markdown";
            }
            const pg_store = try allocator.create(zaki_state_mod.Manager.UserSessionStore);
            errdefer allocator.destroy(pg_store);
            pg_store.* = try zaki_state_mod.Manager.UserSessionStore.init(allocator, state_mgr.?, numeric_user_id);
            runtime.pg_session_store = pg_store;
        }
        // User config JSON must never override the per-tenant workspace root.
        runtime.config.workspace_dir = runtime.workspace_path;
        // Canonical tenant lane policy: app continuity and Telegram DMs share main,
        // while group/topic channels continue to use scoped thread/task/cron lanes.
        runtime.config.session.cross_channel_shared_main = false;

        runtime.provider_bundle = try providers.runtime_bundle.RuntimeProviderBundle.init(allocator, &runtime.config);
        errdefer runtime.provider_bundle.deinit();
        const provider_i: providers.Provider = runtime.provider_bundle.provider();
        const resolved_api_key = runtime.provider_bundle.primaryApiKey();

        runtime.sec_tracker = security.RateTracker.init(allocator, runtime.config.autonomy.max_actions_per_hour);
        runtime.sec_policy = .{
            .autonomy = runtime.config.autonomy.level,
            .workspace_dir = runtime.config.workspace_dir,
            .workspace_only = runtime.config.autonomy.workspace_only,
            .allowed_commands = if (runtime.config.autonomy.allowed_commands.len > 0) runtime.config.autonomy.allowed_commands else &security.default_allowed_commands,
            .max_actions_per_hour = runtime.config.autonomy.max_actions_per_hour,
            .require_approval_for_medium_risk = runtime.config.autonomy.require_approval_for_medium_risk,
            .block_high_risk_commands = runtime.config.autonomy.block_high_risk_commands,
            .tracker = if (runtime.sec_tracker) |*tracker| tracker else null,
        };

        runtime.mem_rt = memory_mod.initRuntimeWithOptions(allocator, &runtime.config.memory, runtime.config.workspace_dir, .{
            .providers = runtime.config.providers,
            .search_api_key_override = resolved_api_key,
        });
        errdefer if (runtime.mem_rt) |*rt| rt.deinit();
        if (runtime.mem_rt) |*rt| {
            if (state_mgr != null and std.mem.eql(u8, runtime.config.state.backend, "postgres")) {
                const numeric_user_id = std.fmt.parseInt(i64, user_ctx.user_id, 10) catch return error.InvalidTenantUserId;
                const old_memory = rt.memory;
                if (rt._engine) |engine| {
                    engine.deinit();
                    allocator.destroy(engine);
                    rt._engine = null;
                }
                const primary_impl = try allocator.create(zaki_postgres_memory.ZakiPostgresMemory);
                errdefer allocator.destroy(primary_impl);
                primary_impl.* = zaki_postgres_memory.ZakiPostgresMemory.init(allocator, state_mgr.?, numeric_user_id);
                primary_impl.owns_self = true;

                const dual = try zaki_dual_memory.ZakiDualMemory.init(allocator, primary_impl.memory(), runtime.config.workspace_dir);
                try dual.syncFromMarkdown(allocator);
                old_memory.deinit();
                rt.memory = dual.memory();
                rt.setVectorUserScope(numeric_user_id);
                rt.capabilities = .{
                    .supports_keyword_rank = true,
                    .supports_session_store = false,
                    .supports_transactions = true,
                    .supports_outbox = false,
                };
                rt.resolved.primary_backend = "zaki_dual";
                log.info("memory runtime wrapped: configured_backend={s} runtime_backend={s}", .{
                    runtime.config.memory.backend,
                    rt.resolved.primary_backend,
                });
                try rebuildTenantMemoryEngine(allocator, rt, &runtime.config.memory, runtime.config.workspace_dir);
            }
        }

        const subagent_manager = allocator.create(subagent_mod.SubagentManager) catch null;
        if (subagent_manager) |mgr| {
            mgr.* = subagent_mod.SubagentManager.init(allocator, &runtime.config, event_bus, .{});
            if (state_mgr) |tenant_state_mgr| {
                const numeric_user_id = std.fmt.parseInt(i64, user_ctx.user_id, 10) catch return error.InvalidTenantUserId;
                mgr.attachPostgresLedger(tenant_state_mgr, numeric_user_id);
            }
        }
        runtime.subagent_manager = subagent_manager;
        errdefer if (runtime.subagent_manager) |mgr| {
            mgr.deinit();
            allocator.destroy(mgr);
        };
        runtime.completion_router = if (runtime.subagent_manager != null) allocator.create(SubagentCompletionRouter) catch null else null;
        errdefer if (runtime.completion_router) |router| allocator.destroy(router);

        runtime.tools = tools_mod.allTools(allocator, runtime.config.workspace_dir, .{
            .config = &runtime.config,
            .http_enabled = runtime.config.http_request.enabled,
            .browser_enabled = runtime.config.browser.enabled,
            .screenshot_enabled = true,
            .composio_api_key = if (runtime.config.composio.enabled) runtime.config.composio.api_key else null,
            .composio_entity_id = user_ctx.user_id,
            .browser_open_domains = if (runtime.config.browser.allowed_domains.len > 0) runtime.config.browser.allowed_domains else null,
            .agents = runtime.config.agents,
            .fallback_api_key = resolved_api_key,
            .event_bus = event_bus,
            .tools_config = runtime.config.tools,
            .allowed_paths = runtime.config.autonomy.allowed_paths,
            .policy = if (runtime.sec_policy) |*policy| policy else null,
            .subagent_manager = runtime.subagent_manager,
        }) catch &.{};
        errdefer if (runtime.tools.len > 0) tools_mod.deinitTools(allocator, runtime.tools);

        const log_obs = try allocator.create(observability.LogObserver);
        errdefer allocator.destroy(log_obs);
        log_obs.* = .{};
        runtime.log_obs = log_obs;
        runtime.observer_slots = .{
            runtime.log_obs.observer(),
            runtime.metrics_obs.observer(),
        };
        runtime.observer_multi = .{ .observers = runtime.observer_slots[0..] };

        const mem_opt: ?memory_mod.Memory = if (runtime.mem_rt) |rt| rt.memory else null;
        runtime.session_mgr = session_mod.SessionManager.init(
            allocator,
            &runtime.config,
            provider_i,
            runtime.tools,
            mem_opt,
            runtime.observer_multi.observer(),
            if (runtime.pg_session_store) |store| store.sessionStore() else if (runtime.mem_rt) |rt| rt.session_store else null,
            if (runtime.mem_rt) |*rt| rt.response_cache else null,
        );
        errdefer runtime.session_mgr.deinit();

        if (runtime.sec_policy) |*policy| {
            runtime.session_mgr.policy = policy;
        }

        if (runtime.mem_rt) |*rt| {
            runtime.session_mgr.mem_rt = rt;
            tools_mod.bindMemoryRuntime(runtime.tools, rt);
        }
        if (runtime.subagent_manager) |mgr| {
            if (runtime.completion_router) |router| {
                router.* = .{
                    .session_mgr = &runtime.session_mgr,
                    .event_bus = event_bus,
                    .config = &runtime.config,
                    .state = gateway_state,
                };
                mgr.attachCompletionDelivery(@ptrCast(router), appendSubagentCompletionToGatewaySession);
            }
        }

        log.info("tenant.runtime.config user={s} source={s} hash={x}", .{
            runtime.user_id,
            runtime.effective_config_source,
            runtime.effective_config_hash,
        });

        return runtime;
    }

    fn rebuildTenantMemoryEngine(
        allocator: std.mem.Allocator,
        rt: *memory_mod.MemoryRuntime,
        config: *const config_types.MemoryConfig,
        workspace_dir: []const u8,
    ) !void {
        if (rt._engine) |engine| {
            engine.deinit();
            allocator.destroy(engine);
            rt._engine = null;
        }
        if (!config.search.enabled) {
            rt.resolved.retrieval_mode = "disabled";
            rt.resolved.source_count = 0;
            return;
        }

        const eng = try allocator.create(memory_mod.RetrievalEngine);
        errdefer allocator.destroy(eng);
        eng.* = memory_mod.RetrievalEngine.init(allocator, config.search.query);

        const primary = try allocator.create(memory_mod.PrimaryAdapter);
        errdefer allocator.destroy(primary);
        primary.* = memory_mod.PrimaryAdapter.init(rt.memory);
        primary.owns_self = true;
        primary.allocator = allocator;
        try eng.addSource(primary.adapter());

        var source_count: usize = 1;
        if (config.qmd.enabled) {
            const qmd = try allocator.create(memory_mod.QmdAdapter);
            errdefer allocator.destroy(qmd);
            qmd.* = memory_mod.QmdAdapter.init(allocator, config.qmd, workspace_dir);
            qmd.owns_self = true;
            try eng.addSource(qmd.adapter());
            source_count += 1;
        }

        eng.setRetrievalStages(config.retrieval_stages);
        if (rt._embedding_provider) |provider| {
            if (rt._vector_store) |store| {
                eng.setVectorSearch(provider, store, rt._circuit_breaker, config.search.query.hybrid);
            }
        }
        rt._engine = eng;
        rt.resolved.retrieval_mode = if (rt._vector_store != null and rt._embedding_provider != null) "hybrid" else "keyword";
        rt.resolved.source_count = source_count;
    }

    fn deinit(self: *TenantRuntime) void {
        self.session_mgr.deinit();
        if (self.tools.len > 0) tools_mod.deinitTools(self.allocator, self.tools);
        if (self.subagent_manager) |mgr| {
            mgr.deinit();
            self.allocator.destroy(mgr);
        }
        if (self.completion_router) |router| {
            self.allocator.destroy(router);
        }
        if (self.pg_session_store) |store| {
            store.deinit();
            self.allocator.destroy(store);
        }
        if (self.mem_rt) |*rt| rt.deinit();
        if (self.sec_tracker) |*tracker| tracker.deinit();
        self.provider_bundle.deinit();
        self.allocator.destroy(self.log_obs);
        self.allocator.free(self.workspace_path);
        self.allocator.free(self.user_id);
        self.allocator.destroy(self);
    }

    fn processMessage(
        self: *TenantRuntime,
        session_key: []const u8,
        message: []const u8,
        conversation_context: ?agent_prompt.ConversationContext,
        message_turn_context: ?tools_mod.MessageTurnContext,
        progress_observer: ?Observer,
    ) ![]const u8 {
        self.last_used_s.store(std.time.timestamp(), .release);
        const numeric_user_id = std.fmt.parseInt(i64, self.user_id, 10) catch null;
        tools_mod.setTenantContext(.{
            .user_id = self.user_id,
            .numeric_user_id = numeric_user_id,
            .session_key = session_key,
            .state_mgr = self.state_mgr,
            .expect_postgres_state = self.config.tenant.enabled and std.mem.eql(u8, self.config.state.backend, "postgres"),
        });
        defer tools_mod.clearTenantContext();
        const response = try self.session_mgr.processMessageWithContext(session_key, message, conversation_context, .{
            .message_turn_context = message_turn_context,
            .progress_observer = progress_observer,
        });
        return response;
    }
};

fn removeTenantRuntime(state: *GatewayState, user_id: []const u8) void {
    if (state.tenant_runtimes.fetchRemove(user_id)) |kv| {
        kv.value.deinit();
    }
}

fn clearAllTenantRuntimes(state: *GatewayState) usize {
    var removed: usize = 0;
    while (state.tenant_runtimes.count() > 0) {
        var it = state.tenant_runtimes.iterator();
        const entry = it.next() orelse break;
        const key_copy = state.allocator.dupe(u8, entry.key_ptr.*) catch break;
        defer state.allocator.free(key_copy);
        removeTenantRuntime(state, key_copy);
        removed += 1;
    }
    return removed;
}

const TenantRuntimeInvalidationRequest = struct {
    all: bool = false,
    user_ids: []const []const u8 = &.{},

    fn deinit(self: TenantRuntimeInvalidationRequest, allocator: std.mem.Allocator) void {
        for (self.user_ids) |user_id| allocator.free(user_id);
        allocator.free(self.user_ids);
    }
};

fn appendTenantRuntimeInvalidationUserId(
    allocator: std.mem.Allocator,
    user_ids: *std.ArrayListUnmanaged([]const u8),
    value: std.json.Value,
) !void {
    switch (value) {
        .string => try user_ids.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, value.string, " \t\r\n"))),
        .integer => try user_ids.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{value.integer})),
        else => return error.InvalidPayload,
    }
}

fn parseTenantRuntimeInvalidationRequest(
    allocator: std.mem.Allocator,
    header_user_id: ?[]const u8,
    body: ?[]const u8,
) !TenantRuntimeInvalidationRequest {
    var user_ids: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (user_ids.items) |user_id| allocator.free(user_id);
        user_ids.deinit(allocator);
    }

    var all = false;
    if (body) |payload| {
        const trimmed = std.mem.trim(u8, payload, " \t\r\n");
        if (trimmed.len > 0) {
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidPayload;
            if (parsed.value.object.get("all")) |all_value| {
                if (all_value != .bool) return error.InvalidPayload;
                all = all_value.bool;
            }
            if (parsed.value.object.get("user_id")) |user_id_value| {
                try appendTenantRuntimeInvalidationUserId(allocator, &user_ids, user_id_value);
            }
            if (parsed.value.object.get("user_ids")) |user_ids_value| {
                if (user_ids_value != .array) return error.InvalidPayload;
                for (user_ids_value.array.items) |item| {
                    try appendTenantRuntimeInvalidationUserId(allocator, &user_ids, item);
                }
            }
        }
    }

    if (!all and user_ids.items.len == 0) {
        if (header_user_id) |value| {
            try user_ids.append(allocator, try allocator.dupe(u8, value));
        } else {
            return error.InvalidPayload;
        }
    }

    return .{
        .all = all,
        .user_ids = try user_ids.toOwnedSlice(allocator),
    };
}

fn pruneTenantRuntimeCache(state: *GatewayState, now_s: i64) void {
    const prune_start_ms = std.time.milliTimestamp();
    var idle_removed: usize = 0;
    var capacity_removed: usize = 0;
    defer {
        const duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - prune_start_ms));
        state.lifecycle_metrics.recordPruning(duration_ms, idle_removed, capacity_removed);
    }

    const ttl_s: i64 = @intCast(state.tenant_runtime_idle_ttl_secs);
    if (ttl_s > 0 and state.tenant_runtimes.count() > 0) {
        var stale_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (stale_keys.items) |k| state.allocator.free(k);
            stale_keys.deinit(state.allocator);
        }
        var it = state.tenant_runtimes.iterator();
        while (it.next()) |entry| {
            const rt = entry.value_ptr.*;
            const last_used = rt.last_used_s.load(.acquire);
            if (now_s - last_used > ttl_s) {
                const key_copy = state.allocator.dupe(u8, entry.key_ptr.*) catch continue;
                stale_keys.append(state.allocator, key_copy) catch state.allocator.free(key_copy);
            }
        }
        for (stale_keys.items) |key| {
            removeTenantRuntime(state, key);
            idle_removed += 1;
        }
    }

    const max_users: usize = @intCast(@max(@as(u32, 1), state.tenant_runtime_cache_max_users));
    while (state.tenant_runtimes.count() > max_users and state.tenant_runtimes.count() > 0) {
        var oldest_key: ?[]u8 = null;
        var oldest_ts: i64 = std.math.maxInt(i64);
        var it = state.tenant_runtimes.iterator();
        while (it.next()) |entry| {
            const rt = entry.value_ptr.*;
            const last_used = rt.last_used_s.load(.acquire);
            if (last_used < oldest_ts) {
                oldest_ts = last_used;
                if (oldest_key) |prev| state.allocator.free(prev);
                oldest_key = state.allocator.dupe(u8, entry.key_ptr.*) catch null;
            }
        }
        if (oldest_key) |key| {
            defer state.allocator.free(key);
            removeTenantRuntime(state, key);
            capacity_removed += 1;
        } else {
            break;
        }
    }
}

fn runTenantRuntimeMaintenance(state: *GatewayState, now_s: i64) void {
    state.tenant_runtime_mutex.lock();
    defer state.tenant_runtime_mutex.unlock();
    var it = state.tenant_runtimes.iterator();
    while (it.next()) |entry| {
        const runtime = entry.value_ptr.*;
        if (runtime.config.agent.session_idle_timeout_secs > 0) {
            _ = runtime.session_mgr.evictIdle(runtime.config.agent.session_idle_timeout_secs);
        }
    }
    pruneTenantRuntimeCache(state, now_s);
}

fn getTenantRuntime(
    state: *GatewayState,
    config: *const Config,
    user_ctx: *const UserContext,
) !*TenantRuntime {
    if (!gatewayRoleOwnsTenantExecution(state.role)) return error.ExecutionDelegated;
    if (state.role == .user_cell) {
        const pinned_user_id = state.pinned_user_id orelse return error.UserCellUserMismatch;
        if (!std.mem.eql(u8, pinned_user_id, user_ctx.user_id)) return error.UserCellUserMismatch;
    }
    const now_s = std.time.timestamp();
    state.tenant_runtime_mutex.lock();
    defer state.tenant_runtime_mutex.unlock();

    if (state.tenant_runtimes.get(user_ctx.user_id)) |runtime| {
        runtime.last_used_s.store(now_s, .release);
        return runtime;
    }

    const runtime = try TenantRuntime.init(state.allocator, config, user_ctx, state.event_bus, state.zaki_state, state, &state.lifecycle_metrics);
    if (runtime.session_mgr.policy != null) {
        state.tenant_runtime_policy_attached.store(true, .monotonic);
    }
    try state.tenant_runtimes.put(state.allocator, runtime.user_id, runtime);
    return runtime;
}

/// Publish an inbound message to the event bus. Returns true on success.
fn publishToBus(
    eb: *bus_mod.Bus,
    allocator: std.mem.Allocator,
    channel: []const u8,
    sender_id: []const u8,
    chat_id: []const u8,
    content: []const u8,
    session_key: []const u8,
    metadata_json: ?[]const u8,
) bool {
    const msg = bus_mod.makeInboundFull(
        allocator,
        channel,
        sender_id,
        chat_id,
        content,
        session_key,
        &.{},
        metadata_json,
    ) catch return false;
    eb.publishInbound(msg) catch {
        msg.deinit(allocator);
        return false;
    };
    return true;
}

/// Check if all registered health components are OK.
fn isHealthOk() bool {
    const snap = health.snapshot();
    var iter = snap.components.iterator();
    while (iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.value_ptr.status, "ok")) return false;
    }
    return true;
}

/// Readiness response — encapsulates HTTP status and body for /ready.
pub const ReadyResponse = struct {
    http_status: []const u8,
    body: []const u8,
    /// Whether body was allocated and should be freed by caller.
    allocated: bool,
};

const BrokerCellControlRoute = enum {
    resolve,
    ensure,
    status,
    drain,
};

const BrokerCellControlResponse = struct {
    status: []const u8,
    body: []const u8,
    allocated: bool = false,
};

const BrokerResolvedCell = struct {
    const State = enum {
        pending,
        warm,
        draining,
    };

    found: bool,
    cell_url: ?[]u8 = null,
    state: State = .pending,

    fn deinit(self: *BrokerResolvedCell, allocator: std.mem.Allocator) void {
        if (self.cell_url) |cell_url| allocator.free(cell_url);
        self.* = undefined;
    }
};

const BrokerProxyTarget = struct {
    target_url: []u8,
    cell_token: []const u8,

    fn deinit(self: *BrokerProxyTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.target_url);
        self.* = undefined;
    }
};

const ParsedUpstreamResponseHeader = struct {
    status_code: u16,
    body_offset: usize,
};

fn brokerCellControlRouteName(route: BrokerCellControlRoute) []const u8 {
    return switch (route) {
        .resolve => "resolve",
        .ensure => "ensure",
        .status => "status",
        .drain => "drain",
    };
}

fn controllerUrlWithPath(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, path });
}

fn normalizeAdvertiseUrl(allocator: std.mem.Allocator, raw_url: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, raw_url, " \t\r\n");
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (trimmed.len == 0) return error.InvalidAdvertiseUrl;
    if (!std.mem.startsWith(u8, trimmed, "http://") and !std.mem.startsWith(u8, trimmed, "https://")) {
        return error.InvalidAdvertiseUrl;
    }
    return allocator.dupe(u8, trimmed);
}

fn httpStatusLineFromCode(status_code: u16) []const u8 {
    return switch (status_code) {
        200 => "200 OK",
        201 => "201 Created",
        202 => "202 Accepted",
        204 => "204 No Content",
        400 => "400 Bad Request",
        401 => "401 Unauthorized",
        403 => "403 Forbidden",
        404 => "404 Not Found",
        405 => "405 Method Not Allowed",
        409 => "409 Conflict",
        422 => "422 Unprocessable Entity",
        429 => "429 Too Many Requests",
        500 => "500 Internal Server Error",
        501 => "501 Not Implemented",
        502 => "502 Bad Gateway",
        503 => "503 Service Unavailable",
        504 => "504 Gateway Timeout",
        else => "500 Internal Server Error",
    };
}

fn buildCellEnsurePayload(allocator: std.mem.Allocator, user_id: []const u8, cell_url: ?[]const u8) ![]u8 {
    if (cell_url) |value| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"user_id\":{f},\"cell_url\":{f}}}",
            .{ std.json.fmt(user_id, .{}), std.json.fmt(value, .{}) },
        );
    }
    return std.fmt.allocPrint(allocator, "{{\"user_id\":{f}}}", .{std.json.fmt(user_id, .{})});
}

fn extractRequestTarget(raw_request: []const u8) ?[]const u8 {
    const first_line_end = std.mem.indexOf(u8, raw_request, "\r\n") orelse return null;
    const first_line = raw_request[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    _ = parts.next() orelse return null;
    return parts.next();
}

fn performBrokerControllerRequest(
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    route: BrokerCellControlRoute,
    method: []const u8,
    request_body: ?[]const u8,
    user_id: ?[]const u8,
) BrokerCellControlResponse {
    if (state.role != .broker) {
        return .{ .status = "404 Not Found", .body = "{\"error\":\"not found\"}" };
    }
    const controller_url = state.controller_url orelse {
        return .{ .status = "503 Service Unavailable", .body = "{\"error\":\"controller_unavailable\"}" };
    };
    const controller_token = firstConfiguredInternalServiceToken(state.internal_service_tokens) orelse
        return .{ .status = "503 Service Unavailable", .body = "{\"error\":\"controller_token_missing\"}" };

    const path = switch (route) {
        .resolve => "/internal/cells/resolve",
        .ensure => "/internal/cells/ensure",
        .status => "/internal/cells/status",
        .drain => "/internal/cells/drain",
    };
    const url = controllerUrlWithPath(allocator, controller_url, path) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"controller_url_invalid\"}" };
    };
    defer allocator.free(url);

    const token_header = std.fmt.allocPrint(allocator, "X-Internal-Token: {s}", .{controller_token}) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"controller_headers_failed\"}" };
    };
    defer allocator.free(token_header);

    var user_id_header_storage: ?[]u8 = null;
    defer if (user_id_header_storage) |header| allocator.free(header);

    var headers_buf: [4][]const u8 = undefined;
    var headers_len: usize = 0;
    headers_buf[headers_len] = "User-Agent: nullalis-broker/1.0";
    headers_len += 1;
    headers_buf[headers_len] = token_header;
    headers_len += 1;
    if (user_id) |value| {
        user_id_header_storage = std.fmt.allocPrint(allocator, "X-Zaki-User-Id: {s}", .{value}) catch null;
        if (user_id_header_storage) |header| {
            headers_buf[headers_len] = header;
            headers_len += 1;
        }
    }

    const controller_response = http_util.curlRequest(
        allocator,
        method,
        url,
        headers_buf[0..headers_len],
        request_body,
        null,
        "10",
    ) catch {
        return .{ .status = "502 Bad Gateway", .body = "{\"error\":\"controller_request_failed\"}" };
    };
    defer allocator.free(controller_response.body);

    const body = allocator.dupe(u8, controller_response.body) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"controller_response_copy_failed\"}" };
    };
    return .{
        .status = httpStatusLineFromCode(controller_response.status_code),
        .body = body,
        .allocated = true,
    };
}

fn parseBrokerResolvedCell(allocator: std.mem.Allocator, body: []const u8) !BrokerResolvedCell {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidControllerResponse;

    const found_value = parsed.value.object.get("found") orelse return error.InvalidControllerResponse;
    if (found_value != .bool) return error.InvalidControllerResponse;

    var out = BrokerResolvedCell{ .found = found_value.bool };
    if (parsed.value.object.get("cell")) |cell_value| {
        if (cell_value != .object) return error.InvalidControllerResponse;
        if (cell_value.object.get("state")) |state_value| {
            out.state = switch (state_value) {
                .string => |value| blk: {
                    if (std.mem.eql(u8, value, "pending")) break :blk .pending;
                    if (std.mem.eql(u8, value, "warm")) break :blk .warm;
                    if (std.mem.eql(u8, value, "draining")) break :blk .draining;
                    return error.InvalidControllerResponse;
                },
                else => return error.InvalidControllerResponse,
            };
        }
        if (cell_value.object.get("cell_url")) |cell_url_value| {
            switch (cell_url_value) {
                .null => {},
                .string => |value| out.cell_url = try allocator.dupe(u8, value),
                else => return error.InvalidControllerResponse,
            }
        }
    }
    return out;
}

fn parseUpstreamResponseHeader(buffer: []const u8) !ParsedUpstreamResponseHeader {
    const header_end = std.mem.indexOf(u8, buffer, "\r\n\r\n") orelse return error.NeedMoreData;
    const first_line_end = std.mem.indexOf(u8, buffer, "\r\n") orelse return error.InvalidUpstreamResponse;
    const first_line = buffer[0..first_line_end];
    if (!std.mem.startsWith(u8, first_line, "HTTP/")) return error.InvalidUpstreamResponse;

    var parts = std.mem.splitScalar(u8, first_line, ' ');
    _ = parts.next() orelse return error.InvalidUpstreamResponse;
    const status_code_raw = parts.next() orelse return error.InvalidUpstreamResponse;
    const status_code = std.fmt.parseInt(u16, status_code_raw, 10) catch return error.InvalidUpstreamResponse;
    return .{
        .status_code = status_code,
        .body_offset = header_end + 4,
    };
}

fn resolveBrokerCell(
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    user_id: []const u8,
) !BrokerResolvedCell {
    const payload = try buildCellEnsurePayload(allocator, user_id, null);
    defer allocator.free(payload);

    const response = performBrokerControllerRequest(allocator, state, .resolve, "POST", payload, user_id);
    defer if (response.allocated) allocator.free(@constCast(response.body));
    if (!std.mem.eql(u8, response.status, "200 OK")) return error.ControllerResolveFailed;

    return parseBrokerResolvedCell(allocator, response.body);
}

fn ensureBrokerCell(
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    user_id: []const u8,
) !BrokerResolvedCell {
    const payload = try buildCellEnsurePayload(allocator, user_id, null);
    defer allocator.free(payload);

    const response = performBrokerControllerRequest(allocator, state, .ensure, "POST", payload, user_id);
    defer if (response.allocated) allocator.free(@constCast(response.body));
    if (!std.mem.eql(u8, response.status, "200 OK")) return error.ControllerEnsureFailed;

    return parseBrokerResolvedCell(allocator, response.body);
}

fn prepareBrokerProxyTarget(
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    user_id: []const u8,
    target: []const u8,
) !BrokerProxyTarget {
    var resolved = try resolveBrokerCell(allocator, state, user_id);
    defer resolved.deinit(allocator);

    if (!resolved.found) {
        var ensured = try ensureBrokerCell(allocator, state, user_id);
        defer ensured.deinit(allocator);
        return switch (ensured.state) {
            .pending => error.CellPending,
            .draining => error.CellDraining,
            .warm => if (ensured.cell_url == null) error.CellUnavailable else .{
                .target_url = try controllerUrlWithPath(allocator, ensured.cell_url.?, target),
                .cell_token = firstConfiguredInternalServiceToken(state.internal_service_tokens) orelse return error.CellTokenMissing,
            },
        };
    }
    switch (resolved.state) {
        .pending => return error.CellPending,
        .draining => return error.CellDraining,
        .warm => {},
    }
    if (resolved.cell_url == null) return error.CellUnavailable;

    const cell_token = firstConfiguredInternalServiceToken(state.internal_service_tokens) orelse
        return error.CellTokenMissing;
    const target_url = try controllerUrlWithPath(allocator, resolved.cell_url.?, target);
    return .{
        .target_url = target_url,
        .cell_token = cell_token,
    };
}

fn brokerProxyFailureResponse(
    allocator: std.mem.Allocator,
    content_type: []const u8,
    status: []const u8,
    code: []const u8,
    message: []const u8,
) RouteResponse {
    if (std.mem.eql(u8, content_type, "text/event-stream; charset=utf-8")) {
        const body = sseErrorEvent(allocator, code, message) catch
            "event: error\ndata: {\"type\":\"error\",\"code\":\"broker_proxy_failed\",\"message\":\"broker proxy failed\"}\n\nevent: done\ndata: {\"type\":\"done\"}\n\n";
        return .{
            .status = status,
            .body = body,
            .content_type = content_type,
        };
    }
    return .{
        .status = status,
        .body = std.fmt.allocPrint(allocator, "{{\"error\":{f}}}", .{std.json.fmt(code, .{})}) catch "{\"error\":\"broker_proxy_failed\"}",
        .content_type = content_type,
    };
}

fn brokerProxyApiRequest(
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    raw_request: []const u8,
    method: []const u8,
    target: []const u8,
    user_id: []const u8,
    content_type: []const u8,
    timeout_secs: []const u8,
) RouteResponse {
    var proxy_target = prepareBrokerProxyTarget(allocator, state, user_id, target) catch |err| {
        return switch (err) {
            error.CellPending => brokerProxyFailureResponse(
                allocator,
                content_type,
                "503 Service Unavailable",
                "cell_starting",
                "user cell is starting",
            ),
            error.CellDraining => brokerProxyFailureResponse(
                allocator,
                content_type,
                "503 Service Unavailable",
                "cell_draining",
                "user cell is draining",
            ),
            error.CellUnavailable => brokerProxyFailureResponse(
                allocator,
                content_type,
                "503 Service Unavailable",
                "cell_unavailable",
                "user cell is not registered",
            ),
            error.CellTokenMissing => brokerProxyFailureResponse(
                allocator,
                content_type,
                "503 Service Unavailable",
                "cell_token_missing",
                "cell token missing",
            ),
            else => brokerProxyFailureResponse(
                allocator,
                content_type,
                "502 Bad Gateway",
                "controller_request_failed",
                "controller request failed",
            ),
        };
    };
    defer proxy_target.deinit(allocator);

    const token_header = std.fmt.allocPrint(allocator, "X-Internal-Token: {s}", .{proxy_target.cell_token}) catch {
        return brokerProxyFailureResponse(
            allocator,
            content_type,
            "500 Internal Server Error",
            "cell_headers_failed",
            "cell headers failed",
        );
    };
    defer allocator.free(token_header);
    const user_header = std.fmt.allocPrint(allocator, "X-Zaki-User-Id: {s}", .{user_id}) catch {
        return brokerProxyFailureResponse(
            allocator,
            content_type,
            "500 Internal Server Error",
            "cell_headers_failed",
            "cell headers failed",
        );
    };
    defer allocator.free(user_header);

    var content_type_header_storage: ?[]u8 = null;
    defer if (content_type_header_storage) |value| allocator.free(value);

    var headers_buf: [4][]const u8 = undefined;
    var headers_len: usize = 0;
    headers_buf[headers_len] = "User-Agent: nullalis-broker/1.0";
    headers_len += 1;
    headers_buf[headers_len] = token_header;
    headers_len += 1;
    headers_buf[headers_len] = user_header;
    headers_len += 1;
    if (extractHeader(raw_request, "Content-Type")) |header_value| {
        content_type_header_storage = std.fmt.allocPrint(allocator, "Content-Type: {s}", .{header_value}) catch null;
        if (content_type_header_storage) |header| {
            headers_buf[headers_len] = header;
            headers_len += 1;
        }
    }

    const request_body = if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD")) null else extractBody(raw_request);
    const proxy_response = http_util.curlRequest(
        allocator,
        method,
        proxy_target.target_url,
        headers_buf[0..headers_len],
        request_body,
        null,
        timeout_secs,
    ) catch {
        return brokerProxyFailureResponse(
            allocator,
            content_type,
            "502 Bad Gateway",
            "cell_request_failed",
            "user cell request failed",
        );
    };
    return .{
        .status = httpStatusLineFromCode(proxy_response.status_code),
        .body = proxy_response.body,
        .content_type = content_type,
    };
}

fn sendStreamingProxyResponseHeader(stream: anytype, status: []const u8, content_type: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nCache-Control: no-cache\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\n",
        .{ status, content_type },
    );
    try stream.writeAll(header);
}

fn brokerProxyChatStreamSseConnection(
    allocator: std.mem.Allocator,
    stream: anytype,
    state: *const GatewayState,
    raw_request: []const u8,
    method: []const u8,
    target: []const u8,
    user_id: []const u8,
) void {
    var proxy_target = prepareBrokerProxyTarget(allocator, state, user_id, target) catch |err| {
        switch (err) {
            error.CellPending => sendSseErrorResponse(stream, allocator, "503 Service Unavailable", "cell_starting", "user cell is starting"),
            error.CellDraining => sendSseErrorResponse(stream, allocator, "503 Service Unavailable", "cell_draining", "user cell is draining"),
            error.CellUnavailable => sendSseErrorResponse(stream, allocator, "503 Service Unavailable", "cell_unavailable", "user cell is not registered"),
            error.CellTokenMissing => sendSseErrorResponse(stream, allocator, "503 Service Unavailable", "cell_token_missing", "cell token missing"),
            else => sendSseErrorResponse(stream, allocator, "502 Bad Gateway", "controller_request_failed", "controller request failed"),
        }
        return;
    };
    defer proxy_target.deinit(allocator);

    var argv_buf: [64][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-sS";
    argc += 1;
    argv_buf[argc] = "-N";
    argc += 1;
    argv_buf[argc] = "--include";
    argc += 1;
    argv_buf[argc] = "--max-time";
    argc += 1;
    argv_buf[argc] = "3600";
    argc += 1;
    argv_buf[argc] = "--request";
    argc += 1;
    argv_buf[argc] = method;
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "User-Agent: nullalis-broker/1.0";
    argc += 1;

    const token_header = std.fmt.allocPrint(allocator, "X-Internal-Token: {s}", .{proxy_target.cell_token}) catch {
        sendSseErrorResponse(stream, allocator, "500 Internal Server Error", "cell_headers_failed", "cell headers failed");
        return;
    };
    defer allocator.free(token_header);
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = token_header;
    argc += 1;

    const user_header = std.fmt.allocPrint(allocator, "X-Zaki-User-Id: {s}", .{user_id}) catch {
        sendSseErrorResponse(stream, allocator, "500 Internal Server Error", "cell_headers_failed", "cell headers failed");
        return;
    };
    defer allocator.free(user_header);
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = user_header;
    argc += 1;

    var content_type_header_storage: ?[]u8 = null;
    defer if (content_type_header_storage) |value| allocator.free(value);
    if (extractHeader(raw_request, "Content-Type")) |header_value| {
        content_type_header_storage = std.fmt.allocPrint(allocator, "Content-Type: {s}", .{header_value}) catch null;
        if (content_type_header_storage) |header| {
            argv_buf[argc] = "-H";
            argc += 1;
            argv_buf[argc] = header;
            argc += 1;
        }
    }

    const request_body = if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD")) null else extractBody(raw_request);
    if (request_body != null) {
        argv_buf[argc] = "--data-binary";
        argc += 1;
        argv_buf[argc] = "@-";
        argc += 1;
    }

    argv_buf[argc] = proxy_target.target_url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = if (request_body != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        sendSseErrorResponse(stream, allocator, "502 Bad Gateway", "cell_request_failed", "user cell request failed");
        return;
    };

    if (request_body) |body| {
        if (child.stdin) |stdin_file| {
            stdin_file.writeAll(body) catch {
                stdin_file.close();
                child.stdin = null;
                _ = child.kill() catch {};
                _ = child.wait() catch {};
                sendSseErrorResponse(stream, allocator, "502 Bad Gateway", "cell_request_failed", "user cell request failed");
                return;
            };
            stdin_file.close();
            child.stdin = null;
        } else {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            sendSseErrorResponse(stream, allocator, "502 Bad Gateway", "cell_request_failed", "user cell request failed");
            return;
        }
    }

    var response_started = false;
    var header_bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer header_bytes.deinit(allocator);
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = child.stdout.?.read(&read_buf) catch {
            if (!response_started) {
                _ = child.kill() catch {};
                _ = child.wait() catch {};
                sendSseErrorResponse(stream, allocator, "502 Bad Gateway", "cell_request_failed", "user cell request failed");
            }
            return;
        };
        if (n == 0) break;
        const chunk = read_buf[0..n];

        if (!response_started) {
            header_bytes.appendSlice(allocator, chunk) catch {
                _ = child.kill() catch {};
                _ = child.wait() catch {};
                sendSseErrorResponse(stream, allocator, "500 Internal Server Error", "cell_response_buffer_failed", "user cell response buffering failed");
                return;
            };

            const parsed = parseUpstreamResponseHeader(header_bytes.items) catch |err| switch (err) {
                error.NeedMoreData => continue,
                else => {
                    _ = child.kill() catch {};
                    _ = child.wait() catch {};
                    sendSseErrorResponse(stream, allocator, "502 Bad Gateway", "cell_response_invalid", "user cell response invalid");
                    return;
                },
            };

            sendStreamingProxyResponseHeader(stream, httpStatusLineFromCode(parsed.status_code), "text/event-stream; charset=utf-8") catch {
                _ = child.kill() catch {};
                _ = child.wait() catch {};
                return;
            };
            response_started = true;

            const body_chunk = header_bytes.items[parsed.body_offset..];
            if (body_chunk.len > 0) {
                stream.writeAll(body_chunk) catch {
                    _ = child.kill() catch {};
                    _ = child.wait() catch {};
                    return;
                };
            }
            header_bytes.clearRetainingCapacity();
            continue;
        }

        stream.writeAll(chunk) catch {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return;
        };
    }

    const term = child.wait() catch {
        if (!response_started) {
            sendSseErrorResponse(stream, allocator, "502 Bad Gateway", "cell_request_failed", "user cell request failed");
        }
        return;
    };

    if (!response_started) {
        _ = term;
        sendSseErrorResponse(stream, allocator, "502 Bad Gateway", "cell_response_invalid", "user cell response invalid");
    }
}

fn handleBrokerCellControlRoute(
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    raw: []const u8,
    method: []const u8,
    route: BrokerCellControlRoute,
) BrokerCellControlResponse {
    const required_method = switch (route) {
        .status => "GET",
        .resolve, .ensure, .drain => "POST",
    };
    if (!std.mem.eql(u8, method, required_method)) {
        return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
    }
    if (!validateInternalServiceToken(raw, state)) {
        return .{ .status = "401 Unauthorized", .body = "{\"error\":\"unauthorized\"}" };
    }
    return performBrokerControllerRequest(
        allocator,
        state,
        route,
        required_method,
        if (std.mem.eql(u8, required_method, "POST")) extractBody(raw) else null,
        extractHeader(raw, "X-Zaki-User-Id"),
    );
}

/// Handle the /ready endpoint logic. Queries the global health registry
/// and returns the appropriate HTTP status and JSON body.
/// If `allocated` is true in the result, the caller owns `body` memory.
pub fn handleReady(allocator: std.mem.Allocator) ReadyResponse {
    const readiness = health.checkRegistryReadiness(allocator) catch {
        return .{
            .http_status = "500 Internal Server Error",
            .body = "{\"status\":\"not_ready\",\"checks\":[]}",
            .allocated = false,
        };
    };
    // formatJson must be called before freeing the checks slice
    const json_body = readiness.formatJson(allocator) catch {
        if (readiness.checks.len > 0) {
            allocator.free(readiness.checks);
        }
        return .{
            .http_status = "500 Internal Server Error",
            .body = "{\"status\":\"not_ready\",\"checks\":[]}",
            .allocated = false,
        };
    };
    if (readiness.checks.len > 0) {
        allocator.free(readiness.checks);
    }
    return .{
        .http_status = if (readiness.status == .ready) "200 OK" else "503 Service Unavailable",
        .body = json_body,
        .allocated = true,
    };
}

/// Extract a query parameter value from a URL target string.
/// e.g. parseQueryParam("/whatsapp?hub.mode=subscribe&hub.challenge=abc", "hub.challenge") => "abc"
/// Returns null if the parameter is not found.
pub fn parseQueryParam(target: []const u8, name: []const u8) ?[]const u8 {
    const qmark = std.mem.indexOf(u8, target, "?") orelse return null;
    var query = target[qmark + 1 ..];

    while (query.len > 0) {
        // Find end of this key=value pair
        const amp = std.mem.indexOf(u8, query, "&") orelse query.len;
        const pair = query[0..amp];

        // Split on '='
        const eq = std.mem.indexOf(u8, pair, "=");
        if (eq) |eq_pos| {
            const key = pair[0..eq_pos];
            const value = pair[eq_pos + 1 ..];
            if (std.mem.eql(u8, key, name)) return value;
        }

        // Advance past the '&'
        if (amp < query.len) {
            query = query[amp + 1 ..];
        } else {
            break;
        }
    }
    return null;
}

// ── Bearer Token Validation ──────────────────────────────────────

/// Validate a bearer token against a list of paired tokens.
/// Returns true if paired_tokens is empty (backwards compat) or token matches.
pub fn validateBearerToken(token: []const u8, paired_tokens: []const []const u8) bool {
    if (paired_tokens.len == 0) return true;
    for (paired_tokens) |pt| {
        if (std.mem.eql(u8, token, pt)) return true;
    }
    return false;
}

/// Extract the value of a named header from raw HTTP bytes.
/// Searches for "Name: value\r\n" (case-insensitive name match).
pub fn extractHeader(raw: []const u8, name: []const u8) ?[]const u8 {
    // Skip past the first line (request line)
    var pos: usize = 0;
    while (pos + 1 < raw.len) {
        if (raw[pos] == '\r' and raw[pos + 1] == '\n') {
            pos += 2;
            break;
        }
        pos += 1;
    }

    // Scan headers
    while (pos < raw.len) {
        // Find end of this header line
        const line_end = std.mem.indexOf(u8, raw[pos..], "\r\n") orelse break;
        const line = raw[pos .. pos + line_end];
        if (line.len == 0) break; // empty line = end of headers

        // Check if this line starts with "name:"
        if (line.len > name.len and line[name.len] == ':') {
            const header_name = line[0..name.len];
            if (asciiEqlIgnoreCase(header_name, name)) {
                // Skip ": " and any leading whitespace
                var val_start: usize = name.len + 1;
                while (val_start < line.len and line[val_start] == ' ') val_start += 1;
                return line[val_start..];
            }
        }

        pos += line_end + 2;
    }
    return null;
}

/// Extract the bearer token from an Authorization header value.
/// "Bearer <token>" -> "<token>", or null if format doesn't match.
pub fn extractBearerToken(auth_header: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (auth_header.len > prefix.len and std.mem.startsWith(u8, auth_header, prefix)) {
        return auth_header[prefix.len..];
    }
    return null;
}

fn headerEndOffset(raw: []const u8) ?usize {
    const separator = "\r\n\r\n";
    const pos = std.mem.indexOf(u8, raw, separator) orelse return null;
    return pos + separator.len;
}

fn expectedHttpRequestSize(raw: []const u8) !?usize {
    const header_end = headerEndOffset(raw) orelse {
        if (raw.len > MAX_HEADER_SIZE) return error.RequestTooLarge;
        return null;
    };
    if (header_end > MAX_HEADER_SIZE) return error.RequestTooLarge;

    const header_slice = raw[0..header_end];
    const content_length_raw = extractHeader(header_slice, "Content-Length") orelse return header_end;
    const trimmed = std.mem.trim(u8, content_length_raw, " \t");
    if (trimmed.len == 0) return error.InvalidContentLength;

    const content_length = std.fmt.parseInt(usize, trimmed, 10) catch return error.InvalidContentLength;
    if (content_length > MAX_BODY_SIZE) return error.RequestTooLarge;

    const total = std.math.add(usize, header_end, content_length) catch return error.RequestTooLarge;
    if (total > MAX_HTTP_REQUEST_SIZE) return error.RequestTooLarge;
    return total;
}

fn configureRequestReadTimeout(stream: std.net.Stream) void {
    // Zig 0.15.x on Darwin can panic inside std.posix.setsockopt for
    // SO_RCVTIMEO (EINVAL mapped to unreachable). Keep gateway stable by
    // skipping this socket-level timeout there; request timeout is still
    // enforced at higher layers.
    if (builtin.os.tag == .macos) return;
    if (!@hasDecl(std.posix.SO, "RCVTIMEO")) return;

    const timeout = std.posix.timeval{
        .sec = @intCast(REQUEST_TIMEOUT_SECS),
        .usec = 0,
    };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        &std.mem.toBytes(timeout),
    ) catch {};
}

fn readHttpRequestFromReader(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
    var request_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer request_buf.deinit(allocator);

    var expected_total: ?usize = null;
    var chunk: [2048]u8 = undefined;

    while (true) {
        const n = reader.read(&chunk) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionTimedOut => return error.RequestTimeout,
            else => return err,
        };
        if (n == 0) return error.IncompleteRequest;

        try request_buf.appendSlice(allocator, chunk[0..n]);
        if (request_buf.items.len > MAX_HTTP_REQUEST_SIZE) return error.RequestTooLarge;

        if (expected_total == null) {
            expected_total = try expectedHttpRequestSize(request_buf.items);
        }

        if (expected_total) |total| {
            if (request_buf.items.len >= total) {
                request_buf.items.len = total;
                return request_buf.toOwnedSlice(allocator);
            }
        }
    }
}

/// Read a full HTTP request (headers + body) from stream.
fn readHttpRequest(allocator: std.mem.Allocator, stream: anytype) ![]u8 {
    return readHttpRequestFromReader(allocator, stream);
}

fn extractInternalServiceToken(raw: []const u8) ?[]const u8 {
    if (extractHeader(raw, "X-Internal-Token")) |hdr| {
        const token = std.mem.trim(u8, hdr, " \t\r\n");
        if (token.len > 0) return token;
    }
    if (extractHeader(raw, "Authorization")) |hdr| {
        if (extractBearerToken(std.mem.trim(u8, hdr, " \t\r\n"))) |token| {
            if (token.len > 0) return token;
        }
    }
    return null;
}

pub const InternalTokenValidationResult = struct {
    ok: bool,
    configured: bool,
    reason: ?[]const u8 = null,
};

fn isLoopbackHost(host_raw: []const u8) bool {
    const host = std.mem.trim(u8, host_raw, " \t\r\n");
    if (host.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "127.0.0.1")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    if (std.mem.eql(u8, host, "[::1]")) return true;
    return false;
}

fn isProductionLikeGateway(cfg: *const Config, effective_host: []const u8) bool {
    _ = cfg.tenant.enabled;
    if (cfg.gateway.allow_public_bind) return true;
    return !isLoopbackHost(effective_host);
}

fn isInternalTokenDenylisted(token: []const u8) bool {
    for (INTERNAL_TOKEN_DENYLIST) |blocked| {
        if (std.ascii.eqlIgnoreCase(token, blocked)) return true;
    }
    return false;
}

pub fn validateInternalTokensForMode(
    internal_service_tokens: []const []const u8,
    production_like: bool,
) InternalTokenValidationResult {
    var has_non_empty = false;
    for (internal_service_tokens) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (token.len == 0) continue;
        has_non_empty = true;
        if (!production_like) continue;
        if (token.len < INTERNAL_TOKEN_MIN_LEN) {
            return .{
                .ok = false,
                .configured = true,
                .reason = "invalid_internal_service_token_too_short",
            };
        }
        if (isInternalTokenDenylisted(token)) {
            return .{
                .ok = false,
                .configured = true,
                .reason = "invalid_internal_service_token_denylisted",
            };
        }
    }

    if (production_like and !has_non_empty) {
        const reason: []const u8 = if (internal_service_tokens.len == 0)
            "missing_internal_service_tokens"
        else
            "invalid_internal_service_token_empty";
        return .{
            .ok = false,
            .configured = false,
            .reason = reason,
        };
    }

    return .{
        .ok = true,
        .configured = has_non_empty,
        .reason = null,
    };
}

fn firstConfiguredInternalServiceToken(internal_service_tokens: []const []const u8) ?[]const u8 {
    for (internal_service_tokens) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (token.len > 0) return token;
    }
    return null;
}

fn validateInternalServiceTokenWithPolicy(
    raw: []const u8,
    internal_service_tokens: []const []const u8,
    auth_required: bool,
) bool {
    if (internal_service_tokens.len == 0) return !auth_required;
    const provided = extractInternalServiceToken(raw) orelse return false;
    for (internal_service_tokens) |tok| {
        const expected = std.mem.trim(u8, tok, " \t\r\n");
        if (expected.len == 0) continue;
        if (std.mem.eql(u8, expected, provided)) return true;
    }
    return false;
}

fn validateInternalServiceToken(raw: []const u8, state: *const GatewayState) bool {
    return validateInternalServiceTokenWithPolicy(
        raw,
        state.internal_service_tokens,
        state.internal_auth_required,
    );
}

fn extractZakiUserId(raw: []const u8) ?[]const u8 {
    const hdr = extractHeader(raw, "X-Zaki-User-Id") orelse return null;
    const user_id = std.mem.trim(u8, hdr, " \t\r\n");
    if (!isValidIdentifier(user_id)) return null;
    return user_id;
}

fn isValidIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |c| {
        const is_alnum = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
        if (!(is_alnum or c == '-' or c == '_' or c == '.' or c == '@')) return false;
    }
    return true;
}

fn parseNumericUserId(user_id: []const u8) !i64 {
    return try std.fmt.parseInt(i64, user_id, 10);
}

fn usesPostgresTenantState(state: *const GatewayState) bool {
    return state.zaki_state != null;
}

fn userCellUserRootPath(allocator: std.mem.Allocator, workspace_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace_path, USER_CELL_STATE_DIR });
}

fn userCellHeartbeatRuntimePath(allocator: std.mem.Allocator, workspace_path: []const u8) ![]u8 {
    const user_root = try userCellUserRootPath(allocator, workspace_path);
    defer allocator.free(user_root);
    return std.fmt.allocPrint(allocator, "{s}/heartbeat_runtime.json", .{user_root});
}

fn normalizeWorkspacePath(allocator: std.mem.Allocator, workspace_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(workspace_path)) {
        return allocator.dupe(u8, workspace_path);
    }
    return std.fs.cwd().realpathAlloc(allocator, workspace_path) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
            defer allocator.free(cwd);
            break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, workspace_path });
        },
        else => return err,
    };
}

fn resolveUserContext(allocator: std.mem.Allocator, state: *const GatewayState, user_id: []const u8) !UserContext {
    if (!isValidIdentifier(user_id)) return error.InvalidUserId;
    if (state.role == .user_cell) {
        const pinned_user_id = state.pinned_user_id orelse return error.InvalidUserId;
        if (!std.mem.eql(u8, pinned_user_id, user_id)) return error.UserCellUserMismatch;
    }
    if (usesPostgresTenantState(state)) {
        _ = parseNumericUserId(user_id) catch return error.InvalidUserId;
    }
    const workspace_path = if (state.role == .user_cell)
        try normalizeWorkspacePath(allocator, state.workspace_dir)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}/workspace", .{ state.tenant_data_root, user_id });
    errdefer allocator.free(workspace_path);
    const user_root = if (state.role == .user_cell)
        try userCellUserRootPath(allocator, workspace_path)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ state.tenant_data_root, user_id });
    errdefer allocator.free(user_root);
    const memory_db_path = try std.fmt.allocPrint(allocator, "{s}/memory.db", .{user_root});
    errdefer allocator.free(memory_db_path);
    const cron_path = try std.fmt.allocPrint(allocator, "{s}/cron.json", .{user_root});
    errdefer allocator.free(cron_path);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{user_root});
    errdefer allocator.free(config_path);
    const heartbeat_path = try std.fmt.allocPrint(allocator, "{s}/heartbeat.json", .{user_root});
    errdefer allocator.free(heartbeat_path);
    const channel_state_path = try std.fmt.allocPrint(allocator, "{s}/channel_state.json", .{user_root});
    errdefer allocator.free(channel_state_path);
    const telegram_path = try std.fmt.allocPrint(allocator, "{s}/telegram.json", .{user_root});
    errdefer allocator.free(telegram_path);
    const secrets_dir = try std.fmt.allocPrint(allocator, "{s}/secrets", .{user_root});
    errdefer allocator.free(secrets_dir);

    return .{
        .user_id = user_id,
        .user_root = user_root,
        .workspace_path = workspace_path,
        .memory_db_path = memory_db_path,
        .cron_path = cron_path,
        .config_path = config_path,
        .heartbeat_path = heartbeat_path,
        .channel_state_path = channel_state_path,
        .telegram_path = telegram_path,
        .secrets_dir = secrets_dir,
    };
}

fn ensureUserDirectories(ctx: *const UserContext) !void {
    try makeAbsolutePath(ctx.user_root);
    try makeAbsolutePath(ctx.workspace_path);
    try makeAbsolutePath(ctx.secrets_dir);
}

fn ensureUserProvisioned(state: *GatewayState, ctx: *const UserContext) !void {
    try ensureUserDirectories(ctx);
    if (state.zaki_state) |mgr| {
        const user_id = try parseNumericUserId(ctx.user_id);
        try mgr.provisionUser(user_id, ctx.workspace_path);
    } else {
        ensureFileWithDefault(ctx.memory_db_path, "") catch {};
        ensureFileWithDefault(ctx.config_path, "{}\n") catch {};
        ensureFileWithDefault(ctx.cron_path, "[]\n") catch {};
        ensureFileWithDefault(ctx.heartbeat_path, "{}\n") catch {};
        ensureFileWithDefault(ctx.channel_state_path, "{}\n") catch {};
    }
}

fn prepareBrokerUserForRouting(allocator: std.mem.Allocator, state: *GatewayState, user_id: []const u8) !void {
    var user_ctx = try resolveUserContext(allocator, state, user_id);
    defer user_ctx.deinit(allocator);

    var prep_guard = try state.user_preparation_gate.acquire(user_ctx.user_id);
    defer prep_guard.deinit();

    try ensureUserDirectories(&user_ctx);
    try ensureUserProvisioned(state, &user_ctx);
    scaffoldUserWorkspace(allocator, &user_ctx);
    prep_guard.release();
}

const GatewayUserIdResolutionError = error{
    MissingUserId,
    UserCellUserMismatch,
};

fn resolveGatewayRequestUserId(
    state: *const GatewayState,
    primary_user_id: ?[]const u8,
    fallback_user_id: ?[]const u8,
    tenant_requires_primary_header: bool,
) GatewayUserIdResolutionError![]const u8 {
    if (state.role == .user_cell) {
        const pinned_user_id = state.pinned_user_id orelse return error.MissingUserId;
        if (primary_user_id) |value| {
            if (!std.mem.eql(u8, value, pinned_user_id)) return error.UserCellUserMismatch;
        }
        if (fallback_user_id) |value| {
            if (!std.mem.eql(u8, value, pinned_user_id)) return error.UserCellUserMismatch;
        }
        return pinned_user_id;
    }
    if (tenant_requires_primary_header and state.tenant_enabled and primary_user_id == null) {
        return error.MissingUserId;
    }
    return primary_user_id orelse fallback_user_id orelse error.MissingUserId;
}

fn resolveGatewayPathUserId(
    state: *const GatewayState,
    path_user_id: []const u8,
) GatewayUserIdResolutionError![]const u8 {
    if (state.role == .user_cell) {
        const pinned_user_id = state.pinned_user_id orelse return error.MissingUserId;
        if (!std.mem.eql(u8, path_user_id, pinned_user_id)) return error.UserCellUserMismatch;
        return pinned_user_id;
    }
    return path_user_id;
}

fn resolveGatewayOptionalUserId(
    state: *const GatewayState,
    user_id_opt: ?[]const u8,
) GatewayUserIdResolutionError!?[]const u8 {
    if (state.role == .user_cell) {
        const pinned_user_id = state.pinned_user_id orelse return error.MissingUserId;
        if (user_id_opt) |value| {
            if (!std.mem.eql(u8, value, pinned_user_id)) return error.UserCellUserMismatch;
        }
        return pinned_user_id;
    }
    return user_id_opt;
}

fn isIdentityUserNotFound(err: anyerror) bool {
    return std.mem.eql(u8, @errorName(err), "IdentityUserNotFound");
}

fn scaffoldUserWorkspace(allocator: std.mem.Allocator, ctx: *const UserContext) void {
    const project_ctx = onboard.zakiBotProjectContext();
    onboard.scaffoldWorkspace(allocator, ctx.workspace_path, &project_ctx) catch {};
}

fn makeAbsolutePath(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return err;
            if (std.mem.eql(u8, parent, path)) return err;
            try makeAbsolutePath(parent);
            try std.fs.makeDirAbsolute(path);
        },
        else => return err,
    };
}

fn ensureFileWithDefault(path: []const u8, default_content: []const u8) !void {
    if (std.fs.openFileAbsolute(path, .{})) |file| {
        file.close();
        return;
    } else |_| {}

    if (std.fs.path.dirname(path)) |dir| {
        try makeAbsolutePath(dir);
    }

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    if (default_content.len > 0) try file.writeAll(default_content);
}

fn readFileOrDefault(allocator: std.mem.Allocator, path: []const u8, default_content: []const u8) ![]u8 {
    if (std.fs.openFileAbsolute(path, .{})) |file| {
        defer file.close();
        return try file.readToEndAlloc(allocator, MAX_BODY_SIZE);
    } else |_| {}
    return try allocator.dupe(u8, default_content);
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn onboardingStatePath(allocator: std.mem.Allocator, user_root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/onboarding.json", .{user_root});
}

fn workspaceFilePath(allocator: std.mem.Allocator, workspace_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace_path, name });
}

fn writeTelegramChannelState(
    allocator: std.mem.Allocator,
    channel_state_path: []const u8,
    account_id: []const u8,
    chat_id: i64,
) !void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.writeAll("{\"telegram\":{\"connected\":true,\"account_id\":\"");
    try jsonEscapeInto(w, account_id);
    try w.print("\",\"chat_id\":{d},\"updated_at_s\":{d}}}", .{ chat_id, std.time.timestamp() });
    try w.writeAll("}");
    try writeFile(channel_state_path, out.items);
}

fn writeTelegramFallbackStateFile(path: []const u8, content: []const u8) !void {
    try writeFile(path, content);
}

fn syncTelegramSecretFallbackBestEffort(secret_path: []const u8, content: []const u8) bool {
    writeFile(secret_path, content) catch |err| {
        log.warn("telegram local secret fallback sync failed path={s}: {}", .{ secret_path, err });
        return false;
    };
    return true;
}

fn syncTelegramStateFallbackBestEffort(telegram_path: []const u8, content: []const u8) bool {
    writeTelegramFallbackStateFile(telegram_path, content) catch |err| {
        log.warn("telegram local state fallback sync failed path={s}: {}", .{ telegram_path, err });
        return false;
    };
    return true;
}

fn deleteTelegramFallbackFilesBestEffort(
    telegram_path: []const u8,
    channel_state_path: []const u8,
) bool {
    deleteTelegramFallbackFiles(telegram_path, channel_state_path) catch |err| {
        log.warn("telegram local fallback cleanup failed telegram_path={s} channel_state_path={s}: {}", .{
            telegram_path,
            channel_state_path,
            err,
        });
        return false;
    };
    return true;
}

fn deleteTelegramFallbackFiles(
    telegram_path: []const u8,
    channel_state_path: []const u8,
) !void {
    std.fs.deleteFileAbsolute(telegram_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.fs.deleteFileAbsolute(channel_state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn freeOwnedStringArray(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |item| allocator.free(item);
    allocator.free(values);
}

fn cloneJsonStringArrayValue(
    allocator: std.mem.Allocator,
    json_value: std.json.Value,
) ![]const []const u8 {
    if (json_value != .array) return error.InvalidJsonType;
    const arr = json_value.array.items;
    if (arr.len == 0) return &.{};
    var out = try allocator.alloc([]const u8, arr.len);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) allocator.free(out[j]);
        allocator.free(out);
    }
    for (arr) |item| {
        if (item != .string) return error.InvalidJsonType;
        out[i] = try allocator.dupe(u8, item.string);
        i += 1;
    }
    return out;
}

fn jsonStringArrayFieldOwned(
    allocator: std.mem.Allocator,
    body: []const u8,
    field_name: []const u8,
) ?[]const []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const field = parsed.value.object.get(field_name) orelse return null;
    return cloneJsonStringArrayValue(allocator, field) catch null;
}

const TelegramUserState = struct {
    connected: bool = false,
    account_id: ?[]const u8 = null,
    webhook_secret_token: ?[]const u8 = null,
    allow_from: []const []const u8 = &.{},
    webhook_url: ?[]const u8 = null,
    chat_id: ?i64 = null,

    fn deinit(self: *TelegramUserState, allocator: std.mem.Allocator) void {
        if (self.account_id) |v| allocator.free(v);
        if (self.webhook_secret_token) |v| allocator.free(v);
        if (self.webhook_url) |v| allocator.free(v);
        if (self.allow_from.len > 0) freeOwnedStringArray(allocator, self.allow_from);
    }
};

const HeartbeatStateSummary = struct {
    enabled: bool = false,
};

const HeartbeatRuntimeSummary = struct {
    available: bool = false,
    last_run_s: ?i64 = null,
    last_status: ?[]const u8 = null,
    last_reason: ?[]const u8 = null,

    fn deinit(self: *HeartbeatRuntimeSummary, allocator: std.mem.Allocator) void {
        if (self.last_status) |value| allocator.free(value);
        if (self.last_reason) |value| allocator.free(value);
        self.* = .{};
    }
};

const NormalizedTelegramReadiness = struct {
    configured: bool = false,
    connected_stored: bool = false,
    connected_normalized: bool = false,
    state_valid: bool = true,
    bot_token_present: bool = false,
    account_id: ?[]const u8 = null,
    chat_id: ?i64 = null,
    allow_from_count: usize = 0,
    data_source: []const u8 = "context_missing",

    fn deinit(self: *NormalizedTelegramReadiness, allocator: std.mem.Allocator) void {
        if (self.account_id) |value| allocator.free(value);
    }

    fn requiresReconnect(self: *const NormalizedTelegramReadiness) bool {
        return self.connected_stored and !self.state_valid;
    }

    fn statusLabel(self: *const NormalizedTelegramReadiness) []const u8 {
        if (self.requiresReconnect()) return "needs_reconnect";
        if (self.connected_normalized) return "connected";
        return "not_connected";
    }
};

fn parseTelegramUserState(allocator: std.mem.Allocator, body: []const u8) !TelegramUserState {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidTelegramState;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTelegramState;

    var state: TelegramUserState = .{};
    errdefer state.deinit(allocator);

    if (parsed.value.object.get("connected")) |connected| {
        if (connected != .bool) return error.InvalidTelegramState;
        state.connected = connected.bool;
    }
    if (parsed.value.object.get("account_id")) |account_id| {
        if (account_id != .string) return error.InvalidTelegramState;
        if (!isValidIdentifier(account_id.string)) return error.InvalidTelegramState;
        state.account_id = try allocator.dupe(u8, account_id.string);
    }
    if (parsed.value.object.get("webhook_secret_token")) |secret| {
        if (secret != .string) return error.InvalidTelegramState;
        const normalized = normalizeTelegramSecretToken(secret.string);
        if (normalized.len > 0) {
            state.webhook_secret_token = try allocator.dupe(u8, normalized);
        }
    }
    if (parsed.value.object.get("allow_from")) |allow_from| {
        state.allow_from = try cloneJsonStringArrayValue(allocator, allow_from);
        if (telegramAllowlistIsLegacyWildcard(state.allow_from)) {
            freeOwnedStringArray(allocator, state.allow_from);
            state.allow_from = &.{};
        }
    }
    if (parsed.value.object.get("webhook_url")) |webhook_url| {
        if (webhook_url != .string) return error.InvalidTelegramState;
        if (webhook_url.string.len > 0) {
            state.webhook_url = try allocator.dupe(u8, std.mem.trim(u8, webhook_url.string, " \t\r\n"));
        }
    }
    if (parsed.value.object.get("chat_id")) |chat_value| {
        state.chat_id = switch (chat_value) {
            .integer => chat_value.integer,
            .string => std.fmt.parseInt(i64, std.mem.trim(u8, chat_value.string, " \t\r\n"), 10) catch return error.InvalidTelegramState,
            else => return error.InvalidTelegramState,
        };
    }

    return state;
}

fn telegramAllowlistIsLegacyWildcard(values: []const []const u8) bool {
    if (values.len != 1) return false;
    return std.mem.eql(u8, std.mem.trim(u8, values[0], " \t\r\n"), "*");
}

fn parseHeartbeatStateSummary(allocator: std.mem.Allocator, content: []const u8) HeartbeatStateSummary {
    if (jsonBoolField(content, "enabled")) |enabled| {
        return .{ .enabled = enabled };
    }

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return .{};

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};

    if (parsed.value.object.get("heartbeat")) |heartbeat| {
        if (heartbeat == .object) {
            if (heartbeat.object.get("enabled")) |enabled| {
                if (enabled == .bool) return .{ .enabled = enabled.bool };
            }
        }
    }

    return .{};
}

fn canonicalHeartbeatEnabledJson(allocator: std.mem.Allocator, enabled: bool) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"enabled\":{s}}}", .{
        if (enabled) "true" else "false",
    });
}

fn writeUserConfigJson(
    state: *GatewayState,
    user_ctx: *const UserContext,
    scoped_user_id: []const u8,
    content: []const u8,
) !void {
    if (state.zaki_state) |mgr| {
        const user_id = try parseNumericUserId(scoped_user_id);
        try mgr.putConfigJson(user_id, content);
        writeFile(user_ctx.config_path, content) catch |err| {
            log.warn("tenant settings mirror write failed path={s}: {}", .{ user_ctx.config_path, err });
        };
        return;
    }
    try writeFile(user_ctx.config_path, content);
}

fn writeHeartbeatEnabledForUser(
    allocator: std.mem.Allocator,
    state: *GatewayState,
    user_ctx: *const UserContext,
    scoped_user_id: []const u8,
    enabled: bool,
) ![]u8 {
    const canonical_body = try canonicalHeartbeatEnabledJson(allocator, enabled);
    errdefer allocator.free(canonical_body);

    if (state.zaki_state) |mgr| {
        const user_id = try parseNumericUserId(scoped_user_id);
        try mgr.putHeartbeatJson(user_id, canonical_body);
    } else {
        try writeFile(user_ctx.heartbeat_path, canonical_body);
    }

    return canonical_body;
}

fn telegramWebhookMatchesUser(webhook_url: []const u8, user_id: []const u8) bool {
    if (std.mem.indexOf(u8, webhook_url, "/webhook/telegram") == null) return false;
    const parsed_user_id = parseQueryParam(webhook_url, "user_id") orelse return false;
    return std.mem.eql(u8, parsed_user_id, user_id);
}

fn readTelegramBotTokenPresence(
    allocator: std.mem.Allocator,
    state_mgr_opt: ?*zaki_state_mod.Manager,
    numeric_user_id_opt: ?i64,
    secrets_dir_opt: ?[]const u8,
) bool {
    if (state_mgr_opt) |mgr| {
        if (numeric_user_id_opt) |numeric_user_id| {
            const secret_opt = mgr.getSecret(allocator, numeric_user_id, "telegram_bot_token") catch null;
            if (secret_opt) |secret_value| {
                defer allocator.free(secret_value);
                return normalizeTelegramBotToken(secret_value).len > 0;
            }
        }
    }
    if (secrets_dir_opt) |secrets_dir| {
        const secret_path = resolveSecretPath(allocator, secrets_dir, "telegram_bot_token") catch return false;
        defer allocator.free(secret_path);
        const secret_value = readTrimmedSecretFile(allocator, secret_path) catch return false;
        defer if (secret_value.len > 0) allocator.free(secret_value);
        return normalizeTelegramBotToken(secret_value).len > 0;
    }
    return false;
}

fn loadNormalizedTelegramReadiness(
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    user_id_raw: []const u8,
    user_ctx: *const UserContext,
) !NormalizedTelegramReadiness {
    const numeric_user_id = parseNumericUserId(user_id_raw) catch null;
    var telegram_state = TelegramUserState{};
    errdefer telegram_state.deinit(allocator);
    var data_source: []const u8 = "file_fallback";

    if (state.zaki_state) |mgr| {
        if (numeric_user_id) |user_id| {
            const raw_state = mgr.getTelegramStateJson(allocator, user_id) catch null;
            if (raw_state) |content| {
                defer allocator.free(content);
                telegram_state = parseTelegramUserState(allocator, content) catch .{};
            }
            data_source = "postgres";
        }
    } else {
        telegram_state = loadTelegramUserState(allocator, user_ctx.telegram_path) catch .{};
    }

    const bot_token_present = readTelegramBotTokenPresence(
        allocator,
        state.zaki_state,
        numeric_user_id,
        user_ctx.secrets_dir,
    );

    var normalized = NormalizedTelegramReadiness{
        .configured = bot_token_present or telegram_state.connected or telegram_state.account_id != null or telegram_state.webhook_url != null or telegram_state.chat_id != null,
        .connected_stored = telegram_state.connected,
        .connected_normalized = false,
        .state_valid = true,
        .bot_token_present = bot_token_present,
        .account_id = if (telegram_state.account_id) |value| try allocator.dupe(u8, value) else null,
        .chat_id = telegram_state.chat_id,
        .allow_from_count = telegram_state.allow_from.len,
        .data_source = data_source,
    };
    errdefer normalized.deinit(allocator);

    if (telegram_state.connected) {
        if (!bot_token_present) normalized.state_valid = false;
        if (telegram_state.webhook_url) |webhook_url| {
            if (!telegramWebhookMatchesUser(webhook_url, user_id_raw)) normalized.state_valid = false;
        } else {
            normalized.state_valid = false;
        }
    }
    normalized.connected_normalized = telegram_state.connected and normalized.state_valid;

    telegram_state.deinit(allocator);
    return normalized;
}

fn loadNormalizedHeartbeatEnabled(
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    user_id_raw: []const u8,
    heartbeat_path: []const u8,
) bool {
    if (state.zaki_state) |mgr| {
        const user_id = parseNumericUserId(user_id_raw) catch return false;
        const content = mgr.getHeartbeatJson(allocator, user_id) catch return false;
        defer allocator.free(content);
        return parseHeartbeatStateSummary(allocator, content).enabled;
    }
    const content = readFileOrDefault(allocator, heartbeat_path, "{}\n") catch return false;
    defer allocator.free(content);
    return parseHeartbeatStateSummary(allocator, content).enabled;
}

fn loadHeartbeatRuntimeSummary(
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    user_id_opt: ?[]const u8,
) HeartbeatRuntimeSummary {
    if (user_id_opt == null) return .{};

    const user_id = user_id_opt.?;
    const path = if (state.role == .user_cell)
        userCellHeartbeatRuntimePath(allocator, state.workspace_dir) catch return .{}
    else
        std.fmt.allocPrint(allocator, "{s}/{s}/heartbeat_runtime.json", .{ state.tenant_data_root, user_id }) catch return .{};
    defer allocator.free(path);

    const raw = readFileOrDefault(allocator, path, "") catch return .{};
    defer allocator.free(raw);
    if (raw.len == 0) return .{};

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};

    const obj = parsed.value.object;
    return .{
        .available = true,
        .last_run_s = if (obj.get("last_run_s")) |v| if (v == .integer) @as(?i64, v.integer) else null else null,
        .last_status = if (obj.get("last_status")) |v| if (v == .string) allocator.dupe(u8, v.string) catch null else null else null,
        .last_reason = if (obj.get("last_reason")) |v| if (v == .string) allocator.dupe(u8, v.string) catch null else null else null,
    };
}

fn proactiveStatusLabel(heartbeat_enabled: bool, runtime_summary: HeartbeatRuntimeSummary) []const u8 {
    if (!heartbeat_enabled) return "disabled_cleanly";
    if (runtime_summary.last_status) |status| {
        if (std.mem.eql(u8, status, "sent")) return "enabled_and_successfully_sent_recently";
        if (std.mem.eql(u8, status, "idle")) return "enabled_and_idle";
        if (std.mem.eql(u8, status, "send_failed")) {
            if (runtime_summary.last_reason) |reason| {
                if (std.mem.eql(u8, reason, "no_target")) return "enabled_but_no_target";
            }
        }
    }
    return "enabled_unproven";
}

fn clientReadyStatus(operator_chat_ready: bool, telegram_readiness: NormalizedTelegramReadiness) []const u8 {
    if (telegram_readiness.requiresReconnect()) return "needs_reconnect";
    if (!operator_chat_ready) return "operator_action_required";
    if (telegram_readiness.connected_normalized) return "ready";
    return "ready_in_app";
}

fn loadTelegramUserState(allocator: std.mem.Allocator, path: []const u8) !TelegramUserState {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, MAX_BODY_SIZE);
    defer allocator.free(content);
    return parseTelegramUserState(allocator, content);
}

const OnboardingStateSummary = struct {
    completed: bool = false,
    completed_at_s: ?i64 = null,
};

const OnboardingReadiness = struct {
    can_start_chat_now: bool,
    minimum_required: []const []const u8,
    onboarding_ready_normalized: bool,
    client_ready_status: []const u8,
    telegram_connected_normalized: bool,
    telegram_state_valid: bool,
    heartbeat_enabled_normalized: bool,

    fn deinit(self: *OnboardingReadiness, allocator: std.mem.Allocator) void {
        allocator.free(self.minimum_required);
    }
};

fn parseOnboardingStateSummary(content: []const u8) OnboardingStateSummary {
    return .{
        .completed = jsonBoolField(content, "completed") orelse false,
        .completed_at_s = jsonIntField(content, "completed_at_s"),
    };
}

fn manualConnectStatus(available: bool, configured_by_operator: bool) []const u8 {
    if (!available) return "disabled_in_build";
    if (!configured_by_operator) return "not_configured_by_operator";
    return "ready_for_user_binding";
}

fn computeOnboardingReadiness(
    allocator: std.mem.Allocator,
    config_opt: ?*const Config,
    summary: OnboardingStateSummary,
    telegram_readiness: NormalizedTelegramReadiness,
    heartbeat_enabled_normalized: bool,
) !OnboardingReadiness {
    var minimum_required: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer minimum_required.deinit(allocator);

    var operator_chat_ready = true;
    if (config_opt) |cfg| {
        const default_model = cfg.default_model orelse "";
        if (cfg.default_provider.len == 0 or default_model.len == 0) {
            operator_chat_ready = false;
            try minimum_required.append(allocator, "operator_configure_model_provider");
        }
    }

    const required_slice = try minimum_required.toOwnedSlice(allocator);
    return .{
        .can_start_chat_now = required_slice.len == 0,
        .minimum_required = required_slice,
        .onboarding_ready_normalized = summary.completed or operator_chat_ready or telegram_readiness.connected_normalized,
        .client_ready_status = clientReadyStatus(operator_chat_ready, telegram_readiness),
        .telegram_connected_normalized = telegram_readiness.connected_normalized,
        .telegram_state_valid = telegram_readiness.state_valid,
        .heartbeat_enabled_normalized = heartbeat_enabled_normalized,
    };
}

fn buildUserRoutePath(
    allocator: std.mem.Allocator,
    user_id: []const u8,
    suffix: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "/api/v1/users/{s}/{s}", .{ user_id, suffix });
}

fn writeOnboardingChannelGuide(
    writer: anytype,
    channel_name: []const u8,
    available: bool,
    connect_supported: bool,
    status: []const u8,
    connected: ?bool,
    required_inputs: []const []const u8,
    instructions: []const []const u8,
    connect_endpoint: ?[]const u8,
    disconnect_endpoint: ?[]const u8,
) !void {
    try writer.writeByte('"');
    try jsonEscapeInto(writer, channel_name);
    try writer.writeAll("\":{");
    try writer.print("\"available\":{s}", .{if (available) "true" else "false"});
    try writer.print(",\"connect_supported\":{s}", .{if (connect_supported) "true" else "false"});
    try writer.writeAll(",\"status\":\"");
    try jsonEscapeInto(writer, status);
    try writer.writeByte('"');
    try writer.writeAll(",\"connected\":");
    if (connected) |value| {
        try writer.writeAll(if (value) "true" else "false");
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"required_inputs\":");
    try jsonWriteStringArray(writer, required_inputs);
    try writer.writeAll(",\"instructions\":");
    try jsonWriteStringArray(writer, instructions);
    try writer.writeAll(",\"connect_endpoint\":");
    if (connect_endpoint) |endpoint| {
        try writer.writeByte('"');
        try jsonEscapeInto(writer, endpoint);
        try writer.writeByte('"');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"disconnect_endpoint\":");
    if (disconnect_endpoint) |endpoint| {
        try writer.writeByte('"');
        try jsonEscapeInto(writer, endpoint);
        try writer.writeByte('"');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn buildOnboardingSetupResponse(
    allocator: std.mem.Allocator,
    user_id: []const u8,
    summary: OnboardingStateSummary,
    telegram_readiness: NormalizedTelegramReadiness,
    heartbeat_enabled_normalized: bool,
    config_opt: ?*const Config,
) ![]u8 {
    var readiness = try computeOnboardingReadiness(allocator, config_opt, summary, telegram_readiness, heartbeat_enabled_normalized);
    defer readiness.deinit(allocator);

    const settings_defaults = user_settings.defaults();
    const settings_defaults_json = try user_settings.renderSettingsJson(allocator, settings_defaults);
    defer allocator.free(settings_defaults_json);

    const settings_endpoint = try buildUserRoutePath(allocator, user_id, "settings");
    defer allocator.free(settings_endpoint);
    const telegram_connect_endpoint = try buildUserRoutePath(allocator, user_id, "channels/telegram/connect");
    defer allocator.free(telegram_connect_endpoint);
    const telegram_disconnect_endpoint = try buildUserRoutePath(allocator, user_id, "channels/telegram/disconnect");
    defer allocator.free(telegram_disconnect_endpoint);
    const slack_bindings_endpoint = try buildUserRoutePath(allocator, user_id, "channels/slack/bindings");
    defer allocator.free(slack_bindings_endpoint);
    const discord_bindings_endpoint = try buildUserRoutePath(allocator, user_id, "channels/discord/bindings");
    defer allocator.free(discord_bindings_endpoint);

    const slack_configured_by_operator = if (config_opt) |cfg| cfg.channels.slack.len > 0 else false;
    const discord_configured_by_operator = if (config_opt) |cfg| cfg.channels.discord.len > 0 else false;
    const telegram_status: []const u8 = if (!build_options.enable_channel_telegram)
        "disabled_in_build"
    else
        telegram_readiness.statusLabel();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.writeAll("{\"completed\":");
    try w.writeAll(if (summary.completed) "true" else "false");
    try w.writeAll(",\"completed_at_s\":");
    if (summary.completed_at_s) |value| {
        try w.print("{d}", .{value});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"setup\":{");
    try w.writeAll("\"can_start_chat_now\":");
    try w.writeAll(if (readiness.can_start_chat_now) "true" else "false");
    try w.writeAll(",\"minimum_required\":");
    try jsonWriteStringArray(w, readiness.minimum_required);
    try w.writeAll(",\"onboarding_ready_normalized\":");
    try w.writeAll(if (readiness.onboarding_ready_normalized) "true" else "false");
    try w.writeAll(",\"client_ready_status\":\"");
    try jsonEscapeInto(w, readiness.client_ready_status);
    try w.writeAll("\",\"telegram_connected_normalized\":");
    try w.writeAll(if (readiness.telegram_connected_normalized) "true" else "false");
    try w.writeAll(",\"telegram_state_valid\":");
    try w.writeAll(if (readiness.telegram_state_valid) "true" else "false");
    try w.writeAll(",\"heartbeat_enabled_normalized\":");
    try w.writeAll(if (readiness.heartbeat_enabled_normalized) "true" else "false");
    try w.writeAll(",\"settings\":{");
    try w.writeAll("\"endpoint\":\"");
    try jsonEscapeInto(w, settings_endpoint);
    try w.writeAll("\",\"required_to_start\":false");
    try w.writeAll(",\"defaults\":");
    try w.writeAll(settings_defaults_json);
    try w.writeAll(",\"fields\":[");
    try w.writeAll("{\"key\":\"assistant_mode\",\"type\":\"enum\",\"required\":false,\"description\":\"Controls speed vs depth preset\",\"options\":[\"fast\",\"balanced\",\"deep\"]}");
    try w.writeAll(",{\"key\":\"group_activation\",\"type\":\"enum\",\"required\":false,\"description\":\"When to respond in group chats\",\"options\":[\"mention\",\"always\"]}");
    try w.writeAll(",{\"key\":\"proactive_updates\",\"type\":\"boolean\",\"required\":false,\"description\":\"Allow proactive updates outside direct prompts\"}");
    try w.writeAll(",{\"key\":\"voice_replies\",\"type\":\"boolean\",\"required\":false,\"description\":\"Enable voice output responses\"}");
    try w.writeAll(",{\"key\":\"session_timeout_minutes\",\"type\":\"integer\",\"required\":false,\"description\":\"Session TTL in minutes (5-180)\",\"minimum\":5,\"maximum\":180}");
    try w.writeAll("]}");
    try w.writeAll(",\"channel_guides\":{");
    try writeOnboardingChannelGuide(
        w,
        "telegram",
        build_options.enable_channel_telegram,
        true,
        telegram_status,
        telegram_readiness.connected_normalized,
        &TELEGRAM_REQUIRED_INPUTS,
        &TELEGRAM_CONNECT_INSTRUCTIONS,
        telegram_connect_endpoint,
        telegram_disconnect_endpoint,
    );
    try w.writeByte(',');
    try writeOnboardingChannelGuide(
        w,
        "slack",
        build_options.enable_channel_slack,
        false,
        manualConnectStatus(build_options.enable_channel_slack, slack_configured_by_operator),
        null,
        &SLACK_REQUIRED_INPUTS,
        &SLACK_CONNECT_INSTRUCTIONS,
        slack_bindings_endpoint,
        null,
    );
    try w.writeByte(',');
    try writeOnboardingChannelGuide(
        w,
        "discord",
        build_options.enable_channel_discord,
        false,
        manualConnectStatus(build_options.enable_channel_discord, discord_configured_by_operator),
        null,
        &DISCORD_REQUIRED_INPUTS,
        &DISCORD_CONNECT_INSTRUCTIONS,
        discord_bindings_endpoint,
        null,
    );
    try w.writeAll("}}}");
    return out.toOwnedSlice(allocator);
}

fn readTrimmedSecretFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const raw = try readFileOrDefault(allocator, path, "");
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return &.{};
    }
    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return out;
}

fn resolveTenantTelegramBotTokenForSend(
    allocator: std.mem.Allocator,
    user_ctx: *const UserContext,
    state_mgr_opt: ?*zaki_state_mod.Manager,
    numeric_user_id_opt: ?i64,
) ![]const u8 {
    if (state_mgr_opt) |state_mgr| {
        if (numeric_user_id_opt) |numeric_user_id| {
            const secret_opt = state_mgr.getSecret(allocator, numeric_user_id, "telegram_bot_token") catch null;
            if (secret_opt) |token_owned| {
                errdefer allocator.free(token_owned);
                const normalized_secret = normalizeTelegramBotToken(token_owned);
                if (!isLikelyTelegramBotToken(normalized_secret)) {
                    allocator.free(token_owned);
                    return error.CurlFailed;
                }
                if (normalized_secret.ptr == token_owned.ptr and normalized_secret.len == token_owned.len) {
                    return token_owned;
                }
                const out = try allocator.dupe(u8, normalized_secret);
                allocator.free(token_owned);
                return out;
            }
        }
    }

    const secret_path = try resolveSecretPath(allocator, user_ctx.secrets_dir, "telegram_bot_token");
    defer allocator.free(secret_path);

    const raw = try readTrimmedSecretFile(allocator, secret_path);
    const normalized = normalizeTelegramBotToken(raw);
    if (!isLikelyTelegramBotToken(normalized)) {
        if (raw.len > 0) allocator.free(raw);
        return error.CurlFailed;
    }
    if (normalized.ptr == raw.ptr and normalized.len == raw.len) return raw;

    const out = try allocator.dupe(u8, normalized);
    if (raw.len > 0) allocator.free(raw);
    return out;
}

fn maybeAcquireTenantOwnershipLock(
    allocator: std.mem.Allocator,
    state: *GatewayState,
    user_id: []const u8,
    user_root: []const u8,
) !OwnershipLockAcquireResult {
    if (!state.tenant_enabled) return .disabled;
    if (!state.ownership_lock_enabled) return .disabled;
    if (state.owner_instance_id.len == 0) return .disabled;

    const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(state.ownership_lock_wait_ms));
    var retries: u32 = 0;

    if (tenantOwnershipUsesPostgresLease(state)) {
        const mgr = state.zaki_state orelse return error.PostgresNotEnabled;
        const numeric_user_id = try parseNumericUserId(user_id);
        while (true) {
            const now_s = std.time.timestamp();
            const lease_token = mgr.acquireUserOwnershipLease(
                allocator,
                numeric_user_id,
                state.owner_instance_id,
                now_s,
                state.ownership_lock_lease_secs,
            ) catch |err| switch (err) {
                error.LockHeld => {
                    retries += 1;
                    const sleep_ms = nextOwnershipRetryDelayMs(state, deadline_ms);
                    if (sleep_ms == 0) {
                        recordTenantLockConflictRetries(state, retries);
                        return .{ .conflict = try buildOwnershipLockConflictInfo(allocator, state, user_id, retries) };
                    }
                    std.Thread.sleep(@as(u64, sleep_ms) * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            recordTenantLockConflictRetries(state, retries);
            return .{ .acquired = .{
                .postgres = .{
                    .allocator = allocator,
                    .state_mgr = mgr,
                    .user_id = numeric_user_id,
                    .owner_id = state.owner_instance_id,
                    .lease_token = lease_token,
                },
            } };
        }
    }

    while (true) {
        const file_lock = tenant_lock.acquireUserOwnershipLock(
            allocator,
            user_root,
            state.owner_instance_id,
            state.ownership_lock_lease_secs,
        ) catch |err| switch (err) {
            error.LockHeld => {
                retries += 1;
                const sleep_ms = nextOwnershipRetryDelayMs(state, deadline_ms);
                if (sleep_ms == 0) {
                    recordTenantLockConflictRetries(state, retries);
                    return .{ .conflict = try buildOwnershipLockConflictInfo(allocator, state, user_id, retries) };
                }
                std.Thread.sleep(@as(u64, sleep_ms) * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        recordTenantLockConflictRetries(state, retries);
        return .{ .acquired = .{ .file = file_lock } };
    }
}

fn tenantOwnershipUsesPostgresLease(state: *const GatewayState) bool {
    return state.zaki_state != null and std.mem.eql(u8, state.state_backend_effective, "postgres");
}

const OwnershipLockConflictInfo = struct {
    allocator: std.mem.Allocator,
    retry_after_ms: u32,
    owner_instance_id: ?[]u8 = null,
    lease_until_s: ?i64 = null,
    retries: u32 = 0,

    fn retryAfterSecs(self: *const OwnershipLockConflictInfo) u16 {
        const ms: u64 = self.retry_after_ms;
        const secs: u64 = (ms + 999) / 1000;
        return @intCast(@max(@as(u64, 1), @min(secs, std.math.maxInt(u16))));
    }

    fn deinit(self: *OwnershipLockConflictInfo) void {
        if (self.owner_instance_id) |value| self.allocator.free(value);
        self.owner_instance_id = null;
    }
};

const OwnershipLockAcquireResult = union(enum) {
    disabled,
    acquired: TenantOwnershipLock,
    conflict: OwnershipLockConflictInfo,

    fn deinit(self: *OwnershipLockAcquireResult) void {
        switch (self.*) {
            .disabled => {},
            .acquired => |*lock| lock.deinit(),
            .conflict => |*conflict| conflict.deinit(),
        }
    }
};

fn ownershipLockRetryAfterMs(state: *const GatewayState, lease_until_s: ?i64) u32 {
    var retry_ms: u32 = state.ownership_lock_retry_max_ms * 3 + 10;
    retry_ms = std.math.clamp(retry_ms, @as(u32, 100), @as(u32, 1500));
    if (lease_until_s) |lease_until| {
        const now_s = std.time.timestamp();
        if (lease_until > now_s) {
            const remaining_s: i64 = lease_until - now_s;
            const bounded_s: i64 = @min(remaining_s, @as(i64, 2));
            if (bounded_s > 0) {
                const lease_ms: u32 = @intCast(bounded_s * 1000);
                if (lease_ms > retry_ms) retry_ms = lease_ms;
            }
        }
    }
    return retry_ms;
}

fn nextOwnershipRetryDelayMs(state: *const GatewayState, deadline_ms: i64) u32 {
    const now_ms = std.time.milliTimestamp();
    if (now_ms >= deadline_ms) return 0;

    const remaining_i64 = deadline_ms - now_ms;
    const remaining_ms: u32 = @intCast(@min(remaining_i64, @as(i64, std.math.maxInt(u32))));

    var min_ms = state.ownership_lock_retry_min_ms;
    var max_ms = state.ownership_lock_retry_max_ms;
    if (min_ms > max_ms) std.mem.swap(u32, &min_ms, &max_ms);
    min_ms = @min(min_ms, remaining_ms);
    max_ms = @min(max_ms, remaining_ms);
    if (max_ms < min_ms) max_ms = min_ms;
    if (max_ms == 0) return 0;
    if (max_ms == min_ms) return min_ms;

    const span: u32 = (max_ms - min_ms) + 1;
    const mod_i64: i64 = @mod(now_ms, @as(i64, span));
    const jitter: u32 = @intCast(mod_i64);
    return min_ms + jitter;
}

fn buildOwnershipLockConflictInfo(
    allocator: std.mem.Allocator,
    state: *GatewayState,
    user_id: []const u8,
    retries: u32,
) !OwnershipLockConflictInfo {
    var info = OwnershipLockConflictInfo{
        .allocator = allocator,
        .retry_after_ms = ownershipLockRetryAfterMs(state, null),
        .retries = retries,
    };
    if (!tenantOwnershipUsesPostgresLease(state)) return info;
    const mgr = state.zaki_state orelse return info;
    const numeric_user_id = parseNumericUserId(user_id) catch return info;
    if (try mgr.getUserOwnershipLeaseSnapshot(allocator, numeric_user_id)) |snapshot| {
        info.owner_instance_id = snapshot.owner_id;
        info.lease_until_s = snapshot.lease_until_s;
        info.retry_after_ms = ownershipLockRetryAfterMs(state, snapshot.lease_until_s);
    }
    return info;
}

const PostgresUserOwnershipLease = struct {
    allocator: std.mem.Allocator,
    state_mgr: *zaki_state_mod.Manager,
    user_id: i64,
    owner_id: []const u8,
    lease_token: []u8,
    released: bool = false,

    fn release(self: *PostgresUserOwnershipLease) void {
        if (self.released) return;
        self.state_mgr.releaseUserOwnershipLease(self.user_id, self.owner_id, self.lease_token) catch |err| {
            log.warn("failed to release postgres ownership lease for user={d}: {}", .{ self.user_id, err });
        };
        self.allocator.free(self.lease_token);
        self.released = true;
    }

    fn deinit(self: *PostgresUserOwnershipLease) void {
        self.release();
    }
};

const TenantOwnershipLock = union(enum) {
    file: tenant_lock.UserOwnershipLock,
    postgres: PostgresUserOwnershipLease,

    fn deinit(self: *TenantOwnershipLock) void {
        switch (self.*) {
            .file => |*lock| lock.deinit(),
            .postgres => |*lease| lease.deinit(),
        }
    }
};

const TenantTelegramAsyncJob = struct {
    allocator: std.mem.Allocator,
    state: *GatewayState,
    config: *const Config,
    user_id: []u8,
    account_id: []u8,
    bot_token: []u8,
    message: []u8,
    chat_id: i64,

    fn deinit(self: *TenantTelegramAsyncJob) void {
        self.allocator.free(self.user_id);
        self.allocator.free(self.account_id);
        self.allocator.free(self.bot_token);
        self.allocator.free(self.message);
        self.allocator.destroy(self);
    }
};

fn tenantTelegramAsyncWorker(job: *TenantTelegramAsyncJob) void {
    defer job.deinit();

    var user_ctx = resolveUserContext(job.allocator, job.state, job.user_id) catch |err| {
        log.warn("tenant telegram async resolveUserContext failed: {}", .{err});
        return;
    };
    defer user_ctx.deinit(job.allocator);

    var user_lock = maybeAcquireTenantOwnershipLock(
        job.allocator,
        job.state,
        user_ctx.user_id,
        user_ctx.user_root,
    ) catch |err| {
        log.warn("tenant telegram async ownership lock failed: {}", .{err});
        return;
    };
    defer user_lock.deinit();
    switch (user_lock) {
        .disabled => {},
        .acquired => {},
        .conflict => |conflict| {
            log.warn("tenant telegram async ownership lock conflict retry_after_ms={d}", .{conflict.retry_after_ms});
            return;
        },
    }

    const tenant_runtime = getTenantRuntime(job.state, job.config, &user_ctx) catch |err| {
        if (err == error.ExecutionDelegated) {
            log.info("tenant telegram async skipped: gateway role delegates execution", .{});
            return;
        }
        log.warn("tenant telegram async runtime init failed: {}", .{err});
        return;
    };

    var session_key_buf: [256]u8 = undefined;
    var topic_buf: [32]u8 = undefined;
    var lane_buf: [64]u8 = undefined;
    const lane_resolution = resolveTenantTelegramLane(
        job.allocator,
        job.config,
        tenantTelegramUsesSharedMain(job.config),
        job.user_id,
        job.account_id,
        job.chat_id,
        null,
        &session_key_buf,
        &topic_buf,
        &lane_buf,
    );
    const session_key = lane_resolution.fallback_session_key;

    var chat_id_buf: [32]u8 = undefined;
    const chat_id_str = std.fmt.bufPrint(&chat_id_buf, "{d}", .{job.chat_id}) catch "0";

    const reply = tenant_runtime.processMessage(
        session_key,
        job.message,
        .{
            .channel = "telegram",
            .is_group = job.chat_id < 0,
        },
        .{
            .channel = "telegram",
            .account_id = job.account_id,
            .chat_id = chat_id_str,
        },
        null,
    ) catch |err| {
        if (job.bot_token.len > 0) {
            sendTelegramReply(job.allocator, job.bot_token, job.chat_id, userFacingAgentError(err)) catch |send_err| {
                log.warn("tenant telegram async error-reply send failed: {}", .{send_err});
            };
        }
        return;
    };
    defer job.allocator.free(reply);

    if (job.bot_token.len == 0) return;
    sendTelegramReply(job.allocator, job.bot_token, job.chat_id, reply) catch |err| {
        log.warn("tenant telegram async send failed: {}", .{err});
    };
}

fn tenantTelegramAsyncWorkerMain(state: *GatewayState) void {
    while (state.tenant_telegram_queue.pop()) |opaque_job| {
        const job: *TenantTelegramAsyncJob = @ptrCast(@alignCast(opaque_job));
        tenantTelegramAsyncWorker(job);
    }
}

fn ensureTenantTelegramWorker(state: *GatewayState) bool {
    state.tenant_telegram_worker_mutex.lock();
    defer state.tenant_telegram_worker_mutex.unlock();
    if (state.tenant_telegram_worker != null) return true;

    const worker = std.Thread.spawn(
        .{ .stack_size = 512 * 1024 },
        tenantTelegramAsyncWorkerMain,
        .{state},
    ) catch return false;
    state.tenant_telegram_worker = worker;
    return true;
}

fn enqueueTenantTelegramAsync(
    state: *GatewayState,
    config: *const Config,
    user_id: []const u8,
    account_id: []const u8,
    bot_token: []const u8,
    chat_id: i64,
    message: []const u8,
) bool {
    const allocator = state.allocator;
    const job = allocator.create(TenantTelegramAsyncJob) catch return false;
    errdefer allocator.destroy(job);

    const user_id_dup = allocator.dupe(u8, user_id) catch return false;
    errdefer allocator.free(user_id_dup);
    const account_id_dup = allocator.dupe(u8, account_id) catch return false;
    errdefer allocator.free(account_id_dup);
    const bot_token_dup = allocator.dupe(u8, bot_token) catch return false;
    errdefer allocator.free(bot_token_dup);
    const message_dup = allocator.dupe(u8, message) catch return false;
    errdefer allocator.free(message_dup);

    job.* = .{
        .allocator = allocator,
        .state = state,
        .config = config,
        .user_id = user_id_dup,
        .account_id = account_id_dup,
        .bot_token = bot_token_dup,
        .message = message_dup,
        .chat_id = chat_id,
    };

    if (!ensureTenantTelegramWorker(state)) {
        job.deinit();
        return false;
    }

    if (!state.tenant_telegram_queue.push(@ptrCast(job))) {
        job.deinit();
        return false;
    }
    return true;
}

/// Returns true when a webhook request should be accepted for the current
/// pairing state and bearer token. Missing pairing state fails closed.
pub fn isWebhookAuthorized(pairing_guard: ?*const PairingGuard, bearer_token: ?[]const u8) bool {
    const guard = pairing_guard orelse return false;
    if (!guard.requirePairing()) return true;
    const token = bearer_token orelse return false;
    return guard.isAuthenticated(token);
}

/// Format the /pair success payload. Returns null when buffer is too small.
pub fn formatPairSuccessResponse(buf: []u8, token: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{{\"status\":\"paired\",\"token\":\"{s}\"}}", .{token}) catch null;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

fn normalizeTelegramSecretToken(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n\"");
}

fn normalizeTelegramBotToken(value: []const u8) []const u8 {
    return telegram_token.normalize_bot_token(value);
}

fn copyIntoBuf(buf: []u8, value: []const u8) usize {
    const n = @min(buf.len, value.len);
    if (n > 0) @memcpy(buf[0..n], value[0..n]);
    if (n < buf.len) @memset(buf[n..], 0);
    return n;
}

fn parsePostgresHostPort(connection_string: []const u8) struct { host: []const u8, port: u16 } {
    const scheme_split = std.mem.indexOf(u8, connection_string, "://") orelse return .{ .host = "", .port = 0 };
    var tail = connection_string[scheme_split + 3 ..];
    if (std.mem.indexOfScalar(u8, tail, '@')) |at_idx| {
        tail = tail[at_idx + 1 ..];
    }

    if (tail.len == 0) return .{ .host = "", .port = 0 };
    if (tail[0] == '[') {
        const close_idx = std.mem.indexOfScalar(u8, tail, ']') orelse return .{ .host = "", .port = 0 };
        const host = tail[1..close_idx];
        var port: u16 = 5432;
        if (close_idx + 1 < tail.len and tail[close_idx + 1] == ':') {
            const after = tail[close_idx + 2 ..];
            const end = std.mem.indexOfAny(u8, after, "/?") orelse after.len;
            port = std.fmt.parseInt(u16, after[0..end], 10) catch 5432;
        }
        return .{ .host = host, .port = port };
    }

    const host_end = std.mem.indexOfAny(u8, tail, ":/?") orelse tail.len;
    const host = tail[0..host_end];
    var port: u16 = 5432;
    if (host_end < tail.len and tail[host_end] == ':') {
        const after = tail[host_end + 1 ..];
        const end = std.mem.indexOfAny(u8, after, "/?") orelse after.len;
        port = std.fmt.parseInt(u16, after[0..end], 10) catch 5432;
    }
    return .{ .host = host, .port = port };
}

fn detectWebhookMode(cfg: *const Config) []const u8 {
    var enabled_count: u8 = 0;
    var only: []const u8 = "none";

    if (cfg.channels.telegram.len > 0) {
        enabled_count += 1;
        only = "telegram";
    }
    if (cfg.channels.whatsapp.len > 0) {
        enabled_count += 1;
        only = "whatsapp";
    }
    if (cfg.channels.line.len > 0) {
        enabled_count += 1;
        only = "line";
    }
    if (cfg.channels.lark.len > 0) {
        enabled_count += 1;
        only = "lark";
    }
    if (enabled_count == 0) return "none";
    if (enabled_count == 1) return only;
    return "multi";
}

fn normalizeProviderAlias(provider_name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, provider_name, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "together-ai")) return "together";
    if (std.mem.eql(u8, trimmed, "google-gemini")) return "gemini";
    return trimmed;
}

fn buildFallbackChainIntoBuf(buf: []u8, fallback_providers: []const []const u8) usize {
    if (fallback_providers.len == 0) return copyIntoBuf(buf, "none");
    var used: usize = 0;
    var wrote_any = false;
    for (fallback_providers) |provider_name| {
        const normalized = normalizeProviderAlias(provider_name);
        if (normalized.len == 0) continue;
        if (wrote_any) {
            if (used >= buf.len) break;
            buf[used] = ',';
            used += 1;
        }
        const copy_len = @min(normalized.len, buf.len - used);
        if (copy_len == 0) break;
        @memcpy(buf[used .. used + copy_len], normalized[0..copy_len]);
        used += copy_len;
        wrote_any = true;
        if (copy_len < normalized.len) break;
    }
    if (!wrote_any) return copyIntoBuf(buf, "none");
    if (used < buf.len) @memset(buf[used..], 0);
    return used;
}

fn applyStartupSelfCheck(state: *GatewayState, cfg: *const Config, postgres_init_error: ?anyerror) void {
    state.state_backend_configured = cfg.state.backend;
    state.state_backend_effective = if (state.zaki_state != null) "postgres" else "file";
    state.scheduler_backend = if (state.zaki_state != null and cfg.tenant.enabled) "postgres" else "file";
    state.webhook_mode = detectWebhookMode(cfg);
    state.heartbeat_enabled = cfg.heartbeat.enabled;
    state.heartbeat_interval_minutes = cfg.heartbeat.interval_minutes;
    state.tenant_enabled_configured = cfg.tenant.enabled;
    state.chat_provider_effective = normalizeProviderAlias(cfg.default_provider);
    state.embedding_provider_effective = normalizeProviderAlias(cfg.memory.search.provider);
    state.provider_data_source = "config";
    state.chat_fallback_chain_len = buildFallbackChainIntoBuf(&state.chat_fallback_chain_buf, cfg.reliability.fallback_providers);
    state.config_path_len = copyIntoBuf(&state.config_path_buf, cfg.config_path);
    state.postgres_host_len = 0;
    state.postgres_port = 0;
    state.postgres_schema_len = copyIntoBuf(&state.postgres_schema_buf, cfg.state.postgres.schema);
    if (std.mem.eql(u8, cfg.state.backend, "postgres")) {
        const parsed = parsePostgresHostPort(cfg.state.postgres.connection_string);
        state.postgres_host_len = copyIntoBuf(&state.postgres_host_buf, parsed.host);
        state.postgres_port = parsed.port;
    }

    state.state_degraded = std.mem.eql(u8, cfg.state.backend, "postgres") and state.zaki_state == null;
    if (state.state_degraded) {
        const reason = if (postgres_init_error) |err| @errorName(err) else "postgres_init_failed";
        state.state_degraded_reason_len = copyIntoBuf(&state.state_degraded_reason_buf, reason);
    } else {
        state.state_degraded_reason_len = 0;
    }

    const dispatch_mode = tool_dispatcher.parseMode(cfg.agent.tool_dispatcher);
    if (!dispatch_mode.supported) {
        log.warn("deferred-explicit: agent.tool_dispatcher={s} is unsupported; falling back to auto", .{
            cfg.agent.tool_dispatcher,
        });
    }
    if (cfg.agent.parallel_tools and cfg.agent.parallel_tools_rollout_percent < 100) {
        log.info(
            "agent.parallel_tools canary active rollout_percent={d} dispatcher={s}",
            .{ cfg.agent.parallel_tools_rollout_percent, tool_dispatcher.effectiveMode(cfg.agent.parallel_tools, dispatch_mode.mode).toSlice() },
        );
    }
}

fn logStartupSelfCheck(state: *const GatewayState) void {
    log.info(
        "startup.self_check config_path={s} tenant_enabled={s} heartbeat_enabled={s} heartbeat_interval_minutes={d} state_configured={s} state_effective={s} degraded={s} pg_host={s} pg_port={d} pg_schema={s} scheduler_backend={s} webhook_mode={s} chat_provider={s} chat_fallbacks={s} embedding_provider={s} internal_auth_required={s} internal_token_configured={s} internal_token_policy_ok={s} internal_token_policy_reason={s}",
        .{
            state.configPath(),
            if (state.tenant_enabled_configured) "true" else "false",
            if (state.heartbeat_enabled) "true" else "false",
            state.heartbeat_interval_minutes,
            state.state_backend_configured,
            state.state_backend_effective,
            if (state.state_degraded) "true" else "false",
            state.postgresHost(),
            state.postgres_port,
            state.postgresSchema(),
            state.scheduler_backend,
            state.webhook_mode,
            state.chat_provider_effective,
            state.chatFallbackChain(),
            state.embedding_provider_effective,
            if (state.internal_auth_required) "true" else "false",
            if (state.internal_token_configured) "true" else "false",
            if (state.internal_token_policy_ok) "true" else "false",
            if (state.internal_token_policy_reason.len > 0) state.internal_token_policy_reason else "null",
        },
    );
    if (state.state_degraded) {
        log.warn(
            "gateway running in degraded state: configured backend={s}, effective backend={s}, reason={s}",
            .{ state.state_backend_configured, state.state_backend_effective, state.degradedReason() },
        );
    }
}

fn maybeLogDegradedStateWarning(state: *GatewayState) void {
    if (!state.state_degraded) return;
    const now = std.time.timestamp();
    const last = state.last_degraded_warn_s.load(.acquire);
    if (now - last < 300 and now >= last) return;
    state.last_degraded_warn_s.store(now, .release);
    log.warn(
        "gateway degraded state persists: configured backend={s}, effective backend={s}, reason={s}",
        .{ state.state_backend_configured, state.state_backend_effective, state.degradedReason() },
    );
}

// ── WhatsApp HMAC-SHA256 Signature Verification ─────────────────

/// Verify a WhatsApp webhook HMAC-SHA256 signature.
///
/// Meta sends `X-Hub-Signature-256: sha256=<hex-digest>` on every webhook POST.
/// This function computes HMAC-SHA256 over `body` using `app_secret` as the key,
/// then performs a constant-time comparison against the hex digest in the header.
///
/// Returns `true` if the signature is valid, `false` otherwise.
pub fn verifyWhatsappSignature(body: []const u8, signature_header: []const u8, app_secret: []const u8) bool {
    // Reject empty secrets — misconfiguration guard
    if (app_secret.len == 0) return false;

    // Header must start with "sha256="
    const prefix = "sha256=";
    if (!std.mem.startsWith(u8, signature_header, prefix)) return false;

    const provided_hex = signature_header[prefix.len..];

    // HMAC-SHA256 digest is 32 bytes = 64 hex chars
    if (provided_hex.len != 64) return false;

    // Decode the provided hex string into bytes
    const provided_bytes = hexDecode(provided_hex) orelse return false;

    // Compute expected HMAC-SHA256
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var expected: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected, body, app_secret);

    // Constant-time comparison — prevents timing side-channels
    return constantTimeEql(&expected, &provided_bytes);
}

/// Decode a 64-char lowercase hex string into 32 bytes.
/// Returns null if any character is not a valid hex digit.
fn hexDecode(hex: []const u8) ?[32]u8 {
    if (hex.len != 64) return null;
    var out: [32]u8 = undefined;
    for (0..32) |i| {
        const hi = hexVal(hex[i * 2]) orelse return null;
        const lo = hexVal(hex[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

/// Convert a single hex character to its 4-bit value.
fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Constant-time comparison of two 32-byte arrays.
/// Always examines all bytes regardless of where a mismatch occurs.
fn constantTimeEql(a: *const [32]u8, b: *const [32]u8) bool {
    var diff: u8 = 0;
    for (a, b) |ab, bb| {
        diff |= ab ^ bb;
    }
    return diff == 0;
}

// ── JSON Helpers ────────────────────────────────────────────────

/// Escape a string for safe embedding inside a JSON string value.
/// Handles: \ → \\, " → \", control chars (0x00-0x1F) → \uXXXX,
/// newlines → \n, tabs → \t, carriage returns → \r.
pub fn jsonEscapeInto(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

/// Wrap a value as a JSON string field: `"key":"escaped_value"`.
/// Returns an owned slice allocated with the provided allocator.
pub fn jsonWrapField(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":\"");
    try jsonEscapeInto(w, value);
    try w.writeByte('"');
    return buf.toOwnedSlice(allocator);
}

fn jsonWriteStringArray(writer: anytype, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try jsonEscapeInto(writer, value);
        try writer.writeByte('"');
    }
    try writer.writeByte(']');
}

/// Build a JSON response object: `{"status":"ok","response":"<escaped>"}`.
/// Returns an owned slice. Caller must free.
pub fn jsonWrapResponse(allocator: std.mem.Allocator, response: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"status\":\"ok\",\"response\":\"");
    try jsonEscapeInto(w, response);
    try w.writeAll("\"}");
    return buf.toOwnedSlice(allocator);
}

/// Build a JSON challenge response: `{"challenge":"<escaped>"}`.
/// Returns an owned slice. Caller must free.
fn jsonWrapChallenge(allocator: std.mem.Allocator, challenge: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"challenge\":\"");
    try jsonEscapeInto(w, challenge);
    try w.writeAll("\"}");
    return buf.toOwnedSlice(allocator);
}

/// Extract a string field from a JSON blob (minimal parser, no allocations).
pub fn jsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n' or after_key[i] == '\r')) : (i += 1)
    {}

    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    // Find closing quote (handle escaped quotes)
    const start = i;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 1;
            continue;
        }
        if (after_key[i] == '"') {
            return after_key[start..i];
        }
    }
    return null;
}

/// Extract an integer field from a JSON blob.
pub fn jsonIntField(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n' or after_key[i] == '\r')) : (i += 1)
    {}

    if (i >= after_key.len) return null;

    // Parse integer (possibly negative)
    const is_negative = after_key[i] == '-';
    if (is_negative) i += 1;
    if (i >= after_key.len or after_key[i] < '0' or after_key[i] > '9') return null;

    var result: i64 = 0;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {
        result = result * 10 + @as(i64, after_key[i] - '0');
    }
    return if (is_negative) -result else result;
}

/// Extract a boolean field from a JSON blob.
pub fn jsonBoolField(json: []const u8, key: []const u8) ?bool {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n' or after_key[i] == '\r')) : (i += 1)
    {}
    if (i >= after_key.len) return null;

    if (std.mem.startsWith(u8, after_key[i..], "true")) return true;
    if (std.mem.startsWith(u8, after_key[i..], "false")) return false;
    return null;
}

fn findWhatsAppConfigByVerifyToken(cfg: *const Config, verify_token: []const u8) ?*const config_types.WhatsAppConfig {
    for (cfg.channels.whatsapp) |*wa_cfg| {
        if (std.mem.eql(u8, wa_cfg.verify_token, verify_token)) return wa_cfg;
    }
    return null;
}

fn findWhatsAppConfigByPhoneNumberId(cfg: *const Config, phone_number_id: []const u8) ?*const config_types.WhatsAppConfig {
    for (cfg.channels.whatsapp) |*wa_cfg| {
        if (std.mem.eql(u8, wa_cfg.phone_number_id, phone_number_id)) return wa_cfg;
    }
    return null;
}

fn selectWhatsAppConfig(
    cfg_opt: ?*const Config,
    body: ?[]const u8,
    verify_token: ?[]const u8,
) ?*const config_types.WhatsAppConfig {
    if (!build_options.enable_channel_whatsapp) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.whatsapp.len == 0) return null;

    if (verify_token) |token| {
        if (findWhatsAppConfigByVerifyToken(cfg, token)) |wa_cfg| {
            return wa_cfg;
        }
    }

    if (body) |b| {
        if (jsonStringField(b, "phone_number_id")) |phone_number_id| {
            if (findWhatsAppConfigByPhoneNumberId(cfg, phone_number_id)) |wa_cfg| {
                return wa_cfg;
            }
        }
    }

    return &cfg.channels.whatsapp[0];
}

fn findTelegramConfigByAccountId(cfg: *const Config, account_id: []const u8) ?*const config_types.TelegramConfig {
    for (cfg.channels.telegram) |*tg_cfg| {
        if (std.ascii.eqlIgnoreCase(tg_cfg.account_id, account_id)) return tg_cfg;
    }
    return null;
}

fn selectTelegramConfig(
    cfg_opt: ?*const Config,
    target: []const u8,
) ?*const config_types.TelegramConfig {
    if (!build_options.enable_channel_telegram) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.telegram.len == 0) return null;

    if (parseQueryParam(target, "account_id")) |account_id| {
        if (findTelegramConfigByAccountId(cfg, account_id)) |tg_cfg| {
            return tg_cfg;
        }
    }
    if (parseQueryParam(target, "account")) |account_id| {
        if (findTelegramConfigByAccountId(cfg, account_id)) |tg_cfg| {
            return tg_cfg;
        }
    }

    if (cfg.channels.telegramPrimary()) |primary| {
        if (findTelegramConfigByAccountId(cfg, primary.account_id)) |tg_cfg| {
            return tg_cfg;
        }
    }
    return &cfg.channels.telegram[0];
}

fn hasLineSecrets(cfg: *const Config) bool {
    if (!build_options.enable_channel_line) return false;
    for (cfg.channels.line) |line_cfg| {
        if (line_cfg.channel_secret.len > 0) return true;
    }
    return false;
}

fn selectLineConfigBySignature(
    cfg_opt: ?*const Config,
    body: []const u8,
    signature: ?[]const u8,
) ?*const config_types.LineConfig {
    if (!build_options.enable_channel_line) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.line.len == 0) return null;

    if (signature) |sig| {
        for (cfg.channels.line) |*line_cfg| {
            if (channels.line.LineChannel.verifySignature(body, sig, line_cfg.channel_secret)) {
                return line_cfg;
            }
        }
        return null;
    }

    return &cfg.channels.line[0];
}

fn findLarkConfigByVerificationToken(
    cfg: *const Config,
    verification_token: []const u8,
) ?*const config_types.LarkConfig {
    for (cfg.channels.lark) |*lark_cfg| {
        if (std.mem.eql(u8, lark_cfg.verification_token orelse "", verification_token)) {
            return lark_cfg;
        }
    }
    return null;
}

fn selectLarkConfig(
    cfg_opt: ?*const Config,
    body: []const u8,
) ?*const config_types.LarkConfig {
    if (!build_options.enable_channel_lark) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.lark.len == 0) return null;

    if (jsonStringField(body, "token")) |verification_token| {
        if (findLarkConfigByVerificationToken(cfg, verification_token)) |lark_cfg| {
            return lark_cfg;
        }
    }

    return &cfg.channels.lark[0];
}

fn webhookBasePath(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |qi| return target[0..qi];
    return target;
}

fn normalizeSlackWebhookPath(path: []const u8) []const u8 {
    if (!build_options.enable_channel_slack) return path;
    return channels.slack.SlackChannel.normalizeWebhookPath(path);
}

fn hasSlackHttpEndpoint(cfg_opt: ?*const Config, base_path: []const u8) bool {
    if (!build_options.enable_channel_slack) return false;
    const cfg = cfg_opt orelse return std.mem.eql(u8, base_path, channels.slack.SlackChannel.DEFAULT_WEBHOOK_PATH);
    for (cfg.channels.slack) |slack_cfg| {
        if (slack_cfg.mode != .http) continue;
        if (std.mem.eql(u8, normalizeSlackWebhookPath(slack_cfg.webhook_path), base_path)) return true;
    }
    return false;
}

fn verifySlackSignature(
    allocator: std.mem.Allocator,
    body: []const u8,
    timestamp_header: []const u8,
    signature_header: []const u8,
    signing_secret: []const u8,
) bool {
    if (signing_secret.len == 0) return false;
    const ts_trimmed = std.mem.trim(u8, timestamp_header, " \t\r\n");
    const sig_trimmed = std.mem.trim(u8, signature_header, " \t\r\n");
    if (!std.mem.startsWith(u8, sig_trimmed, "v0=")) return false;

    const provided_hex = sig_trimmed["v0=".len..];
    if (provided_hex.len != 64) return false;

    const ts = std.fmt.parseInt(i64, ts_trimmed, 10) catch return false;
    const now = std.time.timestamp();
    const delta = if (now >= ts) now - ts else ts - now;
    if (delta > 300) return false; // 5-minute replay window

    var base_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer base_buf.deinit(allocator);
    const bw = base_buf.writer(allocator);
    bw.print("v0:{s}:", .{ts_trimmed}) catch return false;
    bw.writeAll(body) catch return false;

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, base_buf.items, signing_secret);

    var provided: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hi = hexVal(provided_hex[i * 2]) orelse return false;
        const lo = hexVal(provided_hex[i * 2 + 1]) orelse return false;
        provided[i] = (hi << 4) | lo;
    }
    return constantTimeEql(&mac, &provided);
}

fn findSlackConfigForRequest(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    target: []const u8,
    body: []const u8,
    timestamp_header: ?[]const u8,
    signature_header: ?[]const u8,
) ?*const config_types.SlackConfig {
    if (!build_options.enable_channel_slack) return null;
    const cfg = cfg_opt orelse return null;
    if (cfg.channels.slack.len == 0) return null;

    const base_path = webhookBasePath(target);
    for (cfg.channels.slack) |*slack_cfg| {
        if (slack_cfg.mode != .http) continue;
        if (!std.mem.eql(u8, normalizeSlackWebhookPath(slack_cfg.webhook_path), base_path)) continue;

        const secret = slack_cfg.signing_secret orelse continue;
        if (timestamp_header == null or signature_header == null) continue;
        if (verifySlackSignature(
            allocator,
            body,
            timestamp_header.?,
            signature_header.?,
            secret,
        )) return slack_cfg;
    }
    return null;
}

fn slackSessionKey(
    buf: []u8,
    account_id: []const u8,
    sender_id: []const u8,
    channel_id: []const u8,
    is_dm: bool,
) []const u8 {
    if (is_dm) {
        return std.fmt.bufPrint(buf, "slack:{s}:direct:{s}", .{ account_id, sender_id }) catch "slack:unknown";
    }
    return std.fmt.bufPrint(buf, "slack:{s}:channel:{s}", .{ account_id, channel_id }) catch "slack:unknown";
}

fn slackSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    account_id: []const u8,
    sender_id: []const u8,
    channel_id: []const u8,
    is_dm: bool,
    cfg_opt: ?*const Config,
) []const u8 {
    const fallback = slackSessionKey(fallback_buf, account_id, sender_id, channel_id, is_dm);
    return resolveRouteSessionKey(
        allocator,
        cfg_opt,
        "slack",
        account_id,
        .{
            .kind = if (is_dm) .direct else .channel,
            .id = if (is_dm) sender_id else channel_id,
        },
        fallback,
    );
}

fn slackEnvelopeBotUserId(payload_root: std.json.ObjectMap) ?[]const u8 {
    const authz = payload_root.get("authorizations") orelse return null;
    if (authz != .array or authz.array.items.len == 0) return null;
    const first = authz.array.items[0];
    if (first != .object) return null;
    const uid_val = first.object.get("user_id") orelse return null;
    if (uid_val != .string or uid_val.string.len == 0) return null;
    return uid_val.string;
}

fn whatsappSessionKey(buf: []u8, body: []const u8) []const u8 {
    const sender = jsonStringField(body, "from") orelse "unknown";
    const group_id = jsonStringField(body, "group_jid") orelse jsonStringField(body, "group_id");
    if (group_id) |gid| {
        return std.fmt.bufPrint(buf, "whatsapp:group:{s}:{s}", .{ gid, sender }) catch "whatsapp:unknown";
    }
    return std.fmt.bufPrint(buf, "whatsapp:{s}", .{sender}) catch "whatsapp:unknown";
}

fn whatsappReplyTarget(body: []const u8) []const u8 {
    // Cloud API delivery is addressed by recipient id ("from" for inbound DMs).
    // Group IDs are used for routing/session isolation, not outbound target.
    return jsonStringField(body, "from") orelse "unknown";
}

fn whatsappIsGroupMessage(body: []const u8) bool {
    return jsonStringField(body, "group_jid") != null or
        jsonStringField(body, "group_id") != null;
}

fn whatsappGroupId(body: []const u8) ?[]const u8 {
    return jsonStringField(body, "group_jid") orelse
        jsonStringField(body, "group_id");
}

fn whatsappSenderAllowed(
    sender: ?[]const u8,
    is_group: bool,
    group_id: ?[]const u8,
    allow_from: []const []const u8,
    group_allow_from: []const []const u8,
    groups: []const []const u8,
    group_policy: []const u8,
) bool {
    const sender_id = sender orelse return false;

    if (!is_group) {
        if (allow_from.len == 0) return false;
        return whatsappSenderInAllowlist(allow_from, sender_id);
    }

    if (std.mem.eql(u8, group_policy, "disabled")) return false;

    const group_allowlist_enabled = std.mem.eql(u8, group_policy, "allowlist") or groups.len > 0;
    if (group_allowlist_enabled) {
        const gid = group_id orelse return false;
        if (!channels.isAllowed(groups, gid)) return false;
    }

    if (std.mem.eql(u8, group_policy, "open")) return true;

    const effective_allow = if (group_allow_from.len > 0) group_allow_from else allow_from;
    if (effective_allow.len == 0) return false;
    return whatsappSenderInAllowlist(effective_allow, sender_id);
}

fn whatsappSenderInAllowlist(allowlist: []const []const u8, sender_raw: []const u8) bool {
    if (channels.isAllowed(allowlist, sender_raw)) return true;

    var normalized_buf: [64]u8 = undefined;
    const sender_normalized = channels.whatsapp.WhatsAppChannel.normalizePhone(&normalized_buf, sender_raw);
    if (!std.mem.eql(u8, sender_normalized, sender_raw) and channels.isAllowed(allowlist, sender_normalized)) {
        return true;
    }
    if (sender_normalized.len > 0 and sender_normalized[0] == '+' and
        channels.isAllowed(allowlist, sender_normalized[1..]))
    {
        return true;
    }
    return false;
}

fn whatsappSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    body: []const u8,
    cfg_opt: ?*const Config,
    account_id: []const u8,
) []const u8 {
    const sender = jsonStringField(body, "from") orelse "unknown";
    const group_id = jsonStringField(body, "group_jid") orelse jsonStringField(body, "group_id");
    const peer_id = if (group_id) |gid|
        if (gid.len > 0) gid else sender
    else
        sender;
    const peer_kind: agent_routing.ChatType = if (group_id != null) .group else .direct;

    if (cfg_opt) |cfg| {
        const route = agent_routing.resolveRouteWithSession(allocator, .{
            .channel = "whatsapp",
            .account_id = account_id,
            .peer = .{ .kind = peer_kind, .id = peer_id },
        }, cfg.agent_bindings, cfg.agents, cfg.session) catch return whatsappSessionKey(fallback_buf, body);
        allocator.free(route.main_session_key);
        return route.session_key;
    }

    return whatsappSessionKey(fallback_buf, body);
}

fn resolveRouteSessionKey(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    channel: []const u8,
    account_id: []const u8,
    peer: agent_routing.PeerRef,
    fallback: []const u8,
) []const u8 {
    if (cfg_opt) |cfg| {
        const route = agent_routing.resolveRouteWithSession(allocator, .{
            .channel = channel,
            .account_id = account_id,
            .peer = peer,
        }, cfg.agent_bindings, cfg.agents, cfg.session) catch return fallback;
        allocator.free(route.main_session_key);
        return route.session_key;
    }
    return fallback;
}

fn telegramChatIsGroup(allocator: std.mem.Allocator, body: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;

    const msg_obj = parsed.value.object.get("message") orelse
        parsed.value.object.get("edited_message") orelse return false;
    if (msg_obj != .object) return false;

    const chat_obj = msg_obj.object.get("chat") orelse return false;
    if (chat_obj != .object) return false;

    const type_val = chat_obj.object.get("type") orelse return false;
    if (type_val != .string) return false;

    return std.mem.eql(u8, type_val.string, "group") or
        std.mem.eql(u8, type_val.string, "supergroup") or
        std.mem.eql(u8, type_val.string, "channel");
}

fn telegramSenderAllowed(allocator: std.mem.Allocator, allow_from: []const []const u8, body: []const u8) bool {
    // Empty allowlist means sender filtering is disabled for this connected user.
    if (allow_from.len == 0) return true;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;

    const msg_obj = parsed.value.object.get("message") orelse
        parsed.value.object.get("edited_message") orelse return false;
    if (msg_obj != .object) return false;

    const from_obj = msg_obj.object.get("from") orelse return false;
    if (from_obj != .object) return false;

    if (from_obj.object.get("username")) |uname| {
        if (uname == .string and channels.isAllowed(allow_from, uname.string)) return true;
    }

    if (from_obj.object.get("id")) |id_val| {
        if (id_val == .integer) {
            var id_buf: [32]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id_val.integer}) catch return false;
            if (channels.isAllowed(allow_from, id_str)) return true;
        }
    }

    return false;
}

fn telegramSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    chat_id: i64,
    body: []const u8,
    cfg_opt: ?*const Config,
    account_id: []const u8,
) []const u8 {
    const fallback = std.fmt.bufPrint(fallback_buf, "telegram:{d}", .{chat_id}) catch "telegram:0";
    var peer_buf: [64]u8 = undefined;
    const peer_id = std.fmt.bufPrint(&peer_buf, "{d}", .{chat_id}) catch return fallback;
    const peer_kind: agent_routing.ChatType = if (telegramChatIsGroup(allocator, body)) .group else .direct;
    return resolveRouteSessionKey(
        allocator,
        cfg_opt,
        "telegram",
        account_id,
        .{ .kind = peer_kind, .id = peer_id },
        fallback,
    );
}

fn telegramChatId(allocator: std.mem.Allocator, body: []const u8) ?i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return jsonIntField(body, "chat_id");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return jsonIntField(body, "chat_id");

    const msg_obj = parsed.value.object.get("message") orelse
        parsed.value.object.get("edited_message") orelse return jsonIntField(body, "chat_id");
    if (msg_obj != .object) return jsonIntField(body, "chat_id");

    const chat_obj = msg_obj.object.get("chat") orelse return jsonIntField(body, "chat_id");
    if (chat_obj != .object) return jsonIntField(body, "chat_id");

    const id_val = chat_obj.object.get("id") orelse return jsonIntField(body, "chat_id");
    if (id_val != .integer) return jsonIntField(body, "chat_id");
    return id_val.integer;
}

fn telegramThreadKey(allocator: std.mem.Allocator, body: []const u8, buf: []u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const msg_obj = parsed.value.object.get("message") orelse
        parsed.value.object.get("edited_message") orelse return null;
    if (msg_obj != .object) return null;

    const thread_val = msg_obj.object.get("message_thread_id") orelse return null;
    if (thread_val != .integer) return null;
    return std.fmt.bufPrint(buf, "{d}", .{thread_val.integer}) catch null;
}

const TenantTelegramLaneResolution = struct {
    fallback_session_key: []const u8,
    lane: inbound_canonicalizer.CanonicalSessionLane,
    canonical_thread_key: ?[]const u8 = null,
};

fn buildTelegramCanonicalThreadKey(
    chat_id: i64,
    topic_key_opt: ?[]const u8,
    buf: []u8,
) ?[]const u8 {
    if (topic_key_opt) |topic_key| {
        return std.fmt.bufPrint(buf, "{d}:{s}", .{ chat_id, topic_key }) catch
            std.fmt.bufPrint(buf, "{d}", .{chat_id}) catch null;
    }
    return std.fmt.bufPrint(buf, "{d}", .{chat_id}) catch null;
}

fn resolveTenantTelegramLane(
    allocator: std.mem.Allocator,
    cfg_opt: ?*const Config,
    use_shared_main: bool,
    user_id: []const u8,
    account_id: []const u8,
    chat_id: i64,
    body_opt: ?[]const u8,
    fallback_buf: []u8,
    topic_buf: []u8,
    lane_buf: []u8,
) TenantTelegramLaneResolution {
    const topic_key = if (body_opt) |body|
        telegramThreadKey(allocator, body, topic_buf)
    else
        null;
    const is_group_chat = if (body_opt) |body|
        telegramChatIsGroup(allocator, body)
    else
        chat_id < 0;

    if (!is_group_chat and topic_key == null) {
        return .{
            .fallback_session_key = zaki_session.userMainSessionKey(fallback_buf, user_id),
            .lane = .main,
            .canonical_thread_key = null,
        };
    }

    if (use_shared_main) {
        return .{
            .fallback_session_key = zaki_session.userMainSessionKey(fallback_buf, user_id),
            .lane = .main,
            .canonical_thread_key = null,
        };
    }

    const canonical_thread_key = buildTelegramCanonicalThreadKey(chat_id, topic_key, lane_buf);
    const fallback_session_key = if (canonical_thread_key) |thread_key|
        zaki_session.userThreadSessionKey(fallback_buf, user_id, thread_key)
    else if (body_opt) |body|
        telegramSessionKeyRouted(allocator, fallback_buf, chat_id, body, cfg_opt, account_id)
    else
        std.fmt.bufPrint(fallback_buf, "telegram:{d}", .{chat_id}) catch "telegram:0";
    return .{
        .fallback_session_key = fallback_session_key,
        .lane = .thread,
        .canonical_thread_key = canonical_thread_key,
    };
}

fn telegramSenderIdentity(
    allocator: std.mem.Allocator,
    body: []const u8,
    id_buf: []u8,
) []const u8 {
    if (jsonStringField(body, "username")) |uname| return uname;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return "unknown";
    defer parsed.deinit();
    if (parsed.value != .object) return "unknown";

    const msg_obj = parsed.value.object.get("message") orelse
        parsed.value.object.get("edited_message") orelse return "unknown";
    if (msg_obj != .object) return "unknown";

    const from_obj = msg_obj.object.get("from") orelse return "unknown";
    if (from_obj != .object) return "unknown";
    if (from_obj.object.get("id")) |id_val| {
        if (id_val == .integer) {
            return std.fmt.bufPrint(id_buf, "{d}", .{id_val.integer}) catch "unknown";
        }
    }
    return "unknown";
}

const TelegramWebhookTranscriber = struct {
    whisper: ?*voice.WhisperTranscriber = null,
    transcriber: ?voice.Transcriber = null,

    fn deinit(self: *TelegramWebhookTranscriber, allocator: std.mem.Allocator) void {
        if (self.whisper) |ptr| allocator.destroy(ptr);
        self.* = .{};
    }
};

fn buildTelegramWebhookTranscriber(
    allocator: std.mem.Allocator,
    cfg: *const Config,
) TelegramWebhookTranscriber {
    if (!cfg.audio_media.enabled) return .{};
    const provider_name = cfg.audio_media.provider;
    const api_key = cfg.getProviderKey(provider_name) orelse return .{};
    const whisper = allocator.create(voice.WhisperTranscriber) catch return .{};
    whisper.* = .{
        .endpoint = voice.resolveTranscriptionEndpoint(provider_name, cfg.audio_media.base_url),
        .api_key = api_key,
        .model = cfg.audio_media.model,
        .language = cfg.audio_media.language,
    };
    voice.markTelegramTranscriberConfigured();
    return .{
        .whisper = whisper,
        .transcriber = whisper.transcriber(),
    };
}

fn telegramWebhookExtractInboundText(
    allocator: std.mem.Allocator,
    body: []const u8,
    bot_token: []const u8,
    transcriber: ?voice.Transcriber,
    proxy: ?[]const u8,
) ?[]u8 {
    const VOICE_FALLBACK = "[Voice]: (transcription unavailable)";
    const IMAGE_FALLBACK = "[Image]: (caption unavailable)";
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const msg_obj = parsed.value.object.get("message") orelse
        parsed.value.object.get("edited_message") orelse return null;
    if (msg_obj != .object) return null;
    var saw_voice_or_audio = false;
    var saw_photo = false;
    const caption_text: ?[]const u8 = blk: {
        if (msg_obj.object.get("caption")) |caption_val| {
            if (caption_val == .string) break :blk caption_val.string;
        }
        break :blk null;
    };

    if (msg_obj.object.get("text")) |text_val| {
        if (text_val == .string) return allocator.dupe(u8, text_val.string) catch null;
    }

    if (msg_obj.object.get("voice")) |voice_val| {
        saw_voice_or_audio = true;
        if (voice_val == .object) {
            if (voice_val.object.get("file_id")) |file_id_val| {
                if (file_id_val == .string) {
                    if (voice.transcribeTelegramVoice(allocator, bot_token, file_id_val.string, transcriber, proxy)) |transcribed| {
                        defer allocator.free(transcribed);
                        return std.fmt.allocPrint(allocator, "[Voice]: {s}", .{transcribed}) catch null;
                    }
                }
            }
        }
    }

    if (msg_obj.object.get("audio")) |audio_val| {
        saw_voice_or_audio = true;
        if (audio_val == .object) {
            if (audio_val.object.get("file_id")) |file_id_val| {
                if (file_id_val == .string) {
                    if (voice.transcribeTelegramVoice(allocator, bot_token, file_id_val.string, transcriber, proxy)) |transcribed| {
                        defer allocator.free(transcribed);
                        return std.fmt.allocPrint(allocator, "[Voice]: {s}", .{transcribed}) catch null;
                    }
                }
            }
        }
    }

    if (msg_obj.object.get("photo")) |photo_val| {
        if (photo_val == .array and photo_val.array.items.len > 0) {
            saw_photo = true;
            const last_photo = photo_val.array.items[photo_val.array.items.len - 1];
            if (last_photo == .object) {
                if (last_photo.object.get("file_id")) |photo_fid_val| {
                    if (photo_fid_val == .string) {
                        if (channels.telegram.downloadTelegramPhoto(allocator, bot_token, photo_fid_val.string, proxy)) |local_path| {
                            var result: std.ArrayListUnmanaged(u8) = .empty;
                            result.appendSlice(allocator, "[IMAGE:") catch {
                                allocator.free(local_path);
                                return null;
                            };
                            result.appendSlice(allocator, local_path) catch {
                                allocator.free(local_path);
                                result.deinit(allocator);
                                return null;
                            };
                            result.appendSlice(allocator, "]") catch {
                                allocator.free(local_path);
                                result.deinit(allocator);
                                return null;
                            };
                            allocator.free(local_path);
                            if (caption_text) |caption| {
                                result.appendSlice(allocator, " ") catch {};
                                result.appendSlice(allocator, caption) catch {};
                            }
                            return result.toOwnedSlice(allocator) catch {
                                result.deinit(allocator);
                                return null;
                            };
                        }
                    }
                }
            }
        }
    }

    if (caption_text) |caption| {
        return allocator.dupe(u8, caption) catch null;
    }

    if (saw_voice_or_audio) {
        return allocator.dupe(u8, VOICE_FALLBACK) catch null;
    }
    if (saw_photo) {
        return allocator.dupe(u8, IMAGE_FALLBACK) catch null;
    }

    return null;
}

fn tenantTelegramUsesSharedMain(cfg_opt: ?*const Config) bool {
    _ = cfg_opt;
    return false;
}

fn lineSessionKey(buf: []u8, evt: channels.line.LineEvent) []const u8 {
    return std.fmt.bufPrint(buf, "line:{s}", .{evt.user_id orelse "unknown"}) catch "line:unknown";
}

fn lineReplyTarget(evt: channels.line.LineEvent) []const u8 {
    const source_type = evt.source_type orelse "";
    if (std.mem.eql(u8, source_type, "group")) {
        return evt.group_id orelse evt.user_id orelse "unknown";
    }
    if (std.mem.eql(u8, source_type, "room")) {
        return evt.room_id orelse evt.user_id orelse "unknown";
    }
    return evt.user_id orelse "unknown";
}

fn lineSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    evt: channels.line.LineEvent,
    cfg_opt: ?*const Config,
    account_id: []const u8,
) []const u8 {
    const fallback = lineSessionKey(fallback_buf, evt);
    const src_type = evt.source_type orelse "";
    const peer_kind: agent_routing.ChatType = if (std.mem.eql(u8, src_type, "group") or std.mem.eql(u8, src_type, "room")) .group else .direct;
    var peer_buf: [160]u8 = undefined;
    const peer_id = if (std.mem.eql(u8, src_type, "group"))
        std.fmt.bufPrint(&peer_buf, "group:{s}", .{evt.group_id orelse evt.user_id orelse "unknown"}) catch return fallback
    else if (std.mem.eql(u8, src_type, "room"))
        std.fmt.bufPrint(&peer_buf, "room:{s}", .{evt.room_id orelse evt.user_id orelse "unknown"}) catch return fallback
    else
        evt.user_id orelse "unknown";
    return resolveRouteSessionKey(
        allocator,
        cfg_opt,
        "line",
        account_id,
        .{ .kind = peer_kind, .id = peer_id },
        fallback,
    );
}

fn larkSessionKey(buf: []u8, msg: channels.lark.ParsedLarkMessage) []const u8 {
    return std.fmt.bufPrint(buf, "lark:{s}", .{msg.sender}) catch "lark:unknown";
}

fn larkSessionKeyRouted(
    allocator: std.mem.Allocator,
    fallback_buf: []u8,
    msg: channels.lark.ParsedLarkMessage,
    cfg_opt: ?*const Config,
    account_id: []const u8,
) []const u8 {
    const fallback = larkSessionKey(fallback_buf, msg);
    const peer_kind: agent_routing.ChatType = if (msg.is_group) .group else .direct;
    return resolveRouteSessionKey(
        allocator,
        cfg_opt,
        "lark",
        account_id,
        .{ .kind = peer_kind, .id = msg.sender },
        fallback,
    );
}

// ── Message Processing ──────────────────────────────────────────

/// Extract the HTTP request body from raw bytes.
/// Finds the \r\n\r\n boundary and returns everything after it.
pub fn extractBody(raw: []const u8) ?[]const u8 {
    const separator = "\r\n\r\n";
    const pos = std.mem.indexOf(u8, raw, separator) orelse return null;
    const body = raw[pos + separator.len ..];
    if (body.len == 0) return null;
    return body;
}

fn buildIncomingMessageAgentArgv(
    allocator: std.mem.Allocator,
    self_path: []const u8,
    message: []const u8,
    session_key: ?[]const u8,
    user_id: ?[]const u8,
) ![][]const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ self_path, "agent", "-m", message });
    if (session_key) |value| {
        try argv.appendSlice(allocator, &.{ "--session", value });
    }
    if (user_id) |value| {
        try argv.appendSlice(allocator, &.{ "--user-id", value });
    }
    return try argv.toOwnedSlice(allocator);
}

/// Process an incoming message by spawning `nullalis agent -m "..."`.
/// Returns the agent's response text. Caller owns the returned memory.
pub fn processIncomingMessage(
    allocator: std.mem.Allocator,
    message: []const u8,
    session_key: ?[]const u8,
    user_id: ?[]const u8,
) ![]u8 {
    // Find our own executable path
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&self_buf) catch "nullalis";

    const argv = try buildIncomingMessageAgentArgv(allocator, self_path, message, session_key, user_id);
    defer allocator.free(argv);
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read stdout
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);

    const stdout_reader = child.stdout.?;
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = stdout_reader.read(&read_buf) catch break;
        if (n == 0) break;
        try stdout_buf.appendSlice(allocator, read_buf[0..n]);
    }

    const term = try child.wait();
    _ = term;

    if (stdout_buf.items.len > 0) {
        return try allocator.dupe(u8, stdout_buf.items);
    }
    return try allocator.dupe(u8, "No response from agent");
}

/// Send a reply to a Telegram chat using the Bot API.
pub fn sendTelegramReply(allocator: std.mem.Allocator, bot_token: []const u8, chat_id: i64, text: []const u8) !void {
    const normalized_bot_token = normalizeTelegramBotToken(bot_token);
    if (!isLikelyTelegramBotToken(normalized_bot_token)) {
        const colon_idx = std.mem.indexOfScalar(u8, normalized_bot_token, ':');
        const colon_pos: i64 = if (colon_idx) |idx| @intCast(idx) else -1;
        log.warn("telegram send skipped: invalid bot token shape chat_id={d} len={d} colon_pos={d}", .{ chat_id, normalized_bot_token.len, colon_pos });
        return error.CurlFailed;
    }

    if (telegramReplyContainsMediaMarkers(text)) {
        var chat_id_buf: [32]u8 = undefined;
        const chat_id_str = std.fmt.bufPrint(&chat_id_buf, "{d}", .{chat_id}) catch return error.CurlFailed;
        var tg_channel = channels.telegram.TelegramChannel.init(
            allocator,
            normalized_bot_token,
            &.{"*"},
            &.{},
            "open",
        );
        return tg_channel.sendMessageWithReply(chat_id_str, text, null);
    }

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(allocator);
    const w = body_buf.writer(allocator);
    try w.print("{{\"chat_id\":{d},\"text\":\"", .{chat_id});
    for (text) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"}");

    const resp = telegramApiCall(allocator, normalized_bot_token, "sendMessage", body_buf.items) catch |err| {
        log.warn("telegramApiCall sendMessage failed: {}", .{err});
        return sendTelegramReplyViaCurlFallback(allocator, normalized_bot_token, body_buf.items);
    };
    defer allocator.free(resp);
    ensureTelegramSendMessageAccepted(allocator, resp) catch |err| {
        switch (err) {
            error.TelegramApiUnexpectedResponse => return error.TelegramApiRejected,
            else => return err,
        }
    };
}

fn ensureTelegramSendMessageAccepted(allocator: std.mem.Allocator, response_body: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch {
        const preview_len: usize = @min(response_body.len, 220);
        log.warn("telegram sendMessage rejected: non-json body_preview={s}", .{response_body[0..preview_len]});
        return error.TelegramApiUnexpectedResponse;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.TelegramApiUnexpectedResponse;

    const ok_val = parsed.value.object.get("ok") orelse return error.TelegramApiUnexpectedResponse;
    if (ok_val == .bool and ok_val.bool) return;

    if (parsed.value.object.get("description")) |desc_val| {
        if (desc_val == .string and desc_val.string.len > 0) {
            log.warn("telegram sendMessage rejected: {s}", .{desc_val.string});
            return error.TelegramApiRejected;
        }
    }

    const preview_len: usize = @min(response_body.len, 220);
    log.warn("telegram sendMessage unexpected payload: body_preview={s}", .{response_body[0..preview_len]});
    return error.TelegramApiUnexpectedResponse;
}

fn telegramReplyContainsMediaMarkers(text: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, "[AUDIO:") != null or
        std.ascii.indexOfIgnoreCase(text, "[VOICE:") != null or
        std.ascii.indexOfIgnoreCase(text, "[IMAGE:") != null or
        std.ascii.indexOfIgnoreCase(text, "[VIDEO:") != null or
        std.ascii.indexOfIgnoreCase(text, "[DOCUMENT:") != null;
}

fn sendTelegramReplyViaCurlFallback(allocator: std.mem.Allocator, bot_token: []const u8, body: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{bot_token});
    defer allocator.free(url);

    var child = std.process.Child.init(
        &[_][]const u8{
            "curl",
            "-sS",
            "--max-time",
            "30",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            "@-",
            url,
        },
        allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    if (child.stdin) |stdin_file| {
        stdin_file.writeAll(body) catch {
            stdin_file.close();
            child.stdin = null;
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return error.CurlWriteError;
        };
        stdin_file.close();
        child.stdin = null;
    } else {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return error.CurlWriteError;
    }

    const stdout_bytes = if (child.stdout) |stdout_file|
        stdout_file.readToEndAlloc(allocator, 1024 * 1024) catch &.{}
    else
        &.{};
    defer if (stdout_bytes.len > 0) allocator.free(stdout_bytes);

    const stderr_bytes = if (child.stderr) |stderr_file|
        stderr_file.readToEndAlloc(allocator, 256 * 1024) catch &.{}
    else
        &.{};
    defer if (stderr_bytes.len > 0) allocator.free(stderr_bytes);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            log.warn("telegram curl fallback failed code={d} stderr_len={d}", .{ code, stderr_bytes.len });
            return error.CurlFailed;
        },
        else => return error.CurlFailed,
    }

    if (stdout_bytes.len == 0) return;
    ensureTelegramSendMessageAccepted(allocator, stdout_bytes) catch |err| switch (err) {
        error.TelegramApiUnexpectedResponse => return error.TelegramApiRejected,
        else => return err,
    };
}

fn userFacingAgentError(err: anyerror) []const u8 {
    return switch (err) {
        error.Timeout => "The model request timed out. Please try again.",
        error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError => "Network error. Please try again.",
        error.ProviderDoesNotSupportVision => "The current provider does not support image input.",
        error.AllProvidersFailed => "All configured providers failed for this request. Check model/provider compatibility and credentials.",
        error.NoResponseContent => "Model returned an empty response. Please try again.",
        error.OutOfMemory => "Out of memory.",
        else => "An error occurred. Try again.",
    };
}

fn userFacingAgentErrorJson(err: anyerror) []const u8 {
    return switch (err) {
        error.Timeout => "{\"error\":\"request timed out\"}",
        error.CurlFailed, error.CurlReadError, error.CurlWaitError, error.CurlWriteError => "{\"error\":\"network error\"}",
        error.ProviderDoesNotSupportVision => "{\"error\":\"provider does not support image input\"}",
        error.AllProvidersFailed => "{\"error\":\"all providers failed for this request\"}",
        error.NoResponseContent => "{\"error\":\"model returned empty response\"}",
        error.OutOfMemory => "{\"error\":\"out of memory\"}",
        else => "{\"error\":\"agent failure\"}",
    };
}

const RouteResponse = struct {
    status: []const u8 = "200 OK",
    body: []const u8 = "",
    content_type: []const u8 = "application/json",
    retry_after_secs: ?u16 = null,
};

const TenantLockConflictRoute = enum {
    chat_stream_sse,
    chat_stream_http,
    webhook,
    daemon,
    api,
};

fn recordTenantLockConflict(state: *GatewayState, route: TenantLockConflictRoute) void {
    _ = state.tenant_lock_conflicts_total.fetchAdd(1, .monotonic);
    switch (route) {
        .chat_stream_sse => _ = state.tenant_lock_conflicts_chat_stream_sse_total.fetchAdd(1, .monotonic),
        .chat_stream_http => _ = state.tenant_lock_conflicts_chat_stream_http_total.fetchAdd(1, .monotonic),
        .webhook => _ = state.tenant_lock_conflicts_webhook_total.fetchAdd(1, .monotonic),
        .daemon => _ = state.tenant_lock_conflicts_daemon_total.fetchAdd(1, .monotonic),
        .api => _ = state.tenant_lock_conflicts_api_total.fetchAdd(1, .monotonic),
    }
}

fn recordTenantLockConflictRetries(state: *GatewayState, retries: u32) void {
    if (retries == 0) return;
    _ = state.tenant_lock_conflict_retries_total.fetchAdd(retries, .monotonic);
}

const TenantOwnershipLockConfig = struct {
    lease_secs: u64 = TENANT_OWNERSHIP_LOCK_LEASE_SECS,
    wait_ms: u32 = TENANT_OWNERSHIP_LOCK_WAIT_MS_DEFAULT,
    retry_min_ms: u32 = TENANT_OWNERSHIP_LOCK_RETRY_MS_MIN_DEFAULT,
    retry_max_ms: u32 = TENANT_OWNERSHIP_LOCK_RETRY_MS_MAX_DEFAULT,
};

fn normalizeTenantOwnershipLockConfig(cfg: config_types.TenantConfig) TenantOwnershipLockConfig {
    var out = TenantOwnershipLockConfig{};
    out.lease_secs = @intCast(std.math.clamp(
        cfg.ownership_lock_lease_secs,
        TENANT_OWNERSHIP_LOCK_LEASE_SECS_MIN,
        TENANT_OWNERSHIP_LOCK_LEASE_SECS_MAX,
    ));
    out.wait_ms = std.math.clamp(
        cfg.ownership_lock_wait_ms,
        TENANT_OWNERSHIP_LOCK_WAIT_MS_MIN,
        TENANT_OWNERSHIP_LOCK_WAIT_MS_MAX,
    );
    out.retry_min_ms = std.math.clamp(
        cfg.ownership_lock_retry_min_ms,
        TENANT_OWNERSHIP_LOCK_RETRY_MS_MIN,
        TENANT_OWNERSHIP_LOCK_RETRY_MS_MAX,
    );
    out.retry_max_ms = std.math.clamp(
        cfg.ownership_lock_retry_max_ms,
        TENANT_OWNERSHIP_LOCK_RETRY_MS_MIN,
        TENANT_OWNERSHIP_LOCK_RETRY_MS_MAX,
    );
    if (out.retry_min_ms > out.retry_max_ms) {
        std.mem.swap(u32, &out.retry_min_ms, &out.retry_max_ms);
    }
    return out;
}

fn normalizedLocalAgentMemoryConfig(cfg: *const Config) config_types.MemoryConfig {
    var memory_cfg = cfg.memory;
    if (cfg.tenant.enabled and std.mem.eql(u8, cfg.state.backend, "postgres")) {
        // In hosted tenant mode, canonical memory lives in ZAKI Postgres tables and is
        // wrapped by zaki_dual later. The generic Postgres memory engine targets a
        // different schema, so the shared gateway bootstrap must start from the
        // markdown leg just like tenant runtime init does.
        memory_cfg.backend = "markdown";
    }
    return memory_cfg;
}

fn metricsPayload(allocator: std.mem.Allocator, state: *const GatewayState) ![]u8 {
    const transport_stats = http_util.transport_stats_snapshot();
    const requests_total = state.requests_total.load(.monotonic);
    const chat_stream_total = state.chat_stream_total.load(.monotonic);
    const chat_stream_errors_total = state.chat_stream_errors_total.load(.monotonic);
    const telegram_webhook_total = state.telegram_webhook_total.load(.monotonic);
    const telegram_webhook_rejected_total = state.telegram_webhook_rejected_total.load(.monotonic);
    const tenant_lock_conflicts_total = state.tenant_lock_conflicts_total.load(.monotonic);
    const tenant_lock_conflicts_chat_stream_sse_total = state.tenant_lock_conflicts_chat_stream_sse_total.load(.monotonic);
    const tenant_lock_conflicts_chat_stream_http_total = state.tenant_lock_conflicts_chat_stream_http_total.load(.monotonic);
    const tenant_lock_conflicts_webhook_total = state.tenant_lock_conflicts_webhook_total.load(.monotonic);
    const tenant_lock_conflicts_daemon_total = state.tenant_lock_conflicts_daemon_total.load(.monotonic);
    const tenant_lock_conflicts_api_total = state.tenant_lock_conflicts_api_total.load(.monotonic);
    const tenant_lock_conflict_retries_total = state.tenant_lock_conflict_retries_total.load(.monotonic);
    const chat_stream_lane_main_total = state.chat_stream_lane_main_total.load(.monotonic);
    const chat_stream_lane_thread_total = state.chat_stream_lane_thread_total.load(.monotonic);
    const chat_stream_lane_task_total = state.chat_stream_lane_task_total.load(.monotonic);
    const chat_stream_lane_cron_total = state.chat_stream_lane_cron_total.load(.monotonic);
    const chat_stream_session_key_missing_total = state.chat_stream_session_key_missing_total.load(.monotonic);
    const chat_stream_session_key_invalid_total = state.chat_stream_session_key_invalid_total.load(.monotonic);
    const chat_stream_session_key_wrong_user_total = state.chat_stream_session_key_wrong_user_total.load(.monotonic);
    const chat_stream_session_key_invalid_lane_total = state.chat_stream_session_key_invalid_lane_total.load(.monotonic);
    const in_flight_requests = state.in_flight_requests.load(.monotonic);
    const drain_rejected_total = state.drain_rejected_total.load(.monotonic);
    const overload_rejected_total = state.overload_rejected_total.load(.monotonic);
    const lifecycle_lock_wait_total = state.lifecycle_metrics.lock_wait_total.load(.monotonic);
    const lifecycle_lock_wait_duration_ms_total = state.lifecycle_metrics.lock_wait_duration_ms_total.load(.monotonic);
    const lifecycle_compaction_total = state.lifecycle_metrics.compaction_total.load(.monotonic);
    const lifecycle_compaction_duration_ms_total = state.lifecycle_metrics.compaction_duration_ms_total.load(.monotonic);
    const lifecycle_continuity_refresh_total = state.lifecycle_metrics.continuity_refresh_total.load(.monotonic);
    const lifecycle_continuity_refresh_duration_ms_total = state.lifecycle_metrics.continuity_refresh_duration_ms_total.load(.monotonic);
    const lifecycle_pruning_total = state.lifecycle_metrics.pruning_total.load(.monotonic);
    const lifecycle_pruning_duration_ms_total = state.lifecycle_metrics.pruning_duration_ms_total.load(.monotonic);
    const tenant_runtime_pruned_idle_total = state.lifecycle_metrics.tenant_runtime_pruned_idle_total.load(.monotonic);
    const tenant_runtime_pruned_capacity_total = state.lifecycle_metrics.tenant_runtime_pruned_capacity_total.load(.monotonic);
    const draining = state.draining.load(.acquire);
    const shutdown_requested = state.shutdown_requested.load(.acquire);
    const pool = http_native.pool_mod.globalPool(.{}, http_native.closePooledConnForGateway);
    const pool_hits = pool.hits.load(.monotonic);
    const pool_misses = pool.misses.load(.monotonic);
    const pool_idle = pool.idleCount();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.print(
        \\# HELP nullalis_gateway_requests_total Total HTTP requests handled.
        \\# TYPE nullalis_gateway_requests_total counter
        \\nullalis_gateway_requests_total {d}
        \\# HELP nullalis_gateway_chat_stream_total Total chat stream requests.
        \\# TYPE nullalis_gateway_chat_stream_total counter
        \\nullalis_gateway_chat_stream_total {d}
        \\# HELP nullalis_gateway_chat_stream_errors_total Total chat stream errors.
        \\# TYPE nullalis_gateway_chat_stream_errors_total counter
        \\nullalis_gateway_chat_stream_errors_total {d}
        \\# HELP nullalis_gateway_chat_stream_lanes_total Accepted chat stream requests by lane.
        \\# TYPE nullalis_gateway_chat_stream_lanes_total counter
        \\nullalis_gateway_chat_stream_lanes_total{{lane="main"}} {d}
        \\nullalis_gateway_chat_stream_lanes_total{{lane="thread"}} {d}
        \\nullalis_gateway_chat_stream_lanes_total{{lane="task"}} {d}
        \\nullalis_gateway_chat_stream_lanes_total{{lane="cron"}} {d}
        \\# HELP nullalis_gateway_chat_stream_session_key_rejections_total Rejected chat stream requests by session_key validation reason.
        \\# TYPE nullalis_gateway_chat_stream_session_key_rejections_total counter
        \\nullalis_gateway_chat_stream_session_key_rejections_total{{reason="missing"}} {d}
        \\nullalis_gateway_chat_stream_session_key_rejections_total{{reason="invalid"}} {d}
        \\nullalis_gateway_chat_stream_session_key_rejections_total{{reason="wrong_user"}} {d}
        \\nullalis_gateway_chat_stream_session_key_rejections_total{{reason="invalid_lane"}} {d}
        \\# HELP nullalis_gateway_telegram_webhook_total Total telegram webhook requests.
        \\# TYPE nullalis_gateway_telegram_webhook_total counter
        \\nullalis_gateway_telegram_webhook_total {d}
        \\# HELP nullalis_gateway_telegram_webhook_rejected_total Total rejected telegram webhooks.
        \\# TYPE nullalis_gateway_telegram_webhook_rejected_total counter
        \\nullalis_gateway_telegram_webhook_rejected_total {d}
        \\
    ,
        .{
            requests_total,
            chat_stream_total,
            chat_stream_errors_total,
            chat_stream_lane_main_total,
            chat_stream_lane_thread_total,
            chat_stream_lane_task_total,
            chat_stream_lane_cron_total,
            chat_stream_session_key_missing_total,
            chat_stream_session_key_invalid_total,
            chat_stream_session_key_wrong_user_total,
            chat_stream_session_key_invalid_lane_total,
            telegram_webhook_total,
            telegram_webhook_rejected_total,
        },
    );
    try w.print(
        \\# HELP nullalis_gateway_tenant_lock_conflicts_total Total tenant ownership-lock conflicts.
        \\# TYPE nullalis_gateway_tenant_lock_conflicts_total counter
        \\nullalis_gateway_tenant_lock_conflicts_total {d}
        \\# HELP nullalis_gateway_tenant_lock_conflicts_by_route_total Tenant ownership-lock conflicts by route.
        \\# TYPE nullalis_gateway_tenant_lock_conflicts_by_route_total counter
        \\nullalis_gateway_tenant_lock_conflicts_by_route_total{{route="chat_stream_sse"}} {d}
        \\nullalis_gateway_tenant_lock_conflicts_by_route_total{{route="chat_stream_http"}} {d}
        \\nullalis_gateway_tenant_lock_conflicts_by_route_total{{route="webhook"}} {d}
        \\nullalis_gateway_tenant_lock_conflicts_by_route_total{{route="daemon"}} {d}
        \\nullalis_gateway_tenant_lock_conflicts_by_route_total{{route="api"}} {d}
        \\# HELP nullalis_gateway_tenant_lock_conflict_retries_total Total lock-acquire retry attempts before conflicts/success.
        \\# TYPE nullalis_gateway_tenant_lock_conflict_retries_total counter
        \\nullalis_gateway_tenant_lock_conflict_retries_total {d}
        \\# HELP nullalis_gateway_in_flight_requests Current in-flight requests.
        \\# TYPE nullalis_gateway_in_flight_requests gauge
        \\nullalis_gateway_in_flight_requests {d}
        \\# HELP nullalis_gateway_drain_rejected_total Total requests rejected while draining.
        \\# TYPE nullalis_gateway_drain_rejected_total counter
        \\nullalis_gateway_drain_rejected_total {d}
        \\# HELP nullalis_gateway_overload_rejected_total Total requests rejected due to queue overload.
        \\# TYPE nullalis_gateway_overload_rejected_total counter
        \\nullalis_gateway_overload_rejected_total {d}
        \\# HELP nullalis_gateway_drain_mode Current drain mode status.
        \\# TYPE nullalis_gateway_drain_mode gauge
        \\nullalis_gateway_drain_mode {d}
        \\# HELP nullalis_gateway_shutdown_requested Whether shutdown has been requested.
        \\# TYPE nullalis_gateway_shutdown_requested gauge
        \\nullalis_gateway_shutdown_requested {d}
        \\# HELP nullalis_gateway_lifecycle_stage_total Total lifecycle-tax events separated from core turn execution.
        \\# TYPE nullalis_gateway_lifecycle_stage_total counter
        \\nullalis_gateway_lifecycle_stage_total{{stage="lock_wait"}} {d}
        \\nullalis_gateway_lifecycle_stage_total{{stage="compaction"}} {d}
        \\nullalis_gateway_lifecycle_stage_total{{stage="continuity_refresh"}} {d}
        \\nullalis_gateway_lifecycle_stage_total{{stage="pruning"}} {d}
        \\# HELP nullalis_gateway_lifecycle_stage_duration_ms_total Total lifecycle-tax milliseconds by stage.
        \\# TYPE nullalis_gateway_lifecycle_stage_duration_ms_total counter
        \\nullalis_gateway_lifecycle_stage_duration_ms_total{{stage="lock_wait"}} {d}
        \\nullalis_gateway_lifecycle_stage_duration_ms_total{{stage="compaction"}} {d}
        \\nullalis_gateway_lifecycle_stage_duration_ms_total{{stage="continuity_refresh"}} {d}
        \\nullalis_gateway_lifecycle_stage_duration_ms_total{{stage="pruning"}} {d}
        \\# HELP nullalis_gateway_tenant_runtime_pruned_total Total tenant runtimes removed by maintenance reason.
        \\# TYPE nullalis_gateway_tenant_runtime_pruned_total counter
        \\nullalis_gateway_tenant_runtime_pruned_total{{reason="idle"}} {d}
        \\nullalis_gateway_tenant_runtime_pruned_total{{reason="capacity"}} {d}
        \\
    ,
        .{
            tenant_lock_conflicts_total,
            tenant_lock_conflicts_chat_stream_sse_total,
            tenant_lock_conflicts_chat_stream_http_total,
            tenant_lock_conflicts_webhook_total,
            tenant_lock_conflicts_daemon_total,
            tenant_lock_conflicts_api_total,
            tenant_lock_conflict_retries_total,
            in_flight_requests,
            drain_rejected_total,
            overload_rejected_total,
            if (draining) @as(u8, 1) else @as(u8, 0),
            if (shutdown_requested) @as(u8, 1) else @as(u8, 0),
            lifecycle_lock_wait_total,
            lifecycle_compaction_total,
            lifecycle_continuity_refresh_total,
            lifecycle_pruning_total,
            lifecycle_lock_wait_duration_ms_total,
            lifecycle_compaction_duration_ms_total,
            lifecycle_continuity_refresh_duration_ms_total,
            lifecycle_pruning_duration_ms_total,
            tenant_runtime_pruned_idle_total,
            tenant_runtime_pruned_capacity_total,
        },
    );
    try w.print(
        \\# HELP nullalis_http_transport_native_total Native transport successes by subsystem.
        \\# TYPE nullalis_http_transport_native_total counter
        \\nullalis_http_transport_native_total{{subsystem="tools"}} {d}
        \\nullalis_http_transport_native_total{{subsystem="providers"}} {d}
        \\nullalis_http_transport_native_total{{subsystem="channels"}} {d}
        \\nullalis_http_transport_native_total{{subsystem="system"}} {d}
        \\# HELP nullalis_http_transport_curl_total Curl transport uses by subsystem.
        \\# TYPE nullalis_http_transport_curl_total counter
        \\nullalis_http_transport_curl_total{{subsystem="tools"}} {d}
        \\nullalis_http_transport_curl_total{{subsystem="providers"}} {d}
        \\nullalis_http_transport_curl_total{{subsystem="channels"}} {d}
        \\nullalis_http_transport_curl_total{{subsystem="system"}} {d}
        \\# HELP nullalis_http_transport_fallback_total Native transport fallbacks by subsystem.
        \\# TYPE nullalis_http_transport_fallback_total counter
        \\nullalis_http_transport_fallback_total{{subsystem="tools"}} {d}
        \\nullalis_http_transport_fallback_total{{subsystem="providers"}} {d}
        \\nullalis_http_transport_fallback_total{{subsystem="channels"}} {d}
        \\nullalis_http_transport_fallback_total{{subsystem="system"}} {d}
        \\# HELP nullalis_http_pool_hits_total Connection pool hits (reused connection).
        \\# TYPE nullalis_http_pool_hits_total counter
        \\nullalis_http_pool_hits_total {d}
        \\# HELP nullalis_http_pool_misses_total Connection pool misses (new connection opened).
        \\# TYPE nullalis_http_pool_misses_total counter
        \\nullalis_http_pool_misses_total {d}
        \\# HELP nullalis_http_pool_idle_connections Current idle connections in pool.
        \\# TYPE nullalis_http_pool_idle_connections gauge
        \\nullalis_http_pool_idle_connections {d}
        \\
    ,
        .{
            transport_stats.tools_native_total,
            transport_stats.providers_native_total,
            transport_stats.channels_native_total,
            transport_stats.system_native_total,
            transport_stats.tools_curl_total,
            transport_stats.providers_curl_total,
            transport_stats.channels_curl_total,
            transport_stats.system_curl_total,
            transport_stats.tools_fallback_total,
            transport_stats.providers_fallback_total,
            transport_stats.channels_fallback_total,
            transport_stats.system_fallback_total,
            pool_hits,
            pool_misses,
            pool_idle,
        },
    );
    return buf.toOwnedSlice(allocator);
}

fn appendHeartbeatRuntimeSummaryJson(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    user_id_opt: ?[]const u8,
    heartbeat_enabled_opt: ?bool,
) !void {
    var summary = loadHeartbeatRuntimeSummary(allocator, state, user_id_opt);
    defer summary.deinit(allocator);
    const last_status: ?[]const u8 = if (heartbeat_enabled_opt != null and !heartbeat_enabled_opt.?)
        "disabled"
    else
        summary.last_status;
    const last_reason: ?[]const u8 = if (heartbeat_enabled_opt != null and !heartbeat_enabled_opt.?)
        "user_disabled"
    else
        summary.last_reason;

    try json_util.appendJsonKey(buf, allocator, "heartbeat_runtime");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonKey(buf, allocator, "user_id");
    if (user_id_opt) |user_id| {
        try json_util.appendJsonString(buf, allocator, user_id);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "available");

    if (!state.tenant_enabled or user_id_opt == null) {
        try buf.appendSlice(allocator, "false,");
        try json_util.appendJsonKey(buf, allocator, "last_run_s");
        try buf.appendSlice(allocator, "null,");
        try json_util.appendJsonKey(buf, allocator, "last_status");
        try buf.appendSlice(allocator, "null,");
        try json_util.appendJsonKey(buf, allocator, "last_reason");
        try buf.appendSlice(allocator, "null}");
        return;
    }

    try buf.appendSlice(allocator, if (summary.available or heartbeat_enabled_opt != null) "true," else "false,");
    try json_util.appendJsonKey(buf, allocator, "last_run_s");
    if (summary.last_run_s) |value| {
        var int_buf: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&int_buf, "{d}", .{value}) catch "0";
        try buf.appendSlice(allocator, text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "last_status");
    if (last_status) |value| {
        try json_util.appendJsonString(buf, allocator, value);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "last_reason");
    if (last_reason) |value| {
        try json_util.appendJsonString(buf, allocator, value);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, "}");
}

fn appendIntegrationsSummaryJson(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    user_id_opt: ?[]const u8,
) !void {
    try json_util.appendJsonKey(buf, allocator, "integrations");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonKey(buf, allocator, "telegram");
    try buf.appendSlice(allocator, "{");

    const configured_from_runtime = state.telegram_bot_token.len > 0;
    var configured = configured_from_runtime;
    var connected: ?bool = null;
    var account_id: ?[]u8 = null;
    defer if (account_id) |value| allocator.free(value);
    var chat_id: ?i64 = null;
    var data_source: []const u8 = if (user_id_opt != null) "context_missing" else "global";
    var connected_normalized: ?bool = null;
    var state_valid: ?bool = null;
    var allow_from_count: ?usize = null;
    var status_label: ?[]const u8 = null;

    if (user_id_opt != null) {
        var user_ctx = resolveUserContext(allocator, state, user_id_opt.?) catch return error.OutOfMemory;
        defer user_ctx.deinit(allocator);
        var readiness = try loadNormalizedTelegramReadiness(allocator, state, user_id_opt.?, &user_ctx);
        defer readiness.deinit(allocator);
        configured = readiness.configured;
        connected = readiness.connected_stored;
        connected_normalized = readiness.connected_normalized;
        state_valid = readiness.state_valid;
        status_label = readiness.statusLabel();
        allow_from_count = readiness.allow_from_count;
        data_source = readiness.data_source;
        if (readiness.account_id) |value| {
            account_id = try allocator.dupe(u8, value);
        }
        chat_id = readiness.chat_id;
    }

    try json_util.appendJsonKey(buf, allocator, "configured");
    try buf.appendSlice(allocator, if (configured) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "connected");
    if (connected) |value| {
        try buf.appendSlice(allocator, if (value) "true" else "false");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "connected_normalized");
    try appendJsonBoolValue(buf, allocator, connected_normalized);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "state_valid");
    try appendJsonBoolValue(buf, allocator, state_valid);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "account_id");
    if (account_id) |value| {
        try json_util.appendJsonString(buf, allocator, value);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "chat_id");
    if (chat_id) |value| {
        var int_buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&int_buf, "{d}", .{value}) catch "0";
        try buf.appendSlice(allocator, text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "allow_from_count");
    try appendJsonUsizeValue(buf, allocator, allow_from_count);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(buf, allocator, "status");
    try appendJsonStringValue(buf, allocator, status_label);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(buf, allocator, "data_source", data_source);
    try buf.appendSlice(allocator, "}");
    try buf.appendSlice(allocator, "}");
}

const DiagnosticsConfigSnapshot = struct {
    source: []const u8,
    config_hash: u64,
    assistant_mode: []const u8,
    group_activation: []const u8,
    proactive_updates: bool,
    voice_replies: bool,
    session_timeout_minutes: u32,
    operator_chat_ready: bool,
    ignored_override_count: usize,
    agent_parallel_tools: bool,
    agent_parallel_tools_rollout_percent: u8,
    agent_tool_dispatcher: []const u8,
    memory_search_enabled: bool,
    memory_search_sync_mode_requested: []const u8,
    memory_summarizer_enabled: bool,
    memory_summarizer_window_size_tokens: u32,
    memory_summarizer_summary_max_tokens: u32,
    memory_summarizer_auto_extract_semantic: bool,
    memory_reliability_rollout_mode: []const u8,
    memory_reliability_shadow_hybrid_percent: u32,
    memory_reliability_canary_hybrid_percent: u32,
    memory_reliability_fallback_policy: []const u8,
    agent_message_timeout_secs: u64,
    provider_retries: u32,
    fallback_provider_count: usize,
    memory_vector_sync_mode_requested: []const u8,
    memory_outbox_requested: bool,
    tenant_identity_mapping_enforcement: []const u8,
    tenant_identity_mapping_strict_channels: []const []const u8,
    gateway_require_explicit_chat_stream_session_key: bool,
    session_cross_channel_shared_main: bool,
};

fn loadDiagnosticsConfigSnapshot(
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    user_id_raw: []const u8,
) ?DiagnosticsConfigSnapshot {
    var user_ctx = resolveUserContext(allocator, state, user_id_raw) catch return null;
    defer user_ctx.deinit(allocator);

    var source: []const u8 = "user_file_config";
    const raw_user_config = blk: {
        if (state.zaki_state) |mgr| {
            const numeric_user_id = parseNumericUserId(user_id_raw) catch return null;
            if (mgr.getConfigJson(allocator, numeric_user_id)) |value| {
                source = "postgres_user_config";
                break :blk value;
            } else |_| {}
        }
        break :blk readFileOrDefault(allocator, user_ctx.config_path, "{}\n") catch return null;
    };
    defer allocator.free(raw_user_config);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = Config{
        .workspace_dir = user_ctx.workspace_path,
        .config_path = state.configPath(),
        .allocator = a,
    };
    var settings = user_settings.defaults();
    var ignored_override_count: usize = 0;

    const base_config_path = state.configPath();
    if (base_config_path.len > 0) {
        if (readFileOrDefault(a, base_config_path, "{}\n")) |base_json| {
            cfg.parseJson(base_json) catch {};
        } else |_| {}
    }

    const normalized = user_settings.normalizeTenantConfigJson(allocator, raw_user_config) catch null;
    defer if (normalized) |snapshot| allocator.free(snapshot.json);
    if (normalized) |snapshot| {
        settings = snapshot.settings;
        ignored_override_count = snapshot.ignored_override_count;
        cfg.parseJson(snapshot.json) catch {};
    }
    cfg.applyProfileDefaults() catch {};
    cfg.memory.applyProfileDefaults();
    user_settings.applySettingsToConfig(&cfg, settings);

    const requested_sync_mode: []const u8 = if (std.mem.eql(u8, cfg.memory.search.sync.mode, "best_effort"))
        "best_effort"
    else if (std.mem.eql(u8, cfg.memory.search.sync.mode, "durable_outbox"))
        "durable_outbox"
    else
        "custom";

    return .{
        .source = source,
        .config_hash = if (normalized) |snapshot| TenantRuntime.configHash(snapshot.json) else TenantRuntime.configHash(raw_user_config),
        .assistant_mode = settings.assistant_mode.toSlice(),
        .group_activation = settings.group_activation.toSlice(),
        .proactive_updates = settings.proactive_updates,
        .voice_replies = settings.voice_replies,
        .session_timeout_minutes = settings.session_timeout_minutes,
        .operator_chat_ready = !(cfg.default_provider.len == 0 or (cfg.default_model orelse "").len == 0),
        .ignored_override_count = ignored_override_count,
        .agent_parallel_tools = cfg.agent.parallel_tools,
        .agent_parallel_tools_rollout_percent = cfg.agent.parallel_tools_rollout_percent,
        .agent_tool_dispatcher = cfg.agent.tool_dispatcher,
        .memory_search_enabled = cfg.memory.search.enabled,
        .memory_search_sync_mode_requested = cfg.memory.search.sync.mode,
        .memory_summarizer_enabled = cfg.memory.summarizer.enabled,
        .memory_summarizer_window_size_tokens = cfg.memory.summarizer.window_size_tokens,
        .memory_summarizer_summary_max_tokens = cfg.memory.summarizer.summary_max_tokens,
        .memory_summarizer_auto_extract_semantic = cfg.memory.summarizer.auto_extract_semantic,
        .memory_reliability_rollout_mode = cfg.memory.reliability.rollout_mode,
        .memory_reliability_shadow_hybrid_percent = cfg.memory.reliability.shadow_hybrid_percent,
        .memory_reliability_canary_hybrid_percent = cfg.memory.reliability.canary_hybrid_percent,
        .memory_reliability_fallback_policy = cfg.memory.reliability.fallback_policy,
        .agent_message_timeout_secs = cfg.agent.message_timeout_secs,
        .provider_retries = cfg.reliability.provider_retries,
        .fallback_provider_count = cfg.reliability.fallback_providers.len,
        .memory_vector_sync_mode_requested = requested_sync_mode,
        .memory_outbox_requested = !std.mem.eql(u8, cfg.memory.search.sync.mode, "best_effort"),
        .tenant_identity_mapping_enforcement = cfg.tenant.identity_mapping_enforcement,
        .tenant_identity_mapping_strict_channels = cfg.tenant.identity_mapping_strict_channels,
        .gateway_require_explicit_chat_stream_session_key = cfg.gateway.require_explicit_chat_stream_session_key,
        .session_cross_channel_shared_main = cfg.session.cross_channel_shared_main,
    };
}

fn appendJsonBoolValue(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: ?bool,
) !void {
    if (value) |resolved| {
        try buf.appendSlice(allocator, if (resolved) "true" else "false");
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn appendJsonU32Value(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: ?u32,
) !void {
    if (value) |resolved| {
        var number_buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&number_buf, "{d}", .{resolved}) catch "0";
        try buf.appendSlice(allocator, text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn appendJsonU8Value(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: ?u8,
) !void {
    if (value) |resolved| {
        var number_buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&number_buf, "{d}", .{resolved}) catch "0";
        try buf.appendSlice(allocator, text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn appendJsonUsizeValue(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: ?usize,
) !void {
    if (value) |resolved| {
        var number_buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&number_buf, "{d}", .{resolved}) catch "0";
        try buf.appendSlice(allocator, text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn appendJsonStringValue(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) !void {
    if (value) |resolved| {
        try json_util.appendJsonString(buf, allocator, resolved);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn appendJsonStringArrayValue(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    values_opt: ?[]const []const u8,
) !void {
    if (values_opt) |values| {
        try buf.appendSlice(allocator, "[");
        for (values, 0..) |value, index| {
            if (index > 0) try buf.appendSlice(allocator, ",");
            try json_util.appendJsonString(buf, allocator, value);
        }
        try buf.appendSlice(allocator, "]");
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn appendControlPlaneStringEntry(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    configured: ?[]const u8,
    effective: ?[]const u8,
    source: ?[]const u8,
) !void {
    return appendControlPlaneStringEntryWithDrift(buf, allocator, key, configured, effective, source, null);
}

fn appendControlPlaneStringEntryWithDrift(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    configured: ?[]const u8,
    effective: ?[]const u8,
    source: ?[]const u8,
    drift_override: ?bool,
) !void {
    try json_util.appendJsonKey(buf, allocator, key);
    try buf.appendSlice(allocator, "{\"configured\":");
    try appendJsonStringValue(buf, allocator, configured);
    try buf.appendSlice(allocator, ",\"effective\":");
    try appendJsonStringValue(buf, allocator, effective);
    try buf.appendSlice(allocator, ",\"owner\":\"operator\",\"source\":");
    try appendJsonStringValue(buf, allocator, source);
    try buf.appendSlice(allocator, ",\"drift\":");
    if (drift_override) |override| {
        try buf.appendSlice(allocator, if (override) "true" else "false");
    } else if (configured != null and effective != null) {
        try buf.appendSlice(allocator, if (std.mem.eql(u8, configured.?, effective.?)) "false" else "true");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, "}");
}

fn appendControlPlaneBoolEntry(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    configured: ?bool,
    effective: ?bool,
    source: ?[]const u8,
) !void {
    try json_util.appendJsonKey(buf, allocator, key);
    try buf.appendSlice(allocator, "{\"configured\":");
    try appendJsonBoolValue(buf, allocator, configured);
    try buf.appendSlice(allocator, ",\"effective\":");
    try appendJsonBoolValue(buf, allocator, effective);
    try buf.appendSlice(allocator, ",\"owner\":\"operator\",\"source\":");
    try appendJsonStringValue(buf, allocator, source);
    try buf.appendSlice(allocator, ",\"drift\":");
    if (configured != null and effective != null) {
        try buf.appendSlice(allocator, if (configured.? == effective.?) "false" else "true");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, "}");
}

fn appendControlPlaneU32Entry(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    configured: ?u32,
    effective: ?u32,
    source: ?[]const u8,
) !void {
    try json_util.appendJsonKey(buf, allocator, key);
    try buf.appendSlice(allocator, "{\"configured\":");
    try appendJsonU32Value(buf, allocator, configured);
    try buf.appendSlice(allocator, ",\"effective\":");
    try appendJsonU32Value(buf, allocator, effective);
    try buf.appendSlice(allocator, ",\"owner\":\"operator\",\"source\":");
    try appendJsonStringValue(buf, allocator, source);
    try buf.appendSlice(allocator, ",\"drift\":");
    if (configured != null and effective != null) {
        try buf.appendSlice(allocator, if (configured.? == effective.?) "false" else "true");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, "}");
}

fn appendControlPlaneU8Entry(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    configured: ?u8,
    effective: ?u8,
    source: ?[]const u8,
) !void {
    try json_util.appendJsonKey(buf, allocator, key);
    try buf.appendSlice(allocator, "{\"configured\":");
    try appendJsonU8Value(buf, allocator, configured);
    try buf.appendSlice(allocator, ",\"effective\":");
    try appendJsonU8Value(buf, allocator, effective);
    try buf.appendSlice(allocator, ",\"owner\":\"operator\",\"source\":");
    try appendJsonStringValue(buf, allocator, source);
    try buf.appendSlice(allocator, ",\"drift\":");
    if (configured != null and effective != null) {
        try buf.appendSlice(allocator, if (configured.? == effective.?) "false" else "true");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, "}");
}

fn appendControlPlaneStringArrayEntry(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    configured: ?[]const []const u8,
    effective: ?[]const []const u8,
    source: ?[]const u8,
) !void {
    try json_util.appendJsonKey(buf, allocator, key);
    try buf.appendSlice(allocator, "{\"configured\":");
    try appendJsonStringArrayValue(buf, allocator, configured);
    try buf.appendSlice(allocator, ",\"effective\":");
    try appendJsonStringArrayValue(buf, allocator, effective);
    try buf.appendSlice(allocator, ",\"owner\":\"operator\",\"source\":");
    try appendJsonStringValue(buf, allocator, source);
    try buf.appendSlice(allocator, ",\"drift\":");
    if (configured != null and effective != null) {
        var drift = configured.?.len != effective.?.len;
        if (!drift) {
            for (configured.?, effective.?) |lhs, rhs| {
                if (!std.mem.eql(u8, lhs, rhs)) {
                    drift = true;
                    break;
                }
            }
        }
        try buf.appendSlice(allocator, if (drift) "true" else "false");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, "}");
}

fn internalDiagnosticsPayload(
    allocator: std.mem.Allocator,
    state: *const GatewayState,
    user_id_opt: ?[]const u8,
) ![]u8 {
    const ops_json = try ops_guard.diagnosticsJson(allocator);
    defer allocator.free(ops_json);

    var last_trigger_ts_s: ?i64 = null;
    var last_trigger_source: ?[]const u8 = null;
    var last_trigger_action: ?[]const u8 = null;
    var last_trigger_reason: ?[]const u8 = null;
    const parsed_ops = std.json.parseFromSlice(std.json.Value, allocator, ops_json, .{}) catch null;
    defer if (parsed_ops) |*p| p.deinit();
    if (parsed_ops) |p| {
        if (p.value == .object) {
            if (p.value.object.get("last_event")) |last| {
                if (last == .object) {
                    if (last.object.get("ts_s")) |v| {
                        if (v == .integer) last_trigger_ts_s = v.integer;
                    }
                    if (last.object.get("source")) |v| {
                        if (v == .string and v.string.len > 0) last_trigger_source = v.string;
                    }
                    if (last.object.get("action")) |v| {
                        if (v == .string and v.string.len > 0) last_trigger_action = v.string;
                    }
                    if (last.object.get("reason")) |v| {
                        if (v == .string and v.string.len > 0) last_trigger_reason = v.string;
                    }
                }
            }
        }
    }

    const bus_inbound_len: usize = if (state.event_bus) |eb| eb.inboundLen() else 0;
    const bus_outbound_len: usize = if (state.event_bus) |eb| eb.outboundLen() else 0;
    const bus_capacity: usize = if (state.event_bus) |eb| eb.queueCapacity() else bus_mod.QUEUE_CAPACITY;
    const tenant_lock_backend: []const u8 = blk: {
        if (!state.tenant_enabled or !state.ownership_lock_enabled or state.owner_instance_id.len == 0) break :blk "disabled";
        if (tenantOwnershipUsesPostgresLease(state)) break :blk "postgres_lease";
        break :blk "file_lock";
    };
    const owned_users_count: usize = blk: {
        if (!state.tenant_enabled or !state.ownership_lock_enabled or state.owner_instance_id.len == 0) break :blk 0;
        if (tenantOwnershipUsesPostgresLease(state)) {
            const now_s = std.time.timestamp();
            if (state.zaki_state) |mgr| {
                break :blk mgr.countOwnedUserLeases(now_s, state.owner_instance_id) catch 0;
            }
            break :blk 0;
        }
        break :blk tenant_lock.countOwnedUserLocks(
            allocator,
            state.tenant_data_root,
            state.owner_instance_id,
        ) catch 0;
    };
    const tenant_lock_conflicts_chat_stream_sse_total = state.tenant_lock_conflicts_chat_stream_sse_total.load(.monotonic);
    const tenant_lock_conflicts_chat_stream_http_total = state.tenant_lock_conflicts_chat_stream_http_total.load(.monotonic);
    const tenant_lock_conflicts_webhook_total = state.tenant_lock_conflicts_webhook_total.load(.monotonic);
    const tenant_lock_conflicts_daemon_total = state.tenant_lock_conflicts_daemon_total.load(.monotonic);
    const tenant_lock_conflicts_api_total = state.tenant_lock_conflicts_api_total.load(.monotonic);
    const tenant_lock_conflict_retries_total = state.tenant_lock_conflict_retries_total.load(.monotonic);
    const tenant_runtime_policy_attached = state.tenant_runtime_policy_attached.load(.monotonic);
    const sandbox_diag = tool_sandbox_v1.diagnosticsSnapshot();
    var lane_snapshot = try lane_metrics.snapshotBackgroundMainReroutes(allocator);
    defer lane_snapshot.deinit(allocator);

    var lease_probe_snapshot: ?zaki_state_mod.UserOwnershipLeaseSnapshot = null;
    defer if (lease_probe_snapshot) |*value| value.deinit(allocator);
    var lease_probe_data_source: ?[]const u8 = null;
    var effective_config_source: []const u8 = if (user_id_opt == null) "no_user_context" else "runtime_not_loaded";
    var effective_config_hash: ?u64 = null;
    var memory_search_enabled: ?bool = null;
    var memory_summarizer_enabled: ?bool = null;
    var agent_message_timeout_secs: ?u64 = null;
    var provider_retries: ?u32 = null;
    var fallback_provider_count: ?usize = null;
    var memory_vector_sync_mode: ?[]const u8 = null;
    var memory_outbox_enabled: ?bool = null;
    var configured_config_source: ?[]const u8 = null;
    var configured_config_hash: ?u64 = null;
    var configured_assistant_mode: ?[]const u8 = null;
    var configured_group_activation: ?[]const u8 = null;
    var configured_proactive_updates: ?bool = null;
    var configured_voice_replies: ?bool = null;
    var configured_session_timeout_minutes: ?u32 = null;
    var operator_chat_ready: ?bool = null;
    var configured_ignored_tenant_override_count: ?usize = null;
    var configured_agent_parallel_tools: ?bool = null;
    var configured_agent_parallel_tools_rollout_percent: ?u8 = null;
    var configured_agent_tool_dispatcher: ?[]const u8 = null;
    var configured_memory_search_enabled: ?bool = null;
    var configured_memory_search_sync_mode_requested: ?[]const u8 = null;
    var configured_memory_summarizer_enabled: ?bool = null;
    var configured_memory_summarizer_window_size_tokens: ?u32 = null;
    var configured_memory_summarizer_summary_max_tokens: ?u32 = null;
    var configured_memory_summarizer_auto_extract_semantic: ?bool = null;
    var configured_memory_reliability_rollout_mode: ?[]const u8 = null;
    var configured_memory_reliability_shadow_hybrid_percent: ?u32 = null;
    var configured_memory_reliability_canary_hybrid_percent: ?u32 = null;
    var configured_memory_reliability_fallback_policy: ?[]const u8 = null;
    var configured_agent_message_timeout_secs: ?u64 = null;
    var configured_provider_retries: ?u32 = null;
    var configured_fallback_provider_count: ?usize = null;
    var configured_memory_vector_sync_mode_requested: ?[]const u8 = null;
    var configured_memory_outbox_requested: ?bool = null;
    var configured_tenant_identity_mapping_enforcement: ?[]const u8 = null;
    var configured_tenant_identity_mapping_strict_channels: ?[]const []const u8 = null;
    var configured_gateway_require_explicit_chat_stream_session_key: ?bool = null;
    var configured_session_cross_channel_shared_main: ?bool = null;
    var effective_assistant_mode: ?[]const u8 = null;
    var effective_group_activation: ?[]const u8 = null;
    var effective_proactive_updates: ?bool = null;
    var effective_voice_replies: ?bool = null;
    var effective_session_timeout_minutes: ?u32 = null;
    var effective_ignored_tenant_override_count: ?usize = null;
    var effective_agent_parallel_tools: ?bool = null;
    var effective_agent_parallel_tools_rollout_percent: ?u8 = null;
    var effective_agent_tool_dispatcher: ?[]const u8 = null;
    var effective_memory_search_sync_mode: ?[]const u8 = null;
    var effective_memory_summarizer_window_size_tokens: ?u32 = null;
    var effective_memory_summarizer_summary_max_tokens: ?u32 = null;
    var effective_memory_summarizer_auto_extract_semantic: ?bool = null;
    var effective_memory_reliability_rollout_mode: ?[]const u8 = null;
    var effective_memory_reliability_shadow_hybrid_percent: ?u32 = null;
    var effective_memory_reliability_canary_hybrid_percent: ?u32 = null;
    var effective_memory_reliability_fallback_policy: ?[]const u8 = null;
    var effective_tenant_identity_mapping_enforcement: ?[]const u8 = null;
    var effective_tenant_identity_mapping_strict_channels: ?[]const []const u8 = null;
    var effective_gateway_require_explicit_chat_stream_session_key: ?bool = null;
    var effective_session_cross_channel_shared_main: ?bool = null;
    if (user_id_opt) |user_id_raw| {
        if (loadDiagnosticsConfigSnapshot(allocator, state, user_id_raw)) |snapshot| {
            configured_config_source = snapshot.source;
            configured_config_hash = snapshot.config_hash;
            configured_assistant_mode = snapshot.assistant_mode;
            configured_group_activation = snapshot.group_activation;
            configured_proactive_updates = snapshot.proactive_updates;
            configured_voice_replies = snapshot.voice_replies;
            configured_session_timeout_minutes = snapshot.session_timeout_minutes;
            operator_chat_ready = snapshot.operator_chat_ready;
            configured_ignored_tenant_override_count = snapshot.ignored_override_count;
            configured_agent_parallel_tools = snapshot.agent_parallel_tools;
            configured_agent_parallel_tools_rollout_percent = snapshot.agent_parallel_tools_rollout_percent;
            configured_agent_tool_dispatcher = snapshot.agent_tool_dispatcher;
            configured_memory_search_enabled = snapshot.memory_search_enabled;
            configured_memory_search_sync_mode_requested = snapshot.memory_search_sync_mode_requested;
            configured_memory_summarizer_enabled = snapshot.memory_summarizer_enabled;
            configured_memory_summarizer_window_size_tokens = snapshot.memory_summarizer_window_size_tokens;
            configured_memory_summarizer_summary_max_tokens = snapshot.memory_summarizer_summary_max_tokens;
            configured_memory_summarizer_auto_extract_semantic = snapshot.memory_summarizer_auto_extract_semantic;
            configured_memory_reliability_rollout_mode = snapshot.memory_reliability_rollout_mode;
            configured_memory_reliability_shadow_hybrid_percent = snapshot.memory_reliability_shadow_hybrid_percent;
            configured_memory_reliability_canary_hybrid_percent = snapshot.memory_reliability_canary_hybrid_percent;
            configured_memory_reliability_fallback_policy = snapshot.memory_reliability_fallback_policy;
            configured_agent_message_timeout_secs = snapshot.agent_message_timeout_secs;
            configured_provider_retries = snapshot.provider_retries;
            configured_fallback_provider_count = snapshot.fallback_provider_count;
            configured_memory_vector_sync_mode_requested = snapshot.memory_vector_sync_mode_requested;
            configured_memory_outbox_requested = snapshot.memory_outbox_requested;
            configured_tenant_identity_mapping_enforcement = snapshot.tenant_identity_mapping_enforcement;
            configured_tenant_identity_mapping_strict_channels = snapshot.tenant_identity_mapping_strict_channels;
            configured_gateway_require_explicit_chat_stream_session_key = snapshot.gateway_require_explicit_chat_stream_session_key;
            configured_session_cross_channel_shared_main = snapshot.session_cross_channel_shared_main;
        }
        {
            const mutable_state: *GatewayState = @constCast(state);
            mutable_state.tenant_runtime_mutex.lock();
            defer mutable_state.tenant_runtime_mutex.unlock();
            if (mutable_state.tenant_runtimes.get(user_id_raw)) |tenant_runtime| {
                effective_config_source = tenant_runtime.effective_config_source;
                effective_config_hash = tenant_runtime.effective_config_hash;
                effective_assistant_mode = tenant_runtime.resolved_settings.assistant_mode.toSlice();
                effective_group_activation = tenant_runtime.resolved_settings.group_activation.toSlice();
                effective_proactive_updates = tenant_runtime.resolved_settings.proactive_updates;
                effective_voice_replies = tenant_runtime.resolved_settings.voice_replies;
                effective_session_timeout_minutes = tenant_runtime.resolved_settings.session_timeout_minutes;
                effective_ignored_tenant_override_count = tenant_runtime.ignored_tenant_override_count;
                effective_agent_parallel_tools = tenant_runtime.config.agent.parallel_tools;
                effective_agent_parallel_tools_rollout_percent = tenant_runtime.config.agent.parallel_tools_rollout_percent;
                effective_agent_tool_dispatcher = tenant_runtime.config.agent.tool_dispatcher;
                memory_search_enabled = tenant_runtime.config.memory.search.enabled;
                memory_summarizer_enabled = tenant_runtime.config.memory.summarizer.enabled;
                effective_memory_search_sync_mode = tenant_runtime.config.memory.search.sync.mode;
                effective_memory_summarizer_window_size_tokens = tenant_runtime.config.memory.summarizer.window_size_tokens;
                effective_memory_summarizer_summary_max_tokens = tenant_runtime.config.memory.summarizer.summary_max_tokens;
                effective_memory_summarizer_auto_extract_semantic = tenant_runtime.config.memory.summarizer.auto_extract_semantic;
                effective_memory_reliability_rollout_mode = tenant_runtime.config.memory.reliability.rollout_mode;
                effective_memory_reliability_shadow_hybrid_percent = tenant_runtime.config.memory.reliability.shadow_hybrid_percent;
                effective_memory_reliability_canary_hybrid_percent = tenant_runtime.config.memory.reliability.canary_hybrid_percent;
                effective_memory_reliability_fallback_policy = tenant_runtime.config.memory.reliability.fallback_policy;
                agent_message_timeout_secs = tenant_runtime.config.agent.message_timeout_secs;
                provider_retries = tenant_runtime.config.reliability.provider_retries;
                fallback_provider_count = tenant_runtime.config.reliability.fallback_providers.len;
                effective_tenant_identity_mapping_enforcement = tenant_runtime.config.tenant.identity_mapping_enforcement;
                effective_tenant_identity_mapping_strict_channels = tenant_runtime.config.tenant.identity_mapping_strict_channels;
                effective_gateway_require_explicit_chat_stream_session_key = tenant_runtime.config.gateway.require_explicit_chat_stream_session_key;
                effective_session_cross_channel_shared_main = tenant_runtime.config.session.cross_channel_shared_main;
                if (tenant_runtime.mem_rt) |*memory_rt| {
                    memory_vector_sync_mode = memory_rt.resolved.vector_sync_mode;
                    memory_outbox_enabled = memory_rt._outbox != null;
                }
            }
        }

        if (!tenantOwnershipUsesPostgresLease(state) or state.zaki_state == null) {
            lease_probe_data_source = "unavailable";
        } else {
            const numeric_user_id_opt = parseNumericUserId(user_id_raw) catch null;
            if (numeric_user_id_opt) |numeric_user_id| {
                lease_probe_data_source = "postgres_lease";
                lease_probe_snapshot = probe: {
                    const snapshot = state.zaki_state.?.getUserOwnershipLeaseSnapshot(allocator, numeric_user_id) catch {
                        lease_probe_data_source = "probe_error";
                        break :probe null;
                    };
                    break :probe snapshot;
                };
            } else {
                lease_probe_data_source = "invalid_user_id";
            }
        }
    }

    var normalized_telegram: ?NormalizedTelegramReadiness = null;
    defer if (normalized_telegram) |*value| value.deinit(allocator);
    var heartbeat_enabled_normalized: ?bool = null;
    var onboarding_summary: ?OnboardingStateSummary = null;
    var proactive_status: ?[]const u8 = null;
    var onboarding_ready_normalized: ?bool = null;
    var client_ready_status_value: ?[]const u8 = null;
    if (user_id_opt) |user_id_raw| {
        var user_ctx = resolveUserContext(allocator, state, user_id_raw) catch return error.OutOfMemory;
        defer user_ctx.deinit(allocator);
        normalized_telegram = try loadNormalizedTelegramReadiness(allocator, state, user_id_raw, &user_ctx);
        heartbeat_enabled_normalized = loadNormalizedHeartbeatEnabled(allocator, state, user_id_raw, user_ctx.heartbeat_path);
        const onboarding_content = if (state.zaki_state) |mgr| blk: {
            const user_id = parseNumericUserId(user_id_raw) catch break :blk try allocator.dupe(u8, "{\"completed\":false,\"completed_at_s\":null}");
            break :blk mgr.getOnboardingJson(allocator, user_id) catch try allocator.dupe(u8, "{\"completed\":false,\"completed_at_s\":null}");
        } else blk: {
            const onboarding_path = onboardingStatePath(allocator, user_ctx.user_root) catch break :blk try allocator.dupe(u8, "{\"completed\":false,\"completed_at_s\":null}");
            defer allocator.free(onboarding_path);
            break :blk readFileOrDefault(allocator, onboarding_path, "{\"completed\":false,\"completed_at_s\":null}\n") catch try allocator.dupe(u8, "{\"completed\":false,\"completed_at_s\":null}");
        };
        defer allocator.free(onboarding_content);
        onboarding_summary = parseOnboardingStateSummary(onboarding_content);
        var heartbeat_runtime_summary = loadHeartbeatRuntimeSummary(allocator, state, user_id_opt);
        defer heartbeat_runtime_summary.deinit(allocator);
        if (heartbeat_enabled_normalized) |enabled| {
            proactive_status = proactiveStatusLabel(enabled, heartbeat_runtime_summary);
        }
        const operator_ready = operator_chat_ready orelse true;
        onboarding_ready_normalized = (onboarding_summary.?.completed or operator_ready or normalized_telegram.?.connected_normalized);
        client_ready_status_value = clientReadyStatus(operator_ready, normalized_telegram.?);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonKey(&buf, allocator, "gateway");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonInt(&buf, allocator, "requests_total", @intCast(state.requests_total.load(.monotonic)));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "in_flight_requests", @intCast(state.in_flight_requests.load(.monotonic)));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "drain_rejected_total", @intCast(state.drain_rejected_total.load(.monotonic)));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "overload_rejected_total", @intCast(state.overload_rejected_total.load(.monotonic)));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "draining");
    try buf.appendSlice(allocator, if (state.draining.load(.acquire)) "true" else "false");
    try buf.appendSlice(allocator, "},");

    try json_util.appendJsonKeyValue(&buf, allocator, "runtime_mode", "threaded");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "internal_auth_required");
    try buf.appendSlice(allocator, if (state.internal_auth_required) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "internal_token_configured");
    try buf.appendSlice(allocator, if (state.internal_token_configured) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "internal_token_policy_ok");
    try buf.appendSlice(allocator, if (state.internal_token_policy_ok) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "internal_token_policy_reason");
    if (state.internal_token_policy_reason.len > 0) {
        try json_util.appendJsonString(&buf, allocator, state.internal_token_policy_reason);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");

    try json_util.appendJsonKey(&buf, allocator, "instance_id");
    if (state.owner_instance_id.len > 0) {
        try json_util.appendJsonString(&buf, allocator, state.owner_instance_id);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");

    try json_util.appendJsonInt(&buf, allocator, "owned_users_count", @intCast(owned_users_count));
    try buf.appendSlice(allocator, ",");

    try json_util.appendJsonKeyValue(&buf, allocator, "tenant_lock_backend", tenant_lock_backend);
    try buf.appendSlice(allocator, ",");

    const tenant_lock_lease_secs_i64: i64 = @intCast(@min(state.ownership_lock_lease_secs, @as(u64, std.math.maxInt(i64))));
    try json_util.appendJsonInt(&buf, allocator, "tenant_lock_lease_secs", tenant_lock_lease_secs_i64);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "tenant_lock_wait_ms", state.ownership_lock_wait_ms);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "tenant_lock_retry_min_ms", state.ownership_lock_retry_min_ms);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "tenant_lock_retry_max_ms", state.ownership_lock_retry_max_ms);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "tenant_lock_conflict_retries_total", @intCast(tenant_lock_conflict_retries_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "tenant_runtime_policy_attached");
    try buf.appendSlice(allocator, if (tenant_runtime_policy_attached) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "effective_config_source", effective_config_source);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "effective_config_hash");
    if (effective_config_hash) |hash| {
        var hash_buf: [24]u8 = undefined;
        const hash_text = std.fmt.bufPrint(&hash_buf, "{x:0>16}", .{hash}) catch "0000000000000000";
        try json_util.appendJsonString(&buf, allocator, hash_text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "memory_search_enabled");
    if (memory_search_enabled) |enabled| {
        try buf.appendSlice(allocator, if (enabled) "true" else "false");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "memory_summarizer_enabled");
    if (memory_summarizer_enabled) |enabled| {
        try buf.appendSlice(allocator, if (enabled) "true" else "false");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "agent_message_timeout_secs");
    if (agent_message_timeout_secs) |value| {
        var value_buf: [32]u8 = undefined;
        const value_text = std.fmt.bufPrint(&value_buf, "{d}", .{value}) catch "0";
        try buf.appendSlice(allocator, value_text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "provider_retries");
    if (provider_retries) |value| {
        var value_buf: [32]u8 = undefined;
        const value_text = std.fmt.bufPrint(&value_buf, "{d}", .{value}) catch "0";
        try buf.appendSlice(allocator, value_text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "fallback_provider_count");
    if (fallback_provider_count) |value| {
        var value_buf: [32]u8 = undefined;
        const value_text = std.fmt.bufPrint(&value_buf, "{d}", .{value}) catch "0";
        try buf.appendSlice(allocator, value_text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "memory_vector_sync_mode");
    if (memory_vector_sync_mode) |mode| {
        try json_util.appendJsonString(&buf, allocator, mode);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "memory_outbox_enabled");
    if (memory_outbox_enabled) |enabled| {
        try buf.appendSlice(allocator, if (enabled) "true" else "false");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "configured_config_source");
    if (configured_config_source) |value| {
        try json_util.appendJsonString(&buf, allocator, value);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "configured_memory_search_enabled");
    if (configured_memory_search_enabled) |enabled| {
        try buf.appendSlice(allocator, if (enabled) "true" else "false");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "configured_memory_summarizer_enabled");
    if (configured_memory_summarizer_enabled) |enabled| {
        try buf.appendSlice(allocator, if (enabled) "true" else "false");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "configured_agent_message_timeout_secs");
    if (configured_agent_message_timeout_secs) |value| {
        var value_buf: [32]u8 = undefined;
        const value_text = std.fmt.bufPrint(&value_buf, "{d}", .{value}) catch "0";
        try buf.appendSlice(allocator, value_text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "configured_provider_retries");
    if (configured_provider_retries) |value| {
        var value_buf: [32]u8 = undefined;
        const value_text = std.fmt.bufPrint(&value_buf, "{d}", .{value}) catch "0";
        try buf.appendSlice(allocator, value_text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "configured_fallback_provider_count");
    if (configured_fallback_provider_count) |value| {
        var value_buf: [32]u8 = undefined;
        const value_text = std.fmt.bufPrint(&value_buf, "{d}", .{value}) catch "0";
        try buf.appendSlice(allocator, value_text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "configured_memory_vector_sync_mode_requested");
    if (configured_memory_vector_sync_mode_requested) |mode| {
        try json_util.appendJsonString(&buf, allocator, mode);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "configured_memory_outbox_requested");
    if (configured_memory_outbox_requested) |enabled| {
        try buf.appendSlice(allocator, if (enabled) "true" else "false");
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "assistant_mode");
    try appendJsonStringValue(&buf, allocator, if (effective_assistant_mode != null) effective_assistant_mode else configured_assistant_mode);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "group_activation");
    try appendJsonStringValue(&buf, allocator, if (effective_group_activation != null) effective_group_activation else configured_group_activation);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "proactive_updates");
    try appendJsonBoolValue(&buf, allocator, if (effective_proactive_updates != null) effective_proactive_updates else configured_proactive_updates);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "voice_replies");
    try appendJsonBoolValue(&buf, allocator, if (effective_voice_replies != null) effective_voice_replies else configured_voice_replies);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "session_timeout_minutes");
    try appendJsonU32Value(&buf, allocator, if (effective_session_timeout_minutes != null) effective_session_timeout_minutes else configured_session_timeout_minutes);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "telegram_connected_normalized");
    try appendJsonBoolValue(&buf, allocator, if (normalized_telegram) |value| value.connected_normalized else null);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "telegram_state_valid");
    try appendJsonBoolValue(&buf, allocator, if (normalized_telegram) |value| value.state_valid else null);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "heartbeat_enabled_normalized");
    try appendJsonBoolValue(&buf, allocator, heartbeat_enabled_normalized);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "onboarding_ready_normalized");
    try appendJsonBoolValue(&buf, allocator, onboarding_ready_normalized);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "client_ready_status");
    try appendJsonStringValue(&buf, allocator, client_ready_status_value);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "proactive_status");
    try appendJsonStringValue(&buf, allocator, proactive_status);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "control_plane");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonKey(&buf, allocator, "configured_config_source");
    try appendJsonStringValue(&buf, allocator, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "effective_config_source");
    try json_util.appendJsonString(&buf, allocator, effective_config_source);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "configured_config_hash");
    if (configured_config_hash) |hash| {
        var hash_buf: [24]u8 = undefined;
        const hash_text = std.fmt.bufPrint(&hash_buf, "{x:0>16}", .{hash}) catch "0000000000000000";
        try json_util.appendJsonString(&buf, allocator, hash_text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "effective_config_hash");
    if (effective_config_hash) |hash| {
        var hash_buf: [24]u8 = undefined;
        const hash_text = std.fmt.bufPrint(&hash_buf, "{x:0>16}", .{hash}) catch "0000000000000000";
        try json_util.appendJsonString(&buf, allocator, hash_text);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "configured_assistant_mode");
    try appendJsonStringValue(&buf, allocator, configured_assistant_mode);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "effective_assistant_mode");
    try appendJsonStringValue(&buf, allocator, effective_assistant_mode);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "configured_ignored_tenant_override_count");
    try appendJsonUsizeValue(&buf, allocator, configured_ignored_tenant_override_count);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "effective_ignored_tenant_override_count");
    try appendJsonUsizeValue(&buf, allocator, effective_ignored_tenant_override_count);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "controls");
    try buf.appendSlice(allocator, "{");
    try appendControlPlaneBoolEntry(&buf, allocator, "agent.parallel_tools", configured_agent_parallel_tools, effective_agent_parallel_tools, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneU8Entry(&buf, allocator, "agent.parallel_tools_rollout_percent", configured_agent_parallel_tools_rollout_percent, effective_agent_parallel_tools_rollout_percent, configured_config_source);
    try buf.appendSlice(allocator, ",");
    const effective_dispatcher_effective = if (effective_agent_tool_dispatcher != null and effective_agent_parallel_tools != null)
        tool_dispatcher.effectiveMode(effective_agent_parallel_tools.?, tool_dispatcher.parseMode(effective_agent_tool_dispatcher.?).mode).toSlice()
    else
        null;
    const dispatcher_drift_override = if (configured_agent_tool_dispatcher) |configured_mode|
        if (std.ascii.eqlIgnoreCase(configured_mode, "auto")) false else null
    else
        null;
    try appendControlPlaneStringEntryWithDrift(&buf, allocator, "agent.tool_dispatcher", configured_agent_tool_dispatcher, effective_dispatcher_effective, configured_config_source, dispatcher_drift_override);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneStringEntry(&buf, allocator, "memory.reliability.rollout_mode", configured_memory_reliability_rollout_mode, effective_memory_reliability_rollout_mode, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneU32Entry(&buf, allocator, "memory.reliability.shadow_hybrid_percent", configured_memory_reliability_shadow_hybrid_percent, effective_memory_reliability_shadow_hybrid_percent, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneU32Entry(&buf, allocator, "memory.reliability.canary_hybrid_percent", configured_memory_reliability_canary_hybrid_percent, effective_memory_reliability_canary_hybrid_percent, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneStringEntry(&buf, allocator, "memory.reliability.fallback_policy", configured_memory_reliability_fallback_policy, effective_memory_reliability_fallback_policy, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneBoolEntry(&buf, allocator, "memory.search.enabled", configured_memory_search_enabled, memory_search_enabled, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneStringEntry(&buf, allocator, "memory.search.sync.mode", configured_memory_search_sync_mode_requested, effective_memory_search_sync_mode orelse memory_vector_sync_mode, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneBoolEntry(&buf, allocator, "memory.summarizer.enabled", configured_memory_summarizer_enabled, memory_summarizer_enabled, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneU32Entry(&buf, allocator, "memory.summarizer.window_size_tokens", configured_memory_summarizer_window_size_tokens, effective_memory_summarizer_window_size_tokens, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneU32Entry(&buf, allocator, "memory.summarizer.summary_max_tokens", configured_memory_summarizer_summary_max_tokens, effective_memory_summarizer_summary_max_tokens, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneBoolEntry(&buf, allocator, "memory.summarizer.auto_extract_semantic", configured_memory_summarizer_auto_extract_semantic, effective_memory_summarizer_auto_extract_semantic, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneStringEntry(&buf, allocator, "tenant.identity_mapping_enforcement", configured_tenant_identity_mapping_enforcement, effective_tenant_identity_mapping_enforcement, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneStringArrayEntry(&buf, allocator, "tenant.identity_mapping_strict_channels", configured_tenant_identity_mapping_strict_channels, effective_tenant_identity_mapping_strict_channels, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneBoolEntry(&buf, allocator, "gateway.require_explicit_chat_stream_session_key", configured_gateway_require_explicit_chat_stream_session_key, effective_gateway_require_explicit_chat_stream_session_key, configured_config_source);
    try buf.appendSlice(allocator, ",");
    try appendControlPlaneBoolEntry(&buf, allocator, "session.cross_channel_shared_main", configured_session_cross_channel_shared_main, effective_session_cross_channel_shared_main, configured_config_source);
    try buf.appendSlice(allocator, "}},");
    try json_util.appendJsonInt(&buf, allocator, "sandbox_workspace_validation_failed_total", @intCast(sandbox_diag.workspace_validation_failed_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "sandbox_fallback_none_total", @intCast(sandbox_diag.workspace_fallback_none_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "sandbox_workspace_validation_last_reason", sandbox_diag.workspace_validation_last_reason);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "chat_stream_require_explicit_session_key");
    try buf.appendSlice(allocator, if (state.require_explicit_chat_stream_session_key) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "chat_stream_lane_counts");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonInt(&buf, allocator, "main", @intCast(state.chat_stream_lane_main_total.load(.monotonic)));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "thread", @intCast(state.chat_stream_lane_thread_total.load(.monotonic)));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "task", @intCast(state.chat_stream_lane_task_total.load(.monotonic)));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "cron", @intCast(state.chat_stream_lane_cron_total.load(.monotonic)));
    try buf.appendSlice(allocator, "},");
    try json_util.appendJsonKey(&buf, allocator, "chat_stream_session_key_rejections");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonInt(&buf, allocator, "missing", @intCast(state.chat_stream_session_key_missing_total.load(.monotonic)));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "invalid", @intCast(state.chat_stream_session_key_invalid_total.load(.monotonic)));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "wrong_user", @intCast(state.chat_stream_session_key_wrong_user_total.load(.monotonic)));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "invalid_lane", @intCast(state.chat_stream_session_key_invalid_lane_total.load(.monotonic)));
    try buf.appendSlice(allocator, "},");
    try json_util.appendJsonInt(&buf, allocator, "background_main_reroutes_total", @intCast(lane_snapshot.total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "background_main_reroutes_last_job_id");
    if (lane_snapshot.last_job_id) |job_id| {
        try json_util.appendJsonString(&buf, allocator, job_id);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",");

    try json_util.appendJsonKey(&buf, allocator, "tenant_lock_conflicts_by_route");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonInt(&buf, allocator, "chat_stream_sse", @intCast(tenant_lock_conflicts_chat_stream_sse_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "chat_stream_http", @intCast(tenant_lock_conflicts_chat_stream_http_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "webhook", @intCast(tenant_lock_conflicts_webhook_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "daemon", @intCast(tenant_lock_conflicts_daemon_total));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "api", @intCast(tenant_lock_conflicts_api_total));
    try buf.appendSlice(allocator, "},");

    try json_util.appendJsonKey(&buf, allocator, "tenant_lease_probe");
    if (user_id_opt) |user_id_raw| {
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonKeyValue(&buf, allocator, "user_id", user_id_raw);
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKeyValue(&buf, allocator, "data_source", lease_probe_data_source orelse "unknown");
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "owner_id");
        if (lease_probe_snapshot) |snapshot| {
            try json_util.appendJsonString(&buf, allocator, snapshot.owner_id);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "lease_until_s");
        if (lease_probe_snapshot) |snapshot| {
            var lease_buf: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&lease_buf, "{d}", .{snapshot.lease_until_s}) catch "0";
            try buf.appendSlice(allocator, text);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "updated_at_s");
        if (lease_probe_snapshot) |snapshot| {
            var updated_buf: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&updated_buf, "{d}", .{snapshot.updated_at_s}) catch "0";
            try buf.appendSlice(allocator, text);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, "},");
    } else {
        try buf.appendSlice(allocator, "null,");
    }

    try json_util.appendJsonKey(&buf, allocator, "bus");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonInt(&buf, allocator, "inbound_len", @intCast(bus_inbound_len));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "outbound_len", @intCast(bus_outbound_len));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "capacity", @intCast(bus_capacity));
    try buf.appendSlice(allocator, "},");

    // Pool stats section
    {
        const pool = http_native.pool_mod.globalPool(.{}, http_native.closePooledConnForGateway);
        try json_util.appendJsonKey(&buf, allocator, "pool");
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonInt(&buf, allocator, "hits", @intCast(pool.hits.load(.monotonic)));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "misses", @intCast(pool.misses.load(.monotonic)));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "idle", @intCast(pool.idleCount()));
        try buf.appendSlice(allocator, "},");
    }

    try json_util.appendJsonKey(&buf, allocator, "startup_self_check");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonKeyValue(&buf, allocator, "config_path", state.configPath());
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "state_backend_configured", state.state_backend_configured);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "state_backend_effective", state.state_backend_effective);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "heartbeat_enabled");
    try buf.appendSlice(allocator, if (state.heartbeat_enabled) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "heartbeat_interval_minutes", state.heartbeat_interval_minutes);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "tenant_enabled");
    try buf.appendSlice(allocator, if (state.tenant_enabled_configured) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKey(&buf, allocator, "degraded");
    try buf.appendSlice(allocator, if (state.state_degraded) "true" else "false");
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "degraded_reason", state.degradedReason());
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "postgres_host", state.postgresHost());
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "postgres_port", state.postgres_port);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "postgres_schema", state.postgresSchema());
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "scheduler_backend", state.scheduler_backend);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "webhook_mode", state.webhook_mode);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "chat_provider_effective", state.chat_provider_effective);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "chat_fallback_chain", state.chatFallbackChain());
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "embedding_provider_effective", state.embedding_provider_effective);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "provider_data_source", state.provider_data_source);
    try buf.appendSlice(allocator, "},");

    try json_util.appendJsonKey(&buf, allocator, "heartbeat_wake");
    try buf.appendSlice(allocator, "{");
    try json_util.appendJsonInt(&buf, allocator, "pending", @intCast(heartbeat_wake.pendingCount()));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "dropped_total", @intCast(heartbeat_wake.droppedCount()));
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonInt(&buf, allocator, "coalesced_total", @intCast(heartbeat_wake.coalescedCount()));
    try buf.appendSlice(allocator, "},");

    try json_util.appendJsonKey(&buf, allocator, "last_trigger");
    if (last_trigger_source == null and last_trigger_action == null and last_trigger_reason == null and last_trigger_ts_s == null) {
        try buf.appendSlice(allocator, "null,");
    } else {
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonKey(&buf, allocator, "ts_s");
        if (last_trigger_ts_s) |value| {
            var int_buf: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&int_buf, "{d}", .{value}) catch "0";
            try buf.appendSlice(allocator, text);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "source");
        if (last_trigger_source) |value| {
            try json_util.appendJsonString(&buf, allocator, value);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "action");
        if (last_trigger_action) |value| {
            try json_util.appendJsonString(&buf, allocator, value);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonKey(&buf, allocator, "reason");
        if (last_trigger_reason) |value| {
            try json_util.appendJsonString(&buf, allocator, value);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, "},");
    }

    try appendHeartbeatRuntimeSummaryJson(&buf, allocator, state, user_id_opt, heartbeat_enabled_normalized);
    try buf.appendSlice(allocator, ",");
    try appendIntegrationsSummaryJson(&buf, allocator, state, user_id_opt);
    try buf.appendSlice(allocator, ",");
    {
        const identity_metrics = inbound_canonicalizer.metricsSnapshot();
        try json_util.appendJsonKey(&buf, allocator, "identity_mapping");
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonInt(&buf, allocator, "mapped", @intCast(identity_metrics.mapped));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "unmapped", @intCast(identity_metrics.unmapped));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "strict_rejected", @intCast(identity_metrics.strict_rejected));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "degraded_compat", @intCast(identity_metrics.degraded_compat));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "cache_hit", @intCast(identity_metrics.cache_hit));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "cache_miss", @intCast(identity_metrics.cache_miss));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "cache_stale", @intCast(identity_metrics.cache_stale));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "db_lookup_count", @intCast(identity_metrics.db_lookup_count));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "db_lookup_ms_total", @intCast(identity_metrics.db_lookup_ms_total));
        try buf.appendSlice(allocator, "},");
    }
    {
        const stt_metrics = voice.telegramSttMetricsSnapshot();
        try json_util.appendJsonKey(&buf, allocator, "stt");
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonInt(&buf, allocator, "transcriber_configured", @intCast(stt_metrics.transcriber_configured));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "transcription_attempted", @intCast(stt_metrics.transcription_attempted));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "transcription_succeeded", @intCast(stt_metrics.transcription_succeeded));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "transcription_failed", @intCast(stt_metrics.transcription_failed));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "transcription_skipped_no_transcriber", @intCast(stt_metrics.transcription_skipped_no_transcriber));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "failure_get_file", @intCast(stt_metrics.failure_get_file));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "failure_download", @intCast(stt_metrics.failure_download));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "failure_transcriber", @intCast(stt_metrics.failure_transcriber));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "failure_empty_transcript", @intCast(stt_metrics.failure_empty_transcript));
        try buf.appendSlice(allocator, "},");
    }
    {
        const image_metrics = multimodal.imageFlowMetricsSnapshot();
        try json_util.appendJsonKey(&buf, allocator, "multimodal");
        try buf.appendSlice(allocator, "{");
        try json_util.appendJsonInt(&buf, allocator, "image_markers_detected", @intCast(image_metrics.image_markers_detected));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "messages_with_image_markers", @intCast(image_metrics.messages_with_image_markers));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "image_parts_prepared", @intCast(image_metrics.image_parts_prepared));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "image_parts_failed", @intCast(image_metrics.image_parts_failed));
        try buf.appendSlice(allocator, ",");
        try json_util.appendJsonInt(&buf, allocator, "image_markers_ignored", @intCast(image_metrics.image_markers_ignored));
        try buf.appendSlice(allocator, "},");
    }

    try json_util.appendJsonKey(&buf, allocator, "ops");
    try buf.appendSlice(allocator, ops_json);
    try buf.appendSlice(allocator, "}");
    return buf.toOwnedSlice(allocator);
}

fn sseErrorEvent(allocator: std.mem.Allocator, code: []const u8, msg: []const u8) ![]u8 {
    const error_frame = try sseErrorFrame(allocator, code, msg);
    defer allocator.free(error_frame);
    const done_frame = try sseDoneFrame(allocator, null, null);
    defer allocator.free(done_frame);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(error_frame);
    try w.writeAll(done_frame);
    return buf.toOwnedSlice(allocator);
}

fn ownershipLockConflictJsonPayload(allocator: std.mem.Allocator, conflict: *const OwnershipLockConflictInfo) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"error\":\"ownership_lock_conflict\",\"message\":\"user is active on another node, retry shortly\",\"retry_after_ms\":");
    try w.print("{d}", .{conflict.retry_after_ms});
    try w.writeAll(",\"owner_instance_id\":");
    if (conflict.owner_instance_id) |owner_id| {
        try w.writeByte('"');
        try jsonEscapeInto(w, owner_id);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"lease_until_s\":");
    if (conflict.lease_until_s) |lease_until_s| {
        try w.print("{d}", .{lease_until_s});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll("}");
    return buf.toOwnedSlice(allocator);
}

fn sseOwnershipLockConflictEvent(allocator: std.mem.Allocator, conflict: *const OwnershipLockConflictInfo) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("event: error\ndata: {\"type\":\"error\",\"code\":\"ownership_lock_conflict\",\"message\":\"user is active on another node, retry shortly\",\"retry_after_ms\":");
    try w.print("{d}", .{conflict.retry_after_ms});
    try w.writeAll(",\"owner_instance_id\":");
    if (conflict.owner_instance_id) |owner_id| {
        try w.writeByte('"');
        try jsonEscapeInto(w, owner_id);
        try w.writeByte('"');
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"lease_until_s\":");
    if (conflict.lease_until_s) |lease_until_s| {
        try w.print("{d}", .{lease_until_s});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll("}\n\n");
    return buf.toOwnedSlice(allocator);
}

fn sendSseOwnershipLockConflictResponse(stream: anytype, allocator: std.mem.Allocator, conflict: *const OwnershipLockConflictInfo) void {
    sendChunkedSseHeaderRetryAfter(stream, "409 Conflict", conflict.retryAfterSecs()) catch return;
    const error_fallback = "event: error\ndata: {\"type\":\"error\",\"code\":\"ownership_lock_conflict\",\"message\":\"user is active on another node, retry shortly\",\"retry_after_ms\":250,\"owner_instance_id\":null,\"lease_until_s\":null}\n\n";
    const error_owned = sseOwnershipLockConflictEvent(allocator, conflict) catch null;
    defer if (error_owned) |frame| allocator.free(frame);
    const error_frame: []const u8 = if (error_owned) |frame| frame else error_fallback;
    sendChunkedSseFrame(stream, error_frame) catch return;

    const done_fallback = "event: done\ndata: {\"type\":\"done\"}\n\n";
    const done_owned = sseDoneFrame(allocator, null, null) catch null;
    defer if (done_owned) |frame| allocator.free(frame);
    const done_frame: []const u8 = if (done_owned) |frame| frame else done_fallback;
    sendChunkedSseFrame(stream, done_frame) catch return;
    finishChunkedSse(stream) catch {};
}

fn ownershipLockConflictJsonRouteResponse(allocator: std.mem.Allocator, conflict: *const OwnershipLockConflictInfo) RouteResponse {
    const body = ownershipLockConflictJsonPayload(allocator, conflict) catch
        "{\"error\":\"ownership_lock_conflict\",\"message\":\"user is active on another node, retry shortly\",\"retry_after_ms\":250,\"owner_instance_id\":null,\"lease_until_s\":null}";
    return .{
        .status = "409 Conflict",
        .body = body,
        .retry_after_secs = conflict.retryAfterSecs(),
    };
}

fn ownershipLockConflictSseRouteResponse(allocator: std.mem.Allocator, conflict: *const OwnershipLockConflictInfo) RouteResponse {
    const fallback = "event: error\ndata: {\"type\":\"error\",\"code\":\"ownership_lock_conflict\",\"message\":\"ownership lock conflict\",\"retry_after_ms\":250,\"owner_instance_id\":null,\"lease_until_s\":null}\n\nevent: done\ndata: {\"type\":\"done\"}\n\n";
    const event_owned = sseOwnershipLockConflictEvent(allocator, conflict) catch null;
    defer if (event_owned) |value| allocator.free(value);
    const done_owned = sseDoneFrame(allocator, null, null) catch null;
    defer if (done_owned) |value| allocator.free(value);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    w.writeAll(if (event_owned) |value| value else "event: error\ndata: {\"type\":\"error\",\"code\":\"ownership_lock_conflict\",\"message\":\"user is active on another node, retry shortly\",\"retry_after_ms\":250,\"owner_instance_id\":null,\"lease_until_s\":null}\n\n") catch return .{
        .status = "409 Conflict",
        .body = fallback,
        .content_type = "text/event-stream; charset=utf-8",
        .retry_after_secs = conflict.retryAfterSecs(),
    };
    w.writeAll(if (done_owned) |value| value else "event: done\ndata: {\"type\":\"done\"}\n\n") catch return .{
        .status = "409 Conflict",
        .body = fallback,
        .content_type = "text/event-stream; charset=utf-8",
        .retry_after_secs = conflict.retryAfterSecs(),
    };
    const owned = buf.toOwnedSlice(allocator) catch fallback;
    return .{
        .status = "409 Conflict",
        .body = owned,
        .content_type = "text/event-stream; charset=utf-8",
        .retry_after_secs = conflict.retryAfterSecs(),
    };
}

const SSE_TOKEN_CHUNK_SIZE: usize = 96;
const SSE_KEEPALIVE_FRAME: []const u8 = "event: progress\ndata: {\"type\":\"progress\",\"phase\":\"thinking\",\"state\":\"update\",\"label\":\"Still working on the reply\"}\n\n";
const SSE_KEEPALIVE_INTERVAL_MS: u64 = if (builtin.is_test) 25 else 10_000;
const SSE_KEEPALIVE_POLL_MS: u64 = if (builtin.is_test) 5 else 250;

fn sseStatusFrame(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("event: status\ndata: {\"type\":\"statusResponse\",\"content\":\"");
    try jsonEscapeInto(w, content);
    try w.writeAll("\"}\n\n");
    return buf.toOwnedSlice(allocator);
}

fn sseProgressFrame(
    allocator: std.mem.Allocator,
    phase: []const u8,
    state: []const u8,
    label: []const u8,
    tool: ?[]const u8,
    iteration: ?u32,
    duration_ms: ?u64,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("event: progress\ndata: {\"type\":\"progress\",\"phase\":\"");
    try jsonEscapeInto(w, phase);
    try w.writeAll("\",\"state\":\"");
    try jsonEscapeInto(w, state);
    try w.writeAll("\",\"label\":\"");
    try jsonEscapeInto(w, label);
    try w.writeAll("\"");
    if (tool) |tool_name| {
        try w.writeAll(",\"tool\":\"");
        try jsonEscapeInto(w, tool_name);
        try w.writeAll("\"");
    }
    if (iteration) |value| {
        try w.print(",\"iteration\":{d}", .{value});
    }
    if (duration_ms) |value| {
        try w.print(",\"duration_ms\":{d}", .{value});
    }
    try w.writeAll("}\n\n");
    return buf.toOwnedSlice(allocator);
}

fn sseReasoningSummaryFrame(
    allocator: std.mem.Allocator,
    summary: []const u8,
    phase: ?[]const u8,
    tool: ?[]const u8,
    iteration: ?u32,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("event: reasoning_summary\ndata: {\"type\":\"reasoning_summary\",\"summary\":\"");
    try jsonEscapeInto(w, summary);
    try w.writeAll("\"");
    if (phase) |phase_name| {
        try w.writeAll(",\"phase\":\"");
        try jsonEscapeInto(w, phase_name);
        try w.writeAll("\"");
    }
    if (tool) |tool_name| {
        try w.writeAll(",\"tool\":\"");
        try jsonEscapeInto(w, tool_name);
        try w.writeAll("\"");
    }
    if (iteration) |value| {
        try w.print(",\"iteration\":{d}", .{value});
    }
    try w.writeAll("}\n\n");
    return buf.toOwnedSlice(allocator);
}

fn SseProgressObserver(comptime StreamType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        stream: *StreamType,
        stream_failed: bool = false,
        last_emit_ms: i64 = 0,
        last_emit_hash: u64 = 0,
        last_reasoning_emit_ms: i64 = 0,
        last_reasoning_hash: u64 = 0,

        const Self = @This();
        const DEDUPE_WINDOW_MS: i64 = 250;
        const REASONING_DEDUPE_WINDOW_MS: i64 = 450;

        const vtable = Observer.VTable{
            .record_event = recordEvent,
            .record_metric = recordMetric,
            .flush = flush,
            .name = name,
        };

        fn init(allocator: std.mem.Allocator, stream: *StreamType) Self {
            return .{
                .allocator = allocator,
                .stream = stream,
            };
        }

        fn observer(self: *Self) Observer {
            return .{
                .ptr = @ptrCast(self),
                .vtable = &vtable,
            };
        }

        fn resolve(ptr: *anyopaque) *Self {
            return @ptrCast(@alignCast(ptr));
        }

        fn shouldSuppressDuplicate(
            self: *Self,
            phase: []const u8,
            state: []const u8,
            label: []const u8,
            tool: ?[]const u8,
            iteration: ?u32,
        ) bool {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(phase);
            hasher.update(state);
            hasher.update(label);
            if (tool) |tool_name| hasher.update(tool_name);
            if (iteration) |value| {
                var iter_buf: [16]u8 = undefined;
                const iter_text = std.fmt.bufPrint(&iter_buf, "{d}", .{value}) catch "";
                hasher.update(iter_text);
            }
            const hash = hasher.final();
            const now_ms = std.time.milliTimestamp();
            if (self.last_emit_hash == hash and now_ms - self.last_emit_ms < DEDUPE_WINDOW_MS) return true;
            self.last_emit_hash = hash;
            self.last_emit_ms = now_ms;
            return false;
        }

        fn emit(
            self: *Self,
            phase: []const u8,
            state: []const u8,
            label: []const u8,
            tool: ?[]const u8,
            iteration: ?u32,
            duration_ms: ?u64,
        ) void {
            if (self.stream_failed) return;
            if (self.shouldSuppressDuplicate(phase, state, label, tool, iteration)) return;
            const frame = sseProgressFrame(self.allocator, phase, state, label, tool, iteration, duration_ms) catch |err| {
                log.warn("chat.stream.progress encode failed phase={s} state={s}: {}", .{ phase, state, err });
                return;
            };
            defer self.allocator.free(frame);
            self.stream.sendFrame(frame) catch |err| {
                log.warn("chat.stream.progress emit failed phase={s} state={s}: {}", .{ phase, state, err });
                self.stream_failed = true;
                return;
            };
        }

        fn shouldSuppressReasoningSummary(
            self: *Self,
            summary: []const u8,
            phase: ?[]const u8,
            tool: ?[]const u8,
            iteration: ?u32,
        ) bool {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(summary);
            if (phase) |phase_name| hasher.update(phase_name);
            if (tool) |tool_name| hasher.update(tool_name);
            if (iteration) |value| {
                var iter_buf: [16]u8 = undefined;
                const iter_text = std.fmt.bufPrint(&iter_buf, "{d}", .{value}) catch "";
                hasher.update(iter_text);
            }
            const hash = hasher.final();
            const now_ms = std.time.milliTimestamp();
            if (self.last_reasoning_hash == hash and now_ms - self.last_reasoning_emit_ms < REASONING_DEDUPE_WINDOW_MS) {
                return true;
            }
            self.last_reasoning_hash = hash;
            self.last_reasoning_emit_ms = now_ms;
            return false;
        }

        fn emitReasoningSummary(
            self: *Self,
            summary: []const u8,
            phase: ?[]const u8,
            tool: ?[]const u8,
            iteration: ?u32,
        ) void {
            if (self.stream_failed) return;
            if (self.shouldSuppressReasoningSummary(summary, phase, tool, iteration)) return;
            const frame = sseReasoningSummaryFrame(self.allocator, summary, phase, tool, iteration) catch |err| {
                log.warn("chat.stream.reasoning_summary encode failed phase={s}: {}", .{ phase orelse "n/a", err });
                return;
            };
            defer self.allocator.free(frame);
            self.stream.sendFrame(frame) catch |err| {
                log.warn("chat.stream.reasoning_summary emit failed phase={s}: {}", .{ phase orelse "n/a", err });
                self.stream_failed = true;
                return;
            };
        }

        fn emitStage(self: *Self, stage: []const u8, iteration: ?u32, duration_ms: ?u64, count: ?u32) void {
            _ = count;
            if (std.mem.eql(u8, stage, "turn_start")) {
                self.emit("thinking", "start", "Gathering context", null, iteration, duration_ms);
                self.emitReasoningSummary("Checking context and memory", "thinking", null, iteration);
                return;
            }
            if (std.mem.eql(u8, stage, "memory_enrich")) {
                self.emit("thinking", "update", "Retrieving memory", null, iteration, duration_ms);
                self.emitReasoningSummary("Checking context and memory", "thinking", null, iteration);
                return;
            }
            if (std.mem.eql(u8, stage, "turn_compaction") or std.mem.eql(u8, stage, "compact_trim")) {
                self.emit("thinking", "update", "Trimming context", null, iteration, duration_ms);
                return;
            }
            if (std.mem.eql(u8, stage, "build_provider_messages")) {
                self.emit("thinking", "update", "Preparing model request", null, iteration, duration_ms);
                self.emitReasoningSummary("Preparing the model request", "thinking", null, iteration);
                return;
            }
            if (std.mem.eql(u8, stage, "response_cache_hit")) {
                self.emit("compose", "update", "Using cached response", null, iteration, duration_ms);
                self.emitReasoningSummary("Reusing a cached answer", "compose", null, iteration);
                return;
            }
            if (std.mem.eql(u8, stage, "parse_provider_response")) {
                self.emit("thinking", "update", "Processing model response", null, iteration, duration_ms);
                return;
            }
            if (std.mem.eql(u8, stage, "dispatch_tools")) {
                self.emit("tool", "update", "Running tools", null, iteration, duration_ms);
                self.emitReasoningSummary("Running tools to verify the answer", "tool", null, iteration);
                return;
            }
            if (std.mem.eql(u8, stage, "tool_reflection")) {
                self.emit("thinking", "update", "Reflecting on tool results", null, iteration, duration_ms);
                self.emitReasoningSummary("Reviewing tool results", "thinking", null, iteration);
                return;
            }
            if (std.mem.eql(u8, stage, "compose_final_reply")) {
                self.emit("compose", "update", "Preparing final reply", null, iteration, duration_ms);
                self.emitReasoningSummary("Preparing the final answer", "compose", null, iteration);
                return;
            }
            if (std.mem.eql(u8, stage, "finalize_no_tools")) {
                self.emit("finalize", "update", "Finalizing reply", null, iteration, duration_ms);
                self.emitReasoningSummary("Finishing the response", "finalize", null, iteration);
                return;
            }
        }

        fn recordEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
            const self = resolve(ptr);
            switch (event.*) {
                .llm_request => {
                    self.emit("thinking", "start", "Thinking", null, null, null);
                    self.emitReasoningSummary("Thinking through the request", "thinking", null, null);
                },
                .llm_response => |e| {
                    if (e.success) {
                        self.emit("compose", "update", "Model response received", null, null, e.duration_ms);
                    } else {
                        self.emit("finalize", "error", "Model request failed", null, null, e.duration_ms);
                    }
                },
                .tool_call_start => |e| {
                    var label_buf: [160]u8 = undefined;
                    const label = std.fmt.bufPrint(&label_buf, "Using {s}", .{e.tool}) catch "Using tool";
                    self.emit("tool", "start", label, e.tool, null, null);
                    var summary_buf: [196]u8 = undefined;
                    const summary = std.fmt.bufPrint(&summary_buf, "Using {s} to verify the answer", .{e.tool}) catch "Using a tool to verify the answer";
                    self.emitReasoningSummary(summary, "tool", e.tool, null);
                },
                .tool_call => |e| {
                    var label_buf: [192]u8 = undefined;
                    const label = if (e.success)
                        (std.fmt.bufPrint(&label_buf, "{s} completed", .{e.tool}) catch "Tool completed")
                    else
                        (std.fmt.bufPrint(&label_buf, "{s} failed", .{e.tool}) catch "Tool failed");
                    self.emit("tool", if (e.success) "done" else "error", label, e.tool, null, e.duration_ms);
                },
                .tool_iterations_exhausted => self.emit("finalize", "error", "Tool iteration limit reached", null, null, null),
                .turn_stage => |e| self.emitStage(e.stage, e.iteration, e.duration_ms, e.count),
                .turn_complete => self.emit("finalize", "done", "Response ready", null, null, null),
                else => {},
            }
        }

        fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
        fn flush(_: *anyopaque) void {}
        fn name(_: *anyopaque) []const u8 {
            return "sse_progress";
        }
    };
}

const BufferedSseProgressObserver = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayListUnmanaged(u8) = .empty,
    stream_failed: bool = false,
    last_emit_ms: i64 = 0,
    last_emit_hash: u64 = 0,
    last_reasoning_emit_ms: i64 = 0,
    last_reasoning_hash: u64 = 0,

    const Self = @This();
    const DEDUPE_WINDOW_MS: i64 = 250;
    const REASONING_DEDUPE_WINDOW_MS: i64 = 450;

    const vtable = Observer.VTable{
        .record_event = recordEvent,
        .record_metric = recordMetric,
        .flush = flush,
        .name = name,
    };

    fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    fn deinit(self: *Self) void {
        self.frames.deinit(self.allocator);
    }

    fn observer(self: *Self) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn resolve(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }

    fn appendFrame(self: *Self, frame: []const u8) !void {
        try self.frames.appendSlice(self.allocator, frame);
    }

    fn shouldSuppressDuplicate(
        self: *Self,
        phase: []const u8,
        state: []const u8,
        label: []const u8,
        tool: ?[]const u8,
        iteration: ?u32,
    ) bool {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(phase);
        hasher.update(state);
        hasher.update(label);
        if (tool) |tool_name| hasher.update(tool_name);
        if (iteration) |value| {
            var iter_buf: [16]u8 = undefined;
            const iter_text = std.fmt.bufPrint(&iter_buf, "{d}", .{value}) catch "";
            hasher.update(iter_text);
        }
        const hash = hasher.final();
        const now_ms = std.time.milliTimestamp();
        if (self.last_emit_hash == hash and now_ms - self.last_emit_ms < DEDUPE_WINDOW_MS) return true;
        self.last_emit_hash = hash;
        self.last_emit_ms = now_ms;
        return false;
    }

    fn emit(
        self: *Self,
        phase: []const u8,
        state: []const u8,
        label: []const u8,
        tool: ?[]const u8,
        iteration: ?u32,
        duration_ms: ?u64,
    ) void {
        if (self.stream_failed) return;
        if (self.shouldSuppressDuplicate(phase, state, label, tool, iteration)) return;
        const frame = sseProgressFrame(self.allocator, phase, state, label, tool, iteration, duration_ms) catch |err| {
            log.warn("chat.stream.progress encode failed phase={s} state={s}: {}", .{ phase, state, err });
            return;
        };
        defer self.allocator.free(frame);
        self.appendFrame(frame) catch |err| {
            log.warn("chat.stream.progress buffer append failed phase={s} state={s}: {}", .{ phase, state, err });
            self.stream_failed = true;
            return;
        };
    }

    fn shouldSuppressReasoningSummary(
        self: *Self,
        summary: []const u8,
        phase: ?[]const u8,
        tool: ?[]const u8,
        iteration: ?u32,
    ) bool {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(summary);
        if (phase) |phase_name| hasher.update(phase_name);
        if (tool) |tool_name| hasher.update(tool_name);
        if (iteration) |value| {
            var iter_buf: [16]u8 = undefined;
            const iter_text = std.fmt.bufPrint(&iter_buf, "{d}", .{value}) catch "";
            hasher.update(iter_text);
        }
        const hash = hasher.final();
        const now_ms = std.time.milliTimestamp();
        if (self.last_reasoning_hash == hash and now_ms - self.last_reasoning_emit_ms < REASONING_DEDUPE_WINDOW_MS) {
            return true;
        }
        self.last_reasoning_hash = hash;
        self.last_reasoning_emit_ms = now_ms;
        return false;
    }

    fn emitReasoningSummary(
        self: *Self,
        summary: []const u8,
        phase: ?[]const u8,
        tool: ?[]const u8,
        iteration: ?u32,
    ) void {
        if (self.stream_failed) return;
        if (self.shouldSuppressReasoningSummary(summary, phase, tool, iteration)) return;
        const frame = sseReasoningSummaryFrame(self.allocator, summary, phase, tool, iteration) catch |err| {
            log.warn("chat.stream.reasoning_summary encode failed phase={s}: {}", .{ phase orelse "n/a", err });
            return;
        };
        defer self.allocator.free(frame);
        self.appendFrame(frame) catch |err| {
            log.warn("chat.stream.reasoning_summary buffer append failed phase={s}: {}", .{ phase orelse "n/a", err });
            self.stream_failed = true;
            return;
        };
    }

    fn emitStage(self: *Self, stage: []const u8, iteration: ?u32, duration_ms: ?u64, count: ?u32) void {
        _ = count;
        if (std.mem.eql(u8, stage, "turn_start")) {
            self.emit("thinking", "start", "Gathering context", null, iteration, duration_ms);
            self.emitReasoningSummary("Checking context and memory", "thinking", null, iteration);
            return;
        }
        if (std.mem.eql(u8, stage, "memory_enrich")) {
            self.emit("thinking", "update", "Retrieving memory", null, iteration, duration_ms);
            self.emitReasoningSummary("Checking context and memory", "thinking", null, iteration);
            return;
        }
        if (std.mem.eql(u8, stage, "turn_compaction") or std.mem.eql(u8, stage, "compact_trim")) {
            self.emit("thinking", "update", "Trimming context", null, iteration, duration_ms);
            return;
        }
        if (std.mem.eql(u8, stage, "build_provider_messages")) {
            self.emit("thinking", "update", "Preparing model request", null, iteration, duration_ms);
            self.emitReasoningSummary("Preparing the model request", "thinking", null, iteration);
            return;
        }
        if (std.mem.eql(u8, stage, "response_cache_hit")) {
            self.emit("compose", "update", "Using cached response", null, iteration, duration_ms);
            self.emitReasoningSummary("Reusing a cached answer", "compose", null, iteration);
            return;
        }
        if (std.mem.eql(u8, stage, "parse_provider_response")) {
            self.emit("thinking", "update", "Processing model response", null, iteration, duration_ms);
            return;
        }
        if (std.mem.eql(u8, stage, "dispatch_tools")) {
            self.emit("tool", "update", "Running tools", null, iteration, duration_ms);
            self.emitReasoningSummary("Running tools to verify the answer", "tool", null, iteration);
            return;
        }
        if (std.mem.eql(u8, stage, "tool_reflection")) {
            self.emit("thinking", "update", "Reflecting on tool results", null, iteration, duration_ms);
            self.emitReasoningSummary("Reviewing tool results", "thinking", null, iteration);
            return;
        }
        if (std.mem.eql(u8, stage, "compose_final_reply")) {
            self.emit("compose", "update", "Preparing final reply", null, iteration, duration_ms);
            self.emitReasoningSummary("Preparing the final answer", "compose", null, iteration);
            return;
        }
        if (std.mem.eql(u8, stage, "finalize_no_tools")) {
            self.emit("finalize", "update", "Finalizing reply", null, iteration, duration_ms);
            self.emitReasoningSummary("Finishing the response", "finalize", null, iteration);
            return;
        }
    }

    fn recordEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
        const self = resolve(ptr);
        switch (event.*) {
            .llm_request => {
                self.emit("thinking", "start", "Thinking", null, null, null);
                self.emitReasoningSummary("Thinking through the request", "thinking", null, null);
            },
            .llm_response => |e| {
                if (e.success) {
                    self.emit("compose", "update", "Model response received", null, null, e.duration_ms);
                } else {
                    self.emit("finalize", "error", "Model request failed", null, null, e.duration_ms);
                }
            },
            .tool_call_start => |e| {
                var label_buf: [160]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "Using {s}", .{e.tool}) catch "Using tool";
                self.emit("tool", "start", label, e.tool, null, null);
                var summary_buf: [196]u8 = undefined;
                const summary = std.fmt.bufPrint(&summary_buf, "Using {s} to verify the answer", .{e.tool}) catch "Using a tool to verify the answer";
                self.emitReasoningSummary(summary, "tool", e.tool, null);
            },
            .tool_call => |e| {
                var label_buf: [192]u8 = undefined;
                const label = if (e.success)
                    (std.fmt.bufPrint(&label_buf, "{s} completed", .{e.tool}) catch "Tool completed")
                else
                    (std.fmt.bufPrint(&label_buf, "{s} failed", .{e.tool}) catch "Tool failed");
                self.emit("tool", if (e.success) "done" else "error", label, e.tool, null, e.duration_ms);
            },
            .tool_iterations_exhausted => self.emit("finalize", "error", "Tool iteration limit reached", null, null, null),
            .turn_stage => |e| self.emitStage(e.stage, e.iteration, e.duration_ms, e.count),
            .turn_complete => self.emit("finalize", "done", "Response ready", null, null, null),
            else => {},
        }
    }

    fn recordMetric(_: *anyopaque, _: *const observability.ObserverMetric) void {}
    fn flush(_: *anyopaque) void {}
    fn name(_: *anyopaque) []const u8 {
        return "sse_progress_buffer";
    }
};

fn sseReplyStartFrame(
    allocator: std.mem.Allocator,
    stream_kind: []const u8,
    delivery_mode: []const u8,
    live: bool,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("event: reply_start\ndata: {\"type\":\"reply_start\",\"stream_kind\":\"");
    try jsonEscapeInto(w, stream_kind);
    try w.writeAll("\",\"delivery_mode\":\"");
    try jsonEscapeInto(w, delivery_mode);
    try w.writeAll("\",\"live\":");
    try w.writeAll(if (live) "true" else "false");
    try w.writeAll("}\n\n");
    return buf.toOwnedSlice(allocator);
}

fn sseReadyFrame(allocator: std.mem.Allocator, session_key: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("event: ready\ndata: {\"type\":\"ready\",\"session_key\":\"");
    try jsonEscapeInto(w, session_key);
    try w.writeAll("\"}\n\n");
    return buf.toOwnedSlice(allocator);
}

fn sseErrorFrame(allocator: std.mem.Allocator, code: []const u8, msg: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("event: error\ndata: {\"type\":\"error\",\"code\":\"");
    try jsonEscapeInto(w, code);
    try w.writeAll("\",\"message\":\"");
    try jsonEscapeInto(w, msg);
    try w.writeAll("\"}\n\n");
    return buf.toOwnedSlice(allocator);
}

fn sseSubagentCompletionFrame(
    allocator: std.mem.Allocator,
    event_id: []const u8,
    session_key: []const u8,
    content: []const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("event: subagent_completion\ndata: {\"type\":\"subagent_completion\",\"event_id\":\"");
    try jsonEscapeInto(w, event_id);
    try w.writeAll("\",\"session_key\":\"");
    try jsonEscapeInto(w, session_key);
    try w.writeAll("\",\"content\":\"");
    try jsonEscapeInto(w, content);
    try w.writeAll("\"}\n\n");
    return buf.toOwnedSlice(allocator);
}

fn sseTokenFrame(allocator: std.mem.Allocator, delta: []const u8, seq: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("event: token\ndata: {\"delta\":\"");
    try jsonEscapeInto(w, delta);
    try w.writeAll("\",\"content\":\"");
    try jsonEscapeInto(w, delta);
    try w.print("\",\"seq\":{d},\"stream_kind\":\"final_reply\",\"live\":false}}\n\n", .{seq});
    return buf.toOwnedSlice(allocator);
}

fn sseDoneFrame(allocator: std.mem.Allocator, session_id: ?[]const u8, message_id: ?i64) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("event: done\ndata: {\"type\":\"done\"");
    if (session_id) |sid| {
        try w.writeAll(",\"session_id\":\"");
        try jsonEscapeInto(w, sid);
        try w.writeAll("\"");
    }
    if (message_id) |mid| {
        try w.print(",\"message_id\":\"{d}\"", .{mid});
    }
    try w.writeAll("}\n\n");
    return buf.toOwnedSlice(allocator);
}

fn sseChatPayload(allocator: std.mem.Allocator, text: []const u8, session_id: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    const message_id = std.time.milliTimestamp();

    const reply_start = try sseReplyStartFrame(allocator, "final_reply", "buffered_replay", false);
    defer allocator.free(reply_start);
    try w.writeAll(reply_start);

    var start: usize = 0;
    var seq: usize = 0;
    while (start < text.len) : (start += SSE_TOKEN_CHUNK_SIZE) {
        const end = @min(start + SSE_TOKEN_CHUNK_SIZE, text.len);
        const token_frame = try sseTokenFrame(allocator, text[start..end], seq);
        defer allocator.free(token_frame);
        try w.writeAll(token_frame);
        seq += 1;
    }
    const done_frame = try sseDoneFrame(allocator, session_id, message_id);
    defer allocator.free(done_frame);
    try w.writeAll(done_frame);
    return buf.toOwnedSlice(allocator);
}

fn sseBufferedChatPayload(
    allocator: std.mem.Allocator,
    status_frame: []const u8,
    ux_frames: []const u8,
    text: []const u8,
    session_id: []const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(status_frame);
    try w.writeAll(ux_frames);

    const payload = try sseChatPayload(allocator, text, session_id);
    defer allocator.free(payload);
    try w.writeAll(payload);

    return buf.toOwnedSlice(allocator);
}

fn LockedSseStream(comptime StreamType: type) type {
    return struct {
        stream: StreamType,
        mutex: std.Thread.Mutex = .{},
        closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        const Self = @This();

        fn init(stream: StreamType) Self {
            return .{ .stream = stream };
        }

        fn sendHeader(self: *Self, status: []const u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed.load(.acquire)) return error.BrokenPipe;
            try sendChunkedSseHeader(self.stream, status);
        }

        fn sendFrame(self: *Self, frame: []const u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed.load(.acquire)) return error.BrokenPipe;
            try sendChunkedSseFrame(self.stream, frame);
        }

        fn finish(self: *Self) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed.swap(true, .acq_rel)) return;
            try finishChunkedSse(self.stream);
        }

        fn markClosed(self: *Self) void {
            _ = self.closed.swap(true, .acq_rel);
        }
    };
}

fn SseKeepalive(comptime LockedStreamType: type) type {
    return struct {
        stream: *LockedStreamType,
        stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        const Self = @This();

        fn init(stream: *LockedStreamType) Self {
            return .{ .stream = stream };
        }

        fn stop(self: *Self) void {
            self.stop_flag.store(true, .release);
        }

        fn run(self: *Self) void {
            var waited_ms: u64 = 0;
            while (!self.stop_flag.load(.acquire)) {
                std.Thread.sleep(SSE_KEEPALIVE_POLL_MS * std.time.ns_per_ms);
                if (self.stop_flag.load(.acquire)) break;
                waited_ms += SSE_KEEPALIVE_POLL_MS;
                if (waited_ms < SSE_KEEPALIVE_INTERVAL_MS) continue;
                waited_ms = 0;
                self.stream.sendFrame(SSE_KEEPALIVE_FRAME) catch {
                    self.stream.markClosed();
                    self.stop();
                    break;
                };
            }
        }
    };
}

fn sendChunkedSseHeader(stream: anytype, status: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {s}\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nTransfer-Encoding: chunked\r\nX-Accel-Buffering: no\r\n\r\n",
        .{status},
    );
    try stream.writeAll(header);
}

fn sendChunkedSseHeaderRetryAfter(stream: anytype, status: []const u8, retry_after_secs: u16) !void {
    var header_buf: [640]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {s}\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nTransfer-Encoding: chunked\r\nX-Accel-Buffering: no\r\nRetry-After: {d}\r\n\r\n",
        .{ status, @max(@as(u16, 1), retry_after_secs) },
    );
    try stream.writeAll(header);
}

fn sendChunkedSseFrame(stream: anytype, frame: []const u8) !void {
    var prefix_buf: [32]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{x}\r\n", .{frame.len});
    try stream.writeAll(prefix);
    try stream.writeAll(frame);
    try stream.writeAll("\r\n");
}

fn finishChunkedSse(stream: anytype) !void {
    try stream.writeAll("0\r\n\r\n");
}

fn sendSseErrorResponse(stream: anytype, allocator: std.mem.Allocator, status: []const u8, code: []const u8, msg: []const u8) void {
    sendChunkedSseHeader(stream, status) catch return;
    sendSseErrorFrames(stream, allocator, code, msg);
}

fn sendSseErrorFrames(stream: anytype, allocator: std.mem.Allocator, code: []const u8, msg: []const u8) void {
    const error_fallback = "event: error\ndata: {\"type\":\"error\",\"code\":\"chat_failed\",\"message\":\"chat failed\"}\n\n";
    const error_owned = sseErrorFrame(allocator, code, msg) catch null;
    defer if (error_owned) |frame| allocator.free(frame);
    const error_frame: []const u8 = if (error_owned) |frame| frame else error_fallback;
    sendChunkedSseFrame(stream, error_frame) catch return;

    const done_fallback = "event: done\ndata: {\"type\":\"done\"}\n\n";
    const done_owned = sseDoneFrame(allocator, null, null) catch null;
    defer if (done_owned) |frame| allocator.free(frame);
    const done_frame: []const u8 = if (done_owned) |frame| frame else done_fallback;
    sendChunkedSseFrame(stream, done_frame) catch return;

    finishChunkedSse(stream) catch {};
}

fn sendLockedSseErrorFrames(stream: anytype, allocator: std.mem.Allocator, code: []const u8, msg: []const u8) void {
    const error_fallback = "event: error\ndata: {\"type\":\"error\",\"code\":\"chat_failed\",\"message\":\"chat failed\"}\n\n";
    const error_owned = sseErrorFrame(allocator, code, msg) catch null;
    defer if (error_owned) |frame| allocator.free(frame);
    const error_frame: []const u8 = if (error_owned) |frame| frame else error_fallback;
    stream.sendFrame(error_frame) catch {
        stream.markClosed();
        return;
    };

    const done_fallback = "event: done\ndata: {\"type\":\"done\"}\n\n";
    const done_owned = sseDoneFrame(allocator, null, null) catch null;
    defer if (done_owned) |frame| allocator.free(frame);
    const done_frame: []const u8 = if (done_owned) |frame| frame else done_fallback;
    stream.sendFrame(done_frame) catch {
        stream.markClosed();
        return;
    };

    stream.finish() catch stream.markClosed();
}

const ChatStreamSessionKeyError = error{
    InvalidSessionKey,
    SessionKeyUserMismatch,
    InvalidSessionLane,
    MissingSessionKey,
};

const ChatStreamTenantLane = enum {
    main,
    thread,
    task,
    cron,
};

const ChatStreamSessionKeyRejection = enum {
    missing,
    invalid,
    wrong_user,
    invalid_lane,
};

fn sessionKeyOwnedByUser(session_key: []const u8, user_id: []const u8) bool {
    var prefix_buf: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "agent:zaki-bot:user:{s}:", .{user_id}) catch return false;
    return std.mem.startsWith(u8, session_key, prefix);
}

fn sessionKeyHasAllowedTenantLane(session_key: []const u8, user_id: []const u8) bool {
    return tenantLaneFromSessionKey(session_key, user_id) != null;
}

fn tenantLaneFromSessionKey(session_key: []const u8, user_id: []const u8) ?ChatStreamTenantLane {
    var prefix_buf: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "agent:zaki-bot:user:{s}:", .{user_id}) catch return null;
    if (!std.mem.startsWith(u8, session_key, prefix)) return null;
    const lane = session_key[prefix.len..];
    if (std.mem.eql(u8, lane, "main")) return .main;
    if (std.mem.startsWith(u8, lane, "thread:") and lane.len > "thread:".len) return .thread;
    if (std.mem.startsWith(u8, lane, "task:") and lane.len > "task:".len) return .task;
    if (std.mem.startsWith(u8, lane, "cron:") and lane.len > "cron:".len) return .cron;
    return null;
}

fn recordChatStreamLane(state: *GatewayState, session_key: []const u8, user_id: []const u8, tenant_enabled: bool) void {
    const lane_opt = if (tenant_enabled) tenantLaneFromSessionKey(session_key, user_id) else blk: {
        if (std.mem.eql(u8, session_key, "main")) break :blk ChatStreamTenantLane.main;
        if (std.mem.startsWith(u8, session_key, "thread:")) break :blk ChatStreamTenantLane.thread;
        if (std.mem.startsWith(u8, session_key, "task:")) break :blk ChatStreamTenantLane.task;
        if (std.mem.startsWith(u8, session_key, "cron:")) break :blk ChatStreamTenantLane.cron;
        break :blk null;
    };
    const lane = lane_opt orelse return;
    switch (lane) {
        .main => _ = state.chat_stream_lane_main_total.fetchAdd(1, .monotonic),
        .thread => _ = state.chat_stream_lane_thread_total.fetchAdd(1, .monotonic),
        .task => _ = state.chat_stream_lane_task_total.fetchAdd(1, .monotonic),
        .cron => _ = state.chat_stream_lane_cron_total.fetchAdd(1, .monotonic),
    }
}

fn recordChatStreamSessionKeyRejection(state: *GatewayState, reason: ChatStreamSessionKeyRejection) void {
    switch (reason) {
        .missing => _ = state.chat_stream_session_key_missing_total.fetchAdd(1, .monotonic),
        .invalid => _ = state.chat_stream_session_key_invalid_total.fetchAdd(1, .monotonic),
        .wrong_user => _ = state.chat_stream_session_key_wrong_user_total.fetchAdd(1, .monotonic),
        .invalid_lane => _ = state.chat_stream_session_key_invalid_lane_total.fetchAdd(1, .monotonic),
    }
}

fn resolveChatStreamSessionKey(
    body: []const u8,
    user_id: []const u8,
    tenant_enabled: bool,
    require_explicit_session_key: bool,
    fallback_buf: []u8,
) ChatStreamSessionKeyError![]const u8 {
    const requested = jsonStringField(body, "session_key");
    if (requested) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > 255) return error.InvalidSessionKey;
        if (std.mem.indexOfAny(u8, trimmed, "\r\n") != null) return error.InvalidSessionKey;
        if (tenant_enabled) {
            if (!sessionKeyOwnedByUser(trimmed, user_id)) return error.SessionKeyUserMismatch;
            if (!sessionKeyHasAllowedTenantLane(trimmed, user_id)) return error.InvalidSessionLane;
        }
        return trimmed;
    }
    if (require_explicit_session_key) return error.MissingSessionKey;
    return zaki_session.userMainSessionKey(fallback_buf, user_id);
}

fn resolveChatEventsSessionKey(
    target: []const u8,
    user_id: []const u8,
    tenant_enabled: bool,
) ChatStreamSessionKeyError![]const u8 {
    const requested = parseQueryParam(target, "session_key") orelse return error.MissingSessionKey;
    const trimmed = std.mem.trim(u8, requested, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 255) return error.InvalidSessionKey;
    if (std.mem.indexOfAny(u8, trimmed, "\r\n") != null) return error.InvalidSessionKey;
    if (tenant_enabled) {
        if (!sessionKeyOwnedByUser(trimmed, user_id)) return error.SessionKeyUserMismatch;
        if (!sessionKeyHasAllowedTenantLane(trimmed, user_id)) return error.InvalidSessionLane;
    }
    return trimmed;
}

fn handleApiChatEventsSseConnection(
    root_allocator: std.mem.Allocator,
    req_allocator: std.mem.Allocator,
    stream: anytype,
    raw_request: []const u8,
    method: []const u8,
    base_path: []const u8,
    state: *GatewayState,
    config_opt: ?*const Config,
    session_mgr_opt: ?*session_mod.SessionManager,
) bool {
    _ = root_allocator;
    if (!std.mem.eql(u8, base_path, "/api/v1/chat/events")) return false;

    if (!validateInternalServiceToken(raw_request, state)) {
        sendSseErrorResponse(stream, req_allocator, "401 Unauthorized", "unauthorized", "unauthorized");
        return true;
    }
    if (!std.mem.eql(u8, method, "GET")) {
        sendSseErrorResponse(stream, req_allocator, "405 Method Not Allowed", "method_not_allowed", "method not allowed");
        return true;
    }
    if (state.draining.load(.acquire)) {
        sendSseErrorResponse(stream, req_allocator, "503 Service Unavailable", "gateway_draining", "gateway draining, retry shortly");
        return true;
    }

    const header_user_id = extractZakiUserId(raw_request);
    const user_id = resolveGatewayRequestUserId(state, header_user_id, null, true) catch |err| {
        const response = switch (err) {
            error.MissingUserId => .{ "400 Bad Request", "missing_user_id", "missing X-Zaki-User-Id" },
            error.UserCellUserMismatch => .{ "403 Forbidden", "wrong_user_cell", "request does not belong to this user cell" },
        };
        sendSseErrorResponse(stream, req_allocator, response[0], response[1], response[2]);
        return true;
    };

    if (state.role == .broker) {
        prepareBrokerUserForRouting(req_allocator, state, user_id) catch |err| {
            if (isIdentityUserNotFound(err)) {
                sendSseErrorResponse(stream, req_allocator, "404 Not Found", "unknown_user_id", "unknown user id");
                return true;
            }
            sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "provisioning_failed", "user provisioning failed");
            return true;
        };
        const target = extractRequestTarget(raw_request) orelse base_path;
        brokerProxyChatStreamSseConnection(
            req_allocator,
            stream,
            state,
            raw_request,
            method,
            target,
            user_id,
        );
        return true;
    }

    var user_ctx = resolveUserContext(req_allocator, state, user_id) catch {
        sendSseErrorResponse(stream, req_allocator, "400 Bad Request", "invalid_user", "invalid user");
        return true;
    };
    defer user_ctx.deinit(req_allocator);

    var prep_guard = state.user_preparation_gate.acquire(user_ctx.user_id) catch {
        sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "preparation_gate_failed", "user preparation gate failed");
        return true;
    };
    defer prep_guard.deinit();

    ensureUserDirectories(&user_ctx) catch {
        sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "provisioning_failed", "user provisioning failed");
        return true;
    };
    ensureUserProvisioned(state, &user_ctx) catch |err| {
        if (isIdentityUserNotFound(err)) {
            sendSseErrorResponse(stream, req_allocator, "404 Not Found", "unknown_user_id", "unknown user id");
            return true;
        }
        sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "provisioning_failed", "user provisioning failed");
        return true;
    };
    scaffoldUserWorkspace(req_allocator, &user_ctx);
    prep_guard.release();

    var ownership_lock = maybeAcquireTenantOwnershipLock(req_allocator, state, user_ctx.user_id, user_ctx.user_root) catch {
        sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "tenant_lock_failed", "tenant ownership lock failed");
        return true;
    };
    defer ownership_lock.deinit();
    switch (ownership_lock) {
        .disabled => {},
        .acquired => {},
        .conflict => |*conflict| {
            recordTenantLockConflict(state, .chat_stream_sse);
            sendSseOwnershipLockConflictResponse(stream, req_allocator, conflict);
            return true;
        },
    }

    const target = extractRequestTarget(raw_request) orelse base_path;
    const session_key = resolveChatEventsSessionKey(target, user_id, state.tenant_enabled) catch |err| {
        const code: []const u8 = switch (err) {
            error.InvalidSessionKey => "invalid_session_key",
            error.SessionKeyUserMismatch => "session_key_user_mismatch",
            error.InvalidSessionLane => "invalid_session_lane",
            error.MissingSessionKey => "missing_session_key",
        };
        const msg: []const u8 = switch (err) {
            error.InvalidSessionKey => "invalid session_key",
            error.SessionKeyUserMismatch => "session_key must belong to the authenticated user",
            error.InvalidSessionLane => "session_key must use lane main|thread:<id>|task:<id>|cron:<id>",
            error.MissingSessionKey => "session_key is required",
        };
        sendSseErrorResponse(stream, req_allocator, "400 Bad Request", code, msg);
        return true;
    };

    var completion_session_mgr: ?*session_mod.SessionManager = null;
    if (state.tenant_enabled) {
        const cfg = config_opt orelse {
            sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "tenant_config_missing", "tenant runtime unavailable");
            return true;
        };
        const tenant_runtime = getTenantRuntime(state, cfg, &user_ctx) catch |err| {
            if (err == error.ExecutionDelegated) {
                sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "execution_delegated", "broker mode does not execute locally");
            } else {
                sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "tenant_runtime_failed", "tenant runtime init failed");
            }
            return true;
        };
        completion_session_mgr = &tenant_runtime.session_mgr;
    } else if (session_mgr_opt) |sm| {
        completion_session_mgr = sm;
    } else {
        sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "session_store_unavailable", "session manager unavailable");
        return true;
    }

    const sm = completion_session_mgr.?;
    var sse_stream = LockedSseStream(@TypeOf(stream)).init(stream);
    sse_stream.sendHeader("200 OK") catch return true;

    const ready_owned = sseReadyFrame(req_allocator, session_key) catch null;
    defer if (ready_owned) |frame| req_allocator.free(frame);
    const ready_frame: []const u8 = if (ready_owned) |frame| frame else "event: ready\ndata: {\"type\":\"ready\"}\n\n";
    sse_stream.sendFrame(ready_frame) catch return true;

    var subscriber = AppEventsSubscriber{};
    defer subscriber.deinit(state.allocator);
    state.app_event_subscribers.register(user_id, session_key, &subscriber) catch {
        sendLockedSseErrorFrames(&sse_stream, req_allocator, "subscription_failed", "failed to attach live completion subscription");
        return true;
    };
    defer state.app_event_subscribers.unregister(user_id, session_key, &subscriber);

    const pending_completion_events = sm.loadCompletionEvents(session_key) catch &.{};
    defer if (pending_completion_events.len > 0) {
        memory_mod.freeCompletionEvents(sm.allocator, @constCast(pending_completion_events));
    };
    for (pending_completion_events) |event| {
        const frame = sseSubagentCompletionFrame(req_allocator, event.id, event.session_id, event.content) catch {
            sendLockedSseErrorFrames(&sse_stream, req_allocator, "stream_encode_failed", "failed to encode completion frame");
            return true;
        };
        sse_stream.sendFrame(frame) catch {
            req_allocator.free(frame);
            sse_stream.markClosed();
            return true;
        };
        req_allocator.free(frame);
        subscriber.markDelivered(state.allocator, event.id) catch {};
        sm.deleteCompletionEvent(event.id) catch {};
    }

    while (!state.shutdown_requested.load(.acquire)) {
        const result = subscriber.waitForEvent(SSE_KEEPALIVE_INTERVAL_MS * std.time.ns_per_ms);
        switch (result) {
            .timeout => {
                sse_stream.sendFrame(SSE_KEEPALIVE_FRAME) catch {
                    sse_stream.markClosed();
                    return true;
                };
            },
            .closed => break,
            .event => |event| {
                defer {
                    var owned = event;
                    owned.deinit(state.allocator);
                }
                const frame = sseSubagentCompletionFrame(req_allocator, event.id, event.session_key, event.content) catch {
                    sendLockedSseErrorFrames(&sse_stream, req_allocator, "stream_encode_failed", "failed to encode completion frame");
                    return true;
                };
                sse_stream.sendFrame(frame) catch {
                    req_allocator.free(frame);
                    sse_stream.markClosed();
                    return true;
                };
                req_allocator.free(frame);
                subscriber.markDelivered(state.allocator, event.id) catch {};
                sm.deleteCompletionEvent(event.id) catch {};
            },
        }
    }

    subscriber.close();
    sse_stream.finish() catch sse_stream.markClosed();
    return true;
}

fn handleApiChatStreamSseConnection(
    root_allocator: std.mem.Allocator,
    req_allocator: std.mem.Allocator,
    stream: anytype,
    raw_request: []const u8,
    method: []const u8,
    base_path: []const u8,
    state: *GatewayState,
    config_opt: ?*const Config,
    session_mgr_opt: ?*session_mod.SessionManager,
) bool {
    if (!std.mem.eql(u8, base_path, "/api/v1/chat/stream")) return false;

    const request_start_ms = std.time.milliTimestamp();
    if (!validateInternalServiceToken(raw_request, state)) {
        sendSseErrorResponse(stream, req_allocator, "401 Unauthorized", "unauthorized", "unauthorized");
        return true;
    }
    if (!std.mem.eql(u8, method, "POST")) {
        sendSseErrorResponse(stream, req_allocator, "405 Method Not Allowed", "method_not_allowed", "method not allowed");
        return true;
    }
    if (state.draining.load(.acquire)) {
        sendSseErrorResponse(stream, req_allocator, "503 Service Unavailable", "gateway_draining", "gateway draining, retry shortly");
        return true;
    }

    const body = extractBody(raw_request) orelse {
        sendSseErrorResponse(stream, req_allocator, "400 Bad Request", "missing_body", "missing body");
        return true;
    };
    const header_user_id = extractZakiUserId(raw_request);
    const user_id = resolveGatewayRequestUserId(state, header_user_id, jsonStringField(body, "user_id"), true) catch |err| {
        const response = switch (err) {
            error.MissingUserId => .{ "400 Bad Request", "missing_user_id", "missing X-Zaki-User-Id" },
            error.UserCellUserMismatch => .{ "403 Forbidden", "wrong_user_cell", "request does not belong to this user cell" },
        };
        sendSseErrorResponse(stream, req_allocator, response[0], response[1], response[2]);
        return true;
    };
    if (state.role == .broker) {
        prepareBrokerUserForRouting(req_allocator, state, user_id) catch |err| {
            if (isIdentityUserNotFound(err)) {
                sendSseErrorResponse(stream, req_allocator, "404 Not Found", "unknown_user_id", "unknown user id");
                return true;
            }
            sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "provisioning_failed", "user provisioning failed");
            return true;
        };
        const target = extractRequestTarget(raw_request) orelse base_path;
        brokerProxyChatStreamSseConnection(
            req_allocator,
            stream,
            state,
            raw_request,
            method,
            target,
            user_id,
        );
        return true;
    }

    var user_ctx = resolveUserContext(req_allocator, state, user_id) catch {
        sendSseErrorResponse(stream, req_allocator, "400 Bad Request", "invalid_user", "invalid user");
        return true;
    };
    defer user_ctx.deinit(req_allocator);

    var prep_guard = state.user_preparation_gate.acquire(user_ctx.user_id) catch {
        sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "preparation_gate_failed", "user preparation gate failed");
        return true;
    };
    defer prep_guard.deinit();

    ensureUserDirectories(&user_ctx) catch {
        sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "provisioning_failed", "user provisioning failed");
        return true;
    };

    ensureUserProvisioned(state, &user_ctx) catch |err| {
        if (isIdentityUserNotFound(err)) {
            sendSseErrorResponse(stream, req_allocator, "404 Not Found", "unknown_user_id", "unknown user id");
            return true;
        }
        sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "provisioning_failed", "user provisioning failed");
        return true;
    };
    scaffoldUserWorkspace(req_allocator, &user_ctx);
    prep_guard.release();

    var ownership_lock = maybeAcquireTenantOwnershipLock(req_allocator, state, user_ctx.user_id, user_ctx.user_root) catch {
        sendSseErrorResponse(stream, req_allocator, "500 Internal Server Error", "tenant_lock_failed", "tenant ownership lock failed");
        return true;
    };
    defer ownership_lock.deinit();
    switch (ownership_lock) {
        .disabled => {},
        .acquired => {},
        .conflict => |*conflict| {
            recordTenantLockConflict(state, .chat_stream_sse);
            sendSseOwnershipLockConflictResponse(stream, req_allocator, conflict);
            return true;
        },
    }

    const message = jsonStringField(body, "message") orelse jsonStringField(body, "text") orelse {
        sendSseErrorResponse(stream, req_allocator, "400 Bad Request", "missing_message", "missing message");
        return true;
    };

    var session_buf: [256]u8 = undefined;
    const require_explicit_session_key = if (config_opt) |cfg| cfg.gateway.require_explicit_chat_stream_session_key else true;
    const session_key = resolveChatStreamSessionKey(body, user_id, state.tenant_enabled, require_explicit_session_key, &session_buf) catch |err| {
        const rejection: ChatStreamSessionKeyRejection = switch (err) {
            error.InvalidSessionKey => .invalid,
            error.SessionKeyUserMismatch => .wrong_user,
            error.InvalidSessionLane => .invalid_lane,
            error.MissingSessionKey => .missing,
        };
        recordChatStreamSessionKeyRejection(state, rejection);
        const code: []const u8 = switch (err) {
            error.InvalidSessionKey => "invalid_session_key",
            error.SessionKeyUserMismatch => "session_key_user_mismatch",
            error.InvalidSessionLane => "invalid_session_lane",
            error.MissingSessionKey => "missing_session_key",
        };
        const msg: []const u8 = switch (err) {
            error.InvalidSessionKey => "invalid session_key",
            error.SessionKeyUserMismatch => "session_key must belong to the authenticated user",
            error.InvalidSessionLane => "session_key must use lane main|thread:<id>|task:<id>|cron:<id>",
            error.MissingSessionKey => "session_key is required",
        };
        sendSseErrorResponse(stream, req_allocator, "400 Bad Request", code, msg);
        return true;
    };
    _ = state.chat_stream_total.fetchAdd(1, .monotonic);
    recordChatStreamLane(state, session_key, user_id, state.tenant_enabled);
    var sse_stream = LockedSseStream(@TypeOf(stream)).init(stream);
    sse_stream.sendHeader("200 OK") catch return true;

    const status_fallback = "event: status\ndata: {\"type\":\"statusResponse\",\"content\":\"Processing request\"}\n\n";
    const status_owned = sseStatusFrame(req_allocator, "Processing request") catch null;
    defer if (status_owned) |frame| req_allocator.free(frame);
    const status_frame: []const u8 = if (status_owned) |frame| frame else status_fallback;
    sse_stream.sendFrame(status_frame) catch return true;

    var progress_observer_impl = SseProgressObserver(@TypeOf(sse_stream)).init(req_allocator, &sse_stream);
    const progress_observer = progress_observer_impl.observer();
    var keepalive = SseKeepalive(@TypeOf(sse_stream)).init(&sse_stream);
    const keepalive_thread: ?std.Thread = std.Thread.spawn(.{}, SseKeepalive(@TypeOf(sse_stream)).run, .{&keepalive}) catch null;
    var keepalive_joined = false;
    defer if (!keepalive_joined) {
        keepalive.stop();
        if (keepalive_thread) |thread| thread.join();
    };

    const chat_start_ms = std.time.milliTimestamp();
    const ReplyOutcome = union(enum) {
        ok: []const u8,
        err: struct { code: []const u8, msg: []const u8 },
    };
    const outcome: ReplyOutcome = blk: {
        if (state.tenant_enabled) {
            const cfg = config_opt orelse {
                _ = state.chat_stream_errors_total.fetchAdd(1, .monotonic);
                break :blk .{ .err = .{ .code = "tenant_config_missing", .msg = "tenant runtime unavailable" } };
            };
            const tenant_runtime = getTenantRuntime(state, cfg, &user_ctx) catch |err| {
                _ = state.chat_stream_errors_total.fetchAdd(1, .monotonic);
                if (err == error.ExecutionDelegated) {
                    break :blk .{ .err = .{ .code = "execution_delegated", .msg = "broker mode does not execute locally" } };
                } else {
                    break :blk .{ .err = .{ .code = "tenant_runtime_failed", .msg = "tenant runtime init failed" } };
                }
            };
            break :blk .{ .ok = tenant_runtime.processMessage(
                session_key,
                message,
                .{
                    .channel = "zaki_app",
                    .is_group = false,
                },
                .{
                    .channel = "zaki_app",
                    .chat_id = session_key,
                    .is_group = false,
                    .is_dm = true,
                },
                progress_observer,
            ) catch {
                _ = state.chat_stream_errors_total.fetchAdd(1, .monotonic);
                break :blk .{ .err = .{ .code = "chat_failed", .msg = "chat failed" } };
            } };
        }
        if (session_mgr_opt) |sm| {
            break :blk .{ .ok = sm.processMessageWithContext(session_key, message, null, .{
                .message_turn_context = .{
                    .channel = "zaki_app",
                    .chat_id = session_key,
                    .is_group = false,
                    .is_dm = true,
                },
                .progress_observer = progress_observer,
            }) catch {
                _ = state.chat_stream_errors_total.fetchAdd(1, .monotonic);
                break :blk .{ .err = .{ .code = "chat_failed", .msg = "chat failed" } };
            } };
        }
        break :blk .{ .ok = processIncomingMessage(root_allocator, message, session_key, user_id) catch {
            _ = state.chat_stream_errors_total.fetchAdd(1, .monotonic);
            break :blk .{ .err = .{ .code = "chat_failed", .msg = "chat failed" } };
        } };
    };
    keepalive.stop();
    if (keepalive_thread) |thread| thread.join();
    keepalive_joined = true;

    const reply = switch (outcome) {
        .ok => |value| value,
        .err => |err_payload| {
            sendLockedSseErrorFrames(&sse_stream, req_allocator, err_payload.code, err_payload.msg);
            return true;
        },
    };
    defer root_allocator.free(reply);

    const payload_text = if (reply.len > 0)
        reply
    else
        "received";
    const reply_start_fallback = "event: reply_start\ndata: {\"type\":\"reply_start\",\"stream_kind\":\"final_reply\",\"delivery_mode\":\"buffered_replay\",\"live\":false}\n\n";
    const reply_start_owned = sseReplyStartFrame(req_allocator, "final_reply", "buffered_replay", false) catch null;
    defer if (reply_start_owned) |frame| req_allocator.free(frame);
    const reply_start_frame: []const u8 = if (reply_start_owned) |frame| frame else reply_start_fallback;
    sse_stream.sendFrame(reply_start_frame) catch return true;

    var start: usize = 0;
    var seq: usize = 0;
    while (start < payload_text.len) : (start += SSE_TOKEN_CHUNK_SIZE) {
        const end = @min(start + SSE_TOKEN_CHUNK_SIZE, payload_text.len);
        const token_owned = sseTokenFrame(req_allocator, payload_text[start..end], seq) catch {
            sendLockedSseErrorFrames(&sse_stream, req_allocator, "stream_encode_failed", "failed to encode token frame");
            return true;
        };
        defer req_allocator.free(token_owned);
        sse_stream.sendFrame(token_owned) catch return true;
        seq += 1;
    }

    const done_fallback = "event: done\ndata: {\"type\":\"done\"}\n\n";
    const done_owned = sseDoneFrame(req_allocator, session_key, std.time.milliTimestamp()) catch null;
    defer if (done_owned) |frame| req_allocator.free(frame);
    const done_frame: []const u8 = if (done_owned) |frame| frame else done_fallback;
    sse_stream.sendFrame(done_frame) catch {
        sendLockedSseErrorFrames(&sse_stream, req_allocator, "stream_done_failed", "failed to emit done frame");
        return true;
    };
    sse_stream.finish() catch return true;

    const chat_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - chat_start_ms));
    const request_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - request_start_ms));
    log.info("chat.stream.complete user={s} session={s} chat_ms={d} sse_ms={d} total_ms={d}", .{
        user_id,
        session_key,
        chat_duration_ms,
        @as(u64, 0),
        request_duration_ms,
    });

    return true;
}

fn parseUserPath(base_path: []const u8) ?struct { user_id: []const u8, subpath: []const u8 } {
    const prefix = "/api/v1/users/";
    if (!std.mem.startsWith(u8, base_path, prefix)) return null;
    const rest = base_path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const user_id = rest[0..slash];
    if (!isValidIdentifier(user_id)) return null;
    return .{
        .user_id = user_id,
        .subpath = rest[slash + 1 ..],
    };
}

fn parseUserChannelBindingsSubpath(subpath: []const u8) ?struct {
    channel: []const u8,
    binding_id: ?[]const u8,
} {
    const prefix = "channels/";
    if (!std.mem.startsWith(u8, subpath, prefix)) return null;
    const rest = subpath[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const channel = rest[0..slash];
    if (!isValidIdentifier(channel)) return null;
    const tail = rest[slash + 1 ..];
    if (std.mem.eql(u8, tail, "bindings")) {
        return .{
            .channel = channel,
            .binding_id = null,
        };
    }
    const bindings_prefix = "bindings/";
    if (!std.mem.startsWith(u8, tail, bindings_prefix)) return null;
    const binding_id = tail[bindings_prefix.len..];
    if (!isValidIdentifier(binding_id)) return null;
    return .{
        .channel = channel,
        .binding_id = binding_id,
    };
}

fn resolveSecretPath(allocator: std.mem.Allocator, secrets_dir: []const u8, key: []const u8) ![]u8 {
    if (!isValidIdentifier(key)) return error.InvalidSecretKey;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ secrets_dir, key });
}

fn generateWebhookSecretToken(allocator: std.mem.Allocator) ![]u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
    var random_bytes: [24]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var out: [24]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        out[i] = alphabet[@as(usize, b) % alphabet.len];
    }
    return allocator.dupe(u8, out[0..]);
}

fn normalizeWebhookBaseUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, base_url, " \t\r\n");
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (!std.mem.startsWith(u8, trimmed, "https://")) return error.WebhookUrlMustBeHttps;
    return allocator.dupe(u8, trimmed);
}

fn buildWebhookUrlForUser(allocator: std.mem.Allocator, base_url: []const u8, user_id: []const u8) ![]u8 {
    const normalized = try normalizeWebhookBaseUrl(allocator, base_url);
    defer allocator.free(normalized);
    return std.fmt.allocPrint(allocator, "{s}/webhook/telegram?user_id={s}", .{ normalized, user_id });
}

fn isLikelyTelegramBotToken(token: []const u8) bool {
    return telegram_token.is_likely_bot_token(token);
}

fn telegramApiUrl(allocator: std.mem.Allocator, bot_token: []const u8, method: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/{s}", .{ bot_token, method });
}

fn telegramApiCall(
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    method: []const u8,
    body: []const u8,
) ![]u8 {
    const url = try telegramApiUrl(allocator, bot_token, method);
    defer allocator.free(url);
    const response = try http_util.request_with_mode(allocator, .{ .mode = .native_preferred }, .{
        .subsystem = .channels,
        .method = "POST",
        .url = url,
        .body = body,
        .headers = &.{"Content-Type: application/json"},
        .timeout_ms = 30_000,
        .max_response_bytes = 1024 * 1024,
    });
    return response.body;
}

fn handleApiRoute(
    root_allocator: std.mem.Allocator,
    req_allocator: std.mem.Allocator,
    raw_request: []const u8,
    method: []const u8,
    base_path: []const u8,
    state: *GatewayState,
    config_opt: ?*const Config,
    session_mgr_opt: ?*session_mod.SessionManager,
) RouteResponse {
    if (!validateInternalServiceToken(raw_request, state)) {
        return .{ .status = "401 Unauthorized", .body = "{\"error\":\"unauthorized\"}" };
    }

    if (std.mem.eql(u8, base_path, "/api/v1/chat/stream")) {
        const request_start_ms = std.time.milliTimestamp();
        if (!std.mem.eql(u8, method, "POST")) {
            return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
        }
        if (state.draining.load(.acquire)) {
            const body = sseErrorEvent(req_allocator, "gateway_draining", "gateway draining, retry shortly") catch "event: error\ndata: {\"type\":\"error\",\"code\":\"gateway_draining\",\"message\":\"gateway draining\"}\n\nevent: done\ndata: {\"type\":\"done\"}\n\n";
            return .{ .status = "503 Service Unavailable", .body = body, .content_type = "text/event-stream; charset=utf-8" };
        }
        const body = extractBody(raw_request) orelse {
            return .{ .status = "400 Bad Request", .body = "{\"error\":\"missing body\"}" };
        };
        const header_user_id = extractZakiUserId(raw_request);
        const user_id = resolveGatewayRequestUserId(state, header_user_id, jsonStringField(body, "user_id"), true) catch |err| {
            return switch (err) {
                error.MissingUserId => .{ .status = "400 Bad Request", .body = "{\"error\":\"missing X-Zaki-User-Id\"}" },
                error.UserCellUserMismatch => .{ .status = "403 Forbidden", .body = "{\"error\":\"wrong_user_cell\"}" },
            };
        };
        if (state.role == .broker) {
            return .{
                .status = "500 Internal Server Error",
                .body = "{\"error\":\"chat_stream_requires_streaming_path\"}",
            };
        }
        var user_ctx = resolveUserContext(req_allocator, state, user_id) catch {
            return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
        };
        defer user_ctx.deinit(req_allocator);
        var prep_guard = state.user_preparation_gate.acquire(user_ctx.user_id) catch {
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"user preparation gate failed\"}" };
        };
        defer prep_guard.deinit();
        ensureUserDirectories(&user_ctx) catch {
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"user provisioning failed\"}" };
        };
        ensureUserProvisioned(state, &user_ctx) catch |err| {
            if (isIdentityUserNotFound(err)) {
                return .{ .status = "404 Not Found", .body = "{\"error\":\"unknown_user_id\"}" };
            }
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"user provisioning failed\"}" };
        };
        scaffoldUserWorkspace(req_allocator, &user_ctx);
        prep_guard.release();
        var ownership_lock = maybeAcquireTenantOwnershipLock(req_allocator, state, user_ctx.user_id, user_ctx.user_root) catch {
            return .{
                .status = "500 Internal Server Error",
                .body = "{\"error\":\"tenant ownership lock failed\"}",
            };
        };
        defer ownership_lock.deinit();
        switch (ownership_lock) {
            .disabled => {},
            .acquired => {},
            .conflict => |*conflict| {
                recordTenantLockConflict(state, .chat_stream_http);
                return ownershipLockConflictSseRouteResponse(req_allocator, conflict);
            },
        }

        const message = jsonStringField(body, "message") orelse jsonStringField(body, "text") orelse
            return .{ .status = "400 Bad Request", .body = "{\"error\":\"missing message\"}" };
        var session_buf: [256]u8 = undefined;
        const require_explicit_session_key = if (config_opt) |cfg| cfg.gateway.require_explicit_chat_stream_session_key else true;
        const session_key = resolveChatStreamSessionKey(body, user_id, state.tenant_enabled, require_explicit_session_key, &session_buf) catch |err| {
            const rejection: ChatStreamSessionKeyRejection = switch (err) {
                error.InvalidSessionKey => .invalid,
                error.SessionKeyUserMismatch => .wrong_user,
                error.InvalidSessionLane => .invalid_lane,
                error.MissingSessionKey => .missing,
            };
            recordChatStreamSessionKeyRejection(state, rejection);
            const code: []const u8 = switch (err) {
                error.InvalidSessionKey => "invalid_session_key",
                error.SessionKeyUserMismatch => "session_key_user_mismatch",
                error.InvalidSessionLane => "invalid_session_lane",
                error.MissingSessionKey => "missing_session_key",
            };
            const msg: []const u8 = switch (err) {
                error.InvalidSessionKey => "invalid session_key",
                error.SessionKeyUserMismatch => "session_key must belong to the authenticated user",
                error.InvalidSessionLane => "session_key must use lane main|thread:<id>|task:<id>|cron:<id>",
                error.MissingSessionKey => "session_key is required",
            };
            const err_sse = sseErrorEvent(req_allocator, code, msg) catch "event: error\ndata: {\"type\":\"error\",\"code\":\"invalid_session_key\",\"message\":\"invalid session_key\"}\n\nevent: done\ndata: {\"type\":\"done\"}\n\n";
            return .{
                .status = "400 Bad Request",
                .body = err_sse,
                .content_type = "text/event-stream; charset=utf-8",
            };
        };
        _ = state.chat_stream_total.fetchAdd(1, .monotonic);
        recordChatStreamLane(state, session_key, user_id, state.tenant_enabled);
        const status_fallback = "event: status\ndata: {\"type\":\"statusResponse\",\"content\":\"Processing request\"}\n\n";
        const status_owned = sseStatusFrame(req_allocator, "Processing request") catch null;
        defer if (status_owned) |frame| req_allocator.free(frame);
        const status_frame: []const u8 = if (status_owned) |frame| frame else status_fallback;
        var progress_observer_impl = BufferedSseProgressObserver.init(req_allocator);
        defer progress_observer_impl.deinit();
        const progress_observer = progress_observer_impl.observer();

        const chat_start_ms = std.time.milliTimestamp();
        const reply = blk: {
            if (state.tenant_enabled) {
                const cfg = config_opt orelse {
                    _ = state.chat_stream_errors_total.fetchAdd(1, .monotonic);
                    const err_sse = sseErrorEvent(req_allocator, "tenant_config_missing", "tenant runtime unavailable") catch "event: error\ndata: {\"type\":\"error\",\"code\":\"tenant_config_missing\",\"message\":\"tenant runtime unavailable\"}\n\nevent: done\ndata: {\"type\":\"done\"}\n\n";
                    return .{
                        .status = "500 Internal Server Error",
                        .body = err_sse,
                        .content_type = "text/event-stream; charset=utf-8",
                    };
                };
                const tenant_runtime = getTenantRuntime(state, cfg, &user_ctx) catch |err| {
                    _ = state.chat_stream_errors_total.fetchAdd(1, .monotonic);
                    const err_sse = if (err == error.ExecutionDelegated)
                        sseErrorEvent(req_allocator, "execution_delegated", "broker mode does not execute locally") catch "event: error\ndata: {\"type\":\"error\",\"code\":\"execution_delegated\",\"message\":\"broker mode does not execute locally\"}\n\nevent: done\ndata: {\"type\":\"done\"}\n\n"
                    else
                        sseErrorEvent(req_allocator, "tenant_runtime_failed", "tenant runtime init failed") catch "event: error\ndata: {\"type\":\"error\",\"code\":\"tenant_runtime_failed\",\"message\":\"tenant runtime init failed\"}\n\nevent: done\ndata: {\"type\":\"done\"}\n\n";
                    return .{
                        .status = "500 Internal Server Error",
                        .body = err_sse,
                        .content_type = "text/event-stream; charset=utf-8",
                    };
                };
                break :blk tenant_runtime.processMessage(
                    session_key,
                    message,
                    .{
                        .channel = "zaki_app",
                        .is_group = false,
                    },
                    .{
                        .channel = "zaki_app",
                        .chat_id = session_key,
                        .is_group = false,
                        .is_dm = true,
                    },
                    progress_observer,
                ) catch {
                    _ = state.chat_stream_errors_total.fetchAdd(1, .monotonic);
                    const err_sse = sseErrorEvent(req_allocator, "chat_failed", "chat failed") catch "event: error\ndata: {\"type\":\"error\",\"code\":\"chat_failed\",\"message\":\"chat failed\"}\n\nevent: done\ndata: {\"type\":\"done\"}\n\n";
                    return .{
                        .status = "500 Internal Server Error",
                        .body = err_sse,
                        .content_type = "text/event-stream; charset=utf-8",
                    };
                };
            }
            if (session_mgr_opt) |sm| {
                break :blk sm.processMessageWithContext(session_key, message, null, .{
                    .message_turn_context = .{
                        .channel = "zaki_app",
                        .chat_id = session_key,
                        .is_group = false,
                        .is_dm = true,
                    },
                    .progress_observer = progress_observer,
                }) catch {
                    _ = state.chat_stream_errors_total.fetchAdd(1, .monotonic);
                    const err_sse = sseErrorEvent(req_allocator, "chat_failed", "chat failed") catch "event: error\ndata: {\"type\":\"error\",\"code\":\"chat_failed\",\"message\":\"chat failed\"}\n\nevent: done\ndata: {\"type\":\"done\"}\n\n";
                    return .{
                        .status = "500 Internal Server Error",
                        .body = err_sse,
                        .content_type = "text/event-stream; charset=utf-8",
                    };
                };
            }
            break :blk processIncomingMessage(root_allocator, message, session_key, user_id) catch {
                _ = state.chat_stream_errors_total.fetchAdd(1, .monotonic);
                const err_sse = sseErrorEvent(req_allocator, "chat_failed", "chat failed") catch "event: error\ndata: {\"type\":\"error\",\"code\":\"chat_failed\",\"message\":\"chat failed\"}\n\nevent: done\ndata: {\"type\":\"done\"}\n\n";
                return .{
                    .status = "500 Internal Server Error",
                    .body = err_sse,
                    .content_type = "text/event-stream; charset=utf-8",
                };
            };
        };
        const chat_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - chat_start_ms));
        defer root_allocator.free(reply);
        const payload_text = if (reply.len > 0)
            req_allocator.dupe(u8, reply) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"failed to build completion payload\"}" }
        else
            req_allocator.dupe(u8, "received") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"failed to build completion payload\"}" };
        defer req_allocator.free(payload_text);
        const sse_start_ms = std.time.milliTimestamp();
        const sse = sseBufferedChatPayload(req_allocator, status_frame, progress_observer_impl.frames.items, payload_text, session_key) catch {
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"failed to build sse\"}" };
        };
        const sse_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - sse_start_ms));
        const request_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - request_start_ms));
        log.info("chat.stream.complete user={s} session={s} chat_ms={d} sse_ms={d} total_ms={d}", .{
            user_id,
            session_key,
            chat_duration_ms,
            sse_duration_ms,
            request_duration_ms,
        });
        return .{
            .status = "200 OK",
            .body = sse,
            .content_type = "text/event-stream; charset=utf-8",
        };
    }

    if (std.mem.eql(u8, base_path, "/api/v1/chat/events")) {
        return .{
            .status = "500 Internal Server Error",
            .body = "{\"error\":\"chat_events_requires_streaming_path\"}",
        };
    }

    if (std.mem.eql(u8, base_path, "/api/v1/users/provision")) {
        if (!std.mem.eql(u8, method, "POST")) {
            return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
        }
        const body = extractBody(raw_request);
        const body_user_id = if (body) |b| jsonStringField(b, "user_id") else null;
        const user_id = resolveGatewayRequestUserId(state, extractZakiUserId(raw_request), body_user_id, false) catch |err| {
            return switch (err) {
                error.MissingUserId => .{ .status = "400 Bad Request", .body = "{\"error\":\"missing user_id\"}" },
                error.UserCellUserMismatch => .{ .status = "403 Forbidden", .body = "{\"error\":\"wrong_user_cell\"}" },
            };
        };
        if (state.role == .broker) {
            prepareBrokerUserForRouting(req_allocator, state, user_id) catch |err| {
                if (isIdentityUserNotFound(err)) {
                    return .{ .status = "404 Not Found", .body = "{\"error\":\"unknown_user_id\"}" };
                }
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state_provisioning_failed\"}" };
            };
            const target = extractRequestTarget(raw_request) orelse base_path;
            return brokerProxyApiRequest(
                req_allocator,
                state,
                raw_request,
                method,
                target,
                user_id,
                "application/json",
                "30",
            );
        }

        var user_ctx = resolveUserContext(req_allocator, state, user_id) catch {
            return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
        };
        defer user_ctx.deinit(req_allocator);
        var prep_guard = state.user_preparation_gate.acquire(user_ctx.user_id) catch {
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"user preparation gate failed\"}" };
        };
        defer prep_guard.deinit();
        ensureUserDirectories(&user_ctx) catch {
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"workspace_bootstrap_failed\"}" };
        };
        ensureUserProvisioned(state, &user_ctx) catch |err| {
            if (isIdentityUserNotFound(err)) {
                return .{ .status = "404 Not Found", .body = "{\"error\":\"unknown_user_id\"}" };
            }
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state_provisioning_failed\"}" };
        };
        scaffoldUserWorkspace(req_allocator, &user_ctx);
        prep_guard.release();
        return .{ .body = "{\"status\":\"provisioned\"}" };
    }

    const parsed = parseUserPath(base_path) orelse
        return .{ .status = "404 Not Found", .body = "{\"error\":\"not found\"}" };
    const scoped_user_id = resolveGatewayPathUserId(state, parsed.user_id) catch |err| {
        return switch (err) {
            error.MissingUserId => .{ .status = "400 Bad Request", .body = "{\"error\":\"missing user_id\"}" },
            error.UserCellUserMismatch => .{ .status = "403 Forbidden", .body = "{\"error\":\"wrong_user_cell\"}" },
        };
    };
    if (state.role == .broker) {
        prepareBrokerUserForRouting(req_allocator, state, scoped_user_id) catch |err| {
            if (isIdentityUserNotFound(err)) {
                return .{ .status = "404 Not Found", .body = "{\"error\":\"unknown_user_id\"}" };
            }
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state_provisioning_failed\"}" };
        };
        const target = extractRequestTarget(raw_request) orelse base_path;
        return brokerProxyApiRequest(
            req_allocator,
            state,
            raw_request,
            method,
            target,
            scoped_user_id,
            "application/json",
            "30",
        );
    }

    var user_ctx = resolveUserContext(req_allocator, state, scoped_user_id) catch {
        return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
    };
    defer user_ctx.deinit(req_allocator);
    var prep_guard = state.user_preparation_gate.acquire(user_ctx.user_id) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"user preparation gate failed\"}" };
    };
    defer prep_guard.deinit();
    ensureUserDirectories(&user_ctx) catch {
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"workspace_bootstrap_failed\"}" };
    };
    ensureUserProvisioned(state, &user_ctx) catch |err| {
        if (isIdentityUserNotFound(err)) {
            return .{ .status = "404 Not Found", .body = "{\"error\":\"unknown_user_id\"}" };
        }
        return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state_provisioning_failed\"}" };
    };
    scaffoldUserWorkspace(req_allocator, &user_ctx);
    prep_guard.release();
    const raw_config_write_attempt = std.mem.eql(u8, parsed.subpath, "config") and !std.mem.eql(u8, method, "GET");
    const needs_write_lock = !std.mem.eql(u8, method, "GET") and !raw_config_write_attempt;
    var user_write_lock: ?OwnershipLockAcquireResult = null;
    if (needs_write_lock) {
        var acquired = maybeAcquireTenantOwnershipLock(req_allocator, state, user_ctx.user_id, user_ctx.user_root) catch {
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"tenant ownership lock failed\"}" };
        };
        switch (acquired) {
            .disabled => {},
            .acquired => {},
            .conflict => |*conflict| {
                recordTenantLockConflict(state, .api);
                defer acquired.deinit();
                return ownershipLockConflictJsonRouteResponse(req_allocator, conflict);
            },
        }
        user_write_lock = acquired;
    }
    defer if (user_write_lock) |*lock| lock.deinit();

    if (std.mem.eql(u8, parsed.subpath, "onboarding")) {
        if (std.mem.eql(u8, method, "GET")) {
            var onboarding_content: []u8 = undefined;
            if (state.zaki_state) |mgr| {
                const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
                onboarding_content = mgr.getOnboardingJson(req_allocator, user_id) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"read failed\"}" };
                };
            } else {
                const onboarding_path = onboardingStatePath(req_allocator, user_ctx.user_root) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"path failed\"}" };
                };
                defer req_allocator.free(onboarding_path);
                onboarding_content = readFileOrDefault(req_allocator, onboarding_path, "{\"completed\":false,\"completed_at_s\":null}\n") catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"read failed\"}" };
                };
            }
            defer req_allocator.free(onboarding_content);
            const summary = parseOnboardingStateSummary(onboarding_content);
            var telegram_readiness = NormalizedTelegramReadiness{};
            defer telegram_readiness.deinit(req_allocator);
            if (build_options.enable_channel_telegram) {
                telegram_readiness = loadNormalizedTelegramReadiness(req_allocator, state, scoped_user_id, &user_ctx) catch .{};
            }
            const heartbeat_enabled_normalized = loadNormalizedHeartbeatEnabled(req_allocator, state, scoped_user_id, user_ctx.heartbeat_path);
            const setup = buildOnboardingSetupResponse(
                req_allocator,
                scoped_user_id,
                summary,
                telegram_readiness,
                heartbeat_enabled_normalized,
                config_opt,
            ) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            };
            return .{ .body = setup };
        }

        if (std.mem.eql(u8, method, "PUT")) {
            const body = extractBody(raw_request) orelse "{}";
            if (jsonStringField(body, "bootstrap")) |value| {
                const p = workspaceFilePath(req_allocator, user_ctx.workspace_path, "BOOTSTRAP.md") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"path failed\"}" };
                defer req_allocator.free(p);
                writeFile(p, value) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
            }
            if (jsonStringField(body, "identity")) |value| {
                const p = workspaceFilePath(req_allocator, user_ctx.workspace_path, "IDENTITY.md") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"path failed\"}" };
                defer req_allocator.free(p);
                writeFile(p, value) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
            }
            if (jsonStringField(body, "user")) |value| {
                const p = workspaceFilePath(req_allocator, user_ctx.workspace_path, "USER.md") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"path failed\"}" };
                defer req_allocator.free(p);
                writeFile(p, value) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
            }
            if (jsonStringField(body, "soul")) |value| {
                const p = workspaceFilePath(req_allocator, user_ctx.workspace_path, "SOUL.md") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"path failed\"}" };
                defer req_allocator.free(p);
                writeFile(p, value) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
            }
            if (jsonStringField(body, "heartbeat")) |value| {
                const p = workspaceFilePath(req_allocator, user_ctx.workspace_path, "HEARTBEAT.md") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"path failed\"}" };
                defer req_allocator.free(p);
                writeFile(p, value) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
            }

            const completed = jsonBoolField(body, "completed") orelse false;
            const completed_at_s = if (completed) std.time.timestamp() else @as(i64, 0);
            if (completed) {
                const bootstrap_path = workspaceFilePath(req_allocator, user_ctx.workspace_path, "BOOTSTRAP.md") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"path failed\"}" };
                defer req_allocator.free(bootstrap_path);
                std.fs.deleteFileAbsolute(bootstrap_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"delete failed\"}" },
                };
            }

            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(req_allocator);
            const w = out.writer(req_allocator);
            w.writeAll("{\"completed\":") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            w.writeAll(if (completed) "true" else "false") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            w.writeAll(",\"completed_at_s\":") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            if (completed) {
                w.print("{d}", .{completed_at_s}) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            } else {
                w.writeAll("null") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            }
            w.writeAll("}") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            if (state.zaki_state) |mgr| {
                const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
                mgr.putOnboardingJson(user_id, out.items) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
                };
            } else {
                const onboarding_path = onboardingStatePath(req_allocator, user_ctx.user_root) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"path failed\"}" };
                };
                defer req_allocator.free(onboarding_path);
                writeFile(onboarding_path, out.items) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
                };
            }
            return .{ .body = out.toOwnedSlice(req_allocator) catch "{\"status\":\"updated\"}" };
        }

        return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
    }

    if (std.mem.eql(u8, parsed.subpath, "config")) {
        if (std.mem.eql(u8, method, "GET")) {
            const raw_content = if (state.zaki_state) |mgr| blk: {
                const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
                break :blk mgr.getConfigJson(req_allocator, user_id) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"read failed\"}" };
                };
            } else blk: {
                break :blk readFileOrDefault(req_allocator, user_ctx.config_path, "{}\n") catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"read failed\"}" };
                };
            };
            defer req_allocator.free(raw_content);
            const normalized = user_settings.normalizeTenantConfigJson(req_allocator, raw_content) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"normalize failed\"}" };
            };
            return .{ .body = normalized.json };
        }
        if (std.mem.eql(u8, method, "PATCH") or std.mem.eql(u8, method, "PUT")) {
            return .{ .status = "403 Forbidden", .body = "{\"error\":\"raw_config_writes_disabled\"}" };
        }
        return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
    }

    if (std.mem.eql(u8, parsed.subpath, "settings")) {
        const existing_config = if (state.zaki_state) |mgr| blk: {
            const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
            break :blk mgr.getConfigJson(req_allocator, user_id) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"read failed\"}" };
            };
        } else blk: {
            break :blk readFileOrDefault(req_allocator, user_ctx.config_path, "{}\n") catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"read failed\"}" };
            };
        };
        defer req_allocator.free(existing_config);

        if (std.mem.eql(u8, method, "GET")) {
            const settings = user_settings.resolveSettingsFromConfigJson(req_allocator, existing_config) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"settings resolution failed\"}" };
            };
            const body = user_settings.renderSettingsJson(req_allocator, settings) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            };
            return .{ .body = body };
        }

        if (std.mem.eql(u8, method, "PATCH") or std.mem.eql(u8, method, "PUT")) {
            const body = extractBody(raw_request) orelse "{}";
            const base_settings = user_settings.resolveSettingsFromConfigJson(req_allocator, existing_config) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"settings resolution failed\"}" };
            };
            const updated_settings = user_settings.applyPatchToSettingsJson(req_allocator, base_settings, body) catch |err| {
                const code = user_settings.errorCode(err);
                const err_body = std.fmt.allocPrint(req_allocator, "{{\"error\":\"{s}\"}}", .{code}) catch "{\"error\":\"invalid_payload\"}";
                return .{ .status = "400 Bad Request", .body = err_body };
            };
            const merged = user_settings.mergeSettingsIntoConfigJson(req_allocator, existing_config, updated_settings) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"merge failed\"}" };
            };
            defer req_allocator.free(merged);
            writeUserConfigJson(state, &user_ctx, scoped_user_id, merged) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
            };
            removeTenantRuntime(state, scoped_user_id);
            const response = user_settings.renderSettingsJson(req_allocator, updated_settings) catch "{\"status\":\"updated\"}";
            return .{ .body = response };
        }

        return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
    }

    if (std.mem.eql(u8, parsed.subpath, "heartbeat")) {
        if (std.mem.eql(u8, method, "GET")) {
            const enabled = loadNormalizedHeartbeatEnabled(req_allocator, state, scoped_user_id, user_ctx.heartbeat_path);
            const canonical_body = canonicalHeartbeatEnabledJson(req_allocator, enabled) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            };
            return .{ .body = canonical_body };
        }
        if (std.mem.eql(u8, method, "PUT")) {
            const body = extractBody(raw_request) orelse "{}\n";
            const enabled = jsonBoolField(body, "enabled") orelse return .{
                .status = "400 Bad Request",
                .body = "{\"error\":\"missing enabled\"}",
            };
            const canonical_body = writeHeartbeatEnabledForUser(req_allocator, state, &user_ctx, scoped_user_id, enabled) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
            };
            removeTenantRuntime(state, scoped_user_id);
            return .{ .body = canonical_body };
        }
        return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
    }

    if (std.mem.eql(u8, parsed.subpath, "cron")) {
        if (std.mem.eql(u8, method, "GET")) {
            if (state.zaki_state) |mgr| {
                const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
                const content = mgr.getJobsJson(req_allocator, user_id) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"read failed\"}" };
                };
                return .{ .body = content };
            }
            const content = readFileOrDefault(req_allocator, user_ctx.cron_path, "[]\n") catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"read failed\"}" };
            };
            return .{ .body = content };
        }
        if (std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "PATCH") or std.mem.eql(u8, method, "PUT")) {
            const body = extractBody(raw_request) orelse "[]\n";
            if (state.zaki_state) |mgr| {
                const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
                mgr.replaceJobsJson(user_id, "main", body) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
                };
            } else {
                writeFile(user_ctx.cron_path, body) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
                };
            }
            return .{ .body = "{\"status\":\"updated\"}" };
        }
        if (std.mem.eql(u8, method, "DELETE")) {
            if (state.zaki_state) |mgr| {
                const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
                mgr.clearJobs(user_id) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
                };
            } else {
                writeFile(user_ctx.cron_path, "[]\n") catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
                };
            }
            return .{ .body = "{\"status\":\"deleted\"}" };
        }
        return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
    }

    if (std.mem.startsWith(u8, parsed.subpath, "secrets/")) {
        const secret_key = parsed.subpath["secrets/".len..];
        const secret_path = resolveSecretPath(req_allocator, user_ctx.secrets_dir, secret_key) catch {
            return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid secret key\"}" };
        };
        defer req_allocator.free(secret_path);

        if (std.mem.eql(u8, method, "GET")) {
            var owned_secret: ?[]u8 = null;
            defer if (owned_secret) |v| req_allocator.free(v);
            const value_text: []const u8 = if (state.zaki_state) |mgr| blk: {
                const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
                const secret_value = mgr.getSecret(req_allocator, user_id, secret_key) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"read failed\"}" };
                };
                if (secret_value) |v| {
                    owned_secret = v;
                    break :blk v;
                }
                break :blk "";
            } else blk: {
                break :blk readFileOrDefault(req_allocator, secret_path, "") catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"read failed\"}" };
                };
            };
            if (value_text.len == 0) return .{ .status = "404 Not Found", .body = "{\"error\":\"secret not found\"}" };
            var resp: std.ArrayListUnmanaged(u8) = .empty;
            defer resp.deinit(req_allocator);
            const w = resp.writer(req_allocator);
            w.print("{{\"key\":\"{s}\",\"value\":\"", .{secret_key}) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            jsonEscapeInto(w, value_text) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            w.writeAll("\"}") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            return .{ .body = resp.toOwnedSlice(req_allocator) catch "{\"error\":\"response build failed\"}" };
        }
        if (std.mem.eql(u8, method, "PUT")) {
            const body = extractBody(raw_request) orelse return .{ .status = "400 Bad Request", .body = "{\"error\":\"missing body\"}" };
            const value = jsonStringField(body, "value") orelse body;
            if (std.mem.eql(u8, secret_key, "telegram_bot_token")) {
                const normalized = normalizeTelegramBotToken(value);
                if (!isLikelyTelegramBotToken(normalized)) {
                    return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid telegram bot token\"}" };
                }
            }
            if (state.zaki_state) |mgr| {
                const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
                const write_value = if (std.mem.eql(u8, secret_key, "telegram_bot_token"))
                    normalizeTelegramBotToken(value)
                else
                    value;
                mgr.putSecret(user_id, secret_key, write_value) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
                };
            } else {
                const write_value = if (std.mem.eql(u8, secret_key, "telegram_bot_token"))
                    normalizeTelegramBotToken(value)
                else
                    value;
                writeFile(secret_path, write_value) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
                };
            }
            return .{ .body = "{\"status\":\"updated\"}" };
        }
        if (std.mem.eql(u8, method, "DELETE")) {
            if (state.zaki_state) |mgr| {
                const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
                const deleted = mgr.deleteSecret(user_id, secret_key) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"delete failed\"}" };
                };
                if (!deleted) return .{ .status = "404 Not Found", .body = "{\"error\":\"secret not found\"}" };
            } else {
                std.fs.deleteFileAbsolute(secret_path) catch |err| switch (err) {
                    error.FileNotFound => return .{ .status = "404 Not Found", .body = "{\"error\":\"secret not found\"}" },
                    else => return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"delete failed\"}" },
                };
            }
            return .{ .body = "{\"status\":\"deleted\"}" };
        }
        return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
    }

    if (parseUserChannelBindingsSubpath(parsed.subpath)) |bindings_path| {
        const mgr = state.zaki_state orelse return .{
            .status = "501 Not Implemented",
            .body = "{\"error\":\"state backend does not support channel bindings\"}",
        };
        const user_id_numeric = parseNumericUserId(scoped_user_id) catch return .{
            .status = "400 Bad Request",
            .body = "{\"error\":\"invalid user\"}",
        };

        if (std.mem.eql(u8, method, "GET")) {
            if (bindings_path.binding_id != null) {
                return .{ .status = "400 Bad Request", .body = "{\"error\":\"GET requires bindings collection path\"}" };
            }
            const bindings = mgr.listChannelIdentityBindings(req_allocator, user_id_numeric, bindings_path.channel) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"list bindings failed\"}" };
            };
            defer {
                for (bindings) |*entry| entry.deinit(req_allocator);
                req_allocator.free(bindings);
            }

            var resp: std.ArrayListUnmanaged(u8) = .empty;
            defer resp.deinit(req_allocator);
            const w = resp.writer(req_allocator);
            w.writeAll("{\"channel\":\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            jsonEscapeInto(w, bindings_path.channel) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            w.writeAll("\",\"items\":[") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            for (bindings, 0..) |entry, idx| {
                if (idx > 0) {
                    w.writeAll(",") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                }
                w.writeAll("{\"id\":\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                jsonEscapeInto(w, entry.id) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                w.writeAll("\",\"account_id\":\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                jsonEscapeInto(w, entry.account_id) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                w.writeAll("\",\"principal_key\":\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                jsonEscapeInto(w, entry.principal_key) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                w.writeAll("\",\"scope_key\":\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                jsonEscapeInto(w, entry.scope_key) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                w.writeAll("\",\"thread_key\":") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                if (entry.thread_key) |thread_key| {
                    w.writeAll("\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                    jsonEscapeInto(w, thread_key) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                    w.writeAll("\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                } else {
                    w.writeAll("null") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
                }
                w.writeAll("}") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            }
            w.writeAll("]}") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            return .{ .body = resp.toOwnedSlice(req_allocator) catch "{\"error\":\"response build failed\"}" };
        }

        if (std.mem.eql(u8, method, "POST")) {
            if (bindings_path.binding_id != null) {
                return .{ .status = "400 Bad Request", .body = "{\"error\":\"POST requires bindings collection path\"}" };
            }
            const body = extractBody(raw_request) orelse return .{
                .status = "400 Bad Request",
                .body = "{\"error\":\"missing body\"}",
            };
            const account_id = jsonStringField(body, "account_id") orelse return .{
                .status = "400 Bad Request",
                .body = "{\"error\":\"missing account_id\"}",
            };
            const principal_key = jsonStringField(body, "principal_key") orelse return .{
                .status = "400 Bad Request",
                .body = "{\"error\":\"missing principal_key\"}",
            };
            const scope_key = jsonStringField(body, "scope_key") orelse return .{
                .status = "400 Bad Request",
                .body = "{\"error\":\"missing scope_key\"}",
            };
            const thread_key = jsonStringField(body, "thread_key");
            const peer_kind = jsonStringField(body, "peer_kind");
            const peer_id = jsonStringField(body, "peer_id");
            const metadata_json = jsonStringField(body, "metadata_json") orelse "{}";
            if (account_id.len == 0 or principal_key.len == 0 or scope_key.len == 0) {
                return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid binding fields\"}" };
            }
            const binding_id = mgr.upsertChannelIdentityBinding(
                req_allocator,
                user_id_numeric,
                bindings_path.channel,
                account_id,
                principal_key,
                scope_key,
                thread_key,
                peer_kind,
                peer_id,
                metadata_json,
            ) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"upsert binding failed\"}" };
            };
            defer req_allocator.free(binding_id);
            inbound_canonicalizer.invalidateCacheForIdentity(.{
                .channel = bindings_path.channel,
                .account_id = account_id,
                .principal_key = principal_key,
                .scope_key = scope_key,
                .thread_key = thread_key,
                .fallback_session_key = "",
            });

            var resp: std.ArrayListUnmanaged(u8) = .empty;
            defer resp.deinit(req_allocator);
            const rw = resp.writer(req_allocator);
            rw.writeAll("{\"status\":\"upserted\",\"id\":\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            jsonEscapeInto(rw, binding_id) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            rw.writeAll("\"}") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
            return .{ .body = resp.toOwnedSlice(req_allocator) catch "{\"error\":\"response build failed\"}" };
        }

        if (std.mem.eql(u8, method, "DELETE")) {
            const binding_id = bindings_path.binding_id orelse return .{
                .status = "400 Bad Request",
                .body = "{\"error\":\"DELETE requires binding id\"}",
            };
            const deleted = mgr.deleteChannelIdentityBinding(user_id_numeric, binding_id) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"delete binding failed\"}" };
            };
            if (!deleted) return .{ .status = "404 Not Found", .body = "{\"error\":\"binding not found\"}" };
            inbound_canonicalizer.invalidateAllCache();
            return .{ .body = "{\"status\":\"deleted\"}" };
        }

        return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
    }

    if (std.mem.eql(u8, parsed.subpath, "channels/telegram/connect")) {
        if (!std.mem.eql(u8, method, "POST")) {
            return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
        }
        const body = extractBody(raw_request) orelse "{}";
        const secret_path = resolveSecretPath(req_allocator, user_ctx.secrets_dir, "telegram_bot_token") catch {
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"secret path failed\"}" };
        };
        defer req_allocator.free(secret_path);
        const allow_from_override = jsonStringArrayFieldOwned(req_allocator, body, "allow_from");
        defer if (allow_from_override) |arr| {
            if (arr.len > 0) freeOwnedStringArray(req_allocator, arr);
        };

        const input_bot_token = jsonStringField(body, "bot_token");
        if (input_bot_token) |tok| {
            const normalized_tok = normalizeTelegramBotToken(tok);
            if (!isLikelyTelegramBotToken(normalized_tok)) {
                return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid bot_token\"}" };
            }
            if (state.zaki_state) |mgr| {
                const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
                mgr.putSecret(user_id, "telegram_bot_token", normalized_tok) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"failed storing bot token\"}" };
                };
                // Best-effort local fallback sync for degraded/local tenant runtime reads.
                _ = syncTelegramSecretFallbackBestEffort(secret_path, normalized_tok);
            } else {
                writeFile(secret_path, normalized_tok) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"failed storing bot token\"}" };
                };
            }
        }
        const bot_token_raw = readTrimmedSecretFile(req_allocator, secret_path) catch {
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"failed reading bot token\"}" };
        };
        defer if (state.zaki_state != null and bot_token_raw.len > 0) req_allocator.free(bot_token_raw);
        const bot_token = normalizeTelegramBotToken(bot_token_raw);
        if (bot_token.len == 0) {
            return .{ .status = "400 Bad Request", .body = "{\"error\":\"missing bot_token\"}" };
        }
        if (!isLikelyTelegramBotToken(bot_token)) {
            return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid bot_token\"}" };
        }
        const account_id = jsonStringField(body, "account_id") orelse state.telegram_account_id;
        if (!isValidIdentifier(account_id)) {
            return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid account_id\"}" };
        }
        const allow_from: []const []const u8 = if (allow_from_override) |items|
            items
        else if (state.telegram_allow_from.len > 0)
            state.telegram_allow_from
        else
            &.{};

        const webhook_url = blk: {
            if (jsonStringField(body, "webhook_url")) |url| break :blk req_allocator.dupe(u8, url) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"alloc failed\"}" };
            };
            if (jsonStringField(body, "webhook_base_url")) |base_url| {
                break :blk buildWebhookUrlForUser(req_allocator, base_url, scoped_user_id) catch {
                    return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid webhook_base_url (https required)\"}" };
                };
            }
            if (extractHeader(raw_request, "X-Webhook-Base-Url")) |base_header| {
                break :blk buildWebhookUrlForUser(req_allocator, std.mem.trim(u8, base_header, " \t\r\n"), scoped_user_id) catch {
                    return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid X-Webhook-Base-Url (https required)\"}" };
                };
            }
            return .{ .status = "400 Bad Request", .body = "{\"error\":\"missing webhook_url or webhook_base_url\"}" };
        };
        defer req_allocator.free(webhook_url);
        if (!std.mem.startsWith(u8, webhook_url, "https://")) {
            return .{ .status = "400 Bad Request", .body = "{\"error\":\"webhook_url must use https\"}" };
        }

        const webhook_secret_token = blk: {
            if (jsonStringField(body, "webhook_secret_token")) |provided| {
                const normalized = normalizeTelegramSecretToken(provided);
                if (normalized.len >= 8) break :blk req_allocator.dupe(u8, normalized) catch {
                    return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"alloc failed\"}" };
                };
            }
            break :blk generateWebhookSecretToken(req_allocator) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"secret generation failed\"}" };
            };
        };
        defer req_allocator.free(webhook_secret_token);

        const drop_pending_updates = jsonBoolField(body, "drop_pending_updates") orelse false;
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(req_allocator);
        const pw = payload.writer(req_allocator);
        pw.writeAll("{\"url\":\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"payload build failed\"}" };
        jsonEscapeInto(pw, webhook_url) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"payload build failed\"}" };
        pw.writeAll("\",\"secret_token\":\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"payload build failed\"}" };
        jsonEscapeInto(pw, webhook_secret_token) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"payload build failed\"}" };
        pw.print("\",\"drop_pending_updates\":{s}}}", .{if (drop_pending_updates) "true" else "false"}) catch {
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"payload build failed\"}" };
        };

        const set_webhook_resp = telegramApiCall(req_allocator, bot_token, "setWebhook", payload.items) catch {
            return .{ .status = "502 Bad Gateway", .body = "{\"error\":\"telegram setWebhook request failed\"}" };
        };
        if (!(jsonBoolField(set_webhook_resp, "ok") orelse false)) {
            return .{ .status = "502 Bad Gateway", .body = "{\"error\":\"telegram setWebhook rejected\"}" };
        }

        const get_webhook_resp = telegramApiCall(req_allocator, bot_token, "getWebhookInfo", "{}") catch {
            return .{ .status = "502 Bad Gateway", .body = "{\"error\":\"telegram getWebhookInfo request failed\"}" };
        };
        if (!(jsonBoolField(get_webhook_resp, "ok") orelse false)) {
            return .{ .status = "502 Bad Gateway", .body = "{\"error\":\"telegram getWebhookInfo rejected\"}" };
        }
        if (jsonStringField(get_webhook_resp, "url")) |actual_url| {
            if (!std.mem.eql(u8, std.mem.trim(u8, actual_url, " \t\r\n"), webhook_url)) {
                return .{ .status = "502 Bad Gateway", .body = "{\"error\":\"telegram webhook url mismatch after connect\"}" };
            }
        }

        var state_payload: std.ArrayListUnmanaged(u8) = .empty;
        defer state_payload.deinit(req_allocator);
        const sw = state_payload.writer(req_allocator);
        sw.writeAll("{\"connected\":true,\"webhook_url\":\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state build failed\"}" };
        jsonEscapeInto(sw, webhook_url) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state build failed\"}" };
        sw.writeAll("\",\"webhook_secret_token\":\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state build failed\"}" };
        jsonEscapeInto(sw, webhook_secret_token) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state build failed\"}" };
        sw.writeAll("\",\"account_id\":\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state build failed\"}" };
        jsonEscapeInto(sw, account_id) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state build failed\"}" };
        sw.writeAll("\",\"allow_from\":") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state build failed\"}" };
        jsonWriteStringArray(sw, allow_from) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state build failed\"}" };
        sw.print(",\"connected_at\":{d}}}", .{std.time.timestamp()}) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"state build failed\"}" };
        if (state.zaki_state) |mgr| {
            const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
            mgr.putTelegramStateJson(user_id, state_payload.items) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
            };
            // Best-effort local fallback sync for degraded/local tenant runtime reads.
            _ = syncTelegramStateFallbackBestEffort(user_ctx.telegram_path, state_payload.items);
        } else {
            writeTelegramFallbackStateFile(user_ctx.telegram_path, state_payload.items) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"write failed\"}" };
            };
        }

        var resp: std.ArrayListUnmanaged(u8) = .empty;
        defer resp.deinit(req_allocator);
        const rw = resp.writer(req_allocator);
        rw.writeAll("{\"status\":\"connected\",\"webhook_url\":\"") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
        jsonEscapeInto(rw, webhook_url) catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
        rw.writeAll("\",\"channel\":\"telegram\"}") catch return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"response build failed\"}" };
        return .{ .body = resp.toOwnedSlice(req_allocator) catch "{\"status\":\"connected\"}" };
    }

    if (std.mem.eql(u8, parsed.subpath, "channels/telegram/disconnect")) {
        const method_allowed = std.mem.eql(u8, method, "DELETE") or std.mem.eql(u8, method, "POST");
        if (!method_allowed) {
            return .{ .status = "405 Method Not Allowed", .body = "{\"error\":\"method not allowed\"}" };
        }
        const body = extractBody(raw_request) orelse "{}";
        const secret_path = resolveSecretPath(req_allocator, user_ctx.secrets_dir, "telegram_bot_token") catch {
            return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"secret path failed\"}" };
        };
        defer req_allocator.free(secret_path);
        const body_bot_token = jsonStringField(body, "bot_token");
        const stored_bot_token = if (state.zaki_state) |mgr| blk: {
            const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
            const secret_value = mgr.getSecret(req_allocator, user_id, "telegram_bot_token") catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"failed reading bot token\"}" };
            };
            break :blk secret_value orelse "";
        } else blk: {
            break :blk readFileOrDefault(req_allocator, secret_path, "") catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"failed reading bot token\"}" };
            };
        };
        defer if (state.zaki_state != null and stored_bot_token.len > 0 and body_bot_token == null) req_allocator.free(stored_bot_token);
        const token_raw = body_bot_token orelse stored_bot_token;
        const bot_token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (bot_token.len > 0) {
            const drop_pending_updates = jsonBoolField(body, "drop_pending_updates") orelse false;
            const delete_payload = if (drop_pending_updates)
                "{\"drop_pending_updates\":true}"
            else
                "{\"drop_pending_updates\":false}";
            const delete_resp = telegramApiCall(req_allocator, bot_token, "deleteWebhook", delete_payload) catch {
                return .{ .status = "502 Bad Gateway", .body = "{\"error\":\"telegram deleteWebhook request failed\"}" };
            };
            if (!(jsonBoolField(delete_resp, "ok") orelse false)) {
                return .{ .status = "502 Bad Gateway", .body = "{\"error\":\"telegram deleteWebhook rejected\"}" };
            }
        }

        if (state.zaki_state) |mgr| {
            const user_id = parseNumericUserId(scoped_user_id) catch return .{ .status = "400 Bad Request", .body = "{\"error\":\"invalid user\"}" };
            mgr.deleteTelegramState(user_id) catch {
                return .{ .status = "500 Internal Server Error", .body = "{\"error\":\"disconnect failed\"}" };
            };
            _ = deleteTelegramFallbackFilesBestEffort(user_ctx.telegram_path, user_ctx.channel_state_path);
        } else {
            deleteTelegramFallbackFiles(user_ctx.telegram_path, user_ctx.channel_state_path) catch |err| {
                return .{ .status = "500 Internal Server Error", .body = switch (err) {
                    else => "{\"error\":\"disconnect failed\"}",
                } };
            };
        }
        return .{ .body = "{\"status\":\"disconnected\",\"channel\":\"telegram\"}" };
    }

    return .{ .status = "404 Not Found", .body = "{\"error\":\"not found\"}" };
}

const WebhookHandlerContext = struct {
    root_allocator: std.mem.Allocator,
    req_allocator: std.mem.Allocator,
    raw_request: []const u8,
    method: []const u8,
    target: []const u8,
    config_opt: ?*const Config,
    state: *GatewayState,
    session_mgr_opt: ?*session_mod.SessionManager,
    response_status: []const u8 = "200 OK",
    response_body: []const u8 = "",
    response_retry_after_secs: ?u16 = null,
};

const WebhookHandlerFn = *const fn (ctx: *WebhookHandlerContext) void;

const WebhookRouteDescriptor = struct {
    path: []const u8,
    handler: WebhookHandlerFn,
};

const webhook_route_descriptors = [_]WebhookRouteDescriptor{
    .{ .path = "/telegram", .handler = handleTelegramWebhookRoute },
    .{ .path = "/webhook/telegram", .handler = handleTelegramWebhookRoute },
    .{ .path = "/whatsapp", .handler = handleWhatsAppWebhookRoute },
    .{ .path = "/slack/events", .handler = handleSlackWebhookRoute },
    .{ .path = "/line", .handler = handleLineWebhookRoute },
    .{ .path = "/lark", .handler = handleLarkWebhookRoute },
};

fn findWebhookRouteDescriptor(path: []const u8) ?*const WebhookRouteDescriptor {
    for (&webhook_route_descriptors) |*desc| {
        if (std.mem.eql(u8, desc.path, path)) return desc;
    }
    return null;
}

fn handleTelegramWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_telegram) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"telegram channel disabled in this build\"}";
        return;
    }

    const is_post = std.mem.eql(u8, ctx.method, "POST");
    if (!is_post) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }

    var webhook_key_buf: [160]u8 = undefined;
    var webhook_rate_key: []const u8 = "telegram";
    if (ctx.state.tenant_enabled) {
        if (parseQueryParam(ctx.target, "user_id")) |user_id| {
            if (isValidIdentifier(user_id)) {
                webhook_rate_key = std.fmt.bufPrint(&webhook_key_buf, "telegram:{s}", .{user_id}) catch "telegram";
            }
        }
    }

    if (!ctx.state.rate_limiter.allowWebhook(ctx.state.allocator, webhook_rate_key)) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }
    _ = ctx.state.telegram_webhook_total.fetchAdd(1, .monotonic);

    const body = extractBody(ctx.raw_request);
    if (body) |b| {
        var tg_bot_token = ctx.state.telegram_bot_token;
        var tg_allow_from = ctx.state.telegram_allow_from;
        var tg_account_id = ctx.state.telegram_account_id;
        var tg_webhook_secret_token = ctx.state.telegram_webhook_secret_token;
        var tg_bot_token_owned: ?[]const u8 = null;
        var tg_proxy: ?[]const u8 = null;
        var scoped_user_id: ?[]const u8 = null;
        var use_shared_main = false;
        var tenant_channel_state_path: ?[]const u8 = null;
        var numeric_user_id_opt: ?i64 = null;
        defer if (tg_bot_token_owned) |tok| ctx.req_allocator.free(tok);
        defer if (tenant_channel_state_path) |p| ctx.req_allocator.free(p);
        var tenant_user_ctx: ?UserContext = null;
        defer if (tenant_user_ctx) |*value| value.deinit(ctx.req_allocator);
        if (selectTelegramConfig(ctx.config_opt, ctx.target)) |tg_cfg| {
            tg_bot_token = tg_cfg.bot_token;
            tg_allow_from = tg_cfg.allow_from;
            tg_account_id = tg_cfg.account_id;
            tg_webhook_secret_token = tg_cfg.webhook_secret_token orelse "";
            tg_proxy = tg_cfg.proxy;
        }

        if (ctx.state.tenant_enabled) {
            const user_id = parseQueryParam(ctx.target, "user_id") orelse {
                _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"missing user_id\"}";
                return;
            };
            if (!isValidIdentifier(user_id)) {
                _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"invalid user_id\"}";
                return;
            }
            scoped_user_id = user_id;
            use_shared_main = tenantTelegramUsesSharedMain(ctx.config_opt);

            tenant_user_ctx = resolveUserContext(ctx.req_allocator, ctx.state, user_id) catch {
                _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                ctx.response_status = "400 Bad Request";
                ctx.response_body = "{\"error\":\"invalid user\"}";
                return;
            };
            const user_ctx = &tenant_user_ctx.?;
            tenant_channel_state_path = ctx.req_allocator.dupe(u8, user_ctx.channel_state_path) catch null;
            const lock_wait_start_ms = std.time.milliTimestamp();
            var user_lock = maybeAcquireTenantOwnershipLock(ctx.req_allocator, ctx.state, user_ctx.user_id, user_ctx.user_root) catch |err| switch (err) {
                error.FileNotFound => {
                    _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                    ctx.response_status = "403 Forbidden";
                    ctx.response_body = "{\"error\":\"telegram user channel not connected\"}";
                    return;
                },
                else => {
                    _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                    ctx.response_status = "500 Internal Server Error";
                    ctx.response_body = "{\"error\":\"tenant ownership lock failed\"}";
                    return;
                },
            };
            const lock_wait_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - lock_wait_start_ms));
            log.info("telegram.webhook.stage stage=ownership_lock_wait user={s} duration_ms={d}", .{
                user_ctx.user_id,
                lock_wait_duration_ms,
            });
            defer user_lock.deinit();
            switch (user_lock) {
                .disabled => {},
                .acquired => {},
                .conflict => |*conflict| {
                    _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                    recordTenantLockConflict(ctx.state, .webhook);
                    ctx.response_status = "409 Conflict";
                    ctx.response_retry_after_secs = conflict.retryAfterSecs();
                    ctx.response_body = ownershipLockConflictJsonPayload(ctx.req_allocator, conflict) catch
                        "{\"error\":\"ownership_lock_conflict\",\"message\":\"user is active on another node, retry shortly\",\"retry_after_ms\":250,\"owner_instance_id\":null,\"lease_until_s\":null}";
                    return;
                },
            }

            const user_state = blk: {
                if (ctx.state.zaki_state) |mgr| {
                    const numeric_user_id = parseNumericUserId(user_id) catch {
                        _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                        ctx.response_status = "400 Bad Request";
                        ctx.response_body = "{\"error\":\"invalid user\"}";
                        return;
                    };
                    numeric_user_id_opt = numeric_user_id;
                    const raw_state = mgr.getTelegramStateJson(ctx.req_allocator, numeric_user_id) catch {
                        _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                        ctx.response_status = "403 Forbidden";
                        ctx.response_body = "{\"error\":\"telegram user channel not connected\"}";
                        return;
                    };
                    defer ctx.req_allocator.free(raw_state);
                    break :blk parseTelegramUserState(ctx.req_allocator, raw_state) catch {
                        _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                        ctx.response_status = "403 Forbidden";
                        ctx.response_body = "{\"error\":\"telegram user channel not connected\"}";
                        return;
                    };
                }
                break :blk loadTelegramUserState(ctx.req_allocator, user_ctx.telegram_path) catch {
                    _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                    ctx.response_status = "403 Forbidden";
                    ctx.response_body = "{\"error\":\"telegram user channel not connected\"}";
                    return;
                };
            };
            if (!user_state.connected) {
                _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"telegram user channel not connected\"}";
                return;
            }

            if (user_state.account_id) |account_id| {
                tg_account_id = account_id;
            }
            if (user_state.allow_from.len > 0) {
                tg_allow_from = user_state.allow_from;
            }
            if (user_state.webhook_secret_token) |secret| {
                tg_webhook_secret_token = secret;
            }

            const tenant_bot_token = resolveTenantTelegramBotTokenForSend(
                ctx.req_allocator,
                user_ctx,
                ctx.state.zaki_state,
                numeric_user_id_opt,
            ) catch {
                _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"missing telegram bot token\"}";
                return;
            };
            tg_bot_token_owned = tenant_bot_token;
            tg_bot_token = tenant_bot_token;

            if (tg_webhook_secret_token.len == 0) {
                _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"missing telegram secret token\"}";
                return;
            }
        }

        if (tg_webhook_secret_token.len > 0) {
            const header_token = extractHeader(ctx.raw_request, "X-Telegram-Bot-Api-Secret-Token") orelse {
                _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"missing telegram secret token\"}";
                return;
            };
            const expected_secret = normalizeTelegramSecretToken(tg_webhook_secret_token);
            const provided_secret = normalizeTelegramSecretToken(header_token);
            if (expected_secret.len == 0) {
                _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"missing telegram secret token\"}";
                return;
            }
            if (!std.mem.eql(u8, provided_secret, expected_secret)) {
                _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"invalid telegram secret token\"}";
                return;
            }
        }

        if (jsonIntField(b, "update_id")) |update_id| {
            if (ctx.state.zaki_state != null and scoped_user_id != null) {
                const numeric_user_id = parseNumericUserId(scoped_user_id.?) catch {
                    ctx.response_status = "400 Bad Request";
                    ctx.response_body = "{\"error\":\"invalid user\"}";
                    return;
                };
                const is_new = ctx.state.zaki_state.?.recordTelegramUpdate(numeric_user_id, update_id) catch {
                    ctx.response_status = "500 Internal Server Error";
                    ctx.response_body = "{\"error\":\"telegram update dedupe failed\"}";
                    return;
                };
                if (!is_new) {
                    ctx.response_body = "{\"status\":\"duplicate\"}";
                    return;
                }
            } else {
                var key_buf: [192]u8 = undefined;
                const dedupe_scope = if (scoped_user_id) |uid| uid else tg_account_id;
                const key = std.fmt.bufPrint(&key_buf, "telegram:update:{s}:{d}", .{ dedupe_scope, update_id }) catch "telegram:update:invalid";
                if (!ctx.state.idempotency.recordIfNew(ctx.state.allocator, key)) {
                    ctx.response_body = "{\"status\":\"duplicate\"}";
                    return;
                }
            }
        }

        var webhook_transcriber = if (ctx.config_opt) |cfg|
            buildTelegramWebhookTranscriber(ctx.req_allocator, cfg)
        else
            TelegramWebhookTranscriber{};
        defer webhook_transcriber.deinit(ctx.req_allocator);

        const msg_text = telegramWebhookExtractInboundText(
            ctx.req_allocator,
            b,
            tg_bot_token,
            webhook_transcriber.transcriber,
            tg_proxy,
        );
        defer if (msg_text) |mt| ctx.req_allocator.free(mt);
        const chat_id = telegramChatId(ctx.req_allocator, b);
        const tg_authorized = telegramSenderAllowed(ctx.req_allocator, tg_allow_from, b);
        if (!tg_authorized) {
            _ = ctx.state.telegram_webhook_rejected_total.fetchAdd(1, .monotonic);
            ctx.response_body = "{\"status\":\"unauthorized\"}";
            return;
        }

        if (msg_text != null and chat_id != null) {
            if (ctx.state.zaki_state != null and scoped_user_id != null) {
                const numeric_user_id = parseNumericUserId(scoped_user_id.?) catch {
                    ctx.response_status = "400 Bad Request";
                    ctx.response_body = "{\"error\":\"invalid user\"}";
                    return;
                };
                ctx.state.zaki_state.?.recordTelegramChat(numeric_user_id, tg_account_id, chat_id.?) catch {};
                if (tenant_channel_state_path) |state_path| {
                    writeTelegramChannelState(ctx.req_allocator, state_path, tg_account_id, chat_id.?) catch {};
                }
            } else if (tenant_channel_state_path) |state_path| {
                writeTelegramChannelState(ctx.req_allocator, state_path, tg_account_id, chat_id.?) catch {};
            }
            var sender_buf: [32]u8 = undefined;
            const sender = telegramSenderIdentity(ctx.req_allocator, b, &sender_buf);
            var cid_buf: [32]u8 = undefined;
            const cid_str = std.fmt.bufPrint(&cid_buf, "{d}", .{chat_id.?}) catch "0";
            const is_group = telegramChatIsGroup(ctx.req_allocator, b);
            const peer_kind = if (is_group) "group" else "direct";

            if (tenant_user_ctx != null) {
                const cfg = ctx.config_opt orelse {
                    ctx.response_status = "500 Internal Server Error";
                    ctx.response_body = "{\"error\":\"tenant config missing\"}";
                    return;
                };
                // Keep tenant Telegram webhook handling synchronous for deterministic
                // delivery. Async queueing can acknowledge webhooks while worker-side
                // failures silently drop replies.

                var kb: [256]u8 = undefined;
                var thread_buf: [32]u8 = undefined;
                var lane_buf: [64]u8 = undefined;
                const tg_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg_opt| cfg_opt else null;
                const lane_resolution = resolveTenantTelegramLane(
                    ctx.req_allocator,
                    tg_cfg_opt,
                    use_shared_main,
                    scoped_user_id.?,
                    tg_account_id,
                    chat_id.?,
                    b,
                    &kb,
                    &thread_buf,
                    &lane_buf,
                );
                const fallback_session_key = lane_resolution.fallback_session_key;
                var identity_keys = channel_identity_key.build(
                    ctx.req_allocator,
                    "telegram",
                    sender,
                    cid_str,
                    lane_resolution.canonical_thread_key,
                ) catch {
                    ctx.response_status = "400 Bad Request";
                    ctx.response_body = "{\"error\":\"invalid telegram identity\"}";
                    return;
                };
                defer identity_keys.deinit(ctx.req_allocator);

                if (ctx.state.zaki_state != null and scoped_user_id != null and !is_group) {
                    const user_id_numeric = numeric_user_id_opt orelse parseNumericUserId(scoped_user_id.?) catch {
                        ctx.response_status = "400 Bad Request";
                        ctx.response_body = "{\"error\":\"invalid user\"}";
                        return;
                    };
                    const upsert_binding = ctx.state.zaki_state.?.upsertChannelIdentityBinding(
                        ctx.req_allocator,
                        user_id_numeric,
                        "telegram",
                        tg_account_id,
                        identity_keys.principal_key,
                        identity_keys.scope_key,
                        identity_keys.thread_key,
                        peer_kind,
                        cid_str,
                        "{\"source\":\"telegram_webhook\"}",
                    );
                    if (upsert_binding) |binding_id| {
                        ctx.req_allocator.free(binding_id);
                    } else |err| {
                        log.warn("telegram binding upsert failed: {}", .{err});
                    }
                    inbound_canonicalizer.invalidateCacheForIdentity(.{
                        .channel = "telegram",
                        .account_id = tg_account_id,
                        .principal_key = identity_keys.principal_key,
                        .scope_key = identity_keys.scope_key,
                        .thread_key = identity_keys.thread_key,
                        .fallback_session_key = "",
                    });
                }

                const canonicalize_start_ms = std.time.milliTimestamp();
                var canonical_decision = inbound_canonicalizer.canonicalizeInboundTurn(
                    ctx.req_allocator,
                    ctx.state.zaki_state,
                    cfg,
                    .{
                        .channel = "telegram",
                        .account_id = tg_account_id,
                        .principal_key = identity_keys.principal_key,
                        .scope_key = identity_keys.scope_key,
                        .thread_key = identity_keys.thread_key,
                        .fallback_session_key = fallback_session_key,
                        .lane = lane_resolution.lane,
                    },
                ) catch |err| {
                    log.warn("telegram canonicalization failed: {}", .{err});
                    ctx.response_status = "500 Internal Server Error";
                    ctx.response_body = "{\"error\":\"canonicalization_failed\"}";
                    return;
                };
                const canonicalize_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - canonicalize_start_ms));
                log.info("telegram.webhook.stage stage=canonicalization user={s} duration_ms={d} lane={s} decision={s}", .{
                    scoped_user_id.?,
                    canonicalize_duration_ms,
                    switch (lane_resolution.lane) {
                        .main => "main",
                        .thread => "thread",
                        .task => "task",
                        .cron => "cron",
                    },
                    switch (canonical_decision.kind) {
                        .canonical => "canonical",
                        .degraded_compat => "degraded_compat",
                        .strict_reject => "strict_reject",
                    },
                });
                defer canonical_decision.deinit(ctx.req_allocator);

                const sk = blk: {
                    switch (canonical_decision.kind) {
                        .strict_reject => {
                            const send_start_ms = std.time.milliTimestamp();
                            sendTelegramReply(
                                ctx.req_allocator,
                                tg_bot_token,
                                chat_id.?,
                                "This Telegram chat is not mapped to your tenant user yet. Reconnect Telegram from the app, then retry.",
                            ) catch |err| {
                                log.warn("telegram strict reject reply send failed: {}", .{err});
                            };
                            const send_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - send_start_ms));
                            log.info("telegram.webhook.stage stage=telegram_send user={s} duration_ms={d} path=strict_reject", .{
                                scoped_user_id.?,
                                send_duration_ms,
                            });
                            const reject_body = std.fmt.allocPrint(
                                ctx.req_allocator,
                                "{{\"error\":\"strict_identity_reject\",\"code\":\"{s}\"}}",
                                .{canonical_decision.reason_code},
                            ) catch "{\"error\":\"strict_identity_reject\"}";
                            ctx.response_status = "403 Forbidden";
                            ctx.response_body = reject_body;
                            return;
                        },
                        .canonical, .degraded_compat => break :blk canonical_decision.session_key.?,
                    }
                };
                const tenant_runtime = getTenantRuntime(ctx.state, cfg, &tenant_user_ctx.?) catch |err| {
                    if (err == error.ExecutionDelegated) {
                        ctx.response_status = "503 Service Unavailable";
                        ctx.response_body = "{\"error\":\"execution_delegated\"}";
                    } else {
                        ctx.response_status = "500 Internal Server Error";
                        ctx.response_body = "{\"error\":\"tenant runtime init failed\"}";
                    }
                    return;
                };
                var typing_channel = channels.telegram.TelegramChannel.init(
                    ctx.req_allocator,
                    tg_bot_token,
                    &.{"*"},
                    &.{},
                    "open",
                );
                typing_channel.startTyping(cid_str) catch {};
                defer typing_channel.stopTyping(cid_str) catch {};
                const agent_turn_start_ms = std.time.milliTimestamp();
                const reply: ?[]const u8 = tenant_runtime.processMessage(
                    sk,
                    msg_text.?,
                    .{
                        .channel = "telegram",
                        .is_group = is_group,
                    },
                    .{
                        .channel = "telegram",
                        .account_id = tg_account_id,
                        .chat_id = cid_str,
                        .is_group = is_group,
                        .is_dm = !is_group,
                    },
                    null,
                ) catch |err| blk: {
                    const agent_turn_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - agent_turn_start_ms));
                    log.info("telegram.webhook.stage stage=agent_turn user={s} duration_ms={d} ok=false", .{
                        scoped_user_id.?,
                        agent_turn_duration_ms,
                    });
                    if (tenant_user_ctx) |*send_user_ctx| {
                        const send_token = resolveTenantTelegramBotTokenForSend(
                            ctx.req_allocator,
                            send_user_ctx,
                            ctx.state.zaki_state,
                            numeric_user_id_opt,
                        ) catch |token_err| {
                            log.warn("telegram tenant token resolve before error-reply failed: {}", .{token_err});
                            break :blk null;
                        };
                        defer if (send_token.len > 0) ctx.req_allocator.free(send_token);
                        const send_start_ms = std.time.milliTimestamp();
                        sendTelegramReply(ctx.req_allocator, send_token, chat_id.?, userFacingAgentError(err)) catch |send_err| {
                            log.warn("telegram webhook error-reply send failed: {}", .{send_err});
                        };
                        const send_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - send_start_ms));
                        log.info("telegram.webhook.stage stage=telegram_send user={s} duration_ms={d} path=error_reply", .{
                            scoped_user_id.?,
                            send_duration_ms,
                        });
                    }
                    break :blk null;
                };
                if (reply != null) {
                    const agent_turn_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - agent_turn_start_ms));
                    log.info("telegram.webhook.stage stage=agent_turn user={s} duration_ms={d} ok=true", .{
                        scoped_user_id.?,
                        agent_turn_duration_ms,
                    });
                }
                if (reply) |r| {
                    defer ctx.root_allocator.free(r);
                    if (tenant_user_ctx) |*send_user_ctx| {
                        const send_token_opt: ?[]const u8 = blk: {
                            const send_token = resolveTenantTelegramBotTokenForSend(
                                ctx.req_allocator,
                                send_user_ctx,
                                ctx.state.zaki_state,
                                numeric_user_id_opt,
                            ) catch |token_err| {
                                log.warn("telegram tenant token resolve before reply failed: {}", .{token_err});
                                break :blk null;
                            };
                            break :blk send_token;
                        };
                        if (send_token_opt) |send_token| {
                            defer if (send_token.len > 0) ctx.req_allocator.free(send_token);
                            const send_start_ms = std.time.milliTimestamp();
                            sendTelegramReply(ctx.req_allocator, send_token, chat_id.?, r) catch |send_err| {
                                log.warn("telegram webhook reply send failed: {}", .{send_err});
                            };
                            const send_duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - send_start_ms));
                            log.info("telegram.webhook.stage stage=telegram_send user={s} duration_ms={d} path=success", .{
                                scoped_user_id.?,
                                send_duration_ms,
                            });
                        } else {
                            ctx.response_body = "{\"status\":\"received\"}";
                        }
                    }
                    ctx.response_body = "{\"status\":\"ok\"}";
                } else {
                    ctx.response_body = "{\"status\":\"received\"}";
                }
            } else if (ctx.state.event_bus) |eb| {
                var meta_buf: [320]u8 = undefined;
                const meta = std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}", .{
                    tg_account_id,
                    peer_kind,
                    cid_str,
                }) catch null;
                var kb: [256]u8 = undefined;
                const tg_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg| cfg else null;
                const sk = if (use_shared_main)
                    zaki_session.userMainSessionKey(&kb, scoped_user_id.?)
                else
                    telegramSessionKeyRouted(ctx.req_allocator, &kb, chat_id.?, b, tg_cfg_opt, tg_account_id);
                _ = publishToBus(eb, ctx.state.allocator, "telegram", sender, cid_str, msg_text.?, sk, meta);
                ctx.response_body = "{\"status\":\"ok\"}";
            } else if (ctx.session_mgr_opt) |sm| {
                var kb: [256]u8 = undefined;
                const tg_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg| cfg else null;
                const sk = if (use_shared_main)
                    zaki_session.userMainSessionKey(&kb, scoped_user_id.?)
                else
                    telegramSessionKeyRouted(ctx.req_allocator, &kb, chat_id.?, b, tg_cfg_opt, tg_account_id);
                const reply: ?[]const u8 = sm.processMessageWithToolContext(sk, msg_text.?, null, .{
                    .channel = "telegram",
                    .account_id = tg_account_id,
                    .chat_id = cid_str,
                    .is_group = is_group,
                    .is_dm = !is_group,
                }) catch |err| blk: {
                    if (tg_bot_token.len > 0) {
                        sendTelegramReply(ctx.req_allocator, tg_bot_token, chat_id.?, userFacingAgentError(err)) catch |send_err| {
                            log.warn("telegram webhook sync error-reply send failed: {}", .{send_err});
                        };
                    }
                    break :blk null;
                };
                if (reply) |r| {
                    defer ctx.root_allocator.free(r);
                    if (tg_bot_token.len > 0) {
                        sendTelegramReply(ctx.req_allocator, tg_bot_token, chat_id.?, r) catch |send_err| {
                            log.warn("telegram webhook sync reply send failed: {}", .{send_err});
                        };
                    }
                    ctx.response_body = "{\"status\":\"ok\"}";
                } else {
                    ctx.response_body = "{\"status\":\"received\"}";
                }
            } else {
                ctx.response_body = "{\"status\":\"received\"}";
            }
        } else {
            ctx.response_body = "{\"status\":\"ok\"}";
        }
    } else {
        ctx.response_body = "{\"status\":\"received\"}";
    }
}

fn handleWhatsAppWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_whatsapp) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"whatsapp channel disabled in this build\"}";
        return;
    }

    const is_get = std.mem.eql(u8, ctx.method, "GET");
    if (is_get) {
        const mode = parseQueryParam(ctx.target, "hub.mode");
        const token = parseQueryParam(ctx.target, "hub.verify_token");
        const challenge = parseQueryParam(ctx.target, "hub.challenge");
        var wa_verify_token = ctx.state.whatsapp_verify_token;
        if (selectWhatsAppConfig(ctx.config_opt, null, token)) |wa_cfg| {
            wa_verify_token = wa_cfg.verify_token;
        }

        if (mode != null and challenge != null and token != null and
            std.mem.eql(u8, mode.?, "subscribe") and
            wa_verify_token.len > 0 and
            std.mem.eql(u8, token.?, wa_verify_token))
        {
            ctx.response_body = challenge.?;
        } else {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"verification failed\"}";
        }
        return;
    }

    const is_post = std.mem.eql(u8, ctx.method, "POST");
    if (!is_post) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }

    if (!ctx.state.rate_limiter.allowWebhook(ctx.state.allocator, "whatsapp")) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const wa_body = extractBody(ctx.raw_request);
    var wa_app_secret = ctx.state.whatsapp_app_secret;
    var wa_access_token = ctx.state.whatsapp_access_token;
    var wa_allow_from = ctx.state.whatsapp_allow_from;
    var wa_group_allow_from = ctx.state.whatsapp_group_allow_from;
    var wa_groups = ctx.state.whatsapp_groups;
    var wa_group_policy = ctx.state.whatsapp_group_policy;
    var wa_account_id = ctx.state.whatsapp_account_id;
    if (selectWhatsAppConfig(ctx.config_opt, wa_body, null)) |wa_cfg| {
        wa_app_secret = wa_cfg.app_secret orelse "";
        wa_access_token = wa_cfg.access_token;
        wa_allow_from = wa_cfg.allow_from;
        wa_group_allow_from = wa_cfg.group_allow_from;
        wa_groups = wa_cfg.groups;
        wa_group_policy = wa_cfg.group_policy;
        wa_account_id = wa_cfg.account_id;
    }

    const sig_header = extractHeader(ctx.raw_request, "X-Hub-Signature-256");
    if (wa_app_secret.len > 0) sig_check: {
        const sig = sig_header orelse {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"missing signature\"}";
            break :sig_check;
        };
        const body = wa_body orelse {
            ctx.response_body = "{\"status\":\"received\"}";
            break :sig_check;
        };
        if (!verifyWhatsappSignature(body, sig, wa_app_secret)) {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"invalid signature\"}";
            break :sig_check;
        }
        const wa_sender = jsonStringField(body, "from");
        const wa_is_group = whatsappIsGroupMessage(body);
        const wa_group_id = whatsappGroupId(body);
        if (!whatsappSenderAllowed(
            wa_sender,
            wa_is_group,
            wa_group_id,
            wa_allow_from,
            wa_group_allow_from,
            wa_groups,
            wa_group_policy,
        )) {
            ctx.response_body = "{\"status\":\"unauthorized\"}";
            break :sig_check;
        }
        const msg_text = jsonStringField(body, "text") orelse jsonStringField(body, "body") orelse
            channels.whatsapp.WhatsAppChannel.downloadMediaFromPayload(ctx.req_allocator, wa_access_token, body);
        if (msg_text) |mt| {
            var wa_key_buf: [256]u8 = undefined;
            const wa_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg| cfg else null;
            const wa_session_key = whatsappSessionKeyRouted(ctx.req_allocator, &wa_key_buf, body, wa_cfg_opt, wa_account_id);
            const wa_sender_id = wa_sender orelse "unknown";
            const wa_chat_target = whatsappReplyTarget(body);
            const wa_peer_kind = if (wa_is_group) "group" else "direct";
            const wa_peer_id = wa_group_id orelse wa_sender_id;

            if (ctx.state.event_bus) |eb| {
                var meta_buf: [384]u8 = undefined;
                const meta = std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}", .{
                    wa_account_id,
                    wa_peer_kind,
                    wa_peer_id,
                }) catch null;
                _ = publishToBus(eb, ctx.state.allocator, "whatsapp", wa_sender_id, wa_chat_target, mt, wa_session_key, meta);
                ctx.response_body = "{\"status\":\"received\"}";
            } else if (ctx.session_mgr_opt) |sm| {
                const reply: ?[]const u8 = sm.processMessageWithToolContext(wa_session_key, mt, null, .{
                    .channel = "whatsapp",
                    .account_id = wa_account_id,
                    .chat_id = wa_chat_target,
                    .is_group = wa_is_group,
                    .is_dm = !wa_is_group,
                }) catch |err| blk: {
                    ctx.response_body = userFacingAgentErrorJson(err);
                    break :blk null;
                };
                if (reply) |r| {
                    defer ctx.root_allocator.free(r);
                    ctx.response_body = ctx.req_allocator.dupe(u8, r) catch "{\"status\":\"received\"}";
                } else {
                    ctx.response_body = "{\"status\":\"received\"}";
                }
            } else {
                ctx.response_body = "{\"status\":\"received\"}";
            }
        } else {
            ctx.response_body = "{\"status\":\"received\"}";
        }
        return;
    }

    if (wa_body) |b| {
        const wa_sender = jsonStringField(b, "from");
        const wa_is_group = whatsappIsGroupMessage(b);
        const wa_group_id = whatsappGroupId(b);
        if (!whatsappSenderAllowed(
            wa_sender,
            wa_is_group,
            wa_group_id,
            wa_allow_from,
            wa_group_allow_from,
            wa_groups,
            wa_group_policy,
        )) {
            ctx.response_body = "{\"status\":\"unauthorized\"}";
            return;
        }
        const msg_text = jsonStringField(b, "text") orelse jsonStringField(b, "body") orelse
            channels.whatsapp.WhatsAppChannel.downloadMediaFromPayload(ctx.req_allocator, wa_access_token, b);
        if (msg_text) |mt| {
            var wa_key_buf: [256]u8 = undefined;
            const wa_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg| cfg else null;
            const wa_session_key = whatsappSessionKeyRouted(ctx.req_allocator, &wa_key_buf, b, wa_cfg_opt, wa_account_id);
            const wa_sender_ns = wa_sender orelse "unknown";
            const wa_chat_target_ns = whatsappReplyTarget(b);
            const wa_peer_kind = if (wa_is_group) "group" else "direct";
            const wa_peer_id = wa_group_id orelse wa_sender_ns;

            if (ctx.state.event_bus) |eb| {
                var meta_buf: [384]u8 = undefined;
                const meta = std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}", .{
                    wa_account_id,
                    wa_peer_kind,
                    wa_peer_id,
                }) catch null;
                _ = publishToBus(eb, ctx.state.allocator, "whatsapp", wa_sender_ns, wa_chat_target_ns, mt, wa_session_key, meta);
                ctx.response_body = "{\"status\":\"received\"}";
            } else if (ctx.session_mgr_opt) |sm| {
                const reply: ?[]const u8 = sm.processMessageWithToolContext(wa_session_key, mt, null, .{
                    .channel = "whatsapp",
                    .account_id = wa_account_id,
                    .chat_id = wa_chat_target_ns,
                    .is_group = wa_is_group,
                    .is_dm = !wa_is_group,
                }) catch |err| blk: {
                    ctx.response_body = userFacingAgentErrorJson(err);
                    break :blk null;
                };
                if (reply) |r| {
                    defer ctx.root_allocator.free(r);
                    ctx.response_body = ctx.req_allocator.dupe(u8, r) catch "{\"status\":\"received\"}";
                } else {
                    ctx.response_body = "{\"status\":\"received\"}";
                }
            } else {
                ctx.response_body = "{\"status\":\"received\"}";
            }
        } else {
            ctx.response_body = "{\"status\":\"received\"}";
        }
    } else {
        ctx.response_body = "{\"status\":\"received\"}";
    }
}

fn handleSlackWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_slack) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"slack channel disabled in this build\"}";
        return;
    }

    if (!std.mem.eql(u8, ctx.method, "POST")) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    if (!ctx.state.rate_limiter.allowWebhook(ctx.state.allocator, "slack")) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_body = "{\"status\":\"received\"}";
        return;
    };

    const ts_header = extractHeader(ctx.raw_request, "X-Slack-Request-Timestamp");
    const sig_header = extractHeader(ctx.raw_request, "X-Slack-Signature");

    const slack_cfg = findSlackConfigForRequest(ctx.req_allocator, ctx.config_opt, ctx.target, body, ts_header, sig_header) orelse {
        if (hasSlackHttpEndpoint(ctx.config_opt, webhookBasePath(ctx.target))) {
            ctx.response_status = "403 Forbidden";
            ctx.response_body = "{\"error\":\"invalid signature\"}";
            return;
        }
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"slack account not configured\"}";
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.req_allocator, body, .{}) catch {
        ctx.response_body = "{\"status\":\"parse_error\"}";
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }

    const payload_type = if (parsed.value.object.get("type")) |tv|
        if (tv == .string) tv.string else ""
    else
        "";

    if (std.mem.eql(u8, payload_type, "url_verification")) {
        const challenge = jsonStringField(body, "challenge") orelse "";
        if (challenge.len == 0) {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        }
        const challenge_resp = jsonWrapChallenge(ctx.req_allocator, challenge) catch {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        };
        ctx.response_body = challenge_resp;
        return;
    }

    if (!std.mem.eql(u8, payload_type, "event_callback")) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }

    const event_val = parsed.value.object.get("event") orelse {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    };
    if (event_val != .object) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }
    const event_obj = event_val.object;

    const event_type_val = event_obj.get("type") orelse {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    };
    if (event_type_val != .string) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }
    const event_type = event_type_val.string;
    if (!std.mem.eql(u8, event_type, "message") and !std.mem.eql(u8, event_type, "app_mention")) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }

    if (event_obj.get("subtype")) |subtype_val| {
        if (subtype_val == .string and subtype_val.string.len > 0) {
            ctx.response_body = "{\"status\":\"ok\"}";
            return;
        }
    }

    const user_val = event_obj.get("user") orelse {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    };
    if (user_val != .string or user_val.string.len == 0) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }
    const sender_id = user_val.string;

    const text_val = event_obj.get("text") orelse {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    };
    if (text_val != .string) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }
    const text = std.mem.trim(u8, text_val.string, " \t\r\n");
    if (text.len == 0) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }

    const channel_val = event_obj.get("channel") orelse {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    };
    if (channel_val != .string or channel_val.string.len == 0) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }
    const channel_id = channel_val.string;
    const is_dm = blk: {
        if (event_obj.get("channel_type")) |ct| {
            if (ct == .string and std.mem.eql(u8, ct.string, "im")) break :blk true;
        }
        break :blk channel_id.len > 0 and channel_id[0] == 'D';
    };

    var key_buf: [256]u8 = undefined;
    const fallback_session_key = slackSessionKeyRouted(
        ctx.req_allocator,
        &key_buf,
        slack_cfg.account_id,
        sender_id,
        channel_id,
        is_dm,
        ctx.config_opt,
    );
    var effective_session_key = fallback_session_key;
    var canonical_decision_opt: ?inbound_canonicalizer.CanonicalizationDecision = null;
    defer if (canonical_decision_opt) |*decision| decision.deinit(ctx.req_allocator);

    if (ctx.config_opt) |cfg| {
        const thread_raw = blk: {
            if (event_obj.get("thread_ts")) |thread_val| {
                if (thread_val == .string and std.mem.trim(u8, thread_val.string, " \t\r\n").len > 0) {
                    break :blk thread_val.string;
                }
            }
            break :blk null;
        };
        var identity_keys = channel_identity_key.build(
            ctx.req_allocator,
            "slack",
            sender_id,
            channel_id,
            thread_raw,
        ) catch {
            ctx.response_status = "400 Bad Request";
            ctx.response_body = "{\"error\":\"invalid slack identity\"}";
            return;
        };
        defer identity_keys.deinit(ctx.req_allocator);

        canonical_decision_opt = inbound_canonicalizer.canonicalizeInboundTurn(
            ctx.req_allocator,
            ctx.state.zaki_state,
            cfg,
            .{
                .channel = "slack",
                .account_id = slack_cfg.account_id,
                .principal_key = identity_keys.principal_key,
                .scope_key = identity_keys.scope_key,
                .thread_key = identity_keys.thread_key,
                .fallback_session_key = fallback_session_key,
                .lane = if (identity_keys.thread_key != null) .thread else .main,
            },
        ) catch |err| {
            log.warn("slack canonicalization failed: {}", .{err});
            ctx.response_status = "500 Internal Server Error";
            ctx.response_body = "{\"error\":\"canonicalization_failed\"}";
            return;
        };

        switch (canonical_decision_opt.?.kind) {
            .strict_reject => {
                const reject_body = std.fmt.allocPrint(
                    ctx.req_allocator,
                    "{{\"error\":\"strict_identity_reject\",\"code\":\"{s}\"}}",
                    .{canonical_decision_opt.?.reason_code},
                ) catch "{\"error\":\"strict_identity_reject\"}";
                ctx.response_status = "403 Forbidden";
                ctx.response_body = reject_body;
                return;
            },
            .canonical, .degraded_compat => {
                if (canonical_decision_opt.?.session_key) |canonical_session_key| {
                    effective_session_key = canonical_session_key;
                }
            },
        }
    }

    var policy_channel = channels.slack.SlackChannel.initFromConfig(ctx.req_allocator, slack_cfg.*);
    const envelope_bot_user_id = slackEnvelopeBotUserId(parsed.value.object);
    var allowed = policy_channel.shouldHandle(sender_id, is_dm, text, envelope_bot_user_id);
    if (!allowed and std.mem.eql(u8, event_type, "app_mention")) {
        allowed = channels.checkPolicy(policy_channel.policy, sender_id, is_dm, true);
    }
    if (!allowed) {
        ctx.response_body = "{\"status\":\"ok\"}";
        return;
    }

    if (ctx.state.event_bus) |eb| {
        var meta_buf: [384]u8 = undefined;
        const peer_kind = if (is_dm) "direct" else "channel";
        const peer_id = if (is_dm) sender_id else channel_id;
        const metadata = std.fmt.bufPrint(
            &meta_buf,
            "{{\"account_id\":\"{s}\",\"is_dm\":{s},\"channel_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}",
            .{
                slack_cfg.account_id,
                if (is_dm) "true" else "false",
                channel_id,
                peer_kind,
                peer_id,
            },
        ) catch null;
        _ = publishToBus(eb, ctx.state.allocator, "slack", sender_id, channel_id, text, effective_session_key, metadata);
    } else if (ctx.session_mgr_opt) |sm| {
        const reply: ?[]const u8 = sm.processMessageWithToolContext(effective_session_key, text, null, .{
            .channel = "slack",
            .account_id = slack_cfg.account_id,
            .chat_id = if (is_dm) sender_id else channel_id,
            .is_group = !is_dm,
            .is_dm = is_dm,
            .mentioned = std.mem.eql(u8, event_type, "app_mention"),
        }) catch |err| blk: {
            var outbound_ch = channels.slack.SlackChannel.initFromConfig(ctx.req_allocator, slack_cfg.*);
            outbound_ch.sendMessage(channel_id, userFacingAgentError(err)) catch {};
            break :blk null;
        };
        if (reply) |r| {
            defer ctx.root_allocator.free(r);
            var outbound_ch = channels.slack.SlackChannel.initFromConfig(ctx.req_allocator, slack_cfg.*);
            outbound_ch.sendMessage(channel_id, r) catch {};
        }
    }

    ctx.response_body = "{\"status\":\"ok\"}";
}

fn linePeerMetadata(evt: channels.line.LineEvent, peer_buf: []u8) struct {
    kind: []const u8,
    id: []const u8,
} {
    const src_type = evt.source_type orelse "";
    if (std.mem.eql(u8, src_type, "group")) {
        return .{
            .kind = "group",
            .id = std.fmt.bufPrint(peer_buf, "group:{s}", .{evt.group_id orelse evt.user_id orelse "unknown"}) catch "group:unknown",
        };
    }
    if (std.mem.eql(u8, src_type, "room")) {
        return .{
            .kind = "group",
            .id = std.fmt.bufPrint(peer_buf, "room:{s}", .{evt.room_id orelse evt.user_id orelse "unknown"}) catch "room:unknown",
        };
    }
    return .{
        .kind = "direct",
        .id = evt.user_id orelse "unknown",
    };
}

fn handleLineWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_line) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"line channel disabled in this build\"}";
        return;
    }

    const is_post = std.mem.eql(u8, ctx.method, "POST");
    if (!is_post) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    if (!ctx.state.rate_limiter.allowWebhook(ctx.state.allocator, "line")) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const body = extractBody(ctx.raw_request);
    if (body) |b| {
        var line_channel_secret = ctx.state.line_channel_secret;
        var line_access_token = ctx.state.line_access_token;
        var line_allow_from = ctx.state.line_allow_from;
        var line_account_id = ctx.state.line_account_id;

        const sig_header = extractHeader(ctx.raw_request, "X-Line-Signature");
        if (ctx.config_opt) |cfg| {
            const needs_signature = hasLineSecrets(cfg);
            if (needs_signature) {
                const sig = sig_header orelse {
                    ctx.response_status = "403 Forbidden";
                    ctx.response_body = "{\"error\":\"missing signature\"}";
                    return;
                };
                const matched_line_cfg = selectLineConfigBySignature(ctx.config_opt, b, sig) orelse {
                    ctx.response_status = "403 Forbidden";
                    ctx.response_body = "{\"error\":\"invalid signature\"}";
                    return;
                };
                line_channel_secret = matched_line_cfg.channel_secret;
                line_access_token = matched_line_cfg.access_token;
                line_allow_from = matched_line_cfg.allow_from;
                line_account_id = matched_line_cfg.account_id;
            } else if (cfg.channels.linePrimary()) |line_cfg| {
                line_channel_secret = line_cfg.channel_secret;
                line_access_token = line_cfg.access_token;
                line_allow_from = line_cfg.allow_from;
                line_account_id = line_cfg.account_id;
            }
        } else if (line_channel_secret.len > 0) {
            const sig = sig_header orelse {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"missing signature\"}";
                return;
            };
            if (!channels.line.LineChannel.verifySignature(b, sig, line_channel_secret)) {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"invalid signature\"}";
                return;
            }
        }

        const events = channels.line.LineChannel.parseWebhookEvents(ctx.req_allocator, b) catch {
            ctx.response_body = "{\"status\":\"parse_error\"}";
            return;
        };
        for (events) |evt| {
            if (line_allow_from.len > 0) {
                if (evt.user_id) |uid| {
                    if (!channels.isAllowed(line_allow_from, uid)) continue;
                } else continue;
            }
            if (evt.message_text) |text| {
                var kb: [128]u8 = undefined;
                const line_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg| cfg else null;
                const sk = lineSessionKeyRouted(ctx.req_allocator, &kb, evt, line_cfg_opt, line_account_id);
                const uid = evt.user_id orelse "unknown";
                const line_target = lineReplyTarget(evt);
                var peer_buf: [160]u8 = undefined;
                const line_peer = linePeerMetadata(evt, &peer_buf);

                if (ctx.state.event_bus) |eb| {
                    var meta_buf: [384]u8 = undefined;
                    const meta = std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}", .{
                        line_account_id,
                        line_peer.kind,
                        line_peer.id,
                    }) catch null;
                    _ = publishToBus(eb, ctx.state.allocator, "line", uid, line_target, text, sk, meta);
                } else if (ctx.session_mgr_opt) |sm| {
                    const reply: ?[]const u8 = sm.processMessageWithToolContext(sk, text, null, .{
                        .channel = "line",
                        .account_id = line_account_id,
                        .chat_id = line_target,
                        .is_group = std.mem.eql(u8, line_peer.kind, "group"),
                        .is_dm = std.mem.eql(u8, line_peer.kind, "direct"),
                    }) catch |err| blk: {
                        if (evt.reply_token) |rt| {
                            var line_ch = channels.line.LineChannel.init(ctx.req_allocator, .{
                                .access_token = line_access_token,
                                .channel_secret = line_channel_secret,
                            });
                            line_ch.replyMessage(rt, userFacingAgentError(err)) catch {};
                        }
                        break :blk null;
                    };
                    if (reply) |r| {
                        defer ctx.root_allocator.free(r);
                        if (evt.reply_token) |rt| {
                            var line_ch = channels.line.LineChannel.init(ctx.req_allocator, .{
                                .access_token = line_access_token,
                                .channel_secret = line_channel_secret,
                            });
                            line_ch.replyMessage(rt, r) catch {};
                        }
                    }
                }
            }
        }
        ctx.response_body = "{\"status\":\"ok\"}";
    } else {
        ctx.response_body = "{\"status\":\"received\"}";
    }
}

fn handleLarkWebhookRoute(ctx: *WebhookHandlerContext) void {
    if (!build_options.enable_channel_lark) {
        ctx.response_status = "404 Not Found";
        ctx.response_body = "{\"error\":\"lark channel disabled in this build\"}";
        return;
    }

    const is_post = std.mem.eql(u8, ctx.method, "POST");
    if (!is_post) {
        ctx.response_status = "405 Method Not Allowed";
        ctx.response_body = "{\"error\":\"method not allowed\"}";
        return;
    }
    if (!ctx.state.rate_limiter.allowWebhook(ctx.state.allocator, "lark")) {
        ctx.response_status = "429 Too Many Requests";
        ctx.response_body = "{\"error\":\"rate limited\"}";
        return;
    }

    const body = extractBody(ctx.raw_request) orelse {
        ctx.response_body = "{\"status\":\"received\"}";
        return;
    };
    var lark_verification_token = ctx.state.lark_verification_token;
    var lark_app_id = ctx.state.lark_app_id;
    var lark_app_secret = ctx.state.lark_app_secret;
    var lark_allow_from = ctx.state.lark_allow_from;
    var lark_account_id = ctx.state.lark_account_id;
    if (selectLarkConfig(ctx.config_opt, body)) |lark_cfg| {
        lark_verification_token = lark_cfg.verification_token orelse "";
        lark_app_id = lark_cfg.app_id;
        lark_app_secret = lark_cfg.app_secret;
        lark_allow_from = lark_cfg.allow_from;
        lark_account_id = lark_cfg.account_id;
    }

    if (std.mem.indexOf(u8, body, "\"url_verification\"") != null) {
        const challenge = jsonStringField(body, "challenge");
        if (challenge) |c| {
            const challenge_resp = jsonWrapChallenge(ctx.req_allocator, c) catch null;
            ctx.response_body = challenge_resp orelse "{\"status\":\"ok\"}";
        } else {
            ctx.response_body = "{\"status\":\"ok\"}";
        }
        return;
    }

    if (lark_verification_token.len > 0) {
        const payload_token = blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, ctx.req_allocator, body, .{}) catch break :blk @as(?[]const u8, null);
            defer parsed.deinit();
            if (parsed.value != .object) break :blk @as(?[]const u8, null);
            const header = parsed.value.object.get("header") orelse break :blk @as(?[]const u8, null);
            if (header != .object) break :blk @as(?[]const u8, null);
            const token_val = header.object.get("token") orelse break :blk @as(?[]const u8, null);
            break :blk if (token_val == .string) ctx.req_allocator.dupe(u8, token_val.string) catch null else null;
        };
        if (payload_token) |pt| {
            if (!std.mem.eql(u8, pt, lark_verification_token)) {
                ctx.response_status = "403 Forbidden";
                ctx.response_body = "{\"error\":\"invalid verification token\"}";
                return;
            }
        }
    }

    var lark_ch = channels.lark.LarkChannel.init(
        ctx.req_allocator,
        lark_app_id,
        lark_app_secret,
        lark_verification_token,
        0,
        lark_allow_from,
    );
    const messages = lark_ch.parseEventPayload(ctx.req_allocator, body) catch {
        ctx.response_body = "{\"status\":\"parse_error\"}";
        return;
    };
    for (messages) |msg| {
        var kb: [128]u8 = undefined;
        const lark_cfg_opt: ?*const Config = if (ctx.config_opt) |cfg| cfg else null;
        const sk = larkSessionKeyRouted(ctx.req_allocator, &kb, msg, lark_cfg_opt, lark_account_id);

        if (ctx.state.event_bus) |eb| {
            var meta_buf: [320]u8 = undefined;
            const meta = std.fmt.bufPrint(&meta_buf, "{{\"account_id\":\"{s}\",\"peer_kind\":\"{s}\",\"peer_id\":\"{s}\"}}", .{
                lark_account_id,
                if (msg.is_group) "group" else "direct",
                msg.sender,
            }) catch null;
            _ = publishToBus(eb, ctx.state.allocator, "lark", msg.sender, msg.sender, msg.content, sk, meta);
        } else if (ctx.session_mgr_opt) |sm| {
            const reply: ?[]const u8 = sm.processMessageWithToolContext(sk, msg.content, null, .{
                .channel = "lark",
                .account_id = lark_account_id,
                .chat_id = msg.sender,
                .is_group = msg.is_group,
                .is_dm = !msg.is_group,
            }) catch |err| blk: {
                lark_ch.sendMessage(msg.sender, userFacingAgentError(err)) catch {};
                break :blk null;
            };
            if (reply) |r| {
                defer ctx.root_allocator.free(r);
                lark_ch.sendMessage(msg.sender, r) catch {};
            }
        }
    }
    ctx.response_body = "{\"status\":\"ok\"}";
}

fn sendHttpResponse(stream: anytype, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    try stream.writeAll(header);
    if (body.len > 0) try stream.writeAll(body);
}

fn sendHttpResponseRetryAfter(
    stream: anytype,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
    retry_after_secs: u16,
) !void {
    var header_buf: [640]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nRetry-After: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len, @max(@as(u16, 1), retry_after_secs) },
    );
    try stream.writeAll(header);
    if (body.len > 0) try stream.writeAll(body);
}

fn setListenerNonBlocking(server: *std.net.Server) void {
    const flags = std.posix.fcntl(server.stream.handle, std.posix.F.GETFL, 0) catch return;
    _ = std.posix.fcntl(server.stream.handle, std.posix.F.SETFL, flags | @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }))) catch {};
}

fn handleAcceptedConnection(
    allocator: std.mem.Allocator,
    config_opt: ?*const Config,
    state: *GatewayState,
    session_mgr_opt: ?*session_mod.SessionManager,
    conn: std.net.Server.Connection,
) void {
    defer conn.stream.close();
    configureRequestReadTimeout(conn.stream);

    // Per-request arena — all request-scoped allocations freed in one shot
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    const raw = readHttpRequest(req_allocator, conn.stream) catch |err| {
        switch (err) {
            error.RequestTooLarge => sendHttpResponse(conn.stream, "413 Payload Too Large", "application/json", "{\"error\":\"request too large\"}") catch {},
            error.InvalidContentLength => sendHttpResponse(conn.stream, "400 Bad Request", "application/json", "{\"error\":\"invalid content-length\"}") catch {},
            error.RequestTimeout => sendHttpResponse(conn.stream, "408 Request Timeout", "application/json", "{\"error\":\"request timeout\"}") catch {},
            else => sendHttpResponse(conn.stream, "400 Bad Request", "application/json", "{\"error\":\"invalid request\"}") catch {},
        }
        return;
    };
    _ = state.requests_total.fetchAdd(1, .monotonic);
    maybeLogDegradedStateWarning(state);

    // Parse first line: "METHOD /path HTTP/1.1\r\n"
    const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse {
        sendHttpResponse(conn.stream, "400 Bad Request", "application/json", "{\"error\":\"malformed request\"}") catch {};
        return;
    };
    const first_line = raw[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method_str = parts.next() orelse {
        sendHttpResponse(conn.stream, "400 Bad Request", "application/json", "{\"error\":\"malformed request\"}") catch {};
        return;
    };
    const target = parts.next() orelse {
        sendHttpResponse(conn.stream, "400 Bad Request", "application/json", "{\"error\":\"malformed request\"}") catch {};
        return;
    };
    _ = state.in_flight_requests.fetchAdd(1, .acq_rel);
    defer _ = state.in_flight_requests.fetchSub(1, .acq_rel);

    // Simple routing — control endpoints + descriptor-driven channel webhooks + ZAKI API.
    const ControlRoute = enum { health, ready, webhook, pair, metrics, diagnostics, wake_heartbeat, invalidate_tenant_runtime_cache, cell_resolve, cell_ensure, cell_status, cell_drain, drain, undrain, shutdown };
    const control_route_map = std.StaticStringMap(ControlRoute).initComptime(.{
        .{ "/health", .health },
        .{ "/ready", .ready },
        .{ "/webhook", .webhook },
        .{ "/pair", .pair },
        .{ "/metrics", .metrics },
        .{ "/internal/diagnostics", .diagnostics },
        .{ "/internal/wake-heartbeat", .wake_heartbeat },
        .{ "/internal/tenant-runtime-cache/invalidate", .invalidate_tenant_runtime_cache },
        .{ "/internal/cells/resolve", .cell_resolve },
        .{ "/internal/cells/ensure", .cell_ensure },
        .{ "/internal/cells/status", .cell_status },
        .{ "/internal/cells/drain", .cell_drain },
        .{ "/internal/drain", .drain },
        .{ "/internal/undrain", .undrain },
        .{ "/internal/shutdown", .shutdown },
    });
    const base_path = if (std.mem.indexOfScalar(u8, target, '?')) |qi| target[0..qi] else target;
    const is_chat_stream_path = std.mem.eql(u8, base_path, "/api/v1/chat/stream");
    const is_chat_events_path = std.mem.eql(u8, base_path, "/api/v1/chat/events");
    const is_post = std.mem.eql(u8, method_str, "POST");
    var response_status: []const u8 = "200 OK";
    var response_body: []const u8 = "";
    var response_content_type: []const u8 = "application/json";
    var response_retry_after_secs: ?u16 = null;
    var pair_response_buf: [256]u8 = undefined;

    const is_internal_path = std.mem.startsWith(u8, base_path, "/internal/");
    const is_ops_path = std.mem.eql(u8, base_path, "/health") or
        std.mem.eql(u8, base_path, "/ready") or
        std.mem.eql(u8, base_path, "/metrics") or
        is_chat_stream_path or
        is_chat_events_path or
        is_internal_path;
    const overload_retry_after_secs: u16 = if (config_opt) |cfg|
        @max(@as(u16, 1), cfg.gateway.overload_retry_after_secs)
    else
        2;
    if (state.draining.load(.acquire) and !is_ops_path) {
        _ = state.drain_rejected_total.fetchAdd(1, .monotonic);
        sendHttpResponseRetryAfter(
            conn.stream,
            "503 Service Unavailable",
            "application/json",
            "{\"error\":\"draining\",\"retry_hint\":\"retry shortly\"}",
            overload_retry_after_secs,
        ) catch {};
        return;
    }

    if (is_chat_stream_path) {
        _ = handleApiChatStreamSseConnection(
            allocator,
            req_allocator,
            &conn.stream,
            raw,
            method_str,
            base_path,
            state,
            config_opt,
            session_mgr_opt,
        );
        return;
    } else if (is_chat_events_path) {
        _ = handleApiChatEventsSseConnection(
            allocator,
            req_allocator,
            &conn.stream,
            raw,
            method_str,
            base_path,
            state,
            config_opt,
            session_mgr_opt,
        );
        return;
    } else if (std.mem.startsWith(u8, base_path, "/api/v1/")) {
        const api_resp = handleApiRoute(
            allocator,
            req_allocator,
            raw,
            method_str,
            base_path,
            state,
            config_opt,
            session_mgr_opt,
        );
        response_status = api_resp.status;
        response_body = api_resp.body;
        response_content_type = api_resp.content_type;
        response_retry_after_secs = api_resp.retry_after_secs;
    } else if (findWebhookRouteDescriptor(base_path)) |desc| {
        var webhook_ctx = WebhookHandlerContext{
            .root_allocator = allocator,
            .req_allocator = req_allocator,
            .raw_request = raw,
            .method = method_str,
            .target = target,
            .config_opt = config_opt,
            .state = state,
            .session_mgr_opt = session_mgr_opt,
        };
        desc.handler(&webhook_ctx);
        response_status = webhook_ctx.response_status;
        response_body = webhook_ctx.response_body;
        response_retry_after_secs = webhook_ctx.response_retry_after_secs;
    } else if (hasSlackHttpEndpoint(config_opt, base_path)) {
        var webhook_ctx = WebhookHandlerContext{
            .root_allocator = allocator,
            .req_allocator = req_allocator,
            .raw_request = raw,
            .method = method_str,
            .target = target,
            .config_opt = config_opt,
            .state = state,
            .session_mgr_opt = session_mgr_opt,
        };
        handleSlackWebhookRoute(&webhook_ctx);
        response_status = webhook_ctx.response_status;
        response_body = webhook_ctx.response_body;
    } else if (control_route_map.get(base_path)) |route| switch (route) {
        .health => {
            response_body = if (isHealthOk()) "{\"status\":\"ok\"}" else "{\"status\":\"degraded\"}";
        },
        .ready => {
            if (state.draining.load(.acquire)) {
                response_status = "503 Service Unavailable";
                response_body = "{\"status\":\"draining\"}";
            } else {
                const readiness = health.checkRegistryReadiness(req_allocator) catch {
                    response_status = "500 Internal Server Error";
                    response_body = "{\"status\":\"not_ready\",\"checks\":[]}";
                    sendHttpResponse(conn.stream, response_status, response_content_type, response_body) catch {};
                    return;
                };
                const json_body = readiness.formatJson(req_allocator) catch {
                    response_status = "500 Internal Server Error";
                    response_body = "{\"status\":\"not_ready\",\"checks\":[]}";
                    sendHttpResponse(conn.stream, response_status, response_content_type, response_body) catch {};
                    return;
                };
                response_body = json_body;
                if (readiness.status != .ready) {
                    response_status = "503 Service Unavailable";
                }
            }
        },
        .webhook => {
            if (!is_post) {
                response_status = "405 Method Not Allowed";
                response_body = "{\"error\":\"method not allowed\"}";
            } else {
                const auth_header = extractHeader(raw, "Authorization");
                const bearer = if (auth_header) |ah| extractBearerToken(ah) else null;
                const pairing_guard = if (state.pairing_guard) |*guard| guard else null;
                if (!isWebhookAuthorized(pairing_guard, bearer)) {
                    response_status = "401 Unauthorized";
                    response_body = "{\"error\":\"unauthorized\"}";
                } else if (!state.rate_limiter.allowWebhook(state.allocator, "webhook")) {
                    response_status = "429 Too Many Requests";
                    response_body = "{\"error\":\"rate limited\"}";
                } else {
                    const body = extractBody(raw);
                    if (body) |b| {
                        const msg_text = jsonStringField(b, "message") orelse jsonStringField(b, "text") orelse b;
                        var sk_buf: [128]u8 = undefined;
                        const session_key = std.fmt.bufPrint(&sk_buf, "webhook:{s}", .{bearer orelse "anon"}) catch "webhook:anon";

                        if (state.event_bus) |eb| {
                            _ = publishToBus(eb, state.allocator, "webhook", bearer orelse "anon", session_key, msg_text, session_key, null);
                            response_body = "{\"status\":\"received\"}";
                        } else if (session_mgr_opt) |sm| {
                            const reply: ?[]const u8 = sm.processMessageWithToolContext(session_key, msg_text, null, .{
                                .channel = "webhook",
                                .chat_id = session_key,
                                .is_group = false,
                                .is_dm = true,
                            }) catch |err| blk: {
                                response_body = userFacingAgentErrorJson(err);
                                break :blk null;
                            };
                            if (reply) |r| {
                                defer allocator.free(r);
                                const json_resp = jsonWrapResponse(req_allocator, r) catch null;
                                response_body = json_resp orelse "{\"status\":\"received\"}";
                            } else {
                                response_body = "{\"status\":\"received\"}";
                            }
                        } else {
                            response_body = "{\"status\":\"received\"}";
                        }
                    } else {
                        response_body = "{\"status\":\"received\"}";
                    }
                }
            }
        },
        .pair => {
            if (!is_post) {
                response_status = "405 Method Not Allowed";
                response_body = "{\"error\":\"method not allowed\"}";
            } else if (!state.rate_limiter.allowPair(state.allocator, "pair")) {
                response_status = "429 Too Many Requests";
                response_body = "{\"error\":\"rate limited\"}";
            } else {
                if (state.pairing_guard) |*guard| {
                    const pairing_code = extractHeader(raw, "X-Pairing-Code");
                    switch (guard.attemptPair(pairing_code)) {
                        .paired => |token| {
                            defer allocator.free(token);
                            if (formatPairSuccessResponse(&pair_response_buf, token)) |pair_resp| {
                                response_body = pair_resp;
                            } else {
                                response_status = "500 Internal Server Error";
                                response_body = "{\"error\":\"pairing response failed\"}";
                            }
                        },
                        .missing_code => {
                            response_status = "400 Bad Request";
                            response_body = "{\"error\":\"missing X-Pairing-Code\"}";
                        },
                        .invalid_code => {
                            response_status = "401 Unauthorized";
                            response_body = "{\"error\":\"invalid pairing code\"}";
                        },
                        .already_paired => {
                            response_status = "409 Conflict";
                            response_body = "{\"error\":\"already paired\"}";
                        },
                        .disabled => {
                            response_status = "403 Forbidden";
                            response_body = "{\"error\":\"pairing disabled\"}";
                        },
                        .locked_out => {
                            response_status = "429 Too Many Requests";
                            response_body = "{\"error\":\"pairing locked out\"}";
                        },
                        .internal_error => {
                            response_status = "500 Internal Server Error";
                            response_body = "{\"error\":\"pairing failed\"}";
                        },
                    }
                } else {
                    response_status = "500 Internal Server Error";
                    response_body = "{\"error\":\"pairing unavailable\"}";
                }
            }
        },
        .metrics => {
            if (!std.mem.eql(u8, method_str, "GET")) {
                response_status = "405 Method Not Allowed";
                response_body = "{\"error\":\"method not allowed\"}";
            } else {
                response_body = metricsPayload(req_allocator, state) catch "# failed to render metrics\n";
                response_content_type = "text/plain; version=0.0.4";
            }
        },
        .diagnostics => {
            if (!std.mem.eql(u8, method_str, "GET")) {
                response_status = "405 Method Not Allowed";
                response_body = "{\"error\":\"method not allowed\"}";
            } else if (!validateInternalServiceToken(raw, state)) {
                response_status = "401 Unauthorized";
                response_body = "{\"error\":\"unauthorized\"}";
            } else {
                const user_id = resolveGatewayOptionalUserId(state, extractHeader(raw, "X-Zaki-User-Id")) catch {
                    response_status = "403 Forbidden";
                    response_body = "{\"error\":\"wrong_user_cell\"}";
                    sendHttpResponse(conn.stream, response_status, response_content_type, response_body) catch {};
                    return;
                };
                response_body = internalDiagnosticsPayload(req_allocator, state, user_id) catch "{\"error\":\"diagnostics unavailable\"}";
            }
        },
        .wake_heartbeat => {
            if (!std.mem.eql(u8, method_str, "POST")) {
                response_status = "405 Method Not Allowed";
                response_body = "{\"error\":\"method not allowed\"}";
            } else if (!validateInternalServiceToken(raw, state)) {
                response_status = "401 Unauthorized";
                response_body = "{\"error\":\"unauthorized\"}";
            } else {
                const body = extractBody(raw);
                const user_id_from_header = extractHeader(raw, "X-Zaki-User-Id");
                var user_id_owned: ?[]u8 = null;
                defer if (user_id_owned) |value| req_allocator.free(value);
                const requested_user_id = blk: {
                    if (body) |b| {
                        if (jsonStringField(b, "user_id")) |value| break :blk value;
                        if (jsonIntField(b, "user_id")) |value| {
                            user_id_owned = std.fmt.allocPrint(req_allocator, "{d}", .{value}) catch null;
                            break :blk user_id_owned;
                        }
                    }
                    break :blk user_id_from_header;
                };

                const user_id = resolveGatewayOptionalUserId(state, requested_user_id) catch {
                    response_status = "403 Forbidden";
                    response_body = "{\"error\":\"wrong_user_cell\"}";
                    sendHttpResponse(conn.stream, response_status, response_content_type, response_body) catch {};
                    return;
                };

                const reason = if (body) |b| jsonStringField(b, "reason") orelse "internal_wake_hook" else "internal_wake_hook";
                heartbeat_wake.enqueue(user_id, reason) catch {
                    response_status = "500 Internal Server Error";
                    response_body = "{\"error\":\"wake enqueue failed\"}";
                    sendHttpResponse(conn.stream, response_status, response_content_type, response_body) catch {};
                    return;
                };

                response_body = if (user_id) |uid|
                    std.fmt.allocPrint(req_allocator, "{{\"status\":\"queued\",\"user_id\":\"{s}\"}}", .{uid}) catch "{\"status\":\"queued\"}"
                else
                    "{\"status\":\"queued\",\"scope\":\"all\"}";
            }
        },
        .invalidate_tenant_runtime_cache => {
            if (!std.mem.eql(u8, method_str, "POST")) {
                response_status = "405 Method Not Allowed";
                response_body = "{\"error\":\"method not allowed\"}";
            } else if (!validateInternalServiceToken(raw, state)) {
                response_status = "401 Unauthorized";
                response_body = "{\"error\":\"unauthorized\"}";
            } else {
                const request = parseTenantRuntimeInvalidationRequest(
                    req_allocator,
                    extractHeader(raw, "X-Zaki-User-Id"),
                    extractBody(raw),
                ) catch {
                    response_status = "400 Bad Request";
                    response_body = "{\"error\":\"invalid_payload\"}";
                    sendHttpResponse(conn.stream, response_status, response_content_type, response_body) catch {};
                    return;
                };
                defer request.deinit(req_allocator);

                var requested: usize = 0;
                var removed: usize = 0;
                var missing: usize = 0;
                if (state.role == .user_cell and request.all) {
                    const pinned_user_id = state.pinned_user_id orelse {
                        response_status = "400 Bad Request";
                        response_body = "{\"error\":\"missing user_id\"}";
                        sendHttpResponse(conn.stream, response_status, response_content_type, response_body) catch {};
                        return;
                    };
                    requested = 1;
                    if (state.tenant_runtimes.get(pinned_user_id) != null) {
                        removeTenantRuntime(state, pinned_user_id);
                        removed = 1;
                    } else {
                        missing = 1;
                    }
                } else if (request.all) {
                    requested = state.tenant_runtimes.count();
                    removed = clearAllTenantRuntimes(state);
                } else {
                    requested = request.user_ids.len;
                    if (state.role == .user_cell) {
                        for (request.user_ids) |user_id| {
                            _ = resolveGatewayPathUserId(state, user_id) catch {
                                response_status = "403 Forbidden";
                                response_body = "{\"error\":\"wrong_user_cell\"}";
                                sendHttpResponse(conn.stream, response_status, response_content_type, response_body) catch {};
                                return;
                            };
                        }
                    }
                    for (request.user_ids) |user_id| {
                        if (resolveGatewayPathUserId(state, user_id)) |scoped_user_id| {
                            if (state.tenant_runtimes.get(scoped_user_id) != null) {
                                removeTenantRuntime(state, scoped_user_id);
                                removed += 1;
                            } else {
                                missing += 1;
                            }
                        } else |_| {
                            response_status = "403 Forbidden";
                            response_body = "{\"error\":\"wrong_user_cell\"}";
                            sendHttpResponse(conn.stream, response_status, response_content_type, response_body) catch {};
                            return;
                        }
                    }
                }

                response_body = std.fmt.allocPrint(
                    req_allocator,
                    "{{\"status\":\"ok\",\"requested\":{d},\"removed\":{d},\"missing\":{d},\"all\":{s}}}",
                    .{ requested, removed, missing, if (request.all) "true" else "false" },
                ) catch "{\"error\":\"response build failed\"}";
            }
        },
        .cell_resolve => {
            const response = handleBrokerCellControlRoute(req_allocator, state, raw, method_str, .resolve);
            response_status = response.status;
            response_body = response.body;
        },
        .cell_ensure => {
            const response = handleBrokerCellControlRoute(req_allocator, state, raw, method_str, .ensure);
            response_status = response.status;
            response_body = response.body;
        },
        .cell_status => {
            const response = handleBrokerCellControlRoute(req_allocator, state, raw, method_str, .status);
            response_status = response.status;
            response_body = response.body;
        },
        .cell_drain => {
            const response = handleBrokerCellControlRoute(req_allocator, state, raw, method_str, .drain);
            response_status = response.status;
            response_body = response.body;
        },
        .drain => {
            if (!std.mem.eql(u8, method_str, "POST")) {
                response_status = "405 Method Not Allowed";
                response_body = "{\"error\":\"method not allowed\"}";
            } else if (!validateInternalServiceToken(raw, state)) {
                response_status = "401 Unauthorized";
                response_body = "{\"error\":\"unauthorized\"}";
            } else {
                state.draining.store(true, .release);
                response_body = "{\"status\":\"draining\"}";
            }
        },
        .undrain => {
            if (!std.mem.eql(u8, method_str, "POST")) {
                response_status = "405 Method Not Allowed";
                response_body = "{\"error\":\"method not allowed\"}";
            } else if (!validateInternalServiceToken(raw, state)) {
                response_status = "401 Unauthorized";
                response_body = "{\"error\":\"unauthorized\"}";
            } else {
                state.draining.store(false, .release);
                state.shutdown_requested.store(false, .release);
                response_body = "{\"status\":\"ready\"}";
            }
        },
        .shutdown => {
            if (!std.mem.eql(u8, method_str, "POST")) {
                response_status = "405 Method Not Allowed";
                response_body = "{\"error\":\"method not allowed\"}";
            } else if (!validateInternalServiceToken(raw, state)) {
                response_status = "401 Unauthorized";
                response_body = "{\"error\":\"unauthorized\"}";
            } else {
                state.draining.store(true, .release);
                state.shutdown_requested.store(true, .release);
                state.closeAppEventSubscribers();
                response_body = "{\"status\":\"shutdown_requested\"}";
            }
        },
    } else {
        response_status = "404 Not Found";
        response_body = "{\"error\":\"not found\"}";
    }

    if (response_retry_after_secs) |retry_secs| {
        sendHttpResponseRetryAfter(conn.stream, response_status, response_content_type, response_body, retry_secs) catch {};
    } else {
        sendHttpResponse(conn.stream, response_status, response_content_type, response_body) catch {};
    }
}

const RequestQueue = struct {
    allocator: std.mem.Allocator,
    max_queued: usize,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    closed: bool = false,
    items: std.ArrayListUnmanaged(std.net.Server.Connection) = .empty,

    fn init(allocator: std.mem.Allocator, max_queued: usize) RequestQueue {
        return .{
            .allocator = allocator,
            .max_queued = max_queued,
        };
    }

    fn deinit(self: *RequestQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |conn| conn.stream.close();
        self.items.deinit(self.allocator);
    }

    fn push(self: *RequestQueue, conn: std.net.Server.Connection) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return false;
        if (self.items.items.len >= self.max_queued) return false;
        self.items.append(self.allocator, conn) catch return false;
        self.cond.signal();
        return true;
    }

    fn popWait(self: *RequestQueue) ?std.net.Server.Connection {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.items.items.len == 0 and !self.closed) {
            self.cond.wait(&self.mutex);
        }
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    fn len(self: *RequestQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len;
    }

    fn close(self: *RequestQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }
};

const GatewayWorkerContext = struct {
    allocator: std.mem.Allocator,
    config_opt: ?*const Config,
    state: *GatewayState,
    session_mgr_opt: ?*session_mod.SessionManager,
    queue: *RequestQueue,
};

fn gatewayWorkerMain(ctx: *GatewayWorkerContext) void {
    while (true) {
        const conn = ctx.queue.popWait() orelse break;
        handleAcceptedConnection(ctx.allocator, ctx.config_opt, ctx.state, ctx.session_mgr_opt, conn);
    }
}

/// Run the HTTP gateway. Binds to host:port and serves HTTP requests.
/// Endpoints: GET /health, GET /ready, POST /pair, POST /webhook, GET|POST /whatsapp, POST /telegram, POST /slack/events, POST /line, POST /lark
/// If config_ptr is null, loads config internally (for backward compatibility).
pub fn run(allocator: std.mem.Allocator, host: []const u8, port: u16, config_ptr: ?*const Config, event_bus: ?*bus_mod.Bus) !void {
    return runWithRole(allocator, host, port, config_ptr, event_bus, .shared, null, null, null);
}

fn registerUserCellWithController(
    allocator: std.mem.Allocator,
    state: *const GatewayState,
) !void {
    if (state.role != .user_cell) return;
    const controller_url = state.controller_url orelse return;
    const user_id = state.pinned_user_id orelse return error.UserCellRequiresPinnedUser;
    const controller_token = firstConfiguredInternalServiceToken(state.internal_service_tokens) orelse
        return error.ControllerTokenMissing;
    const advertise_url = state.advertise_url orelse return error.UserCellRequiresAdvertiseUrl;
    const payload = try buildCellEnsurePayload(allocator, user_id, advertise_url);
    defer allocator.free(payload);

    const ensure_url = try controllerUrlWithPath(allocator, controller_url, "/internal/cells/ensure");
    defer allocator.free(ensure_url);
    const token_header = try std.fmt.allocPrint(allocator, "X-Internal-Token: {s}", .{controller_token});
    defer allocator.free(token_header);

    const response = try http_util.curlRequest(
        allocator,
        "POST",
        ensure_url,
        &[_][]const u8{
            "User-Agent: nullalis-user-cell/1.0",
            token_header,
            "Content-Type: application/json",
        },
        payload,
        null,
        "10",
    );
    defer allocator.free(response.body);

    if (response.status_code != 200) return error.ControllerRegistrationFailed;
}

const UserCellRegistrationContext = struct {
    state: *const GatewayState,
};

fn userCellRegistrationMain(ctx: *UserCellRegistrationContext) void {
    while (!ctx.state.shutdown_requested.load(.acquire)) {
        var slept_secs: u64 = 0;
        while (slept_secs < USER_CELL_REGISTRATION_REFRESH_SECS and !ctx.state.shutdown_requested.load(.acquire)) : (slept_secs += 1) {
            std.Thread.sleep(std.time.ns_per_s);
        }
        if (ctx.state.shutdown_requested.load(.acquire)) break;

        registerUserCellWithController(std.heap.page_allocator, ctx.state) catch |err| {
            log.warn("user cell controller re-registration failed: {}", .{err});
        };
    }
}

pub fn runWithRole(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    config_ptr: ?*const Config,
    event_bus: ?*bus_mod.Bus,
    role: GatewayRole,
    controller_url: ?[]const u8,
    advertise_url: ?[]const u8,
    pinned_user_id: ?[]const u8,
) !void {
    health.markComponentOk("gateway");

    if (role == .user_cell and pinned_user_id == null) {
        return error.UserCellRequiresPinnedUser;
    }
    if (role == .user_cell and controller_url != null and advertise_url == null) {
        return error.UserCellRequiresAdvertiseUrl;
    }

    var state = GatewayState.init(allocator);
    defer state.deinit();
    state.role = role;
    state.controller_url = controller_url;
    if (advertise_url) |value| {
        state.advertise_url = try normalizeAdvertiseUrl(allocator, value);
        state.advertise_url_owned = true;
    }
    if (pinned_user_id) |value| {
        state.pinned_user_id = try allocator.dupe(u8, value);
        state.pinned_user_id_owned = true;
    }
    state.event_bus = event_bus;

    var owned_config: ?Config = null;
    var config_opt: ?*const Config = null;
    if (config_ptr) |cfg| {
        config_opt = cfg;
    } else {
        owned_config = Config.load(allocator) catch null;
        if (owned_config) |*c| {
            config_opt = c;
        }
    }
    defer if (owned_config) |*c| c.deinit();
    if (role == .user_cell and config_opt == null) {
        return error.UserCellRequiresConfig;
    }

    // Provider runtime bundle (primary + reliability wrapper) must outlive the accept loop.
    var provider_bundle_opt: ?providers.runtime_bundle.RuntimeProviderBundle = null;
    var session_mgr_opt: ?session_mod.SessionManager = null;
    var tools_slice: []const tools_mod.Tool = &.{};
    var mem_rt: ?memory_mod.MemoryRuntime = null;
    var subagent_manager_opt: ?*subagent_mod.SubagentManager = null;
    var completion_router_opt: ?*SubagentCompletionRouter = null;
    var sec_tracker_opt: ?security.RateTracker = null;
    var sec_policy_opt: ?security.SecurityPolicy = null;
    var log_obs_gateway = observability.LogObserver{};
    var metrics_obs_gateway = LifecycleMetricsObserver{ .metrics = &state.lifecycle_metrics };
    var gateway_observer_slots: [2]Observer = undefined;
    var gateway_observer_multi = observability.MultiObserver{ .observers = &.{} };
    const needs_local_agent = gatewayRoleNeedsLocalAgent(role, event_bus != null);

    if (config_opt) |cfg_ptr| {
        const cfg = cfg_ptr;
        if (role == .user_cell and !cfg.tenant.enabled) {
            return error.UserCellRequiresTenantMode;
        }
        var postgres_init_error: ?anyerror = null;
        state.rate_limiter = GatewayRateLimiter.init(
            cfg.gateway.pair_rate_limit_per_minute,
            cfg.gateway.webhook_rate_limit_per_minute,
        );
        state.idempotency = IdempotencyStore.init(cfg.gateway.idempotency_ttl_secs);
        state.pairing_guard = try PairingGuard.init(
            allocator,
            cfg.gateway.require_pairing,
            cfg.gateway.paired_tokens,
        );
        if (cfg.channels.telegramPrimary()) |tg_cfg| {
            state.telegram_bot_token = tg_cfg.bot_token;
            state.telegram_allow_from = tg_cfg.allow_from;
            state.telegram_account_id = tg_cfg.account_id;
            state.telegram_webhook_secret_token = tg_cfg.webhook_secret_token orelse "";
        }
        if (cfg.channels.whatsappPrimary()) |wa_cfg| {
            state.whatsapp_verify_token = wa_cfg.verify_token;
            state.whatsapp_app_secret = wa_cfg.app_secret orelse "";
            state.whatsapp_access_token = wa_cfg.access_token;
            state.whatsapp_allow_from = wa_cfg.allow_from;
            state.whatsapp_group_allow_from = wa_cfg.group_allow_from;
            state.whatsapp_groups = wa_cfg.groups;
            state.whatsapp_group_policy = wa_cfg.group_policy;
            state.whatsapp_account_id = wa_cfg.account_id;
        }
        if (cfg.channels.linePrimary()) |line_cfg| {
            state.line_channel_secret = line_cfg.channel_secret;
            state.line_access_token = line_cfg.access_token;
            state.line_allow_from = line_cfg.allow_from;
            state.line_account_id = line_cfg.account_id;
        }
        if (cfg.channels.larkPrimary()) |lark_cfg| {
            state.lark_verification_token = lark_cfg.verification_token orelse "";
            state.lark_app_id = lark_cfg.app_id;
            state.lark_app_secret = lark_cfg.app_secret;
            state.lark_allow_from = lark_cfg.allow_from;
            state.lark_account_id = lark_cfg.account_id;
        }
        const production_like_gateway = isProductionLikeGateway(cfg, host);
        const token_validation = validateInternalTokensForMode(
            cfg.gateway.internal_service_tokens,
            production_like_gateway,
        );
        state.internal_auth_required = production_like_gateway;
        state.internal_token_policy_ok = token_validation.ok;
        state.internal_token_configured = token_validation.configured;
        state.internal_token_policy_reason = token_validation.reason orelse "";
        if (production_like_gateway and !token_validation.ok) {
            log.err(
                "security_config_invalid reason={s} host={s} tenant_enabled={s} allow_public_bind={s}",
                .{
                    token_validation.reason orelse "unknown",
                    host,
                    if (cfg.tenant.enabled) "true" else "false",
                    if (cfg.gateway.allow_public_bind) "true" else "false",
                },
            );
            return error.SecurityConfigInvalid;
        }
        state.internal_service_tokens = cfg.gateway.internal_service_tokens;
        state.require_explicit_chat_stream_session_key = cfg.gateway.require_explicit_chat_stream_session_key;
        state.tenant_enabled = cfg.tenant.enabled;
        state.tenant_data_root = cfg.tenant.data_root;
        state.workspace_dir = cfg.workspace_dir;
        state.tenant_runtime_cache_max_users = cfg.tenant.runtime_cache_max_users;
        state.tenant_runtime_idle_ttl_secs = cfg.tenant.runtime_idle_ttl_secs;
        if (std.mem.eql(u8, cfg.state.backend, "postgres")) init_state: {
            const mgr = allocator.create(zaki_state_mod.Manager) catch break :init_state;
            mgr.* = zaki_state_mod.Manager.init(allocator, cfg.state) catch |err| {
                allocator.destroy(mgr);
                postgres_init_error = err;
                log.warn("zaki state init failed, falling back to file state: {}", .{err});
                break :init_state;
            };
            state.zaki_state = mgr;
        }
        if (cfg.tenant.enabled) {
            const owner_id = tenant_lock.resolveOwnerId(allocator) catch null;
            const lock_cfg = normalizeTenantOwnershipLockConfig(cfg.tenant);
            if (owner_id) |oid| {
                state.owner_instance_id = oid;
                state.owner_instance_id_owned = true;
                state.ownership_lock_enabled = true;
                state.ownership_lock_lease_secs = lock_cfg.lease_secs;
                state.ownership_lock_wait_ms = lock_cfg.wait_ms;
                state.ownership_lock_retry_min_ms = lock_cfg.retry_min_ms;
                state.ownership_lock_retry_max_ms = lock_cfg.retry_max_ms;
            } else {
                log.warn("tenant ownership lock disabled: failed to resolve owner id", .{});
                state.ownership_lock_enabled = false;
            }
        }

        // In daemon mode (`event_bus` is present), inbound processing is delegated to
        // the bus + channel runtime. Avoid creating a second local agent runtime here.
        if (needs_local_agent) {
            sec_tracker_opt = security.RateTracker.init(allocator, cfg.autonomy.max_actions_per_hour);
            sec_policy_opt = .{
                .autonomy = cfg.autonomy.level,
                .workspace_dir = cfg.workspace_dir,
                .workspace_only = cfg.autonomy.workspace_only,
                .allowed_commands = if (cfg.autonomy.allowed_commands.len > 0) cfg.autonomy.allowed_commands else &security.default_allowed_commands,
                .max_actions_per_hour = cfg.autonomy.max_actions_per_hour,
                .require_approval_for_medium_risk = cfg.autonomy.require_approval_for_medium_risk,
                .block_high_risk_commands = cfg.autonomy.block_high_risk_commands,
                .tracker = if (sec_tracker_opt) |*tracker| tracker else null,
            };
            provider_bundle_opt = try providers.runtime_bundle.RuntimeProviderBundle.init(allocator, cfg);

            if (provider_bundle_opt) |*bundle| {
                const provider_i: providers.Provider = bundle.provider();
                const resolved_api_key = bundle.primaryApiKey();
                const memory_cfg = normalizedLocalAgentMemoryConfig(cfg);

                // Optional memory backend.
                mem_rt = memory_mod.initRuntimeWithOptions(allocator, &memory_cfg, cfg.workspace_dir, .{
                    .providers = cfg.providers,
                    .search_api_key_override = resolved_api_key,
                });

                const subagent_manager = allocator.create(subagent_mod.SubagentManager) catch null;
                if (subagent_manager) |mgr| {
                    mgr.* = subagent_mod.SubagentManager.init(allocator, cfg, event_bus, .{});
                    subagent_manager_opt = mgr;
                    completion_router_opt = allocator.create(SubagentCompletionRouter) catch null;
                }

                // Tools.
                tools_slice = tools_mod.allTools(allocator, cfg.workspace_dir, .{
                    .config = cfg,
                    .http_enabled = cfg.http_request.enabled,
                    .browser_enabled = cfg.browser.enabled,
                    .screenshot_enabled = true,
                    .composio_api_key = if (cfg.composio.enabled) cfg.composio.api_key else null,
                    .browser_open_domains = if (cfg.browser.allowed_domains.len > 0) cfg.browser.allowed_domains else null,
                    .agents = cfg.agents,
                    .fallback_api_key = resolved_api_key,
                    .event_bus = event_bus,
                    .tools_config = cfg.tools,
                    .allowed_paths = cfg.autonomy.allowed_paths,
                    .policy = if (sec_policy_opt) |*policy| policy else null,
                    .subagent_manager = subagent_manager_opt,
                }) catch &.{};

                const mem_opt: ?memory_mod.Memory = if (mem_rt) |rt| rt.memory else null;
                gateway_observer_slots = .{
                    log_obs_gateway.observer(),
                    metrics_obs_gateway.observer(),
                };
                gateway_observer_multi = .{ .observers = gateway_observer_slots[0..] };
                var sm = session_mod.SessionManager.init(allocator, cfg, provider_i, tools_slice, mem_opt, gateway_observer_multi.observer(), if (mem_rt) |rt| rt.session_store else null, if (mem_rt) |*rt| rt.response_cache else null);
                if (sec_policy_opt) |*policy| {
                    sm.policy = policy;
                }
                if (mem_rt) |*rt| {
                    sm.mem_rt = rt;
                    tools_mod.bindMemoryRuntime(tools_slice, rt);
                }
                session_mgr_opt = sm;
                if (subagent_manager_opt) |mgr| {
                    if (session_mgr_opt) |*session_mgr| {
                        if (completion_router_opt) |router| {
                            router.* = .{
                                .session_mgr = session_mgr,
                                .event_bus = event_bus,
                                .config = cfg,
                                .state = &state,
                            };
                            mgr.attachCompletionDelivery(@ptrCast(router), appendSubagentCompletionToGatewaySession);
                        }
                    }
                }
            }
        }

        applyStartupSelfCheck(&state, cfg, postgres_init_error);
        logStartupSelfCheck(&state);
    }
    if (state.pairing_guard == null) {
        state.pairing_guard = try PairingGuard.init(allocator, true, &.{});
    }
    defer if (provider_bundle_opt) |*bundle| bundle.deinit();
    defer if (mem_rt) |*rt| rt.deinit();
    defer if (subagent_manager_opt) |mgr| {
        mgr.deinit();
        allocator.destroy(mgr);
    };
    defer if (completion_router_opt) |router| allocator.destroy(router);
    defer if (tools_slice.len > 0) tools_mod.deinitTools(allocator, tools_slice);
    defer if (session_mgr_opt) |*sm| sm.deinit();
    defer if (sec_tracker_opt) |*tracker| tracker.deinit();

    // Resolve the listen address
    const addr = try std.net.Address.resolveIp(host, port);
    var server = try addr.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();
    setListenerNonBlocking(&server);
    try registerUserCellWithController(allocator, &state);

    var user_cell_registration_ctx = UserCellRegistrationContext{
        .state = &state,
    };
    const user_cell_registration_thread = if (role == .user_cell and state.controller_url != null)
        try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, userCellRegistrationMain, .{&user_cell_registration_ctx})
    else
        null;
    defer if (user_cell_registration_thread) |thread| {
        state.shutdown_requested.store(true, .release);
        thread.join();
    };

    var stdout_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &bw.interface;
    try stdout.print("Gateway listening on {s}:{d}\n", .{ host, port });
    try stdout.flush();
    if (config_opt) |cfg| {
        // In daemon mode the parent already prints model/provider.
        if (config_ptr == null) cfg.printModelConfig();
    }
    if (state.pairing_guard) |*guard| {
        if (guard.pairingCode()) |code| {
            try stdout.print("Gateway pairing code: {s}\n", .{code});
            try stdout.flush();
        }
    }

    const max_workers: usize = if (config_opt) |cfg|
        @intCast(@max(@as(u16, 1), cfg.gateway.max_workers))
    else
        1;
    const max_queued_requests: usize = if (config_opt) |cfg|
        @intCast(@max(@as(u32, 1), cfg.gateway.max_queued_requests))
    else
        1024;
    const overload_retry_after_secs: u16 = if (config_opt) |cfg|
        @max(@as(u16, 1), cfg.gateway.overload_retry_after_secs)
    else
        2;

    var request_queue = RequestQueue.init(allocator, max_queued_requests);
    defer request_queue.deinit();

    var worker_contexts = try allocator.alloc(GatewayWorkerContext, max_workers);
    defer allocator.free(worker_contexts);
    var worker_threads = try allocator.alloc(std.Thread, max_workers);
    defer allocator.free(worker_threads);

    for (0..max_workers) |i| {
        worker_contexts[i] = .{
            .allocator = allocator,
            .config_opt = config_opt,
            .state = &state,
            .session_mgr_opt = if (session_mgr_opt) |*sm| sm else null,
            .queue = &request_queue,
        };
        worker_threads[i] = try std.Thread.spawn(
            .{ .stack_size = 512 * 1024 },
            gatewayWorkerMain,
            .{&worker_contexts[i]},
        );
    }
    defer {
        request_queue.close();
        for (worker_threads) |thread| thread.join();
    }

    var last_tenant_runtime_maintenance_s: i64 = 0;

    // Accept loop — one acceptor thread, bounded queue + worker pool.
    while (true) {
        if (state.shutdown_requested.load(.acquire) and
            state.in_flight_requests.load(.acquire) == 0 and
            request_queue.len() == 0)
        {
            break;
        }

        const conn = server.accept() catch |err| switch (err) {
            error.WouldBlock => {
                const now_s = std.time.timestamp();
                if (now_s - last_tenant_runtime_maintenance_s >= TENANT_RUNTIME_MAINTENANCE_INTERVAL_SECS) {
                    runTenantRuntimeMaintenance(&state, now_s);
                    last_tenant_runtime_maintenance_s = now_s;
                }
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            },
            else => continue,
        };
        if (!request_queue.push(conn)) {
            _ = state.overload_rejected_total.fetchAdd(1, .monotonic);
            sendHttpResponseRetryAfter(
                conn.stream,
                "503 Service Unavailable",
                "application/json",
                "{\"error\":\"overloaded\",\"retry_hint\":\"retry shortly\"}",
                overload_retry_after_secs,
            ) catch {};
            conn.stream.close();
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────

test "constants are set correctly" {
    try std.testing.expectEqual(@as(usize, 65_536), MAX_BODY_SIZE);
    try std.testing.expectEqual(@as(u64, 30), REQUEST_TIMEOUT_SECS);
    try std.testing.expectEqual(@as(u64, 60), RATE_LIMIT_WINDOW_SECS);
}

test "rate limiter allows up to limit" {
    var limiter = SlidingWindowRateLimiter.init(2, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "127.0.0.1"));
}

test "rate limiter zero limit always allows" {
    var limiter = SlidingWindowRateLimiter.init(0, 60);
    defer limiter.deinit(std.testing.allocator);

    for (0..100) |_| {
        try std.testing.expect(limiter.allow(std.testing.allocator, "any-key"));
    }
}

test "rate limiter different keys are independent" {
    var limiter = SlidingWindowRateLimiter.init(1, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "ip-1"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "ip-1"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "ip-2"));
}

test "gateway rate limiter blocks after limit" {
    var limiter = GatewayRateLimiter.init(2, 2);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allowPair(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(limiter.allowPair(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(!limiter.allowPair(std.testing.allocator, "127.0.0.1"));
}

test "idempotency store rejects duplicate key" {
    var store = IdempotencyStore.init(30);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "req-1"));
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "req-1"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "req-2"));
}

test "idempotency store allows different keys" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "a"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "b"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "c"));
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "a"));
}

test "gateway module compiles" {
    // Compile-time check only
}

test "findWebhookRouteDescriptor resolves known webhook paths" {
    try std.testing.expect(findWebhookRouteDescriptor("/telegram") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/webhook/telegram") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/whatsapp") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/slack/events") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/line") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/lark") != null);
    try std.testing.expect(findWebhookRouteDescriptor("/health") == null);
}

// ── Additional gateway tests ────────────────────────────────────

test "rate limiter single request allowed" {
    var limiter = SlidingWindowRateLimiter.init(1, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "test-key"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "test-key"));
}

test "rate limiter high limit" {
    var limiter = SlidingWindowRateLimiter.init(100, 60);
    defer limiter.deinit(std.testing.allocator);

    for (0..100) |_| {
        try std.testing.expect(limiter.allow(std.testing.allocator, "ip"));
    }
    try std.testing.expect(!limiter.allow(std.testing.allocator, "ip"));
}

test "gateway rate limiter pair and webhook independent" {
    var limiter = GatewayRateLimiter.init(1, 1);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allowPair(std.testing.allocator, "ip"));
    try std.testing.expect(!limiter.allowPair(std.testing.allocator, "ip"));
    // Webhook should still be allowed since it's separate
    try std.testing.expect(limiter.allowWebhook(std.testing.allocator, "ip"));
    try std.testing.expect(!limiter.allowWebhook(std.testing.allocator, "ip"));
}

test "gateway rate limiter zero limits always allow" {
    var limiter = GatewayRateLimiter.init(0, 0);
    defer limiter.deinit(std.testing.allocator);

    for (0..50) |_| {
        try std.testing.expect(limiter.allowPair(std.testing.allocator, "any"));
        try std.testing.expect(limiter.allowWebhook(std.testing.allocator, "any"));
    }
}

test "idempotency store init with various TTLs" {
    var store1 = IdempotencyStore.init(1);
    defer store1.deinit(std.testing.allocator);
    try std.testing.expect(store1.ttl_ns > 0);

    var store2 = IdempotencyStore.init(3600);
    defer store2.deinit(std.testing.allocator);
    try std.testing.expect(store2.ttl_ns > store1.ttl_ns);
}

test "idempotency store zero TTL treated as 1 second" {
    var store = IdempotencyStore.init(0);
    defer store.deinit(std.testing.allocator);
    // Should use @max(0, 1) = 1 second
    try std.testing.expectEqual(@as(i128, 1_000_000_000), store.ttl_ns);
}

test "idempotency store many unique keys" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    // Use distinct string literals to avoid buffer aliasing
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-alpha"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-beta"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-gamma"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-delta"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-epsilon"));
}

test "idempotency store duplicate after many inserts" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "first"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "second"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "third"));
    // First key should still be duplicate
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "first"));
}

test "idempotency store copies transient key memory" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    var key_buf: [32]u8 = undefined;
    const transient_key = try std.fmt.bufPrint(&key_buf, "req-{d}", .{123});
    try std.testing.expect(store.recordIfNew(std.testing.allocator, transient_key));

    @memset(&key_buf, 'x');
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "req-123"));
}

test "rate limiter copies transient key memory" {
    var limiter = SlidingWindowRateLimiter.init(2, 60);
    defer limiter.deinit(std.testing.allocator);

    var key_buf: [48]u8 = undefined;
    const transient_key = try std.fmt.bufPrint(&key_buf, "tenant-{d}", .{42});
    try std.testing.expect(limiter.allow(std.testing.allocator, transient_key));

    @memset(&key_buf, 'x');
    try std.testing.expect(limiter.allow(std.testing.allocator, "tenant-42"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "tenant-42"));
}

test "rate limiter window_ns calculation" {
    const limiter = SlidingWindowRateLimiter.init(10, 120);
    try std.testing.expectEqual(@as(i128, 120_000_000_000), limiter.window_ns);
}

test "MAX_BODY_SIZE is 64KB" {
    try std.testing.expectEqual(@as(usize, 64 * 1024), MAX_BODY_SIZE);
}

test "RATE_LIMIT_WINDOW_SECS is 60" {
    try std.testing.expectEqual(@as(u64, 60), RATE_LIMIT_WINDOW_SECS);
}

test "REQUEST_TIMEOUT_SECS is 30" {
    try std.testing.expectEqual(@as(u64, 30), REQUEST_TIMEOUT_SECS);
}

test "rate limiter different keys do not interfere" {
    var limiter = SlidingWindowRateLimiter.init(2, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "key-a"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "key-b"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "key-a"));
    // key-a should now be at limit
    try std.testing.expect(!limiter.allow(std.testing.allocator, "key-a"));
    // key-b still has room
    try std.testing.expect(limiter.allow(std.testing.allocator, "key-b"));
}

// ── WhatsApp / parseQueryParam tests ────────────────────────────

test "parseQueryParam extracts single param" {
    const val = parseQueryParam("/whatsapp?hub.mode=subscribe", "hub.mode");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("subscribe", val.?);
}

test "parseQueryParam extracts param from multiple" {
    const target = "/whatsapp?hub.mode=subscribe&hub.verify_token=mytoken&hub.challenge=abc123";
    try std.testing.expectEqualStrings("subscribe", parseQueryParam(target, "hub.mode").?);
    try std.testing.expectEqualStrings("mytoken", parseQueryParam(target, "hub.verify_token").?);
    try std.testing.expectEqualStrings("abc123", parseQueryParam(target, "hub.challenge").?);
}

test "parseQueryParam returns null for missing param" {
    const val = parseQueryParam("/whatsapp?hub.mode=subscribe", "hub.challenge");
    try std.testing.expect(val == null);
}

test "parseQueryParam returns null for no query string" {
    const val = parseQueryParam("/whatsapp", "hub.mode");
    try std.testing.expect(val == null);
}

test "parseQueryParam empty value" {
    const val = parseQueryParam("/path?key=", "key");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("", val.?);
}

test "parseQueryParam partial key match does not match" {
    const val = parseQueryParam("/path?hub.mode_extra=subscribe", "hub.mode");
    try std.testing.expect(val == null);
}

test "jsonStringArrayFieldOwned extracts string list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = "{\"allow_from\":[\"12345\",\"alice\"]}";
    const arr = jsonStringArrayFieldOwned(allocator, body, "allow_from");
    try std.testing.expect(arr != null);
    try std.testing.expectEqual(@as(usize, 2), arr.?.len);
    try std.testing.expectEqualStrings("12345", arr.?[0]);
    try std.testing.expectEqualStrings("alice", arr.?[1]);
}

test "parseTelegramUserState parses user-scoped telegram settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body =
        \\{"connected":true,"account_id":"work","webhook_secret_token":"sec-12345","allow_from":["user1","user2"],"webhook_url":"https://example.com/webhook/telegram?user_id=1","chat_id":1110331014}
    ;
    var state = try parseTelegramUserState(allocator, body);
    defer state.deinit(allocator);

    try std.testing.expect(state.connected);
    try std.testing.expectEqualStrings("work", state.account_id.?);
    try std.testing.expectEqualStrings("sec-12345", state.webhook_secret_token.?);
    try std.testing.expectEqual(@as(usize, 2), state.allow_from.len);
    try std.testing.expectEqualStrings("user1", state.allow_from[0]);
    try std.testing.expectEqualStrings("user2", state.allow_from[1]);
    try std.testing.expectEqualStrings("https://example.com/webhook/telegram?user_id=1", state.webhook_url.?);
    try std.testing.expectEqual(@as(i64, 1110331014), state.chat_id.?);
}

test "parseTelegramUserState normalizes webhook secret token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body =
        \\{"connected":true,"account_id":"work","webhook_secret_token":"  \"sec-12345\"  "}
    ;
    var state = try parseTelegramUserState(allocator, body);
    defer state.deinit(allocator);

    try std.testing.expect(state.webhook_secret_token != null);
    try std.testing.expectEqualStrings("sec-12345", state.webhook_secret_token.?);
}

test "parseTelegramUserState normalizes legacy wildcard allowlist to empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body =
        \\{"connected":true,"allow_from":["*"]}
    ;
    var state = try parseTelegramUserState(allocator, body);
    defer state.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), state.allow_from.len);
}

test "parseTelegramUserState rejects invalid account_id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body =
        \\{"connected":true,"account_id":"../../bad","webhook_secret_token":"secret"}
    ;
    try std.testing.expectError(error.InvalidTelegramState, parseTelegramUserState(allocator, body));
}

test "normalizeTelegramSecretToken trims whitespace and quotes" {
    try std.testing.expectEqualStrings("abc123", normalizeTelegramSecretToken("  \"abc123\" \r\n"));
    try std.testing.expectEqualStrings("", normalizeTelegramSecretToken(" \t\r\n\"\""));
}

test "normalizeTelegramBotToken trims wrapping quotes" {
    try std.testing.expectEqualStrings("123:ABC_def-ghi", normalizeTelegramBotToken("  \"123:ABC_def-ghi\"  "));
    try std.testing.expectEqualStrings("123:ABC_def-ghi", normalizeTelegramBotToken("  '123:ABC_def-ghi'  "));
}

test "isLikelyTelegramBotToken accepts quoted valid token and rejects json blob" {
    try std.testing.expect(isLikelyTelegramBotToken(" \"123456789:AAABBBccc___---\" "));
    try std.testing.expect(!isLikelyTelegramBotToken("{\"key\":\"telegram_bot_token\",\"value\":\"123:ABC\"}"));
}

test "normalizeTelegramBotToken extracts valid token from wrapped blob" {
    const wrapped = "{\"key\":\"telegram_bot_token\",\"value\":\"123456789:AAABBBccc___---\"}";
    try std.testing.expectEqualStrings("123456789:AAABBBccc___---", normalizeTelegramBotToken(wrapped));
    try std.testing.expect(isLikelyTelegramBotToken(wrapped));
}

test "readTrimmedSecretFile trims trailing whitespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = "token.txt";
    const f = try tmp.dir.createFile(rel_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll("abc123  \n");

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, rel_path);
    defer std.testing.allocator.free(path);

    const value = try readTrimmedSecretFile(std.testing.allocator, path);
    defer if (value.len > 0) std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("abc123", value);
}

test "writeTelegramChannelState writes valid nested telegram state json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = "channel_state.json";
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root, rel_path });
    defer std.testing.allocator.free(path);

    try writeTelegramChannelState(std.testing.allocator, path, "main", 123456789);

    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, content, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("telegram") != null);
    try std.testing.expect(parsed.value.object.get("telegram").? == .object);
    const telegram = parsed.value.object.get("telegram").?.object;
    try std.testing.expectEqual(@as(i64, 123456789), telegram.get("chat_id").?.integer);
}

test "GatewayState initWithVerifyToken stores token" {
    var state = GatewayState.initWithVerifyToken(std.testing.allocator, "test-verify-token");
    defer state.deinit();
    try std.testing.expectEqualStrings("test-verify-token", state.whatsapp_verify_token);
}

test "GatewayState init has empty verify token" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqualStrings("", state.whatsapp_verify_token);
}

test "handleApiRoute accepts POST alias for telegram disconnect" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "POST /api/v1/users/1/channels/telegram/disconnect HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "POST",
        "/api/v1/users/1/channels/telegram/disconnect",
        &state,
        null,
        null,
    );

    try std.testing.expectEqualStrings("200 OK", response.status);
    try std.testing.expectEqualStrings("{\"status\":\"disconnected\",\"channel\":\"telegram\"}", response.body);
}

test "handleApiRoute GET onboarding returns setup contract for settings panel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/1/onboarding HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );
    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "GET",
        "/api/v1/users/1/onboarding",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", response.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(false, parsed.value.object.get("completed").?.bool);
    try std.testing.expect(parsed.value.object.get("completed_at_s").? == .null);

    const setup = parsed.value.object.get("setup").?.object;
    try std.testing.expectEqual(true, setup.get("can_start_chat_now").?.bool);
    try std.testing.expectEqual(true, setup.get("onboarding_ready_normalized").?.bool);
    try std.testing.expectEqualStrings("ready_in_app", setup.get("client_ready_status").?.string);
    try std.testing.expectEqual(false, setup.get("telegram_connected_normalized").?.bool);
    try std.testing.expectEqual(true, setup.get("telegram_state_valid").?.bool);
    try std.testing.expectEqual(false, setup.get("heartbeat_enabled_normalized").?.bool);
    const settings = setup.get("settings").?.object;
    try std.testing.expectEqualStrings("/api/v1/users/1/settings", settings.get("endpoint").?.string);
    const defaults = settings.get("defaults").?.object;
    try std.testing.expectEqualStrings("balanced", defaults.get("assistant_mode").?.string);

    const guides = setup.get("channel_guides").?.object;
    const telegram = guides.get("telegram").?.object;
    try std.testing.expectEqual(build_options.enable_channel_telegram, telegram.get("available").?.bool);
    try std.testing.expectEqual(true, telegram.get("connect_supported").?.bool);
    try std.testing.expectEqualStrings("/api/v1/users/1/channels/telegram/connect", telegram.get("connect_endpoint").?.string);

    const slack = guides.get("slack").?.object;
    try std.testing.expectEqual(build_options.enable_channel_slack, slack.get("available").?.bool);
    try std.testing.expectEqual(false, slack.get("connect_supported").?.bool);

    const discord = guides.get("discord").?.object;
    try std.testing.expectEqual(build_options.enable_channel_discord, discord.get("available").?.bool);
    try std.testing.expectEqual(false, discord.get("connect_supported").?.bool);
}

test "handleApiRoute GET onboarding reports minimum_required when model/provider missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var cfg = Config{
        .workspace_dir = "/tmp/nullalis",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    cfg.default_provider = "";
    cfg.default_model = "";

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/1/onboarding HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );
    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "GET",
        "/api/v1/users/1/onboarding",
        &state,
        &cfg,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", response.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.body, .{});
    defer parsed.deinit();
    const setup = parsed.value.object.get("setup").?.object;
    try std.testing.expectEqual(false, setup.get("can_start_chat_now").?.bool);
    try std.testing.expectEqual(false, setup.get("onboarding_ready_normalized").?.bool);
    try std.testing.expectEqualStrings("operator_action_required", setup.get("client_ready_status").?.string);
    const minimum_required = setup.get("minimum_required").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), minimum_required.len);
    try std.testing.expectEqualStrings("operator_configure_model_provider", minimum_required[0].string);
}

test "handleApiRoute GET onboarding reflects connected telegram status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    const user_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/1", .{tenant_root});
    defer std.testing.allocator.free(user_dir);
    try std.fs.makeDirAbsolute(user_dir);
    const telegram_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/telegram.json", .{user_dir});
    defer std.testing.allocator.free(telegram_path);
    try writeFile(telegram_path, "{\"connected\":true,\"account_id\":\"main\",\"webhook_url\":\"https://example.com/webhook/telegram?user_id=1\"}\n");
    const secrets_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/secrets", .{user_dir});
    defer std.testing.allocator.free(secrets_dir);
    try std.fs.makeDirAbsolute(secrets_dir);
    const token_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/telegram_bot_token", .{secrets_dir});
    defer std.testing.allocator.free(token_path);
    try writeFile(token_path, "123456:ABCDEF\n");
    const heartbeat_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/heartbeat.json", .{user_dir});
    defer std.testing.allocator.free(heartbeat_path);
    try writeFile(heartbeat_path, "{\"enabled\":true}\n");

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/1/onboarding HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );
    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "GET",
        "/api/v1/users/1/onboarding",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", response.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.body, .{});
    defer parsed.deinit();
    const setup = parsed.value.object.get("setup").?.object;
    try std.testing.expectEqual(true, setup.get("onboarding_ready_normalized").?.bool);
    try std.testing.expectEqualStrings("ready", setup.get("client_ready_status").?.string);
    try std.testing.expectEqual(true, setup.get("telegram_connected_normalized").?.bool);
    try std.testing.expectEqual(true, setup.get("telegram_state_valid").?.bool);
    try std.testing.expectEqual(true, setup.get("heartbeat_enabled_normalized").?.bool);
    const guides = setup.get("channel_guides").?.object;
    const telegram = guides.get("telegram").?.object;
    try std.testing.expectEqual(true, telegram.get("connected").?.bool);
    try std.testing.expectEqualStrings("connected", telegram.get("status").?.string);
}

test "handleApiRoute GET onboarding flags stale telegram webhook state as needs_reconnect" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    const user_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/42", .{tenant_root});
    defer std.testing.allocator.free(user_dir);
    try std.fs.makeDirAbsolute(user_dir);
    const telegram_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/telegram.json", .{user_dir});
    defer std.testing.allocator.free(telegram_path);
    try writeFile(telegram_path, "{\"connected\":true,\"account_id\":\"main\",\"webhook_url\":\"https://example.com/webhook/telegram?user_id=1\",\"allow_from\":[\"*\"]}\n");
    const secrets_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/secrets", .{user_dir});
    defer std.testing.allocator.free(secrets_dir);
    try std.fs.makeDirAbsolute(secrets_dir);
    const token_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/telegram_bot_token", .{secrets_dir});
    defer std.testing.allocator.free(token_path);
    try writeFile(token_path, "123456:ABCDEF\n");

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/42/onboarding HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );
    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "GET",
        "/api/v1/users/42/onboarding",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", response.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.body, .{});
    defer parsed.deinit();
    const setup = parsed.value.object.get("setup").?.object;
    try std.testing.expectEqual(false, setup.get("telegram_connected_normalized").?.bool);
    try std.testing.expectEqual(false, setup.get("telegram_state_valid").?.bool);
    try std.testing.expectEqualStrings("needs_reconnect", setup.get("client_ready_status").?.string);
    const guides = setup.get("channel_guides").?.object;
    const telegram = guides.get("telegram").?.object;
    try std.testing.expectEqual(false, telegram.get("connected").?.bool);
    try std.testing.expectEqualStrings("needs_reconnect", telegram.get("status").?.string);
}

test "handleApiRoute GET settings returns defaults when no profile exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/1/settings HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "GET",
        "/api/v1/users/1/settings",
        &state,
        null,
        null,
    );

    try std.testing.expectEqualStrings("200 OK", response.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("balanced", parsed.value.object.get("assistant_mode").?.string);
    try std.testing.expectEqualStrings("mention", parsed.value.object.get("group_activation").?.string);
    try std.testing.expectEqual(true, parsed.value.object.get("proactive_updates").?.bool);
    try std.testing.expectEqual(false, parsed.value.object.get("voice_replies").?.bool);
    try std.testing.expectEqual(@as(i64, 30), parsed.value.object.get("session_timeout_minutes").?.integer);
}

test "handleApiRoute GET settings ignores heartbeat state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    const user_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/1", .{tenant_root});
    defer std.testing.allocator.free(user_dir);
    try std.fs.makeDirAbsolute(user_dir);

    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{user_dir});
    defer std.testing.allocator.free(config_path);
    try writeFile(config_path, "{\"product_settings\":{\"assistant_mode\":\"balanced\",\"group_activation\":\"mention\",\"proactive_updates\":true,\"voice_replies\":false,\"session_timeout_minutes\":30}}\n");

    const heartbeat_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/heartbeat.json", .{user_dir});
    defer std.testing.allocator.free(heartbeat_path);
    try writeFile(heartbeat_path, "{\"enabled\":false}\n");

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/1/settings HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "GET",
        "/api/v1/users/1/settings",
        &state,
        null,
        null,
    );

    try std.testing.expectEqualStrings("200 OK", response.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(true, parsed.value.object.get("proactive_updates").?.bool);
}

test "handleApiRoute PATCH settings writes canonical tenant preferences and preserves unknown keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    const user_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/1", .{tenant_root});
    defer std.testing.allocator.free(user_dir);
    try std.fs.makeDirAbsolute(user_dir);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{user_dir});
    defer std.testing.allocator.free(config_path);
    try writeFile(config_path, "{\"foo\":\"bar\",\"agent\":{\"max_tool_iterations\":9}}\n");
    const heartbeat_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/heartbeat.json", .{user_dir});
    defer std.testing.allocator.free(heartbeat_path);
    try writeFile(heartbeat_path, "{\"enabled\":true}\n");

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const patch_body =
        \\{"assistant_mode":"deep","group_activation":"always","proactive_updates":false,"voice_replies":true,"session_timeout_minutes":45}
    ;
    const patch_request = try std.fmt.allocPrint(
        req_allocator,
        "PATCH /api/v1/users/1/settings HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ patch_body.len, patch_body },
    );

    const patch_response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        patch_request,
        "PATCH",
        "/api/v1/users/1/settings",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", patch_response.status);
    try std.testing.expect(std.mem.indexOf(u8, patch_response.body, "\"assistant_mode\":\"deep\"") != null);

    const get_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/1/config HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );
    const get_response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        get_request,
        "GET",
        "/api/v1/users/1/config",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", get_response.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, get_response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("bar", parsed.value.object.get("foo").?.string);
    const product = parsed.value.object.get("product_settings").?.object;
    try std.testing.expectEqualStrings("deep", product.get("assistant_mode").?.string);
    try std.testing.expectEqual(false, product.get("proactive_updates").?.bool);
    try std.testing.expect(parsed.value.object.get("agent") == null);
    try std.testing.expect(parsed.value.object.get("memory") == null);
    try std.testing.expect(parsed.value.object.get("session") == null);

    const heartbeat_get_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/1/heartbeat HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );
    const heartbeat_get_response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        heartbeat_get_request,
        "GET",
        "/api/v1/users/1/heartbeat",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", heartbeat_get_response.status);
    try std.testing.expectEqualStrings("{\"enabled\":true}", heartbeat_get_response.body);
}

test "handleApiRoute PATCH config rejects raw config writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"agent\":{\"queue_mode\":\"latest\"}}";
    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "PATCH /api/v1/users/1/config HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "PATCH",
        "/api/v1/users/1/config",
        &state,
        null,
        null,
    );

    try std.testing.expectEqualStrings("403 Forbidden", response.status);
    try std.testing.expectEqualStrings("{\"error\":\"raw_config_writes_disabled\"}", response.body);
}

test "handleApiRoute PATCH settings rejects invalid assistant mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"assistant_mode\":\"turbo\"}";
    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "PATCH /api/v1/users/1/settings HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "PATCH",
        "/api/v1/users/1/settings",
        &state,
        null,
        null,
    );

    try std.testing.expectEqualStrings("400 Bad Request", response.status);
    try std.testing.expectEqualStrings("{\"error\":\"invalid_assistant_mode\"}", response.body);
}

test "handleApiRoute PATCH settings clamps huge timeout without crashing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"session_timeout_minutes\":9223372036854775807}";
    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "PATCH /api/v1/users/1/settings HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "PATCH",
        "/api/v1/users/1/settings",
        &state,
        null,
        null,
    );

    try std.testing.expectEqualStrings("200 OK", response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"session_timeout_minutes\":180") != null);
}

test "handleApiRoute PUT heartbeat stores canonical enabled-only payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    const user_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/1", .{tenant_root});
    defer std.testing.allocator.free(user_dir);
    try std.fs.makeDirAbsolute(user_dir);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{user_dir});
    defer std.testing.allocator.free(config_path);
    try writeFile(config_path, "{\"product_settings\":{\"assistant_mode\":\"balanced\",\"group_activation\":\"mention\",\"proactive_updates\":false,\"voice_replies\":false,\"session_timeout_minutes\":30}}\n");

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"enabled\":true,\"intervalSec\":900,\"every\":\"15m\"}";
    const put_request = try std.fmt.allocPrint(
        req_allocator,
        "PUT /api/v1/users/1/heartbeat HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    const put_response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        put_request,
        "PUT",
        "/api/v1/users/1/heartbeat",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", put_response.status);
    try std.testing.expectEqualStrings("{\"enabled\":true}", put_response.body);

    const get_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/1/heartbeat HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );
    const get_response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        get_request,
        "GET",
        "/api/v1/users/1/heartbeat",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", get_response.status);
    try std.testing.expectEqualStrings("{\"enabled\":true}", get_response.body);

    const settings_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/1/settings HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );
    const settings_response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        settings_request,
        "GET",
        "/api/v1/users/1/settings",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", settings_response.status);
    const settings_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, settings_response.body, .{});
    defer settings_parsed.deinit();
    try std.testing.expectEqual(false, settings_parsed.value.object.get("proactive_updates").?.bool);
}

test "handleApiRoute GET heartbeat normalizes legacy stored payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    const user_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/1", .{tenant_root});
    defer std.testing.allocator.free(user_dir);
    try std.fs.makeDirAbsolute(user_dir);
    const heartbeat_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/heartbeat.json", .{user_dir});
    defer std.testing.allocator.free(heartbeat_path);
    try writeFile(heartbeat_path, "{\"heartbeat\":{\"enabled\":true},\"intervalSec\":3600}\n");

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const get_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/1/heartbeat HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );
    const get_response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        get_request,
        "GET",
        "/api/v1/users/1/heartbeat",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", get_response.status);
    try std.testing.expectEqualStrings("{\"enabled\":true}", get_response.body);
}

test "handleApiRoute PUT heartbeat rejects payload without enabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"intervalSec\":900}";
    const put_request = try std.fmt.allocPrint(
        req_allocator,
        "PUT /api/v1/users/1/heartbeat HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    const put_response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        put_request,
        "PUT",
        "/api/v1/users/1/heartbeat",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("400 Bad Request", put_response.status);
    try std.testing.expectEqualStrings("{\"error\":\"missing enabled\"}", put_response.body);
}

test "ownership_lock_conflict_http_returns_structured_payload_and_retry_after" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);
    const user_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/1", .{tenant_root});
    defer std.testing.allocator.free(user_root);
    try std.fs.makeDirAbsolute(user_root);

    var held_lock = try tenant_lock.acquireUserOwnershipLock(std.testing.allocator, user_root, "owner-b", 300);
    defer held_lock.deinit();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_enabled = true;
    state.ownership_lock_enabled = true;
    state.owner_instance_id = "owner-a";
    state.tenant_data_root = tenant_root;
    state.ownership_lock_wait_ms = 120;
    state.ownership_lock_retry_min_ms = 20;
    state.ownership_lock_retry_max_ms = 20;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"assistant_mode\":\"deep\"}";
    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "PATCH /api/v1/users/1/settings HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "PATCH",
        "/api/v1/users/1/settings",
        &state,
        null,
        null,
    );

    try std.testing.expectEqualStrings("409 Conflict", response.status);
    try std.testing.expect(response.retry_after_secs != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ownership_lock_conflict", parsed.value.object.get("error").?.string);
    try std.testing.expect(parsed.value.object.get("retry_after_ms").? == .integer);
}

test "ownership_lock_conflict_sse_contains_retry_after_ms" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);
    const user_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/1", .{tenant_root});
    defer std.testing.allocator.free(user_root);
    try std.fs.makeDirAbsolute(user_root);

    var held_lock = try tenant_lock.acquireUserOwnershipLock(std.testing.allocator, user_root, "owner-b", 300);
    defer held_lock.deinit();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_enabled = true;
    state.ownership_lock_enabled = true;
    state.owner_instance_id = "owner-a";
    state.tenant_data_root = tenant_root;
    state.ownership_lock_wait_ms = 120;
    state.ownership_lock_retry_min_ms = 20;
    state.ownership_lock_retry_max_ms = 20;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"message\":\"hello\"}";
    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "POST /api/v1/chat/stream HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nX-Zaki-User-Id: 1\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "POST",
        "/api/v1/chat/stream",
        &state,
        null,
        null,
    );

    try std.testing.expectEqualStrings("409 Conflict", response.status);
    try std.testing.expectEqualStrings("text/event-stream; charset=utf-8", response.content_type);
    try std.testing.expect(response.retry_after_secs != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"code\":\"ownership_lock_conflict\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"retry_after_ms\":") != null);
}

test "ownership_lock_wait_budget_retries_then_conflicts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);
    const user_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/7", .{tenant_root});
    defer std.testing.allocator.free(user_root);
    try std.fs.makeDirAbsolute(user_root);

    var held_lock = try tenant_lock.acquireUserOwnershipLock(std.testing.allocator, user_root, "owner-b", 300);
    defer held_lock.deinit();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_enabled = true;
    state.ownership_lock_enabled = true;
    state.owner_instance_id = "owner-a";
    state.ownership_lock_wait_ms = 60;
    state.ownership_lock_retry_min_ms = 20;
    state.ownership_lock_retry_max_ms = 20;

    var acquired = try maybeAcquireTenantOwnershipLock(std.testing.allocator, &state, "7", user_root);
    defer acquired.deinit();

    switch (acquired) {
        .conflict => |conflict| {
            try std.testing.expect(conflict.retries >= 1);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(state.tenant_lock_conflict_retries_total.load(.monotonic) > 0);
}

test "ownership_lock_wait_succeeds_within_budget_when_lease_released" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);
    const user_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/9", .{tenant_root});
    defer std.testing.allocator.free(user_root);
    try std.fs.makeDirAbsolute(user_root);

    var held_lock = try tenant_lock.acquireUserOwnershipLock(std.testing.allocator, user_root, "owner-b", 1);
    defer held_lock.deinit();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_enabled = true;
    state.ownership_lock_enabled = true;
    state.owner_instance_id = "owner-a";
    state.ownership_lock_wait_ms = 1500;
    state.ownership_lock_retry_min_ms = 100;
    state.ownership_lock_retry_max_ms = 100;

    var acquired = try maybeAcquireTenantOwnershipLock(std.testing.allocator, &state, "9", user_root);
    defer acquired.deinit();

    switch (acquired) {
        .acquired => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(state.tenant_lock_conflict_retries_total.load(.monotonic) > 0);
}

test "users provision route succeeds even when ownership lock is held in file mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);
    const user_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/1", .{tenant_root});
    defer std.testing.allocator.free(user_root);
    try std.fs.makeDirAbsolute(user_root);

    var held_lock = try tenant_lock.acquireUserOwnershipLock(std.testing.allocator, user_root, "owner-b", 300);
    defer held_lock.deinit();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_enabled = true;
    state.ownership_lock_enabled = true;
    state.owner_instance_id = "owner-a";
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"user_id\":\"1\"}";
    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "POST /api/v1/users/provision HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "POST",
        "/api/v1/users/provision",
        &state,
        null,
        null,
    );

    try std.testing.expectEqualStrings("200 OK", response.status);
    try std.testing.expectEqualStrings("{\"status\":\"provisioned\"}", response.body);
}

test "prepareBrokerUserForRouting bootstraps broker file-mode user state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.role = .broker;
    state.tenant_enabled = true;
    state.tenant_data_root = tenant_root;

    try prepareBrokerUserForRouting(std.testing.allocator, &state, "42");

    const workspace_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/42/workspace", .{tenant_root});
    defer std.testing.allocator.free(workspace_path);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/42/config.json", .{tenant_root});
    defer std.testing.allocator.free(config_path);

    try std.fs.accessAbsolute(workspace_path, .{});
    try std.fs.accessAbsolute(config_path, .{});
}

test "user_cell users provision route rejects mismatched user" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.role = .user_cell;
    state.pinned_user_id = "1";
    state.tenant_enabled = true;
    state.tenant_data_root = tenant_root;
    state.workspace_dir = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"user_id\":\"2\"}";
    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "POST /api/v1/users/provision HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "POST",
        "/api/v1/users/provision",
        &state,
        null,
        null,
    );

    try std.testing.expectEqualStrings("403 Forbidden", response.status);
    try std.testing.expectEqualStrings("{\"error\":\"wrong_user_cell\"}", response.body);
}

test "user_cell chat stream route uses pinned user without header" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.role = .user_cell;
    state.pinned_user_id = "1";
    state.tenant_enabled = true;
    state.tenant_data_root = tenant_root;
    state.workspace_dir = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"message\":\"hi\"}";
    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "POST /api/v1/chat/stream HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "POST",
        "/api/v1/chat/stream",
        &state,
        null,
        null,
    );

    try std.testing.expectEqualStrings("400 Bad Request", response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "missing_session_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "missing X-Zaki-User-Id") == null);
}

test "handleApiRoute chat stream includes buffered progress and reasoning summaries" {
    const TestProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{
                .content = try allocator.dupe(u8, "Hello from buffered SSE"),
                .tool_calls = &.{},
                .usage = .{ .prompt_tokens = 8, .completion_tokens = 4, .total_tokens = 12 },
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "test-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{workspace});
    defer std.testing.allocator.free(config_path);

    var cfg = Config{
        .workspace_dir = workspace,
        .config_path = config_path,
        .default_model = "test/mock-model",
        .allocator = std.testing.allocator,
    };

    var provider_state: u8 = 0;
    const provider_vtable = providers.Provider.VTable{
        .chatWithSystem = TestProvider.chatWithSystem,
        .chat = TestProvider.chat,
        .supportsNativeTools = TestProvider.supportsNativeTools,
        .getName = TestProvider.getName,
        .deinit = TestProvider.deinitFn,
    };
    const provider = providers.Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };
    var noop = observability.NoopObserver{};
    var session_mgr = session_mod.SessionManager.init(
        std.testing.allocator,
        &cfg,
        provider,
        &.{},
        null,
        noop.observer(),
        null,
        null,
    );
    defer session_mgr.deinit();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = workspace;
    state.workspace_dir = workspace;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"message\":\"hello\",\"session_key\":\"session:1\"}";
    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "POST /api/v1/chat/stream HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nX-Zaki-User-Id: 1\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "POST",
        "/api/v1/chat/stream",
        &state,
        null,
        &session_mgr,
    );

    try std.testing.expectEqualStrings("200 OK", response.status);
    try std.testing.expectEqualStrings("text/event-stream; charset=utf-8", response.content_type);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "event: status") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "event: progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "event: reasoning_summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "event: reply_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"stream_kind\":\"final_reply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"live\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "Hello from buffered SSE") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "event: done") != null);
}

test "handleApiRoute chat stream leaves pending subagent completions for dedicated events stream" {
    const TestProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            return .{
                .content = try allocator.dupe(u8, "Main reply"),
                .tool_calls = &.{},
                .usage = .{ .prompt_tokens = 8, .completion_tokens = 4, .total_tokens = 12 },
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "test-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{workspace});
    defer std.testing.allocator.free(config_path);

    var cfg = Config{
        .workspace_dir = workspace,
        .config_path = config_path,
        .default_model = "test/mock-model",
        .allocator = std.testing.allocator,
    };

    var sqlite_mem = try memory_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    var provider_state: u8 = 0;
    const provider_vtable = providers.Provider.VTable{
        .chatWithSystem = TestProvider.chatWithSystem,
        .chat = TestProvider.chat,
        .supportsNativeTools = TestProvider.supportsNativeTools,
        .getName = TestProvider.getName,
        .deinit = TestProvider.deinitFn,
    };
    const provider = providers.Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };
    var noop = observability.NoopObserver{};
    var session_mgr = session_mod.SessionManager.init(
        std.testing.allocator,
        &cfg,
        provider,
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        store,
        null,
    );
    defer session_mgr.deinit();

    const pending_event_id = (try session_mgr.saveCompletionEvent(
        "session:1",
        "zaki_app",
        null,
        "session:1",
        "[Subagent 'research'] completed\nanswer",
    )).?;
    defer std.testing.allocator.free(pending_event_id);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = workspace;
    state.workspace_dir = workspace;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"message\":\"hello\",\"session_key\":\"session:1\"}";
    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "POST /api/v1/chat/stream HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nX-Zaki-User-Id: 1\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    const response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        raw_request,
        "POST",
        "/api/v1/chat/stream",
        &state,
        null,
        &session_mgr,
    );

    try std.testing.expectEqualStrings("200 OK", response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "Main reply") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "[Subagent 'research'] completed") == null);

    const remaining = try session_mgr.loadCompletionEvents("session:1");
    defer memory_mod.freeCompletionEvents(std.testing.allocator, remaining);
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
}

test "handleApiChatEventsSseConnection replays pending completions and clears them" {
    const FakeStream = struct {
        buf: std.ArrayListUnmanaged(u8) = .empty,

        fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.buf.appendSlice(std.testing.allocator, bytes);
        }

        fn deinit(self: *@This()) void {
            self.buf.deinit(std.testing.allocator);
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{workspace});
    defer std.testing.allocator.free(config_path);

    var cfg = Config{
        .workspace_dir = workspace,
        .config_path = config_path,
        .default_model = "test/mock-model",
        .allocator = std.testing.allocator,
    };

    var sqlite_mem = try memory_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    var provider_state: u8 = 0;
    const provider_vtable = providers.Provider.VTable{
        .chatWithSystem = struct {
            fn call(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
                return allocator.dupe(u8, "");
            }
        }.call,
        .chat = struct {
            fn call(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
                return .{
                    .content = try allocator.dupe(u8, "unused"),
                    .tool_calls = &.{},
                    .usage = .{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
                    .model = try allocator.dupe(u8, "test-model"),
                };
            }
        }.call,
        .supportsNativeTools = struct {
            fn call(_: *anyopaque) bool {
                return false;
            }
        }.call,
        .getName = struct {
            fn call(_: *anyopaque) []const u8 {
                return "test-provider";
            }
        }.call,
        .deinit = struct {
            fn call(_: *anyopaque) void {}
        }.call,
    };
    const provider = providers.Provider{ .ptr = @ptrCast(&provider_state), .vtable = &provider_vtable };
    var noop = observability.NoopObserver{};
    var session_mgr = session_mod.SessionManager.init(
        std.testing.allocator,
        &cfg,
        provider,
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        store,
        null,
    );
    defer session_mgr.deinit();

    const event_id = (try session_mgr.saveCompletionEvent(
        "session:events",
        "zaki_app",
        null,
        "session:events",
        "[Subagent 'research'] completed\nanswer",
    )).?;
    defer std.testing.allocator.free(event_id);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = workspace;
    state.workspace_dir = workspace;
    state.shutdown_requested.store(true, .release);
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();
    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/chat/events?session_key=session:events HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nX-Zaki-User-Id: 1\r\n\r\n",
        .{},
    );

    var fake_stream = FakeStream{};
    defer fake_stream.deinit();

    const handled = handleApiChatEventsSseConnection(
        std.testing.allocator,
        req_allocator,
        &fake_stream,
        raw_request,
        "GET",
        "/api/v1/chat/events",
        &state,
        null,
        &session_mgr,
    );

    try std.testing.expect(handled);
    try std.testing.expect(std.mem.indexOf(u8, fake_stream.buf.items, "event: ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake_stream.buf.items, "event: subagent_completion") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake_stream.buf.items, "\"session_key\":\"session:events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake_stream.buf.items, "answer") != null);

    const remaining = try session_mgr.loadCompletionEvents("session:events");
    defer memory_mod.freeCompletionEvents(std.testing.allocator, remaining);
    try std.testing.expectEqual(@as(usize, 0), remaining.len);
}

test "handleApiChatEventsSseConnection delivers live completions to active subscriber" {
    const FakeStream = struct {
        buf: std.ArrayListUnmanaged(u8) = .empty,

        fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.buf.appendSlice(std.testing.allocator, bytes);
        }

        fn deinit(self: *@This()) void {
            self.buf.deinit(std.testing.allocator);
        }
    };

    const EventsThread = struct {
        fn run(ctx: *@This().Context) void {
            var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer req_arena.deinit();
            const req_allocator = req_arena.allocator();
            const raw_request = std.fmt.allocPrint(
                req_allocator,
                "GET /api/v1/chat/events?session_key={s} HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nX-Zaki-User-Id: 1\r\n\r\n",
                .{ctx.session_key},
            ) catch return;
            _ = handleApiChatEventsSseConnection(
                std.testing.allocator,
                req_allocator,
                ctx.stream,
                raw_request,
                "GET",
                "/api/v1/chat/events",
                ctx.state,
                null,
                ctx.session_mgr,
            );
        }

        const Context = struct {
            state: *GatewayState,
            session_mgr: *session_mod.SessionManager,
            stream: *FakeStream,
            session_key: []const u8,
        };
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{workspace});
    defer std.testing.allocator.free(config_path);

    var cfg = Config{
        .workspace_dir = workspace,
        .config_path = config_path,
        .default_model = "test/mock-model",
        .allocator = std.testing.allocator,
    };

    var sqlite_mem = try memory_mod.SqliteMemory.init(std.testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const store = sqlite_mem.sessionStore();

    var provider_state: u8 = 0;
    const provider_vtable = providers.Provider.VTable{
        .chatWithSystem = struct {
            fn call(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
                return allocator.dupe(u8, "");
            }
        }.call,
        .chat = struct {
            fn call(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
                return .{
                    .content = try allocator.dupe(u8, "unused"),
                    .tool_calls = &.{},
                    .usage = .{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
                    .model = try allocator.dupe(u8, "test-model"),
                };
            }
        }.call,
        .supportsNativeTools = struct {
            fn call(_: *anyopaque) bool {
                return false;
            }
        }.call,
        .getName = struct {
            fn call(_: *anyopaque) []const u8 {
                return "test-provider";
            }
        }.call,
        .deinit = struct {
            fn call(_: *anyopaque) void {}
        }.call,
    };
    const provider = providers.Provider{ .ptr = @ptrCast(&provider_state), .vtable = &provider_vtable };
    var noop = observability.NoopObserver{};
    var session_mgr = session_mod.SessionManager.init(
        std.testing.allocator,
        &cfg,
        provider,
        &.{},
        sqlite_mem.memory(),
        noop.observer(),
        store,
        null,
    );
    defer session_mgr.deinit();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = workspace;
    state.workspace_dir = workspace;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var fake_stream = FakeStream{};
    defer fake_stream.deinit();
    var ctx = EventsThread.Context{
        .state = &state,
        .session_mgr = &session_mgr,
        .stream = &fake_stream,
        .session_key = "session:live",
    };
    const thread = try std.Thread.spawn(.{}, EventsThread.run, .{&ctx});

    var subscriber_ready = false;
    for (0..50) |_| {
        state.app_event_subscribers.mutex.lock();
        subscriber_ready = state.app_event_subscribers.subscribers.contains("session:live");
        state.app_event_subscribers.mutex.unlock();
        if (subscriber_ready) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(subscriber_ready);

    const content = "[Subagent 'research'] completed\nlive answer";
    const event_id = (try session_mgr.saveCompletionEvent("session:live", "zaki_app", null, "session:live", content)).?;
    defer std.testing.allocator.free(event_id);

    const published = try state.app_event_subscribers.publish(event_id, "1", "session:live", content);
    try std.testing.expect(published);

    var delivered = false;
    for (0..50) |_| {
        const remaining = try session_mgr.loadCompletionEvents("session:live");
        defer memory_mod.freeCompletionEvents(std.testing.allocator, remaining);
        if (remaining.len == 0) {
            delivered = true;
            break;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(delivered);

    state.shutdown_requested.store(true, .release);
    state.closeAppEventSubscribers();
    thread.join();

    try std.testing.expect(std.mem.indexOf(u8, fake_stream.buf.items, "event: ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake_stream.buf.items, "event: subagent_completion") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake_stream.buf.items, "live answer") != null);
}

test "handleApiChatStreamSseConnection emits keepalive comments during slow turns" {
    const SlowProvider = struct {
        fn chatWithSystem(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, _: []const u8, _: []const u8, _: f64) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }

        fn chat(_: *anyopaque, allocator: std.mem.Allocator, _: providers.ChatRequest, _: []const u8, _: f64) anyerror!providers.ChatResponse {
            std.Thread.sleep(70 * std.time.ns_per_ms);
            return .{
                .content = try allocator.dupe(u8, "Hello after keepalive"),
                .tool_calls = &.{},
                .usage = .{ .prompt_tokens = 8, .completion_tokens = 4, .total_tokens = 12 },
                .model = try allocator.dupe(u8, "test-model"),
            };
        }

        fn supportsNativeTools(_: *anyopaque) bool {
            return false;
        }

        fn getName(_: *anyopaque) []const u8 {
            return "slow-provider";
        }

        fn deinitFn(_: *anyopaque) void {}
    };

    const FakeStream = struct {
        buf: std.ArrayListUnmanaged(u8) = .empty,

        fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.buf.appendSlice(std.testing.allocator, bytes);
        }

        fn deinit(self: *@This()) void {
            self.buf.deinit(std.testing.allocator);
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{workspace});
    defer std.testing.allocator.free(config_path);

    var cfg = Config{
        .workspace_dir = workspace,
        .config_path = config_path,
        .default_model = "test/mock-model",
        .allocator = std.testing.allocator,
    };

    var provider_state: u8 = 0;
    const provider_vtable = providers.Provider.VTable{
        .chatWithSystem = SlowProvider.chatWithSystem,
        .chat = SlowProvider.chat,
        .supportsNativeTools = SlowProvider.supportsNativeTools,
        .getName = SlowProvider.getName,
        .deinit = SlowProvider.deinitFn,
    };
    const provider = providers.Provider{
        .ptr = @ptrCast(&provider_state),
        .vtable = &provider_vtable,
    };
    var noop = observability.NoopObserver{};
    var session_mgr = session_mod.SessionManager.init(
        std.testing.allocator,
        &cfg,
        provider,
        &.{},
        null,
        noop.observer(),
        null,
        null,
    );
    defer session_mgr.deinit();

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = workspace;
    state.workspace_dir = workspace;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const body = "{\"message\":\"hello\",\"session_key\":\"session:slow\"}";
    const raw_request = try std.fmt.allocPrint(
        req_allocator,
        "POST /api/v1/chat/stream HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\nX-Zaki-User-Id: 1\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );

    var fake_stream = FakeStream{};
    defer fake_stream.deinit();

    const handled = handleApiChatStreamSseConnection(
        std.testing.allocator,
        req_allocator,
        &fake_stream,
        raw_request,
        "POST",
        "/api/v1/chat/stream",
        &state,
        null,
        &session_mgr,
    );

    try std.testing.expect(handled);
    try std.testing.expect(std.mem.indexOf(u8, fake_stream.buf.items, "Still working on the reply") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake_stream.buf.items, "Hello after keepalive") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake_stream.buf.items, "event: done") != null);
}

test "tenant_lock_config_clamps_invalid_values" {
    const cfg = config_types.TenantConfig{
        .ownership_lock_lease_secs = 5,
        .ownership_lock_wait_ms = 99999,
        .ownership_lock_retry_min_ms = 250,
        .ownership_lock_retry_max_ms = 5,
    };
    const normalized = normalizeTenantOwnershipLockConfig(cfg);
    try std.testing.expectEqual(@as(u64, TENANT_OWNERSHIP_LOCK_LEASE_SECS_MIN), normalized.lease_secs);
    try std.testing.expectEqual(@as(u32, TENANT_OWNERSHIP_LOCK_WAIT_MS_MAX), normalized.wait_ms);
    try std.testing.expectEqual(@as(u32, TENANT_OWNERSHIP_LOCK_RETRY_MS_MIN), normalized.retry_min_ms);
    try std.testing.expectEqual(@as(u32, TENANT_OWNERSHIP_LOCK_RETRY_MS_MAX), normalized.retry_max_ms);
}

test "normalizedLocalAgentMemoryConfig remaps tenant postgres memory to markdown" {
    const cfg = Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .memory = .{
            .backend = "postgres",
        },
        .tenant = .{
            .enabled = true,
        },
        .state = .{
            .backend = "postgres",
        },
        .allocator = std.testing.allocator,
    };

    const normalized = normalizedLocalAgentMemoryConfig(&cfg);
    try std.testing.expectEqualStrings("markdown", normalized.backend);
    try std.testing.expectEqualStrings("postgres", cfg.memory.backend);
}

test "normalizedLocalAgentMemoryConfig preserves non-tenant postgres backend" {
    const cfg = Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .memory = .{
            .backend = "postgres",
        },
        .tenant = .{
            .enabled = false,
        },
        .state = .{
            .backend = "postgres",
        },
        .allocator = std.testing.allocator,
    };

    const normalized = normalizedLocalAgentMemoryConfig(&cfg);
    try std.testing.expectEqualStrings("postgres", normalized.backend);
}

test "handleApiRoute settings endpoint derives from legacy config and config GET normalizes overlay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_data_root = tenant_root;
    const internal_tokens = [_][]const u8{"test-internal-token"};
    state.internal_service_tokens = &internal_tokens;

    var req_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer req_arena.deinit();
    const req_allocator = req_arena.allocator();

    const user_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/1", .{tenant_root});
    defer std.testing.allocator.free(user_dir);
    try std.fs.makeDirAbsolute(user_dir);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{user_dir});
    defer std.testing.allocator.free(config_path);
    const raw_cfg = "{\"agent\":{\"queue_mode\":\"latest\",\"queue_cap\":8,\"queue_drop\":\"newest\",\"max_history_messages\":40},\"models\":{\"providers\":{\"openai\":{\"api_key\":\"test-key\"}}}}\n";
    try writeFile(config_path, raw_cfg);

    const settings_get_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/1/settings HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );
    const settings_get_response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        settings_get_request,
        "GET",
        "/api/v1/users/1/settings",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", settings_get_response.status);
    try std.testing.expect(std.mem.indexOf(u8, settings_get_response.body, "\"assistant_mode\":\"fast\"") != null);

    const config_get_request = try std.fmt.allocPrint(
        req_allocator,
        "GET /api/v1/users/1/config HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: test-internal-token\r\n\r\n",
        .{},
    );
    const config_get_response = handleApiRoute(
        std.testing.allocator,
        req_allocator,
        config_get_request,
        "GET",
        "/api/v1/users/1/config",
        &state,
        null,
        null,
    );
    try std.testing.expectEqualStrings("200 OK", config_get_response.status);
    try std.testing.expect(std.mem.indexOf(u8, config_get_response.body, "\"agent\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, config_get_response.body, "\"models\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, config_get_response.body, "\"product_settings\"") != null);
}

test "parseTenantRuntimeInvalidationRequest rejects empty payload without user id" {
    try std.testing.expectError(
        error.InvalidPayload,
        parseTenantRuntimeInvalidationRequest(std.testing.allocator, null, "{}"),
    );
}

test "parseTenantRuntimeInvalidationRequest accepts mixed user id body" {
    const request = try parseTenantRuntimeInvalidationRequest(
        std.testing.allocator,
        null,
        "{\"user_ids\":[1,\"2\"]}",
    );
    defer request.deinit(std.testing.allocator);

    try std.testing.expect(!request.all);
    try std.testing.expectEqual(@as(usize, 2), request.user_ids.len);
    try std.testing.expectEqualStrings("1", request.user_ids[0]);
    try std.testing.expectEqualStrings("2", request.user_ids[1]);
}

// ── Bearer Token Validation tests ───────────────────────────────

test "validateBearerToken allows when no paired tokens" {
    try std.testing.expect(validateBearerToken("anything", &.{}));
}

test "validateBearerToken allows valid token" {
    const tokens = &[_][]const u8{ "token-a", "token-b", "token-c" };
    try std.testing.expect(validateBearerToken("token-b", tokens));
}

test "validateBearerToken rejects invalid token" {
    const tokens = &[_][]const u8{ "token-a", "token-b" };
    try std.testing.expect(!validateBearerToken("token-c", tokens));
}

test "validateBearerToken rejects empty token when tokens configured" {
    const tokens = &[_][]const u8{"secret"};
    try std.testing.expect(!validateBearerToken("", tokens));
}

test "validateBearerToken exact match required" {
    const tokens = &[_][]const u8{"abc123"};
    try std.testing.expect(validateBearerToken("abc123", tokens));
    try std.testing.expect(!validateBearerToken("abc1234", tokens));
    try std.testing.expect(!validateBearerToken("abc12", tokens));
}

test "validateInternalTokensForMode allows empty tokens in localhost mode" {
    const result = validateInternalTokensForMode(&.{}, false);
    try std.testing.expect(result.ok);
    try std.testing.expect(!result.configured);
    try std.testing.expect(result.reason == null);
}

test "validateInternalTokensForMode rejects empty tokens in production-like mode" {
    const missing = validateInternalTokensForMode(&.{}, true);
    try std.testing.expect(!missing.ok);
    try std.testing.expect(!missing.configured);
    try std.testing.expectEqualStrings("missing_internal_service_tokens", missing.reason.?);

    const empty_only = validateInternalTokensForMode(&[_][]const u8{"   "}, true);
    try std.testing.expect(!empty_only.ok);
    try std.testing.expect(!empty_only.configured);
    try std.testing.expectEqualStrings("invalid_internal_service_token_empty", empty_only.reason.?);
}

test "validateInternalTokensForMode rejects weak and denylisted tokens in production-like mode" {
    const too_short = validateInternalTokensForMode(&[_][]const u8{"short-token"}, true);
    try std.testing.expect(!too_short.ok);
    try std.testing.expect(too_short.configured);
    try std.testing.expectEqualStrings("invalid_internal_service_token_too_short", too_short.reason.?);

    const denylisted = validateInternalTokensForMode(&[_][]const u8{"DEV-INTERNAL-TOKEN"}, true);
    try std.testing.expect(!denylisted.ok);
    try std.testing.expect(denylisted.configured);
    try std.testing.expectEqualStrings("invalid_internal_service_token_denylisted", denylisted.reason.?);

    const strong = validateInternalTokensForMode(&[_][]const u8{"svc-prod-token-1234"}, true);
    try std.testing.expect(strong.ok);
    try std.testing.expect(strong.configured);
    try std.testing.expect(strong.reason == null);
}

test "validateInternalServiceTokenWithPolicy enforces strict mode when token set is empty" {
    const no_auth_raw = "GET /internal/diagnostics HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(validateInternalServiceTokenWithPolicy(no_auth_raw, &.{}, false));
    try std.testing.expect(!validateInternalServiceTokenWithPolicy(no_auth_raw, &.{}, true));

    const with_auth_raw = "GET /internal/diagnostics HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\n\r\n";
    const tokens = &[_][]const u8{"svc-prod-token-1234"};
    try std.testing.expect(validateInternalServiceTokenWithPolicy(with_auth_raw, tokens, true));
}

test "isProductionLikeGateway treats non-loopback host as production-like" {
    var cfg = Config{
        .workspace_dir = ".",
        .config_path = "config.json",
        .allocator = std.testing.allocator,
    };

    try std.testing.expect(!isProductionLikeGateway(&cfg, "127.0.0.1"));
    try std.testing.expect(!isProductionLikeGateway(&cfg, "localhost"));
    try std.testing.expect(isProductionLikeGateway(&cfg, "0.0.0.0"));

    cfg.tenant.enabled = true;
    try std.testing.expect(!isProductionLikeGateway(&cfg, "127.0.0.1"));
    try std.testing.expect(isProductionLikeGateway(&cfg, "8.8.8.8"));

    cfg.tenant.enabled = false;
    cfg.gateway.allow_public_bind = true;
    try std.testing.expect(isProductionLikeGateway(&cfg, "127.0.0.1"));
}

test "isWebhookAuthorized fails closed when pairing guard missing" {
    try std.testing.expect(!isWebhookAuthorized(null, "token"));
}

test "isWebhookAuthorized allows when pairing disabled" {
    var guard = try PairingGuard.init(std.testing.allocator, false, &.{});
    defer guard.deinit();
    try std.testing.expect(isWebhookAuthorized(&guard, null));
}

test "isWebhookAuthorized requires valid bearer token when pairing enabled" {
    const tokens = [_][]const u8{"zc_valid"};
    var guard = try PairingGuard.init(std.testing.allocator, true, &tokens);
    defer guard.deinit();

    try std.testing.expect(isWebhookAuthorized(&guard, "zc_valid"));
    try std.testing.expect(!isWebhookAuthorized(&guard, null));
    try std.testing.expect(!isWebhookAuthorized(&guard, "zc_invalid"));
}

test "formatPairSuccessResponse includes paired token" {
    var buf: [256]u8 = undefined;
    const response = formatPairSuccessResponse(&buf, "zc_token_123") orelse unreachable;
    try std.testing.expectEqualStrings(
        "{\"status\":\"paired\",\"token\":\"zc_token_123\"}",
        response,
    );
}

test "formatPairSuccessResponse fails when buffer is too small" {
    var buf: [8]u8 = undefined;
    try std.testing.expect(formatPairSuccessResponse(&buf, "zc_token_123") == null);
}

// ── extractHeader tests ──────────────────────────────────────────

test "extractHeader finds Authorization header" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer secret123\r\nContent-Type: application/json\r\n\r\n";
    const val = extractHeader(raw, "Authorization");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("Bearer secret123", val.?);
}

test "extractHeader case insensitive" {
    const raw = "GET /health HTTP/1.1\r\ncontent-type: text/plain\r\n\r\n";
    const val = extractHeader(raw, "Content-Type");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("text/plain", val.?);
}

test "extractHeader returns null for missing header" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const val = extractHeader(raw, "Authorization");
    try std.testing.expect(val == null);
}

test "extractHeader returns null for empty headers" {
    const raw = "GET / HTTP/1.1\r\n\r\n";
    try std.testing.expect(extractHeader(raw, "Host") == null);
}

// ── extractBearerToken tests ─────────────────────────────────────

test "extractBearerToken extracts token" {
    try std.testing.expectEqualStrings("mytoken", extractBearerToken("Bearer mytoken").?);
}

test "extractBearerToken returns null for non-Bearer" {
    try std.testing.expect(extractBearerToken("Basic abc123") == null);
}

test "extractBearerToken returns null for empty string" {
    try std.testing.expect(extractBearerToken("") == null);
}

test "extractBearerToken returns null for just Bearer" {
    // "Bearer " is 7 chars, "Bearer" is 6 — no space
    try std.testing.expect(extractBearerToken("Bearer") == null);
}

// ── JSON helper tests ────────────────────────────────────────────

test "jsonStringField extracts value" {
    const json = "{\"message\": \"hello world\"}";
    const val = jsonStringField(json, "message");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("hello world", val.?);
}

test "jsonStringField returns null for missing key" {
    const json = "{\"other\": \"value\"}";
    try std.testing.expect(jsonStringField(json, "message") == null);
}

test "jsonStringField handles nested JSON" {
    const json = "{\"message\": {\"text\": \"hi\"}, \"text\": \"direct\"}";
    const val = jsonStringField(json, "text");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("hi", val.?);
}

test "ensureTelegramSendMessageAccepted accepts ok=true payload" {
    try ensureTelegramSendMessageAccepted(std.testing.allocator, "{\"ok\":true,\"result\":{}}");
}

test "ensureTelegramSendMessageAccepted rejects ok=false payload" {
    const result = ensureTelegramSendMessageAccepted(
        std.testing.allocator,
        "{\"ok\":false,\"description\":\"Bad Request: chat not found\"}",
    );
    try std.testing.expectError(error.TelegramApiRejected, result);
}

test "ensureTelegramSendMessageAccepted rejects non-json payload" {
    const result = ensureTelegramSendMessageAccepted(std.testing.allocator, "<html>error</html>");
    try std.testing.expectError(error.TelegramApiUnexpectedResponse, result);
}

test "ensureTelegramSendMessageAccepted rejects payload without ok field" {
    const result = ensureTelegramSendMessageAccepted(std.testing.allocator, "{\"result\":{}}");
    try std.testing.expectError(error.TelegramApiUnexpectedResponse, result);
}

test "jsonIntField extracts positive integer" {
    const json = "{\"chat_id\": 12345}";
    const val = jsonIntField(json, "chat_id");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 12345), val.?);
}

test "jsonIntField extracts negative integer" {
    const json = "{\"offset\": -100}";
    const val = jsonIntField(json, "offset");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, -100), val.?);
}

test "jsonIntField returns null for missing key" {
    const json = "{\"other\": 42}";
    try std.testing.expect(jsonIntField(json, "chat_id") == null);
}

test "jsonIntField returns null for string value" {
    const json = "{\"chat_id\": \"not a number\"}";
    try std.testing.expect(jsonIntField(json, "chat_id") == null);
}

test "selectWhatsAppConfig picks account by phone_number_id" {
    const wa_accounts = [_]config_types.WhatsAppConfig{
        .{
            .account_id = "main",
            .access_token = "tok-a",
            .phone_number_id = "111",
            .verify_token = "verify-a",
        },
        .{
            .account_id = "backup",
            .access_token = "tok-b",
            .phone_number_id = "222",
            .verify_token = "verify-b",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .whatsapp = &wa_accounts,
        },
    };
    const body = "{\"entry\":[{\"changes\":[{\"value\":{\"metadata\":{\"phone_number_id\":\"222\"}}}]}]}";
    const selected = selectWhatsAppConfig(&cfg, body, null);
    if (!build_options.enable_channel_whatsapp) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "selectTelegramConfig picks account by query account_id" {
    const tg_accounts = [_]config_types.TelegramConfig{
        .{
            .account_id = "main",
            .bot_token = "token-main",
            .allow_from = &.{"main-user"},
        },
        .{
            .account_id = "backup",
            .bot_token = "token-backup",
            .allow_from = &.{"backup-user"},
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .telegram = &tg_accounts,
        },
    };

    const selected = selectTelegramConfig(&cfg, "/telegram?account_id=backup");
    if (!build_options.enable_channel_telegram) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "selectTelegramConfig falls back to preferred primary account" {
    const tg_accounts = [_]config_types.TelegramConfig{
        .{
            .account_id = "z-last",
            .bot_token = "token-z",
        },
        .{
            .account_id = "default",
            .bot_token = "token-default",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .telegram = &tg_accounts,
        },
    };

    const selected = selectTelegramConfig(&cfg, "/telegram");
    if (!build_options.enable_channel_telegram) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("default", selected.?.account_id);
}

test "selectWhatsAppConfig picks account by verify_token" {
    const wa_accounts = [_]config_types.WhatsAppConfig{
        .{
            .account_id = "main",
            .access_token = "tok-a",
            .phone_number_id = "111",
            .verify_token = "verify-a",
        },
        .{
            .account_id = "backup",
            .access_token = "tok-b",
            .phone_number_id = "222",
            .verify_token = "verify-b",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .whatsapp = &wa_accounts,
        },
    };
    const selected = selectWhatsAppConfig(&cfg, null, "verify-b");
    if (!build_options.enable_channel_whatsapp) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "selectLineConfigBySignature matches account and rejects bad signature" {
    const body = "{\"events\":[]}";
    const line_accounts = [_]config_types.LineConfig{
        .{
            .account_id = "main",
            .access_token = "line-a",
            .channel_secret = "secret-a",
        },
        .{
            .account_id = "backup",
            .access_token = "line-b",
            .channel_secret = "secret-b",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .line = &line_accounts,
        },
    };

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, "secret-b");
    var sig_buf: [44]u8 = undefined;
    const signature = std.base64.standard.Encoder.encode(&sig_buf, &mac);

    const selected = selectLineConfigBySignature(&cfg, body, signature);
    if (!build_options.enable_channel_line) {
        try std.testing.expect(selected == null);
        try std.testing.expect(selectLineConfigBySignature(&cfg, body, "invalid-signature") == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
    try std.testing.expect(selectLineConfigBySignature(&cfg, body, "invalid-signature") == null);
}

test "selectLarkConfig picks account by verification token" {
    const lark_accounts = [_]config_types.LarkConfig{
        .{
            .account_id = "main",
            .app_id = "app-a",
            .app_secret = "secret-a",
            .verification_token = "token-a",
        },
        .{
            .account_id = "backup",
            .app_id = "app-b",
            .app_secret = "secret-b",
            .verification_token = "token-b",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .lark = &lark_accounts,
        },
    };
    const body = "{\"header\":{\"token\":\"token-b\"}}";
    const selected = selectLarkConfig(&cfg, body);
    if (!build_options.enable_channel_lark) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("backup", selected.?.account_id);
}

test "whatsappSessionKey builds direct key by sender" {
    const body = "{\"from\":\"15550001111\",\"text\":{\"body\":\"hi\"}}";
    var key_buf: [256]u8 = undefined;
    const key = whatsappSessionKey(&key_buf, body);
    try std.testing.expectEqualStrings("whatsapp:15550001111", key);
}

test "whatsappSessionKey builds group key when group id exists" {
    const body = "{\"from\":\"15550001111\",\"context\":{\"group_jid\":\"1203630@g.us\"},\"text\":{\"body\":\"hi\"}}";
    var key_buf: [256]u8 = undefined;
    const key = whatsappSessionKey(&key_buf, body);
    try std.testing.expectEqualStrings("whatsapp:group:1203630@g.us:15550001111", key);
}

test "telegramSenderAllowed allows all when allow_from is empty" {
    const allocator = std.testing.allocator;
    const body =
        \\{"message":{"from":{"id":12345,"username":"alice"}}}
    ;
    try std.testing.expect(telegramSenderAllowed(allocator, &.{}, body));
}

test "telegramChatId extracts nested message.chat.id" {
    const allocator = std.testing.allocator;
    const body =
        \\{"update_id":1,"message":{"chat":{"id":-100777},"from":{"id":12345},"text":"hi"}}
    ;
    try std.testing.expectEqual(@as(i64, -100777), telegramChatId(allocator, body).?);
}

test "telegramChatId falls back to flat chat_id for backward compatibility" {
    const allocator = std.testing.allocator;
    const body = "{\"chat_id\":12345,\"text\":\"hi\"}";
    try std.testing.expectEqual(@as(i64, 12345), telegramChatId(allocator, body).?);
}

test "telegramWebhookExtractInboundText returns nested text" {
    const allocator = std.testing.allocator;
    const body =
        \\{"update_id":1,"message":{"chat":{"id":123},"from":{"id":1},"text":"hello from tg"}}
    ;
    const text = telegramWebhookExtractInboundText(allocator, body, "123:bot", null, null) orelse return error.TestUnexpectedResult;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello from tg", text);
}

test "telegramWebhookExtractInboundText falls back to caption" {
    const allocator = std.testing.allocator;
    const body =
        \\{"update_id":1,"message":{"chat":{"id":123},"from":{"id":1},"caption":"voice caption only"}}
    ;
    const text = telegramWebhookExtractInboundText(allocator, body, "123:bot", null, null) orelse return error.TestUnexpectedResult;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("voice caption only", text);
}

test "telegramWebhookExtractInboundText voice without transcriber returns fallback marker" {
    const allocator = std.testing.allocator;
    const body =
        \\{"update_id":1,"message":{"chat":{"id":123},"from":{"id":1},"voice":{"file_id":"abc123"}}}
    ;
    const text = telegramWebhookExtractInboundText(allocator, body, "123:bot", null, null) orelse return error.TestUnexpectedResult;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("[Voice]: (transcription unavailable)", text);
}

test "telegramWebhookExtractInboundText photo without caption returns fallback marker" {
    const allocator = std.testing.allocator;
    const body =
        \\{"update_id":1,"message":{"chat":{"id":123},"from":{"id":1},"photo":[{"file_id":"a"},{"file_id":"b"}]}}
    ;
    const text = telegramWebhookExtractInboundText(allocator, body, "123:bot", null, null) orelse return error.TestUnexpectedResult;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("[Image]: (caption unavailable)", text);
}

test "telegramWebhookExtractInboundText photo with caption returns caption" {
    const allocator = std.testing.allocator;
    const body =
        \\{"update_id":1,"message":{"chat":{"id":123},"from":{"id":1},"photo":[{"file_id":"a"}],"caption":"look at this"}}
    ;
    const text = telegramWebhookExtractInboundText(allocator, body, "123:bot", null, null) orelse return error.TestUnexpectedResult;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("look at this", text);
}

test "telegramWebhookExtractInboundText photo without caption does not return null" {
    const allocator = std.testing.allocator;
    const body =
        \\{"update_id":1,"message":{"chat":{"id":123},"from":{"id":1},"photo":[{"file_id":"a"},{"file_id":"b"}]}}
    ;
    const text = telegramWebhookExtractInboundText(allocator, body, "123:bot", null, null) orelse return error.TestUnexpectedResult;
    defer allocator.free(text);
    try std.testing.expect(text.len > 0);
}

test "telegramSenderAllowed matches numeric sender id from nested from object" {
    const allocator = std.testing.allocator;
    const allow_from = [_][]const u8{"12345"};
    const body =
        \\{"message":{"from":{"id":12345},"chat":{"id":-100777}}}
    ;
    try std.testing.expect(telegramSenderAllowed(allocator, &allow_from, body));
}

test "telegramSenderAllowed does not confuse chat id with sender id" {
    const allocator = std.testing.allocator;
    const allow_from = [_][]const u8{"-100777"};
    const body =
        \\{"message":{"from":{"id":12345},"chat":{"id":-100777}}}
    ;
    try std.testing.expect(!telegramSenderAllowed(allocator, &allow_from, body));
}

test "telegramSenderAllowed rejects sender outside allowlist" {
    const allocator = std.testing.allocator;
    const allow_from = [_][]const u8{"alice"};
    const body =
        \\{"message":{"from":{"id":12345}}}
    ;
    try std.testing.expect(!telegramSenderAllowed(allocator, &allow_from, body));
}

test "parseTelegramUserState accepts connected telegram state without allowlist" {
    const allocator = std.testing.allocator;
    const body =
        \\{"connected":true,"account_id":"default","webhook_secret_token":"sec-12345","connected_at":1234567890}
    ;

    var state = try parseTelegramUserState(allocator, body);
    defer state.deinit(allocator);

    try std.testing.expect(state.connected);
    try std.testing.expectEqualStrings("default", state.account_id.?);
    try std.testing.expectEqualStrings("sec-12345", state.webhook_secret_token.?);
    try std.testing.expectEqual(@as(usize, 0), state.allow_from.len);
}

test "telegramSenderIdentity falls back to numeric id when username is missing" {
    const allocator = std.testing.allocator;
    var sender_buf: [32]u8 = undefined;
    const body =
        \\{"message":{"from":{"id":12345},"chat":{"id":-100777}}}
    ;
    try std.testing.expectEqualStrings("12345", telegramSenderIdentity(allocator, body, &sender_buf));
}

test "whatsappSenderAllowed direct respects allow_from" {
    const allow_from = [_][]const u8{"+1111111111"};
    try std.testing.expect(whatsappSenderAllowed("+1111111111", false, null, &allow_from, &.{}, &.{}, "allowlist"));
    try std.testing.expect(!whatsappSenderAllowed("+2222222222", false, null, &allow_from, &.{}, &.{}, "allowlist"));
}

test "whatsappSenderAllowed direct denies all when allow_from is empty" {
    try std.testing.expect(!whatsappSenderAllowed("+1111111111", false, null, &.{}, &.{}, &.{}, "allowlist"));
}

test "whatsappSenderAllowed group open bypasses allow_from" {
    const allow_from = [_][]const u8{"+1111111111"};
    try std.testing.expect(whatsappSenderAllowed("+2222222222", true, "1203630@g.us", &allow_from, &.{}, &.{}, "open"));
}

test "whatsappSenderAllowed open policy still respects explicit groups allowlist" {
    const allow_from = [_][]const u8{"+1111111111"};
    const groups = [_][]const u8{"1203630@g.us"};
    try std.testing.expect(whatsappSenderAllowed("+2222222222", true, "1203630@g.us", &allow_from, &.{}, &groups, "open"));
    try std.testing.expect(!whatsappSenderAllowed("+2222222222", true, "1203631@g.us", &allow_from, &.{}, &groups, "open"));
}

test "whatsappSenderAllowed group allowlist uses groups and sender allowlists" {
    const allow_from = [_][]const u8{"+1111111111"};
    const group_allow = [_][]const u8{"+3333333333"};
    const groups = [_][]const u8{"1203630@g.us"};

    try std.testing.expect(whatsappSenderAllowed("+3333333333", true, "1203630@g.us", &allow_from, &group_allow, &groups, "allowlist"));
    try std.testing.expect(!whatsappSenderAllowed("+1111111111", true, "1203630@g.us", &allow_from, &group_allow, &groups, "allowlist"));

    try std.testing.expect(whatsappSenderAllowed("+1111111111", true, "1203630@g.us", &allow_from, &.{}, &groups, "allowlist"));
    try std.testing.expect(!whatsappSenderAllowed("+1111111111", true, "1203631@g.us", &allow_from, &.{}, &groups, "allowlist"));
    try std.testing.expect(!whatsappSenderAllowed("+9999999999", true, "1203630@g.us", &.{}, &.{}, &groups, "allowlist"));
    try std.testing.expect(!whatsappSenderAllowed("+1111111111", true, "1203630@g.us", &allow_from, &.{}, &.{}, "allowlist"));
}

test "whatsappSenderAllowed matches with and without plus prefix" {
    const allow_with_plus = [_][]const u8{"+15550001111"};
    const allow_without_plus = [_][]const u8{"15550001111"};

    try std.testing.expect(whatsappSenderAllowed("15550001111", false, null, &allow_with_plus, &.{}, &.{}, "allowlist"));
    try std.testing.expect(whatsappSenderAllowed("+15550001111", false, null, &allow_without_plus, &.{}, &.{}, "allowlist"));
}

test "whatsappSessionKeyRouted falls back without config" {
    const allocator = std.testing.allocator;
    const body = "{\"from\":\"15550001111\",\"text\":{\"body\":\"hi\"}}";
    var key_buf: [256]u8 = undefined;
    const key = whatsappSessionKeyRouted(allocator, &key_buf, body, null, "default");
    try std.testing.expectEqualStrings("whatsapp:15550001111", key);
}

test "whatsappSessionKeyRouted uses route engine when config exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = "{\"from\":\"15550001111\",\"group_jid\":\"1203630@g.us\",\"text\":{\"body\":\"hi\"}}";
    var key_buf: [256]u8 = undefined;

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "wa-agent",
                .match = .{
                    .channel = "whatsapp",
                    .account_id = "wa-prod",
                    .peer = .{ .kind = .group, .id = "1203630@g.us" },
                },
            },
        },
    };

    const key = whatsappSessionKeyRouted(allocator, &key_buf, body, &cfg, "wa-prod");
    try std.testing.expectEqualStrings("agent:wa-agent:whatsapp:group:1203630@g.us", key);
}

test "whatsappSessionKeyRouted uses nested context.group_jid for group routing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body = "{\"from\":\"15550001111\",\"context\":{\"group_jid\":\"1203631@g.us\"},\"text\":{\"body\":\"hi\"}}";
    var key_buf: [256]u8 = undefined;

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "wa-context-agent",
                .match = .{
                    .channel = "whatsapp",
                    .account_id = "wa-main",
                    .peer = .{ .kind = .group, .id = "1203631@g.us" },
                },
            },
        },
    };

    const key = whatsappSessionKeyRouted(allocator, &key_buf, body, &cfg, "wa-main");
    try std.testing.expectEqualStrings("agent:wa-context-agent:whatsapp:group:1203631@g.us", key);
}

test "telegramSessionKeyRouted uses group peer for group chats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body =
        \\{"message":{"chat":{"id":-10012345,"type":"supergroup"}}}
    ;
    var key_buf: [128]u8 = undefined;

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "tg-group-agent",
                .match = .{
                    .channel = "telegram",
                    .account_id = "tg-main",
                    .peer = .{ .kind = .group, .id = "-10012345" },
                },
            },
        },
    };

    const key = telegramSessionKeyRouted(allocator, &key_buf, -10012345, body, &cfg, "tg-main");
    try std.testing.expectEqualStrings("agent:tg-group-agent:telegram:group:-10012345", key);
}

test "telegramSessionKeyRouted uses direct peer for private chats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body =
        \\{"message":{"chat":{"id":4242,"type":"private"}}}
    ;
    var key_buf: [128]u8 = undefined;

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "tg-dm-agent",
                .match = .{
                    .channel = "telegram",
                    .account_id = "tg-main",
                    .peer = .{ .kind = .direct, .id = "4242" },
                },
            },
        },
    };

    const key = telegramSessionKeyRouted(allocator, &key_buf, 4242, body, &cfg, "tg-main");
    try std.testing.expectEqualStrings("agent:tg-dm-agent:main", key);
}

test "telegramSessionKeyRouted applies session dm_scope for direct chats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body =
        \\{"message":{"chat":{"id":4242,"type":"private"}}}
    ;
    var key_buf: [128]u8 = undefined;

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "tg-dm-agent",
                .match = .{
                    .channel = "telegram",
                    .account_id = "tg-main",
                    .peer = .{ .kind = .direct, .id = "4242" },
                },
            },
        },
        .session = .{
            .dm_scope = .per_peer,
        },
    };

    const key = telegramSessionKeyRouted(allocator, &key_buf, 4242, body, &cfg, "tg-main");
    try std.testing.expectEqualStrings("agent:tg-dm-agent:direct:4242", key);
}

test "tenantTelegramUsesSharedMain defaults false without config" {
    try std.testing.expect(!tenantTelegramUsesSharedMain(null));
}

test "tenantTelegramUsesSharedMain is locked off for tenant lane determinism" {
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };

    cfg.session.cross_channel_shared_main = false;
    try std.testing.expect(!tenantTelegramUsesSharedMain(&cfg));

    cfg.session.cross_channel_shared_main = true;
    try std.testing.expect(!tenantTelegramUsesSharedMain(&cfg));
}

test "resolveTenantTelegramLane routes direct chats to canonical main lane" {
    var fallback_buf: [128]u8 = undefined;
    var topic_buf: [32]u8 = undefined;
    var lane_buf: [64]u8 = undefined;

    const lane = resolveTenantTelegramLane(
        std.testing.allocator,
        null,
        false,
        "1",
        "default",
        123456789,
        "{\"message\":{\"chat\":{\"id\":123456789,\"type\":\"private\"}}}",
        &fallback_buf,
        &topic_buf,
        &lane_buf,
    );

    try std.testing.expectEqual(inbound_canonicalizer.CanonicalSessionLane.main, lane.lane);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", lane.fallback_session_key);
    try std.testing.expect(lane.canonical_thread_key == null);
}

test "resolveTenantTelegramLane appends topic id for forum messages" {
    var fallback_buf: [128]u8 = undefined;
    var topic_buf: [32]u8 = undefined;
    var lane_buf: [64]u8 = undefined;

    const lane = resolveTenantTelegramLane(
        std.testing.allocator,
        null,
        false,
        "1",
        "default",
        -10012345,
        "{\"message\":{\"chat\":{\"id\":-10012345,\"type\":\"supergroup\"},\"message_thread_id\":77}}",
        &fallback_buf,
        &topic_buf,
        &lane_buf,
    );

    try std.testing.expectEqual(inbound_canonicalizer.CanonicalSessionLane.thread, lane.lane);
    try std.testing.expectEqualStrings("-10012345:77", lane.canonical_thread_key.?);
}

test "lineSessionKeyRouted uses group id for group events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var key_buf: [128]u8 = undefined;
    const evt = channels.line.LineEvent{
        .event_type = "message",
        .user_id = "U111",
        .group_id = "G222",
        .source_type = "group",
    };

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "line-group-agent",
                .match = .{
                    .channel = "line",
                    .account_id = "line-main",
                    .peer = .{ .kind = .group, .id = "group:G222" },
                },
            },
        },
    };

    const key = lineSessionKeyRouted(allocator, &key_buf, evt, &cfg, "line-main");
    try std.testing.expectEqualStrings("agent:line-group-agent:line:group:group:G222", key);
}

test "lineSessionKeyRouted falls back to user session key without config" {
    const allocator = std.testing.allocator;
    var key_buf: [128]u8 = undefined;
    const evt = channels.line.LineEvent{
        .event_type = "message",
        .user_id = "U777",
    };

    const key = lineSessionKeyRouted(allocator, &key_buf, evt, null, "default");
    try std.testing.expectEqualStrings("line:U777", key);
}

test "lineSessionKeyRouted uses room-prefixed peer id for room events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var key_buf: [128]u8 = undefined;
    const evt = channels.line.LineEvent{
        .event_type = "message",
        .user_id = "U111",
        .room_id = "R333",
        .source_type = "room",
    };

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "line-room-agent",
                .match = .{
                    .channel = "line",
                    .account_id = "line-main",
                    .peer = .{ .kind = .group, .id = "room:R333" },
                },
            },
        },
    };

    const key = lineSessionKeyRouted(allocator, &key_buf, evt, &cfg, "line-main");
    try std.testing.expectEqualStrings("agent:line-room-agent:line:group:room:R333", key);
}

test "lineReplyTarget resolves conversation target for group events" {
    const evt = channels.line.LineEvent{
        .event_type = "message",
        .user_id = "U111",
        .group_id = "G222",
        .source_type = "group",
    };
    try std.testing.expectEqualStrings("G222", lineReplyTarget(evt));
}

test "lineReplyTarget resolves conversation target for room events" {
    const evt = channels.line.LineEvent{
        .event_type = "message",
        .user_id = "U111",
        .room_id = "R333",
        .source_type = "room",
    };
    try std.testing.expectEqualStrings("R333", lineReplyTarget(evt));
}

test "lineReplyTarget falls back to user for direct events" {
    const evt = channels.line.LineEvent{
        .event_type = "message",
        .user_id = "U111",
        .source_type = "user",
    };
    try std.testing.expectEqualStrings("U111", lineReplyTarget(evt));
}

test "larkSessionKeyRouted uses route engine when config exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var key_buf: [128]u8 = undefined;
    const msg = channels.lark.ParsedLarkMessage{
        .sender = "ou_abc123",
        .content = "hello",
        .timestamp = 123,
        .is_group = true,
    };

    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .agent_bindings = &[_]agent_routing.AgentBinding{
            .{
                .agent_id = "lark-group-agent",
                .match = .{
                    .channel = "lark",
                    .account_id = "lark-main",
                    .peer = .{ .kind = .group, .id = "ou_abc123" },
                },
            },
        },
    };

    const key = larkSessionKeyRouted(allocator, &key_buf, msg, &cfg, "lark-main");
    try std.testing.expectEqualStrings("agent:lark-group-agent:lark:group:ou_abc123", key);
}

// ── extractBody tests ────────────────────────────────────────────

test "extractBody finds body after headers" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\n\r\n{\"message\":\"hi\"}";
    const body = extractBody(raw);
    try std.testing.expect(body != null);
    try std.testing.expectEqualStrings("{\"message\":\"hi\"}", body.?);
}

test "extractBody returns null for no body" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(extractBody(raw) == null);
}

test "extractBody returns null for no separator" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n";
    try std.testing.expect(extractBody(raw) == null);
}

test "expectedHttpRequestSize rejects oversized incomplete headers" {
    const raw = try std.testing.allocator.alloc(u8, MAX_HEADER_SIZE + 1);
    defer std.testing.allocator.free(raw);
    for (raw) |*byte| byte.* = 'a';
    try std.testing.expectError(error.RequestTooLarge, expectedHttpRequestSize(raw));
}

test "expectedHttpRequestSize returns header length for requests without body" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expectEqual(raw.len, (try expectedHttpRequestSize(raw)).?);
}

test "expectedHttpRequestSize includes content length payload" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expectEqual(raw.len, (try expectedHttpRequestSize(raw)).?);
}

test "expectedHttpRequestSize rejects invalid content length" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\nContent-Length: abc\r\n\r\nhello";
    try std.testing.expectError(error.InvalidContentLength, expectedHttpRequestSize(raw));
}

test "expectedHttpRequestSize rejects oversized content length" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\nContent-Length: 999999\r\n\r\n";
    try std.testing.expectError(error.RequestTooLarge, expectedHttpRequestSize(raw));
}

test "readHttpRequestFromReader assembles fragmented request" {
    const ChunkedReader = struct {
        chunks: []const []const u8,
        chunk_idx: usize = 0,
        offset_in_chunk: usize = 0,

        fn read(self: *@This(), out: []u8) !usize {
            while (self.chunk_idx < self.chunks.len and self.offset_in_chunk >= self.chunks[self.chunk_idx].len) {
                self.chunk_idx += 1;
                self.offset_in_chunk = 0;
            }
            if (self.chunk_idx >= self.chunks.len) return 0;

            const chunk = self.chunks[self.chunk_idx];
            const remaining = chunk[self.offset_in_chunk..];
            const n = @min(out.len, remaining.len);
            std.mem.copyForwards(u8, out[0..n], remaining[0..n]);
            self.offset_in_chunk += n;
            return n;
        }
    };

    const expected = "POST /pair HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\nhello world";
    const chunks = [_][]const u8{
        "POST /pair HTTP/1.1\r\nHo",
        "st: localhost\r\nContent-Length: 11\r\n\r\nhel",
        "lo world",
    };
    var reader = ChunkedReader{ .chunks = chunks[0..] };

    const raw = try readHttpRequestFromReader(std.testing.allocator, &reader);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings(expected, raw);
}

test "readHttpRequestFromReader returns IncompleteRequest for truncated body" {
    const ChunkedReader = struct {
        chunks: []const []const u8,
        chunk_idx: usize = 0,
        offset_in_chunk: usize = 0,

        fn read(self: *@This(), out: []u8) !usize {
            while (self.chunk_idx < self.chunks.len and self.offset_in_chunk >= self.chunks[self.chunk_idx].len) {
                self.chunk_idx += 1;
                self.offset_in_chunk = 0;
            }
            if (self.chunk_idx >= self.chunks.len) return 0;

            const chunk = self.chunks[self.chunk_idx];
            const remaining = chunk[self.offset_in_chunk..];
            const n = @min(out.len, remaining.len);
            std.mem.copyForwards(u8, out[0..n], remaining[0..n]);
            self.offset_in_chunk += n;
            return n;
        }
    };

    const chunks = [_][]const u8{
        "POST /pair HTTP/1.1\r\nHost: localhost\r\nContent-Length: 8\r\n\r\nabc",
    };
    var reader = ChunkedReader{ .chunks = chunks[0..] };
    try std.testing.expectError(error.IncompleteRequest, readHttpRequestFromReader(std.testing.allocator, &reader));
}

test "readHttpRequestFromReader maps WouldBlock to RequestTimeout" {
    const TimeoutReader = struct {
        const ReadError = error{ WouldBlock, ConnectionTimedOut };

        fn read(_: *@This(), _: []u8) ReadError!usize {
            return error.WouldBlock;
        }
    };

    var reader = TimeoutReader{};
    try std.testing.expectError(error.RequestTimeout, readHttpRequestFromReader(std.testing.allocator, &reader));
}

test "userFacingAgentError maps ProviderDoesNotSupportVision" {
    try std.testing.expectEqualStrings(
        "The current provider does not support image input.",
        userFacingAgentError(error.ProviderDoesNotSupportVision),
    );
}

test "userFacingAgentError maps NoResponseContent" {
    try std.testing.expectEqualStrings(
        "Model returned an empty response. Please try again.",
        userFacingAgentError(error.NoResponseContent),
    );
}

test "userFacingAgentError maps AllProvidersFailed" {
    try std.testing.expectEqualStrings(
        "All configured providers failed for this request. Check model/provider compatibility and credentials.",
        userFacingAgentError(error.AllProvidersFailed),
    );
}

test "userFacingAgentError maps generic error fallback" {
    try std.testing.expectEqualStrings(
        "An error occurred. Try again.",
        userFacingAgentError(error.Unexpected),
    );
}

test "userFacingAgentErrorJson maps NoResponseContent" {
    try std.testing.expectEqualStrings(
        "{\"error\":\"model returned empty response\"}",
        userFacingAgentErrorJson(error.NoResponseContent),
    );
}

test "userFacingAgentErrorJson maps AllProvidersFailed" {
    try std.testing.expectEqualStrings(
        "{\"error\":\"all providers failed for this request\"}",
        userFacingAgentErrorJson(error.AllProvidersFailed),
    );
}

test "userFacingAgentErrorJson maps generic error fallback" {
    try std.testing.expectEqualStrings(
        "{\"error\":\"agent failure\"}",
        userFacingAgentErrorJson(error.Unexpected),
    );
}

test "GatewayState init has empty telegram_bot_token" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqualStrings("", state.telegram_bot_token);
}

// ── asciiEqlIgnoreCase tests ─────────────────────────────────────

test "asciiEqlIgnoreCase equal strings" {
    try std.testing.expect(asciiEqlIgnoreCase("Authorization", "authorization"));
    try std.testing.expect(asciiEqlIgnoreCase("CONTENT-TYPE", "content-type"));
    try std.testing.expect(asciiEqlIgnoreCase("Host", "Host"));
}

test "asciiEqlIgnoreCase different strings" {
    try std.testing.expect(!asciiEqlIgnoreCase("Authorization", "authenticate"));
    try std.testing.expect(!asciiEqlIgnoreCase("a", "ab"));
}

test "asciiEqlIgnoreCase empty strings" {
    try std.testing.expect(asciiEqlIgnoreCase("", ""));
}

// ── WhatsApp HMAC-SHA256 Signature Verification tests ───────────

test "verifyWhatsappSignature valid signature" {
    // Compute a real HMAC-SHA256 and verify it passes
    const body = "{\"entry\":[{\"changes\":[{\"value\":{\"messages\":[{\"text\":{\"body\":\"hello\"}}]}}]}]}";
    const secret = "my_app_secret";
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, secret);
    // Format as hex
    var hex_buf: [64]u8 = undefined;
    for (0..32) |i| {
        const byte = mac[i];
        hex_buf[i * 2] = "0123456789abcdef"[byte >> 4];
        hex_buf[i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }
    var header_buf: [71]u8 = undefined; // "sha256=" (7) + 64 hex chars
    @memcpy(header_buf[0..7], "sha256=");
    @memcpy(header_buf[7..71], &hex_buf);
    try std.testing.expect(verifyWhatsappSignature(body, &header_buf, secret));
}

test "verifyWhatsappSignature invalid signature rejected" {
    const body = "{\"message\":\"test\"}";
    const secret = "correct_secret";
    // Provide a well-formed but wrong signature (all zeros)
    const bad_sig = "sha256=0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expect(!verifyWhatsappSignature(body, bad_sig, secret));
}

test "verifyWhatsappSignature missing sha256= prefix rejected" {
    const body = "test body";
    const secret = "secret";
    const no_prefix = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    try std.testing.expect(!verifyWhatsappSignature(body, no_prefix, secret));
}

test "verifyWhatsappSignature empty body with valid signature" {
    const body = "";
    const secret = "empty_body_secret";
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, secret);
    var hex_buf: [64]u8 = undefined;
    for (0..32) |i| {
        const byte = mac[i];
        hex_buf[i * 2] = "0123456789abcdef"[byte >> 4];
        hex_buf[i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }
    var header_buf: [71]u8 = undefined;
    @memcpy(header_buf[0..7], "sha256=");
    @memcpy(header_buf[7..71], &hex_buf);
    try std.testing.expect(verifyWhatsappSignature(body, &header_buf, secret));
}

test "verifyWhatsappSignature empty secret returns false" {
    const body = "any body";
    const sig = "sha256=0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expect(!verifyWhatsappSignature(body, sig, ""));
}

test "verifyWhatsappSignature wrong secret rejected" {
    const body = "{\"data\":\"payload\"}";
    const correct_secret = "real_secret";
    const wrong_secret = "wrong_secret";
    // Compute signature with correct secret
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, correct_secret);
    var hex_buf: [64]u8 = undefined;
    for (0..32) |i| {
        const byte = mac[i];
        hex_buf[i * 2] = "0123456789abcdef"[byte >> 4];
        hex_buf[i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }
    var header_buf: [71]u8 = undefined;
    @memcpy(header_buf[0..7], "sha256=");
    @memcpy(header_buf[7..71], &hex_buf);
    // Verify with wrong secret — should fail
    try std.testing.expect(!verifyWhatsappSignature(body, &header_buf, wrong_secret));
}

test "verifyWhatsappSignature constant-time comparison basic check" {
    // Verify that two identical MACs pass and two differing-by-one-bit MACs fail.
    // This doesn't prove constant-time, but ensures the comparison logic is correct.
    const body = "timing test body";
    const secret = "timing_secret";
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, secret);

    // constantTimeEql with itself
    try std.testing.expect(constantTimeEql(&mac, &mac));

    // Flip one bit in the last byte
    var altered = mac;
    altered[31] ^= 0x01;
    try std.testing.expect(!constantTimeEql(&mac, &altered));

    // Flip one bit in the first byte
    var altered2 = mac;
    altered2[0] ^= 0x80;
    try std.testing.expect(!constantTimeEql(&mac, &altered2));
}

test "verifyWhatsappSignature hex encoding edge cases" {
    // Truncated hex (too short)
    try std.testing.expect(!verifyWhatsappSignature("body", "sha256=abcdef", "secret"));
    // Too long hex
    try std.testing.expect(!verifyWhatsappSignature("body", "sha256=00000000000000000000000000000000000000000000000000000000000000001", "secret"));
    // Invalid hex characters
    try std.testing.expect(!verifyWhatsappSignature("body", "sha256=zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", "secret"));
    // Empty signature header
    try std.testing.expect(!verifyWhatsappSignature("body", "", "secret"));
    // Just the prefix, no hex
    try std.testing.expect(!verifyWhatsappSignature("body", "sha256=", "secret"));
}

test "verifyWhatsappSignature uppercase hex accepted" {
    // Meta typically sends lowercase, but we accept uppercase too
    const body = "uppercase hex test";
    const secret = "hex_secret";
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, secret);
    var hex_buf: [64]u8 = undefined;
    for (0..32) |i| {
        const byte = mac[i];
        hex_buf[i * 2] = "0123456789ABCDEF"[byte >> 4];
        hex_buf[i * 2 + 1] = "0123456789ABCDEF"[byte & 0x0f];
    }
    var header_buf: [71]u8 = undefined;
    @memcpy(header_buf[0..7], "sha256=");
    @memcpy(header_buf[7..71], &hex_buf);
    try std.testing.expect(verifyWhatsappSignature(body, &header_buf, secret));
}

test "verifySlackSignature accepts valid signature" {
    const body = "{\"type\":\"event_callback\"}";
    const secret = "slack_signing_secret";

    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch unreachable;

    var signed: std.ArrayListUnmanaged(u8) = .empty;
    defer signed.deinit(std.testing.allocator);
    const sw = signed.writer(std.testing.allocator);
    try sw.print("v0:{s}:", .{ts});
    try sw.writeAll(body);

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, signed.items, secret);

    var sig_buf: [67]u8 = undefined; // "v0=" + 64 hex
    @memcpy(sig_buf[0..3], "v0=");
    for (0..32) |i| {
        const byte = mac[i];
        sig_buf[3 + i * 2] = "0123456789abcdef"[byte >> 4];
        sig_buf[3 + i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }

    try std.testing.expect(verifySlackSignature(std.testing.allocator, body, ts, &sig_buf, secret));
}

fn buildSignedSlackWebhookRequest(
    allocator: std.mem.Allocator,
    target: []const u8,
    body: []const u8,
    signing_secret: []const u8,
) ![]u8 {
    var ts_buf: [32]u8 = undefined;
    const ts = try std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()});

    var signed: std.ArrayListUnmanaged(u8) = .empty;
    defer signed.deinit(allocator);
    const sw = signed.writer(allocator);
    try sw.print("v0:{s}:", .{ts});
    try sw.writeAll(body);

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, signed.items, signing_secret);

    var sig_buf: [67]u8 = undefined; // "v0=" + 64 hex
    @memcpy(sig_buf[0..3], "v0=");
    for (0..32) |i| {
        const byte = mac[i];
        sig_buf[3 + i * 2] = "0123456789abcdef"[byte >> 4];
        sig_buf[3 + i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }

    return std.fmt.allocPrint(
        allocator,
        "POST {s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nX-Slack-Request-Timestamp: {s}\r\nX-Slack-Signature: {s}\r\n\r\n{s}",
        .{ target, ts, sig_buf, body },
    );
}

test "handleSlackWebhookRoute strict rejects unmapped ingress when channel is strict" {
    if (!build_options.enable_channel_slack) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const signing_secret = "strict_slack_secret";
    const body =
        \\{"type":"event_callback","event":{"type":"message","user":"U_STRICT","text":"hello","channel":"D_STRICT","channel_type":"im","event_ts":"1700000000","ts":"1700000000"}}
    ;
    const raw = try buildSignedSlackWebhookRequest(allocator, "/slack/events", body, signing_secret);

    const slack_accounts = [_]config_types.SlackConfig{
        .{
            .account_id = "stage2a",
            .mode = .http,
            .bot_token = "xoxb-stage2a",
            .signing_secret = signing_secret,
            .webhook_path = "/slack/events",
        },
    };
    const strict_channels = [_][]const u8{"slack"};
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .channels = .{ .slack = &slack_accounts },
    };
    cfg.tenant.enabled = true;
    cfg.tenant.identity_mapping_enforcement = "staged_strict";
    cfg.tenant.identity_mapping_strict_channels = &strict_channels;
    cfg.state.backend = "postgres";

    var state = GatewayState.init(allocator);
    defer state.deinit();

    var ctx = WebhookHandlerContext{
        .root_allocator = allocator,
        .req_allocator = allocator,
        .raw_request = raw,
        .method = "POST",
        .target = "/slack/events",
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleSlackWebhookRoute(&ctx);

    try std.testing.expectEqualStrings("403 Forbidden", ctx.response_status);
    try std.testing.expect(std.mem.indexOf(u8, ctx.response_body, "strict_identity_reject") != null);
}

test "handleSlackWebhookRoute compat mode accepts unmapped ingress" {
    if (!build_options.enable_channel_slack) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const signing_secret = "compat_slack_secret";
    const body =
        \\{"type":"event_callback","event":{"type":"message","user":"U_COMPAT","text":"hello","channel":"D_COMPAT","channel_type":"im","event_ts":"1700000001","ts":"1700000001"}}
    ;
    const raw = try buildSignedSlackWebhookRequest(allocator, "/slack/events", body, signing_secret);

    const slack_accounts = [_]config_types.SlackConfig{
        .{
            .account_id = "stage2a",
            .mode = .http,
            .bot_token = "xoxb-stage2a",
            .signing_secret = signing_secret,
            .webhook_path = "/slack/events",
        },
    };
    var cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
        .channels = .{ .slack = &slack_accounts },
    };
    cfg.tenant.enabled = true;
    cfg.tenant.identity_mapping_enforcement = "compat";
    cfg.state.backend = "postgres";

    var state = GatewayState.init(allocator);
    defer state.deinit();

    var ctx = WebhookHandlerContext{
        .root_allocator = allocator,
        .req_allocator = allocator,
        .raw_request = raw,
        .method = "POST",
        .target = "/slack/events",
        .config_opt = &cfg,
        .state = &state,
        .session_mgr_opt = null,
    };
    handleSlackWebhookRoute(&ctx);

    try std.testing.expectEqualStrings("200 OK", ctx.response_status);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", ctx.response_body);
}

test "verifySlackSignature rejects stale timestamp" {
    const body = "{\"type\":\"event_callback\"}";
    const secret = "slack_signing_secret";

    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp() - 900}) catch unreachable;

    var signed: std.ArrayListUnmanaged(u8) = .empty;
    defer signed.deinit(std.testing.allocator);
    const sw = signed.writer(std.testing.allocator);
    try sw.print("v0:{s}:", .{ts});
    try sw.writeAll(body);

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, signed.items, secret);

    var sig_buf: [67]u8 = undefined;
    @memcpy(sig_buf[0..3], "v0=");
    for (0..32) |i| {
        const byte = mac[i];
        sig_buf[3 + i * 2] = "0123456789abcdef"[byte >> 4];
        sig_buf[3 + i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }

    try std.testing.expect(!verifySlackSignature(std.testing.allocator, body, ts, &sig_buf, secret));
}

test "hasSlackHttpEndpoint respects mode and webhook_path" {
    const slack_accounts = [_]config_types.SlackConfig{
        .{
            .account_id = "sl-http",
            .mode = .http,
            .bot_token = "xoxb-http",
            .signing_secret = "sec-http",
            .webhook_path = "/slack/custom",
        },
        .{
            .account_id = "sl-socket",
            .mode = .socket,
            .bot_token = "xoxb-socket",
            .app_token = "xapp-socket",
        },
    };
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .slack = &slack_accounts,
        },
    };

    if (!build_options.enable_channel_slack) {
        try std.testing.expect(!hasSlackHttpEndpoint(&cfg, "/slack/custom"));
        try std.testing.expect(!hasSlackHttpEndpoint(&cfg, "/slack/events"));
        try std.testing.expect(!hasSlackHttpEndpoint(&cfg, "/line"));
        return;
    }

    try std.testing.expect(hasSlackHttpEndpoint(&cfg, "/slack/custom"));
    try std.testing.expect(!hasSlackHttpEndpoint(&cfg, "/slack/events"));
    try std.testing.expect(!hasSlackHttpEndpoint(&cfg, "/line"));
}

test "findSlackConfigForRequest selects account by verified signature" {
    const body = "{\"type\":\"event_callback\",\"event\":{\"type\":\"message\",\"channel\":\"C1\",\"user\":\"U1\",\"text\":\"hi\"}}";
    const ts_val = std.time.timestamp();
    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{ts_val}) catch unreachable;

    const secret_a = "slack_secret_a";
    const secret_b = "slack_secret_b";

    var signed: std.ArrayListUnmanaged(u8) = .empty;
    defer signed.deinit(std.testing.allocator);
    const sw = signed.writer(std.testing.allocator);
    try sw.print("v0:{s}:", .{ts});
    try sw.writeAll(body);

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac_b: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac_b, signed.items, secret_b);

    var sig_buf: [67]u8 = undefined;
    @memcpy(sig_buf[0..3], "v0=");
    for (0..32) |i| {
        const byte = mac_b[i];
        sig_buf[3 + i * 2] = "0123456789abcdef"[byte >> 4];
        sig_buf[3 + i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }

    const slack_accounts = [_]config_types.SlackConfig{
        .{
            .account_id = "a",
            .mode = .http,
            .bot_token = "xoxb-a",
            .signing_secret = secret_a,
            .webhook_path = "/slack/events",
        },
        .{
            .account_id = "b",
            .mode = .http,
            .bot_token = "xoxb-b",
            .signing_secret = secret_b,
            .webhook_path = "/slack/events",
        },
    };
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .slack = &slack_accounts,
        },
    };

    const selected = findSlackConfigForRequest(std.testing.allocator, &cfg, "/slack/events", body, ts, &sig_buf);
    if (!build_options.enable_channel_slack) {
        try std.testing.expect(selected == null);
        return;
    }
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("b", selected.?.account_id);
}

test "GatewayState init has empty whatsapp_app_secret" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqualStrings("", state.whatsapp_app_secret);
}

// ── /ready endpoint tests ────────────────────────────────────────────

test "handleReady all components healthy returns 200" {
    health.reset();
    health.markComponentOk("gateway");
    health.markComponentOk("database");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    // Verify JSON contains "ready" status
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ready\"") != null);
}

test "handleReady one component unhealthy returns 503" {
    health.reset();
    health.markComponentOk("gateway");
    health.markComponentError("database", "connection refused");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"not_ready\"") != null);
}

test "handleReady no components returns 200 vacuously" {
    health.reset();
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"checks\":[]") != null);
}

test "handleReady JSON output has checks array" {
    health.reset();
    health.markComponentOk("agent");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"checks\":[") != null);
    // Should contain the agent component
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"name\":\"agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"healthy\":true") != null);
}

test "handleReady multiple unhealthy components returns 503" {
    health.reset();
    health.markComponentError("gateway", "port in use");
    health.markComponentError("database", "disk full");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"not_ready\"") != null);
}

test "handleReady response body is valid JSON structure" {
    health.reset();
    health.markComponentOk("test-svc");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    // Must start with { and end with }
    try std.testing.expect(resp.body.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), resp.body[0]);
    try std.testing.expectEqual(@as(u8, '}'), resp.body[resp.body.len - 1]);
}

test "handleReady unhealthy component includes error message" {
    health.reset();
    health.markComponentError("cache", "redis timeout");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"message\":\"redis timeout\"") != null);
}

test "handleReady recovered component shows healthy" {
    health.reset();
    health.markComponentError("db", "down");
    health.markComponentOk("db");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"healthy\":true") != null);
}

test "publishToBus creates inbound message on bus" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const ok = publishToBus(&eb, alloc, "telegram", "user1", "chat42", "hello", "telegram:chat42", null);
    try std.testing.expect(ok);

    // Consume the message
    const msg = eb.consumeInbound() orelse return error.TestUnexpectedResult;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("telegram", msg.channel);
    try std.testing.expectEqualStrings("user1", msg.sender_id);
    try std.testing.expectEqualStrings("chat42", msg.chat_id);
    try std.testing.expectEqualStrings("hello", msg.content);
    try std.testing.expectEqualStrings("telegram:chat42", msg.session_key);
}

test "publishToBus with metadata" {
    const alloc = std.testing.allocator;
    var eb = bus_mod.Bus.init();
    defer eb.close();

    const meta = "{\"account_id\":\"personal\"}";
    const ok = publishToBus(&eb, alloc, "whatsapp", "sender", "chat1", "hi", "wa:chat1", meta);
    try std.testing.expect(ok);

    const msg = eb.consumeInbound() orelse return error.TestUnexpectedResult;
    defer msg.deinit(alloc);
    try std.testing.expectEqualStrings("whatsapp", msg.channel);
    try std.testing.expectEqualStrings("hi", msg.content);
    try std.testing.expect(msg.metadata_json != null);
    try std.testing.expectEqualStrings("{\"account_id\":\"personal\"}", msg.metadata_json.?);
}

test "GatewayState event_bus defaults to null" {
    var gs = GatewayState.init(std.testing.allocator);
    defer gs.deinit();
    try std.testing.expect(gs.event_bus == null);
}

test "gatewayRoleNeedsLocalAgent keeps shared default behavior" {
    try std.testing.expect(gatewayRoleNeedsLocalAgent(.shared, false));
    try std.testing.expect(!gatewayRoleNeedsLocalAgent(.shared, true));
    try std.testing.expect(!gatewayRoleNeedsLocalAgent(.broker, false));
    try std.testing.expect(!gatewayRoleNeedsLocalAgent(.user_cell, false));
}

test "gatewayRoleOwnsTenantExecution disables local execution for broker role" {
    try std.testing.expect(gatewayRoleOwnsTenantExecution(.shared));
    try std.testing.expect(!gatewayRoleOwnsTenantExecution(.broker));
    try std.testing.expect(gatewayRoleOwnsTenantExecution(.user_cell));
}

test "resolveGatewayRequestUserId pins user_cell requests to one user" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.role = .user_cell;
    state.pinned_user_id = "42";

    try std.testing.expectEqualStrings("42", try resolveGatewayRequestUserId(&state, null, null, true));
    try std.testing.expectEqualStrings("42", try resolveGatewayRequestUserId(&state, "42", null, true));
    try std.testing.expectEqualStrings("42", try resolveGatewayRequestUserId(&state, null, "42", true));
    try std.testing.expectError(error.UserCellUserMismatch, resolveGatewayRequestUserId(&state, "7", null, true));
    try std.testing.expectError(error.UserCellUserMismatch, resolveGatewayRequestUserId(&state, null, "7", true));
}

test "runWithRole rejects user_cell mode without pinned user" {
    const cfg = Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .tenant = .{
            .enabled = true,
        },
        .allocator = std.testing.allocator,
    };

    try std.testing.expectError(
        error.UserCellRequiresPinnedUser,
        runWithRole(std.testing.allocator, "127.0.0.1", 0, &cfg, null, .user_cell, null, null, null),
    );
}

test "runWithRole rejects user_cell mode when tenant semantics are disabled" {
    const cfg = Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .tenant = .{
            .enabled = false,
        },
        .allocator = std.testing.allocator,
    };

    try std.testing.expectError(
        error.UserCellRequiresTenantMode,
        runWithRole(std.testing.allocator, "127.0.0.1", 0, &cfg, null, .user_cell, null, null, "1"),
    );
}

test "runWithRole rejects controller-backed user_cell mode without advertise url" {
    const cfg = Config{
        .workspace_dir = "/tmp/nullalis-test",
        .config_path = "/tmp/nullalis-test/config.json",
        .tenant = .{
            .enabled = true,
        },
        .allocator = std.testing.allocator,
    };

    try std.testing.expectError(
        error.UserCellRequiresAdvertiseUrl,
        runWithRole(std.testing.allocator, "127.0.0.1", 0, &cfg, null, .user_cell, "http://127.0.0.1:3001", null, "1"),
    );
}

fn makeTenantRuntimeTestConfig(
    allocator: std.mem.Allocator,
    tenant_root: []const u8,
    base_config_path: []const u8,
) Config {
    var cfg = Config{
        .workspace_dir = tenant_root,
        .config_path = base_config_path,
        .allocator = allocator,
        .default_model = "test/mock-model",
    };
    cfg.tenant.enabled = true;
    cfg.memory.search.enabled = false;
    cfg.browser.enabled = false;
    cfg.http_request.enabled = false;
    return cfg;
}

fn provisionTenantRuntimeTestUser(
    allocator: std.mem.Allocator,
    state: *GatewayState,
    user_id: []const u8,
) !UserContext {
    var user_ctx = try resolveUserContext(allocator, state, user_id);
    errdefer user_ctx.deinit(allocator);
    try ensureUserProvisioned(state, &user_ctx);
    return user_ctx;
}

test "getTenantRuntime does not prune inline on request path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    const base_config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/base-config.json", .{tenant_root});
    defer std.testing.allocator.free(base_config_path);
    try writeFile(base_config_path, "{\"agents\":{\"defaults\":{\"model\":{\"primary\":\"openrouter/test/mock-model\"}}},\"memory\":{\"search\":{\"enabled\":false}}}\n");

    var cfg = makeTenantRuntimeTestConfig(std.testing.allocator, tenant_root, base_config_path);
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_enabled = true;
    state.tenant_data_root = tenant_root;
    state.tenant_runtime_cache_max_users = 1;
    state.tenant_runtime_idle_ttl_secs = 0;

    var user_ctx_1 = try provisionTenantRuntimeTestUser(std.testing.allocator, &state, "1");
    defer user_ctx_1.deinit(std.testing.allocator);
    const runtime_1 = try getTenantRuntime(&state, &cfg, &user_ctx_1);

    var user_ctx_2 = try provisionTenantRuntimeTestUser(std.testing.allocator, &state, "2");
    defer user_ctx_2.deinit(std.testing.allocator);
    const runtime_2 = try getTenantRuntime(&state, &cfg, &user_ctx_2);

    try std.testing.expect(runtime_1 != runtime_2);
    try std.testing.expectEqual(@as(usize, 2), state.tenant_runtimes.count());

    state.tenant_runtime_mutex.lock();
    defer state.tenant_runtime_mutex.unlock();
    try std.testing.expect(state.tenant_runtimes.get("1") != null);
    try std.testing.expect(state.tenant_runtimes.get("2") != null);
}

test "tenant runtime maintenance prunes cache outside request path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    const base_config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/base-config.json", .{tenant_root});
    defer std.testing.allocator.free(base_config_path);
    try writeFile(base_config_path, "{\"agents\":{\"defaults\":{\"model\":{\"primary\":\"openrouter/test/mock-model\"}}},\"memory\":{\"search\":{\"enabled\":false}}}\n");

    var cfg = makeTenantRuntimeTestConfig(std.testing.allocator, tenant_root, base_config_path);
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_enabled = true;
    state.tenant_data_root = tenant_root;
    state.tenant_runtime_cache_max_users = 1;
    state.tenant_runtime_idle_ttl_secs = 0;

    var user_ctx_1 = try provisionTenantRuntimeTestUser(std.testing.allocator, &state, "1");
    defer user_ctx_1.deinit(std.testing.allocator);
    const runtime_1 = try getTenantRuntime(&state, &cfg, &user_ctx_1);

    var user_ctx_2 = try provisionTenantRuntimeTestUser(std.testing.allocator, &state, "2");
    defer user_ctx_2.deinit(std.testing.allocator);
    const runtime_2 = try getTenantRuntime(&state, &cfg, &user_ctx_2);

    runtime_1.last_used_s.store(10, .release);
    runtime_2.last_used_s.store(20, .release);

    runTenantRuntimeMaintenance(&state, 20);

    state.tenant_runtime_mutex.lock();
    defer state.tenant_runtime_mutex.unlock();
    try std.testing.expectEqual(@as(usize, 1), state.tenant_runtimes.count());
    try std.testing.expect(state.tenant_runtimes.get("1") == null);
    try std.testing.expect(state.tenant_runtimes.get("2") != null);
}

test "tenant runtime maintenance evicts idle sessions outside request path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    const base_config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/base-config.json", .{tenant_root});
    defer std.testing.allocator.free(base_config_path);
    try writeFile(base_config_path, "{\"agents\":{\"defaults\":{\"model\":{\"primary\":\"openrouter/test/mock-model\"}}},\"memory\":{\"search\":{\"enabled\":false}}}\n");

    var cfg = makeTenantRuntimeTestConfig(std.testing.allocator, tenant_root, base_config_path);
    cfg.agent.session_idle_timeout_secs = 60;

    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.tenant_enabled = true;
    state.tenant_data_root = tenant_root;

    var user_ctx = try provisionTenantRuntimeTestUser(std.testing.allocator, &state, "1");
    defer user_ctx.deinit(std.testing.allocator);
    const runtime = try getTenantRuntime(&state, &cfg, &user_ctx);

    const session = try runtime.session_mgr.getOrCreate("agent:zaki-bot:user:1:thread:tg:111");
    session.last_active = 0;
    try std.testing.expectEqual(@as(usize, 1), runtime.session_mgr.sessionCount());

    runTenantRuntimeMaintenance(&state, std.time.timestamp());

    try std.testing.expectEqual(@as(usize, 0), runtime.session_mgr.sessionCount());
}

test "resolveUserContext rejects mismatched user in user_cell mode" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();
    gs.role = .user_cell;
    gs.pinned_user_id = "42";

    try std.testing.expectError(error.UserCellUserMismatch, resolveUserContext(allocator, &gs, "7"));
}

test "resolveUserContext uses mounted workspace contract in user_cell mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_dir);

    var gs = GatewayState.init(std.testing.allocator);
    defer gs.deinit();
    gs.role = .user_cell;
    gs.pinned_user_id = "42";
    gs.workspace_dir = workspace_dir;

    var user_ctx = try resolveUserContext(std.testing.allocator, &gs, "42");
    defer user_ctx.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(workspace_dir, user_ctx.workspace_path);
    const expected_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/.nullalis", .{workspace_dir});
    defer std.testing.allocator.free(expected_root);
    try std.testing.expectEqualStrings(expected_root, user_ctx.user_root);
    const expected_secrets = try std.fmt.allocPrint(std.testing.allocator, "{s}/secrets", .{expected_root});
    defer std.testing.allocator.free(expected_secrets);
    try std.testing.expectEqualStrings(expected_secrets, user_ctx.secrets_dir);
}

test "loadHeartbeatRuntimeSummary reads user_cell runtime state from workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".nullalis");
    try tmp.dir.writeFile(.{
        .sub_path = ".nullalis/heartbeat_runtime.json",
        .data = "{\"last_run_s\":123,\"last_status\":\"sent\",\"last_reason\":\"none\"}\n",
    });
    const workspace_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_dir);

    var gs = GatewayState.init(std.testing.allocator);
    defer gs.deinit();
    gs.role = .user_cell;
    gs.workspace_dir = workspace_dir;

    var summary = loadHeartbeatRuntimeSummary(std.testing.allocator, &gs, "42");
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(summary.available);
    try std.testing.expectEqual(@as(?i64, 123), summary.last_run_s);
    try std.testing.expectEqualStrings("sent", summary.last_status.?);
}

test "handleBrokerCellControlRoute requires internal auth" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.role = .broker;
    state.internal_auth_required = true;
    state.internal_service_tokens = &[_][]const u8{"svc-prod-token-1234"};

    const response = handleBrokerCellControlRoute(std.testing.allocator, &state, "POST /internal/cells/ensure HTTP/1.1\r\nHost: localhost\r\n\r\n", "POST", .ensure);
    try std.testing.expectEqualStrings("401 Unauthorized", response.status);
    try std.testing.expectEqualStrings("{\"error\":\"unauthorized\"}", response.body);
}

test "handleBrokerCellControlRoute returns controller unavailable without controller url" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.role = .broker;
    state.internal_auth_required = true;
    state.internal_service_tokens = &[_][]const u8{"svc-prod-token-1234"};

    const raw = "POST /internal/cells/ensure HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\n\r\n";
    const response = handleBrokerCellControlRoute(std.testing.allocator, &state, raw, "POST", .ensure);
    try std.testing.expectEqualStrings("503 Service Unavailable", response.status);
    try std.testing.expectEqualStrings("{\"error\":\"controller_unavailable\"}", response.body);
}

test "handleBrokerCellControlRoute hidden outside broker role" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    state.role = .shared;
    state.internal_auth_required = true;
    state.internal_service_tokens = &[_][]const u8{"svc-prod-token-1234"};

    const raw = "GET /internal/cells/status HTTP/1.1\r\nHost: localhost\r\nX-Internal-Token: svc-prod-token-1234\r\n\r\n";
    const response = handleBrokerCellControlRoute(std.testing.allocator, &state, raw, "GET", .status);
    try std.testing.expectEqualStrings("404 Not Found", response.status);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", response.body);
}

test "parseBrokerResolvedCell extracts routed cell url" {
    const body =
        "{\"status\":\"ok\",\"operation\":\"ensure\",\"user_id\":\"42\",\"found\":true,\"created\":true,\"cell\":{\"user_id\":\"42\",\"cell_url\":\"http://127.0.0.1:3100\",\"state\":\"warm\",\"created_at_s\":1,\"updated_at_s\":1,\"last_ensured_at_s\":1,\"drain_requested_at_s\":null,\"ensure_count\":1}}";
    var resolved = try parseBrokerResolvedCell(std.testing.allocator, body);
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expect(resolved.found);
    try std.testing.expectEqual(BrokerResolvedCell.State.warm, resolved.state);
    try std.testing.expectEqualStrings("http://127.0.0.1:3100", resolved.cell_url.?);
}

test "parseBrokerResolvedCell extracts pending state without cell url" {
    const body =
        "{\"status\":\"ok\",\"operation\":\"ensure\",\"user_id\":\"42\",\"found\":true,\"created\":true,\"cell\":{\"user_id\":\"42\",\"cell_url\":null,\"state\":\"pending\",\"created_at_s\":1,\"updated_at_s\":1,\"last_ensured_at_s\":1,\"drain_requested_at_s\":null,\"ensure_count\":1}}";
    var resolved = try parseBrokerResolvedCell(std.testing.allocator, body);
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expect(resolved.found);
    try std.testing.expectEqual(BrokerResolvedCell.State.pending, resolved.state);
    try std.testing.expect(resolved.cell_url == null);
}

test "normalizeAdvertiseUrl trims and preserves routable service url" {
    const normalized = try normalizeAdvertiseUrl(std.testing.allocator, "  http://nullalis-cell-42.zaki.svc.cluster.local:3000/ \n");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("http://nullalis-cell-42.zaki.svc.cluster.local:3000", normalized);
}

test "normalizeAdvertiseUrl rejects empty or schemeless values" {
    try std.testing.expectError(error.InvalidAdvertiseUrl, normalizeAdvertiseUrl(std.testing.allocator, "   "));
    try std.testing.expectError(error.InvalidAdvertiseUrl, normalizeAdvertiseUrl(std.testing.allocator, "nullalis-cell-42:3000"));
}

test "parseUpstreamResponseHeader parses status and body offset" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nX-Test: 1\r\n\r\nevent: token\r\n\r\n";
    const parsed = try parseUpstreamResponseHeader(raw);
    try std.testing.expectEqual(@as(u16, 200), parsed.status_code);
    try std.testing.expectEqualStrings("event: token\r\n\r\n", raw[parsed.body_offset..]);
}

test "writeTelegramFallbackStateFile writes telegram fallback state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/telegram.json", .{tmp_root});
    defer std.testing.allocator.free(path);

    try writeTelegramFallbackStateFile(path, "{\"connected\":true}\n");
    const content = try readFileOrDefault(std.testing.allocator, path, "");
    defer if (content.len > 0) std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("{\"connected\":true}\n", content);
}

test "syncTelegramStateFallbackBestEffort surfaces failure without throwing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing/telegram.json", .{tmp_root});
    defer std.testing.allocator.free(path);

    const ok = syncTelegramStateFallbackBestEffort(path, "{\"connected\":true}\n");
    try std.testing.expect(!ok);
}

test "syncTelegramSecretFallbackBestEffort surfaces failure without throwing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing/telegram_bot_token", .{tmp_root});
    defer std.testing.allocator.free(path);

    const ok = syncTelegramSecretFallbackBestEffort(path, "123:abc");
    try std.testing.expect(!ok);
}

test "deleteTelegramFallbackFilesBestEffort surfaces failure without throwing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_root);

    const ok = deleteTelegramFallbackFilesBestEffort(tmp_root, tmp_root);
    try std.testing.expect(!ok);
}

test "deleteTelegramFallbackFiles removes local fallback files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_root);
    const telegram_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/telegram.json", .{tmp_root});
    defer std.testing.allocator.free(telegram_path);
    const channel_state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/channel_state.json", .{tmp_root});
    defer std.testing.allocator.free(channel_state_path);

    try writeFile(telegram_path, "{\"connected\":true}\n");
    try writeFile(channel_state_path, "{\"telegram\":{\"chat_id\":1}}\n");

    try deleteTelegramFallbackFiles(telegram_path, channel_state_path);

    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(telegram_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(channel_state_path, .{}));
}

test "extractRequestTarget returns raw request target with query" {
    const raw = "POST /api/v1/users/42/onboarding?step=1 HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expectEqualStrings("/api/v1/users/42/onboarding?step=1", extractRequestTarget(raw).?);
}

test "firstConfiguredInternalServiceToken skips blank entries" {
    const tokens = &[_][]const u8{ "   ", "\t", "svc-prod-token-1234", "other-token" };
    try std.testing.expectEqualStrings("svc-prod-token-1234", firstConfiguredInternalServiceToken(tokens).?);
    try std.testing.expect(firstConfiguredInternalServiceToken(&[_][]const u8{ "", "   " }) == null);
}

test "resolveUserContext rejects non-numeric user ids when postgres tenant state is enabled" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();
    gs.tenant_enabled = true;
    var fake_mgr: zaki_state_mod.Manager = undefined;
    gs.zaki_state = &fake_mgr;
    defer gs.zaki_state = null;

    try std.testing.expectError(error.InvalidUserId, resolveUserContext(allocator, &gs, "stable-user"));
}

const TestGateThreadCtx = struct {
    gate: *UserPreparationGate,
    acquired: *std.atomic.Value(bool),
};

fn testAcquirePreparationGate(ctx: *TestGateThreadCtx) void {
    var guard = ctx.gate.acquire("user-1") catch return;
    defer guard.deinit();
    ctx.acquired.store(true, .release);
}

test "UserPreparationGate serializes same-user work on one node" {
    var gate = UserPreparationGate.init(std.testing.allocator);
    defer gate.deinit();

    var first = try gate.acquire("user-1");
    defer first.deinit();

    var acquired = std.atomic.Value(bool).init(false);
    var ctx = TestGateThreadCtx{
        .gate = &gate,
        .acquired = &acquired,
    };
    const thread = try std.Thread.spawn(.{}, testAcquirePreparationGate, .{&ctx});

    std.Thread.sleep(20 * std.time.ns_per_ms);
    try std.testing.expect(!acquired.load(.acquire));

    first.release();
    thread.join();
    try std.testing.expect(acquired.load(.acquire));
}

test "internalDiagnosticsPayload includes runtime_mode and bus fields" {
    const allocator = std.testing.allocator;
    lane_metrics.resetForTest();
    lane_metrics.recordBackgroundMainReroute("diag-job");
    var gs = GatewayState.init(allocator);
    defer gs.deinit();
    var eb = bus_mod.Bus.init();
    defer eb.close();
    gs.event_bus = &eb;
    gs.tenant_enabled = true;
    gs.ownership_lock_enabled = true;
    gs.ownership_lock_lease_secs = 300;
    gs.internal_auth_required = true;
    gs.internal_token_configured = true;
    gs.internal_token_policy_ok = true;
    gs.internal_token_policy_reason = "";
    gs.require_explicit_chat_stream_session_key = true;
    gs.owner_instance_id = "diag-owner";
    recordTenantLockConflict(&gs, .chat_stream_sse);
    recordTenantLockConflict(&gs, .webhook);
    recordChatStreamLane(&gs, "agent:zaki-bot:user:1:thread:diag", "1", true);
    recordChatStreamSessionKeyRejection(&gs, .missing);

    const payload = try internalDiagnosticsPayload(allocator, &gs, null);
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"runtime_mode\":\"threaded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"internal_auth_required\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"internal_token_configured\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"internal_token_policy_ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"internal_token_policy_reason\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"instance_id\":\"diag-owner\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"owned_users_count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"chat_stream_require_explicit_session_key\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tenant_lock_backend\":\"file_lock\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tenant_lock_lease_secs\":300") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"chat_stream_lane_counts\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"thread\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"chat_stream_session_key_rejections\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"missing\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"bus\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"inbound_len\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"outbound_len\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"capacity\":1024") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tenant_lock_conflicts_by_route\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"chat_stream_sse\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"webhook\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"background_main_reroutes_total\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"background_main_reroutes_last_job_id\":\"diag-job\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"agent_message_timeout_secs\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"provider_retries\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"fallback_provider_count\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"memory_vector_sync_mode\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"memory_outbox_enabled\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"control_plane\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"agent.parallel_tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"agent.tool_dispatcher\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"configured_agent_message_timeout_secs\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tenant_lease_probe\":null") != null);
}

test "internalDiagnosticsPayload normalizes user readiness surfaces without loaded runtime" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tenant_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tenant_root);

    const base_config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/base-config.json", .{tenant_root});
    defer std.testing.allocator.free(base_config_path);
    try writeFile(base_config_path, "{\"default_provider\":\"together\",\"default_model\":\"moonshotai/Kimi-K2.5\"}\n");

    const user_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/42", .{tenant_root});
    defer std.testing.allocator.free(user_dir);
    try std.fs.makeDirAbsolute(user_dir);
    const user_config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{user_dir});
    defer std.testing.allocator.free(user_config_path);
    try writeFile(user_config_path, "{\"product_settings\":{\"assistant_mode\":\"deep\",\"group_activation\":\"always\",\"proactive_updates\":false,\"voice_replies\":true,\"session_timeout_minutes\":45}}\n");
    const heartbeat_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/heartbeat.json", .{user_dir});
    defer std.testing.allocator.free(heartbeat_path);
    try writeFile(heartbeat_path, "{\"enabled\":false,\"intervalSec\":3600}\n");
    const runtime_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/heartbeat_runtime.json", .{user_dir});
    defer std.testing.allocator.free(runtime_path);
    try writeFile(runtime_path, "{\"last_run_s\":123,\"last_status\":\"send_failed\",\"last_reason\":\"no_target\"}\n");
    const telegram_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/telegram.json", .{user_dir});
    defer std.testing.allocator.free(telegram_path);
    try writeFile(telegram_path, "{\"connected\":true,\"account_id\":\"default\",\"webhook_url\":\"https://example.com/webhook/telegram?user_id=1\",\"allow_from\":[\"*\"]}\n");
    const onboarding_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/onboarding.json", .{user_dir});
    defer std.testing.allocator.free(onboarding_path);
    try writeFile(onboarding_path, "{\"completed\":false,\"completed_at_s\":null}\n");
    const secrets_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/secrets", .{user_dir});
    defer std.testing.allocator.free(secrets_dir);
    try std.fs.makeDirAbsolute(secrets_dir);
    const token_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/telegram_bot_token", .{secrets_dir});
    defer std.testing.allocator.free(token_path);
    try writeFile(token_path, "123456:ABCDEF\n");

    var gs = GatewayState.init(std.testing.allocator);
    defer gs.deinit();
    gs.tenant_enabled = true;
    gs.tenant_enabled_configured = true;
    gs.tenant_data_root = tenant_root;
    gs.heartbeat_enabled = true;
    gs.heartbeat_interval_minutes = 60;
    gs.state_backend_effective = "file";
    gs.state_backend_configured = "file";
    gs.chat_provider_effective = "together";
    gs.embedding_provider_effective = "together";
    gs.config_path_len = copyIntoBuf(&gs.config_path_buf, base_config_path);

    const payload = try internalDiagnosticsPayload(std.testing.allocator, &gs, "42");
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"assistant_mode\":\"deep\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"group_activation\":\"always\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"proactive_updates\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"voice_replies\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"session_timeout_minutes\":45") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"telegram_connected_normalized\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"telegram_state_valid\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"heartbeat_enabled_normalized\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"client_ready_status\":\"needs_reconnect\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"proactive_status\":\"disabled_cleanly\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"last_status\":\"disabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"last_reason\":\"user_disabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"status\":\"needs_reconnect\"") != null);
}

test "appendControlPlaneStringEntryWithDrift suppresses expected derived drift" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendControlPlaneStringEntryWithDrift(
        &buf,
        std.testing.allocator,
        "agent.tool_dispatcher",
        "auto",
        "serial",
        "helm_config",
        false,
    );
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"configured\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"effective\":\"serial\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"drift\":false") != null);
}

test "recordTenantLockConflict increments route counters and total" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();

    recordTenantLockConflict(&gs, .chat_stream_sse);
    recordTenantLockConflict(&gs, .chat_stream_http);
    recordTenantLockConflict(&gs, .webhook);
    recordTenantLockConflict(&gs, .daemon);
    recordTenantLockConflict(&gs, .api);

    try std.testing.expectEqual(@as(u64, 5), gs.tenant_lock_conflicts_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), gs.tenant_lock_conflicts_chat_stream_sse_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), gs.tenant_lock_conflicts_chat_stream_http_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), gs.tenant_lock_conflicts_webhook_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), gs.tenant_lock_conflicts_daemon_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), gs.tenant_lock_conflicts_api_total.load(.monotonic));
}

test "recordChatStreamLane increments per-lane counters" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();

    recordChatStreamLane(&gs, "agent:zaki-bot:user:5:main", "5", true);
    recordChatStreamLane(&gs, "agent:zaki-bot:user:5:thread:abc", "5", true);
    recordChatStreamLane(&gs, "agent:zaki-bot:user:5:task:abc", "5", true);
    recordChatStreamLane(&gs, "agent:zaki-bot:user:5:cron:abc", "5", true);

    try std.testing.expectEqual(@as(u64, 1), gs.chat_stream_lane_main_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), gs.chat_stream_lane_thread_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), gs.chat_stream_lane_task_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), gs.chat_stream_lane_cron_total.load(.monotonic));
}

test "recordChatStreamSessionKeyRejection increments reason counters" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();

    recordChatStreamSessionKeyRejection(&gs, .missing);
    recordChatStreamSessionKeyRejection(&gs, .invalid);
    recordChatStreamSessionKeyRejection(&gs, .wrong_user);
    recordChatStreamSessionKeyRejection(&gs, .invalid_lane);

    try std.testing.expectEqual(@as(u64, 1), gs.chat_stream_session_key_missing_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), gs.chat_stream_session_key_invalid_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), gs.chat_stream_session_key_wrong_user_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), gs.chat_stream_session_key_invalid_lane_total.load(.monotonic));
}

test "metricsPayload includes chat stream lane and session key counters" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();

    recordChatStreamLane(&gs, "agent:zaki-bot:user:7:task:bench", "7", true);
    recordChatStreamSessionKeyRejection(&gs, .wrong_user);

    const payload = try metricsPayload(allocator, &gs);
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_chat_stream_lanes_total{lane=\"task\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_chat_stream_session_key_rejections_total{reason=\"wrong_user\"} 1") != null);
}

test "metricsPayload includes lifecycle timing series" {
    const allocator = std.testing.allocator;
    var gs = GatewayState.init(allocator);
    defer gs.deinit();

    var obs = LifecycleMetricsObserver{ .metrics = &gs.lifecycle_metrics };
    const lock_wait_event = ObserverEvent{ .turn_stage = .{
        .stage = GATEWAY_SESSION_LOCK_WAIT_STAGE,
        .duration_ms = 12,
    } };
    obs.observer().recordEvent(&lock_wait_event);
    const compaction_event = ObserverEvent{ .turn_stage = .{
        .stage = "turn_auto_compaction",
        .duration_ms = 34,
    } };
    obs.observer().recordEvent(&compaction_event);
    const continuity_event = ObserverEvent{ .turn_stage = .{
        .stage = "continuity_refresh",
        .duration_ms = 9,
    } };
    obs.observer().recordEvent(&continuity_event);
    gs.lifecycle_metrics.recordPruning(7, 2, 1);

    const payload = try metricsPayload(allocator, &gs);
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_lifecycle_stage_total{stage=\"lock_wait\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_lifecycle_stage_duration_ms_total{stage=\"lock_wait\"} 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_lifecycle_stage_total{stage=\"compaction\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_lifecycle_stage_duration_ms_total{stage=\"compaction\"} 34") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_lifecycle_stage_total{stage=\"continuity_refresh\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_lifecycle_stage_duration_ms_total{stage=\"continuity_refresh\"} 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_lifecycle_stage_total{stage=\"pruning\"} 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_lifecycle_stage_duration_ms_total{stage=\"pruning\"} 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_tenant_runtime_pruned_total{reason=\"idle\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "nullalis_gateway_tenant_runtime_pruned_total{reason=\"capacity\"} 1") != null);
}

// ── jsonEscapeInto tests ────────────────────────────────────────

fn escapeToString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try jsonEscapeInto(w, input);
    return buf.toOwnedSlice(allocator);
}

test "jsonEscapeInto escapes double quotes" {
    const result = try escapeToString(std.testing.allocator, "hello \"world\"");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello \\\"world\\\"", result);
}

test "jsonEscapeInto escapes backslashes" {
    const result = try escapeToString(std.testing.allocator, "path\\to\\file");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", result);
}

test "jsonEscapeInto escapes newlines and tabs" {
    const result = try escapeToString(std.testing.allocator, "line1\nline2\ttab");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("line1\\nline2\\ttab", result);
}

test "jsonEscapeInto escapes control chars as unicode" {
    // 0x00, 0x01, 0x1F
    const result = try escapeToString(std.testing.allocator, &[_]u8{ 0x00, 0x01, 0x1F });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\\u0000\\u0001\\u001f", result);
}

test "jsonEscapeInto empty string yields empty output" {
    const result = try escapeToString(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "jsonEscapeInto passes through unicode and emoji unchanged" {
    const result = try escapeToString(std.testing.allocator, "hello \xc3\xa9\xf0\x9f\x98\x80 world");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello \xc3\xa9\xf0\x9f\x98\x80 world", result);
}

test "jsonEscapeInto escapes carriage return" {
    const result = try escapeToString(std.testing.allocator, "hello\r\nworld");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello\\r\\nworld", result);
}

test "jsonEscapeInto escapes backspace and form feed" {
    const result = try escapeToString(std.testing.allocator, "a\x08b\x0Cc");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a\\bb\\fc", result);
}

test "jsonEscapeInto mixed special characters" {
    const result = try escapeToString(std.testing.allocator, "He said \"hi\\there\"\nnew line");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("He said \\\"hi\\\\there\\\"\\nnew line", result);
}

// ── jsonWrapField tests ─────────────────────────────────────────

test "jsonWrapField produces valid JSON string field" {
    const result = try jsonWrapField(std.testing.allocator, "msg", "hello \"world\"");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"msg\":\"hello \\\"world\\\"\"", result);
}

test "jsonWrapField with empty value" {
    const result = try jsonWrapField(std.testing.allocator, "key", "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"key\":\"\"", result);
}

test "jsonWrapField result is valid JSON when wrapped in braces" {
    const field = try jsonWrapField(std.testing.allocator, "response", "test\nvalue");
    defer std.testing.allocator.free(field);
    // Wrap in object: {"response":"test\nvalue"}
    const json = try std.fmt.allocPrint(std.testing.allocator, "{{{s}}}", .{field});
    defer std.testing.allocator.free(json);
    // Parse to verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const val = parsed.value.object.get("response") orelse unreachable;
    try std.testing.expect(val == .string);
    try std.testing.expectEqualStrings("test\nvalue", val.string);
}

// ── jsonWrapResponse tests ──────────────────────────────────────

test "jsonWrapResponse produces valid JSON with escaped content" {
    const result = try jsonWrapResponse(std.testing.allocator, "Hello \"user\"\nLine 2");
    defer std.testing.allocator.free(result);
    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const status = parsed.value.object.get("status") orelse unreachable;
    try std.testing.expectEqualStrings("ok", status.string);
    const response = parsed.value.object.get("response") orelse unreachable;
    try std.testing.expectEqualStrings("Hello \"user\"\nLine 2", response.string);
}

test "jsonWrapResponse with clean input" {
    const result = try jsonWrapResponse(std.testing.allocator, "simple reply");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"status\":\"ok\",\"response\":\"simple reply\"}", result);
}

// ── jsonWrapChallenge tests ─────────────────────────────────────

test "jsonWrapChallenge produces valid JSON" {
    const result = try jsonWrapChallenge(std.testing.allocator, "abc123");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"challenge\":\"abc123\"}", result);
}

test "jsonWrapChallenge escapes malicious challenge value" {
    const result = try jsonWrapChallenge(std.testing.allocator, "abc\",\"evil\":\"true");
    defer std.testing.allocator.free(result);
    // Must be valid JSON with the value properly escaped
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const challenge = parsed.value.object.get("challenge") orelse unreachable;
    try std.testing.expectEqualStrings("abc\",\"evil\":\"true", challenge.string);
    // Must NOT have an "evil" key (injection prevented)
    try std.testing.expect(parsed.value.object.get("evil") == null);
}

test "sseErrorEvent includes code and terminal done event" {
    const sse = try sseErrorEvent(std.testing.allocator, "chat_failed", "chat failed");
    defer std.testing.allocator.free(sse);
    try std.testing.expect(std.mem.indexOf(u8, sse, "event: error") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"type\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"code\":\"chat_failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"message\":\"chat failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "event: done") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"type\":\"done\"") != null);
}

test "sseProgressFrame emits progress payload with optional fields" {
    const frame = try sseProgressFrame(
        std.testing.allocator,
        "tool",
        "start",
        "Using \"schedule\"",
        "schedule",
        2,
        123,
    );
    defer std.testing.allocator.free(frame);

    try std.testing.expect(std.mem.indexOf(u8, frame, "event: progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"type\":\"progress\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"phase\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"state\":\"start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"label\":\"Using \\\"schedule\\\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool\":\"schedule\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"iteration\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"duration_ms\":123") != null);
}

test "sseReasoningSummaryFrame emits reasoning summary payload with optional fields" {
    const frame = try sseReasoningSummaryFrame(
        std.testing.allocator,
        "Using web_search to verify the answer",
        "tool",
        "web_search",
        1,
    );
    defer std.testing.allocator.free(frame);

    try std.testing.expect(std.mem.indexOf(u8, frame, "event: reasoning_summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"type\":\"reasoning_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"summary\":\"Using web_search to verify the answer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"phase\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"tool\":\"web_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"iteration\":1") != null);
}

test "sseReplyStartFrame emits explicit final reply streaming metadata" {
    const frame = try sseReplyStartFrame(std.testing.allocator, "final_reply", "buffered_replay", false);
    defer std.testing.allocator.free(frame);

    try std.testing.expect(std.mem.indexOf(u8, frame, "event: reply_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"type\":\"reply_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"stream_kind\":\"final_reply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"delivery_mode\":\"buffered_replay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"live\":false") != null);
}

test "sseTokenFrame emits explicit final reply metadata" {
    const frame = try sseTokenFrame(std.testing.allocator, "hello world", 3);
    defer std.testing.allocator.free(frame);

    try std.testing.expect(std.mem.indexOf(u8, frame, "event: token") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"delta\":\"hello world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"content\":\"hello world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"seq\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"stream_kind\":\"final_reply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"live\":false") != null);
}

test "sseChatPayload emits token deltas and done metadata" {
    const sse = try sseChatPayload(std.testing.allocator, "hello world", "agent:zaki-bot:user:user_a:main");
    defer std.testing.allocator.free(sse);
    try std.testing.expect(std.mem.indexOf(u8, sse, "event: reply_start") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"type\":\"reply_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"stream_kind\":\"final_reply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"delivery_mode\":\"buffered_replay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"live\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "event: token") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"delta\":\"hello world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"content\":\"hello world\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"seq\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "event: done") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"type\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"session_id\":\"agent:zaki-bot:user:user_a:main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"message_id\":\"") != null);
}

test "resolveChatStreamSessionKey falls back to canonical user main key" {
    var fallback_buf: [256]u8 = undefined;
    const session_key = try resolveChatStreamSessionKey("{\"message\":\"hi\"}", "42", true, false, &fallback_buf);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:main", session_key);
}

test "resolveChatStreamSessionKey accepts tenant-owned override" {
    var fallback_buf: [256]u8 = undefined;
    const session_key = try resolveChatStreamSessionKey(
        "{\"message\":\"hi\",\"session_key\":\"agent:zaki-bot:user:42:thread:abc\"}",
        "42",
        true,
        false,
        &fallback_buf,
    );
    try std.testing.expectEqualStrings("agent:zaki-bot:user:42:thread:abc", session_key);
}

test "resolveChatStreamSessionKey rejects cross-user override in tenant mode" {
    var fallback_buf: [256]u8 = undefined;
    try std.testing.expectError(
        error.SessionKeyUserMismatch,
        resolveChatStreamSessionKey(
            "{\"message\":\"hi\",\"session_key\":\"agent:zaki-bot:user:43:main\"}",
            "42",
            true,
            false,
            &fallback_buf,
        ),
    );
}

test "resolveChatStreamSessionKey rejects invalid tenant lane override" {
    var fallback_buf: [256]u8 = undefined;
    try std.testing.expectError(
        error.InvalidSessionLane,
        resolveChatStreamSessionKey(
            "{\"message\":\"hi\",\"session_key\":\"agent:zaki-bot:user:42:bench:abc\"}",
            "42",
            true,
            false,
            &fallback_buf,
        ),
    );
}

test "resolveChatStreamSessionKey requires explicit key when strict mode is enabled" {
    var fallback_buf: [256]u8 = undefined;
    try std.testing.expectError(
        error.MissingSessionKey,
        resolveChatStreamSessionKey(
            "{\"message\":\"hi\"}",
            "42",
            true,
            true,
            &fallback_buf,
        ),
    );
}

test "resolveChatStreamSessionKey allows non-tenant custom lanes" {
    var fallback_buf: [256]u8 = undefined;
    const session_key = try resolveChatStreamSessionKey(
        "{\"message\":\"hi\",\"session_key\":\"local:bench:1\"}",
        "42",
        false,
        false,
        &fallback_buf,
    );
    try std.testing.expectEqualStrings("local:bench:1", session_key);
}

test "buildIncomingMessageAgentArgv forwards tenant session context" {
    const argv = try buildIncomingMessageAgentArgv(
        std.testing.allocator,
        "/tmp/nullalis",
        "hello",
        "agent:zaki-bot:user:1:main",
        "1",
    );
    defer std.testing.allocator.free(argv);

    try std.testing.expectEqual(@as(usize, 8), argv.len);
    try std.testing.expectEqualStrings("/tmp/nullalis", argv[0]);
    try std.testing.expectEqualStrings("agent", argv[1]);
    try std.testing.expectEqualStrings("-m", argv[2]);
    try std.testing.expectEqualStrings("hello", argv[3]);
    try std.testing.expectEqualStrings("--session", argv[4]);
    try std.testing.expectEqualStrings("agent:zaki-bot:user:1:main", argv[5]);
    try std.testing.expectEqualStrings("--user-id", argv[6]);
    try std.testing.expectEqualStrings("1", argv[7]);
}

test "parseUserChannelBindingsSubpath parses bindings collection route" {
    const parsed = parseUserChannelBindingsSubpath("channels/telegram/bindings") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("telegram", parsed.channel);
    try std.testing.expect(parsed.binding_id == null);
}

test "parseUserChannelBindingsSubpath parses binding item route" {
    const parsed = parseUserChannelBindingsSubpath("channels/slack/bindings/bnd_123") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("slack", parsed.channel);
    try std.testing.expectEqualStrings("bnd_123", parsed.binding_id.?);
}

test "tenant preference application uses operator-owned assistant mode presets" {
    var cfg = Config{
        .workspace_dir = "/tmp/nullalis",
        .config_path = "/tmp/nullalis/config.json",
        .allocator = std.testing.allocator,
    };
    user_settings.applySettingsToConfig(&cfg, .{
        .assistant_mode = .deep,
        .group_activation = .always,
        .proactive_updates = false,
        .voice_replies = true,
        .session_timeout_minutes = 45,
    });

    try std.testing.expectEqualStrings("serial", cfg.agent.queue_mode);
    try std.testing.expectEqual(@as(u32, 20), cfg.agent.queue_cap);
    try std.testing.expectEqualStrings("summarize", cfg.agent.queue_drop);
    try std.testing.expectEqual(@as(u32, 80), cfg.agent.max_history_messages);
    try std.testing.expectEqualStrings("always", cfg.agent.activation_mode);
    try std.testing.expectEqualStrings("off", cfg.agent.send_mode);
    try std.testing.expectEqualStrings("inbound", cfg.agent.tts_mode);
    try std.testing.expect(cfg.agent.tts_audio);
    try std.testing.expectEqual(@as(?u64, 2700), cfg.agent.session_ttl_secs);
    try std.testing.expect(cfg.memory.summarizer.enabled);
    try std.testing.expectEqual(@as(u32, 6000), cfg.memory.summarizer.window_size_tokens);
    try std.testing.expectEqual(@as(u32, 700), cfg.memory.summarizer.summary_max_tokens);
    try std.testing.expect(cfg.memory.summarizer.auto_extract_semantic);
    try std.testing.expect(!cfg.session.cross_channel_shared_main);
}

test "tenant config normalization strips operator-owned runtime keys" {
    const normalized = try user_settings.normalizeTenantConfigJson(
        std.testing.allocator,
        "{\"default_provider\":\"openai\",\"agent\":{\"parallel_tools\":true},\"memory\":{\"search\":{\"enabled\":false}},\"product_settings\":{\"assistant_mode\":\"balanced\",\"group_activation\":\"mention\",\"proactive_updates\":true,\"voice_replies\":false,\"session_timeout_minutes\":30}}",
    );
    defer std.testing.allocator.free(normalized.json);

    try std.testing.expectEqual(@as(usize, 3), normalized.ignored_override_count);
    try std.testing.expect(std.mem.indexOf(u8, normalized.json, "\"default_provider\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, normalized.json, "\"agent\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, normalized.json, "\"memory\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, normalized.json, "\"product_settings\"") != null);
}

test "telegramReplyContainsMediaMarkers detects audio marker" {
    try std.testing.expect(telegramReplyContainsMediaMarkers("[AUDIO:/tmp/nullalis_tts_1.mp3]\nHello"));
    try std.testing.expect(!telegramReplyContainsMediaMarkers("Plain text reply"));
}

// ── Baseline characterization tests (Phase 00-01) ───────────────

test "baseline: MAX_BODY_SIZE is 65536" {
    try std.testing.expectEqual(@as(usize, 65_536), MAX_BODY_SIZE);
}

test "baseline: RATE_LIMIT_WINDOW_SECS is 60" {
    try std.testing.expectEqual(@as(u64, 60), RATE_LIMIT_WINDOW_SECS);
}

test "baseline: RATE_LIMITER_SWEEP_INTERVAL_SECS is 300" {
    try std.testing.expectEqual(@as(u64, 300), RATE_LIMITER_SWEEP_INTERVAL_SECS);
}

test "baseline: REQUEST_TIMEOUT_SECS is 30" {
    try std.testing.expectEqual(@as(u64, 30), REQUEST_TIMEOUT_SECS);
}

test "baseline: SSE_TOKEN_CHUNK_SIZE is 96" {
    try std.testing.expectEqual(@as(usize, 96), SSE_TOKEN_CHUNK_SIZE);
}

test "baseline: sseStatusFrame emits event:status with content" {
    const frame = try sseStatusFrame(std.testing.allocator, "thinking");
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: status\ndata: "));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"statusResponse\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"thinking\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, frame, "\n\n"));
}

test "baseline: sseReadyFrame emits event:ready with session key" {
    const frame = try sseReadyFrame(std.testing.allocator, "agent:zaki-bot:user:1:main");
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: ready\ndata: "));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "agent:zaki-bot:user:1:main") != null);
}

test "baseline: sseDoneFrame is always terminal with type:done" {
    const frame_full = try sseDoneFrame(std.testing.allocator, "sess-1", 42);
    defer std.testing.allocator.free(frame_full);
    try std.testing.expect(std.mem.startsWith(u8, frame_full, "event: done\ndata: "));
    try std.testing.expect(std.mem.indexOf(u8, frame_full, "\"type\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_full, "\"session_id\":\"sess-1\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, frame_full, "\n\n"));

    // Without optional fields
    const frame_minimal = try sseDoneFrame(std.testing.allocator, null, null);
    defer std.testing.allocator.free(frame_minimal);
    try std.testing.expect(std.mem.indexOf(u8, frame_minimal, "\"type\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_minimal, "session_id") == null);
}

test "baseline: sseErrorFrame emits event:error with code and message" {
    const frame = try sseErrorFrame(std.testing.allocator, "rate_limited", "Too many requests");
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: error\ndata: "));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"rate_limited\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"Too many requests\"") != null);
}

test "baseline: sseSubagentCompletionFrame emits event:subagent_completion" {
    const frame = try sseSubagentCompletionFrame(std.testing.allocator, "evt-1", "session:task:7", "task result here");
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "event: subagent_completion\ndata: "));
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"subagent_completion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"evt-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"session:task:7\"") != null);
}

test "baseline: sseChatPayload emits reply_start then token(s) then done" {
    const payload = try sseChatPayload(std.testing.allocator, "Hello world", "sess-42");
    defer std.testing.allocator.free(payload);
    // Must start with reply_start event
    try std.testing.expect(std.mem.startsWith(u8, payload, "event: reply_start\n"));
    // Must contain at least one token event
    try std.testing.expect(std.mem.indexOf(u8, payload, "event: token\n") != null);
    // Must end with done event
    try std.testing.expect(std.mem.indexOf(u8, payload, "event: done\n") != null);
    // reply_start must appear before done
    const reply_pos = std.mem.indexOf(u8, payload, "event: reply_start\n").?;
    const done_pos = std.mem.indexOf(u8, payload, "event: done\n").?;
    try std.testing.expect(reply_pos < done_pos);
}

test "baseline: SlidingWindowRateLimiter tracks requests within window" {
    var limiter = SlidingWindowRateLimiter{
        .limit_per_window = 3,
        .window_ns = @as(i128, RATE_LIMIT_WINDOW_SECS) * 1_000_000_000,
        .entries = .{},
        .last_sweep = std.time.nanoTimestamp(),
    };
    defer limiter.deinit(std.testing.allocator);

    // First 3 requests should be allowed
    try std.testing.expect(limiter.allow(std.testing.allocator, "test-ip"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "test-ip"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "test-ip"));
    // 4th should be denied
    try std.testing.expect(!limiter.allow(std.testing.allocator, "test-ip"));
    // Different key should still be allowed
    try std.testing.expect(limiter.allow(std.testing.allocator, "other-ip"));
}

test "baseline: IdempotencyStore deduplicates keys" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);
    // First insert returns true (new)
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "req-1"));
    // Duplicate returns false
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "req-1"));
    // Different key returns true
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "req-2"));
}
