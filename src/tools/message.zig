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
const log = std.log.scoped(.message_tool);

/// Message tool — sends a message to a specific channel/chat via the bus.
pub const MessageTool = struct {
    event_bus: ?*bus.Bus = null,
    outbound_allocator: ?std.mem.Allocator = null,

    pub const tool_name = "message";

    pub const tool_description_struct = @import("metadata.zig").ToolDescription{
        .what = "Send a message to the user or log output to conversation.",
        .use_when = &.{
            "first scenario",
            "second scenario",
        },
        .do_not_use_for = &.{
            "web_search — for web queries",
            "memory_store — for persistence",
        },
    };

    comptime {
        @import("lint.zig").lintToolDescription("message", tool_description_struct, &@import("lint.zig").ALL_TOOLS);
    }
    pub const tool_description = "Send an explicit outbound message to a channel or the current conversation. Optionally attach an image by public HTTPS URL. Do not treat as a heartbeat default.";
    pub const tool_params =
        \\{"type":"object","properties":{"content":{"type":"string","description":"Message text. When image_url is set, this becomes the caption (where the channel supports captions; Telegram caps at 1024 chars). May be empty when image_url is set."},"image_url":{"type":"string","description":"Optional public HTTPS URL of an image to attach. Today: Telegram supports this via sendPhoto (channel fetches the URL server-side). Other channels: not yet wired — prefer [IMAGE:/abs/path] markers in your reply text for those (see Channel Attachments section). For workspace-local files on any channel, use the marker approach."},"channel":{"type":"string","description":"Target channel (telegram, discord, slack, signal, mattermost, whatsapp, etc.). Defaults to current."},"account_id":{"type":"string","description":"Target account for multi-account channels. Defaults to current account."},"chat_id":{"type":"string","description":"Target chat/room ID. Defaults to current."}},"required":["content"]}
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

        // Optional image attachment (Telegram sendPhoto / future channel parity).
        // Only public HTTPS URLs are accepted today — Telegram fetches the URL
        // server-side. Workspace-local file paths require multipart upload
        // which is a follow-up.
        const image_url_raw = root.getString(args, "image_url");
        const image_url: ?[]const u8 = blk: {
            if (image_url_raw) |raw| {
                const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                if (trimmed.len == 0) break :blk null;
                if (!std.mem.startsWith(u8, trimmed, "https://")) {
                    return ToolResult.fail("image_url must be a public HTTPS URL (got non-https)");
                }
                break :blk trimmed;
            }
            break :blk null;
        };

        if (image_url == null and std.mem.trim(u8, content, " \t\n\r").len == 0)
            return ToolResult.fail("'content' must not be empty when image_url is not provided");

        const msg_turn_ctx = current_turn_context;
        const runtime_turn_ctx = root.getTurnContext();
        const is_background_origin = root.isBackgroundTurnOrigin(runtime_turn_ctx.origin);

        const channel_raw = root.getString(args, "channel") orelse
            (msg_turn_ctx.channel orelse
                return ToolResult.fail("No channel specified and no default channel set"));
        const channel = std.mem.trim(u8, channel_raw, " \t\r\n");
        if (channel.len == 0) return ToolResult.fail("Channel must not be empty");

        // S7.8 — channel-locality enforcement. If the tool is running inside
        // a turn whose inbound channel is known AND the model passed an
        // explicit `channel` arg that differs, require an explicit
        // `allow_channel_override=true` opt-in. Prevents the model from
        // silently replying on a random channel because it misread context.
        // Background-origin turns are exempt — they don't have an inbound
        // channel to pin to.
        if (!is_background_origin) {
            if (msg_turn_ctx.channel) |inbound_channel| {
                const explicit_channel_arg = root.getString(args, "channel");
                if (explicit_channel_arg) |explicit| {
                    const explicit_trimmed = std.mem.trim(u8, explicit, " \t\r\n");
                    if (!std.ascii.eqlIgnoreCase(explicit_trimmed, inbound_channel)) {
                        const allow_override = blk: {
                            if (args.get("allow_channel_override")) |v| {
                                if (v == .bool) break :blk v.bool;
                            }
                            break :blk false;
                        };
                        if (!allow_override) {
                            const msg = try std.fmt.allocPrint(
                                allocator,
                                "Channel-locality violation: inbound was '{s}', tool tried to send on '{s}'. Pass allow_channel_override=true to bypass.",
                                .{ inbound_channel, explicit_trimmed },
                            );
                            return ToolResult{ .success = false, .output = "", .error_msg = msg };
                        }
                    }
                }
            }
        }
        const is_telegram_channel = std.ascii.eqlIgnoreCase(channel, "telegram");

        var account_id = root.getString(args, "account_id") orelse msg_turn_ctx.account_id;

        var chat_id_opt = root.getString(args, "chat_id") orelse msg_turn_ctx.chat_id;
        var resolved_telegram: ?runtime_resolver.DeliveryResolvedContext = null;
        defer if (resolved_telegram) |*ctx| ctx.deinit(allocator);
        const tenant_ctx = root.getTenantContext();
        const has_postgres_tenant = tenant_ctx.state_mgr != null and tenant_ctx.numeric_user_id != null;
        const has_file_tenant = tenant_ctx.user_root != null;
        const can_direct_telegram = has_postgres_tenant or has_file_tenant;

        if (is_telegram_channel and (is_background_origin or can_direct_telegram)) {
            if (tenant_ctx.expect_postgres_state and !has_postgres_tenant and !has_file_tenant) {
                return ToolResult.fail("Telegram context is incomplete for background send");
            }

            resolved_telegram = runtime_resolver.resolveRuntimeDeliveryContext(allocator, .{
                .channel = "telegram",
                .tenant_ctx = .{
                    .state_mgr = tenant_ctx.state_mgr,
                    .numeric_user_id = tenant_ctx.numeric_user_id,
                    .expect_postgres_state = tenant_ctx.expect_postgres_state,
                },
                .user_root = tenant_ctx.user_root,
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
        if (is_telegram_channel and can_direct_telegram and !is_background_origin) {
            return send_telegram_direct(allocator, content, account_id, chat_id_opt, image_url);
        }
        // Background turns should primarily use bus dispatch, but allow a direct
        // fallback when bus wiring is unavailable for this runtime lane.
        if (is_telegram_channel and can_direct_telegram and is_background_origin and self.event_bus == null) {
            return send_telegram_direct(allocator, content, account_id, chat_id_opt, image_url);
        }
        if (self.event_bus == null and is_telegram_channel) {
            if (is_background_origin) {
                return ToolResult.fail("Background Telegram send requires event bus dispatch");
            }
            return send_telegram_direct(allocator, content, account_id, chat_id_opt, image_url);
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
        const source_tag: ?[]const u8 = if (is_background_origin) "tool" else null;

        const msg = (if (account_id) |aid|
            bus.makeOutboundWithAccountAnnotated(
                outbound_allocator,
                channel,
                aid,
                chat_id,
                content,
                source_tag,
                user_id_opt,
                null,
            )
        else
            bus.makeOutboundAnnotated(
                outbound_allocator,
                channel,
                chat_id,
                content,
                source_tag,
                user_id_opt,
                null,
            )) catch
            return ToolResult.fail("Failed to create outbound message");

        event_bus.publishOutbound(msg) catch {
            msg.deinit(outbound_allocator);
            if (is_telegram_channel and can_direct_telegram and is_background_origin) {
                return send_telegram_direct(allocator, content, account_id, chat_id_opt, image_url);
            }
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
        image_url: ?[]const u8,
    ) ToolResult {
        const tenant_ctx = root.getTenantContext();
        const has_postgres_tenant = tenant_ctx.state_mgr != null and tenant_ctx.numeric_user_id != null;
        if (!has_postgres_tenant and tenant_ctx.user_root == null) {
            return ToolResult.fail("Telegram direct send unavailable: no tenant state or user_root");
        }

        var resolved = runtime_resolver.resolveRuntimeDeliveryContext(allocator, .{
            .channel = "telegram",
            .tenant_ctx = .{
                .state_mgr = tenant_ctx.state_mgr,
                .numeric_user_id = tenant_ctx.numeric_user_id,
                .expect_postgres_state = tenant_ctx.expect_postgres_state,
            },
            .user_root = tenant_ctx.user_root,
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

        // Branch on whether an image is attached:
        // - sendPhoto with `photo` URL + optional `caption` (Telegram fetches the
        //   URL server-side; caption capped at 1024 chars by Telegram, we
        //   don't pre-truncate and let API surface the error).
        // - sendMessage with `text` for text-only.
        const endpoint = if (image_url != null) "sendPhoto" else "sendMessage";
        const url = std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/bot{s}/{s}",
            .{ token, endpoint },
        ) catch return ToolResult.fail("Failed to build Telegram API URL");
        defer allocator.free(url);

        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);
        body.appendSlice(allocator, "{") catch return ToolResult.fail("Failed to allocate Telegram request");
        json_util.appendJsonKeyValue(&body, allocator, "chat_id", resolved_chat_id) catch
            return ToolResult.fail("Failed to encode Telegram chat_id");

        if (image_url) |img| {
            body.appendSlice(allocator, ",") catch return ToolResult.fail("Failed to encode Telegram request");
            json_util.appendJsonKeyValue(&body, allocator, "photo", img) catch
                return ToolResult.fail("Failed to encode Telegram photo URL");
            // Caption only when content is non-empty. Telegram tolerates omitted
            // caption fine; an empty-string caption is also harmless but cleaner
            // to omit.
            if (std.mem.trim(u8, content, " \t\n\r").len > 0) {
                body.appendSlice(allocator, ",") catch return ToolResult.fail("Failed to encode Telegram request");
                json_util.appendJsonKeyValue(&body, allocator, "caption", content) catch
                    return ToolResult.fail("Failed to encode Telegram caption");
            }
        } else {
            body.appendSlice(allocator, ",") catch return ToolResult.fail("Failed to encode Telegram request");
            json_util.appendJsonKeyValue(&body, allocator, "text", content) catch
                return ToolResult.fail("Failed to encode Telegram text");
        }
        body.appendSlice(allocator, "}") catch return ToolResult.fail("Failed to finalize Telegram request");

        const response = http_util.request_with_mode(allocator, .{ .mode = .curl_only }, .{
            .subsystem = .channels,
            .method = "POST",
            .url = url,
            .headers = &.{"Content-Type: application/json"},
            .body = body.items,
            .timeout_ms = 30_000,
            .max_response_bytes = 256 * 1024,
        }) catch {
            return ToolResult.fail("Telegram send failed");
        };
        defer allocator.free(response.body);

        if (response.status_code < 200 or response.status_code >= 300) {
            return ToolResult.fail("Telegram send failed");
        }
        if (!telegramApiResponseOk(allocator, response.body)) {
            return ToolResult.fail("Telegram API rejected message");
        }

        const result_msg = if (image_url != null)
            std.fmt.allocPrint(
                allocator,
                "Photo delivered to telegram:{s} (caption {d} chars)",
                .{ resolved_chat_id, content.len },
            )
        else
            std.fmt.allocPrint(
                allocator,
                "Message delivered to telegram:{s} ({d} chars)",
                .{ resolved_chat_id, content.len },
            );
        if (result_msg) |msg| {
            return ToolResult.ok(msg);
        } else |_| {
            return ToolResult.ok(if (image_url != null) "Photo delivered to telegram" else "Message delivered to telegram");
        }
    }

    fn telegramApiResponseOk(allocator: std.mem.Allocator, body: []const u8) bool {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            log.warn("telegram send rejected: non-json response", .{});
            return false;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            log.warn("telegram send rejected: invalid JSON shape", .{});
            return false;
        }
        const ok_val = parsed.value.object.get("ok") orelse {
            log.warn("telegram send rejected: missing ok field", .{});
            return false;
        };
        if (ok_val != .bool or !ok_val.bool) {
            if (parsed.value.object.get("description")) |desc_val| {
                if (desc_val == .string and desc_val.string.len > 0) {
                    log.warn("telegram send rejected: {s}", .{desc_val.string});
                }
            }
            return false;
        }
        return true;
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
    try testing.expectEqualStrings("'content' must not be empty when image_url is not provided", result.error_msg.?);
}

test "MessageTool execute with empty content + image_url accepted (caption-less photo)" {
    // Regression for the 2026-04-29 image-send addition: empty content is
    // permitted when image_url is provided (Telegram tolerates a captionless
    // sendPhoto). The test path deliberately omits chat_id so we land at the
    // static "No chat_id specified" failure instead of the bus dispatch
    // (which would allocate a bus.Outbound that the test's drainless bus
    // can't free without a consumer).
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    defer event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    const parsed = try root.parseTestArgs(
        "{\"content\":\"\",\"channel\":\"telegram\",\"image_url\":\"https://example.com/img.png\"}",
    );
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    // The failure must NOT be the empty-content gate — that's the regression
    // we're pinning. Any downstream failure (no chat_id, no tenant) is fine.
    try testing.expect(result.error_msg != null);
    try testing.expect(std.mem.indexOf(u8, result.error_msg.?, "must not be empty") == null);
}

test "MessageTool execute rejects non-https image_url" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    defer event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    const parsed = try root.parseTestArgs(
        "{\"content\":\"hi\",\"channel\":\"telegram\",\"chat_id\":\"c1\",\"image_url\":\"http://insecure.example.com/x.png\"}",
    );
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("image_url must be a public HTTPS URL (got non-https)", result.error_msg.?);
}

test "MessageTool S7.8 rejects cross-channel send without allow_channel_override" {
    // S7.8 — if the inbound channel is telegram and the model passes
    // `channel=slack`, the tool must reject with a channel-locality
    // violation error unless `allow_channel_override=true` is also set.
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    defer event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    mt.setContext("telegram", "chat42");
    const parsed = try root.parseTestArgs("{\"content\":\"hi\",\"channel\":\"slack\",\"chat_id\":\"s1\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    defer if (result.error_msg) |e| testing.allocator.free(e);
    try testing.expect(!result.success);
    const err = result.error_msg orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, err, "Channel-locality violation") != null);
    try testing.expect(std.mem.indexOf(u8, err, "telegram") != null);
    try testing.expect(std.mem.indexOf(u8, err, "slack") != null);
}

test "MessageTool S7.8 accepts same-channel explicit arg (no override needed)" {
    // Passing `channel=telegram` when inbound IS telegram is a no-op
    // equality check; must NOT trigger the locality violation.
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    defer event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    mt.setContext("telegram", "chat42");
    const parsed = try root.parseTestArgs("{\"content\":\"ok\",\"channel\":\"telegram\",\"chat_id\":\"chat42\"}");
    defer parsed.deinit();
    const result = try mt.execute(testing.allocator, parsed.value.object);
    defer {
        if (result.error_msg) |e| testing.allocator.free(e);
        if (result.output.len > 0) testing.allocator.free(result.output);
    }
    // Drain any queued outbound so the bus doesn't leak on scope exit.
    if (event_bus.consumeOutbound()) |m| {
        var mm = m;
        mm.deinit(testing.allocator);
    }
    // Either succeeds (normal path) or fails on downstream reasons —
    // but the failure must NOT be the channel-locality one.
    if (result.error_msg) |e| {
        try testing.expect(std.mem.indexOf(u8, e, "Channel-locality violation") == null);
    }
}

test "telegramApiResponseOk accepts ok true payload" {
    try testing.expect(MessageTool.telegramApiResponseOk(testing.allocator, "{\"ok\":true,\"result\":{}}"));
}

test "telegramApiResponseOk rejects ok false payload" {
    try testing.expect(!MessageTool.telegramApiResponseOk(testing.allocator, "{\"ok\":false,\"description\":\"Bad Request: chat not found\"}"));
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

test "MessageTool execute with explicit channel overrides default (requires allow_channel_override post-S7.8)" {
    // S7.8 — cross-channel routing now requires an explicit
    // `allow_channel_override=true` opt-in. This test preserves the
    // pre-S7.8 assertion ("explicit channel arg routes there") under
    // the new opt-in shape.
    resetTestTurnContext();
    defer resetTestTurnContext();
    var event_bus = bus.Bus.init();
    defer event_bus.close();
    var mt = MessageTool{ .event_bus = &event_bus, .outbound_allocator = testing.allocator };
    mt.setContext("telegram", "chat42");
    const parsed = try root.parseTestArgs("{\"content\":\"hi\",\"channel\":\"discord\",\"chat_id\":\"room1\",\"allow_channel_override\":true}");
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

test "MessageTool background telegram requires bus when direct path is unavailable" {
    resetTestTurnContext();
    defer resetTestTurnContext();
    root.setTurnContext(.{ .origin = .heartbeat });
    defer root.clearTurnContext();

    var mt = MessageTool{};
    MessageTool.setTurnContext(.{
        .channel = "telegram",
        .chat_id = "123",
    });
    const parsed = try root.parseTestArgs("{\"content\":\"hello\"}");
    defer parsed.deinit();

    const result = try mt.execute(testing.allocator, parsed.value.object);
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Background Telegram send requires event bus dispatch", result.error_msg.?);
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
