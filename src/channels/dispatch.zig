const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");
const bus = @import("../bus.zig");
const ops_guard = @import("../ops_guard.zig");
const runtime_resolver = @import("../delivery/runtime_resolver.zig");
const telegram = @import("telegram.zig");
const TEST_THREAD_STACK_SIZE: usize = 256 * 1024;

/// Message dispatch — routes incoming ChannelMessages to the agent,
/// routes agent responses back to the originating channel.
///
/// This module replaces the Rust channels/mod.rs orchestration:
/// - start_channels, process_channel_message, build_system_prompt
///
/// Zig doesn't have async/await, so channels will be started
/// synchronously or via thread spawning.
pub const ChannelRegistry = struct {
    allocator: std.mem.Allocator,
    channels: std.ArrayListUnmanaged(ChannelEntry),

    const ChannelEntry = struct {
        channel: root.Channel,
        account_id: []const u8 = "default",
    };

    pub fn init(allocator: std.mem.Allocator) ChannelRegistry {
        return .{
            .allocator = allocator,
            .channels = .empty,
        };
    }

    pub fn deinit(self: *ChannelRegistry) void {
        self.channels.deinit(self.allocator);
    }

    pub fn register(self: *ChannelRegistry, ch: root.Channel) !void {
        try self.channels.append(self.allocator, .{ .channel = ch });
    }

    pub fn registerWithAccount(self: *ChannelRegistry, ch: root.Channel, account_id: []const u8) !void {
        try self.channels.append(self.allocator, .{
            .channel = ch,
            .account_id = account_id,
        });
    }

    pub fn count(self: *const ChannelRegistry) usize {
        return self.channels.items.len;
    }

    /// Find a channel by name.
    pub fn findByName(self: *const ChannelRegistry, channel_name: []const u8) ?root.Channel {
        for (self.channels.items) |entry| {
            if (std.mem.eql(u8, entry.channel.name(), channel_name)) return entry.channel;
        }
        return null;
    }

    pub fn findByNameAccount(self: *const ChannelRegistry, channel_name: []const u8, account_id: []const u8) ?root.Channel {
        for (self.channels.items) |entry| {
            if (std.mem.eql(u8, entry.channel.name(), channel_name) and
                std.mem.eql(u8, entry.account_id, account_id))
            {
                return entry.channel;
            }
        }
        return null;
    }

    /// Start all registered channels.
    pub fn startAll(self: *ChannelRegistry) !void {
        for (self.channels.items) |entry| {
            try entry.channel.start();
        }
    }

    /// Stop all registered channels.
    pub fn stopAll(self: *ChannelRegistry) void {
        for (self.channels.items) |entry| {
            entry.channel.stop();
        }
    }

    /// Run health checks on all channels.
    pub fn healthCheckAll(self: *const ChannelRegistry) HealthReport {
        var healthy: usize = 0;
        var unhealthy: usize = 0;
        for (self.channels.items) |entry| {
            if (entry.channel.healthCheck()) {
                healthy += 1;
            } else {
                unhealthy += 1;
            }
        }
        return .{ .healthy = healthy, .unhealthy = unhealthy, .total = self.channels.items.len };
    }

    /// Get names of all registered channels.
    pub fn channelNames(self: *const ChannelRegistry, allocator: std.mem.Allocator) ![][]const u8 {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer names.deinit(allocator);
        for (self.channels.items) |entry| {
            try names.append(allocator, entry.channel.name());
        }
        return names.toOwnedSlice(allocator);
    }
};

pub const HealthReport = struct {
    healthy: usize,
    unhealthy: usize,
    total: usize,

    pub fn allHealthy(self: HealthReport) bool {
        return self.unhealthy == 0 and self.total > 0;
    }
};

/// Build a system prompt with channel context.
pub fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    base_prompt: []const u8,
    channel_name: []const u8,
    identity_name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\nYou are {s}. You are responding on the {s} channel.",
        .{ base_prompt, identity_name, channel_name },
    );
}

// ════════════════════════════════════════════════════════════════════════════
// Outbound Dispatch Loop
// ════════════════════════════════════════════════════════════════════════════

/// Counters for the outbound dispatch loop (all atomic for thread safety).
pub const DispatchStats = struct {
    dispatched: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    channel_not_found: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn getDispatched(self: *const DispatchStats) u64 {
        return self.dispatched.load(.monotonic);
    }

    pub fn getErrors(self: *const DispatchStats) u64 {
        return self.errors.load(.monotonic);
    }

    pub fn getChannelNotFound(self: *const DispatchStats) u64 {
        return self.channel_not_found.load(.monotonic);
    }
};

pub const TenantDispatchContext = struct {
    enabled: bool = false,
    data_root: []const u8 = "",
    allow_telegram_fallback: bool = true,
};

fn normalizeTenantUserId(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "u:")) {
        return std.mem.trim(u8, trimmed[2..], " \t\r\n");
    }
    return trimmed;
}

fn isValidTenantUserId(user_id: []const u8) bool {
    if (user_id.len == 0 or user_id.len > 32) return false;
    for (user_id) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn tryTenantTelegramFallbackSend(
    allocator: Allocator,
    tenant_ctx: *const TenantDispatchContext,
    msg: *const bus.OutboundMessage,
) bool {
    if (!tenant_ctx.enabled or !tenant_ctx.allow_telegram_fallback) return false;
    if (!std.mem.eql(u8, msg.channel, "telegram")) return false;
    if (msg.content.len == 0) return false;
    const raw_user_id = msg.user_id orelse return false;
    const user_id = normalizeTenantUserId(raw_user_id);
    if (!isValidTenantUserId(user_id)) return false;
    if (user_id.len == 0 or tenant_ctx.data_root.len == 0) return false;

    const user_root = std.fmt.allocPrint(allocator, "{s}/{s}", .{ tenant_ctx.data_root, user_id }) catch return false;
    defer allocator.free(user_root);

    const user_dir = std.fs.openDirAbsolute(user_root, .{}) catch return false;
    @constCast(&user_dir).close();

    var resolved = runtime_resolver.resolveRuntimeDeliveryContext(allocator, .{
        .channel = "telegram",
        .tenant_ctx = .{},
        .user_root = user_root,
        .account_id_hint = msg.account_id,
        .target_hint = msg.chat_id,
    }) catch return false;
    defer resolved.deinit(allocator);

    runtime_resolver.requireConnectedTarget(&resolved) catch return false;
    const bot_token = runtime_resolver.requireCredential(&resolved) catch return false;
    const chat_id = runtime_resolver.parseResolvedTargetChatId(&resolved) catch return false;

    var chat_buf: [32]u8 = undefined;
    const chat_text = std.fmt.bufPrint(&chat_buf, "{d}", .{chat_id}) catch return false;
    var tg_channel = telegram.TelegramChannel.init(allocator, bot_token, &.{"*"}, &.{}, "open");
    tg_channel.sendMessage(chat_text, msg.content) catch return false;
    return true;
}

/// Run the outbound dispatch loop. Blocks until the bus is closed.
/// Consumes messages from `bus.consumeOutbound()` and routes them to the
/// appropriate channel via `registry.findByName(msg.channel)`.
///
/// Designed to run in a dedicated thread:
///   `std.Thread.spawn(.{}, runOutboundDispatcher, .{ alloc, &bus, &registry, &stats })`
///
/// The loop exits when `bus.close()` is called and the outbound queue is drained.
pub fn runOutboundDispatcher(
    allocator: Allocator,
    event_bus: *bus.Bus,
    registry: *const ChannelRegistry,
    stats: *DispatchStats,
) void {
    runOutboundDispatcherWithTenantContext(allocator, event_bus, registry, stats, null);
}

pub fn runOutboundDispatcherWithTenantContext(
    allocator: Allocator,
    event_bus: *bus.Bus,
    registry: *const ChannelRegistry,
    stats: *DispatchStats,
    tenant_ctx: ?*const TenantDispatchContext,
) void {
    const DeliverySignal = struct {
        fn shouldPublish(msg: *const bus.OutboundMessage) bool {
            const source = msg.source orelse return false;
            // Beta containment: only heartbeat outcomes drive runtime state today.
            // Suppress other sourced outcomes until the delivery path is stable again.
            return std.mem.eql(u8, source, "heartbeat");
        }

        fn publish(
            alloc: Allocator,
            eb: *bus.Bus,
            msg: *const bus.OutboundMessage,
            action: []const u8,
            reason: []const u8,
            ts_s: i64,
        ) void {
            if (!shouldPublish(msg)) return;
            const outcome = bus.makeDeliveryOutcome(
                alloc,
                msg.source,
                msg.user_id,
                msg.channel,
                msg.chat_id,
                action,
                reason,
                ts_s,
            ) catch return;
            eb.publishDeliveryOutcome(outcome) catch {
                outcome.deinit(alloc);
            };
        }
    };

    while (event_bus.consumeOutbound()) |msg| {
        defer msg.deinit(allocator);

        const source = msg.source orelse "";
        const proactive = ops_guard.isProactiveSource(msg.source);
        if (proactive) {
            const decision = ops_guard.allowProactive(
                source,
                msg.user_id,
                msg.channel,
                msg.chat_id,
                msg.content,
                msg.dedupe_key,
                std.time.timestamp(),
            );
            switch (decision) {
                .allow => {},
                .blocked_rate => {
                    DeliverySignal.publish(allocator, event_bus, &msg, "blocked_rate", "rate_limit", std.time.timestamp());
                    continue;
                },
                .blocked_dedupe => {
                    DeliverySignal.publish(allocator, event_bus, &msg, "blocked_dedupe", "dedupe_window", std.time.timestamp());
                    continue;
                },
            }
        }

        const channel_opt = if (msg.account_id) |aid|
            registry.findByNameAccount(msg.channel, aid)
        else
            registry.findByName(msg.channel);

        if (channel_opt) |channel| {
            channel.send(msg.chat_id, msg.content, msg.media) catch {
                _ = stats.errors.fetchAdd(1, .monotonic);
                DeliverySignal.publish(allocator, event_bus, &msg, "send_error", "channel_send_failed", std.time.timestamp());
                if (proactive) {
                    ops_guard.recordProactiveSendError(source, msg.user_id, msg.channel, msg.chat_id, "channel_send_failed", std.time.timestamp());
                }
                continue;
            };
            _ = stats.dispatched.fetchAdd(1, .monotonic);
            DeliverySignal.publish(allocator, event_bus, &msg, "sent", "sent", std.time.timestamp());
            if (proactive) {
                ops_guard.recordProactiveSent(source, msg.user_id, msg.channel, msg.chat_id, std.time.timestamp());
            }
        } else {
            if (tenant_ctx) |ctx| {
                if (tryTenantTelegramFallbackSend(allocator, ctx, &msg)) {
                    _ = stats.dispatched.fetchAdd(1, .monotonic);
                    DeliverySignal.publish(allocator, event_bus, &msg, "sent", "tenant_fallback", std.time.timestamp());
                    if (proactive) {
                        ops_guard.recordProactiveSent(source, msg.user_id, msg.channel, msg.chat_id, std.time.timestamp());
                    }
                    continue;
                }
            }
            _ = stats.channel_not_found.fetchAdd(1, .monotonic);
            DeliverySignal.publish(allocator, event_bus, &msg, "channel_not_found", "channel_not_found", std.time.timestamp());
            if (proactive) {
                ops_guard.recordProactiveSendError(source, msg.user_id, msg.channel, msg.chat_id, "channel_not_found", std.time.timestamp());
            }
        }
    }
}

/// Get names of all enabled (registered) channels.
pub fn getEnabledChannelNames(registry: *const ChannelRegistry, allocator: Allocator) ![][]const u8 {
    return registry.channelNames(allocator);
}

// ════════════════════════════════════════════════════════════════════════════
// Channel Supervisor
// ════════════════════════════════════════════════════════════════════════════

/// Wraps a Channel with supervision state: restart counting, exponential
/// backoff, and a circuit-breaker that gives up after `max_restarts`.
pub const SupervisedChannel = struct {
    channel: root.Channel,
    state: State = .idle,
    restart_count: u32 = 0,
    max_restarts: u32 = 5,
    backoff_ms: u64 = 1000,
    max_backoff_ms: u64 = 60000,
    backoff_factor: u64 = 2,

    pub const State = enum {
        idle,
        running,
        restarting,
        gave_up,
    };

    /// Record a channel failure. Increments the restart counter, computes
    /// exponential backoff, and transitions to `restarting` or `gave_up`.
    pub fn recordFailure(self: *SupervisedChannel) void {
        self.restart_count += 1;
        if (self.restart_count >= self.max_restarts) {
            self.state = .gave_up;
        } else {
            self.state = .restarting;
        }
        // Compute exponential backoff: initial * factor^(restart_count - 1)
        var delay: u64 = self.backoff_ms;
        var i: u32 = 1;
        while (i < self.restart_count) : (i += 1) {
            delay = @min(delay * self.backoff_factor, self.max_backoff_ms);
        }
        self.backoff_ms = @min(delay, self.max_backoff_ms);
    }

    /// Record a successful start / recovery. Resets restart count and
    /// backoff to initial values, sets state to `running`.
    pub fn recordSuccess(self: *SupervisedChannel) void {
        self.restart_count = 0;
        self.backoff_ms = 1000;
        self.state = .running;
    }

    /// Returns the current backoff delay in milliseconds.
    pub fn currentBackoffMs(self: *const SupervisedChannel) u64 {
        return self.backoff_ms;
    }

    /// Returns true if the supervisor should attempt a restart (state is
    /// `restarting`, not `gave_up`).
    pub fn shouldRestart(self: *const SupervisedChannel) bool {
        return self.state == .restarting;
    }
};

/// Create a SupervisedChannel wrapping the given Channel.
pub fn spawnSupervisedChannel(channel: root.Channel, max_restarts: u32) SupervisedChannel {
    return .{
        .channel = channel,
        .max_restarts = max_restarts,
    };
}

/// Wrap an array of Channels into heap-allocated SupervisedChannels.
pub fn startAllSupervised(allocator: Allocator, channels: []const root.Channel) ![]SupervisedChannel {
    const supervised = try allocator.alloc(SupervisedChannel, channels.len);
    for (channels, 0..) |ch, i| {
        supervised[i] = spawnSupervisedChannel(ch, 5);
    }
    return supervised;
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "channel registry init and count" {
    const allocator = std.testing.allocator;
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 0), reg.count());
}

test "channel registry register and find" {
    const allocator = std.testing.allocator;
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();

    var cli_ch = @import("cli.zig").CliChannel.init(allocator);
    try reg.register(cli_ch.channel());

    try std.testing.expectEqual(@as(usize, 1), reg.count());
    try std.testing.expect(reg.findByName("cli") != null);
    try std.testing.expect(reg.findByName("nonexistent") == null);
}

test "channel registry health check all" {
    const allocator = std.testing.allocator;
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();

    var cli_ch = @import("cli.zig").CliChannel.init(allocator);
    try reg.register(cli_ch.channel());

    const report = reg.healthCheckAll();
    try std.testing.expectEqual(@as(usize, 1), report.healthy);
    try std.testing.expectEqual(@as(usize, 0), report.unhealthy);
    try std.testing.expect(report.allHealthy());
}

test "channel registry channel names" {
    const allocator = std.testing.allocator;
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();

    var cli_ch = @import("cli.zig").CliChannel.init(allocator);
    try reg.register(cli_ch.channel());

    const names = try reg.channelNames(allocator);
    defer allocator.free(names);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("cli", names[0]);
}

test "health report all healthy" {
    const report = HealthReport{ .healthy = 3, .unhealthy = 0, .total = 3 };
    try std.testing.expect(report.allHealthy());
}

test "health report not all healthy" {
    const report = HealthReport{ .healthy = 2, .unhealthy = 1, .total = 3 };
    try std.testing.expect(!report.allHealthy());
}

test "health report empty is not healthy" {
    const report = HealthReport{ .healthy = 0, .unhealthy = 0, .total = 0 };
    try std.testing.expect(!report.allHealthy());
}

test "build system prompt" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "Be helpful.", "telegram", "nullalis");
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Be helpful.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "nullalis") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "telegram") != null);
}

// ════════════════════════════════════════════════════════════════════════════
// Outbound Dispatch Tests
// ════════════════════════════════════════════════════════════════════════════

/// Mock channel for dispatch tests.
const MockChannel = struct {
    name_str: []const u8,
    sent_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    should_fail: bool = false,

    const vtable = root.Channel.VTable{
        .start = mockStart,
        .stop = mockStop,
        .send = mockSend,
        .name = mockName,
        .healthCheck = mockHealthCheck,
    };

    fn channel(self: *MockChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn mockStart(_: *anyopaque) anyerror!void {}
    fn mockStop(_: *anyopaque) void {}
    fn mockSend(ctx: *anyopaque, _: []const u8, _: []const u8, _: []const []const u8) anyerror!void {
        const self: *MockChannel = @ptrCast(@alignCast(ctx));
        if (self.should_fail) return error.SendFailed;
        _ = self.sent_count.fetchAdd(1, .monotonic);
    }
    fn mockName(ctx: *anyopaque) []const u8 {
        const self: *const MockChannel = @ptrCast(@alignCast(ctx));
        return self.name_str;
    }
    fn mockHealthCheck(_: *anyopaque) bool {
        return true;
    }
};

fn waitUntil(comptime predicate: fn () bool, max_wait_ms: u64) bool {
    const sleep_step_ms: u64 = 2;
    var elapsed_ms: u64 = 0;
    while (elapsed_ms < max_wait_ms) : (elapsed_ms += sleep_step_ms) {
        if (predicate()) return true;
        std.Thread.sleep(sleep_step_ms * std.time.ns_per_ms);
    }
    return predicate();
}

test "DispatchStats init all zero" {
    const stats = DispatchStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 0), stats.getErrors());
    try std.testing.expectEqual(@as(u64, 0), stats.getChannelNotFound());
}

test "normalizeTenantUserId trims optional prefix and whitespace" {
    try std.testing.expectEqualStrings("7", normalizeTenantUserId("u:7"));
    try std.testing.expectEqualStrings("42", normalizeTenantUserId("  u:42  "));
    try std.testing.expectEqualStrings("9", normalizeTenantUserId(" 9 "));
}

test "isValidTenantUserId accepts digits only" {
    try std.testing.expect(isValidTenantUserId("1"));
    try std.testing.expect(isValidTenantUserId("1234567890"));
    try std.testing.expect(!isValidTenantUserId(""));
    try std.testing.expect(!isValidTenantUserId("u:1"));
    try std.testing.expect(!isValidTenantUserId("../1"));
    try std.testing.expect(!isValidTenantUserId("1/2"));
    try std.testing.expect(!isValidTenantUserId("abc"));
}

test "dispatcher routes message to correct channel" {
    const allocator = std.testing.allocator;

    var mock_tg = MockChannel{ .name_str = "telegram" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_tg.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    // Publish a message, then close bus so dispatcher exits
    const msg = try bus.makeOutbound(allocator, "telegram", "chat1", "hello");
    try event_bus.publishOutbound(msg);
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 1), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 0), stats.getErrors());
    try std.testing.expectEqual(@as(u64, 0), stats.getChannelNotFound());
    try std.testing.expectEqual(@as(u64, 1), mock_tg.sent_count.load(.monotonic));
}

test "dispatcher routes to matching account when channel has multiple accounts" {
    const allocator = std.testing.allocator;

    var main_tg = MockChannel{ .name_str = "telegram" };
    var backup_tg = MockChannel{ .name_str = "telegram" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerWithAccount(main_tg.channel(), "main");
    try reg.registerWithAccount(backup_tg.channel(), "backup");

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    const msg = try bus.makeOutboundWithAccount(allocator, "telegram", "backup", "chat1", "hello");
    try event_bus.publishOutbound(msg);
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 1), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 0), stats.getErrors());
    try std.testing.expectEqual(@as(u64, 0), stats.getChannelNotFound());
    try std.testing.expectEqual(@as(u64, 0), main_tg.sent_count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), backup_tg.sent_count.load(.monotonic));
}

test "dispatcher does not fallback to wrong account when account_id is unknown" {
    const allocator = std.testing.allocator;

    var main_tg = MockChannel{ .name_str = "telegram" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.registerWithAccount(main_tg.channel(), "main");

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    const msg = try bus.makeOutboundWithAccount(allocator, "telegram", "missing", "chat1", "hello");
    try event_bus.publishOutbound(msg);
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 0), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 0), stats.getErrors());
    try std.testing.expectEqual(@as(u64, 1), stats.getChannelNotFound());
    try std.testing.expectEqual(@as(u64, 0), main_tg.sent_count.load(.monotonic));
}

test "dispatcher increments channel_not_found for unknown channel" {
    const allocator = std.testing.allocator;

    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    // Empty registry — no channels registered

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    const msg = try bus.makeOutbound(allocator, "nonexistent", "chat1", "hi");
    try event_bus.publishOutbound(msg);
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 0), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 1), stats.getChannelNotFound());
}

test "dispatcher increments errors on channel.send failure" {
    const allocator = std.testing.allocator;

    var mock_fail = MockChannel{ .name_str = "failing", .should_fail = true };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_fail.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    const msg = try bus.makeOutbound(allocator, "failing", "c1", "boom");
    try event_bus.publishOutbound(msg);
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 0), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 1), stats.getErrors());
    try std.testing.expectEqual(@as(u64, 0), stats.getChannelNotFound());
}

test "dispatcher handles multiple messages" {
    const allocator = std.testing.allocator;

    var mock_tg = MockChannel{ .name_str = "telegram" };
    var mock_dc = MockChannel{ .name_str = "discord" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_tg.channel());
    try reg.register(mock_dc.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    // 3 to telegram, 2 to discord
    for (0..3) |_| {
        const msg = try bus.makeOutbound(allocator, "telegram", "c1", "msg");
        try event_bus.publishOutbound(msg);
    }
    for (0..2) |_| {
        const msg = try bus.makeOutbound(allocator, "discord", "c2", "msg");
        try event_bus.publishOutbound(msg);
    }
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 5), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 3), mock_tg.sent_count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), mock_dc.sent_count.load(.monotonic));
}

test "dispatcher mixed: found, not_found, error" {
    const allocator = std.testing.allocator;

    var mock_ok = MockChannel{ .name_str = "telegram" };
    var mock_fail = MockChannel{ .name_str = "broken", .should_fail = true };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_ok.channel());
    try reg.register(mock_fail.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    // 1 ok, 1 error, 1 not found
    const m1 = try bus.makeOutbound(allocator, "telegram", "c1", "ok");
    try event_bus.publishOutbound(m1);
    const m2 = try bus.makeOutbound(allocator, "broken", "c2", "fail");
    try event_bus.publishOutbound(m2);
    const m3 = try bus.makeOutbound(allocator, "ghost", "c3", "where");
    try event_bus.publishOutbound(m3);
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 1), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 1), stats.getErrors());
    try std.testing.expectEqual(@as(u64, 1), stats.getChannelNotFound());
}

test "dispatcher publishes proactive sent outcome" {
    const allocator = std.testing.allocator;

    var mock_tg = MockChannel{ .name_str = "telegram" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_tg.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};
    const thread = try std.Thread.spawn(.{ .stack_size = TEST_THREAD_STACK_SIZE }, runOutboundDispatcher, .{
        allocator, &event_bus, &reg, &stats,
    });

    const msg = try bus.makeOutboundAnnotated(
        allocator,
        "telegram",
        "dispatch-outcome-chat-sent",
        "hello",
        "heartbeat",
        "dispatch-outcome-user-sent",
        "dispatch-outcome-key-sent",
    );
    try event_bus.publishOutbound(msg);
    const sent_ready = struct {
        var bus_ptr: *bus.Bus = undefined;
        fn check() bool {
            return bus_ptr.deliveryOutcomeLen() >= 1;
        }
    };
    sent_ready.bus_ptr = &event_bus;
    _ = waitUntil(sent_ready.check, 200);

    var outcome = event_bus.consumeDeliveryOutcome() orelse return error.TestUnexpectedResult;
    defer outcome.deinit(allocator);
    try std.testing.expectEqualStrings("sent", outcome.action);
    try std.testing.expectEqualStrings("sent", outcome.reason);
    try std.testing.expectEqualStrings("heartbeat", outcome.source.?);

    event_bus.close();
    thread.join();
}

test "dispatcher publishes proactive blocked_dedupe outcome" {
    const allocator = std.testing.allocator;

    var mock_tg = MockChannel{ .name_str = "telegram" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_tg.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};
    const thread = try std.Thread.spawn(.{ .stack_size = TEST_THREAD_STACK_SIZE }, runOutboundDispatcher, .{
        allocator, &event_bus, &reg, &stats,
    });

    const first = try bus.makeOutboundAnnotated(
        allocator,
        "telegram",
        "dispatch-outcome-chat-dedupe",
        "duplicate payload",
        "heartbeat",
        "dispatch-outcome-user-dedupe",
        "dispatch-outcome-key-dedupe",
    );
    try event_bus.publishOutbound(first);

    const second = try bus.makeOutboundAnnotated(
        allocator,
        "telegram",
        "dispatch-outcome-chat-dedupe",
        "duplicate payload",
        "heartbeat",
        "dispatch-outcome-user-dedupe",
        "dispatch-outcome-key-dedupe",
    );
    try event_bus.publishOutbound(second);
    const dedupe_ready = struct {
        var bus_ptr: *bus.Bus = undefined;
        fn check() bool {
            return bus_ptr.deliveryOutcomeLen() >= 2;
        }
    };
    dedupe_ready.bus_ptr = &event_bus;
    _ = waitUntil(dedupe_ready.check, 200);

    var found_blocked_dedupe = false;
    while (event_bus.deliveryOutcomeLen() > 0) {
        var outcome = event_bus.consumeDeliveryOutcome() orelse break;
        defer outcome.deinit(allocator);
        if (std.mem.eql(u8, outcome.action, "blocked_dedupe")) found_blocked_dedupe = true;
    }
    try std.testing.expect(found_blocked_dedupe);

    event_bus.close();
    thread.join();
}

test "dispatcher publishes proactive send_error and channel_not_found outcomes" {
    const allocator = std.testing.allocator;

    var mock_fail = MockChannel{ .name_str = "failing", .should_fail = true };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_fail.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};
    const thread = try std.Thread.spawn(.{ .stack_size = TEST_THREAD_STACK_SIZE }, runOutboundDispatcher, .{
        allocator, &event_bus, &reg, &stats,
    });

    const failing = try bus.makeOutboundAnnotated(
        allocator,
        "failing",
        "dispatch-outcome-chat-error",
        "boom",
        "heartbeat",
        "dispatch-outcome-user-error",
        "dispatch-outcome-key-error",
    );
    try event_bus.publishOutbound(failing);

    const not_found = try bus.makeOutboundAnnotated(
        allocator,
        "missing-channel",
        "dispatch-outcome-chat-missing",
        "hi",
        "heartbeat",
        "dispatch-outcome-user-missing",
        "dispatch-outcome-key-missing",
    );
    try event_bus.publishOutbound(not_found);
    const terminal_ready = struct {
        var bus_ptr: *bus.Bus = undefined;
        fn check() bool {
            return bus_ptr.deliveryOutcomeLen() >= 2;
        }
    };
    terminal_ready.bus_ptr = &event_bus;
    _ = waitUntil(terminal_ready.check, 200);

    var found_send_error = false;
    var found_channel_not_found = false;
    while (event_bus.deliveryOutcomeLen() > 0) {
        var outcome = event_bus.consumeDeliveryOutcome() orelse break;
        defer outcome.deinit(allocator);
        if (std.mem.eql(u8, outcome.action, "send_error")) found_send_error = true;
        if (std.mem.eql(u8, outcome.action, "channel_not_found")) found_channel_not_found = true;
    }
    try std.testing.expect(found_send_error);
    try std.testing.expect(found_channel_not_found);

    event_bus.close();
    thread.join();
}

test "dispatcher suppresses non-heartbeat delivery outcomes during beta containment" {
    const allocator = std.testing.allocator;

    var mock_tg = MockChannel{ .name_str = "telegram" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_tg.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};
    const thread = try std.Thread.spawn(.{ .stack_size = TEST_THREAD_STACK_SIZE }, runOutboundDispatcher, .{
        allocator, &event_bus, &reg, &stats,
    });

    const msg = try bus.makeOutboundAnnotated(
        allocator,
        "telegram",
        "dispatch-outcome-chat-cron",
        "hello from cron",
        "cron",
        "dispatch-outcome-user-cron",
        "dispatch-outcome-key-cron",
    );
    try event_bus.publishOutbound(msg);

    const sent_ready = struct {
        var stats_ptr: *DispatchStats = undefined;
        fn check() bool {
            return stats_ptr.getDispatched() >= 1;
        }
    };
    sent_ready.stats_ptr = &stats;
    _ = waitUntil(sent_ready.check, 200);

    try std.testing.expectEqual(@as(usize, 0), event_bus.deliveryOutcomeLen());

    event_bus.close();
    thread.join();
}

test "dispatcher empty bus returns immediately" {
    const allocator = std.testing.allocator;

    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};
    event_bus.close();

    runOutboundDispatcher(allocator, &event_bus, &reg, &stats);

    try std.testing.expectEqual(@as(u64, 0), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 0), stats.getErrors());
    try std.testing.expectEqual(@as(u64, 0), stats.getChannelNotFound());
}

test "dispatcher runs in a separate thread" {
    const allocator = std.testing.allocator;

    var mock_tg = MockChannel{ .name_str = "telegram" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_tg.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    // Spawn dispatcher thread
    const thread = try std.Thread.spawn(.{ .stack_size = TEST_THREAD_STACK_SIZE }, runOutboundDispatcher, .{
        allocator, &event_bus, &reg, &stats,
    });

    // Publish from main thread
    const msg = try bus.makeOutbound(allocator, "telegram", "c1", "threaded");
    try event_bus.publishOutbound(msg);

    // Small delay then close bus to let dispatcher process
    std.Thread.sleep(10 * std.time.ns_per_ms);
    event_bus.close();
    thread.join();

    try std.testing.expectEqual(@as(u64, 1), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, 1), mock_tg.sent_count.load(.monotonic));
}

test "dispatcher concurrent producers + single dispatcher" {
    const allocator = std.testing.allocator;

    var mock_ch = MockChannel{ .name_str = "test" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock_ch.channel());

    var event_bus = bus.Bus.init();
    var stats = DispatchStats{};

    const num_producers = 4;
    const msgs_per_producer = 25;
    const total = num_producers * msgs_per_producer;

    // Spawn dispatcher
    const dispatcher = try std.Thread.spawn(.{ .stack_size = TEST_THREAD_STACK_SIZE }, runOutboundDispatcher, .{
        allocator, &event_bus, &reg, &stats,
    });

    // Spawn producers
    var producers: [num_producers]std.Thread = undefined;
    for (0..num_producers) |i| {
        producers[i] = try std.Thread.spawn(.{ .stack_size = TEST_THREAD_STACK_SIZE }, struct {
            fn run(b: *bus.Bus, a: Allocator) void {
                for (0..msgs_per_producer) |_| {
                    const m = bus.makeOutbound(a, "test", "c", "x") catch return;
                    b.publishOutbound(m) catch return;
                }
            }
        }.run, .{ &event_bus, allocator });
    }

    // Wait for all producers, then close bus
    for (&producers) |*p| p.join();
    // Small delay for dispatcher to drain
    std.Thread.sleep(20 * std.time.ns_per_ms);
    event_bus.close();
    dispatcher.join();

    try std.testing.expectEqual(@as(u64, total), stats.getDispatched());
    try std.testing.expectEqual(@as(u64, total), mock_ch.sent_count.load(.monotonic));
}

test "getEnabledChannelNames returns registered names" {
    const allocator = std.testing.allocator;

    var mock1 = MockChannel{ .name_str = "telegram" };
    var mock2 = MockChannel{ .name_str = "discord" };
    var reg = ChannelRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(mock1.channel());
    try reg.register(mock2.channel());

    const names = try getEnabledChannelNames(&reg, allocator);
    defer allocator.free(names);

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("telegram", names[0]);
    try std.testing.expectEqualStrings("discord", names[1]);
}

// ════════════════════════════════════════════════════════════════════════════
// Channel Supervisor Tests
// ════════════════════════════════════════════════════════════════════════════

test "supervised channel initial state" {
    var mock = MockChannel{ .name_str = "test" };
    const sc = spawnSupervisedChannel(mock.channel(), 5);
    try std.testing.expectEqual(SupervisedChannel.State.idle, sc.state);
    try std.testing.expectEqual(@as(u32, 0), sc.restart_count);
    try std.testing.expectEqual(@as(u64, 1000), sc.currentBackoffMs());
    try std.testing.expectEqual(@as(u32, 5), sc.max_restarts);
    try std.testing.expect(!sc.shouldRestart());
}

test "supervised channel recordFailure increments and sets restarting" {
    var mock = MockChannel{ .name_str = "test" };
    var sc = spawnSupervisedChannel(mock.channel(), 5);

    sc.recordFailure();
    try std.testing.expectEqual(@as(u32, 1), sc.restart_count);
    try std.testing.expectEqual(SupervisedChannel.State.restarting, sc.state);
    try std.testing.expect(sc.shouldRestart());

    sc.recordFailure();
    try std.testing.expectEqual(@as(u32, 2), sc.restart_count);
    try std.testing.expectEqual(SupervisedChannel.State.restarting, sc.state);
    // Backoff should have doubled
    try std.testing.expect(sc.currentBackoffMs() > 1000);
}

test "supervised channel backoff capped at max_backoff_ms" {
    var mock = MockChannel{ .name_str = "test" };
    var sc = spawnSupervisedChannel(mock.channel(), 100);
    // Override to make the cap easy to test
    sc.max_backoff_ms = 5000;

    // Record many failures to push backoff beyond the cap
    for (0..20) |_| {
        sc.recordFailure();
    }
    try std.testing.expect(sc.currentBackoffMs() <= 5000);
}

test "supervised channel gave_up after max_restarts" {
    var mock = MockChannel{ .name_str = "test" };
    var sc = spawnSupervisedChannel(mock.channel(), 3);

    sc.recordFailure(); // 1 — restarting
    sc.recordFailure(); // 2 — restarting
    sc.recordFailure(); // 3 — gave_up (restart_count == max_restarts)

    try std.testing.expectEqual(SupervisedChannel.State.gave_up, sc.state);
    try std.testing.expect(!sc.shouldRestart());
    try std.testing.expectEqual(@as(u32, 3), sc.restart_count);
}

test "supervised channel recordSuccess resets state" {
    var mock = MockChannel{ .name_str = "test" };
    var sc = spawnSupervisedChannel(mock.channel(), 5);

    // Fail a couple of times
    sc.recordFailure();
    sc.recordFailure();
    try std.testing.expectEqual(@as(u32, 2), sc.restart_count);
    try std.testing.expect(sc.currentBackoffMs() > 1000);

    // Successful recovery
    sc.recordSuccess();
    try std.testing.expectEqual(SupervisedChannel.State.running, sc.state);
    try std.testing.expectEqual(@as(u32, 0), sc.restart_count);
    try std.testing.expectEqual(@as(u64, 1000), sc.currentBackoffMs());
}

test "startAllSupervised wraps channel array" {
    const allocator = std.testing.allocator;

    var mock1 = MockChannel{ .name_str = "telegram" };
    var mock2 = MockChannel{ .name_str = "discord" };
    const channels = [_]root.Channel{ mock1.channel(), mock2.channel() };

    const supervised = try startAllSupervised(allocator, &channels);
    defer allocator.free(supervised);

    try std.testing.expectEqual(@as(usize, 2), supervised.len);
    try std.testing.expectEqual(SupervisedChannel.State.idle, supervised[0].state);
    try std.testing.expectEqual(SupervisedChannel.State.idle, supervised[1].state);
    try std.testing.expectEqualStrings("telegram", supervised[0].channel.name());
    try std.testing.expectEqualStrings("discord", supervised[1].channel.name());
}
