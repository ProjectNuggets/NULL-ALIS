//! Message Tool — proactive channel routing.
//!
//! Allows the agent to send messages to any channel, not just reply
//! to the current one. Used for cross-channel routing, cron delivery,
//! subagent announcements.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const bus = @import("../bus.zig");
const json_util = @import("../json_util.zig");
const http_util = @import("../http_util.zig");
const runtime_resolver = @import("../delivery/runtime_resolver.zig");
const ops_guard = @import("../ops_guard.zig");

/// Message tool — sends a message to a specific channel/chat via the bus.
pub const MessageTool = struct {
    event_bus: ?*bus.Bus = null,
    outbound_allocator: ?std.mem.Allocator = null,

    pub const tool_name = "message";
    pub const tool_description = "Send a message to a channel. If channel/chat_id are omitted, sends to the current conversation. When a channel has multiple configured accounts, account_id defaults to the current account.";
    pub const tool_params =
        \\{"type":"object","properties":{"content":{"type":"string","minLength":1,"description":"Message text to send"},"channel":{"type":"string","description":"Target channel (telegram, discord, slack, etc.). Defaults to current."},"account_id":{"type":"string","description":"Target account for multi-account channels. Defaults to current account."},"chat_id":{"type":"string","description":"Target chat/room ID. Defaults to current."}},"required":["content"]}
    ;

    const vtable = root.ToolVTable(@This());

    pub fn tool(self: *MessageTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub const TurnContext = struct {
        channel: ?[]const u8 = null,
        account_id: ?[]const u8 = null,
        chat_id: ?[]const u8 = null,
        is_group: ?bool = null,
        is_dm: ?bool = null,
        mentioned: ?bool = null,
    };

    threadlocal var current_turn_context: TurnContext = .{};
    threadlocal var sent_in_round: bool = false;

    /// Set the context for the current turn (called before agent.turn).
    pub fn setContext(_: *MessageTool, channel: ?[]const u8, chat_id: ?[]const u8) void {
        setTurnContext(.{
            .channel = channel,
            .chat_id = chat_id,
        });
    }

    pub fn setTurnContext(ctx: TurnContext) void {
        current_turn_context = ctx;
        sent_in_round = false;
    }

    pub fn clearTurnContext() void {
        current_turn_context = .{};
        sent_in_round = false;
    }

    pub fn getTurnContext() TurnContext {
        return current_turn_context;
    }

    /// Check if a message was sent during this round.
    pub fn hasMessageBeenSent(_: *const MessageTool) bool {
        return sent_in_round;
    }

    pub fn execute(self: *MessageTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const content = root.getString(args, "content") orelse
            return ToolResult.fail("Missing required 'content' parameter");

        if (std.mem.trim(u8, content, " \t\n\r").len == 0)
            return ToolResult.fail("'content' must not be empty");

        const msg_turn_ctx = current_turn_context;
        const runtime_turn_ctx = root.getTurnContext();
        const is_background_origin = root.isBackgroundTurnOrigin(runtime_turn_ctx.origin);

        const channel_raw = root.getString(args, "channel") orelse
            (msg_turn_ctx.channel orelse
                return ToolResult.fail("No channel specified and no default channel set"));
        const channel = std.mem.trim(u8, channel_raw, " \t\r\n");
        if (channel.len == 0) return ToolResult.fail("Channel must not be empty");
        const is_telegram_channel = std.ascii.eqlIgnoreCase(channel, "telegram");

        var account_id = root.getString(args, "account_id") orelse msg_turn_ctx.account_id;

        var chat_id_opt = root.getString(args, "chat_id") orelse msg_turn_ctx.chat_id;
        var resolved_telegram: ?runtime_resolver.DeliveryResolvedContext = null;
        defer if (resolved_telegram) |*ctx| ctx.deinit(allocator);
        const tenant_ctx = root.getTenantContext();
        const can_direct_telegram = tenant_ctx.state_mgr != null and tenant_ctx.numeric_user_id != null;

        if (is_telegram_channel and (is_background_origin or can_direct_telegram)) {
            if (tenant_ctx.expect_postgres_state and (tenant_ctx.state_mgr == null or tenant_ctx.numeric_user_id == null)) {
                return ToolResult.fail("Telegram context is incomplete for background send");
            }

            resolved_telegram = runtime_resolver.resolveRuntimeDeliveryContext(allocator, .{
                .channel = "telegram",
                .tenant_ctx = .{
                    .state_mgr = tenant_ctx.state_mgr,
                    .numeric_user_id = tenant_ctx.numeric_user_id,
                    .expect_postgres_state = tenant_ctx.expect_postgres_state,
                },
                .target_hint = chat_id_opt,
            }) catch blk: {
                if (is_background_origin) {
                    return ToolResult.fail("Failed to resolve Telegram runtime context");
                }
                break :blk null;
            };

            if (resolved_telegram != null) {
                runtime_resolver.requireConnectedTarget(&resolved_telegram.?) catch
                    return ToolResult.fail("Telegram chat is not connected");
                if (chat_id_opt == null) chat_id_opt = resolved_telegram.?.target_id;
                if (account_id == null) account_id = resolved_telegram.?.account_id;
            }
        }

        // Prefer direct Telegram delivery when tenant state is available.
        // This provides immediate success/failure instead of "queued" semantics,
        // and avoids account mismatch drops in the async dispatcher path.
        if (is_telegram_channel and can_direct_telegram) {
            return send_telegram_direct(allocator, content, account_id, chat_id_opt, is_background_origin);
        }
        if (self.event_bus == null and is_telegram_channel) {
            return send_telegram_direct(allocator, content, account_id, chat_id_opt, is_background_origin);
        }

        const chat_id = chat_id_opt orelse
            return ToolResult.fail("No chat_id specified and no default chat_id set");

        const event_bus = self.event_bus orelse
            return ToolResult.fail("Message tool not connected to event bus");

        const outbound_allocator = self.outbound_allocator orelse allocator;
        var user_id_buf: [32]u8 = undefined;
        const user_id_opt: ?[]const u8 = if (tenant_ctx.numeric_user_id) |user_id|
            std.fmt.bufPrint(&user_id_buf, "{d}", .{user_id}) catch null
        else
            null;

        const msg = (if (account_id) |aid|
            bus.makeOutboundWithAccountAnnotated(
                outbound_allocator,
                channel,
                aid,
                chat_id,
                content,
                "tool",
                user_id_opt,
                null,
            )
        else
            bus.makeOutboundAnnotated(
                outbound_allocator,
                channel,
                chat_id,
                content,
                "tool",
                user_id_opt,
                null,
            )) catch
            return ToolResult.fail("Failed to create outbound message");

        event_bus.publishOutbound(msg) catch {
            msg.deinit(outbound_allocator);
            return ToolResult.fail("Bus is closed, cannot send message");
        };

        sent_in_round = true;

        const result = blk: {
            if (account_id) |aid| {
                break :blk std.fmt.allocPrint(
                    allocator,
                    "Message queued to {s}:{s}:{s} ({d} chars, async delivery not confirmed)",
                    .{ channel, aid, chat_id, content.len },
                ) catch return ToolResult.ok("Message queued");
            }
            break :blk std.fmt.allocPrint(
                allocator,
                "Message queued to {s}:{s} ({d} chars, async delivery not confirmed)",
                .{ channel, chat_id, content.len },
            ) catch return ToolResult.ok("Message queued");
        };

        return ToolResult.ok(result);
    }

    fn send_telegram_direct(
        allocator: std.mem.Allocator,
        content: []const u8,
        requested_account_id: ?[]const u8,
        requested_chat_id: ?[]const u8,
        is_background_origin: bool,
    ) ToolResult {
        const tenant_ctx = root.getTenantContext();
        const state_mgr = tenant_ctx.state_mgr orelse
            return ToolResult.fail("Telegram direct send unavailable: no tenant state");
        const user_id = tenant_ctx.numeric_user_id orelse
            return ToolResult.fail("Telegram direct send unavailable: no tenant user");

        var resolved = runtime_resolver.resolveRuntimeDeliveryContext(allocator, .{
            .channel = "telegram",
            .tenant_ctx = .{
                .state_mgr = state_mgr,
                .numeric_user_id = user_id,
                .expect_postgres_state = tenant_ctx.expect_postgres_state,
            },
            .account_id_hint = requested_account_id,
            .target_hint = requested_chat_id,
        }) catch return ToolResult.fail("Failed to resolve Telegram runtime context");
        defer resolved.deinit(allocator);

        runtime_resolver.requireConnectedTarget(&resolved) catch
            return ToolResult.fail("Telegram chat is not connected");
        const token = runtime_resolver.requireCredential(&resolved) catch
            return ToolResult.fail("Telegram bot token is not configured");
        const resolved_chat_id = resolved.target_id orelse
            return ToolResult.fail("Telegram chat is not connected");

        var user_id_buf: [32]u8 = undefined;
        const proactive_user_id = resolveProactiveUserId(tenant_ctx, &user_id_buf);
        if (is_background_origin) {
            if (backgroundTelegramBlockReason(proactive_user_id, resolved_chat_id, content, std.time.timestamp())) |reason| {
                return ToolResult.fail(reason);
            }
        }

        const url = std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{token}) catch
            return ToolResult.fail("Failed to build Telegram API URL");
        defer allocator.free(url);

        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);
        body.appendSlice(allocator, "{") catch return ToolResult.fail("Failed to allocate Telegram request");
        json_util.appendJsonKeyValue(&body, allocator, "chat_id", resolved_chat_id) catch
            return ToolResult.fail("Failed to encode Telegram chat_id");
        body.appendSlice(allocator, ",") catch return ToolResult.fail("Failed to encode Telegram request");
        json_util.appendJsonKeyValue(&body, allocator, "text", content) catch
            return ToolResult.fail("Failed to encode Telegram text");
        body.appendSlice(allocator, "}") catch return ToolResult.fail("Failed to finalize Telegram request");

        const response = http_util.request_with_mode(allocator, .{ .mode = .curl_only }, .{
            .subsystem = .channels,
            .method = "POST",
            .url = url,
            .headers = &.{"Content-Type: application/json"},
            .body = body.items,
            .timeout_ms = 30_000,
            .max_response_bytes = 256 * 1024,
        }) catch |err| {
            if (is_background_origin) {
                ops_guard.recordProactiveSendError("tool", proactive_user_id, "telegram", resolved_chat_id, @errorName(err), std.time.timestamp());
            }
            return ToolResult.fail("Telegram send failed");
        };
        defer allocator.free(response.body);

        if (response.status_code < 200 or response.status_code >= 300) {
            if (is_background_origin) {
                ops_guard.recordProactiveSendError("tool", proactive_user_id, "telegram", resolved_chat_id, "http_status", std.time.timestamp());
            }
            return ToolResult.fail("Telegram send failed");
        }
        if (is_background_origin) {
            ops_guard.recordProactiveSent("tool", proactive_user_id, "telegram", resolved_chat_id, std.time.timestamp());
        }

        if (std.fmt.allocPrint(
            allocator,
            "Message delivered to telegram:{s} ({d} chars)",
            .{
                resolved_chat_id,
                content.len,
            },
        )) |msg| {
            return ToolResult.ok(msg);
        } else |_| {
            return ToolResult.ok("Message delivered to telegram");
        }
    }

    fn resolveProactiveUserId(tenant_ctx: root.ToolTenantContext, user_id_buf: *[32]u8) ?[]const u8 {
        if (tenant_ctx.numeric_user_id) |numeric_user_id| {
            return std.fmt.bufPrint(user_id_buf, "{d}", .{numeric_user_id}) catch tenant_ctx.user_id;
        }
        return tenant_ctx.user_id;
    }

    fn backgroundTelegramBlockReason(
        user_id_opt: ?[]const u8,
        chat_id: []const u8,
        content: []const u8,
        now_s: i64,
    ) ?[]const u8 {
        return switch (ops_guard.allowProactive("tool", user_id_opt, "telegram", chat_id, content, null, now_s)) {
            .allow => null,
            .blocked_rate => "Telegram send blocked by background rate guard",
            .blocked_dedupe => "Telegram send blocked by background dedupe guard",
        };
    }
};

// ══════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════

const testing = std.testing;

fn resetTestTurnContext() void {
    MessageTool.clearTurnContext();
}

test "MessageTool name and description" {
    resetTestTurnContext();
    var mt = MessageTool{};
    const t = mt.tool();
    try testing.expectEqualStrings("message", t.name());
    try testing.expect(t.description().len > 0);
    try testing.expect(t.parametersJson()[0] == '{');
}

test "MessageTool execute without bus fails" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    var mt = MessageTool{};
    const parsed = try root.parseTestArgs("{\"content\":\"hello\",\"channel\":\"tg\",\"chat_id\":\"c1\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Message tool not connected to event bus", result.error_msg.?);
}

test "MessageTool execute without content fails" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    defer event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    const parsed = try root.parseTestArgs("{\"channel\":\"tg\",\"chat_id\":\"c1\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Missing required 'content' parameter", result.error_msg.?);
}

test "MessageTool execute with empty content fails" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    defer event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    const parsed = try root.parseTestArgs("{\"content\":\"  \",\"channel\":\"tg\",\"chat_id\":\"c1\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("'content' must not be empty", result.error_msg.?);
}

test "MessageTool execute without channel uses default" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    defer event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    mt.setContext("telegram", "chat42");
    const parsed = try root.parseTestArgs("{\"content\":\"hello\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "telegram") != null);
    // Free the allocated output
    testing.allocator.free(result.output);

    // Consume and free the bus message
    var msg = event_bus.consumeOutbound().?;
    msg.deinit(testing.allocator);
}

test "MessageTool execute with explicit channel overrides default" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    defer event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    mt.setContext("telegram", "chat42");
    const parsed = try root.parseTestArgs("{\"content\":\"hi\",\"channel\":\"discord\",\"chat_id\":\"room1\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "discord") != null);
    testing.allocator.free(result.output);

    var msg = event_bus.consumeOutbound().?;
    defer msg.deinit(testing.allocator);
    try testing.expectEqualStrings("discord", msg.channel);
    try testing.expectEqualStrings("room1", msg.chat_id);
    try testing.expectEqualStrings("hi", msg.content);
}

test "MessageTool setContext and hasMessageBeenSent" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    var mt = MessageTool{};
    try testing.expect(!mt.hasMessageBeenSent());

    mt.setContext("telegram", "c1");
    try testing.expect(!mt.hasMessageBeenSent());
}

test "MessageTool sent_in_round is set after successful send" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    defer event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    mt.setContext("tg", "c1");

    try testing.expect(!mt.hasMessageBeenSent());
    const parsed = try root.parseTestArgs("{\"content\":\"ping\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(result.success);
    testing.allocator.free(result.output);
    try testing.expect(mt.hasMessageBeenSent());

    // Reset on setContext
    mt.setContext("discord", "c2");
    try testing.expect(!mt.hasMessageBeenSent());

    // Consume bus message
    var msg = event_bus.consumeOutbound().?;
    msg.deinit(testing.allocator);
}

test "MessageTool no channel and no default fails" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    defer event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    const parsed = try root.parseTestArgs("{\"content\":\"hello\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("No channel specified and no default channel set", result.error_msg.?);
}

test "MessageTool closed bus fails gracefully" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    mt.setContext("tg", "c1");
    const parsed = try root.parseTestArgs("{\"content\":\"hello\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Bus is closed, cannot send message", result.error_msg.?);
}

test "MessageTool execute with default account routes through account-aware outbound bus" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    defer event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    MessageTool.setTurnContext(.{
        .channel = "telegram",
        .account_id = "personal",
        .chat_id = "42",
    });

    const parsed = try root.parseTestArgs("{\"content\":\"hello\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(result.success);
    testing.allocator.free(result.output);

    const outbound = event_bus.consumeOutbound() orelse return error.TestUnexpectedResult;
    defer outbound.deinit(testing.allocator);
    try testing.expectEqualStrings("telegram", outbound.channel);
    try testing.expectEqualStrings("personal", outbound.account_id.?);
    try testing.expectEqualStrings("42", outbound.chat_id);
}

test "MessageTool bus payload survives request allocator lifetime" {
    resetTestTurnContext();
    defer resetTestTurnContext();

    var event_bus = bus.Bus.init();
    defer event_bus.close();

    var mt = MessageTool{
        .event_bus = &event_bus,
        .outbound_allocator = testing.allocator,
    };

    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const parsed = try std.json.parseFromSlice(root.JsonValue, arena, "{\"content\":\"hello\",\"channel\":\"telegram\",\"chat_id\":\"42\"}", .{});
    const result = try mt.execute(arena, parsed.value.object);
    try testing.expect(result.success);

    var outbound = event_bus.consumeOutbound() orelse return error.TestUnexpectedResult;
    defer outbound.deinit(testing.allocator);
    try testing.expectEqualStrings("42", outbound.chat_id);
    try testing.expectEqualStrings("hello", outbound.content);
}

test "MessageTool background telegram without connected target fails explicitly" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    root.setTurnContext(.{ .origin = .heartbeat });
    defer root.clearTurnContext();

    var event_bus = bus.Bus.init();
    defer event_bus.close();

    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    MessageTool.setTurnContext(.{
        .channel = "telegram",
        .chat_id = null,
    });

    const parsed = try root.parseTestArgs("{\"content\":\"hello\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expect(std.mem.indexOf(u8, result.error_msg.?, "Telegram chat is not connected") != null);
}

test "MessageTool background proactive guard blocks duplicate direct sends" {
    const now_s = std.time.timestamp();
    const block_first = MessageTool.backgroundTelegramBlockReason("msg-tool-guard-user", "msg-tool-guard-chat", "hello guard", now_s);
    try testing.expect(block_first == null);

    const block_second = MessageTool.backgroundTelegramBlockReason("msg-tool-guard-user", "msg-tool-guard-chat", "hello guard", now_s + 1) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Telegram send blocked by background dedupe guard", block_second);
}

test "MessageTool background telegram rejects invalid explicit chat_id" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    root.setTurnContext(.{ .origin = .scheduler });
    defer root.clearTurnContext();

    var event_bus = bus.Bus.init();
    defer event_bus.close();

    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    MessageTool.setTurnContext(.{
        .channel = "telegram",
    });

    const parsed = try root.parseTestArgs("{\"content\":\"hello\",\"chat_id\":\"not-a-number\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Failed to resolve Telegram runtime context", result.error_msg.?);
}
