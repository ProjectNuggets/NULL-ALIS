// ⚠️ V1.7-cherrypick PENDING WIRING (CR-WIP-02 from REVIEW.md 2026-05-02):
// This channel is fully implemented but not yet instantiated in
// `src/channel_manager.zig`. It IS gated — `enable_channel_teams` build
// flag defaults false; only `-Dchannels=all` or explicit `-Dchannels=teams`
// pulls this file in. The catalog at `src/channel_catalog.zig` declares
// Teams as `webhook_only` so once channel_manager learns to instantiate
// webhook-only channels, this slots in. Do NOT delete; the impl is faithful
// + tests pass. Final wire-up is queued as a follow-up commit.
const std = @import("std");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");
const bus_mod = @import("../bus.zig");

const log = std.log.scoped(.teams);

/// Microsoft Teams channel — Bot Framework REST API for outbound, webhook for inbound.
/// Uses Azure AD OAuth2 client credentials flow for authentication.
///
/// ## Teams Conversation ID Formats
///
/// Teams uses three different ID formats for the same conversation, depending on context:
///
/// 1. **Teams URL format** (`19:...@unq.gbl.spaces`) — visible in Teams deep-links and
///    the Teams client URL bar. NOT what Bot Framework uses.
///
/// 2. **Bot Framework `conversation.id`** (`a:1lFKq...`) — the ID in the Activity JSON
///    that Bot Framework sends to our webhook. This is the correct value for
///    `notification_channel_id` in config.json. Used for outbound API calls.
///
/// 3. **Session key format** (`29:...`) — sometimes seen in `from.id` or other fields.
///    NOT the conversation identifier.
///
/// When configuring `notification_channel_id`, use the Bot Framework format (type 2).
/// To discover it, send a message to the bot and check the `conversation.id` field
/// in the Activity JSON payload received at the `/api/messages` webhook.
pub const TeamsChannel = struct {
    allocator: std.mem.Allocator,
    account_id: []const u8 = "default",
    client_id: []const u8,
    client_secret: []const u8,
    tenant_id: []const u8,
    webhook_secret: ?[]const u8 = null,
    notification_channel_id: ?[]const u8 = null,
    bot_id: ?[]const u8 = null,
    bus: ?*bus_mod.Bus = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // OAuth2 token cache
    cached_token: ?[]u8 = null,
    token_expiry: i64 = 0, // epoch seconds

    // Config directory for conversation reference file persistence
    config_dir: []const u8 = ".",

    // Conversation reference for proactive messaging (serviceUrl + conversationId)
    conv_ref_service_url: ?[]u8 = null,
    conv_ref_conversation_id: ?[]u8 = null,

    // Placeholder activity ID cache: maps recipient target → activityId for pending placeholders.
    // Guarded by placeholder_mutex for thread safety (startTyping and vtableSend may run on different threads).
    placeholder_entries: [MAX_PLACEHOLDER_ENTRIES]?PlaceholderEntry = .{null} ** MAX_PLACEHOLDER_ENTRIES,
    placeholder_mutex: std.Thread.Mutex = .{},

    pub const MAX_PLACEHOLDER_ENTRIES = 16;
    pub const PlaceholderEntry = struct {
        target: []const u8, // owned by allocator
        activity_id: []const u8, // owned by allocator
    };
    pub const TOKEN_BUFFER_SECS: i64 = 5 * 60; // 5-minute buffer before token expiry
    pub const WEBHOOK_PATH = "/api/messages";

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.TeamsConfig) TeamsChannel {
        return .{
            .allocator = allocator,
            .account_id = cfg.account_id,
            .client_id = cfg.client_id,
            .client_secret = cfg.client_secret,
            .tenant_id = cfg.tenant_id,
            .webhook_secret = cfg.webhook_secret,
            .notification_channel_id = cfg.notification_channel_id,
            .bot_id = cfg.bot_id,
            .config_dir = cfg.config_dir,
        };
    }

    pub fn setBus(self: *TeamsChannel, b: *bus_mod.Bus) void {
        self.bus = b;
    }

    // ── OAuth2 Token Management ─────────────────────────────────────

    /// Acquire a new OAuth2 token from Azure AD using client credentials flow.
    pub fn acquireToken(self: *TeamsChannel) !void {
        var url_buf: [256]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        try url_fbs.writer().print("https://login.microsoftonline.com/{s}/oauth2/v2.0/token", .{self.tenant_id});
        const token_url = url_fbs.getWritten();

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        const bw = body_list.writer(self.allocator);
        try bw.writeAll("grant_type=client_credentials&client_id=");
        try writeUrlEncoded(bw, self.client_id);
        try bw.writeAll("&client_secret=");
        try writeUrlEncoded(bw, self.client_secret);
        try bw.writeAll("&scope=https%3A%2F%2Fapi.botframework.com%2F.default");

        const resp = root.http_util.curlPost(self.allocator, token_url, body_list.items, &.{"Content-Type: application/x-www-form-urlencoded"}) catch |err| {
            log.err("Teams OAuth2 token request failed: {}", .{err});
            return error.TeamsTokenError;
        };
        defer self.allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch {
            log.err("Teams OAuth2: failed to parse token response: {s}", .{resp[0..@min(resp.len, 500)]});
            return error.TeamsTokenError;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return error.TeamsTokenError;
        const obj = parsed.value.object;

        const token_val = obj.get("access_token") orelse {
            if (obj.get("error_description")) |desc| {
                if (desc == .string) log.err("Teams OAuth2 error: {s}", .{desc.string});
            } else if (obj.get("error")) |err_val| {
                if (err_val == .string) log.err("Teams OAuth2 error: {s}", .{err_val.string});
            } else {
                log.err("Teams OAuth2: no access_token in response: {s}", .{resp[0..@min(resp.len, 500)]});
            }
            return error.TeamsTokenError;
        };
        if (token_val != .string) return error.TeamsTokenError;

        const expires_in_val = obj.get("expires_in") orelse {
            log.err("Teams OAuth2: no expires_in in response", .{});
            return error.TeamsTokenError;
        };
        const expires_in: i64 = switch (expires_in_val) {
            .integer => expires_in_val.integer,
            else => return error.TeamsTokenError,
        };

        // V1.7-cherrypick fix (WR-WIP-04): dupe FIRST, then free old. The
        // previous order freed the cached token before the dupe; if the dupe
        // OOM'd, `self.cached_token` was still non-null but pointing to
        // freed memory — next getToken() call would read freed bytes.
        const new_tok = try self.allocator.dupe(u8, token_val.string);
        if (self.cached_token) |old| self.allocator.free(old);
        self.cached_token = new_tok;
        self.token_expiry = std.time.timestamp() + expires_in;

        log.info("Teams OAuth2 token acquired, expires in {d}s", .{expires_in});
    }

    /// Get a valid token, refreshing if necessary.
    fn getToken(self: *TeamsChannel) ![]const u8 {
        const now = std.time.timestamp();
        if (self.cached_token) |token| {
            if (now < self.token_expiry - TOKEN_BUFFER_SECS) {
                return token;
            }
        }
        try self.acquireToken();
        return self.cached_token orelse error.TeamsTokenError;
    }

    // ── Outbound Messaging ──────────────────────────────────────────

    /// Send a message to a Teams conversation via Bot Framework REST API.
    /// Returns the activityId from the response (caller-owned), or null if not available.
    pub fn sendMessage(self: *TeamsChannel, service_url: []const u8, conversation_id: []const u8, text: []const u8) !?[]const u8 {
        const token = try self.getToken();

        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        const svc = if (service_url.len > 0 and service_url[service_url.len - 1] == '/')
            service_url[0 .. service_url.len - 1]
        else
            service_url;
        try url_fbs.writer().print("{s}/v3/conversations/{s}/activities", .{ svc, conversation_id });
        const url = url_fbs.getWritten();

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        const bw = body_list.writer(self.allocator);
        try bw.writeAll("{\"type\":\"message\",\"text\":");
        try root.appendJsonStringW(bw, text);
        try bw.writeByte('}');

        var auth_buf: [2048]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        try auth_fbs.writer().print("Authorization: Bearer {s}", .{token});
        const auth_header = auth_fbs.getWritten();

        const resp = root.http_util.curlPost(self.allocator, url, body_list.items, &.{ auth_header, "Content-Type: application/json" }) catch |err| {
            log.err("Teams Bot Framework POST failed: {}", .{err});
            return error.TeamsSendError;
        };
        defer self.allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch {
            log.warn("Teams sendMessage: failed to parse response JSON", .{});
            return null;
        };
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("error")) |_| {
                log.err("Teams Bot Framework API returned error", .{});
                return error.TeamsSendError;
            }
            if (parsed.value.object.get("id")) |id_val| {
                if (id_val == .string) {
                    return try self.allocator.dupe(u8, id_val.string);
                }
            }
        }
        return null;
    }

    /// Update an existing message in a Teams conversation via Bot Framework REST API.
    pub fn updateMessage(self: *TeamsChannel, service_url: []const u8, conversation_id: []const u8, activity_id: []const u8, text: []const u8) !void {
        const token = try self.getToken();

        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        const svc = if (service_url.len > 0 and service_url[service_url.len - 1] == '/')
            service_url[0 .. service_url.len - 1]
        else
            service_url;
        try url_fbs.writer().print("{s}/v3/conversations/{s}/activities/{s}", .{ svc, conversation_id, activity_id });
        const url = url_fbs.getWritten();

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        const bw = body_list.writer(self.allocator);
        try bw.writeAll("{\"type\":\"message\",\"text\":");
        try root.appendJsonStringW(bw, text);
        try bw.writeByte('}');

        var auth_buf: [2048]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        try auth_fbs.writer().print("Authorization: Bearer {s}", .{token});
        const auth_header = auth_fbs.getWritten();

        // curlRequest returns CurlResponse = {status_code, body}; use .body
        const curl_resp = root.http_util.curlRequest(self.allocator, "PUT", url, &.{ auth_header, "Content-Type: application/json" }, body_list.items, null, "30") catch |err| {
            log.err("Teams Bot Framework PUT (update) failed: {}", .{err});
            return error.TeamsSendError;
        };
        defer self.allocator.free(curl_resp.body);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, curl_resp.body, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("error")) |_| {
                log.err("Teams Bot Framework update API returned error", .{});
                return error.TeamsSendError;
            }
        }
    }

    // ── Conversation Reference Persistence ──────────────────────────

    /// Save conversation reference to JSON file.
    pub fn saveConversationRef(self: *TeamsChannel, config_dir: []const u8) !void {
        const service_url = self.conv_ref_service_url orelse return;
        const conversation_id = self.conv_ref_conversation_id orelse return;

        var path_buf: [512]u8 = undefined;
        var path_fbs = std.io.fixedBufferStream(&path_buf);
        try path_fbs.writer().print("{s}/teams_conversation_ref.json", .{config_dir});
        const path = path_fbs.getWritten();

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);
        const bw = body_list.writer(self.allocator);
        try bw.writeAll("{\"serviceUrl\":");
        try root.appendJsonStringW(bw, service_url);
        try bw.writeAll(",\"conversationId\":");
        try root.appendJsonStringW(bw, conversation_id);
        try bw.writeByte('}');

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(body_list.items);

        log.info("Teams conversation reference saved to {s}", .{path});
    }

    /// Load conversation reference from JSON file.
    pub fn loadConversationRef(self: *TeamsChannel, config_dir: []const u8) !void {
        var path_buf: [512]u8 = undefined;
        var path_fbs = std.io.fixedBufferStream(&path_buf);
        try path_fbs.writer().print("{s}/teams_conversation_ref.json", .{config_dir});
        const path = path_fbs.getWritten();

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                log.debug("No Teams conversation reference file found", .{});
                return;
            }
            return err;
        };
        defer file.close();

        var buf: [4096]u8 = undefined;
        const len = try file.readAll(&buf);
        if (len == 0) return;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, buf[0..len], .{}) catch {
            log.warn("Failed to parse Teams conversation reference file", .{});
            return;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        // V1.7-cherrypick fix (WR-WIP-04): dupe FIRST, then free. See
        // acquireToken comment for rationale.
        if (obj.get("serviceUrl")) |v| {
            if (v == .string) {
                const new_url = try self.allocator.dupe(u8, v.string);
                if (self.conv_ref_service_url) |old| self.allocator.free(old);
                self.conv_ref_service_url = new_url;
            }
        }
        if (obj.get("conversationId")) |v| {
            if (v == .string) {
                const new_conv = try self.allocator.dupe(u8, v.string);
                if (self.conv_ref_conversation_id) |old| self.allocator.free(old);
                self.conv_ref_conversation_id = new_conv;
            }
        }

        if (self.conv_ref_service_url != null and self.conv_ref_conversation_id != null) {
            log.info("Teams conversation reference loaded", .{});
        }
    }

    /// Capture conversation reference from an inbound message if it matches the notification channel.
    pub fn captureConversationRef(self: *TeamsChannel, conversation_id: []const u8, service_url: []const u8, config_dir: []const u8) !void {
        const notif_id = self.notification_channel_id orelse return;
        if (!std.mem.eql(u8, conversation_id, notif_id)) return;

        // Already captured
        if (self.conv_ref_conversation_id != null) return;

        self.conv_ref_service_url = try self.allocator.dupe(u8, service_url);
        self.conv_ref_conversation_id = try self.allocator.dupe(u8, conversation_id);

        self.saveConversationRef(config_dir) catch |err| {
            log.warn("Failed to save conversation reference: {}", .{err});
        };
    }

    // ── Webhook Payload Parsing ─────────────────────────────────────

    pub const ParsedTeamsMessage = struct {
        text: []const u8,
        sender_id: []const u8,
        conversation_id: []const u8,
        service_url: []const u8,

        pub fn deinit(self: *ParsedTeamsMessage, allocator: std.mem.Allocator) void {
            allocator.free(self.text);
            allocator.free(self.sender_id);
            allocator.free(self.conversation_id);
            allocator.free(self.service_url);
        }
    };

    /// Parse a Bot Framework Activity JSON payload and return text messages.
    /// Caller owns the returned slice and must call deinit on each element.
    /// Returns an empty slice for non-message activities (e.g. conversationUpdate).
    /// Target key is `serviceUrl|conversationId` — matches vtableSend/startTyping format.
    pub fn parseWebhookPayload(allocator: std.mem.Allocator, body: []const u8) ![]ParsedTeamsMessage {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            log.warn("Teams webhook: failed to parse Activity JSON", .{});
            return &.{};
        };
        defer parsed.deinit();

        if (parsed.value != .object) return &.{};
        const obj = parsed.value.object;

        // Only process "message" type activities
        const type_val = obj.get("type") orelse return &.{};
        if (type_val != .string or !std.mem.eql(u8, type_val.string, "message")) return &.{};

        const text_val = obj.get("text") orelse return &.{};
        if (text_val != .string) return &.{};

        const from_val = obj.get("from") orelse return &.{};
        if (from_val != .object) return &.{};
        const from_id_val = from_val.object.get("id") orelse return &.{};
        if (from_id_val != .string) return &.{};

        const conv_val = obj.get("conversation") orelse return &.{};
        if (conv_val != .object) return &.{};
        const conv_id_val = conv_val.object.get("id") orelse return &.{};
        if (conv_id_val != .string) return &.{};

        const svc_val = obj.get("serviceUrl") orelse return &.{};
        if (svc_val != .string) return &.{};

        const messages = try allocator.alloc(ParsedTeamsMessage, 1);
        messages[0] = .{
            .text = try allocator.dupe(u8, text_val.string),
            .sender_id = try allocator.dupe(u8, from_id_val.string),
            .conversation_id = try allocator.dupe(u8, conv_id_val.string),
            .service_url = try allocator.dupe(u8, svc_val.string),
        };
        return messages;
    }

    // ── Placeholder Cache ──────────────────────────────────────────

    /// Cache a placeholder activityId for a recipient target. Dupes both target and activity_id.
    fn cachePlaceholder(self: *TeamsChannel, target: []const u8, activity_id: []const u8) void {
        self.placeholder_mutex.lock();
        defer self.placeholder_mutex.unlock();

        // Replace existing entry with the same target
        for (&self.placeholder_entries) |*entry| {
            if (entry.*) |e| {
                if (std.mem.eql(u8, e.target, target)) {
                    self.allocator.free(e.activity_id);
                    entry.*.?.activity_id = self.allocator.dupe(u8, activity_id) catch return;
                    return;
                }
            }
        }

        const owned_target = self.allocator.dupe(u8, target) catch return;
        const owned_id = self.allocator.dupe(u8, activity_id) catch {
            self.allocator.free(owned_target);
            return;
        };

        for (&self.placeholder_entries) |*entry| {
            if (entry.* == null) {
                entry.* = .{ .target = owned_target, .activity_id = owned_id };
                return;
            }
        }
        // Cache full — evict first entry (FIFO)
        self.allocator.free(self.placeholder_entries[0].?.target);
        self.allocator.free(self.placeholder_entries[0].?.activity_id);
        for (0..MAX_PLACEHOLDER_ENTRIES - 1) |i| {
            self.placeholder_entries[i] = self.placeholder_entries[i + 1];
        }
        self.placeholder_entries[MAX_PLACEHOLDER_ENTRIES - 1] = .{ .target = owned_target, .activity_id = owned_id };
    }

    /// Take (get + remove) a cached placeholder activityId for a target.
    /// Returns the activity_id (caller owns) and frees the target key.
    fn takePlaceholder(self: *TeamsChannel, target: []const u8) ?[]const u8 {
        self.placeholder_mutex.lock();
        defer self.placeholder_mutex.unlock();

        for (&self.placeholder_entries) |*entry| {
            if (entry.*) |e| {
                if (std.mem.eql(u8, e.target, target)) {
                    const id = e.activity_id;
                    self.allocator.free(e.target);
                    entry.* = null;
                    return id;
                }
            }
        }
        return null;
    }

    // ── Typing Indicator ──────────────────────────────────────────

    /// Send a typing indicator and placeholder message to a Teams conversation.
    /// The placeholder activityId is cached so vtableSend can update it with the real response.
    pub fn startTyping(self: *TeamsChannel, target: []const u8) !void {
        if (!self.running.load(.acquire)) return;

        // Parse target as "serviceUrl|conversationId".
        // Proactive messages (stored conv ref) won't have this format — silently skip,
        // since typing indicators don't make sense for bot-initiated messages.
        const sep = std.mem.indexOfScalar(u8, target, '|') orelse return;
        const service_url = target[0..sep];
        const conversation_id = target[sep + 1 ..];

        const token = self.getToken() catch |err| {
            log.warn("Teams startTyping: failed to get token: {}", .{err});
            return;
        };

        var url_buf: [512]u8 = undefined;
        var url_fbs = std.io.fixedBufferStream(&url_buf);
        const svc = if (service_url.len > 0 and service_url[service_url.len - 1] == '/')
            service_url[0 .. service_url.len - 1]
        else
            service_url;
        url_fbs.writer().print("{s}/v3/conversations/{s}/activities", .{ svc, conversation_id }) catch return;
        const url = url_fbs.getWritten();

        var auth_buf: [2048]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        auth_fbs.writer().print("Authorization: Bearer {s}", .{token}) catch return;
        const auth_header = auth_fbs.getWritten();

        const resp = root.http_util.curlPost(self.allocator, url, "{\"type\":\"typing\"}", &.{ auth_header, "Content-Type: application/json" }) catch |err| {
            log.warn("Teams typing indicator failed: {}", .{err});
            return;
        };
        self.allocator.free(resp);

        // Channel threads show a placeholder because typing animations don't render there.
        // DMs have native typing animation, so no placeholder needed.
        // Heuristic: channel thread conversationIds contain "@thread".
        // If Microsoft changes the format, this degrades gracefully to no-placeholder (DM behavior).
        const is_thread = std.mem.indexOf(u8, conversation_id, "@thread") != null;
        if (is_thread) {
            const placeholder_id = self.sendMessage(service_url, conversation_id, "\u{1F914} Working on it...") catch |err| {
                log.warn("Teams placeholder message failed: {}", .{err});
                return;
            };
            if (placeholder_id) |id| {
                defer self.allocator.free(id);
                self.cachePlaceholder(target, id);
                log.debug("Teams placeholder cached for target, activityId={s}", .{id});
            }
        }
    }

    /// No-op — Bot Framework typing indicator auto-clears after ~3 seconds.
    pub fn stopTyping(_: *TeamsChannel, _: []const u8) !void {}

    // ── VTable Implementation ───────────────────────────────────────

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));
        if (self.running.load(.acquire)) return;

        self.running.store(true, .release);
        errdefer self.running.store(false, .release);

        if (self.webhook_secret == null) {
            log.warn("Teams webhook_secret not configured — inbound auth is disabled", .{});
        }

        self.acquireToken() catch |err| {
            log.warn("Teams initial token acquisition failed (will retry on send): {}", .{err});
        };

        self.loadConversationRef(self.config_dir) catch |err| {
            log.warn("Teams conversation ref load failed: {}", .{err});
        };

        log.info("Teams channel started", .{});
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));
        self.running.store(false, .release);

        if (self.cached_token) |token| {
            self.allocator.free(token);
            self.cached_token = null;
        }
        if (self.conv_ref_service_url) |url| {
            self.allocator.free(url);
            self.conv_ref_service_url = null;
        }
        if (self.conv_ref_conversation_id) |id| {
            self.allocator.free(id);
            self.conv_ref_conversation_id = null;
        }

        for (&self.placeholder_entries) |*entry| {
            if (entry.*) |e| {
                self.allocator.free(e.target);
                self.allocator.free(e.activity_id);
                entry.* = null;
            }
        }

        log.info("Teams channel stopped", .{});
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));

        const clean = if (std.mem.indexOf(u8, message, "<nc_choices>")) |tag_start|
            std.mem.trimRight(u8, message[0..tag_start], &std.ascii.whitespace)
        else
            message;

        if (self.takePlaceholder(target)) |cached_id| {
            defer self.allocator.free(cached_id);
            if (std.mem.indexOfScalar(u8, target, '|')) |sep| {
                const service_url = target[0..sep];
                const conversation_id = target[sep + 1 ..];
                self.updateMessage(service_url, conversation_id, cached_id, clean) catch |err| {
                    log.warn("Teams placeholder update failed, sending new message: {}", .{err});
                    const activity_id = try self.sendMessage(service_url, conversation_id, clean);
                    if (activity_id) |id| self.allocator.free(id);
                };
                return;
            }
        }

        // Target format: "serviceUrl|conversationId" or use stored conversation ref for proactive
        if (std.mem.indexOfScalar(u8, target, '|')) |sep| {
            const service_url = target[0..sep];
            const conversation_id = target[sep + 1 ..];
            const activity_id = try self.sendMessage(service_url, conversation_id, clean);
            if (activity_id) |id| self.allocator.free(id);
        } else if (self.conv_ref_service_url != null and self.conv_ref_conversation_id != null) {
            const activity_id = try self.sendMessage(self.conv_ref_service_url.?, self.conv_ref_conversation_id.?, clean);
            if (activity_id) |id| self.allocator.free(id);
        } else {
            log.warn("Teams send: no conversation reference available for target '{s}'", .{target});
        }
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));
        _ = self;
        return "teams";
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));
        if (!self.running.load(.acquire)) return false;
        const now = std.time.timestamp();
        if (self.cached_token != null and now < self.token_expiry - TOKEN_BUFFER_SECS) {
            return true;
        }
        self.acquireToken() catch return false;
        return self.cached_token != null;
    }

    /// URL-encode a string for use in application/x-www-form-urlencoded bodies.
    fn writeUrlEncoded(writer: anytype, input: []const u8) !void {
        for (input) |c| {
            switch (c) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '*' => try writer.writeByte(c),
                ' ' => try writer.writeByte('+'),
                else => {
                    try writer.writeByte('%');
                    const hex = "0123456789ABCDEF";
                    try writer.writeByte(hex[c >> 4]);
                    try writer.writeByte(hex[c & 0x0F]);
                },
            }
        }
    }

    fn vtableStartTyping(ptr: *anyopaque, recipient: []const u8) anyerror!void {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));
        return self.startTyping(recipient);
    }

    fn vtableStopTyping(ptr: *anyopaque, recipient: []const u8) anyerror!void {
        const self: *TeamsChannel = @ptrCast(@alignCast(ptr));
        return self.stopTyping(recipient);
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
        .startTyping = &vtableStartTyping,
        .stopTyping = &vtableStopTyping,
    };

    pub fn channel(self: *TeamsChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

test "Teams startTyping and stopTyping are safe in tests" {
    var ch = TeamsChannel{
        .allocator = std.testing.allocator,
        .client_id = "test-client-id",
        .client_secret = "test-secret",
        .tenant_id = "test-tenant",
    };
    // startTyping returns immediately when not running (running = false by default)
    try ch.startTyping("https://smba.trafficmanager.net/teams|19:abc@thread.v2");
    try ch.stopTyping("https://smba.trafficmanager.net/teams|19:abc@thread.v2");
}

test "Teams stopTyping is idempotent" {
    var ch = TeamsChannel{
        .allocator = std.testing.allocator,
        .client_id = "test-client-id",
        .client_secret = "test-secret",
        .tenant_id = "test-tenant",
    };
    try ch.stopTyping("https://smba.trafficmanager.net/teams|19:abc@thread.v2");
    try ch.stopTyping("https://smba.trafficmanager.net/teams|19:abc@thread.v2");
}

test "vtableSend strips nc_choices tags from message" {
    const msg = "Pick one:\n- Option A\n- Option B\n<nc_choices>{\"v\":1,\"options\":[{\"id\":\"a\",\"label\":\"A\"},{\"id\":\"b\",\"label\":\"B\"}]}</nc_choices>";
    const clean = if (std.mem.indexOf(u8, msg, "<nc_choices>")) |tag_start|
        std.mem.trimRight(u8, msg[0..tag_start], &std.ascii.whitespace)
    else
        msg;
    try std.testing.expectEqualStrings("Pick one:\n- Option A\n- Option B", clean);
}

test "placeholder cache stores and retrieves by target" {
    var ch = TeamsChannel{
        .allocator = std.testing.allocator,
        .client_id = "test-client-id",
        .client_secret = "test-secret",
        .tenant_id = "test-tenant",
    };
    const target = "https://smba.trafficmanager.net/teams|19:abc@thread.v2";

    ch.cachePlaceholder(target, "activity-123");

    const taken = ch.takePlaceholder(target);
    try std.testing.expect(taken != null);
    try std.testing.expectEqualStrings("activity-123", taken.?);
    std.testing.allocator.free(taken.?);

    try std.testing.expect(ch.takePlaceholder(target) == null);
}

test "placeholder cache returns null for unknown target" {
    var ch = TeamsChannel{
        .allocator = std.testing.allocator,
        .client_id = "test-client-id",
        .client_secret = "test-secret",
        .tenant_id = "test-tenant",
    };
    try std.testing.expect(ch.takePlaceholder("unknown|target") == null);
}

test "placeholder cache replaces duplicate target" {
    var ch = TeamsChannel{
        .allocator = std.testing.allocator,
        .client_id = "test-client-id",
        .client_secret = "test-secret",
        .tenant_id = "test-tenant",
    };
    const target = "https://smba.trafficmanager.net/teams|19:abc@thread.v2";

    ch.cachePlaceholder(target, "first-id");
    ch.cachePlaceholder(target, "second-id");

    const taken = ch.takePlaceholder(target);
    try std.testing.expect(taken != null);
    try std.testing.expectEqualStrings("second-id", taken.?);
    std.testing.allocator.free(taken.?);

    try std.testing.expect(ch.takePlaceholder(target) == null);
}

test "placeholder cache evicts oldest when full" {
    var ch = TeamsChannel{
        .allocator = std.testing.allocator,
        .client_id = "test-client-id",
        .client_secret = "test-secret",
        .tenant_id = "test-tenant",
    };

    var targets: [TeamsChannel.MAX_PLACEHOLDER_ENTRIES][32]u8 = undefined;
    for (0..TeamsChannel.MAX_PLACEHOLDER_ENTRIES) |i| {
        var fbs = std.io.fixedBufferStream(&targets[i]);
        fbs.writer().print("target-{d}", .{i}) catch unreachable;
        ch.cachePlaceholder(fbs.getWritten(), "id");
    }

    ch.cachePlaceholder("target-overflow", "overflow");

    var fbs1: [32]u8 = undefined;
    var fbs1_stream = std.io.fixedBufferStream(&fbs1);
    fbs1_stream.writer().print("target-{d}", .{1}) catch unreachable;
    const taken1 = ch.takePlaceholder(fbs1_stream.getWritten());
    try std.testing.expect(taken1 != null);
    std.testing.allocator.free(taken1.?);

    const taken_overflow = ch.takePlaceholder("target-overflow");
    try std.testing.expect(taken_overflow != null);
    std.testing.allocator.free(taken_overflow.?);

    for (2..TeamsChannel.MAX_PLACEHOLDER_ENTRIES) |i| {
        var tgt_buf: [32]u8 = undefined;
        var tgt_fbs = std.io.fixedBufferStream(&tgt_buf);
        tgt_fbs.writer().print("target-{d}", .{i}) catch unreachable;
        if (ch.takePlaceholder(tgt_fbs.getWritten())) |id| {
            std.testing.allocator.free(id);
        }
    }
}

test "vtableSend preserves message without nc_choices" {
    const msg = "Hello, how can I help?";
    const clean = if (std.mem.indexOf(u8, msg, "<nc_choices>")) |tag_start|
        std.mem.trimRight(u8, msg[0..tag_start], &std.ascii.whitespace)
    else
        msg;
    try std.testing.expectEqualStrings("Hello, how can I help?", clean);
}

test "parseWebhookPayload returns empty for non-message type" {
    const body =
        \\{"type":"conversationUpdate","conversation":{"id":"19:abc"},"serviceUrl":"https://smba.trafficmanager.net/"}
    ;
    const msgs = try TeamsChannel.parseWebhookPayload(std.testing.allocator, body);
    defer std.testing.allocator.free(msgs);
    try std.testing.expectEqual(@as(usize, 0), msgs.len);
}

test "parseWebhookPayload parses message activity" {
    const body =
        \\{"type":"message","text":"Hello bot","from":{"id":"29:user-abc"},"conversation":{"id":"a:conv-xyz"},"serviceUrl":"https://smba.trafficmanager.net/teams/"}
    ;
    const msgs = try TeamsChannel.parseWebhookPayload(std.testing.allocator, body);
    defer {
        for (msgs) |*m| m.deinit(std.testing.allocator);
        std.testing.allocator.free(msgs);
    }
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings("Hello bot", msgs[0].text);
    try std.testing.expectEqualStrings("29:user-abc", msgs[0].sender_id);
    try std.testing.expectEqualStrings("a:conv-xyz", msgs[0].conversation_id);
    try std.testing.expectEqualStrings("https://smba.trafficmanager.net/teams/", msgs[0].service_url);
}

test "parseWebhookPayload returns empty for invalid JSON" {
    const msgs = try TeamsChannel.parseWebhookPayload(std.testing.allocator, "not-json");
    defer std.testing.allocator.free(msgs);
    try std.testing.expectEqual(@as(usize, 0), msgs.len);
}

test "parseWebhookPayload returns empty when text field missing" {
    const body =
        \\{"type":"message","from":{"id":"29:user"},"conversation":{"id":"a:conv"},"serviceUrl":"https://example.com/"}
    ;
    const msgs = try TeamsChannel.parseWebhookPayload(std.testing.allocator, body);
    defer std.testing.allocator.free(msgs);
    try std.testing.expectEqual(@as(usize, 0), msgs.len);
}
