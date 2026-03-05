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

        const turn_ctx = current_turn_context;

        const channel = root.getString(args, "channel") orelse
            (turn_ctx.channel orelse
                return ToolResult.fail("No channel specified and no default channel set"));

        const account_id = root.getString(args, "account_id") orelse turn_ctx.account_id;

        const chat_id_opt = root.getString(args, "chat_id") orelse turn_ctx.chat_id;

        if (self.event_bus == null and std.mem.eql(u8, channel, "telegram")) {
            return send_telegram_direct(allocator, content, account_id, chat_id_opt);
        }

        const chat_id = chat_id_opt orelse
            return ToolResult.fail("No chat_id specified and no default chat_id set");

        const event_bus = self.event_bus orelse
            return ToolResult.fail("Message tool not connected to event bus");

        const outbound_allocator = self.outbound_allocator orelse allocator;
        const tenant_ctx = root.getTenantContext();
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
                    "Message sent to {s}:{s}:{s} ({d} chars)",
                    .{ channel, aid, chat_id, content.len },
                ) catch return ToolResult.ok("Message sent");
            }
            break :blk std.fmt.allocPrint(
                allocator,
                "Message sent to {s}:{s} ({d} chars)",
                .{ channel, chat_id, content.len },
            ) catch return ToolResult.ok("Message sent");
        };

        return ToolResult.ok(result);
    }

    fn send_telegram_direct(
        allocator: std.mem.Allocator,
        content: []const u8,
        _: ?[]const u8,
        requested_chat_id: ?[]const u8,
    ) ToolResult {
        const tenant_ctx = root.getTenantContext();
        const state_mgr = tenant_ctx.state_mgr orelse
            return ToolResult.fail("Telegram direct send unavailable: no tenant state");
        const user_id = tenant_ctx.numeric_user_id orelse
            return ToolResult.fail("Telegram direct send unavailable: no tenant user");

        const bot_token = state_mgr.getSecret(allocator, user_id, "telegram_bot_token") catch
            return ToolResult.fail("Failed to load Telegram bot token");
        defer if (bot_token) |tok| allocator.free(tok);
        const token = bot_token orelse
            return ToolResult.fail("Telegram bot token is not configured");

        const resolved_chat_id = if (requested_chat_id) |chat_id| blk: {
            break :blk allocator.dupe(u8, chat_id) catch
                return ToolResult.fail("Failed to allocate chat id");
        } else resolve_telegram_chat_id_from_state(allocator, state_mgr, user_id) catch
            return ToolResult.fail("Failed to resolve Telegram chat_id from state");
        defer allocator.free(resolved_chat_id);

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
        }) catch return ToolResult.fail("Telegram send failed");
        defer allocator.free(response.body);

        if (response.status_code < 200 or response.status_code >= 300) {
            return ToolResult.fail("Telegram send failed");
        }

        if (std.fmt.allocPrint(
            allocator,
            "Message sent to telegram:{s} ({d} chars)",
            .{
                resolved_chat_id,
                content.len,
            },
        )) |msg| {
            return ToolResult.ok(msg);
        } else |_| {
            return ToolResult.ok("Message sent to telegram");
        }
    }

    fn resolve_telegram_chat_id_from_state(
        allocator: std.mem.Allocator,
        state_mgr: anytype,
        user_id: i64,
    ) ![]u8 {
        const state_json = try state_mgr.getTelegramStateJson(allocator, user_id);
        defer allocator.free(state_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, state_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidTelegramState;
        const obj = parsed.value.object;
        const chat_val = obj.get("chat_id") orelse return error.MissingTelegramChatId;
        return switch (chat_val) {
            .string => allocator.dupe(u8, chat_val.string),
            .integer => std.fmt.allocPrint(allocator, "{d}", .{chat_val.integer}),
            else => error.InvalidTelegramState,
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
